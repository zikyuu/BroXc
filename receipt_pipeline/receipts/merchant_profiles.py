'''per mecahnt correction cache'''
'''append only store of HINTS learned from user corrections, not a model being retarained'''

import json
from dataclasses import asdict, dataclass, field 
from pathlib import Path 
from typing import Dict, List, Optional, Tuple

DEFAULT_PROFILE_PATH = Path("merchant_profiles.json")

@dataclass
class MerchantProfile: 
    '''Accumulated hints for one merchant, built entirely from past user corrections'''
    total_keywords : List[str] = field(default_factory=list)  # keywords for the whole receipt, e.g. "Walmart", "Tesco"
    ignore_lines: List[str] = field(default_factory=list)  # lines to ignore, e.g. "Thank you for shopping at"
    item_translations: Dict[str, str] = field(default_factory=dict)  # map of original line text -> translated line text, e.g. "Bananer" -> "Bananas"

class MerchantProfileStore:
    '''loads/saves json file of merchantprofile keyed by merchant name'''
    def __init__(self, path: Path = DEFAULT_PROFILE_PATH):
        self.path = Path(path)
        self._profiles: Dict[str, MerchantProfile] = self._load()

    def _load(self) -> Dict[str, MerchantProfile]:
        if not self.path.exists():
            return {}
        with open(self.path, "r", encoding="utf-8") as f:
            raw = json.load(f)
        return {name: MerchantProfile(**data) for name, data in raw.items()}

    def _save(self) -> None:
        raw = {name: asdict(profile) for name, profile in self._profiles.items()}
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump(raw, f, indent=2, ensure_ascii=False, sort_keys=True)

#get() never raises or returns None
#unknown merchant -> gets an empty MerchantProfile() so parser.py can always call store.get(merchant).total_leywords 
#without a null check, and itll just fall back to whatever generic defaults live in the parser
    def get(self, merchant: str) -> MerchantProfile:
        """Returns this merchant's profile, or an empty one if none exists yet — never raises."""
        return self._profiles.get(merchant, MerchantProfile())

#first call for a new merchant name -> creates the merchant profile 
#tldR: nth exists until a correction actually happens
    def record_correction(
        self,
        merchant: str,
        total_keyword: Optional[str] = None,
        ignore_line: Optional[str] = None,
        item_translation: Optional[Tuple[str, str]] = None,
    ) -> None:
        """Merges one user correction into merchant's profile, creating it on first use."""
        profile = self._profiles.setdefault(merchant, MerchantProfile())

        if total_keyword and total_keyword not in profile.total_keywords:
            profile.total_keywords.append(total_keyword)

        if ignore_line and ignore_line not in profile.ignore_lines:
            profile.ignore_lines.append(ignore_line)

        if item_translation:
            original, translated = item_translation
            profile.item_translations[original] = translated

            self._save() # save after each correction to avoid losing data on crash