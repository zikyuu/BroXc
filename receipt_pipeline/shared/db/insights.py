"""Read-only analysis for the phone UI's screens: the category tree, the Home radial data, the
activity feed, the review list, search, trends, and balance reconciliation.

Everything is in personal SGD: an item's personal share (deposits excluded), so money fronted for
others never inflates a category. "Usual" is what a category normally costs in a month, averaged over up
to six earlier months that have any spending at all - it needs history, so it's simply absent until then.
"""

import calendar
import sqlite3
from collections import defaultdict
from datetime import date, timedelta
from statistics import median
from typing import Dict, List, Optional, Tuple

from ..dates import parse_date
from . import categories as cats
from . import ledger
from .database import get_active_trip

USUAL_MONTHS = 6
MIN_PROJECTION_DAY = 3  # before this, "spent so far / fraction of month" is mostly noise
WATCH_RATIO = 1.15  # projected up to 15% over the usual/budget total is "watch", beyond that "over"


# ---- small helpers ----

def _counted(items: List[dict]) -> List[dict]:
    """Items that are real personal spend with a known SGD value and a date."""
    return [
        i for i in items
        if not i["is_deposit"] and i["personal_sgd"] is not None and i["receipt"]["date"]
    ]


def _month_key(day: str) -> str:
    return day[:7]


def _month_bounds(month: str) -> Tuple[date, int]:
    year, mon = int(month[:4]), int(month[5:7])
    return date(year, mon, 1), calendar.monthrange(year, mon)[1]


def _shift_month(month: str, delta: int) -> str:
    year, mon = int(month[:4]), int(month[5:7])
    index = year * 12 + (mon - 1) + delta
    return f"{index // 12:04d}-{index % 12 + 1:02d}"


def _month_label(month: str) -> str:
    return date(int(month[:4]), int(month[5:7]), 1).strftime("%B %Y")


def _elapsed(month: str, today: date) -> Tuple[float, int]:
    """(fraction of the month that has passed, days elapsed) - 1.0 for past months, 0 for future ones."""
    first, days = _month_bounds(month)
    if today < first:
        return 0.0, 0
    if today >= first.replace(day=days):
        return 1.0, days
    return today.day / days, today.day


def _round(value: float) -> float:
    return round(value, 2)


# ---- category tree ----

def category_tree(
    conn: sqlite3.Connection, start: Optional[str] = None, end: Optional[str] = None,
    trip_id: Optional[int] = None,
) -> dict:
    """Every category with its personal spend (its own items plus everything beneath it). A node
    with sub-categories AND items sitting directly on it gets a synthetic 'Unsorted' child for those
    items: they're real, the app just can't place them any deeper yet."""
    index = cats.category_index(conn)
    items = [i for i in ledger.list_items(conn, start, end, trip_id) if not i["is_deposit"]]

    own: Dict[Optional[int], float] = defaultdict(float)
    count: Dict[Optional[int], int] = defaultdict(int)
    unconverted: Dict[str, float] = defaultdict(float)
    for item in items:
        if item["personal_sgd"] is None:
            unconverted[item["currency"] or "?"] += item["personal_price"]
            continue
        if item["personal_sgd"] == 0:
            continue  # paid entirely for someone else: not personal spend anywhere
        own[item["category_id"]] += item["personal_sgd"]
        count[item["category_id"]] += 1

    def build(category_id: int) -> dict:
        category = index[category_id]
        children = [build(c) for c in category["children"]]
        children.sort(key=lambda n: (n["kind"] == "misc", -n["total_sgd"], n["sort_order"]))
        node_own = own.get(category_id, 0.0)
        total = node_own + sum(c["total_sgd"] for c in children)  # before the Unsorted child below, which holds node_own again
        node_count = count.get(category_id, 0) + sum(c["count"] for c in children)
        if children and node_own > 0:
            children.append({
                "id": None, "unsorted_of": category_id, "name": "Unsorted", "icon": "?", "kind": "unsorted",
                "color": category["effective_color"], "budget_sgd": None, "sort_order": 999,
                "own_sgd": _round(node_own), "total_sgd": _round(node_own), "count": count[category_id],
                "children": [],
            })
        return {
            "id": category_id, "name": category["name"], "icon": category["icon"], "kind": category["kind"],
            "color": category["effective_color"], "budget_sgd": category["budget_sgd"],
            "sort_order": category["sort_order"], "parent_id": category["parent_id"],
            "own_sgd": _round(node_own),
            "total_sgd": _round(total),
            "count": node_count,
            "children": children,
        }

    roots = sorted((c for c in index.values() if c["parent_id"] is None), key=lambda c: (c["sort_order"], c["id"]))
    tree = [build(c["id"]) for c in roots]
    return {
        "roots": tree,
        "unsorted_sgd": _round(own.get(None, 0.0)),
        "unsorted_count": count.get(None, 0),
        "total_sgd": _round(sum(n["total_sgd"] for n in tree) + own.get(None, 0.0)),
        "unconverted": {cur: _round(amount) for cur, amount in unconverted.items()},
    }


