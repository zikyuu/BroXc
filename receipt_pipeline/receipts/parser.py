"""Rule-based field / line-item extraction from OCR output."""

import re
from typing import List, Optional, Tuple

from .merchant_profiles import MerchantProfileStore
from ..shared.ocr.engine import OcrResult, group_into_rows
from .tag_store import TagStore
from ..shared.ocr.translator import translate
from ..types import Lineitem, ReceiptDraft, ReviewStatus

# generic multilingual keyword defaults — merchant profile corrections extend these per-merchant
TOTAL_KEYWORDS = ["total", "totalt", "att betala", "summe", "gesamt", "yhteensä", "summa"]
TAX_KEYWORDS = ["gst", "vat", "moms", "mwst", "tax"]
DEPOSIT_KEYWORDS = ["pant", "pfand", "pantti"]
DISCOUNT_KEYWORDS = ["rabatt", "discount", "off"]
# a recap line restating a figure already captured elsewhere (e.g. a discount subtotal),
# not a real item or a real total
SKIP_KEYWORDS = ["summering"]

AMOUNT_PATTERN = re.compile(r"-?\d+[.,]\d{2}\b")
QUANTITY_PATTERN = re.compile(r"\b(\d+)\s*[x×]\s*", re.IGNORECASE)
# a quantity/weight breakdown printed on its OWN line under an item rather than beside it —
# e.g. "2 st x 20,95" or "0,298 kg x 103,16 SEK/kg"
QUANTITY_BREAKDOWN_PATTERN = re.compile(
    r"^\s*([\d.,]+)\s*(?:st|kg|g|ml|l)\s*x\s*[\d.,]+", re.IGNORECASE
)
CURRENCY_PATTERN = re.compile(r"\b(SEK|EUR|NOK|DKK|GBP|USD|SGD|KR|€|£|\$)\b", re.IGNORECASE)
DATE_PATTERN = re.compile(r"\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}[./]\d{1,2}[./]\d{2,4}\b")

# below this per-ROW confidence, tag the item "mystery" instead of trusting the extracted name.
# distinct from ocr_engine's LOW_CONFIDENCE_THRESHOLD, which judges the whole receipt image
# to decide on a page-dewarp retry — this one judges a single already-final OCR row.
MYSTERY_LINE_CONFIDENCE = 0.4

# MVP scope matches translator.py: Swedish only, matching the current trip itinerary
DEFAULT_SOURCE_LANG = "sv"


def _extract_amount(text: str) -> Optional[float]:
    matches = AMOUNT_PATTERN.findall(text)
    if not matches:
        return None
    return float(matches[-1].replace(",", "."))


def _strip_amount(text: str) -> str:
    return AMOUNT_PATTERN.sub("", text).strip(" -\t")


def _extract_quantity(text: str) -> Tuple[float, str]:
    """Pulls a '2 x' / '3x' style multiplier on the SAME line as the item, returns (quantity, text with it removed)."""
    match = QUANTITY_PATTERN.search(text)
    if not match:
        return 1.0, text
    return float(match.group(1)), QUANTITY_PATTERN.sub("", text, count=1)


def _matches_any(text: str, keywords: List[str]) -> bool:
    lowered = text.lower()
    return any(kw in lowered for kw in keywords)


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


def _translate_item_name(name: str, profile_translations: dict, source_lang: str) -> Optional[str]:
    cached = profile_translations.get(name)
    if cached:
        return cached
    try:
        return translate(name, source_lang=source_lang)
    except Exception:
        return None


def parse_receipt(
    ocr_result: OcrResult,
    profile_store: MerchantProfileStore,
    tag_store: TagStore,
    source_image_path: Optional[str] = None,
    source_lang: str = DEFAULT_SOURCE_LANG,
) -> ReceiptDraft:
    """Turns raw OCR lines into a ReceiptDraft — every field here is a suggestion, never confirmed."""
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
            # past the total line, everything left is payment/footer/tax-table noise on a
            # real receipt — stop treating numbers here as more purchasable items
            continue

        if _matches_any(text, DEPOSIT_KEYWORDS):
            amount = _extract_amount(text)
            if amount is not None:
                line_items.append(Lineitem(name=text, price=amount, is_deposit=True))
            continue

        breakdown_match = QUANTITY_BREAKDOWN_PATTERN.match(text)
        if breakdown_match and line_items:
            line_items[-1].quantity = float(breakdown_match.group(1).replace(",", "."))
            continue

        amount = _extract_amount(text)
        if amount is None:
            continue  # no price and no keyword match — not an item

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

        translated = None
        if not unreadable:
            translated = _translate_item_name(name, profile.item_translations, source_lang)

        tags = ["mystery"] if unreadable else tag_store.suggest(translated or name)

        line_items.append(Lineitem(
            name=name or text,
            price=amount,
            quantity=quantity,
            translated_text=translated,
            tags=tags,
        ))

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