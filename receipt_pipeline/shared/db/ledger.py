"""UI-facing reads and writes over the expenses database: SGD-converted item listings,
spend-by-tag insights, bulk tag edits, match review actions, trips, and the paid-for-others
reimbursement ledger.

Spend is tracked in SGD, the currency that actually left the card. A receipt's items are
converted at the rate its own matched YouTrip charge implies (exact), else at the usual rate
for that currency (an estimate, flagged as one), else left unconverted in the original currency.

"Personal spend" is only the user's own portion: an item paid entirely for someone else (NOT_MINE)
or split with others (SHARED) contributes just its personal part to spending totals, and the rest
is tracked as paid-for-others until a reimbursement transaction brings the balance back to zero.
"""

import sqlite3
from collections import Counter, defaultdict
from typing import Dict, List, Optional, Tuple

from ..dates import parse_date
from ...types import ReviewStatus, SplitMode, TransactionType, YouTripTransaction
from .database import (
    get_or_create_tag_id, get_reference_rates, last_balance_checkpoint, record_balance_checkpoint,
    record_match, save_youtrip_transaction,
)

UNSORTED = "Unsorted"  # the bucket shown for items with no tags yet - a real item whose category isn't resolved, not a real tag
BALANCE_TOLERANCE = 0.005  # SGD - anything smaller than a cent is rounding noise, not a debt
# shortest individual word from a known merchant's name allowed to trigger a category guess.
# Fuzzy character-alignment scoring (rapidfuzz's partial_ratio) was tried first and produced
# real false positives against real data - "SL" scored 66.7 against "SYSTEMBOLAGET UPPSALA"
# purely by coincidence, and even a full name like "Large coop" scored 60 against it too, both
# well above any threshold that still caught genuine matches. A literal substring check on
# individual words doesn't have that failure mode.
MIN_HINT_WORD_LENGTH = 4


def _receipt_rates(conn: sqlite3.Connection) -> Dict[int, Tuple[Optional[float], Optional[str]]]:
    """receipt id -> (local units per SGD, source) where source is native | matched | estimated."""
    reference = get_reference_rates(conn, min_samples=1)
    rows = conn.execute(
        """
        SELECT r.id, r.currency, r.total, t.amount_sgd
        FROM receipts r LEFT JOIN youtrip_transactions t ON t.matched_receipt_id = r.id
        """
    ).fetchall()

    rates: Dict[int, Tuple[Optional[float], Optional[str]]] = {}
    for receipt_id, currency, total, amount_sgd in rows:
        code = (currency or "").upper()
        if code == "SGD":
            rates[receipt_id] = (1.0, "native")
        elif amount_sgd and total:
            rates[receipt_id] = (total / amount_sgd, "matched")  # what actually left the card
        elif code in reference:
            rates[receipt_id] = (reference[code], "estimated")
        else:
            rates[receipt_id] = (None, None)
    return rates


def _merchant_category_hints(conn: sqlite3.Connection) -> Dict[str, str]:
    """merchant name -> its single most common tag, learned from that merchant's own past
    receipts. Powers a best-effort category guess for a charge with no receipt at all. Indexes
    by both the translated and original-language merchant name (same reasoning as the matcher's
    own name comparison), since YouTrip's description is in the original language and a
    translated name alone can score poorly against it even for a genuine match."""
    rows = conn.execute(
        """
        SELECT r.merchant, r.merchant_original, t.name, COUNT(*) as n
        FROM receipts r
        JOIN line_items li ON li.receipt_id = r.id
        JOIN item_tags it ON it.item_id = li.id
        JOIN tags t ON t.id = it.tag_id
        WHERE r.merchant IS NOT NULL OR r.merchant_original IS NOT NULL
        GROUP BY r.merchant, r.merchant_original, t.name
        ORDER BY r.merchant, n DESC
        """
    ).fetchall()
    hints: Dict[str, str] = {}
    for merchant, merchant_original, tag, _ in rows:
        for name in (merchant, merchant_original):
            if name:
                hints.setdefault(name, tag)  # first row per name is its highest-count tag, since ORDER BY put n DESC within each merchant
    return hints