# ---- usual spending ----

def _usual(items: List[dict], month: str) -> dict:
    """Average monthly spend per top-level category over the months before `month`, plus cumulative-by-day
    for the total. {} fields are empty when there's no history yet."""
    per_month: Dict[str, Dict[Optional[int], float]] = defaultdict(lambda: defaultdict(float))
    per_month_days: Dict[str, Dict[int, float]] = defaultdict(lambda: defaultdict(float))
    for item in _counted(items):
        key = _month_key(item["receipt"]["date"])
        if key >= month:
            continue
        per_month[key][item["category_root_id"]] += item["personal_sgd"]
        per_month_days[key][int(item["receipt"]["date"][8:10])] += item["personal_sgd"]

    months = sorted(per_month)[-USUAL_MONTHS:]
    if not months:
        return {"months": 0, "by_root": {}, "total": None, "cumulative": []}

    roots = {r for m in months for r in per_month[m]}
    by_root = {r: sum(per_month[m].get(r, 0.0) for m in months) / len(months) for r in roots}

    _, this_days = _month_bounds(month)
    cumulative = []
    for day in range(1, this_days + 1):
        values = []
        for m in months:
            values.append(sum(v for d, v in per_month_days[m].items() if d <= day))
        cumulative.append(_round(sum(values) / len(values)))
    return {"months": len(months), "by_root": by_root, "total": sum(by_root.values()), "cumulative": cumulative}


def _cumulative(items: List[dict], month: str, upto_day: int) -> List[float]:
    _, days = _month_bounds(month)
    daily = [0.0] * days
    for item in _counted(items):
        if _month_key(item["receipt"]["date"]) == month:
            daily[int(item["receipt"]["date"][8:10]) - 1] += item["personal_sgd"]
    running, out = 0.0, []
    for day in range(min(upto_day, days)):
        running += daily[day]
        out.append(_round(running))
    return out


# ---- balance reconciliation ----

def _movement_since(conn: sqlite3.Connection, last_txn_id: int) -> float:
    """Net cash movement of transactions the last reconciliation didn't know about yet. An expense is
    money out; every other type (reimbursement, income, refund, own-account transfer, other) is money in."""
    total = 0.0
    for amount, kind in conn.execute(
        "SELECT amount_sgd, transaction_type FROM youtrip_transactions WHERE id > ?", (last_txn_id,)
    ):
        total += (-abs(amount or 0)) if kind == "expense" else abs(amount or 0)
    return total


def current_balance(conn: sqlite3.Connection) -> Optional[dict]:
    """The balance implied right now: the last real balance the user typed in, moved by every
    transaction recorded since. None until they've reconciled at least once."""
    row = conn.execute(
        "SELECT reconciled_on, actual_sgd, last_txn_id FROM balance_reconciliations ORDER BY id DESC LIMIT 1"
    ).fetchone()
    if not row:
        return None
    reconciled_on, actual, last_txn_id = row
    return {
        "implied_sgd": _round(actual + _movement_since(conn, last_txn_id)),
        "reconciled_on": reconciled_on,
        "reconciled_sgd": actual,
    }


