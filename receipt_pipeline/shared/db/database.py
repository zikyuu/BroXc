"""SQLite persistence for receipts, line items, tags, and YouTrip transactions.

Python-side prototype of the schema designed for the eventual PWA
(SQLite-WASM+OPFS or IndexedDB, depending on device) — same tables, same
columns, only the runtime location changes later. Building it here first lets
the Hungarian matcher and tag-based insights get tested against real data now,
without waiting on a browser frontend that doesn't exist yet.

SplitShare details (per-person amounts/percentages) live in line_item_shares, one row per
person, so a SHARED item's personal portion can be computed without guessing.
"""

import json
import sqlite3
from collections import defaultdict
from pathlib import Path
from statistics import median
from typing import Dict, List, Optional, Tuple

from ...types import ReceiptDraft, ReviewStatus, TransactionType, Trip, YouTripTransaction

DEFAULT_DB_PATH = Path("expenses.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS receipts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    merchant TEXT,
    merchant_original TEXT,
    date TEXT,
    currency TEXT,
    total REAL,
    tax REAL,
    status TEXT NOT NULL,
    suggested_category TEXT,
    ocr_confidence REAL,
    raw_text TEXT,
    source_image_path TEXT
);

CREATE TABLE IF NOT EXISTS line_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    receipt_id INTEGER NOT NULL REFERENCES receipts(id),
    name TEXT NOT NULL,
    price REAL NOT NULL,
    quantity REAL,
    translated_text TEXT,
    original_price REAL,
    discount REAL,
    is_deposit INTEGER NOT NULL DEFAULT 0,
    split_mode TEXT NOT NULL DEFAULT 'mine'
);

-- one row per person on a SHARED item; exactly one of amount/percentage is set. person 'me' is
-- the user's own portion, anyone else's portion is what they owe back (paid-for-others)
CREATE TABLE IF NOT EXISTS line_item_shares (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id INTEGER NOT NULL REFERENCES line_items(id),
    person TEXT NOT NULL,
    amount REAL,
    percentage REAL
);

CREATE TABLE IF NOT EXISTS tags (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS item_tags (
    item_id INTEGER NOT NULL REFERENCES line_items(id),
    tag_id INTEGER NOT NULL REFERENCES tags(id),
    PRIMARY KEY (item_id, tag_id)
);

CREATE TABLE IF NOT EXISTS youtrip_transactions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    date TEXT,
    description TEXT,
    amount_sgd REAL,
    local_amount REAL,
    local_currency TEXT,
    matched_receipt_id INTEGER REFERENCES receipts(id),
    match_status TEXT,
    match_note TEXT,
    transaction_type TEXT NOT NULL DEFAULT 'expense',
    trip_id INTEGER REFERENCES trips(id),
    refunds_receipt_id INTEGER REFERENCES receipts(id)
);

CREATE TABLE IF NOT EXISTS trips (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    start_date TEXT,
    end_date TEXT,
    is_active INTEGER NOT NULL DEFAULT 0
);

