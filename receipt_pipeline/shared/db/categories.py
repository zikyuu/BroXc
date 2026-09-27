"""The user's category tree: reading it, editing it, and mapping older flat tags onto it.

An item sits at exactly one node (line_items.category_id). Items that predate the tree, or that the
tag store suggested tags for, have no category_id yet - infer_from_tags picks the deepest category
whose name matches one of their tags, and the ledger reports that as a *suggestion*, never as fact.
"""

import sqlite3
from typing import Dict, List, Optional

from .database import TOP_LEVEL_COLORS

# tags people actually type/learned earlier that don't spell a category's name exactly
TAG_ALIASES = {
    "meals out": "eat out", "restaurant": "eat out", "restaurants": "eat out", "cafe": "eat out",
    "vege": "vegetables", "veg": "vegetables", "veggies": "vegetables", "vegetable": "vegetables",
    "groceries": "cooking ingredients", "grocery": "cooking ingredients",
    "gifts": "souvenirs", "gift": "souvenirs", "toiletries": "health",
    "transit": "public transit", "bus": "public transit", "train": "public transit",
    "clothing": "clothes",
}
FALLBACK_COLOR = "#a0a4b0"


def _rows(conn: sqlite3.Connection) -> List[dict]:
    return [
        {"id": r[0], "name": r[1], "parent_id": r[2], "color": r[3], "icon": r[4],
         "budget_sgd": r[5], "kind": r[6], "sort_order": r[7]}
        for r in conn.execute(
            "SELECT id, name, parent_id, color, icon, budget_sgd, kind, sort_order FROM categories ORDER BY sort_order, id"
        )
    ]


def category_index(conn: sqlite3.Connection) -> Dict[int, dict]:
    """id -> category, each carrying its path (names + ids from the top), depth, root id, and an
    effective colour: a sub-category takes its top-level ancestor's colour, because colour is for
    identity and a Meat tile should read as Food at a glance."""
    by_id = {c["id"]: c for c in _rows(conn)}
    for category in by_id.values():
        path, seen, node = [], set(), category
        while node and node["id"] not in seen:
            seen.add(node["id"])
            path.append(node)
            node = by_id.get(node["parent_id"])
        path.reverse()
        category["path"] = [n["name"] for n in path]
        category["path_ids"] = [n["id"] for n in path]
        category["depth"] = len(path) - 1
        category["root_id"] = path[0]["id"]
        category["effective_color"] = path[0]["color"] or FALLBACK_COLOR
        category["children"] = []
    for category in by_id.values():
        parent = by_id.get(category["parent_id"])
        if parent:
            parent["children"].append(category["id"])
    return by_id


def grocery_child(category: dict, index: Dict[int, dict]) -> Optional[dict]:
    return next((index[c] for c in category["children"] if index[c]["kind"] == "grocery"), None)


def name_lookup(index: Dict[int, dict]) -> Dict[str, dict]:
    """lower-cased name -> the deepest category with that name. Misc categories are left out: the
    same name exists under several parents, so a bare "misc" tag can't point at one of them."""
    lookup: Dict[str, dict] = {}
    for category in index.values():
        if category["kind"] == "misc":
            continue
        key = category["name"].lower()
        if key not in lookup or category["depth"] > lookup[key]["depth"]:
            lookup[key] = category
    return lookup


def infer_from_tags(tags: List[str], lookup: Dict[str, dict]) -> Optional[int]:
    """The deepest category any of these tags names, or None ('mystery' and unknown tags don't count)."""
    best = None
    for tag in tags:
        key = TAG_ALIASES.get(tag.strip().lower(), tag.strip().lower())
        category = lookup.get(key)
        if category and (best is None or category["depth"] > best["depth"]):
            best = category
    return best["id"] if best else None


