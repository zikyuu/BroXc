"""Per-item tag suggestions — an append-only correction cache, mirroring MerchantProfileStore.

Two lookup paths: item_tags is an exact-name fast path ("I've seen this item before, reuse
its tags"); tag_cooccurrence tracks which tags have historically appeared together, so a
brand-new item tagged "food" can still surface "meat"/"vege"/"cooked meals" as one-click
suggestions without ever declaring an explicit parent/child hierarchy.
"""

import json
from collections import defaultdict
from pathlib import Path
from typing import Dict, List

DEFAULT_TAG_STORE_PATH = Path("tag_store.json")

# cold-start defaults for common grocery items with zero correction history yet.
# these only match English item names/generic terms — until the translation milestone
# lands, a receipt in Swedish/German/etc. won't hit this dict at all and falls through
# to no suggestion, same as any other never-seen item.
DEFAULT_ITEM_TAGS: Dict[str, List[str]] = {
    "eggs": ["food"],
    "chicken breast": ["food", "meat"],
    "chicken thigh": ["food", "meat"],
    "salmon": ["food", "meat"],
    "onion": ["food", "vege"],
    "onions": ["food", "vege"],
    "toothpaste": ["toiletries"],
}


class TagStore:
    def __init__(self, path: Path = DEFAULT_TAG_STORE_PATH):
        self.path = Path(path)
        self._item_tags: Dict[str, List[str]] = {}
        self._tag_cooccurrence: Dict[str, Dict[str, int]] = {}
        self._load()

    def _load(self) -> None:
        if not self.path.exists():
            return
        with open(self.path, "r", encoding="utf-8") as f:
            raw = json.load(f)
        self._item_tags = raw.get("item_tags", {})
        self._tag_cooccurrence = raw.get("tag_cooccurrence", {})

    def _save(self) -> None:
        raw = {"item_tags": self._item_tags, "tag_cooccurrence": self._tag_cooccurrence}
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump(raw, f, indent=2, ensure_ascii=False, sort_keys=True)

    def suggest(self, item_name: str) -> List[str]:
        """Exact match on a previously-tagged item first, else the built-in cold-start defaults, else nothing."""
        key = item_name.strip().lower()
        if key in self._item_tags:
            return list(self._item_tags[key])
        return list(DEFAULT_ITEM_TAGS.get(key, []))

    def related_tags(self, tags: List[str], limit: int = 5) -> List[str]:
        """Given tags already on an item, rank other tags that have historically co-occurred with them."""
        scores: Dict[str, int] = defaultdict(int)
        for tag in tags:
            for other_tag, count in self._tag_cooccurrence.get(tag, {}).items():
                if other_tag not in tags:
                    scores[other_tag] += count
        return [tag for tag, _ in sorted(scores.items(), key=lambda kv: kv[1], reverse=True)[:limit]]

    def record_correction(self, item_name: str, tags: List[str]) -> None:
        """Called when a user confirms/edits an item's tags in the review UI — updates both lookup paths."""
        key = item_name.strip().lower()
        self._item_tags[key] = list(tags)

        for tag in tags:
            bucket = self._tag_cooccurrence.setdefault(tag, {})
            for other_tag in tags:
                if other_tag != tag:
                    bucket[other_tag] = bucket.get(other_tag, 0) + 1

        self._save()