def reconcile_balance(conn: sqlite3.Connection, actual_sgd: float, on_date: Optional[str] = None) -> dict:
    """Records the user's real balance. The first one is just a baseline. After that, whatever the
    tracked transactions can't explain becomes 'untracked' - no merchant, date or category invented."""
    on_date = on_date or date.today().isoformat()
    current = current_balance(conn)
    implied = current["implied_sgd"] if current else None
    gap = _round(implied - actual_sgd) if implied is not None else 0.0  # positive = money missing
    last_txn_id = conn.execute("SELECT COALESCE(MAX(id), 0) FROM youtrip_transactions").fetchone()[0]
    conn.execute(
        """
        INSERT INTO balance_reconciliations (reconciled_on, actual_sgd, implied_sgd, untracked_sgd, last_txn_id)
        VALUES (?, ?, ?, ?, ?)
        """,
        (on_date, actual_sgd, implied, gap, last_txn_id),
    )
    conn.commit()
    return {"implied_sgd": implied, "actual_sgd": actual_sgd, "untracked_sgd": gap, "first": implied is None}


def list_reconciliations(conn: sqlite3.Connection) -> List[dict]:
    return [
        {"id": r[0], "reconciled_on": r[1], "actual_sgd": r[2], "implied_sgd": r[3], "untracked_sgd": r[4]}
        for r in conn.execute(
            "SELECT id, reconciled_on, actual_sgd, implied_sgd, untracked_sgd FROM balance_reconciliations ORDER BY id DESC"
        )
    ]


def _untracked_in_month(conn: sqlite3.Connection, month: str) -> float:
    """Missing money found by reconciliations dated in this month. Extra money (a negative gap) is not
    spending, so it never shows here."""
    total = 0.0
    for on_date, gap in conn.execute("SELECT reconciled_on, untracked_sgd FROM balance_reconciliations"):
        if on_date and on_date[:7] == month and gap > 0:
            total += gap
    return total


# ---- activity feed ----

def _group_items(items: List[dict]) -> Tuple[Dict[int, List[dict]], Dict[int, List[dict]]]:
    by_transaction: Dict[int, List[dict]] = defaultdict(list)
    by_receipt: Dict[int, List[dict]] = defaultdict(list)
    for item in items:
        transaction_id = item["receipt"]["transaction_id"]
        if transaction_id is not None:
            by_transaction[transaction_id].append(item)
        elif item["receipt"]["id"] is not None:
            by_receipt[item["receipt"]["id"]].append(item)
    return by_transaction, by_receipt


def _category_of(items: List[dict]) -> Optional[dict]:
    """One category to show for a group of items: their shared one, else the one with the most money
    (flagged mixed so the UI can say '3 categories')."""
    counted = [i for i in items if not i["is_deposit"]]
    if not counted:
        return None
    ids = {i["category_id"] for i in counted}
    top = max(counted, key=lambda i: abs(i["price_sgd"] or 0))
    return {
        "id": top["category_id"], "path": top["category_path"], "color": top["category_color"],
        "icon": top["category_icon"], "confidence": top["category_confidence"],
        "mixed": len(ids) > 1, "distinct": len(ids),
    }


def activity_feed(conn: sqlite3.Connection, limit: Optional[int] = None) -> List[dict]:
    items = ledger._all_items(conn)
    by_transaction, by_receipt = _group_items(items)
    entries = []

    for t in ledger.list_transactions(conn):
        group = by_transaction.get(t["id"], []) + [i for i in items if i["id"] == -t["id"]]
        counted = [i for i in group if not i["is_deposit"]]
        parsed = parse_date(t["date"])
        entries.append({
            "kind": "transaction", "id": t["id"], "date": parsed.isoformat() if parsed else None,
            "title": t["description"] or "Unknown charge", "amount_sgd": t["amount_sgd"],
            "local_amount": t["local_amount"], "local_currency": t["local_currency"],
            "type": t["type"], "status": t["status"], "trip": t["trip"], "note": t["note"],
            "user_note": t["user_note"], "receipt": t["receipt"],
            "personal_sgd": _round(sum(i["personal_sgd"] or 0 for i in counted)),
            "others_sgd": _round(sum(i["others_sgd"] or 0 for i in counted)),
            "item_count": len(counted), "category": _category_of(group),
        })

    for receipt_id, group in by_receipt.items():
        counted = [i for i in group if not i["is_deposit"]]
        receipt = group[0]["receipt"]
        entries.append({
            "kind": "receipt", "id": receipt_id, "date": receipt["date"], "title": receipt["merchant"] or "Receipt",
            "amount_sgd": _round(sum(i["price_sgd"] or 0 for i in counted)) if all(i["price_sgd"] is not None for i in counted) else None,
            "type": "expense", "status": "receipt_only", "trip": group[0]["trip"],
            "personal_sgd": _round(sum(i["personal_sgd"] or 0 for i in counted)),
            "others_sgd": _round(sum(i["others_sgd"] or 0 for i in counted)),
            "item_count": len(counted), "category": _category_of(group),
        })

    entries.sort(key=lambda e: (e["date"] or "", e["id"]), reverse=True)
    return entries[:limit] if limit else entries


