"""YouTrip transaction-list screenshot parser.

Real screenshots lay out each transaction across three stacked lines, not one
flat row: a date header (once per day, shared by every transaction below it
until the next date), then per-transaction a merchant-name-plus-local-currency
line, a converted SGD-amount line right below it, and a "SmartExchange"
caption line below that. This walks rows top-to-bottom as a small state
machine: accumulate description text until an SGD-amount line appears (that
closes out one transaction), track the running date separately since it
applies to many transactions at once, and skip the SmartExchange caption by
keyword.
"""

import re
from typing import List, Optional

from ..shared.ocr.engine import group_into_rows, run_ocr
from ..types import YouTripTransaction

SGD_AMOUNT_PATTERN = re.compile(r"-?\d+[.,]\d{2}\s*SGD\b", re.IGNORECASE)
AMOUNT_PATTERN = re.compile(r"-?\d+[.,]\d{2}")
MONTH_NAMES = r"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)"
DATE_PATTERN = re.compile(rf"\b\d{{1,2}}\s+{MONTH_NAMES}\w*(?:\s+\d{{2,4}})?\b", re.IGNORECASE)
SKIP_KEYWORDS = ["smartexchange"]

_DIGIT_LOOKALIKES = str.maketrans({
    "i": "1", "I": "1", "l": "1", "L": "1",
    "o": "0", "O": "0",
    "s": "5", "S": "5",
    "b": "8", "B": "8",
})

LOCAL_AMOUNT_PATTERN = re.compile(r"kr([A-Za-z0-9]+\.\d{2})\s*SEK", re.IGNORECASE)


def _fix_local_amount(text: str) -> str:
    """OCR sometimes reads a digit as a visually similar letter (1<->i/l, 0<->o) inside a
    currency amount. A 'kr<...>.NN SEK' substring can only ever be a number, so it's safe to
    translate those specific letters back to digits within that substring only — nowhere else
    in the row gets touched, so a real merchant name can't get mangled by this."""
    def _repair(match):
        return f"kr{match.group(1).translate(_DIGIT_LOOKALIKES)} SEK"

    return LOCAL_AMOUNT_PATTERN.sub(_repair, text)


def _extract_sgd_amount(text: str) -> Optional[float]:
    match = SGD_AMOUNT_PATTERN.search(text)
    if not match:
        return None
    number = AMOUNT_PATTERN.search(match.group(0))
    return float(number.group(0).replace(",", ".")) if number else None


def parse_youtrip_screenshot(
    image_path: str, languages: Optional[List[str]] = None
) -> List[YouTripTransaction]:
    """Runs OCR on a YouTrip transaction-list screenshot, returns one entry per transaction."""
    ocr_result = run_ocr(image_path, languages or ["en"])
    row_texts = [text for text, _ in group_into_rows(ocr_result.lines)]

    transactions: List[YouTripTransaction] = []
    current_date: Optional[str] = None
    pending_description_parts: List[str] = []

    for row_text in row_texts:
        row_text = _fix_local_amount(row_text)
        date_match = DATE_PATTERN.search(row_text)
        sgd_amount = _extract_sgd_amount(row_text)

        if date_match and sgd_amount is None:
            current_date = date_match.group(0)
            continue

        if sgd_amount is not None:
            leftover = SGD_AMOUNT_PATTERN.sub("", row_text)
            for keyword in SKIP_KEYWORDS:
                leftover = re.sub(keyword, "", leftover, flags=re.IGNORECASE)
            leftover = re.sub(r"\s+", " ", leftover).strip(" -,$\t")
            if leftover:
                pending_description_parts.append(leftover)

            description = " ".join(pending_description_parts).strip(" -,\t") or None
            transactions.append(YouTripTransaction(
                date=current_date,
                description=description,
                amount_sgd=sgd_amount,
            ))
            pending_description_parts = []
            continue

        if any(keyword in row_text.lower() for keyword in SKIP_KEYWORDS):
            continue

        pending_description_parts.append(row_text.strip())

    return transactions