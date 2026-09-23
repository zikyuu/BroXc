"""Date parsing shared by the matcher and the ledger."""

import re
from datetime import date
from typing import Optional

from dateutil import parser as date_parser


def parse_date(value: Optional[str]) -> Optional[date]:
    """Receipts print dates as 2026-08-21 or 21.08.2026; YouTrip writes '07 Sep 2026'. ISO is read
    directly (dateutil's dayfirst flag would swap its month and day); anything else is read
    day-first, since that's how the European receipts this app sees write ambiguous dates."""
    if not value:
        return None
    try:
        if re.match(r"\d{4}-\d{2}-\d{2}", value):
            return date.fromisoformat(value[:10])
        return date_parser.parse(value, fuzzy=True, dayfirst=True).date()
    except (ValueError, OverflowError):
        return None