# ---- needs a look ----

def review_list(conn: sqlite3.Connection, month: Optional[str] = None) -> dict:
    """What the app isn't sure about, biggest money first: items whose category is only a guess or
    unknown, and card charges it linked to a receipt but wants confirmed. month ('YYYY-MM') limits the
    items to one month, so the numbers agree with what Home shows for it."""
    items = ledger._all_items(conn)
    if month:
        items = [i for i in items if i["receipt"]["date"] and _month_key(i["receipt"]["date"]) == month]
    uncertain = sorted(
        (i for i in items if not i["is_deposit"] and (i["personal_sgd"] or 0) > 0 and i["category_confidence"] != "confirmed"),
        key=lambda i: i["personal_sgd"], reverse=True,
    )
    matches = [t for t in ledger.list_transactions(conn) if t["status"] == "needs_review"]
    confident = sum(
        i["personal_sgd"] or 0 for i in items
        if not i["is_deposit"] and i["category_confidence"] == "confirmed"
    )
    return {
        "items": uncertain,
        "matches": matches,
        "uncertain_sgd": _round(sum(i["personal_sgd"] for i in uncertain)),
        "confident_sgd": _round(confident),
        "suggestions": sum(1 for i in uncertain if i["category_confidence"] == "suggested"),
        "unknown": sum(1 for i in uncertain if i["category_confidence"] == "unknown"),
    }


# ---- home ----

