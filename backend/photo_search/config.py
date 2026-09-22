from __future__ import annotations

import os
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
APP_HOME = Path(
    os.environ.get(
        "PHOTO_SEARCH_HOME",
        Path.home() / "Library" / "Application Support" / "PhotoSearch",
    )
).expanduser()
DATABASE_PATH = APP_HOME / "photo-search.sqlite3"
ASSET_DIR = APP_HOME / "assets"
IMPORT_DIR = APP_HOME / "imports"
LOG_DIR = APP_HOME / "logs"
WORKER_STATUS_PATH = APP_HOME / "worker-status.json"
WORKER_BATCH_SIZE = max(1, int(os.environ.get("PHOTO_SEARCH_WORKER_BATCH_SIZE", "12")))
SKIP_RETRY_HOURS = max(1, int(os.environ.get("PHOTO_SEARCH_SKIP_RETRY_HOURS", "12")))
BUILD_DIR = PROJECT_ROOT / ".build"
PHOTO_EXPORTER = BUILD_DIR / "PhotoSearchExporter.app" / "Contents" / "MacOS" / "photo-export"
VISION_OCR = BUILD_DIR / "vision-ocr"

OCR_PRODUCER = "apple-vision"
OCR_VERSION = "recognize-text-v1"
ANNOTATION_PROMPT_VERSION = "universal-v1"
ANNOTATION_SCHEMA_VERSION = "1.0"
PREPROCESS_VERSION = "photos-thumbnail-1600-v1"
QUERY_PROMPT_VERSION = "query-planner-v1"


def ensure_app_dirs() -> None:
    for path in (APP_HOME, ASSET_DIR, IMPORT_DIR, LOG_DIR):
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.chmod(0o700)