def _infer_category(description: Optional[str], merchant_hints: Dict[str, str]) -> Optional[str]:
    """Best-effort tag guess for a transaction with no receipt: does any individual word from a
    merchant we've already learned tags for appear literally inside this description? A literal
    substring check, not a fuzzy score — prefers the longest matching word when several merchants'
    names share a short one, and returns None (an honest "don't know") rather than force a guess."""
    if not description or not merchant_hints:
        return None
    text = description.lower()
    best_tag, best_word_len = None, 0
    for merchant, tag in merchant_hints.items():
        for word in merchant.lower().split():
            if len(word) >= MIN_HINT_WORD_LENGTH and word in text and len(word) > best_word_len:
                best_tag, best_word_len = tag, len(word)
    return best_tag


def _split_price(price: float, split_mode: str, shares: List[Tuple[str, Optional[float], Optional[float]]]):
    """(personal, others, unresolved) for one item, in the receipt's own currency. A SHARED item
    with no 'me' share recorded can't be split honestly, so it counts fully as personal (never
    silently understating spend) and is flagged unresolved for the UI to ask about."""
    if split_mode == SplitMode.NOT_MINE.value:
        return 0.0, price, False
    if split_mode == SplitMode.SHARED.value:
        mine = next(((amount, pct) for person, amount, pct in shares if person.lower() == "me"), None)
        if mine is None:
            return price, 0.0, True
        amount, pct = mine
        personal = amount if amount is not None else price * (pct or 0) / 100
        return personal, price - personal, False
    return price, 0.0, False


def _all_items(conn: sqlite3.Connection) -> List[dict]:
    rates = _receipt_rates(conn)

    tags_by_item: Dict[int, List[str]] = defaultdict(list)
    for item_id, name in conn.execute(
        "SELECT it.item_id, t.name FROM item_tags it JOIN tags t ON t.id = it.tag_id ORDER BY t.name"
    ):
        tags_by_item[item_id].append(name)

    shares_by_item: Dict[int, List[Tuple[str, Optional[float], Optional[float]]]] = defaultdict(list)
    for item_id, person, amount, percentage in conn.execute(
        "SELECT item_id, person, amount, percentage FROM line_item_shares"
    ):
        shares_by_item[item_id].append((person, amount, percentage))

    trip_names = {trip_id: name for trip_id, name in conn.execute("SELECT id, name FROM trips")}

    rows = conn.execute(
        """
        SELECT li.id, li.name, li.price, li.quantity, li.is_deposit, li.split_mode,
               r.id, r.merchant, r.date, r.currency, r.trip_id
        FROM line_items li JOIN receipts r ON r.id = li.receipt_id
        ORDER BY r.date DESC, li.id
        """
    ).fetchall()

    items = []
    for item_id, name, price, quantity, is_deposit, split_mode, receipt_id, merchant, raw_date, currency, trip_id in rows:
        parsed = parse_date(raw_date)
        rate, source = rates.get(receipt_id, (None, None))
        personal, others, unresolved = _split_price(price, split_mode, shares_by_item.get(item_id, []))
        items.append({
            "id": item_id,
            "name": name,
            "quantity": quantity,
            "is_deposit": bool(is_deposit),
            "price": price,
            "currency": currency,
            "price_sgd": round(price / rate, 2) if rate else None,
            "split_mode": split_mode,
            "split_unresolved": unresolved,
            "personal_price": personal,
            "personal_sgd": round(personal / rate, 2) if rate else None,
            "others_sgd": round(others / rate, 2) if rate else None,
            "sgd_source": source,
            "tags": tags_by_item.get(item_id, []),
            "tag_confidence": "confirmed",
            "trip": {"id": trip_id, "name": trip_names.get(trip_id)} if trip_id else None,
            "receipt": {
                "id": receipt_id,
                "merchant": merchant,
                "date": parsed.isoformat() if parsed else None,
            },
        })

    # expense transactions with no receipt at all get no line_items row to read from — without
    # this, that money is invisible in every spending total even though it genuinely left the card.
    # Reimbursements/income/transfers are deliberately not here: they aren't purchases.
    merchant_hints = _merchant_category_hints(conn)
    unmatched = conn.execute(
        """
        SELECT id, date, description, amount_sgd, trip_id FROM youtrip_transactions
        WHERE matched_receipt_id IS NULL AND transaction_type = 'expense'
        """
    ).fetchall()
    for t_id, raw_date, description, amount_sgd, trip_id in unmatched:
        parsed = parse_date(raw_date)
        inferred = _infer_category(description, merchant_hints)
        items.append({
            "id": -t_id,  # negative space marks a transaction with no backing receipt yet, distinct from real line_items ids
            "name": description or "Unknown charge",
            "quantity": 1,
            "is_deposit": False,
            "price": amount_sgd,
            "currency": "SGD",
            "price_sgd": amount_sgd,  # already SGD - this is what YouTrip actually charged, no conversion needed
            "split_mode": SplitMode.MINE.value,
            "split_unresolved": False,
            "personal_price": amount_sgd,
            "personal_sgd": amount_sgd,
            "others_sgd": 0.0,
            "sgd_source": "native",
            "tags": [inferred] if inferred else [],
            "tag_confidence": "inferred" if inferred else "unknown",
            "trip": {"id": trip_id, "name": trip_names.get(trip_id)} if trip_id else None,
            "receipt": {
                "id": None,
                "merchant": "No receipt yet",
                "date": parsed.isoformat() if parsed else None,
            },
        })

    return items


