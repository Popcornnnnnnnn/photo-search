from __future__ import annotations

import json
import os
import time
from datetime import datetime, timezone

from .config import APP_HOME, WORKER_BATCH_SIZE, ensure_app_dirs
from .db import Database
from .embeddings import (
    DIMENSIONS,
    EMBEDDING_MODEL,
    EMBEDDING_NAMESPACE,
    EMBEDDING_PROMPT,
    EMBEDDING_REVISION,
    VIDEO_EMBEDDING_NAMESPACE,
    VIDEO_EMBEDDING_PROMPT,
    index_embeddings,
)

STATUS_PATH = APP_HOME / "embedding-status.json"


def load_embedding_status() -> dict:
    try:
        return json.loads(STATUS_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"status": "not_started"}


def write_embedding_status(state: dict) -> None:
    ensure_app_dirs()
    temporary = STATUS_PATH.with_suffix(".tmp")
    temporary.write_text(json.dumps({**state, "updated_at": datetime.now(timezone.utc).isoformat()}, ensure_ascii=False), encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(STATUS_PATH)


def pending_embedding_count() -> int:
    """Count assets that still need a vector for the pinned model contract."""
    with Database() as db:
        return db.embedding_pending(
            namespace=EMBEDDING_NAMESPACE, model=EMBEDDING_MODEL, revision=EMBEDDING_REVISION,
            prompt=EMBEDDING_PROMPT, dimensions=DIMENSIONS, count=True,
        ) + db.embedding_pending(namespace=VIDEO_EMBEDDING_NAMESPACE, model=EMBEDDING_MODEL,
                                 revision=EMBEDDING_REVISION, prompt=VIDEO_EMBEDDING_PROMPT,
                                 dimensions=DIMENSIONS, count=True, media_type="video")


def run_embedding_batch(limit: int = WORKER_BATCH_SIZE) -> dict:
    """Fill one bounded vector batch; the scheduled worker supplies the cadence."""
    state = {**load_embedding_status(), "status": "running", "pid": os.getpid()}
    state.pop("error", None)
    state.pop("busy", None)
    write_embedding_status(state)
    try:
        started = time.monotonic()
        with Database() as db:
            result = index_embeddings(db, limit=limit)
            skipped = db.conn.execute("SELECT COUNT(*) FROM processing_skips s JOIN assets a ON a.id=s.asset_id WHERE s.stage='embedding' AND a.is_available=1").fetchone()[0]
        state.update(result)
        state.update(skipped=skipped, batch_seconds=round(time.monotonic() - started, 2))
        state["status"] = "waiting" if result.get("busy") else "indexing" if result["pending"] else "complete_with_errors" if skipped else "complete"
    except Exception as error:
        state.update(status="unavailable", error=f"{type(error).__name__}: {error}")
    write_embedding_status(state)
    return state
