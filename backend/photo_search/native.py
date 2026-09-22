from __future__ import annotations

import json
import subprocess
import time
from pathlib import Path
from typing import Any

from .config import PHOTO_EXPORTER, PROJECT_ROOT, VISION_OCR


class NativeHelperError(RuntimeError):
    pass


def build_native() -> None:
    script = PROJECT_ROOT / "scripts" / "build_native.sh"
    subprocess.run([str(script)], cwd=PROJECT_ROOT, check=True)


def ensure_native() -> None:
    if not PHOTO_EXPORTER.exists() or not VISION_OCR.exists():
        build_native()


def run_ocr(image_path: Path) -> dict[str, Any]:
    ensure_native()
    process = subprocess.run(
        [str(VISION_OCR), str(image_path)],
        capture_output=True,
        text=True,
        timeout=180,
    )
    if process.returncode != 0:
        raise NativeHelperError(process.stderr.strip() or "Vision OCR failed")
    return json.loads(process.stdout)


def export_library_photos(output_dir: Path, limit: int, strategy: str = "recent") -> dict[str, Any]:
    ensure_native()
    output_dir.mkdir(parents=True, exist_ok=True)
    manifest = output_dir / "manifest.jsonl"
    result_path = output_dir / "result.json"
    app_bundle = PHOTO_EXPORTER.parents[2]
    started_at = time.time()
    process = subprocess.run(
        [
            "open", "-W", "-n", str(app_bundle), "--args", "--output", str(output_dir),
            "--limit", str(limit), "--strategy", strategy,
        ],
        capture_output=True,
        text=True,
        timeout=max(300, min(limit * 60, 24 * 60 * 60)),
    )
    if process.returncode != 0:
        raise NativeHelperError(process.stderr.strip() or "Photo export failed")
    if not manifest.is_file() or not result_path.is_file():
        raise NativeHelperError("Photo exporter did not create a manifest")
    if result_path.stat().st_mtime < started_at - 1:
        raise NativeHelperError("Photo exporter did not finish this run")
    result = json.loads(result_path.read_text(encoding="utf-8"))
    if int(result.get("failed", 0)) > 0:
        raise NativeHelperError(f"Photo exporter failed on {result['failed']} asset(s)")
    return result


def export_recent_photos(output_dir: Path, limit: int) -> dict[str, Any]:
    return export_library_photos(output_dir, limit, "recent")
