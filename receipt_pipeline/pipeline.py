'''orchestrates dewarp -> OCR -> trasnlate -> parse into 1 call, plus a CLI demo'''

'''note for me to test: python -m receipt_pipeline.pipline path/to/receipt.jpg sv.en'''

import sys
from typing import List, Optional 

from .receipts.merchant_profiles import MerchantProfileStore
from .shared.ocr.engine import run_ocr
from .receipts.parser import parse_receipt
from .receipts.tag_store import TagStore
from .types import ReceiptDraft

def run_pipeline(
        image_path: str,
        languages: List[str],
        profile_store: Optional[MerchantProfileStore] = None,
        tag_store: Optional[TagStore] = None,
) -> ReceiptDraft:
    """Runs the full pipeline: dewarp -> OCR (confidence gated) -> translate -> parse into ReceiptDraft."""
    profile_store = profile_store or MerchantProfileStore()
    tag_store = tag_store or TagStore()
    ocr_result = run_ocr(image_path, languages)
    return parse_receipt(ocr_result, profile_store, tag_store, source_image_path=image_path)

#diff between x or y vs if x is not None else y
# first one evaluates y if x is falsy (None, 0, 0.0, empty string etc)
# second one evalutes y if it is None, so it allows 0, 0.0 etc
def _print_draft(draft: ReceiptDraft) -> None:
    print(f"Merchant:    {draft.merchant or '(unknown)'}")
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
        translated = f" ({item.translated_text})" if item.translated_text else ""
        tags = f" tags={item.tags}" if item.tags else ""
        print(f"  - {item.name}{translated} x{item.quantity} @ {item.price}{flag_str}{tags}")

#what ies sys.argv?
# list fo everything typed on that command line split by spaces after python script is ran
def main() -> None:
    if len(sys.argv) < 3:
        print("Usage: python -m receipt_pipeline.pipeline path/to/receipt.jpg sv,en")
        sys.exit(1)

    image_path = sys.argv[1] #receipt.jpg
    languages = sys.argv[2].split(",") #sv, en

    draft = run_pipeline(image_path, languages)
    _print_draft(draft)


if __name__ == "__main__":
    main()