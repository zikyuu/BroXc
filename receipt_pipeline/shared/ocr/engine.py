"""Preprocessing + OCR with a confidence gate that falls back to page-dewarp."""

from dataclasses import dataclass, field
from functools import lru_cache
from typing import List, Optional, Tuple

import cv2
import easyocr
import numpy as np

from .dewarp import DewarpError, dewarp_image

LOW_CONFIDENCE_THRESHOLD = 0.8  
#changed from 0.55 to 0.8 since the output from a ocr confidence 0.6 receipt was sooooo bad ughhhh

@dataclass
class OcrLine:
    text: str
    confidence: float
    bbox: List[List[float]] = field(default_factory=list)  # optional bounding box, not used in parsing


@dataclass
class OcrResult:
    lines: List[OcrLine]
    raw_text: str
    average_confidence: float
    used_dewarp: bool


@lru_cache(maxsize=4)
def _get_reader(languages: Tuple[str, ...]) -> easyocr.Reader:
    return easyocr.Reader(list(languages), gpu=False)


def _preprocess(image_path: str) -> np.ndarray:
    """Deskew/contrast/denoise pass — classical CV, not a neural model."""
    img = cv2.imread(image_path)
    #^ loads image file into memoery as numpy array of pixel values 
    if img is None:
        raise ValueError(f"could not read image: {image_path}")

    #converts colour to grayscale (since ocr ignores colour)
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    #CLAHE: contrat limited adaptive histogram equalisation
    #boosts local contrast (does it uniformly across the whole iamge)
    #washes out/blow out diff regions of unevenly lit receipt 
    #helps improve ocr accuracy since they are photographs of receipts not scanned
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    contrasted = clahe.apply(gray)
    #falseNlMeansDenoising: removes noise from image while preserving edges
    #h=10: filter strength for luminance component, higher h removes more noise but
    #can also remove fine details, lower h preserves details but may leave more noise
    return cv2.fastNlMeansDenoising(contrasted, h=10)


def _run_easyocr(reader: easyocr.Reader, image: np.ndarray) -> Tuple[List[OcrLine], str, float]:
    #ocr main method -> returns list of (bounding box, text, confidence) tuples
    #one per detected line/text region 
    results = reader.readtext(image)
    #keeps the bounding box this time — the receipt parser still ignores it (it just needs
    #text + confidence), but the YouTrip screenshot parser needs it to group text into rows
    lines = [OcrLine(text=text, confidence=conf, bbox=bbox) for bbox, text, conf in results]
    #joins every line into a newline separated block
    #for ReceiptDraft.raw_text
    raw_text = "\n".join(line.text for line in lines)
    avg_confidence = sum(l.confidence for l in lines) / len(lines) if lines else 0.0
    return lines, raw_text, avg_confidence
    #avg confidence -> help decide if dewarp fallback needs to be used


def run_ocr(image_path: str, languages: List[str], allow_dewarp: bool = False) -> OcrResult:
    """Full OCR pass: preprocess -> EasyOCR -> confidence gate -> optional page-dewarp retry.

    Dewarp is off by default: the live inputs are clean screenshots, where it does more harm
    than good. Pass allow_dewarp=True to re-enable it for photographed receipts.
    """
    reader = _get_reader(tuple(languages))

    lines, raw_text, confidence = _run_easyocr(reader, _preprocess(image_path))
    if not allow_dewarp or confidence >= LOW_CONFIDENCE_THRESHOLD:
        return OcrResult(lines, raw_text, confidence, used_dewarp=False)

    try:
        dewarped_path = dewarp_image(image_path)
    except DewarpError:
        return OcrResult(lines, raw_text, confidence, used_dewarp=False)

    dewarped_lines, dewarped_raw_text, dewarped_confidence = _run_easyocr(
        reader, _preprocess(dewarped_path)
    )
    if dewarped_confidence > confidence:
        return OcrResult(dewarped_lines, dewarped_raw_text, dewarped_confidence, used_dewarp=True)

    return OcrResult(lines, raw_text, confidence, used_dewarp=False)

ROW_TOLERANCE_FACTOR = 0.3  # fraction of the median text-box height two boxes may differ by and still share a row

def group_into_rows(lines: List[OcrLine], y_tolerance: Optional[float] = None) -> List[Tuple[str, float]]:
    """Clusters text boxes into visual lines by vertical position, each read left-to-right.

    y_tolerance is in pixels; left as None it scales with the median text height, so the same
    setting works whether the screenshot is 430px or 1200px wide (a fixed pixel value fused
    neighbouring rows on small images and split name from price on large ones).
    """
    '''returns (row text, row confidence) pairs wherer row confidence is the minimum of that rows boxes' confidence'''
    ''' aka if the item name is perfectly clear but price is smudged, it is overall counted as low confidence'''
    def y_center(line: OcrLine) -> float:
        ys = [p[1] for p in line.bbox]
        return sum(ys) / len(ys) if ys else 0.0

    def x_left(line: OcrLine) -> float:
        xs = [p[0] for p in line.bbox]
        return min(xs) if xs else 0.0

    if y_tolerance is None:
        heights = sorted(max(p[1] for p in l.bbox) - min(p[1] for p in l.bbox) for l in lines if l.bbox)
        y_tolerance = ROW_TOLERANCE_FACTOR * heights[len(heights) // 2] if heights else 0.0

    rows: List[List[OcrLine]] = []
    for line in sorted(lines, key=y_center):
        for row in rows:
            if abs(y_center(row[0]) - y_center(line)) <= y_tolerance:
                row.append(line)
                break
        else:
            rows.append([line])

    result: List[Tuple[str, float]] = []
    for row in rows:
        row.sort(key=x_left)
        text = " ".join(l.text for l in row)
        confidence = min(l.confidence for l in row)
        result.append((text, confidence))
    return result