def home(conn: sqlite3.Connection, month: Optional[str] = None, today: Optional[date] = None) -> dict:
    today = today or date.today()
    current_month = today.strftime("%Y-%m")
    month = month or current_month
    all_items = ledger._all_items(conn)
    usual = _usual(all_items, month)
    fraction, elapsed_days = _elapsed(month, today)
    _, days_in_month = _month_bounds(month)

    index = cats.category_index(conn)
    month_items = [i for i in _counted(all_items) if _month_key(i["receipt"]["date"]) == month and i["personal_sgd"] > 0]

    actual: Dict[Optional[int], float] = defaultdict(float)
    for item in month_items:
        actual[item["category_root_id"]] += item["personal_sgd"]

    rows = []
    roots = sorted((c for c in index.values() if c["parent_id"] is None), key=lambda c: (c["sort_order"], c["id"]))
    for root in roots:
        spent = actual.get(root["id"], 0.0)
        usual_sgd = usual["by_root"].get(root["id"])
        budget = root["budget_sgd"]
        reference, kind = (budget, "budget") if budget else ((usual_sgd, "usual") if usual_sgd else (None, None))
        if spent <= 0 and not (usual_sgd and usual_sgd > 0):
            continue
        rows.append({
            "id": root["id"], "name": root["name"], "icon": root["icon"], "color": root["effective_color"],
            "actual_sgd": _round(spent), "budget_sgd": budget,
            "usual_sgd": _round(usual_sgd) if usual_sgd else None,
            "reference_sgd": _round(reference) if reference else None, "reference_kind": kind,
        })

    unsorted_sgd = actual.get(None, 0.0)
    untracked_sgd = _untracked_in_month(conn, month)
    total = sum(actual.values()) + untracked_sgd

    # projection and the health of the month against what's usual (or budgeted)
    if fraction >= 1:
        projected = total
    elif fraction <= 0:
        projected = 0.0
    elif elapsed_days >= MIN_PROJECTION_DAY:
        projected = total / fraction
    else:
        projected = max(total, usual["total"] or total)
    budgets = [r["budget_sgd"] for r in rows if r["budget_sgd"]]
    reference_total = usual["total"] if usual["total"] else (sum(budgets) if budgets else None)
    if reference_total and projected:
        ratio = projected / reference_total
        status = "good" if ratio <= 1.0 else "watch" if ratio <= WATCH_RATIO else "over"
    else:
        status = "neutral"

    actual_cumulative = _cumulative(all_items, month, elapsed_days) if fraction > 0 else []
    if untracked_sgd and actual_cumulative:
        actual_cumulative = [_round(v + untracked_sgd) for v in actual_cumulative]

    # what moved most against usual, scaled to how much of the month has happened
    compared = []
    if usual["months"] and fraction > 0:
        for root in roots:
            expected = (usual["by_root"].get(root["id"]) or 0.0) * fraction
            delta = actual.get(root["id"], 0.0) - expected
            if abs(delta) >= 1:
                compared.append({"id": root["id"], "name": root["name"], "icon": root["icon"],
                                 "color": root["effective_color"], "delta_sgd": _round(delta)})
        compared.sort(key=lambda c: abs(c["delta_sgd"]), reverse=True)

    review = review_list(conn)
    month_uncertain = [i for i in month_items if i["category_confidence"] != "confirmed"]
    uncertain_sgd = sum(i["personal_sgd"] for i in month_uncertain)
    balance = current_balance(conn)
    reimbursements = ledger.reimbursement_summary(conn)
    active = get_active_trip(conn)

    first_month = min((_month_key(i["receipt"]["date"]) for i in _counted(all_items)), default=None)
    return {
        "month": month, "label": _month_label(month), "is_current": month == current_month,
        "prev_month": _shift_month(month, -1) if first_month and first_month < month else None,
        "next_month": _shift_month(month, 1) if month < current_month else None,
        "has_data": bool(all_items) or bool(ledger.list_transactions(conn)),
        "day_label": today.strftime("%-d %b") if month == current_month else _month_label(month),
        "elapsed_fraction": _round(fraction), "elapsed_days": elapsed_days, "days_in_month": days_in_month,
        "total_sgd": _round(total),
        "categories": rows,
        "unsorted_sgd": _round(unsorted_sgd), "untracked_sgd": _round(untracked_sgd),
        "status": status, "projected_sgd": _round(projected), "usual_total_sgd": _round(usual["total"]) if usual["total"] else None,
        "usual_months": usual["months"],
        "this_month": {
            "spent_sgd": _round(total),
            "balance": balance,
            "owed_back_sgd": max(0.0, reimbursements["outstanding_sgd"]),
        },
        "pace": {
            "actual": actual_cumulative, "usual": usual["cumulative"], "projected_sgd": _round(projected),
            "days_in_month": days_in_month,
            "balance_after_sgd": _round(balance["implied_sgd"] - max(0.0, projected - total)) if balance and fraction < 1 else None,
        },
        "needs_look": {
            "uncertain_sgd": _round(uncertain_sgd),
            "confident_sgd": _round(sum(i["personal_sgd"] for i in month_items) - uncertain_sgd),
            "suggestions": sum(1 for i in month_uncertain if i["category_confidence"] == "suggested"),
            "unknown": sum(1 for i in month_uncertain if i["category_confidence"] == "unknown"),
            "matches": len(review["matches"]),
        },
        "compared": compared[:4],
        "recent": activity_feed(conn, limit=5),
        "active_trip": {"id": active.id, "name": active.name} if active else None,
    }


# ---- search ----