def list_items(
    conn: sqlite3.Connection, start: Optional[str] = None, end: Optional[str] = None,
    trip_id: Optional[int] = None,
) -> List[dict]:
    """Items in an optional ISO date range and/or trip. Items on undated receipts can't be placed
    in a range, so they only appear when no range is set (summary() reports how many were left out)."""
    items = _all_items(conn)
    if trip_id is not None:
        items = [i for i in items if i["trip"] and i["trip"]["id"] == trip_id]
    if not (start or end):
        return items
    kept = []
    for item in items:
        day = item["receipt"]["date"]
        if not day or (start and day < start) or (end and day > end):
            continue
        kept.append(item)
    return kept


def summary(
    conn: sqlite3.Connection, start: Optional[str] = None, end: Optional[str] = None,
    trip_id: Optional[int] = None,
) -> dict:
    """Personal spend in SGD, split by tag. Items can carry several tags, so per-tag totals overlap
    and won't add up to total_sgd - each item is counted once in the total. Deposits are excluded,
    and only each item's personal share counts (paid_for_others_sgd reports the rest)."""
    everything = _all_items(conn)
    undated_excluded = sum(1 for i in everything if not i["receipt"]["date"]) if (start or end) else 0

    total_sgd = estimated_sgd = paid_for_others_sgd = 0.0
    unconverted: Dict[str, float] = defaultdict(float)
    by_tag: Dict[str, dict] = defaultdict(lambda: {"count": 0, "sgd": 0.0, "estimated_sgd": 0.0})
    counted = [i for i in list_items(conn, start, end, trip_id) if not i["is_deposit"]]

    for item in counted:
        sgd = item["personal_sgd"]
        estimated = item["sgd_source"] == "estimated"
        paid_for_others_sgd += item["others_sgd"] or 0.0
        if sgd is None:
            unconverted[item["currency"] or "?"] += item["personal_price"]
        else:
            total_sgd += sgd
            if estimated:
                estimated_sgd += sgd

        if item["split_mode"] == SplitMode.NOT_MINE.value:
            continue  # struck out of personal spend entirely - it would only add a zero to a category
        for tag in item["tags"] or [UNSORTED]:
            bucket = by_tag[tag]
            bucket["count"] += 1
            if sgd is not None:
                bucket["sgd"] += sgd
                if estimated:
                    bucket["estimated_sgd"] += sgd

    return {
        "item_count": len(counted),
        "total_sgd": round(total_sgd, 2),
        "estimated_sgd": round(estimated_sgd, 2),
        "paid_for_others_sgd": round(paid_for_others_sgd, 2),
        "unconverted": {cur: round(amount, 2) for cur, amount in unconverted.items()},
        "undated_excluded": undated_excluded,
        "by_tag": sorted(
            (
                {"tag": tag, "count": b["count"], "sgd": round(b["sgd"], 2), "estimated_sgd": round(b["estimated_sgd"], 2)}
                for tag, b in by_tag.items()
            ),
            key=lambda row: row["sgd"],
            reverse=True,
        ),
    }