-- a checkpoint each time the paid-for-others balance settles back to exactly $0 - lets "recent
-- activity" show what's happened since the last time everything was square, per the spec's
-- zero-balance checkpoint idea, without needing to allocate debt to specific people
-- a checkpoint snapshots exactly which paid-for-others items and reimbursements it settled (JSON
-- id lists), so "activity since" is whatever isn't in the snapshot. Dates can't anchor this:
-- spending gets entered late, so a back-dated item must still show up as new. reached_at is just
-- the date of the latest covered activity, for display.
CREATE TABLE IF NOT EXISTS balance_checkpoints (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    reached_at TEXT NOT NULL,
    paid_total REAL,
    received_total REAL,
    item_ids TEXT,
    reimbursement_ids TEXT
);
"""

# Columns added after the first version of the schema. CREATE TABLE IF NOT EXISTS never alters a
# table that already exists, so a database created earlier gets these added by _migrate instead.
MIGRATIONS = {
    "receipts": {"merchant_original": "TEXT", "trip_id": "INTEGER REFERENCES trips(id)"},
    "youtrip_transactions": {
        "local_amount": "REAL",
        "local_currency": "TEXT",
        "match_status": "TEXT",  # auto (matcher was confident) | needs_review | approved (a human said yes)
        "match_note": "TEXT",
        "transaction_type": "TEXT NOT NULL DEFAULT 'expense'",
        "trip_id": "INTEGER REFERENCES trips(id)",
        "refunds_receipt_id": "INTEGER REFERENCES receipts(id)",
    },
    "balance_checkpoints": {
        "paid_total": "REAL", "received_total": "REAL", "item_ids": "TEXT", "reimbursement_ids": "TEXT",
    },
}


def _migrate(conn: sqlite3.Connection) -> None:
    for table, columns in MIGRATIONS.items():
        existing = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
        for name, sql_type in columns.items():
            if name not in existing:
                conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} {sql_type}")
    conn.commit()


def connect(db_path: Path = DEFAULT_DB_PATH) -> sqlite3.Connection:
    """Opens (creating if needed) the local SQLite database with the schema applied."""
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(SCHEMA)
    _migrate(conn)
    return conn


def get_or_create_tag_id(conn: sqlite3.Connection, tag_name: str) -> int:
    conn.execute("INSERT OR IGNORE INTO tags (name) VALUES (?)", (tag_name,))
    row = conn.execute("SELECT id FROM tags WHERE name = ?", (tag_name,)).fetchone()
    return row[0]


def save_receipt(conn: sqlite3.Connection, draft: ReceiptDraft) -> int:
    """Persists a ReceiptDraft and its line items (with tags), returns the new receipt id.
    A receipt with no trip of its own joins whichever trip has Trip Mode on."""
    trip_id = draft.trip_id if draft.trip_id is not None else get_active_trip_id(conn)
    cursor = conn.execute(
        """
        INSERT INTO receipts (merchant, merchant_original, date, currency, total, tax, status,
                               suggested_category, ocr_confidence, raw_text, source_image_path, trip_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            draft.merchant, draft.merchant_original, draft.date, draft.currency, draft.total,
            draft.tax, draft.status.value, draft.suggested_category, draft.ocr_confidence,
            draft.raw_text, draft.source_image_path, trip_id,
        ),
    )
    receipt_id = cursor.lastrowid

    for item in draft.line_items:
        item_cursor = conn.execute(
            """
            INSERT INTO line_items (receipt_id, name, price, quantity, translated_text,
                                     original_price, discount, is_deposit, split_mode)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                receipt_id, item.name, item.price, item.quantity, item.translated_text,
                item.original_price, item.discount, int(item.is_deposit), item.split_mode.value,
            ),
        )
        item_id = item_cursor.lastrowid

        for share in item.shares:
            conn.execute(
                "INSERT INTO line_item_shares (item_id, person, amount, percentage) VALUES (?, ?, ?, ?)",
                (item_id, share.person, share.amount, share.percentage),
            )

        for tag_name in item.tags:
            tag_id = get_or_create_tag_id(conn, tag_name)
            conn.execute(
                "INSERT OR IGNORE INTO item_tags (item_id, tag_id) VALUES (?, ?)",
                (item_id, tag_id),
            )

    conn.commit()
    return receipt_id


def save_youtrip_transaction(conn: sqlite3.Connection, transaction: YouTripTransaction) -> int:
    """Persists one YouTripTransaction, returns its new id. Only expenses pick up the active trip -
    an incoming reimbursement or a transfer between own accounts isn't part of any trip's spend."""
    trip_id = transaction.trip_id
    if trip_id is None and transaction.transaction_type == TransactionType.EXPENSE:
        trip_id = get_active_trip_id(conn)
    cursor = conn.execute(
        """
        INSERT INTO youtrip_transactions (date, description, amount_sgd, local_amount, local_currency,
                                           transaction_type, trip_id, refunds_receipt_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            transaction.date, transaction.description, transaction.amount_sgd,
            transaction.local_amount, transaction.local_currency,
            transaction.transaction_type.value, trip_id, transaction.refunds_receipt_id,
        ),
    )
    conn.commit()
    return cursor.lastrowid


# ---- trips ----

