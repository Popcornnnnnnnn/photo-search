"""Prune superseded preview files and move unreferenced legacy media to Trash."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import re
import shutil
import sqlite3
import stat
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from uuid import uuid4

from .config import APP_HOME, DATABASE_PATH

JPG_NAME = re.compile(r"(photos-[0-9a-f]{24})(?:-[0-9a-f]{12})?\.jpg\Z")
IMPORT_MEDIA_NAME = re.compile(r"(photos-[0-9a-f]{24})(?:-[0-9a-f]{12})?\.(?:jpg|mov)\Z")


def fingerprint(path: Path) -> tuple[int, int, int]:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError("not a regular file")
    return info.st_ino, info.st_size, info.st_mtime_ns


def _try_fingerprint(path: Path) -> tuple[int, int, int] | None:
    try:
        return fingerprint(path)
    except (OSError, ValueError):
        return None


def _file_id(path: Path, *, follow_symlinks: bool = True) -> tuple[int, int] | None:
    try:
        info = path.stat() if follow_symlinks else path.lstat()
        return info.st_dev, info.st_ino
    except OSError:
        return None


def _regular_file(path: Path) -> bool:
    try:
        return stat.S_ISREG(path.lstat().st_mode)
    except OSError:
        return False


def _record_protected(
    raw_paths: list[str], protected_paths: set[Path], protected_inodes: set[tuple[int, int]]
) -> list[Path]:
    paths: list[Path] = []
    for raw in raw_paths:
        if not raw:
            continue
        candidate = Path(raw)
        paths.append(candidate)
        protected_paths.add(candidate.resolve())
        fid = _file_id(candidate)
        if fid is not None:
            protected_inodes.add(fid)
    return paths


def _is_protected(entry: Path, protected_paths: set[Path], protected_inodes: set[tuple[int, int]]) -> bool:
    if entry.resolve() in protected_paths:
        return True
    fid = _file_id(entry, follow_symlinks=False)
    return fid is not None and fid in protected_inodes


def identical(a: Path, b: Path) -> bool:
    before_a, before_b = _try_fingerprint(a), _try_fingerprint(b)
    if before_a is None or before_b is None or before_a[1] != before_b[1]:
        return False
    try:
        with a.open("rb") as first, b.open("rb") as second:
            equal = hashlib.file_digest(first, "sha256").digest() == hashlib.file_digest(second, "sha256").digest()
    except OSError:
        return False
    return equal and _try_fingerprint(a) == before_a and _try_fingerprint(b) == before_b


def prune_superseded_previews(conn: sqlite3.Connection, imports: Path, manifest: Path) -> int:
    """Delete superseded preview JPEGs in ``imports`` after SQLite updates under ``worker.lock``."""
    if imports.is_symlink() or not imports.is_dir() or manifest.is_symlink() or not manifest.is_file():
        return 0
    records = [json.loads(line) for line in manifest.read_text(encoding="utf-8").splitlines() if line.strip()]
    verified_ids: set[str] = set()
    protected_paths: set[Path] = set()
    protected_inodes: set[tuple[int, int]] = set()
    for record in records:
        if not isinstance(record, dict):
            continue
        asset_id = record.get("id")
        raw_paths = [p for p in (record.get("path"), record.get("thumbnail_path")) if isinstance(p, str) and p]
        if not isinstance(asset_id, str) or not asset_id or not raw_paths:
            continue
        paths = _record_protected(raw_paths, protected_paths, protected_inodes)
        if all(_regular_file(path) for path in paths):
            verified_ids.add(asset_id)
    for row in conn.execute("SELECT file_path, thumbnail_path FROM assets"):
        _record_protected([p for p in row if isinstance(p, str) and p], protected_paths, protected_inodes)

    removed = 0
    for entry in sorted(imports.iterdir()):
        match = JPG_NAME.fullmatch(entry.name)
        if not match or not _regular_file(entry):
            continue
        if match.group(1) in verified_ids and not _is_protected(entry, protected_paths, protected_inodes):
            entry.unlink(missing_ok=True)
            removed += 1
    return removed


def _load_manifest_state(imports: Path) -> tuple[bool, set[Path], set[tuple[int, int]], set[str], set[str]]:
    manifest_path = imports / "manifest.jsonl"
    result_path = imports / "result.json"
    if manifest_path.is_symlink() or result_path.is_symlink():
        raise ValueError("Refusing symlinked Photos manifest metadata")

    snapshot: dict | None = None
    if result_path.exists():
        loaded = json.loads(result_path.read_text(encoding="utf-8"))
        if not isinstance(loaded, dict):
            raise ValueError("Invalid Photos export result metadata")
        if loaded.get("error"):
            raise ValueError(f"Photos exporter reported an error: {loaded['error']}")
        snapshot = loaded

    if not manifest_path.exists():
        if snapshot and snapshot.get("full_snapshot") is True:
            raise ValueError("Photos manifest is missing for a full snapshot")
        return False, set(), set(), set(), set()

    records = [json.loads(line) for line in manifest_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    manifest_ids: set[str] = set()
    manifest_paths: set[Path] = set()
    manifest_inodes: set[tuple[int, int]] = set()
    for record in records:
        if not isinstance(record, dict):
            raise ValueError("Invalid Photos manifest record")
        asset_id = record.get("id")
        raw_paths = [p for p in (record.get("path"), record.get("thumbnail_path")) if isinstance(p, str) and p]
        if not isinstance(asset_id, str) or not asset_id or not raw_paths:
            raise ValueError("Invalid Photos manifest record")
        if asset_id in manifest_ids:
            raise ValueError("Photos manifest contains duplicate IDs")
        manifest_ids.add(asset_id)
        paths = _record_protected(raw_paths, manifest_paths, manifest_inodes)
        for candidate in paths:
            if not _regular_file(candidate):
                raise ValueError(f"Photos manifest references a missing preview: {candidate}")

    if snapshot is None:
        return False, manifest_paths, manifest_inodes, set(), set()

    present = snapshot.get("present_ids", [])
    failed = snapshot.get("failed_ids", [])
    if (not isinstance(present, list) or not all(isinstance(x, str) for x in present)
            or not isinstance(failed, list) or not all(isinstance(x, str) for x in failed)):
        raise ValueError("Invalid Photos snapshot ID lists")
    present_ids = set(present)
    failed_ids = set(failed)
    claims_full = snapshot.get("full_snapshot") is True
    expected = snapshot.get("library_assets")
    mixed_inventory = isinstance(expected, int) and not isinstance(expected, bool)
    if claims_full:
        fallback_expected = snapshot.get("library_images") if not mixed_inventory else expected
        if (snapshot.get("strategy") != "all"
                or not isinstance(fallback_expected, int) or isinstance(fallback_expected, bool)
                or fallback_expected != len(present_ids)
                or (manifest_ids | failed_ids) != present_ids
                or bool(manifest_ids & failed_ids)):
            raise ValueError("Incomplete Photos inventory; refusing cleanup")

    full_snapshot = bool(claims_full and mixed_inventory)
    return full_snapshot, manifest_paths, manifest_inodes, present_ids, failed_ids


@contextmanager
def locked_index(home: Path, database: Path, apply: bool):
    # A cleanup must not race the background sync or a concurrent index writer.
    lock = None
    conn = None
    try:
        if apply:
            lock = (home / "worker.lock").open("a+")
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        uri = database.resolve().as_uri() + ("?mode=rw" if apply else "?mode=ro")
        conn = sqlite3.connect(uri, uri=True, timeout=5)
        if apply:
            conn.execute("BEGIN IMMEDIATE")
        yield conn
    finally:
        if conn is not None:
            conn.rollback()
            conn.close()
        if lock is not None:
            lock.close()


def cleanup(home: Path, database: Path, trash: Path, *, apply: bool = False) -> dict:
    assets, imports = home / "assets", home / "imports" / "photos-full"
    if (home.is_symlink() or assets.is_symlink() or imports.is_symlink()
            or not assets.is_dir() or not imports.is_dir()):
        raise ValueError("Expected the normal PhotoSearch preview folders")

    assets_count = imports_jpg_count = imports_mov_count = size = 0
    destination = None
    with locked_index(home, database, apply) as conn:
        full_snapshot, manifest_paths, manifest_inodes, present_ids, failed_ids = _load_manifest_state(imports)
        columns = {row[1] for row in conn.execute("PRAGMA table_info(assets)")}
        active_paths: list[Path] = []
        protected_paths: set[Path] = set(manifest_paths)
        protected_inodes: set[tuple[int, int]] = set(manifest_inodes)
        if {"id", "is_available"} <= columns:
            for asset_id, file_path, thumbnail_path, is_available in conn.execute(
                "SELECT id, file_path, thumbnail_path, is_available FROM assets"
            ):
                raw = [p for p in (file_path, thumbnail_path) if isinstance(p, str) and p]
                if is_available:
                    active_paths.extend(_record_protected(raw, protected_paths, protected_inodes))
                elif not full_snapshot or asset_id in present_ids or asset_id in failed_ids:
                    _record_protected(raw, protected_paths, protected_inodes)
        else:
            for file_path, thumbnail_path in conn.execute("SELECT file_path, thumbnail_path FROM assets"):
                raw = [p for p in (file_path, thumbnail_path) if isinstance(p, str) and p]
                active_paths.extend(_record_protected(raw, protected_paths, protected_inodes))

        managed_root_paths = {assets.resolve(), imports.resolve()}
        managed_root_ids = {fid for d in (assets, imports) if (fid := _file_id(d)) is not None}
        for active in active_paths:
            parent_id = _file_id(active.parent)
            in_managed = active.parent.resolve() in managed_root_paths or (
                parent_id is not None and parent_id in managed_root_ids
            )
            if in_managed and not _regular_file(active):
                raise ValueError(f"Active asset preview is missing: {active}")

        candidates: list[tuple[Path, str, tuple[int, int, int]]] = []
        for source in sorted(assets.iterdir()):
            if not JPG_NAME.fullmatch(source.name) or not _regular_file(source):
                continue
            if _is_protected(source, protected_paths, protected_inodes):
                continue
            if full_snapshot or identical(source, imports / source.name):
                fp = _try_fingerprint(source)
                if fp is not None:
                    candidates.append((source, "assets", fp))

        if full_snapshot:
            for source in sorted(imports.iterdir()):
                if not IMPORT_MEDIA_NAME.fullmatch(source.name) or not _regular_file(source):
                    continue
                if _is_protected(source, protected_paths, protected_inodes):
                    continue
                fp = _try_fingerprint(source)
                if fp is not None:
                    kind = "imports_mov" if source.suffix.lower() == ".mov" else "imports_jpg"
                    candidates.append((source, kind, fp))

        for source, kind, expected_fp in candidates:
            if _try_fingerprint(source) != expected_fp:
                continue
            if apply:
                if destination is None:
                    if not trash.is_dir() or trash.is_symlink():
                        raise ValueError("The macOS Trash is unavailable")
                    destination = trash / f"PhotoSearch unused media {datetime.now():%Y-%m-%d} {uuid4().hex[:8]}"
                    destination.mkdir(mode=0o700)
                    (destination / "Restore instructions.txt").write_text(
                        f"These unreferenced PhotoSearch media files came from {home}.\n"
                        f"Subfolders match their original paths relative to {home} (assets/ and imports/photos-full/).\n"
                        f"To restore any file, move it back into the matching folder under {home}.\n",
                        encoding="utf-8",
                    )
                target = destination / source.relative_to(home)
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                shutil.move(str(source), str(target))
            size += expected_fp[1]
            if kind == "assets":
                assets_count += 1
            elif kind == "imports_mov":
                imports_mov_count += 1
            else:
                imports_jpg_count += 1

    total_files = assets_count + imports_jpg_count + imports_mov_count
    return {
        "files": total_files,
        "bytes": size,
        "assets_files": assets_count,
        "imports_jpg_files": imports_jpg_count,
        "imports_mov_files": imports_mov_count,
        "trash_folder": str(destination) if destination else None,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Find or move unused PhotoSearch previews and legacy exports to Trash")
    parser.add_argument("--trash", action="store_true", help="Move verified unreferenced media to macOS Trash")
    args = parser.parse_args()
    print(json.dumps(cleanup(APP_HOME, DATABASE_PATH, Path.home() / ".Trash", apply=args.trash), indent=2))


if __name__ == "__main__":
    main()