def list_tags(conn: sqlite3.Connection) -> List[dict]:
    rows = conn.execute(
        """
        SELECT t.name, COUNT(it.item_id) FROM tags t
        LEFT JOIN item_tags it ON it.tag_id = t.id GROUP BY t.id ORDER BY COUNT(it.item_id) DESC, t.name
        """
    ).fetchall()
    return [{"name": name, "count": count} for name, count in rows]


def _clean_tags(tags: List[str]) -> List[str]:
    """Lower-cased and trimmed so 'Meat' and 'meat ' can't become two tags."""
    cleaned = []
    for tag in tags:
        tag = tag.strip().lower()
        if tag and tag != UNSORTED.lower() and tag not in cleaned:
            cleaned.append(tag)
    return cleaned


def _resolve_transaction_as_manual_receipt(conn: sqlite3.Connection, transaction_id: int) -> int:
    """Turns a receipt-less transaction into a matched one backed by a minimal, hand-entered
    receipt, the moment a user tags it directly from the Spending tab. Reuses the same idea as
    a personal-transfer breakdown (a transaction can be enriched by a manually-typed receipt,
    not just an OCR'd one) - just triggered by tagging instead of an explicit "add details" step.
    Returns the id of the one line item created, so the caller can tag that."""
    row = conn.execute(
        "SELECT date, description, amount_sgd, local_amount, local_currency, trip_id FROM youtrip_transactions WHERE id = ?",
        (transaction_id,),
    ).fetchone()
    if not row:
        raise ValueError(f"no transaction with id {transaction_id}")
    date, description, amount_sgd, local_amount, local_currency, trip_id = row

    cursor = conn.execute(
        "INSERT INTO receipts (merchant, date, currency, total, status, trip_id) VALUES (?, ?, ?, ?, ?, ?)",
        (description, date, local_currency or "SGD", local_amount or amount_sgd, ReviewStatus.CONFIRMED.value, trip_id),
    )
    receipt_id = cursor.lastrowid
    item_cursor = conn.execute(
        "INSERT INTO line_items (receipt_id, name, price, quantity, is_deposit, split_mode) VALUES (?, ?, ?, 1, 0, 'mine')",
        (receipt_id, description or "Unknown charge", local_amount or amount_sgd),
    )
    record_match(conn, transaction_id, receipt_id, match_status="approved", match_note="resolved by tagging from Spending")
    return item_cursor.lastrowid


def apply_tag_changes(
    conn: sqlite3.Connection, item_ids: List[int], add: List[str], remove: List[str]
) -> List[Tuple[str, List[str]]]:
    """Adds/removes tags on the given items. Returns (item name, its new tags) for each item touched,
    so the caller can teach the tag store what the user just decided."""
    add, remove = _clean_tags(add), _clean_tags(remove)
    updated = []
    for item_id in item_ids:
        if item_id < 0:
            item_id = _resolve_transaction_as_manual_receipt(conn, -item_id)
        row = conn.execute("SELECT name FROM line_items WHERE id = ?", (item_id,)).fetchone()
        if not row:
            continue
        for tag in add:
            conn.execute(
                "INSERT OR IGNORE INTO item_tags (item_id, tag_id) VALUES (?, ?)",
                (item_id, get_or_create_tag_id(conn, tag)),
            )
        for tag in remove:
            conn.execute(
                "DELETE FROM item_tags WHERE item_id = ? AND tag_id = (SELECT id FROM tags WHERE name = ?)",
                (item_id, tag),
            )
        new_tags = [
            r[0] for r in conn.execute(
                "SELECT t.name FROM item_tags it JOIN tags t ON t.id = it.tag_id WHERE it.item_id = ? ORDER BY t.name",
                (item_id,),
            )
        ]
        updated.append((row[0], new_tags))
    conn.commit()
    return updated


