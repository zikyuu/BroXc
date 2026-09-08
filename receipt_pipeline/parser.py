"""Rule-based field / line-item extraction from OCR output."""

import re
from typing import List, Optional, Tuple

from .merchant_profiles import MerchantProfileStore
from .ocr_engine import OcrResult
from .tag_store import TagStore
from .translator import translate
from .types import Lineitem, ReceiptDraft, ReviewStatus

# generic multilingual keyword defaults — merchant profile corrections extend these per-merchant
TOTAL_KEYWORDS = ["total", "totalt", "att betala", "summe", "gesamt", "yhteensä", "summa"]
TAX_KEYWORDS = ["gst", "vat", "moms", "mwst", "tax"]
DEPOSIT_KEYWORDS = ["pant", "pfand", "pantti"]
DISCOUNT_KEYWORDS = ["rabatt", "discount", "off"]

AMOUNT_PATTERN = re.compile(r"-?\d+[.,]\d{2}\b")
QUANTITY_PATTERN = re.compile(r"\b(\d+)\s*[x×]\s*", re.IGNORECASE)
CURRENCY_PATTERN = re.compile(r"\b(SEK|EUR|NOK|DKK|GBP|USD|SGD|KR|€|£|\$)\b", re.IGNORECASE)
DATE_PATTERN = re.compile(r"\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}[./]\d{1,2}[./]\d{2,4}\b")

MYSTERY_LINE_CONFIDENCE = 0.4


def _extract_amount(text: str) -> Optional[float]:
    matches = AMOUNT_PATTERN.findall(text)
    if not matches:
        return None
    return float(matches[-1].replace(",", "."))


def _strip_amount(text: str) -> str:
    return AMOUNT_PATTERN.sub("", text).strip(" -\t")


def _extract_quantity(text: str) -> Tuple[float, str]:
    match = QUANTITY_PATTERN.search(text)
    if not match:
        return 1.0, text
    return float(match.group(1)), QUANTITY_PATTERN.sub("", text, count=1)


def _matches_any(text: str, keywords: List[str]) -> bool:
    lowered = text.lower()
    return any(kw in lowered for kw in keywords)


def _guess_merchant(lines: List[str]) -> Optional[str]:
    for line in lines:
        stripped = line.strip()
        if len(stripped) >= 3 and not AMOUNT_PATTERN.search(stripped):
            return stripped
    return None


def _guess_currency(lines: List[str]) -> Optional[str]:
    for line in lines:
        match = CURRENCY_PATTERN.search(line)
        if match:
            return match.group(1).upper()
    return None


def _guess_date(lines: List[str]) -> Optional[str]:
    for line in lines:
        match = DATE_PATTERN.search(line)
        if match:
            return match.group(0)
    return None


def parse_receipt(
    ocr_result: OcrResult,
    profile_store: MerchantProfileStore,
    tag_store: TagStore,
    source_language: str = "sv",
    source_image_path: Optional[str] = None,
) -> ReceiptDraft:
    """Turns raw OCR lines into a ReceiptDraft — every field here is a suggestion, never confirmed."""
    raw_texts = [line.text for line in ocr_result.lines]

    merchant = _guess_merchant(raw_texts)
    profile = profile_store.get(merchant or "")
    ignore_lines = set(profile.ignore_lines)
    total_keywords = TOTAL_KEYWORDS + profile.total_keywords

    total: Optional[float] = None
    tax: Optional[float] = None
    line_items: List[Lineitem] = []

    for ocr_line in ocr_result.lines:
        text = ocr_line.text.strip()
        if not text or text in ignore_lines:
            continue

        if _matches_any(text, total_keywords):
            amount = _extract_amount(text)
            if amount is not None:
                total = amount
            continue

        if _matches_any(text, TAX_KEYWORDS):
            amount = _extract_amount(text)
            if amount is not None:
                tax = amount
            continue

        if _matches_any(text, DEPOSIT_KEYWORDS):
            amount = _extract_amount(text)
            if amount is not None:
                line_items.append(Lineitem(name=text, price=amount, is_deposit=True))
            continue

        amount = _extract_amount(text)
        if amount is None:
            continue

        without_amount = _strip_amount(text)

        if amount < 0 and line_items and (_matches_any(text, DISCOUNT_KEYWORDS) or len(without_amount) <= 3):
            previous = line_items[-1]
            previous.original_price = previous.price
            previous.discount = abs(amount)
            previous.price = previous.original_price - previous.discount
            continue

        quantity, name = _extract_quantity(without_amount)
        name = name.strip(" -\t")

        unreadable = not name or ocr_line.confidence < MYSTERY_LINE_CONFIDENCE

        if unreadable:
            translated = None
            tags = ["mystery"]
        else:
            translated = profile.item_translations.get(name)
            if translated is None:
                translated = translate(name, source_lang=source_language)
                if translated and merchant:
                    # seed the cache with the model's own output — a human correction later just overwrites this same entry
                    profile_store.record_correction(merchant, item_translation=(name, translated))
            tags = tag_store.suggest(translated or name)

        line_items.append(Lineitem(
            name=name or text,
            price=amount,
            quantity=quantity,
            translated_text=translated,
            tags=tags,
        ))

    return ReceiptDraft(
        merchant=merchant,
        date=_guess_date(raw_texts),
        currency=_guess_currency(raw_texts),
        total=total,
        tax=tax,
        line_items=line_items,
        status=ReviewStatus.NEEDS_REVIEW,
        suggested_category="Mystery" if total is None and not line_items else None,
        ocr_confidence=ocr_result.average_confidence,
        raw_text=ocr_result.raw_text,
        source_image_path=source_image_path,
    )