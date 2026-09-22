from __future__ import annotations

import fcntl
import json
import os
from datetime import datetime, timedelta, timezone
from typing import Any

from .config import (
    APP_HOME,
    IMPORT_DIR,
    SKIP_RETRY_HOURS,
    WORKER_BATCH_SIZE,
    WORKER_STATUS_PATH,
    ensure_app_dirs,
)
from .db import Database
from .indexer import index_assets, pending_annotation_assets
from .native import export_library_photos
from .qwen import QwenClient
from .providers import load_provider
from .sources import import_photos_manifest


LOCK_PATH = APP_HOME / "worker.lock"
FULL_IMPORT_DIR = IMPORT_DIR / "photos-full"
PHOTO_SOURCE_KINDS = {"apple-photos-full"}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_worker_status() -> dict[str, Any]:
    if not WORKER_STATUS_PATH.is_file():
        return {
            "status": "not_started",
            "stage": "idle",
            "message": "The full-library worker has not started yet.",
        }
    try:
        state = json.loads(WORKER_STATUS_PATH.read_text(encoding="utf-8"))
        if state.get("status") == "running" and state.get("stage") == "exporting":
            state["exported_previews"] = sum(1 for _ in FULL_IMPORT_DIR.glob("*.jpg"))
        return state
    except (OSError, json.JSONDecodeError) as error:
        return {"status": "unknown", "stage": "status", "message": str(error)}


def write_worker_status(state: dict[str, Any]) -> None:
    ensure_app_dirs()
    payload = {**state, "updated_at": now_iso()}
    temporary = WORKER_STATUS_PATH.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, WORKER_STATUS_PATH)


def update_rate(state: dict[str, Any], annotated: int) -> None:
    state.setdefault("index_started_at", now_iso())
    state.setdefault("index_start_annotated", annotated)
    started = datetime.fromisoformat(str(state["index_started_at"]))
    elapsed = max(0.001, (datetime.now(timezone.utc) - started).total_seconds())
    processed = max(0, annotated - int(state["index_start_annotated"]))
    if processed == 0:
        return
    per_second = processed / elapsed
    remaining = max(0, int(state.get("library_images", annotated)) - annotated)
    state["rate_per_hour"] = round(per_second * 3600, 1)
    state["eta_at"] = (datetime.now(timezone.utc) + timedelta(seconds=remaining / per_second)).isoformat()


def run_full_library_worker() -> dict[str, Any]:
    ensure_app_dirs()
    with LOCK_PATH.open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {"status": "already_running", "stage": "lock"}

        state = load_worker_status()
        provider = load_provider()
        state.setdefault("started_at", now_iso())
        state.pop("last_error", None)
        state.pop("next_retry_at", None)
        try:
            state.update(
                status="running",
                stage="syncing",
                message="Checking Apple Photos for new images and resumable previews.",
            )
            write_worker_status(state)
            result = export_library_photos(FULL_IMPORT_DIR, 1_000_000, "all")
            state.update(
                stage="importing",
                message="Updating the private SQLite index from the Photos manifest.",
                library_images=int(result.get("library_images", 0)),
                exported=int(result.get("exported", 0)),
                export_failed=int(result.get("failed", 0)),
            )
            write_worker_status(state)
            with Database() as db:
                imported = import_photos_manifest(
                    db,
                    FULL_IMPORT_DIR / "manifest.jsonl",
                    "apple-photos-full",
                    sampling_strategy="full-library-v1",
                )
                retry_before = (
                    datetime.now(timezone.utc) - timedelta(hours=SKIP_RETRY_HOURS)
                ).isoformat()
                released_skips = db.release_processing_skips("index", retry_before)
                counts = db.pipeline_counts("apple-photos-full")
                pending = pending_annotation_assets(
                    db,
                    provider,
                    source_kinds=PHOTO_SOURCE_KINDS,
                )
            state.update(
                full_import_complete=True,
                last_sync_at=now_iso(),
                library_images=int(result.get("library_images", imported)),
                imported=imported,
                pending=len(pending),
                batch_size=WORKER_BATCH_SIZE,
                auto_retried_skips=released_skips,
                provider_id=provider.id,
                provider_name=provider.name,
                provider_model=provider.model,
                **counts,
            )
            write_worker_status(state)

            if not pending:
                completed_status = "complete_with_errors" if counts["skipped"] else "complete"
                state.update(
                    status=completed_status,
                    stage="complete",
                    message="Photo index is up to date. The next scheduled run will check for new Photos.",
                    finished_at=now_iso(),
                    embeddings="deferred_manual_gpu_swap",
                )
                write_worker_status(state)
                return state

            state.update(
                status="running",
                stage="checking_model",
                message="Checking the private Qwen service before indexing.",
            )
            write_worker_status(state)
            QwenClient(provider).models()

            with Database() as db:
                counts = db.pipeline_counts("apple-photos-full")
                update_rate(state, counts["annotated"])
                state.update(
                    status="running",
                    stage="indexing",
                    message="Running Apple Vision OCR and Qwen structured annotations.",
                    **counts,
                )
                write_worker_status(state)

                def progress(message: str) -> None:
                    current_counts = db.pipeline_counts("apple-photos-full")
                    update_rate(state, current_counts["annotated"])
                    state.update(message=message, **current_counts)
                    write_worker_status(state)
                    print(message, flush=True)

                index_assets(
                    db,
                    limit=WORKER_BATCH_SIZE,
                    source_kinds=PHOTO_SOURCE_KINDS,
                    halt_on_error=True,
                    pending_only=True,
                    provider=provider,
                    progress=progress,
                )
                counts = db.pipeline_counts("apple-photos-full")
                pending = pending_annotation_assets(
                    db,
                    provider,
                    source_kinds=PHOTO_SOURCE_KINDS,
                )

            complete = not pending
            completed_status = "complete_with_errors" if counts["skipped"] else "complete"
            state.update(
                status=completed_status if complete else "waiting",
                stage="complete" if complete else "indexing",
                message=(
                    "Photo index is up to date. The next scheduled run will check for new Photos."
                    if complete
                    else "This batch is complete; the scheduled worker will continue with the next batch."
                ),
                finished_at=now_iso() if complete else None,
                embeddings="deferred_manual_gpu_swap",
                pending=len(pending),
                **counts,
            )
            write_worker_status(state)
            return state
        except Exception as error:
            retry_at = datetime.now(timezone.utc) + timedelta(minutes=10)
            state.update(
                status="waiting",
                stage=state.get("stage", "unknown"),
                message="Paused after an error; launchd will retry automatically.",
                last_error=f"{type(error).__name__}: {error}",
                next_retry_at=retry_at.isoformat(),
            )
            write_worker_status(state)
            raise
