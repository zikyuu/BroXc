"""Rule-based field / line-item extraction from OCR output."""

import re
from typing import List, Optional

from .merchant_profiles import MerchantProfileStore
from .ocr_engine import OcrResult
from .types import Lineitem, ReceiptDraft, ReviewStatus

# generic multilingual keyword defaults — merchant profile corrections extend these per-merchant
TOTAL_KEYWORDS = ["total", "totalt", "att betala", "summe", "gesamt", "yhteensä", "summa"]
TAX_KEYWORDS = ["gst", "vat", "moms", "mwst", "tax"]
DEPOSIT_KEYWORDS = ["pant", "pfand", "pantti"]
DISCOUNT_KEYWORDS = ["rabatt", "discount", "off"]

AMOUNT_PATTERN = re.compile(r"-?\d+[.,]\d{2}\b")
CURRENCY_PATTERN = re.compile(r"\b(SEK|EUR|NOK|DKK|GBP|USD|SGD|KR|€|£|\$)\b", re.IGNORECASE)
DATE_PATTERN = re.compile(r"\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}[./]\d{1,2}[./]\d{2,4}\b")


def _extract_amount(line: str) -> Optional[float]:
    """Pulls the last decimal-looking number off a line — receipts put the price at the end."""
    matches = AMOUNT_PATTERN.findall(line)
    if not matches:
        return None
    return float(matches[-1].replace(",", "."))


def _strip_amount(line: str) -> str:
    """Line with its amount(s) removed, for use as an item name."""
    return AMOUNT_PATTERN.sub("", line).strip(" -\t")


def _matches_any(line: str, keywords: List[str]) -> bool:
    lowered = line.lower()
    return any(kw in lowered for kw in keywords)


def _guess_merchant(lines: List[str]) -> Optional[str]:
    """First substantive, non-numeric line is usually the merchant name — a rough heuristic to refine against real receipts."""
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
    source_image_path: Optional[str] = None,
) -> ReceiptDraft:
    """Turns raw OCR lines into a ReceiptDraft — every field here is a suggestion, never confirmed."""
    raw_lines = [line.text for line in ocr_result.lines]

    merchant = _guess_merchant(raw_lines)
    profile = profile_store.get(merchant or "")
    ignore_lines = set(profile.ignore_lines)
    total_keywords = TOTAL_KEYWORDS + profile.total_keywords

    total: Optional[float] = None
    tax: Optional[float] = None
    line_items: List[Lineitem] = []

    for raw_line in raw_lines:
        line = raw_line.strip()
        if not line or line in ignore_lines:
            continue

        if _matches_any(line, total_keywords):
            amount = _extract_amount(line)
            if amount is not None:
                total = amount
            continue

        if _matches_any(line, TAX_KEYWORDS):
            amount = _extract_amount(line)
            if amount is not None:
                tax = amount
            continue

        if _matches_any(line, DEPOSIT_KEYWORDS):
            amount = _extract_amount(line)
            if amount is not None:
                line_items.append(Lineitem(name=line, price=amount, is_deposit=True))
            continue

        amount = _extract_amount(line)
        if amount is None:
            continue  # no price and no keyword match — not an item

        name = _strip_amount(line)

        # a lone negative amount right after an item, keyword-flagged or too short to be its own name, is a discount on it
        if amount < 0 and line_items and (_matches_any(line, DISCOUNT_KEYWORDS) or len(name) <= 3):
            previous = line_items[-1]
            previous.original_price = previous.price
            previous.discount = abs(amount)
            previous.price = previous.original_price - previous.discount
            continue

        line_items.append(Lineitem(name=name, price=amount, translated_text=profile.item_translations.get(name)))

    suggested_category = "Mystery" if total is None and not line_items else None

    return ReceiptDraft(
        merchant=merchant,
        date=_guess_date(raw_lines),
        currency=_guess_currency(raw_lines),
        total=total,
        tax=tax,
        line_items=line_items,
        status=ReviewStatus.NEEDS_REVIEW,
        suggested_category=suggested_category,
        ocr_confidence=ocr_result.average_confidence,
        raw_text=ocr_result.raw_text,
        source_image_path=source_image_path,
    )