def set_split(
    conn: sqlite3.Connection, item_ids: List[int], split_mode: SplitMode,
    shares: Optional[List[dict]] = None,
) -> int:
    """Marks items as fully mine, paid entirely for someone else, or shared. shares (SHARED only) is
    a list of {person, amount | percentage}; it must include a "me" entry, since that's the only
    portion that counts as personal spend. Returns how many items were changed."""
    shares = shares or []
    if split_mode == SplitMode.SHARED:
        if not any(s["person"].strip().lower() == "me" for s in shares):
            raise ValueError("a shared item needs a 'me' share")
        for s in shares:
            if (s.get("amount") is None) == (s.get("percentage") is None):
                raise ValueError(f"share for {s['person']} needs exactly one of amount or percentage")
    changed = 0
    for item_id in item_ids:
        if item_id < 0:
            item_id = _resolve_transaction_as_manual_receipt(conn, -item_id)
        if not conn.execute("SELECT 1 FROM line_items WHERE id = ?", (item_id,)).fetchone():
            continue
        conn.execute("UPDATE line_items SET split_mode = ? WHERE id = ?", (split_mode.value, item_id))
        conn.execute("DELETE FROM line_item_shares WHERE item_id = ?", (item_id,))
        if split_mode == SplitMode.SHARED:
            for s in shares:
                conn.execute(
                    "INSERT INTO line_item_shares (item_id, person, amount, percentage) VALUES (?, ?, ?, ?)",
                    (item_id, s["person"].strip(), s.get("amount"), s.get("percentage")),
                )
        changed += 1
    conn.commit()
    return changed


def list_transactions(conn: sqlite3.Connection) -> List[dict]:
    rows = conn.execute(
        """
        SELECT t.id, t.date, t.description, t.amount_sgd, t.local_amount, t.local_currency,
               t.matched_receipt_id, t.match_status, t.match_note,
               r.merchant, r.date, r.total, r.currency, t.transaction_type, t.trip_id, tr.name
        FROM youtrip_transactions t
        LEFT JOIN receipts r ON r.id = t.matched_receipt_id
        LEFT JOIN trips tr ON tr.id = t.trip_id
        ORDER BY t.id DESC
        """
    ).fetchall()

    transactions = []
    for (t_id, date, description, amount_sgd, local_amount, local_currency,
         receipt_id, match_status, match_note, r_merchant, r_date, r_total, r_currency,
         transaction_type, trip_id, trip_name) in rows:
        if transaction_type != TransactionType.EXPENSE.value:
            status = "not_expense"  # never has a receipt, so "unmatched" would wrongly ask for one
        else:
            status = "unmatched" if receipt_id is None else (match_status or "auto")
        transactions.append({
            "id": t_id,
            "date": date,
            "description": description,
            "amount_sgd": amount_sgd,
            "local_amount": local_amount,
            "local_currency": local_currency,
            "type": transaction_type,
            "trip": {"id": trip_id, "name": trip_name} if trip_id else None,
            "status": status,
            "note": match_note,
            "receipt": None if receipt_id is None else {
                "id": receipt_id, "merchant": r_merchant, "date": r_date, "total": r_total, "currency": r_currency,
            },
        })
    return transactions