def search(conn: sqlite3.Connection, query: str, limit: int = 40) -> dict:
    """One box across transactions, receipt items, receipts, merchants, categories and trips. Matching is
    a plain case-insensitive substring on each field - predictable, and there's no model behind it."""
    needle = (query or "").strip().lower()
    if not needle:
        return {"query": query, "items": [], "transactions": [], "receipts": [], "trips": []}

    items = ledger._all_items(conn)
    matched_items = []
    for item in items:
        haystack = " ".join([
            item["name"] or "", item["receipt"]["merchant"] or "", " ".join(item["tags"]),
            " ".join(item["category_path"]), (item["trip"] or {}).get("name") or "",
        ]).lower()
        if needle in haystack:
            matched_items.append(item)
    matched_items.sort(key=lambda i: i["receipt"]["date"] or "", reverse=True)

    transactions = [
        e for e in activity_feed(conn)
        if e["kind"] == "transaction" and needle in " ".join([
            e["title"] or "", e.get("user_note") or "", (e["trip"] or {}).get("name") or "",
            " ".join((e["category"] or {}).get("path") or []),
        ]).lower()
    ]

    receipts: Dict[int, dict] = {}
    for item in matched_items:
        rid = item["receipt"]["id"]
        if rid is None:
            continue
        entry = receipts.setdefault(rid, {
            "id": rid, "merchant": item["receipt"]["merchant"], "date": item["receipt"]["date"],
            "transaction_id": item["receipt"]["transaction_id"], "matched_items": 0,
        })
        entry["matched_items"] += 1

    trips = [t for t in ledger.trip_summaries(conn) if needle in (t["name"] or "").lower()]
    return {
        "query": query, "items": matched_items[:limit], "transactions": transactions[:limit],
        "receipts": list(receipts.values())[:limit], "trips": trips,
    }


# ---- trends ----

RANGE_MONTHS = {"1M": 1, "3M": 3, "6M": 6, "1Y": 12}


def trends(conn: sqlite3.Connection, range_key: str = "1M", today: Optional[date] = None) -> dict:
    today = today or date.today()
    current_month = today.strftime("%Y-%m")
    all_items = ledger._all_items(conn)
    counted = [i for i in _counted(all_items) if i["personal_sgd"] > 0]

    by_month: Dict[str, float] = defaultdict(float)
    for item in counted:
        by_month[_month_key(item["receipt"]["date"])] += item["personal_sgd"]

    if range_key == "All":
        first = min(by_month, default=current_month)
        months = []
        cursor = first
        while cursor <= current_month:
            months.append(cursor)
            cursor = _shift_month(cursor, 1)
    else:
        n = RANGE_MONTHS.get(range_key, 1)
        months = [_shift_month(current_month, -k) for k in range(n - 1, -1, -1)]

    usual = _usual(all_items, current_month)
    fraction, elapsed_days = _elapsed(current_month, today)
    series = [{"month": m, "label": _month_label(m)[:3] + (" " + m[2:4] if range_key in ("1Y", "All") else ""),
               "total_sgd": _round(by_month.get(m, 0.0))} for m in months]

    # per-category movement of this month against usual
    index = cats.category_index(conn)
    actual: Dict[Optional[int], float] = defaultdict(float)
    for item in counted:
        if _month_key(item["receipt"]["date"]) == current_month:
            actual[item["category_root_id"]] += item["personal_sgd"]
    category_changes = []
    for root in sorted((c for c in index.values() if c["parent_id"] is None), key=lambda c: (c["sort_order"], c["id"])):
        spent = actual.get(root["id"], 0.0)
        expected = (usual["by_root"].get(root["id"]) or 0.0) * fraction
        if spent or expected:
            category_changes.append({
                "id": root["id"], "name": root["name"], "icon": root["icon"], "color": root["effective_color"],
                "actual_sgd": _round(spent), "delta_sgd": _round(spent - expected) if usual["months"] else None,
            })
    category_changes.sort(key=lambda c: abs(c["delta_sgd"] or 0) or c["actual_sgd"], reverse=True)

    # average daily spend and weekday pattern over the selected window
    window_start = date.fromisoformat(months[0] + "-01")
    in_window = [i for i in counted if window_start.isoformat() <= i["receipt"]["date"] <= today.isoformat()]
    days_covered = max(1, (today - window_start).days + 1)
    weekday_totals: Dict[int, float] = defaultdict(float)
    for item in in_window:
        weekday_totals[date.fromisoformat(item["receipt"]["date"]).weekday()] += item["personal_sgd"]
    weekday_counts = defaultdict(int)
    for offset in range(days_covered):
        weekday_counts[(window_start + timedelta(days=offset)).weekday()] += 1
    weekdays = [
        {"weekday": w, "label": calendar.day_abbr[w], "avg_sgd": _round(weekday_totals.get(w, 0.0) / weekday_counts[w]) if weekday_counts[w] else 0.0}
        for w in range(7)
    ]

    # recurring: the same merchant/item turning up in different months at a similar price
    groups: Dict[str, List[dict]] = defaultdict(list)
    for item in counted:
        merchant = item["receipt"]["merchant"]
        label = item["name"] if merchant in (None, "No receipt yet") else merchant
        groups[label.strip().lower()].append(item)
    recurring = []
    for label, group in groups.items():
        distinct_months = {_month_key(i["receipt"]["date"]) for i in group}
        amounts = [i["personal_sgd"] for i in group]
        typical = median(amounts)
        similar = [a for a in amounts if typical and abs(a - typical) / typical <= 0.25]
        if len(distinct_months) >= 2 and len(similar) >= 2:
            recurring.append({"name": group[0]["receipt"]["merchant"] if group[0]["receipt"]["merchant"] not in (None, "No receipt yet") else group[0]["name"],
                              "months": len(distinct_months), "count": len(group), "typical_sgd": _round(typical)})
    recurring.sort(key=lambda r: (r["months"], r["typical_sgd"]), reverse=True)

    trips = sorted(ledger.trip_summaries(conn), key=lambda t: t["start_date"] or "")
    return {
        "range": range_key, "months": series, "current_month": current_month,
        "usual_monthly_sgd": _round(usual["total"]) if usual["total"] else None,
        "daily": {
            "actual": _cumulative(all_items, current_month, elapsed_days), "usual": usual["cumulative"],
            "days_in_month": _month_bounds(current_month)[1], "today_day": elapsed_days,
        },
        "this_month_sgd": _round(by_month.get(current_month, 0.0)),
        "avg_daily_sgd": _round(sum(i["personal_sgd"] for i in in_window) / days_covered),
        "weekdays": weekdays,
        "category_changes": category_changes,
        "recurring": recurring[:6],
        "trips": [{"id": t["id"], "name": t["name"], "start_date": t["start_date"], "spend_sgd": t["spend_sgd"], "emoji": t["emoji"], "color": t["color"]} for t in trips],
    }