def create_trip(
    conn: sqlite3.Connection, name: str, start_date: Optional[str] = None,
    end_date: Optional[str] = None, activate: bool = False,
) -> int:
    cursor = conn.execute(
        "INSERT INTO trips (name, start_date, end_date, is_active) VALUES (?, ?, ?, 0)",
        (name, start_date, end_date),
    )
    conn.commit()
    if activate:
        set_active_trip(conn, cursor.lastrowid)
    return cursor.lastrowid


def _trip_from_row(row) -> Trip:
    return Trip(id=row[0], name=row[1], start_date=row[2], end_date=row[3], is_active=bool(row[4]))


def list_trips(conn: sqlite3.Connection) -> List[Trip]:
    rows = conn.execute(
        "SELECT id, name, start_date, end_date, is_active FROM trips ORDER BY start_date DESC, id DESC"
    ).fetchall()
    return [_trip_from_row(row) for row in rows]


def get_active_trip(conn: sqlite3.Connection) -> Optional[Trip]:
    row = conn.execute(
        "SELECT id, name, start_date, end_date, is_active FROM trips WHERE is_active = 1"
    ).fetchone()
    return _trip_from_row(row) if row else None


def get_active_trip_id(conn: sqlite3.Connection) -> Optional[int]:
    trip = get_active_trip(conn)
    return trip.id if trip else None


def set_active_trip(conn: sqlite3.Connection, trip_id: Optional[int]) -> None:
    """Turns Trip Mode on for one trip (turning it off everywhere else - only one is active at a
    time), or off entirely when trip_id is None."""
    conn.execute("UPDATE trips SET is_active = 0")
    if trip_id is not None:
        conn.execute("UPDATE trips SET is_active = 1 WHERE id = ?", (trip_id,))
    conn.commit()


def set_receipt_trip(conn: sqlite3.Connection, receipt_id: int, trip_id: Optional[int]) -> None:
    """Auto-tagging isn't a hard rule - this moves a receipt into (or out of, with None) a trip."""
    conn.execute("UPDATE receipts SET trip_id = ? WHERE id = ?", (trip_id, receipt_id))
    conn.commit()


def set_transaction_trip(conn: sqlite3.Connection, transaction_id: int, trip_id: Optional[int]) -> None:
    conn.execute("UPDATE youtrip_transactions SET trip_id = ? WHERE id = ?", (trip_id, transaction_id))
    conn.commit()


def classify_transaction(
    conn: sqlite3.Connection, transaction_id: int, transaction_type: TransactionType,
    refunds_receipt_id: Optional[int] = None,
) -> None:
    """Reclassifies a transaction (e.g. an incoming YouTrip credit as a reimbursement). Anything
    that isn't an expense is pulled out of the receipt matcher, so a match it already holds is
    cleared, and it leaves any trip it was auto-tagged into."""
    if transaction_type == TransactionType.EXPENSE:
        conn.execute(
            "UPDATE youtrip_transactions SET transaction_type = ?, refunds_receipt_id = NULL WHERE id = ?",
            (transaction_type.value, transaction_id),
        )
    else:
        conn.execute(
            """
            UPDATE youtrip_transactions
            SET transaction_type = ?, refunds_receipt_id = ?, matched_receipt_id = NULL,
                match_status = NULL, match_note = NULL, trip_id = NULL
            WHERE id = ?
            """,
            (
                transaction_type.value,
                refunds_receipt_id if transaction_type == TransactionType.REFUND else None,
                transaction_id,
            ),
        )
    conn.commit()


def record_balance_checkpoint(
    conn: sqlite3.Connection, reached_at: str, paid_total: float, received_total: float,
    item_ids: List[int], reimbursement_ids: List[int],
) -> None:
    conn.execute(
        """
        INSERT INTO balance_checkpoints (reached_at, paid_total, received_total, item_ids, reimbursement_ids)
        VALUES (?, ?, ?, ?, ?)
        """,
        (reached_at, paid_total, received_total, json.dumps(sorted(item_ids)), json.dumps(sorted(reimbursement_ids))),
    )
    conn.commit()


def last_balance_checkpoint(conn: sqlite3.Connection) -> Optional[dict]:
    row = conn.execute(
        """
        SELECT reached_at, paid_total, received_total, item_ids, reimbursement_ids
        FROM balance_checkpoints ORDER BY id DESC LIMIT 1
        """
    ).fetchone()
    if not row:
        return None
    return {
        "reached_at": row[0], "paid_total": row[1], "received_total": row[2],
        "item_ids": set(json.loads(row[3] or "[]")), "reimbursement_ids": set(json.loads(row[4] or "[]")),
    }


