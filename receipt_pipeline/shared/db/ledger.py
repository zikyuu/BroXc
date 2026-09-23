"""UI-facing reads and writes over the expenses database: SGD-converted item listings,
spend-by-tag insights, bulk tag edits, and match review actions.

Spend is tracked in SGD, the currency that actually left the card. A receipt's items are
converted at the rate its own matched YouTrip charge implies (exact), else at the usual rate
for that currency (an estimate, flagged as one), else left unconverted in the original currency.
"""

import sqlite3
from collections import Counter, defaultdict
from typing import Dict, List, Optional, Tuple

from ..dates import parse_date
from ...types import ReviewStatus, YouTripTransaction
from .database import get_or_create_tag_id, get_reference_rates, record_match

UNTAGGED = "Untagged"  # the bucket shown for items with no tags; not a real tag
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


def _all_items(conn: sqlite3.Connection) -> List[dict]:
    rates = _receipt_rates(conn)

    tags_by_item: Dict[int, List[str]] = defaultdict(list)
    for item_id, name in conn.execute(
        "SELECT it.item_id, t.name FROM item_tags it JOIN tags t ON t.id = it.tag_id ORDER BY t.name"
    ):
        tags_by_item[item_id].append(name)

    rows = conn.execute(
        """
        SELECT li.id, li.name, li.price, li.quantity, li.is_deposit,
               r.id, r.merchant, r.date, r.currency
        FROM line_items li JOIN receipts r ON r.id = li.receipt_id
        ORDER BY r.date DESC, li.id
        """
    ).fetchall()

    items = []
    for item_id, name, price, quantity, is_deposit, receipt_id, merchant, raw_date, currency in rows:
        parsed = parse_date(raw_date)
        rate, source = rates.get(receipt_id, (None, None))
        items.append({
            "id": item_id,
            "name": name,
            "quantity": quantity,
            "is_deposit": bool(is_deposit),
            "price": price,
            "currency": currency,
            "price_sgd": round(price / rate, 2) if rate else None,
            "sgd_source": source,
            "tags": tags_by_item.get(item_id, []),
            "tag_confidence": "confirmed",
            "receipt": {
                "id": receipt_id,
                "merchant": merchant,
                "date": parsed.isoformat() if parsed else None,
            },
        })

    # transactions with no receipt at all get no line_items row to read from — without this,
    # that money is invisible in every spending total even though it genuinely left the card
    merchant_hints = _merchant_category_hints(conn)
    unmatched = conn.execute(
        "SELECT id, date, description, amount_sgd FROM youtrip_transactions WHERE matched_receipt_id IS NULL"
    ).fetchall()
    for t_id, raw_date, description, amount_sgd in unmatched:
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
            "sgd_source": "native",
            "tags": [inferred] if inferred else [],
            "tag_confidence": "inferred" if inferred else "unknown",
            "receipt": {
                "id": None,
                "merchant": "No receipt yet",
                "date": parsed.isoformat() if parsed else None,
            },
        })

    return items


def list_items(conn: sqlite3.Connection, start: Optional[str] = None, end: Optional[str] = None) -> List[dict]:
    """Items in an optional ISO date range. Items on undated receipts can't be placed in a range,
    so they only appear when no range is set (summary() reports how many were left out)."""
    items = _all_items(conn)
    if not (start or end):
        return items
    kept = []
    for item in items:
        day = item["receipt"]["date"]
        if not day or (start and day < start) or (end and day > end):
            continue
        kept.append(item)
    return kept


def summary(conn: sqlite3.Connection, start: Optional[str] = None, end: Optional[str] = None) -> dict:
    """Spend in SGD, split by tag. Items can carry several tags, so per-tag totals overlap and
    won't add up to total_sgd - each item is counted once in the total. Deposits are excluded."""
    everything = _all_items(conn)
    undated_excluded = sum(1 for i in everything if not i["receipt"]["date"]) if (start or end) else 0

    total_sgd = estimated_sgd = 0.0
    unconverted: Dict[str, float] = defaultdict(float)
    by_tag: Dict[str, dict] = defaultdict(lambda: {"count": 0, "sgd": 0.0, "estimated_sgd": 0.0})
    counted = [i for i in list_items(conn, start, end) if not i["is_deposit"]]

    for item in counted:
        sgd = item["price_sgd"]
        estimated = item["sgd_source"] == "estimated"
        if sgd is None:
            unconverted[item["currency"] or "?"] += item["price"]
        else:
            total_sgd += sgd
            if estimated:
                estimated_sgd += sgd

        for tag in item["tags"] or [UNTAGGED]:
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
        if tag and tag != UNTAGGED.lower() and tag not in cleaned:
            cleaned.append(tag)
    return cleaned


def _resolve_transaction_as_manual_receipt(conn: sqlite3.Connection, transaction_id: int) -> int:
    """Turns a receipt-less transaction into a matched one backed by a minimal, hand-entered
    receipt, the moment a user tags it directly from the Spending tab. Reuses the same idea as
    a personal-transfer breakdown (a transaction can be enriched by a manually-typed receipt,
    not just an OCR'd one) - just triggered by tagging instead of an explicit "add details" step.
    Returns the id of the one line item created, so the caller can tag that."""
    row = conn.execute(
        "SELECT date, description, amount_sgd, local_amount, local_currency FROM youtrip_transactions WHERE id = ?",
        (transaction_id,),
    ).fetchone()
    if not row:
        raise ValueError(f"no transaction with id {transaction_id}")
    date, description, amount_sgd, local_amount, local_currency = row

    cursor = conn.execute(
        "INSERT INTO receipts (merchant, date, currency, total, status) VALUES (?, ?, ?, ?, ?)",
        (description, date, local_currency or "SGD", local_amount or amount_sgd, ReviewStatus.CONFIRMED.value),
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


def list_transactions(conn: sqlite3.Connection) -> List[dict]:
    rows = conn.execute(
        """
        SELECT t.id, t.date, t.description, t.amount_sgd, t.local_amount, t.local_currency,
               t.matched_receipt_id, t.match_status, t.match_note,
               r.merchant, r.date, r.total, r.currency
        FROM youtrip_transactions t LEFT JOIN receipts r ON r.id = t.matched_receipt_id
        ORDER BY t.id DESC
        """
    ).fetchall()

    transactions = []
    for (t_id, date, description, amount_sgd, local_amount, local_currency,
         receipt_id, match_status, match_note, r_merchant, r_date, r_total, r_currency) in rows:
        transactions.append({
            "id": t_id,
            "date": date,
            "description": description,
            "amount_sgd": amount_sgd,
            "local_amount": local_amount,
            "local_currency": local_currency,
            "status": "unmatched" if receipt_id is None else (match_status or "auto"),
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
        conn.execute(
            """
            INSERT INTO youtrip_transactions (date, description, amount_sgd, local_amount, local_currency)
            VALUES (?, ?, ?, ?, ?)
            """,
            (
                transaction.date, transaction.description, transaction.amount_sgd,
                transaction.local_amount, transaction.local_currency,
            ),
        )
        inserted += 1
    conn.commit()
    return inserted, skipped