def list_unmatched_receipts(conn: sqlite3.Connection) -> List[dict]:
    rows = conn.execute(
        """
        SELECT id, merchant, date, total, currency FROM receipts
        WHERE id NOT IN (SELECT matched_receipt_id FROM youtrip_transactions WHERE matched_receipt_id IS NOT NULL)
        ORDER BY id DESC
        """
    ).fetchall()
    return [{"id": i, "merchant": m, "date": d, "total": t, "currency": c} for i, m, d, t, c in rows]


def status(conn: sqlite3.Connection) -> dict:
    """The one-line reconciliation picture: what still needs a human, and how much money that is."""
    transactions = list_transactions(conn)
    needs_review = [t for t in transactions if t["status"] == "needs_review"]
    unmatched = [t for t in transactions if t["status"] == "unmatched"]
    return {
        "has_data": bool(transactions) or bool(conn.execute("SELECT 1 FROM receipts LIMIT 1").fetchone()),
        "needs_review": len(needs_review),
        "unmatched_transactions": len(unmatched),
        "unreconciled_sgd": round(sum(t["amount_sgd"] or 0 for t in needs_review + unmatched), 2),
        "unmatched_receipts": len(list_unmatched_receipts(conn)),
    }


def approve_match(conn: sqlite3.Connection, transaction_id: int) -> None:
    conn.execute(
        "UPDATE youtrip_transactions SET match_status = 'approved' WHERE id = ? AND matched_receipt_id IS NOT NULL",
        (transaction_id,),
    )
    conn.commit()


def unlink_match(conn: sqlite3.Connection, transaction_id: int) -> None:
    conn.execute(
        "UPDATE youtrip_transactions SET matched_receipt_id = NULL, match_status = NULL, match_note = NULL WHERE id = ?",
        (transaction_id,),
    )
    conn.commit()


def link_match(conn: sqlite3.Connection, transaction_id: int, receipt_id: int) -> None:
    """A human pairing a transaction with a receipt the matcher didn't - counts as approved. The
    receipt's SGD value then follows the charge, so if the two amounts disagree the note says so."""
    note = "linked manually"
    row = conn.execute(
        """
        SELECT r.total, r.currency, t.local_amount, t.local_currency
        FROM receipts r, youtrip_transactions t WHERE r.id = ? AND t.id = ?
        """,
        (receipt_id, transaction_id),
    ).fetchone()
    if row:
        total, currency, local_amount, local_currency = row
        same_currency = not currency or not local_currency or currency.upper() == local_currency.upper()
        if total and local_amount and same_currency and abs(total - local_amount) / local_amount > 0.05:
            note += f" (receipt total {total:.2f} but charged {local_amount:.2f})"
    record_match(conn, transaction_id, receipt_id, match_status="approved", match_note=note)


def save_new_transactions(conn: sqlite3.Connection, transactions: List[YouTripTransaction]) -> Tuple[int, int]:
    """Saves parsed transactions, skipping ones already stored. Screenshots overlap when you scroll,
    but two identical rows can also be genuine (two 10 kr rides in a day) - so this compares counts:
    if the database already holds N copies of a row, the first N in the upload are the same ones."""
    def key(t: YouTripTransaction):
        return (t.date, t.description, t.amount_sgd, t.local_amount, t.local_currency)

    existing = Counter(
        (r[0], r[1], r[2], r[3], r[4])
        for r in conn.execute(
            "SELECT date, description, amount_sgd, local_amount, local_currency FROM youtrip_transactions"
        )
    )
    inserted = skipped = 0
    for transaction in transactions:
        if existing[key(transaction)] > 0:
            existing[key(transaction)] -= 1
            skipped += 1
            continue
        save_youtrip_transaction(conn, transaction)  # also auto-tags the active trip
        inserted += 1
    return inserted, skipped


# ---- trips ----

