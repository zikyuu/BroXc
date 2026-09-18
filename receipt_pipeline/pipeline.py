'''orchestrates the live receipt flow: OCR a translated receipt screenshot -> parse it, and optionally
read the store name off the original-language upload, plus a CLI demo'''

'''the photographed-receipt path (dewarp -> OCR -> OPUS-MT translate -> receipts/parser.py) is
deliberately unlinked from here and left as dead code until the rest of the project settles'''

'''note for me to test: python -m receipt_pipeline.pipeline translated_receipt.png [original_receipt.jpg]'''

import sys
from typing import List, Optional

from .receipts.merchant_profiles import MerchantProfileStore
from .receipts.tag_store import TagStore
from .receipts.translated_parser import parse_translated_receipt, read_original_merchant
from .shared.ocr.engine import run_ocr
from .types import ReceiptDraft

DEFAULT_ORIGINAL_LANGUAGES = ["sv", "en"]


def run_receipt_pipeline(
        translated_image_path: str,
        original_image_path: Optional[str] = None,
        original_languages: Optional[List[str]] = None,
        profile_store: Optional[MerchantProfileStore] = None,
        tag_store: Optional[TagStore] = None,
) -> ReceiptDraft:
    """Parses a translated receipt screenshot; if the original-language image is also given,
    reads its store name too so the matcher can compare against YouTrip's Swedish description."""
    profile_store = profile_store or MerchantProfileStore()
    tag_store = tag_store or TagStore()

    translated_ocr = run_ocr(translated_image_path, ["en"])
    draft = parse_translated_receipt(
        translated_ocr, profile_store, tag_store, source_image_path=translated_image_path
    )

    if original_image_path:
        original_ocr = run_ocr(original_image_path, original_languages or DEFAULT_ORIGINAL_LANGUAGES)
        draft.merchant_original = read_original_merchant(original_ocr)

    return draft

#diff between x or y vs if x is not None else y
# first one evaluates y if x is falsy (None, 0, 0.0, empty string etc)
# second one evalutes y if it is None, so it allows 0, 0.0 etc
def _print_draft(draft: ReceiptDraft) -> None:
    print(f"Merchant:    {draft.merchant or '(unknown)'}")
    print(f"Merchant (original): {draft.merchant_original or '(not provided)'}")
    print(f"Date:        {draft.date or '(unknown)'}")
    print(f"Currency:    {draft.currency or '(unknown)'}")
    print(f"Total:       {draft.total if draft.total is not None else '(unknown)'}")
    print(f"Tax:         {draft.tax if draft.tax is not None else '(none detected)'}")
    print(f"Status:      {draft.status.value}")
    print(f"Category:    {draft.suggested_category or '(n/a)'}")
    conf = f"{draft.ocr_confidence:.2f}" if draft.ocr_confidence is not None else "(n/a)"
    print(f"OCR conf:    {conf}")
    print()
    print(f"Line items ({len(draft.line_items)}):")
    if not draft.line_items:
        print("  (none parsed)")
    for item in draft.line_items:
        flags = []
        if item.is_deposit:
            flags.append("deposit")
        if "mystery" in item.tags:
            flags.append("MYSTERY")
        flag_str = f" [{', '.join(flags)}]" if flags else ""
        tags = f" tags={item.tags}" if item.tags else ""
        print(f"  - {item.name} x{item.quantity} @ {item.price}{flag_str}{tags}")

#what ies sys.argv?
# list fo everything typed on that command line split by spaces after python script is ran
def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: python -m receipt_pipeline.pipeline translated_receipt.png [original_receipt.jpg]")
        sys.exit(1)

    translated_path = sys.argv[1] #translated_receipt.png
    original_path = sys.argv[2] if len(sys.argv) > 2 else None #receipt.jpg (optional)

    draft = run_receipt_pipeline(translated_path, original_path)
    _print_draft(draft)


if __name__ == "__main__":
    main()
