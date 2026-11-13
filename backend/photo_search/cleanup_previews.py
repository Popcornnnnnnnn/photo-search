"""Find or move unreferenced, byte-identical legacy preview copies to Trash."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import re
import shutil
import sqlite3
import stat
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from uuid import uuid4

from .config import APP_HOME, DATABASE_PATH

NAME = re.compile(r"photos-[0-9a-f]{24}(?:-[0-9a-f]{12})?\.jpg\Z")


def fingerprint(path: Path) -> tuple[int, int, int]:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError("not a regular file")
    return info.st_ino, info.st_size, info.st_mtime_ns


def identical(a: Path, b: Path) -> bool:
    try:
        before_a, before_b = fingerprint(a), fingerprint(b)
        if before_a[1] != before_b[1]:
            return False
        with a.open("rb") as first, b.open("rb") as second:
            equal = hashlib.file_digest(first, "sha256").digest() == hashlib.file_digest(second, "sha256").digest()
        return equal and fingerprint(a) == before_a and fingerprint(b) == before_b
    except (OSError, ValueError):
        return False


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
    if assets.is_symlink() or imports.is_symlink() or not assets.is_dir() or not imports.is_dir():
        raise ValueError("Expected the normal PhotoSearch preview folders")
    count = size = 0
    destination = None
    with locked_index(home, database, apply) as conn:
        used = {Path(path).resolve() for row in conn.execute("SELECT file_path, thumbnail_path FROM assets")
                for path in row if path}
        for source in assets.iterdir():
            if not NAME.fullmatch(source.name) or source.resolve() in used:
                continue
            counterpart = imports / source.name
            if not identical(source, counterpart):
                continue
            amount = source.stat().st_size
            if apply:
                if destination is None:
                    if not trash.is_dir() or trash.is_symlink():
                        raise ValueError("The macOS Trash is unavailable")
                    destination = trash / f"PhotoSearch duplicate previews {datetime.now():%Y-%m-%d} {uuid4().hex[:8]}"
                    destination.mkdir(mode=0o700)
                    (destination / "Restore instructions.txt").write_text(
                        f"These verified duplicate previews came from {assets}.\n"
                        "To restore them, move the JPEG files back into that folder.\n", encoding="utf-8")
                shutil.move(str(source), str(destination / source.name))
            count += 1
            size += amount
    return {"files": count, "bytes": size, "trash_folder": str(destination) if destination else None}


def main() -> None:
    parser = argparse.ArgumentParser(description="Find unused duplicate PhotoSearch previews")
    parser.add_argument("--trash", action="store_true", help="Move verified duplicates to macOS Trash")
    args = parser.parse_args()
    import json
    print(json.dumps(cleanup(APP_HOME, DATABASE_PATH, Path.home() / ".Trash", apply=args.trash), indent=2))


if __name__ == "__main__":
    main()
