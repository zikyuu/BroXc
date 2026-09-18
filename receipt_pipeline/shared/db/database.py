"""SQLite persistence for receipts, line items, tags, and YouTrip transactions.

Python-side prototype of the schema designed for the eventual PWA
(SQLite-WASM+OPFS or IndexedDB, depending on device) — same tables, same
columns, only the runtime location changes later. Building it here first lets
the Hungarian matcher and tag-based insights get tested against real data now,
without waiting on a browser frontend that doesn't exist yet.

Deliberately NOT persisted yet: SplitShare details (per-person amounts/percentages)
— there's no review UI producing that data yet, so only split_mode is stored for
now; a shares table can be added once there's something to actually populate it.
"""

import sqlite3
from pathlib import Path
from typing import List, Tuple

from ...types import ReceiptDraft,ReviewStatus, YouTripTransaction

DEFAULT_DB_PATH = Path("expenses.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS receipts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    merchant TEXT,
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
    matched_receipt_id INTEGER REFERENCES receipts(id)
);
"""


def connect(db_path: Path = DEFAULT_DB_PATH) -> sqlite3.Connection:
    """Opens (creating if needed) the local SQLite database with the schema applied."""
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(SCHEMA)
    return conn


def _get_or_create_tag_id(conn: sqlite3.Connection, tag_name: str) -> int:
    conn.execute("INSERT OR IGNORE INTO tags (name) VALUES (?)", (tag_name,))
    row = conn.execute("SELECT id FROM tags WHERE name = ?", (tag_name,)).fetchone()
    return row[0]


def save_receipt(conn: sqlite3.Connection, draft: ReceiptDraft) -> int:
    """Persists a ReceiptDraft and its line items (with tags), returns the new receipt id."""
    cursor = conn.execute(
        """
        INSERT INTO receipts (merchant, date, currency, total, tax, status,
                               suggested_category, ocr_confidence, raw_text, source_image_path)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            draft.merchant, draft.date, draft.currency, draft.total, draft.tax,
            draft.status.value, draft.suggested_category, draft.ocr_confidence,
            draft.raw_text, draft.source_image_path,
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

        for tag_name in item.tags:
            tag_id = _get_or_create_tag_id(conn, tag_name)
            conn.execute(
                "INSERT OR IGNORE INTO item_tags (item_id, tag_id) VALUES (?, ?)",
                (item_id, tag_id),
            )

    conn.commit()
    return receipt_id


def save_youtrip_transaction(conn: sqlite3.Connection, transaction: YouTripTransaction) -> int:
    """Persists one YouTripTransaction, returns its new id."""
    cursor = conn.execute(
        "INSERT INTO youtrip_transactions (date, description, amount_sgd) VALUES (?, ?, ?)",
        (transaction.date, transaction.description, transaction.amount_sgd),
    )
    conn.commit()
    return cursor.lastrowid


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
        SELECT id, merchant, date, currency, total, tax, status,
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
        (receipt_id, merchant, date, currency, total, tax, status,
         suggested_category, ocr_confidence, raw_text, source_image_path) = row
        draft = ReceiptDraft(
            merchant=merchant, date=date, currency=currency, total=total, tax=tax,
            status=ReviewStatus(status), suggested_category=suggested_category,
            ocr_confidence=ocr_confidence, raw_text=raw_text, source_image_path=source_image_path,
        )
        results.append((receipt_id, draft))
    return results


def get_unmatched_transactions(conn: sqlite3.Connection) -> List[Tuple[int, YouTripTransaction]]:
    """YouTrip transactions not yet linked to a receipt."""
    rows = conn.execute(
        "SELECT id, date, description, amount_sgd FROM youtrip_transactions WHERE matched_receipt_id IS NULL"
    ).fetchall()
    return [
        (row[0], YouTripTransaction(date=row[1], description=row[2], amount_sgd=row[3]))
        for row in rows
    ]


def record_match(conn: sqlite3.Connection, transaction_id: int, receipt_id: int) -> None:
    """Links a YouTrip transaction to the receipt the matcher decided it corresponds to."""
    conn.execute(
        "UPDATE youtrip_transactions SET matched_receipt_id = ? WHERE id = ?",
        (receipt_id, transaction_id),
    )
    conn.commit()