# ---- trip detail ----

def trip_detail(conn: sqlite3.Connection, trip_id: int) -> Optional[dict]:
    trip = next((t for t in ledger.trip_summaries(conn) if t["id"] == trip_id), None)
    if not trip:
        return None
    items = [i for i in ledger.list_items(conn, trip_id=trip_id) if not i["is_deposit"]]
    tree = category_tree(conn, trip_id=trip_id)
    feed = [e for e in activity_feed(conn) if (e.get("trip") or {}).get("id") == trip_id]
    return {
        "trip": trip,
        "spend_sgd": trip["spend_sgd"],
        "fronted_sgd": _round(sum(i["others_sgd"] or 0 for i in items)),
        "categories": [n for n in tree["roots"] if n["total_sgd"] > 0],
        "unsorted_sgd": tree["unsorted_sgd"],
        "transactions": feed,
    }


def travel_summary(conn: sqlite3.Connection) -> dict:
    """Both Travel views over the same records: personal spend per trip, and per category across all
    trips. Nothing is duplicated - a transaction is one record seen through two groupings."""
    trips = ledger.trip_summaries(conn)
    tree = category_tree(conn)
    items = [i for i in ledger.list_items(conn) if i["trip"] and not i["is_deposit"] and i["personal_sgd"]]
    by_root: Dict[Optional[int], float] = defaultdict(float)
    for item in items:
        by_root[item["category_root_id"]] += item["personal_sgd"]
    index = cats.category_index(conn)
    categories = [
        {"id": root_id, "name": index[root_id]["name"] if root_id in index else "Unsorted",
         "icon": index[root_id]["icon"] if root_id in index else "?",
         "color": index[root_id]["effective_color"] if root_id in index else None, "spend_sgd": _round(amount)}
        for root_id, amount in by_root.items()
    ]
    categories.sort(key=lambda c: c["spend_sgd"], reverse=True)
    travel_total = _round(sum(t["spend_sgd"] for t in trips))
    return {
        "trips": trips, "categories": categories, "travel_total_sgd": travel_total,
        "share_of_spending": round(travel_total / tree["total_sgd"] * 100, 1) if tree["total_sgd"] else 0,
    }
