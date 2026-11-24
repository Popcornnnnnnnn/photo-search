from __future__ import annotations

import fcntl
import hashlib
import json
import shutil
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable

from .cleanup_previews import prune_superseded_previews
from .config import APP_HOME, ASSET_DIR, IMPORT_DIR, PREPROCESS_VERSION, ensure_app_dirs
from .db import Database
from .native import export_library_photos, export_recent_photos


SUPPORTED_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".tif", ".tiff"}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def import_recent_photos(db: Database, limit: int) -> int:
    ensure_app_dirs()
    output = IMPORT_DIR / "photos-recent"
    result = export_recent_photos(output, limit)
    return import_photos_manifest(db, Path(result["manifest"]), "apple-photos")


def import_photos_manifest(
    db: Database,
    manifest: Path,
    source_kind: str,
    *,
    sampling_strategy: str | None = None,
    snapshot: dict[str, Any] | None = None,
) -> int:
    imported = 0
    records = [json.loads(line) for line in manifest.read_text(encoding="utf-8").splitlines() if line.strip()]
    ids = {record["id"] for record in records}
    if len(ids) != len(records):
        raise ValueError("Photos manifest contains duplicate IDs")
    complete = bool(snapshot and snapshot.get("full_snapshot"))
    present = set(snapshot.get("present_ids", [])) if snapshot else set()
    failed = set(snapshot.get("failed_ids", [])) if snapshot else set()
    if complete and (snapshot.get("strategy") != "all" or len(present) != snapshot.get("library_assets", snapshot.get("library_images"))
                     or ids | failed != present or ids & failed):
        raise ValueError("Incomplete Photos inventory; refusing deletion reconciliation")
    for record in records:
        is_video = record.get("media_type") == "video"
        # The export cache is already private and durable. Index its one preview
        # directly rather than copying every preview a second time.
        source = Path(record.get("thumbnail_path") or record["path"]) if is_video else Path(record["path"])
        destination = source
        thumbnail = source
        previous = db.get_asset(record["id"])
        old_metadata = json.loads(previous["metadata_json"]) if previous else {}
        stat = source.stat()
        unchanged = bool(previous and destination.is_file() and previous["file_path"] == str(destination)
                         and old_metadata.get("preview_mtime_ns") == stat.st_mtime_ns
                         and old_metadata.get("preview_size") == stat.st_size)
        if is_video:
            # A cover alone cannot identify a video edit (the audio may change).
            # Preserve old content hashes for an unchanged Photos version so its
            # existing annotations and vectors remain valid during migration.
            same_video = bool(previous and old_metadata.get("media_type") == "video"
                              and previous["source_identifier"] == record["local_identifier"]
                              and record.get("modified_at") is not None
                              and old_metadata.get("source_modified_at") == record.get("modified_at")
                              and previous["width"] == record.get("width")
                              and previous["height"] == record.get("height")
                              and old_metadata.get("duration_seconds") == record.get("duration"))
            version = [record["local_identifier"], record.get("modified_at"), record.get("width"),
                       record.get("height"), record.get("duration")]
            digest = (previous["sha256"] if same_video else
                      hashlib.sha256(json.dumps(version, separators=(",", ":")).encode()).hexdigest())
        else:
            # Rehash during migration from the old assets/ path, preserving the
            # digest and derived data if the source preview is identical.
            digest = previous["sha256"] if unchanged else sha256_file(source)
        metadata = {
            "favorite": record.get("favorite", False),
            "media_subtypes": record.get("media_subtypes", 0),
            "preprocess_version": PREPROCESS_VERSION,
            "source_modified_at": record.get("modified_at"),
            "preview_mtime_ns": stat.st_mtime_ns,
            "preview_size": stat.st_size,
        }
        if is_video:
            metadata.update(media_type="video", duration_seconds=record.get("duration"),
                            preprocess_version="video-frames-5s-v1")
        if sampling_strategy:
            metadata["sampling_strategy"] = sampling_strategy
        if unchanged and previous["is_available"] and previous["source_kind"] == source_kind and (
            previous["metadata_json"] == json.dumps(metadata, ensure_ascii=False)
            and all(previous[key] == record.get(key) for key in ("filename", "captured_at", "width", "height"))
        ):
            imported += 1
            continue
        db.upsert_asset(
            {
                "id": record["id"],
                "source_kind": source_kind,
                "source_identifier": record["local_identifier"],
                "file_path": str(destination),
                "thumbnail_path": str(thumbnail),
                "sha256": digest,
                "filename": record["filename"],
                "captured_at": record.get("captured_at"),
                "width": record.get("width"),
                "height": record.get("height"),
                "metadata": metadata,
            }
        )
        imported += 1
    if complete:
        db.reconcile_photos(present, failed_ids=failed,
                            media_types={"image", "video"} if "library_assets" in snapshot else {"image"})
    return imported


