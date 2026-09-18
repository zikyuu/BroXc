'''hungarian algorithm matcher linking parsed receipts to youtrip transactions'''

'''cost = date proximity + implied Fx rate deviation from the batch's own median'''
'''fuzzy merchant name similarity (deterministic and fully explainable, no ML judgement call)'''

from dataclasses import dataclass
from typing import List, Optional 

from dateutil import parser as date_parser
from rapidfuzz import fuzz
from scipy.optimize import linear_sum_assignment 

from .types import ReceiptDraft, YouTripTransaction

from .shared.db.database import get_unmatched_receipts, get_unmatched_transactions, record_match

#tunable weights for cost function 
DATE_WEIGHT = 1.0
FX_WEIGHT = 1.0
NAME_WEIGHT = 1.0

#  pair costing more than this is rejected rather than forced together
MAX_ACCEPTABLE_COST = 3.0
#impt bc linear_sum_assignment will always return a match for every receipt, 
# even if the cost is absurdly high. This threshold allows us to filter out those bad matches.
# prevents forcefitting receipts to transactions, when in reality maybe the user is just lazy and hasnt uploaded the corresponding receipt lol

DATE_COST_SCALE_DAYS = 1  # instant-processing card: even a 1-day gap is unusual; kept at 1 (not 0) only for midnight/timezone quirks


@dataclass
class Match:
    receipt_index: int
    transaction_index: int
    cost: float


def _parse_date(date_str: Optional[str]):
    if not date_str:
        return None
    try:
        return date_parser.parse(date_str, fuzzy=True).date()
    except (ValueError, OverflowError):
        return None


def _date_cost(receipt_date: Optional[str], transaction_date: Optional[str]) -> float:
    """0 = same day, rises fast, capped once clearly outside a same-day-ish match."""
    r_date = _parse_date(receipt_date)
    t_date = _parse_date(transaction_date)
    if r_date is None or t_date is None:
        return 1.0
    days_apart = abs((t_date - r_date).days)
    return min(days_apart / DATE_COST_SCALE_DAYS, 2.0)


def _implied_rate(receipt: ReceiptDraft, transaction: YouTripTransaction) -> Optional[float]:
    if not receipt.total or not transaction.amount_sgd:
        return None
    return receipt.total / transaction.amount_sgd


def _name_cost(receipt: ReceiptDraft, description: Optional[str]) -> float:
    """Best of the translated and original-language merchant names — the translated one can
    differ from the Swedish name YouTrip shows, so either matching well is enough."""
    if not description:
        return 1.0
    names = [n for n in (receipt.merchant, receipt.merchant_original) if n]
    if not names:
        return 1.0
    best = max(fuzz.partial_ratio(n.lower(), description.lower()) for n in names)  # 0-100
    return 1.0 - (best / 100)


def match_receipts_to_transactions(
    receipts: List[ReceiptDraft], transactions: List[YouTripTransaction]
) -> List[Match]:
    """Returns only the accepted matches — pairs costing too much are left out entirely
    rather than forcing every receipt onto some transaction regardless of fit."""
    if not receipts or not transactions:
        return []

    implied_rates = [
        rate
        for r in receipts
        for t in transactions
        if (rate := _implied_rate(r, t)) is not None
    ]
    median_rate = sorted(implied_rates)[len(implied_rates) // 2] if implied_rates else None

    cost_matrix = []
    for receipt in receipts:
        row = []
        for transaction in transactions:
            date_cost = _date_cost(receipt.date, transaction.date)
            name_cost = _name_cost(receipt, transaction.description)

            rate = _implied_rate(receipt, transaction)
            fx_cost = 1.0 if rate is None or median_rate is None else abs(rate - median_rate) / median_rate

            row.append(DATE_WEIGHT * date_cost + FX_WEIGHT * fx_cost + NAME_WEIGHT * name_cost)
        cost_matrix.append(row)

    receipt_indices, transaction_indices = linear_sum_assignment(cost_matrix)

    matches = []
    for r_idx, t_idx in zip(receipt_indices, transaction_indices):
        cost = cost_matrix[r_idx][t_idx]
        if cost <= MAX_ACCEPTABLE_COST:
            matches.append(Match(receipt_index=r_idx, transaction_index=t_idx, cost=cost))

    return matches


def run_matching(conn) -> List[Match]:
    """Full cycle: pull whatever's currently unmatched from the DB, run the algorithm,
    write accepted matches back. Safe to call repeatedly — already-matched rows are
    excluded by the get_unmatched_* queries, so re-running never reconsiders a link
    that's already been made.
    """
    unmatched_receipts = get_unmatched_receipts(conn)
    unmatched_transactions = get_unmatched_transactions(conn)

    receipt_ids = [r_id for r_id, _ in unmatched_receipts]
    receipts = [draft for _, draft in unmatched_receipts]
    transaction_ids = [t_id for t_id, _ in unmatched_transactions]
    transactions = [txn for _, txn in unmatched_transactions]

    matches = match_receipts_to_transactions(receipts, transactions)

    for match in matches:
        record_match(
            conn,
            transaction_id=transaction_ids[match.transaction_index],
            receipt_id=receipt_ids[match.receipt_index],
        )

    return matches