def list_categories(conn: sqlite3.Connection) -> List[dict]:
    index = category_index(conn)
    return [
        {"id": c["id"], "name": c["name"], "parent_id": c["parent_id"], "icon": c["icon"],
         "color": c["effective_color"], "own_color": c["color"], "budget_sgd": c["budget_sgd"],
         "kind": c["kind"], "path": c["path"], "path_ids": c["path_ids"], "depth": c["depth"],
         "root_id": c["root_id"], "sort_order": c["sort_order"]}
        for c in sorted(index.values(), key=lambda c: [(index[i]["sort_order"], i) for i in c["path_ids"]])
    ]  # tree order: each parent right before its children, siblings by sort_order


def create_category(
    conn: sqlite3.Connection, name: str, parent_id: Optional[int] = None,
    icon: Optional[str] = None, color: Optional[str] = None, kind: str = "normal",
) -> int:
    name = name.strip()
    if not name:
        raise ValueError("A category needs a name.")
    if parent_id is not None and not conn.execute("SELECT 1 FROM categories WHERE id = ?", (parent_id,)).fetchone():
        raise ValueError("That parent category doesn't exist.")
    siblings = conn.execute(
        "SELECT LOWER(name) FROM categories WHERE parent_id IS ?", (parent_id,)
    ).fetchall()
    if (name.lower(),) in siblings:
        raise ValueError(f"There's already a “{name}” here.")
    order = conn.execute("SELECT COALESCE(MAX(sort_order), -1) + 1 FROM categories WHERE parent_id IS ?", (parent_id,)).fetchone()[0]
    if parent_id is None and not color:
        color = TOP_LEVEL_COLORS[order % len(TOP_LEVEL_COLORS)]  # top-level colours are stable identity, so pick one now
    cursor = conn.execute(
        "INSERT INTO categories (name, parent_id, color, icon, kind, sort_order) VALUES (?, ?, ?, ?, ?, ?)",
        (name, parent_id, color if parent_id is None else None, icon, kind, order),
    )
    conn.commit()
    return cursor.lastrowid


def update_category(conn: sqlite3.Connection, category_id: int, **fields) -> None:
    """Edits name, icon, colour (top-level only - children inherit), budget, or parent. Only fields
    actually passed change; budget_sgd=None clears the budget."""
    index = category_index(conn)
    if category_id not in index:
        raise ValueError("No such category.")
    changes = {}
    if "name" in fields:
        name = (fields["name"] or "").strip()
        if not name:
            raise ValueError("A category needs a name.")
        changes["name"] = name
    for key in ("icon", "color", "budget_sgd"):
        if key in fields:
            changes[key] = fields[key]
    if "parent_id" in fields:
        new_parent = fields["parent_id"]
        if new_parent is not None and (new_parent not in index or new_parent == category_id
                                       or category_id in index[new_parent]["path_ids"]):
            raise ValueError("A category can't move inside itself.")
        changes["parent_id"] = new_parent
    if not changes:
        return
    assignments = ", ".join(f"{column} = ?" for column in changes)
    conn.execute(f"UPDATE categories SET {assignments} WHERE id = ?", (*changes.values(), category_id))
    conn.commit()


def delete_category(conn: sqlite3.Connection, category_id: int) -> int:
    """Removes a category without losing anything: its sub-categories and items move up to its parent
    (or become unsorted, at the top level). Returns how many items were moved."""
    row = conn.execute("SELECT parent_id, color FROM categories WHERE id = ?", (category_id,)).fetchone()
    if not row:
        raise ValueError("No such category.")
    parent_id, color = row
    conn.execute("UPDATE categories SET parent_id = ? WHERE parent_id = ?", (parent_id, category_id))
    if parent_id is None:  # promoted to top level: they were inheriting this colour, so keep it
        conn.execute("UPDATE categories SET color = COALESCE(color, ?) WHERE parent_id IS NULL AND color IS NULL", (color,))
    moved = conn.execute(
        "UPDATE line_items SET category_id = ? WHERE category_id = ?", (parent_id, category_id)
    ).rowcount
    conn.execute("DELETE FROM categories WHERE id = ?", (category_id,))
    conn.commit()
    return moved
