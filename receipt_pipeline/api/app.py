"""Local web API over the expenses database, and the static frontend that talks to it.

Run from the repo root:  python3 -m uvicorn receipt_pipeline.api.app:app --port 8000
EXPENSES_DB, TAG_STORE and UPLOAD_DIR point it somewhere else (the demo config does).
"""

import os
import shutil
from contextlib import contextmanager
from pathlib import Path
from typing import List, Optional
from uuid import uuid4

from fastapi import FastAPI, File, HTTPException, Query, UploadFile
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from ..matcher import run_matching
from ..receipts.tag_store import TagStore
from ..shared.db import ledger
from ..shared.db.database import DEFAULT_DB_PATH, connect, save_receipt

FRONTEND_DIR = Path(__file__).resolve().parents[2] / "frontend"

app = FastAPI(title="Expense tracker")


@contextmanager
def db():
    """A fresh connection per request - sqlite3 connections can't be shared across threads."""
    conn = connect(Path(os.environ.get("EXPENSES_DB", DEFAULT_DB_PATH)))
    try:
        yield conn
    finally:
        conn.close()


def _tag_store() -> TagStore:
    return TagStore(Path(os.environ.get("TAG_STORE", "tag_store.json")))


def _save_upload(upload: UploadFile) -> str:
    """Keeps the uploaded image on disk so a receipt's source_image_path stays valid."""
    if not (upload.content_type or "").startswith("image/"):
        raise HTTPException(400, f"{upload.filename or 'That file'} isn't an image.")
    directory = Path(os.environ.get("UPLOAD_DIR", "uploads"))
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{uuid4().hex}{Path(upload.filename or '').suffix or '.png'}"
    with path.open("wb") as out:
        shutil.copyfileobj(upload.file, out)
    return str(path)


# ---- reading ----

@app.get("/api/overview")
def overview(start: Optional[str] = None, end: Optional[str] = None):
    with db() as conn:
        return {"status": ledger.status(conn), "summary": ledger.summary(conn, start, end)}


@app.get("/api/items")
def items(start: Optional[str] = None, end: Optional[str] = None):
    with db() as conn:
        return ledger.list_items(conn, start, end)


@app.get("/api/tags")
def tags():
    with db() as conn:
        return ledger.list_tags(conn)


@app.get("/api/tags/related")
def related_tags(tags: List[str] = Query(default=[])):
    """Tags that have historically travelled with the given ones - suggestions for the next tag."""
    return _tag_store().related_tags(tags)


@app.get("/api/transactions")
def transactions():
    with db() as conn:
        return {
            "transactions": ledger.list_transactions(conn),
            "unmatched_receipts": ledger.list_unmatched_receipts(conn),
        }


# ---- editing ----

class TagChange(BaseModel):
    item_ids: List[int]
    add: List[str] = []
    remove: List[str] = []


@app.post("/api/items/tags")
def change_tags(change: TagChange):
    with db() as conn:
        updated = ledger.apply_tag_changes(conn, change.item_ids, change.add, change.remove)
    store = _tag_store()
    for name, item_tags in updated:
        store.record_correction(name, item_tags)  # next receipt with this item starts with these tags
    return {"updated": len(updated)}


class LinkRequest(BaseModel):
    receipt_id: int


@app.post("/api/transactions/{transaction_id}/approve")
def approve(transaction_id: int):
    with db() as conn:
        ledger.approve_match(conn, transaction_id)
    return {"ok": True}


@app.post("/api/transactions/{transaction_id}/unlink")
def unlink(transaction_id: int):
    with db() as conn:
        ledger.unlink_match(conn, transaction_id)
    return {"ok": True}


@app.post("/api/transactions/{transaction_id}/link")
def link(transaction_id: int, request: LinkRequest):
    with db() as conn:
        ledger.link_match(conn, transaction_id, request.receipt_id)
    return {"ok": True}


# ---- uploading (runs OCR, which takes a while, so these are plain `def` - FastAPI runs them in a worker thread) ----

def _match_summary(matches) -> dict:
    return {"matched": len(matches), "needs_review": sum(1 for m in matches if m.needs_review)}


@app.post("/api/upload/receipt")
def upload_receipt(translated: UploadFile = File(...), original: Optional[UploadFile] = File(None)):
    from ..pipeline import run_receipt_pipeline  # heavy OCR imports, only when actually needed

    translated_path = _save_upload(translated)
    original_path = _save_upload(original) if original and original.filename else None
    try:
        draft = run_receipt_pipeline(translated_path, original_path, tag_store=_tag_store())
    except ValueError as error:
        raise HTTPException(400, str(error))

    with db() as conn:
        receipt_id = save_receipt(conn, draft)
        matches = run_matching(conn)
    return {
        "receipt_id": receipt_id,
        "merchant": draft.merchant,
        "date": draft.date,
        "total": draft.total,
        "currency": draft.currency,
        "items": len(draft.line_items),
        **_match_summary(matches),
    }


@app.post("/api/upload/youtrip")
def upload_youtrip(screenshot: UploadFile = File(...)):
    from ..transactions.youtrip_parser import parse_youtrip_screenshot

    path = _save_upload(screenshot)
    try:
        parsed = parse_youtrip_screenshot(path)
    except ValueError as error:
        raise HTTPException(400, str(error))

    with db() as conn:
        inserted, skipped = ledger.save_new_transactions(conn, parsed)
        matches = run_matching(conn)
    return {"found": len(parsed), "added": inserted, "already_had": skipped, **_match_summary(matches)}


# static frontend last, so it never shadows an /api route
app.mount("/", StaticFiles(directory=FRONTEND_DIR, html=True), name="frontend")
