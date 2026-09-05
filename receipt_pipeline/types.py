'''domain shared across the receipt pipeline'''

from dataclasses import dataclass, field
from enum import Enum
from typing import List, Optional


class ReviewStatus(Enum):
    '''how much a user has actually looked at this receipt log'''
    '''NEEDS_REVIEW: default for fresh parse '''
    '''CONFIRMED: only when user has actually reviewed it and pressed confirmation'''

    CONFIRMED = "confirmed"
    NEEDS_REVIEW = "needs_review"  # for low confidence OCR, ambiguous matching or unreviewed


class SplitMode(Enum):
    '''how a line item counts toward the user's own spend'''

    MINE = "mine"          # fully the user's own expense
    NOT_MINE = "not_mine"  # cancelled off — paid entirely on someone else's behalf, struck out
    SHARED = "shared"      # split across multiple people, see Lineitem.shares


@dataclass
class SplitShare:
    '''one person's portion of a SHARED line item. Set exactly one of amount/percentage.'''

    person: str  # "me" for the user's own portion, otherwise a name
    amount: Optional[float] = None
    percentage: Optional[float] = None


@dataclass
class Lineitem:
    '''a single line parsed off a receipt'''

    name: str
    price: float
    quantity: Optional[float] = 1.0
    translated_text: Optional[str] = None
    original_price: Optional[float] = None
    discount: Optional[float] = None  # special offers etc, price markdowns
    is_deposit: bool = False  # sweden/germany/finland bottle pant/Pfand/pantti deposit refund — its own line, never merged as a discount even when negative
    tags: List[str] = field(default_factory=list)  # per-item categories e.g. ["food", "meats"] — "mystery" tag means this one line is unreadable and unremembered
    split_mode: SplitMode = SplitMode.MINE
    shares: List[SplitShare] = field(default_factory=list)  # only populated when split_mode is SHARED


@dataclass
class ReceiptDraft:
    '''pipeline's output for one receipt, still provisional until reviewed'''
    '''suggested_category is only ever "Mystery" or None — whole receipt unreadable, not a real category'''

    merchant: Optional[str] = None
    date: Optional[str] = None
    currency: Optional[str] = None
    total: Optional[float] = None
    tax: Optional[float] = None  # GST/VAT on the receipt total — receipt-level, not per-item like is_deposit
    line_items: List[Lineitem] = field(default_factory=list)
    status: ReviewStatus = ReviewStatus.NEEDS_REVIEW
    suggested_category: Optional[str] = None
    ocr_confidence: Optional[float] = None
    raw_text: Optional[str] = None
    source_image_path: Optional[str] = None