def spend_by_tag(conn: sqlite3.Connection, tag_name: str) -> float:
    """Sums net spend for every item carrying this tag — excludes deposits, matching
    CLAUDE.md's intent that a pant refund shouldn't count as negative grocery spend."""
    row = conn.execute(
        """
        SELECT COALESCE(SUM(li.price), 0)
        FROM line_items li
        JOIN item_tags it ON it.item_id = li.id
        JOIN tags t ON t.id = it.tag_id
        WHERE t.name = ? AND li.is_deposit = 0
        """,
        (tag_name,),
    ).fetchone()
    return row[0]


def get_unmatched_receipts(conn: sqlite3.Connection) -> List[Tuple[int, ReceiptDraft]]:
    """Receipts with no YouTrip transaction pointing at them yet. Line items aren't
    loaded here — the matcher only needs merchant/date/total, not the full item list."""
    rows = conn.execute(
        """
        SELECT id, merchant, merchant_original, date, currency, total, tax, status,
               suggested_category, ocr_confidence, raw_text, source_image_path
        FROM receipts
        WHERE id NOT IN (
            SELECT matched_receipt_id FROM youtrip_transactions
            WHERE matched_receipt_id IS NOT NULL
        )
        """
    ).fetchall()

    results = []
    for row in rows:
        (receipt_id, merchant, merchant_original, date, currency, total, tax, status,
         suggested_category, ocr_confidence, raw_text, source_image_path) = row
        draft = ReceiptDraft(
            merchant=merchant, merchant_original=merchant_original, date=date,
            currency=currency, total=total, tax=tax, status=ReviewStatus(status),
            suggested_category=suggested_category, ocr_confidence=ocr_confidence,
            raw_text=raw_text, source_image_path=source_image_path,
        )
        results.append((receipt_id, draft))
    return results


def get_unmatched_transactions(conn: sqlite3.Connection) -> List[Tuple[int, YouTripTransaction]]:
    """Expense transactions not yet linked to a receipt - reimbursements, income and transfers
    never have a receipt, so they stay out of the matcher entirely."""
    rows = conn.execute(
        """
        SELECT id, date, description, amount_sgd, local_amount, local_currency
        FROM youtrip_transactions
        WHERE matched_receipt_id IS NULL AND transaction_type = 'expense'
        """
    ).fetchall()
    return [
        (
            row[0],
            YouTripTransaction(
                date=row[1], description=row[2], amount_sgd=row[3],
                local_amount=row[4], local_currency=row[5],
            ),
        )
        for row in rows
    ]


def record_match(
    conn: sqlite3.Connection,
    transaction_id: int,
    receipt_id: int,
    match_status: str = "auto",
    match_note: Optional[str] = None,
) -> None:
    """Links a YouTrip transaction to a receipt. match_status is 'auto' when the matcher was
    confident, 'needs_review' when it linked but wants a human to look, 'approved' once one has."""
    conn.execute(
        "UPDATE youtrip_transactions SET matched_receipt_id = ?, match_status = ?, match_note = ? WHERE id = ?",
        (receipt_id, match_status, match_note, transaction_id),
    )
    conn.commit()


def get_reference_rates(conn: sqlite3.Connection, min_samples: int = 3) -> Dict[str, float]:
    """The usual local-currency-per-SGD rate for each currency, taken from YouTrip's own charges
    (the median of local_amount / amount_sgd). A currency needs min_samples transactions before
    it gets a rate, since a median of one or two isn't a baseline anything can be an outlier against."""
    rows = conn.execute(
        """
        SELECT local_currency, local_amount / amount_sgd
        FROM youtrip_transactions
        WHERE local_amount > 0 AND amount_sgd > 0 AND local_currency IS NOT NULL
        """
    ).fetchall()

    rates_by_currency: Dict[str, List[float]] = defaultdict(list)
    for currency, rate in rows:
        rates_by_currency[currency.upper()].append(rate)

    return {c: median(rates) for c, rates in rates_by_currency.items() if len(rates) >= min_samples}