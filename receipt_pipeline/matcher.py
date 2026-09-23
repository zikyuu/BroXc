'''hungarian algorithm matcher linking parsed receipts to youtrip transactions'''

'''cost = date proximity + how closely the receipt total equals what YouTrip charged in the same currency
+ fuzzy merchant name similarity (deterministic and fully explainable, no ML judgement call)'''

'''a link the matcher isn't sure about (weak cost, or an exchange rate far from the usual one) is still made,
but flagged needs_review so the user can approve or undo it - nothing waits on the user to keep the budget moving'''

from dataclasses import dataclass
from typing import Dict, List, Optional

from rapidfuzz import fuzz
from scipy.optimize import linear_sum_assignment

from .shared.dates import parse_date
from .types import ReceiptDraft, YouTripTransaction

from .shared.db.database import (
    get_reference_rates,
    get_unmatched_receipts,
    get_unmatched_transactions,
    record_match,
)

#tunable weights for cost function
DATE_WEIGHT = 1.0
AMOUNT_WEIGHT = 1.0
NAME_WEIGHT = 1.0

#  pair costing more than this is rejected rather than forced together
MAX_ACCEPTABLE_COST = 3.0
#impt bc linear_sum_assignment will always return a match for every receipt,
# even if the cost is absurdly high. This threshold allows us to filter out those bad matches.
# prevents forcefitting receipts to transactions, when in reality maybe the user is just lazy and hasnt uploaded the corresponding receipt lol

# at or below this a link is trusted; between this and MAX_ACCEPTABLE_COST it is linked but flagged for review
CONFIDENT_COST = 1.0

DATE_COST_SCALE_DAYS = 1  # instant-processing card: even a 1-day gap is unusual; kept at 1 (not 0) only for midnight/timezone quirks
AMOUNT_GAP_SCALE = 20  # a 5% gap between receipt total and YouTrip's charge costs 1.0 (capped at 2.0)
FX_REVIEW_TOLERANCE = 0.10  # flag a link whose exchange rate is more than 10% off that currency's usual rate


@dataclass
class Match:
    receipt_index: int
    transaction_index: int
    cost: float
    needs_review: bool = False
    note: Optional[str] = None


def _date_cost(receipt_date: Optional[str], transaction_date: Optional[str]) -> float:
    """0 = same day, rises fast, capped once clearly outside a same-day-ish match."""
    r_date = parse_date(receipt_date)
    t_date = parse_date(transaction_date)
    if r_date is None or t_date is None:
        return 1.0
    days_apart = abs((t_date - r_date).days)
    return min(days_apart / DATE_COST_SCALE_DAYS, 2.0)


def _gap_cost(a: float, b: Optional[float]) -> float:
    if not b:
        return 1.0
    return min(abs(a - b) / b * AMOUNT_GAP_SCALE, 2.0)


def _amount_cost(receipt: ReceiptDraft, transaction: YouTripTransaction) -> float:
    """0 = the receipt total equals what YouTrip says the merchant charged, in the same currency.
    This is the strongest signal we have: it needs no exchange rate and no readable store name."""
    if not receipt.total:
        return 1.0  # nothing to compare - neutral, not a penalty
    currency = (receipt.currency or "").upper()

    if transaction.local_amount and transaction.local_currency:
        if currency and currency != transaction.local_currency.upper():
            return 2.0  # both currencies known and they differ
        return _gap_cost(receipt.total, transaction.local_amount)

    if currency == "SGD" and transaction.amount_sgd:
        return _gap_cost(receipt.total, transaction.amount_sgd)

    return 1.0


def _name_cost(receipt: ReceiptDraft, description: Optional[str]) -> float:
    """Best of the translated and original-language merchant names - the translated one can
    differ from the Swedish name YouTrip shows, so either matching well is enough."""
    if not description:
        return 1.0
    names = [n for n in (receipt.merchant, receipt.merchant_original) if n]
    if not names:
        return 1.0
    best = max(fuzz.partial_ratio(n.lower(), description.lower()) for n in names)  # 0-100
    return 1.0 - (best / 100)


def _fx_note(transaction: YouTripTransaction, reference_rates: Dict[str, float]) -> Optional[str]:
    """A warning when the exchange rate on this transaction is far from the usual one for its
    currency - e.g. 50 EUR that cost 88 SGD when it normally costs about 75. Needs history."""
    currency = (transaction.local_currency or "").upper()
    reference = reference_rates.get(currency)
    if not (reference and transaction.local_amount and transaction.amount_sgd):
        return None
    rate = transaction.local_amount / transaction.amount_sgd
    deviation = abs(rate - reference) / reference
    if deviation > FX_REVIEW_TOLERANCE:
        return f"exchange rate {rate:.2f} {currency}/SGD is {deviation:.0%} off the usual {reference:.2f}"
    return None


def match_receipts_to_transactions(
    receipts: List[ReceiptDraft],
    transactions: List[YouTripTransaction],
    reference_rates: Optional[Dict[str, float]] = None,
) -> List[Match]:
    """Returns only the accepted matches - pairs costing too much are left out entirely
    rather than forcing every receipt onto some transaction regardless of fit. Accepted
    matches the matcher isn't fully sure of come back with needs_review set and a note."""
    if not receipts or not transactions:
        return []
    reference_rates = reference_rates or {}

    cost_matrix = [
        [
            DATE_WEIGHT * _date_cost(receipt.date, transaction.date)
            + AMOUNT_WEIGHT * _amount_cost(receipt, transaction)
            + NAME_WEIGHT * _name_cost(receipt, transaction.description)
            for transaction in transactions
        ]
        for receipt in receipts
    ]

    receipt_indices, transaction_indices = linear_sum_assignment(cost_matrix)

    matches = []
    for r_idx, t_idx in zip(receipt_indices, transaction_indices):
        cost = cost_matrix[r_idx][t_idx]
        if cost > MAX_ACCEPTABLE_COST:
            continue

        notes = []
        fx_note = _fx_note(transactions[t_idx], reference_rates)
        if fx_note:
            notes.append(fx_note)
        if cost > CONFIDENT_COST:
            notes.append(f"weak match (cost {cost:.1f})")

        matches.append(Match(
            receipt_index=int(r_idx),
            transaction_index=int(t_idx),
            cost=cost,
            needs_review=bool(notes),
            note="; ".join(notes) or None,
        ))

    return matches


def run_matching(conn) -> List[Match]:
    """Full cycle: pull whatever's currently unmatched from the DB, run the algorithm,
    write accepted matches back. Safe to call repeatedly - already-matched rows are
    excluded by the get_unmatched_* queries, so re-running never reconsiders a link
    that's already been made.
    """
    unmatched_receipts = get_unmatched_receipts(conn)
    unmatched_transactions = get_unmatched_transactions(conn)

    receipt_ids = [r_id for r_id, _ in unmatched_receipts]
    receipts = [draft for _, draft in unmatched_receipts]
    transaction_ids = [t_id for t_id, _ in unmatched_transactions]
    transactions = [txn for _, txn in unmatched_transactions]

    matches = match_receipts_to_transactions(receipts, transactions, get_reference_rates(conn))

    for match in matches:
        record_match(
            conn,
            transaction_id=transaction_ids[match.transaction_index],
            receipt_id=receipt_ids[match.receipt_index],
            match_status="needs_review" if match.needs_review else "auto",
            match_note=match.note,
        )

    return matches
