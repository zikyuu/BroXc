"""Fills demo.db (and demo_tag_store.json) with made-up data so the UI can be explored without
running any OCR or touching your real database. Run from the repo root:

    python3 scripts/seed_demo.py

then start the demo server (port 8001) with the 'expense-tracker-demo' launch config, or:

    EXPENSES_DB=demo.db TAG_STORE=demo_tag_store.json python3 -m uvicorn receipt_pipeline.api.app:app --port 8001
"""

import sys
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from receipt_pipeline.receipts.tag_store import TagStore
from receipt_pipeline.shared.db.database import (
    classify_transaction, connect, create_trip, record_match, save_receipt, save_youtrip_transaction,
    set_receipt_trip, set_transaction_trip,
)
from receipt_pipeline.shared.db.ledger import set_split
from receipt_pipeline.types import Lineitem, ReceiptDraft, SplitMode, TransactionType, YouTripTransaction

DB, TAGS = Path("demo.db"), Path("demo_tag_store.json")
for path in (DB, TAGS):
    path.unlink(missing_ok=True)

today = date.today()
conn = connect(DB)


def receipt(merchant, original, days_ago, currency, items):
    return save_receipt(conn, ReceiptDraft(
        merchant=merchant, merchant_original=original,
        date=(today - timedelta(days=days_ago)).isoformat(), currency=currency,
        total=round(sum(i.price for i in items), 2), line_items=items,
    ))


def charge(days_ago, description, sgd, local, currency):
    day = today - timedelta(days=days_ago)
    return save_youtrip_transaction(conn, YouTripTransaction(
        date=day.strftime("%d %b %Y"), description=description,
        amount_sgd=sgd, local_amount=local, local_currency=currency,
    ))


# ---- Sweden (SEK) ----
r_coop = receipt("Large coop", "Stora Coop", 2, "SEK", [
    Lineitem(name="Facial napkins", price=41.90, quantity=2.0, tags=["household"]),
    Lineitem(name="Candy, loose weight", price=30.74, quantity=0.298, tags=["food", "snacks"]),
    Lineitem(name="Resin cord velvet", price=29.90),
    Lineitem(name="Max white purple", price=33.95),
    Lineitem(name="Hygiene napkins 2 for 30:-", price=-11.90),
])
r_press = receipt("Pressbyran", "Pressbyran", 5, "SEK", [
    Lineitem(name="Coffee", price=39.00, tags=["food", "drinks"]),
    Lineitem(name="Sandwich", price=55.00, tags=["food", "meals out"]),
    Lineitem(name="?????", price=12.00, tags=["mystery"]),
])
r_transit = receipt("SL", "SL", 9, "SEK", [Lineitem(name="Travel card top-up", price=300.00, tags=["transport"])])
receipt("ICA Maxi", "ICA Maxi", 12, "SEK", [  # no charge yet: its SGD value is an estimate
    Lineitem(name="Chicken breast", price=89.90, tags=["food", "meat"]),
    Lineitem(name="Onions", price=19.90, tags=["food", "vege"]),
    Lineitem(name="Milk", price=15.90, tags=["food"]),
    Lineitem(name="Pant", price=2.00, is_deposit=True),
])

t_coop = charge(2, "STORA COOP UPPSALA", 16.50, 124.59, "SEK")
t_press = charge(5, "PRESSBYRAN UPPSALA C", 14.10, 106.00, "SEK")
t_transit = charge(9, "SL ACCESS", 39.90, 300.00, "SEK")
charge(7, "SYSTEMBOLAGET UPPSALA", 28.00, 210.00, "SEK")  # receipt lost: stays unmatched

record_match(conn, t_coop, r_coop, "auto")
record_match(conn, t_press, r_press, "approved", "linked manually")
record_match(conn, t_transit, r_transit, "auto")

# ---- a weekend in Berlin (EUR): three charges establish the usual rate of about 0.67 EUR per SGD ----
r_cafe = receipt("Cafe Roma", "Cafe Roma", 14, "EUR", [Lineitem(name="Lunch for two", price=50.00, tags=["food", "meals out"])])
r_bakery = receipt("Backerei Mohr", "Backerei Mohr", 15, "EUR", [Lineitem(name="Bread and pastries", price=20.00, tags=["food"])])
r_shop = receipt("Museum shop", "Museumsshop", 15, "EUR", [Lineitem(name="Postcards", price=30.00, tags=["gifts"])])

t_cafe = charge(14, "CAFE ROMA BERLIN", 88.00, 50.00, "EUR")  # far pricier than the usual rate: flagged
t_bakery = charge(15, "BACKEREI MOHR", 30.00, 20.00, "EUR")
t_shop = charge(15, "MUSEUMSSHOP BERLIN", 45.00, 30.00, "EUR")
charge(16, "RESTAURANT ZUR LINDE", 60.00, 40.00, "EUR")  # no receipt

record_match(conn, t_cafe, r_cafe, "needs_review", "exchange rate 0.57 EUR/SGD is 15% off the usual 0.67")
record_match(conn, t_bakery, r_bakery, "auto")
record_match(conn, t_shop, r_shop, "auto")

# ---- trip mode + paid-for-others: Berlin is a trip (a context tag, separate from categories), the
# Cafe Roma lunch was split with a friend, and the friend has paid part of it back ----
berlin = create_trip(conn, "Berlin weekend", (today - timedelta(days=16)).isoformat(), (today - timedelta(days=14)).isoformat())
for receipt_id in (r_cafe, r_bakery, r_shop):
    set_receipt_trip(conn, receipt_id, berlin)
for transaction_id in (t_cafe, t_bakery, t_shop):
    set_transaction_trip(conn, transaction_id, berlin)

lunch_item = conn.execute("SELECT id FROM line_items WHERE receipt_id = ?", (r_cafe,)).fetchone()[0]
set_split(conn, [lunch_item], SplitMode.SHARED, [{"person": "me", "percentage": 50}, {"person": "Sam", "percentage": 50}])
paid_back = charge(10, "FROM SAM", 30.00, None, None)
classify_transaction(conn, paid_back, TransactionType.REIMBURSEMENT)

# ---- corrections the tag store has learned, so tag suggestions have something to draw on ----
store = TagStore(TAGS)
for name, tags in [("chicken breast", ["food", "meat"]), ("onions", ["food", "vege"]), ("coffee", ["food", "drinks"]),
                   ("sandwich", ["food", "meals out"]), ("milk", ["food"]), ("facial napkins", ["household"])]:
    store.record_correction(name, tags)

conn.close()
print(f"Seeded {DB} and {TAGS}")
