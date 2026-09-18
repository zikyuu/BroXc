"""Parser for a Google Translate screenshot of a receipt — the text is already English, so no
translation step and English keywords.

Deliberately separate from parser.py (the photographed-receipt parser, currently unlinked from
the pipeline) so either can change without touching the other; the small helpers below are
duplicated on purpose and can be merged when parser.py comes back.
"""

import re
from typing import List, Optional, Tuple

from ..shared.ocr.engine import OcrResult, group_into_rows
from ..types import Lineitem, ReceiptDraft, ReviewStatus
from .merchant_profiles import MerchantProfileStore
from .tag_store import TagStore

# best guesses at how Google renders Swedish receipt terms — calibrate against a real screenshot
TOTAL_KEYWORDS = ["total", "to pay", "amount due"]
TAX_KEYWORDS = ["vat", "gst", "tax"]
DEPOSIT_KEYWORDS = ["deposit", "pledge", "pant"]
DISCOUNT_KEYWORDS = ["discount", "rebate"]
# recap lines that restate a figure already captured elsewhere, not real items or totals
SKIP_KEYWORDS = ["subtotal", "sub total", "summary", "summation"]

AMOUNT_PATTERN = re.compile(r"-?\d+[.,]\d{2}\b")
QUANTITY_PATTERN = re.compile(r"\b(\d+)\s*[x×]\s*", re.IGNORECASE)
# a quantity/weight breakdown on its own line under an item: "2 pcs x 20.95", "0,298 kg x 103,16 SEK/kg"
QUANTITY_BREAKDOWN_PATTERN = re.compile(r"^\s*([\d.,]+)\s*[A-Za-z]{1,6}\.?\s*x\s*[\d.,]+", re.IGNORECASE)
CURRENCY_PATTERN = re.compile(r"(?<!\w)(SEK|EUR|NOK|DKK|GBP|USD|SGD|KR|€|£|\$)(?!\w)", re.IGNORECASE)
DATE_PATTERN = re.compile(r"\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}[./]\d{1,2}[./]\d{2,4}\b")

MYSTERY_LINE_CONFIDENCE = 0.4  # below this per-row confidence, tag the item "mystery"


def _extract_amount(text: str) -> Optional[float]:
    matches = AMOUNT_PATTERN.findall(text)
    if not matches:
        return None
    return float(matches[-1].replace(",", "."))


def _strip_amount(text: str) -> str:
    return AMOUNT_PATTERN.sub("", text).strip(" -\t")


def _extract_quantity(text: str) -> Tuple[float, str]:
    """Pulls a '2 x' / '3x' multiplier on the SAME line as the item."""
    match = QUANTITY_PATTERN.search(text)
    if not match:
        return 1.0, text
    return float(match.group(1)), QUANTITY_PATTERN.sub("", text, count=1)


def _matches_any(text: str, keywords: List[str]) -> bool:
    """Whole-word match, so 'pant' doesn't fire on 'pants' or 'vat' on 'private'."""
    lowered = text.lower()
    return any(re.search(rf"\b{re.escape(kw)}\b", lowered) for kw in keywords)


def _guess_merchant(rows: List[str]) -> Optional[str]:
    for row in rows:
        stripped = row.strip()
        if len(stripped) >= 3 and not AMOUNT_PATTERN.search(stripped):
            return stripped
    return None


def _guess_currency(rows: List[str]) -> Optional[str]:
    for row in rows:
        match = CURRENCY_PATTERN.search(row)
        if match:
            return match.group(1).upper()
    return None


def _guess_date(rows: List[str]) -> Optional[str]:
    for row in rows:
        match = DATE_PATTERN.search(row)
        if match:
            return match.group(0)
    return None


def read_original_merchant(ocr_result: OcrResult) -> Optional[str]:
    """Store name off the original-language receipt, kept as printed (untranslated) so it can be
    compared against the Swedish description YouTrip shows."""
    return _guess_merchant([text for text, _ in group_into_rows(ocr_result.lines)])


def parse_translated_receipt(
    ocr_result: OcrResult,
    profile_store: MerchantProfileStore,
    tag_store: TagStore,
    source_image_path: Optional[str] = None,
) -> ReceiptDraft:
    """Turns OCR of a translated receipt screenshot into a ReceiptDraft — suggestions only."""
    grouped_rows = group_into_rows(ocr_result.lines)
    row_texts = [text for text, _ in grouped_rows]

    merchant = _guess_merchant(row_texts)
    profile = profile_store.get(merchant or "")
    ignore_lines = set(profile.ignore_lines)
    total_keywords = TOTAL_KEYWORDS + profile.total_keywords

    total: Optional[float] = None
    tax: Optional[float] = None
    line_items: List[Lineitem] = []
    seen_total = False

    for text, row_confidence in grouped_rows:
        text = text.strip()
        if not text or text in ignore_lines or _matches_any(text, SKIP_KEYWORDS):
            continue

        if _matches_any(text, total_keywords):
            amount = _extract_amount(text)
            if amount is not None:
                total = amount
                seen_total = True
            continue

        if _matches_any(text, TAX_KEYWORDS):
            amount = _extract_amount(text)
            if amount is not None:
                tax = amount
            continue

        if seen_total:
            continue  # past the total: payment details, tax table, footer — not more items

        if _matches_any(text, DEPOSIT_KEYWORDS):
            amount = _extract_amount(text)
            if amount is not None:
                line_items.append(Lineitem(name=text, price=amount, is_deposit=True))
            continue

        breakdown = QUANTITY_BREAKDOWN_PATTERN.match(text)
        if breakdown and line_items:
            line_items[-1].quantity = float(breakdown.group(1).replace(",", "."))
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

        unreadable = not name or row_confidence < MYSTERY_LINE_CONFIDENCE
        tags = ["mystery"] if unreadable else tag_store.suggest(name)

        line_items.append(Lineitem(name=name or text, price=amount, quantity=quantity, tags=tags))

    return ReceiptDraft(
        merchant=merchant,
        date=_guess_date(row_texts),
        currency=_guess_currency(row_texts),
        total=total,
        tax=tax,
        line_items=line_items,
        status=ReviewStatus.NEEDS_REVIEW,
        suggested_category="Mystery" if total is None and not line_items else None,
        ocr_confidence=ocr_result.average_confidence,
        raw_text=ocr_result.raw_text,
        source_image_path=source_image_path,
    )