def import_library_benchmark_sample(db: Database, limit: int) -> int:
    ensure_app_dirs()
    output = IMPORT_DIR / f"photos-benchmark-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    result = export_library_photos(output, limit, "benchmark")
    return import_photos_manifest(
        db,
        Path(result["manifest"]),
        "apple-photos-benchmark",
        sampling_strategy="benchmark-uniform-plus-screenshots-v1",
    )


def import_full_photos_library(db: Database) -> dict[str, Any]:
    ensure_app_dirs()
    output = IMPORT_DIR / "photos-full"
    with (APP_HOME / "worker.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = export_library_photos(output, 1_000_000, "all")
        manifest = Path(result["manifest"])
        imported = import_photos_manifest(
            db,
            manifest,
            "apple-photos-full",
            sampling_strategy="full-library-v1",
            snapshot=result,
        )
        pruned = prune_superseded_previews(db.conn, output, manifest)
    return {**result, "imported": imported, "pruned_previews": pruned}


def export_photos_selection(limit: int) -> Path:
    """Export up to ``limit`` currently selected Photos assets without private DB access."""
    ensure_app_dirs()
    output = IMPORT_DIR / f"photos-selection-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    output_literal = json.dumps(str(output), ensure_ascii=False)
    script = f"""
tell application "Photos"
    set chosen to selection
    set chosenCount to count chosen
    if chosenCount is 0 then error "Select a few photos in Photos first."
    set sampleCount to {max(1, limit)}
    if chosenCount < sampleCount then set sampleCount to chosenCount
    set sampleItems to items 1 thru sampleCount of chosen
    export sampleItems to POSIX file {output_literal} with using originals
    return sampleCount
end tell
"""
    process = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
        timeout=max(300, limit * 60),
    )
    if process.returncode != 0:
        raise RuntimeError(process.stderr.strip() or "Photos selection export failed")
    return output


def iter_image_paths(inputs: Iterable[str]) -> Iterable[Path]:
    for raw in inputs:
        path = Path(raw).expanduser().resolve()
        if path.is_file() and path.suffix.lower() in SUPPORTED_SUFFIXES:
            yield path
        elif path.is_dir():
            for candidate in sorted(path.rglob("*")):
                if candidate.is_file() and candidate.suffix.lower() in SUPPORTED_SUFFIXES:
                    yield candidate


def _create_jpeg_preview(source: Path, destination: Path) -> None:
    process = subprocess.run(
        ["sips", "-Z", "1600", "-s", "format", "jpeg", str(source), "--out", str(destination)],
        capture_output=True,
        text=True,
        timeout=180,
    )
    if process.returncode != 0:
        raise RuntimeError(process.stderr.strip() or f"Unable to create preview for {source}")


def import_files(
    db: Database,
    inputs: Iterable[str],
    limit: int | None = None,
    *,
    source_kind: str = "file",
) -> int:
    ensure_app_dirs()
    imported = 0
    for source in iter_image_paths(inputs):
        digest = sha256_file(source)
        asset_id = "file-" + digest[:24]
        destination = ASSET_DIR / f"{asset_id}.jpg"
        if not destination.exists():
            _create_jpeg_preview(source, destination)
        db.upsert_asset(
            {
                "id": asset_id,
                "source_kind": source_kind,
                "source_identifier": str(source),
                "file_path": str(destination),
                "thumbnail_path": str(destination),
                "sha256": digest,
                "filename": source.name,
                "captured_at": None,
                "width": None,
                "height": None,
                "metadata": {"original_path": str(source)},
            }
        )
        imported += 1
        if limit is not None and imported >= limit:
            break
    return imported


def import_photos_selection(db: Database, limit: int) -> int:
    exported = export_photos_selection(limit)
    return import_files(db, [str(exported)], limit=limit, source_kind="apple-photos-selection")
