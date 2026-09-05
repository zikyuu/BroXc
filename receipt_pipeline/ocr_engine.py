"""Preprocessing + OCR with a confidence gate that falls back to page-dewarp."""

from dataclasses import dataclass
from functools import lru_cache
from typing import List, Tuple

import cv2
import easyocr
import numpy as np

from .dewarp import DewarpError, dewarp_image

LOW_CONFIDENCE_THRESHOLD = 0.55  # below this average, retry once through page-dewarp


@dataclass
class OcrLine:
    text: str
    confidence: float


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
    #unpacks each tuple and throws away the bounding box, keeping only the text and confidence
    lines = [OcrLine(text=text, confidence=conf) for _, text, conf in results]
    #joins every line into a newline separated block
    #for ReceiptDraft.raw_text
    raw_text = "\n".join(line.text for line in lines)
    avg_confidence = sum(l.confidence for l in lines) / len(lines) if lines else 0.0
    return lines, raw_text, avg_confidence
    #avg confidence -> help decide if dewarp fallback needs to be used


def run_ocr(image_path: str, languages: List[str]) -> OcrResult:
    """Full OCR pass: preprocess -> EasyOCR -> confidence gate -> optional page-dewarp retry."""
    reader = _get_reader(tuple(languages))

    lines, raw_text, confidence = _run_easyocr(reader, _preprocess(image_path))
    if confidence >= LOW_CONFIDENCE_THRESHOLD:
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