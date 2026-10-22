from __future__ import annotations

import fcntl
import json
import os
import threading
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
from .qwen import ModelProviderError, QwenClient
from .providers import ModelProvider, load_provider, load_fallback_provider
from .local_model import ensure_local_model, uses_lm_studio
from .sources import import_photos_manifest
from .embedding_worker import load_embedding_status, pending_embedding_count, run_embedding_batch
from .embeddings import embedding_count


LOCK_PATH = APP_HOME / "worker.lock"
FULL_IMPORT_DIR = IMPORT_DIR / "photos-full"
PHOTO_SOURCE_KINDS = {"apple-photos-full"}
_STATUS_LOCK = threading.Lock()


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
    with _STATUS_LOCK:
        ensure_app_dirs()
        payload = {**state, "updated_at": now_iso()}
        temporary = WORKER_STATUS_PATH.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        os.chmod(temporary, 0o600)
        os.replace(temporary, WORKER_STATUS_PATH)


def start_heartbeat(state: dict[str, Any], interval: float = 30):
    """Keep a long local transcription/model call distinct from a stopped worker."""
    stopped = threading.Event()

    def pulse():
        while not stopped.wait(interval):
            if state.get("status") == "running":
                try:
                    write_worker_status(state)
                except OSError:
                    # The main path also writes and reports a status-file failure.
                    pass

    thread = threading.Thread(target=pulse, name="photo-search-worker-heartbeat", daemon=True)
    thread.start()

    def stop():
        stopped.set()
        thread.join(timeout=1)

    return stop


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


def _confirm_model_reachable(provider: ModelProvider, attempts: int = 3) -> None:
    """Verify the private model answers before spending a batch on it.

    A single probe is unreliable here: the tunnel to the 4090 accepts the TCP
    connection and then sometimes never answers, while the model service is
    healthy. Retrying keeps one unlucky sample from pausing indexing for the
    full retry interval.
    """
    last_error: Exception | None = None
    for _ in range(attempts):
        try:
            models = QwenClient(provider).models()
            if not any(item.get("id") == provider.model for item in models.get("data", [])):
                raise ModelProviderError(f"The provider does not offer the configured model {provider.model!r}.")
            return
        except Exception as error:
            last_error = error
    raise last_error if last_error is not None else ModelProviderError("model unreachable")


def sync_due(state: dict[str, Any]) -> bool:
    try:
        last_sync = datetime.fromisoformat(str(state["last_sync_at"]))
        return (datetime.now(timezone.utc) - last_sync).total_seconds() >= 300
    except (KeyError, TypeError, ValueError):
        return True


def select_processing_provider(preferred: ModelProvider, fallback: ModelProvider | None,
                               state: dict[str, Any]) -> ModelProvider:
    state["requested_provider_id"] = preferred.id
    state.pop("fallback_reason", None)
    if fallback is None:
        return preferred
    # A fallback is explicitly configured and must stay on this Mac.
    if not uses_lm_studio(fallback):
        raise ValueError("The fallback provider must be a local LM Studio model.")
    state.update(status="running", stage="checking_model",
                 message=f"Checking preferred provider {preferred.name}.")
    write_worker_status(state)
    try:
        _confirm_model_reachable(preferred)
        return preferred
    except ModelProviderError as error:
        state["fallback_reason"] = str(error)
        return fallback


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
        stop_heartbeat = start_heartbeat(state)
        try:
            if sync_due(state):
                state.update(status="running", stage="syncing", message="Checking Apple Photos for changed or deleted photos and videos.")
                write_worker_status(state)
                result = export_library_photos(FULL_IMPORT_DIR, 1_000_000, "all")
                state.update(stage="importing", message="Updating changed Photos previews and source availability.")
                write_worker_status(state)
                with Database() as db:
                    imported = import_photos_manifest(
                        db, FULL_IMPORT_DIR / "manifest.jsonl", "apple-photos-full",
                        sampling_strategy="full-library-v1", snapshot=result,
                    )
                state.update(
                    full_import_complete=True, last_sync_at=now_iso(),
                    library_images=int(result.get("library_assets", result.get("library_images", imported))),
                    library_videos=int(result.get("library_videos", 0)), imported=imported,
                    export_failed=int(result.get("failed", 0)),
                    regenerated_previews=int(result.get("regenerated", 0)),
                )
            provider = select_processing_provider(provider, load_fallback_provider(), state)
            with Database() as db:
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
                pending=len(pending),
                batch_size=WORKER_BATCH_SIZE,
                auto_retried_skips=released_skips,
                provider_id=provider.id,
                provider_name=provider.name,
                provider_model=provider.model,
                **counts,
            )
            write_worker_status(state)

            if uses_lm_studio(provider):
                state.update(status="running", stage="loading_model",
                             message=f"Loading {provider.model} in LM Studio.")
                write_worker_status(state)
                ensure_local_model(provider)

            if pending_embedding_count():
                state.update(status="running", stage="embedding", message="Filling photo and video vectors for the pinned local encoder.")
                write_worker_status(state)
                run_embedding_batch()

            visual = load_embedding_status()
            # Match the library denominator and refresh after every sync, even
            # when deletions leave no new vectors for the encoder to process.
            with Database() as db:
                embedded = embedding_count(db, source_kind="apple-photos-full")
            state.update(embeddings=visual.get("status"), embedded=embedded,
                         embedding_pending=pending_embedding_count(), embedding_error=visual.get("error"))

            if not pending:
                completed_status = "complete_with_errors" if counts["skipped"] else "complete"
                visual_pending = state.get("embedding_pending") != 0 or bool(state.get("embedding_error"))
                state.update(
                    status="waiting" if visual_pending else completed_status,
                    stage="embedding" if visual_pending else "complete",
                    message=("Text indexing is up to date; visual indexing will continue in scheduled batches."
                             if visual_pending else "Photo index is up to date. The next scheduled run will check for new Photos."),
                    finished_at=None if visual_pending else now_iso(),
                )
                write_worker_status(state)
                return state

            state.update(
                status="running",
                stage="checking_model",
                message=f"Preparing {provider.name} before indexing.",
            )
            write_worker_status(state)
            _confirm_model_reachable(provider)

            with Database() as db:
                counts = db.pipeline_counts("apple-photos-full")
                update_rate(state, counts["annotated"])
                state.update(
                    status="running",
                    stage="indexing",
                    message="Indexing photos and videos, including local speech recognition.",
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

            complete = not pending and state.get("embedding_pending") == 0 and not state.get("embedding_error")
            completed_status = "complete_with_errors" if counts["skipped"] else "complete"
            state.update(
                status=completed_status if complete else "waiting",
                stage="complete" if complete else "indexing" if pending else "embedding",
                message=(
                    "Photo index is up to date. The next scheduled run will check for new Photos."
                    if complete
                    else "This batch is complete; the scheduled worker will continue with the next batch."
                ),
                finished_at=now_iso() if complete else None,
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
        finally:
            stop_heartbeat()