def trip_summaries(conn: sqlite3.Connection) -> List[dict]:
    """Every trip with its personal spend in SGD. A trip is a context tag, not a category: the same
    item is counted in its category totals AND its trip's total."""
    items = [i for i in _all_items(conn) if i["trip"] and not i["is_deposit"]]
    totals: Dict[int, dict] = defaultdict(lambda: {"sgd": 0.0, "count": 0})
    for item in items:
        bucket = totals[item["trip"]["id"]]
        bucket["sgd"] += item["personal_sgd"] or 0.0
        bucket["count"] += 1

    trips = conn.execute(
        "SELECT id, name, start_date, end_date, is_active FROM trips ORDER BY start_date DESC, id DESC"
    ).fetchall()
    return [
        {
            "id": trip_id, "name": name, "start_date": start_date, "end_date": end_date,
            "is_active": bool(is_active),
            "spend_sgd": round(totals[trip_id]["sgd"], 2), "item_count": totals[trip_id]["count"],
        }
        for trip_id, name, start_date, end_date, is_active in trips
    ]


# ---- reimbursement ledger ----

def reimbursement_summary(conn: sqlite3.Connection) -> dict:
    """The running paid-for-others balance: what was fronted for others minus what they've paid
    back. Deliberately one pooled balance, not per-person debts - the spec's zero-balance
    checkpoint idea. When the balance settles to exactly zero it's recorded as a checkpoint, and
    'since_checkpoint' shows only the activity after the last one. Known simplification: paying
    back more than owed shows as a negative balance (over_reimbursed) rather than being re-routed.

    Reading this can record a checkpoint - it's idempotent, keyed on the paid/received totals."""
    items = [i for i in _all_items(conn) if not i["is_deposit"] and (i["others_sgd"] or 0) > 0]
    paid_items = [
        {"id": i["id"], "name": i["name"], "date": i["receipt"]["date"], "merchant": i["receipt"]["merchant"],
         "others_sgd": i["others_sgd"], "split_mode": i["split_mode"]}
        for i in items
    ]
    received = [
        {"id": t_id, "date": parse_date(raw_date).isoformat() if parse_date(raw_date) else None,
         "description": description, "amount_sgd": abs(amount_sgd or 0)}
        for t_id, raw_date, description, amount_sgd in conn.execute(
            "SELECT id, date, description, amount_sgd FROM youtrip_transactions WHERE transaction_type = 'reimbursement'"
        )
    ]

    paid_total = round(sum(i["others_sgd"] for i in paid_items), 2)
    received_total = round(sum(r["amount_sgd"] for r in received), 2)
    outstanding = round(paid_total - received_total, 2)

    paid_ids = {i["id"] for i in paid_items}
    received_ids = {r["id"] for r in received}

    last = last_balance_checkpoint(conn)
    settled = abs(outstanding) < BALANCE_TOLERANCE and (paid_total > 0 or received_total > 0)
    if settled and not (last and last["item_ids"] == paid_ids and last["reimbursement_ids"] == received_ids):
        dates = [d for d in [i["date"] for i in paid_items] + [r["date"] for r in received] if d]
        record_balance_checkpoint(conn, max(dates) if dates else "", paid_total, received_total,
                                  list(paid_ids), list(received_ids))
        last = last_balance_checkpoint(conn)

    # activity "since" the checkpoint is whatever it didn't cover - not judged by date, since spending
    # gets entered late and a back-dated item is still new information
    recent_paid = [i for i in paid_items if not last or i["id"] not in last["item_ids"]]
    recent_received = [r for r in received if not last or r["id"] not in last["reimbursement_ids"]]
    since = last["reached_at"] if last else None

    return {
        "paid_for_others_sgd": paid_total,
        "received_sgd": received_total,
        "outstanding_sgd": outstanding,
        "settled": settled,
        "over_reimbursed": outstanding < -BALANCE_TOLERANCE,
        "last_checkpoint": since,
        "since_checkpoint": {
            "paid_sgd": round(sum(i["others_sgd"] for i in recent_paid), 2),
            "received_sgd": round(sum(r["amount_sgd"] for r in recent_received), 2),
            "paid_items": recent_paid,
            "reimbursements": recent_received,
        },
    }
