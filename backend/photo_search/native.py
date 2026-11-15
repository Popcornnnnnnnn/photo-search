from __future__ import annotations

import json
import subprocess
import time
from pathlib import Path
from typing import Any

from .config import APP_HOME, PHOTO_EXPORTER, PROJECT_ROOT, VISION_OCR


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


def simplify_chinese(text: str) -> str:
    ensure_native()
    process = subprocess.run([str(VISION_OCR), "--simplify-text"], input=text,
                             capture_output=True, text=True, timeout=180)
    if process.returncode:
        raise NativeHelperError(process.stderr.strip() or "Local Chinese normalization failed")
    return process.stdout


def export_library_photos(output_dir: Path, limit: int, strategy: str = "recent") -> dict[str, Any]:
    ensure_native()
    output_dir.mkdir(parents=True, exist_ok=True)
    manifest = output_dir / "manifest.jsonl"
    result_path = output_dir / "result.json"
    app_bundle = PHOTO_EXPORTER.parents[2]
    started_at = time.time()
    process = subprocess.run(
        [
            "open", "-g", "-W", "-n", str(app_bundle), "--args", "--output", str(output_dir),
            "--limit", str(limit), "--strategy", strategy, "--no-prompt",
        ],
        capture_output=True,
        text=True,
        timeout=max(300, min(limit * 60, 24 * 60 * 60)),
    )
    if process.returncode != 0:
        raise NativeHelperError(process.stderr.strip() or "Photo export failed")
    if not result_path.is_file():
        raise NativeHelperError("Photo exporter did not report a result")
    if result_path.stat().st_mtime < started_at - 1:
        raise NativeHelperError("Photo exporter did not finish this run")
    result = json.loads(result_path.read_text(encoding="utf-8"))
    if result.get("error"):
        raise NativeHelperError(result["error"])
    if not manifest.is_file():
        raise NativeHelperError("Photo exporter did not create a manifest")
    return result


def export_recent_photos(output_dir: Path, limit: int) -> dict[str, Any]:
    return export_library_photos(output_dir, limit, "recent")


def export_video_for_indexing(identifier: str, modified_at: str | None, output_dir: Path) -> Path:
    """Export one current Photos video to a private, caller-owned temporary directory."""
    ensure_native()
    app_bundle = PHOTO_EXPORTER.parents[2]
    result_path = output_dir / "result.json"
    try:
        process = subprocess.run(
            ["open", "-g", "-W", "-n", str(app_bundle), "--args", "--output", str(output_dir),
             "--video-id", identifier, "--expected-modified-at", modified_at or "", "--no-prompt"],
            capture_output=True, text=True, timeout=3600,
        )
    except subprocess.TimeoutExpired as error:
        raise NativeHelperError("Photos video export timed out") from error
    if process.returncode or not result_path.is_file():
        raise NativeHelperError(process.stderr.strip() or "Photos could not export the video")
    result = json.loads(result_path.read_text(encoding="utf-8"))
    if result.get("error"):
        raise NativeHelperError(result["error"])
    video = output_dir / "video.mov"
    if result.get("video") != str(video) or not video.is_file():
        raise NativeHelperError("Photos did not produce the requested video")
    return video


def authorize_photos() -> dict[str, Any]:
    """Only a user-invoked action may display the Photos consent dialog."""
    ensure_native()
    output = APP_HOME / "imports/photos-authorization"
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    started = time.time()
    process = subprocess.run(["open", "-g", "-W", "-n", str(PHOTO_EXPORTER.parents[2]),
                              "--args", "--output", str(output), "--authorize"],
                             capture_output=True, text=True, timeout=300)
    result = output / "result.json"
    if process.returncode or not result.is_file() or result.stat().st_mtime < started - 1:
        raise NativeHelperError(process.stderr.strip() or "Photos authorization did not finish")
    payload = json.loads(result.read_text(encoding="utf-8"))
    if payload.get("error") or not payload.get("authorized"):
        raise NativeHelperError(payload.get("error") or "Photos access was not granted")
    return payload
