from __future__ import annotations

import json
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .config import APP_HOME


PROVIDER_CONFIG_PATH = APP_HOME / "model-providers.json"
KEYCHAIN_SERVICE = "com.popcornnn.photo-search.model-api-key"


@dataclass(frozen=True)
class ModelProvider:
    id: str
    name: str
    kind: str
    base_url: str
    model: str
    producer: str
    requires_tailscale: bool = False
    json_mode: bool = True
    qwen_thinking_control: bool = False
    reprocess_existing: bool = False

    @property
    def api_key(self) -> str:
        override = os.environ.get("PHOTO_SEARCH_API_KEY", "").strip()
        if override:
            return override
        try:
            result = subprocess.run(
                [
                    "/usr/bin/security",
                    "find-generic-password",
                    "-s",
                    KEYCHAIN_SERVICE,
                    "-a",
                    self.id,
                    "-w",
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
            )
        except (OSError, subprocess.SubprocessError):
            return ""
        return result.stdout.strip() if result.returncode == 0 else ""


def default_provider() -> ModelProvider:
    return ModelProvider(
        id="qwen-4090",
        name="Qwen 4090",
        kind="local",
        base_url=os.environ.get(
            "PHOTO_SEARCH_QWEN_URL", "http://127.0.0.1:18000/v1"
        ).rstrip("/"),
        model=os.environ.get("PHOTO_SEARCH_QWEN_MODEL", "qwen3.8-27b-fp8"),
        producer="qwen-vlm",
        requires_tailscale=True,
        json_mode=True,
        qwen_thinking_control=True,
    )


def _profile_from_json(value: dict[str, Any], reprocess_existing: bool) -> ModelProvider:
    provider_id = str(value.get("id", "")).strip()
    if not re.fullmatch(r"[A-Za-z0-9._-]+", provider_id):
        raise ValueError("model provider id must contain only letters, numbers, dot, dash, or underscore")
    base_url = str(value.get("base_url", "")).strip().rstrip("/")
    if not base_url.startswith(("http://", "https://")):
        raise ValueError(f"model provider {provider_id} has an invalid base URL")
    model = str(value.get("model", "")).strip()
    if not model:
        raise ValueError(f"model provider {provider_id} has no model")
    producer = str(value.get("producer", "")).strip() or f"openai-compatible:{provider_id}"
    return ModelProvider(
        id=provider_id,
        name=str(value.get("name", provider_id)).strip() or provider_id,
        kind=str(value.get("kind", "local")).strip() or "local",
        base_url=base_url,
        model=model,
        producer=producer,
        requires_tailscale=bool(value.get("requires_tailscale", False)),
        json_mode=bool(value.get("json_mode", True)),
        qwen_thinking_control=bool(value.get("qwen_thinking_control", False)),
        reprocess_existing=reprocess_existing,
    )


def load_provider(path: Path = PROVIDER_CONFIG_PATH) -> ModelProvider:
    if not path.is_file():
        return default_provider()
    payload = json.loads(path.read_text(encoding="utf-8"))
    profiles = payload.get("providers")
    if not isinstance(profiles, list):
        raise ValueError("model provider configuration has no providers list")
    active_id = str(payload.get("active_provider_id", "")).strip()
    for profile in profiles:
        if isinstance(profile, dict) and str(profile.get("id", "")) == active_id:
            return _profile_from_json(profile, bool(payload.get("reprocess_existing", False)))
    raise ValueError(f"active model provider {active_id!r} was not found")
