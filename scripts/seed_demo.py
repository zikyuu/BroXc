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
from receipt_pipeline.shared.db import categories as category_store
from receipt_pipeline.shared.db.insights import reconcile_balance
from receipt_pipeline.shared.db.ledger import assign_category, set_split
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
        total=round(sum(i.price for i in items), 2), line_items=items, raw_text="(demo receipt)",
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

# ---- three earlier months at home (SGD), so "usual", trends and projections have history ----
def first_of_month(offset):
    index = today.year * 12 + today.month - 1 - offset
    return date(index // 12, index % 12 + 1, 1)


HISTORY = [  # (day of month, merchant, [(item, price, tags)])
    (3, "Cold Storage", [("Chicken thigh", 9.80, ["food", "meat"]), ("Broccoli", 3.20, ["food", "vege"]), ("Rice 5kg", 12.90, ["food"])]),
    (8, "MRT top-up", [("Card top-up", 30.00, ["transport"])]),
    (12, "Ramen Bar", [("Ramen set", 16.50, ["food", "meals out"])]),
    (17, "Cold Storage", [("Salmon fillet", 11.40, ["food", "meat"]), ("Onions", 2.10, ["food", "vege"]), ("Milk", 3.50, ["food"])]),
    (21, "Uniqlo", [("T-shirt", 19.90, ["shopping"])]),
    (25, "Guardian", [("Vitamins", 14.00, ["health"])]),
]
for months_ago, factor in [(3, 3.6), (2, 4.0), (1, 4.4)]:  # scaled up: an exchange student's month is bigger than one grocery run
    month_start = first_of_month(months_ago)
    for day, merchant, rows in HISTORY:
        conn_items = [Lineitem(name=n, price=round(price * factor, 2), tags=t) for n, price, t in rows]
        save_receipt(conn, ReceiptDraft(
            merchant=merchant, date=month_start.replace(day=day).isoformat(), currency="SGD",
            total=round(sum(i.price for i in conn_items), 2), line_items=conn_items, raw_text="(demo receipt)",
        ))

# ---- the user has confirmed some categories; the rest stay suggestions or unknown, so Needs a Look has content ----
index = category_store.category_index(conn)
by_name = {c["name"]: c["id"] for c in index.values() if c["kind"] != "misc"}
confirmed = {"Coffee": "Drinks", "Sandwich": "Eat Out", "Lunch for two": "Eat Out", "Bread and pastries": "Carbs",
             "Travel card top-up": "Public Transit", "Postcards": "Souvenirs", "Facial napkins": "Household"}
for name, category in confirmed.items():
    ids = [r[0] for r in conn.execute("SELECT id FROM line_items WHERE name = ?", (name,))]
    assign_category(conn, ids, by_name[category])

# ---- Trip Mode is on for a Tallinn trip: the latest charges joined it automatically ----
tallinn = create_trip(conn, "Tallinn trip", (today - timedelta(days=1)).isoformat(), (today + timedelta(days=4)).isoformat(),
                      activate=True, color="#5d8df6", emoji="🏰")
set_receipt_trip(conn, r_coop, tallinn)
set_transaction_trip(conn, t_coop, tallinn)
for description, sgd, local, days_ago in [("RAKVERE KOHVIK TALLINN", 7.20, 5.00, 1), ("BOLT TALLINN", 11.80, 8.20, 0)]:
    charge(days_ago, description, sgd, local, "EUR")  # saved while Trip Mode is on, so they tag themselves

# ---- balance: a baseline, then activity, then a check that finds $48 the records can't explain ----
reconcile_balance(conn, 1500.00, first_of_month(0).isoformat())
for days_ago, description, sgd in [(3, "DABBA COFFEE", 6.50), (1, "COMFORT TAXI", 12.00)]:
    save_youtrip_transaction(conn, YouTripTransaction(
        date=(today - timedelta(days=days_ago)).strftime("%d %b %Y"), description=description, amount_sgd=sgd))
reconcile_balance(conn, round(1500.00 - 6.50 - 12.00 - 48.00, 2), today.isoformat())

# ---- corrections the tag store has learned, so tag suggestions have something to draw on ----
store = TagStore(TAGS)
for name, tags in [("chicken breast", ["food", "meat"]), ("onions", ["food", "vege"]), ("coffee", ["food", "drinks"]),
                   ("sandwich", ["food", "meals out"]), ("milk", ["food"]), ("facial napkins", ["household"])]:
    store.record_correction(name, tags)

conn.close()
print(f"Seeded {DB} and {TAGS}")
