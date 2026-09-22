from __future__ import annotations

import json
from pathlib import Path
from typing import Callable

from .config import (
    ANNOTATION_PROMPT_VERSION,
    ANNOTATION_SCHEMA_VERSION,
    OCR_PRODUCER,
    OCR_VERSION,
    PREPROCESS_VERSION,
)
from .db import Database
from .native import run_ocr
from .qwen import QwenClient, ModelProviderError
from .providers import ModelProvider, load_provider


def pending_annotation_assets(
    db: Database,
    provider: ModelProvider,
    *,
    source_kinds: set[str] | None = None,
    limit: int | None = None,
):
    if not provider.reprocess_existing:
        return db.assets_missing_active_artifact(
            kind="annotation",
            source_kinds=source_kinds,
            skip_stage="index",
            limit=limit,
        )
    return db.assets_missing_artifact(
        kind="annotation",
        producer=provider.producer,
        model=provider.model,
        prompt_version=ANNOTATION_PROMPT_VERSION,
        schema_version=ANNOTATION_SCHEMA_VERSION,
        preprocess_version=PREPROCESS_VERSION,
        source_kinds=source_kinds,
        skip_stage="index",
        limit=limit,
    )


def is_transient_error(error: Exception) -> bool:
    if not isinstance(error, ModelProviderError):
        return False
    message = str(error).lower()
    return any(
        marker in message
        for marker in ("request failed", "unavailable", "timed out", "connection", "api error")
    )


def index_assets(
    db: Database,
    *,
    limit: int | None = None,
    source_kinds: set[str] | None = None,
    halt_on_error: bool = False,
    pending_only: bool = False,
    provider: ModelProvider | None = None,
    progress: Callable[[str], None] = print,
) -> dict[str, int]:
    provider = provider or load_provider()
    client = QwenClient(provider)
    stats = {
        "visited": 0, "ocr": 0, "annotated": 0, "skipped": 0,
        "terminal_skipped": 0, "failed": 0,
    }
    if pending_only:
        assets = pending_annotation_assets(
            db,
            provider,
            source_kinds=source_kinds,
            limit=limit,
        )
    else:
        assets = [
            asset for asset in db.assets()
            if source_kinds is None or asset["source_kind"] in source_kinds
        ]
        if limit is not None:
            assets = assets[:limit]
    for asset in assets:
        stats["visited"] += 1
        asset_id = asset["id"]
        image_path = Path(asset["file_path"])
        progress(f"[{stats['visited']}] {asset_id} {asset['filename']}")
        if db.is_processing_skipped(asset_id, "index"):
            stats["terminal_skipped"] += 1
            continue
        try:
            if not db.has_artifact(
                asset_id, "ocr", OCR_PRODUCER, "", OCR_VERSION, "1.0",
                PREPROCESS_VERSION, asset["sha256"],
            ):
                ocr = run_ocr(image_path)
                db.add_artifact(
                    asset_id=asset_id,
                    kind="ocr",
                    producer=OCR_PRODUCER,
                    prompt_version=OCR_VERSION,
                    schema_version="1.0",
                    preprocess_version=PREPROCESS_VERSION,
                    input_sha256=asset["sha256"],
                    data=ocr,
                    raw_text=ocr.get("text", ""),
                )
                stats["ocr"] += 1
            ocr_artifact = db.active_artifact(asset_id, "ocr") or {"data": {}}
            if not db.has_artifact(
                asset_id, "annotation", provider.producer, provider.model,
                ANNOTATION_PROMPT_VERSION, ANNOTATION_SCHEMA_VERSION,
                PREPROCESS_VERSION, asset["sha256"],
            ):
                metadata = json.loads(asset["metadata_json"])
                metadata.update(
                    {
                        "captured_at": asset["captured_at"],
                        "width": asset["width"],
                        "height": asset["height"],
                        "filename": asset["filename"],
                    }
                )
                annotation, raw = client.annotate(
                    image_path,
                    str(ocr_artifact["data"].get("text", "")),
                    metadata,
                )
                db.add_artifact(
                    asset_id=asset_id,
                    kind="annotation",
                    producer=provider.producer,
                    model=provider.model,
                    prompt_version=ANNOTATION_PROMPT_VERSION,
                    schema_version=ANNOTATION_SCHEMA_VERSION,
                    preprocess_version=PREPROCESS_VERSION,
                    input_sha256=asset["sha256"],
                    data=annotation,
                    raw_text=raw,
                )
                stats["annotated"] += 1
            else:
                stats["skipped"] += 1
            db.rebuild_search_doc(asset_id)
        except Exception as error:
            stats["failed"] += 1
            db.record_error(asset_id, "index", repr(error))
            progress(f"  ERROR: {error}")
            if halt_on_error:
                attempts = db.error_count(asset_id, "index")
                if is_transient_error(error) or attempts < 3:
                    raise
                db.mark_processing_skip(asset_id, "index", repr(error))
                progress(f"  ISOLATED after {attempts} deterministic failures")
    return stats
