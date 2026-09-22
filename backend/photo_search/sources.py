from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable

from .config import ASSET_DIR, IMPORT_DIR, PREPROCESS_VERSION, ensure_app_dirs
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
) -> int:
    imported = 0
    for line in manifest.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        source = Path(record["path"])
        destination = ASSET_DIR / source.name
        if source.resolve() != destination.resolve() and not destination.exists():
            shutil.copy2(source, destination)
        digest = sha256_file(destination)
        metadata = {
            "favorite": record.get("favorite", False),
            "media_subtypes": record.get("media_subtypes", 0),
            "preprocess_version": PREPROCESS_VERSION,
        }
        if sampling_strategy:
            metadata["sampling_strategy"] = sampling_strategy
        db.upsert_asset(
            {
                "id": record["id"],
                "source_kind": source_kind,
                "source_identifier": record["local_identifier"],
                "file_path": str(destination),
                "thumbnail_path": str(destination),
                "sha256": digest,
                "filename": record["filename"],
                "captured_at": record.get("captured_at"),
                "width": record.get("width"),
                "height": record.get("height"),
                "metadata": metadata,
            }
        )
        imported += 1
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
    result = export_library_photos(output, 1_000_000, "all")
    imported = import_photos_manifest(
        db,
        Path(result["manifest"]),
        "apple-photos-full",
        sampling_strategy="full-library-v1",
    )
    return {**result, "imported": imported}


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
