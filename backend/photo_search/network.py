from __future__ import annotations

import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .config import APP_HOME, ensure_app_dirs
from .providers import ModelProvider, load_provider
from .qwen import QwenClient


NETWORK_STATUS_PATH = APP_HOME / "network-status.json"
TAILSCALE_CANDIDATES = (
    Path("/Applications/Tailscale.app/Contents/MacOS/Tailscale"),
    Path("/opt/homebrew/bin/tailscale"),
    Path("/usr/local/bin/tailscale"),
)


def _write_status(**values: Any) -> dict[str, Any]:
    ensure_app_dirs()
    status = {**values, "updated_at": datetime.now(timezone.utc).isoformat()}
    temporary = NETWORK_STATUS_PATH.with_suffix(".tmp")
    temporary.write_text(json.dumps(status, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(NETWORK_STATUS_PATH)
    return status


def load_network_status() -> dict[str, Any]:
    try:
        return json.loads(NETWORK_STATUS_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"status": "not_checked"}


def _api_error(provider: ModelProvider) -> str | None:
    try:
        QwenClient(provider).models()
        return None
    except Exception as error:
        return str(error)


def _tailscale_binary() -> Path | None:
    return next((path for path in TAILSCALE_CANDIDATES if path.is_file()), None)


def _tailscale_status(binary: Path) -> dict[str, Any]:
    result = subprocess.run(
        [str(binary), "status", "--json"],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "Tailscale status failed")
    return json.loads(result.stdout)


def recover_model_connection() -> dict[str, Any]:
    provider = load_provider()
    first_error = _api_error(provider)
    if first_error is None:
        return _write_status(
            status="connected", provider_id=provider.id,
            message="Model API is reachable.",
        )
    if not provider.requires_tailscale:
        return _write_status(
            status="unavailable", provider_id=provider.id,
            message="The active provider is unavailable; automatic network recovery is disabled.",
            error=first_error,
        )

    binary = _tailscale_binary()
    if binary is None:
        return _write_status(
            status="action_required", provider_id=provider.id,
            message="Tailscale is not installed.", error=first_error,
        )
    try:
        tailscale = _tailscale_status(binary)
        backend_state = str(tailscale.get("BackendState", "Unknown"))
        if backend_state == "NeedsLogin" or not tailscale.get("HaveNodeKey", False):
            return _write_status(
                status="action_required", provider_id=provider.id,
                tailscale_state=backend_state,
                message="Tailscale login is required before the private model can reconnect.",
                error=first_error,
            )
        if backend_state != "Running":
            subprocess.run(
                [str(binary), "up"], check=False, capture_output=True,
                text=True, timeout=20,
            )

        user_id = subprocess.check_output(["/usr/bin/id", "-u"], text=True).strip()
        subprocess.run(
            [
                "/bin/launchctl", "kickstart", "-k",
                f"gui/{user_id}/com.popcornnn.qwen4090-tunnel",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
        error = first_error
        for _ in range(5):
            time.sleep(2)
            error = _api_error(provider)
            if error is None:
                return _write_status(
                    status="recovered", provider_id=provider.id,
                    tailscale_state="Running",
                    message="Tailscale, SSH tunnel, and model API are connected.",
                )
        return _write_status(
            status="unavailable", provider_id=provider.id,
            tailscale_state=str(_tailscale_status(binary).get("BackendState", "Unknown")),
            message="Recovery ran, but the model API is still unavailable.",
            error=error,
        )
    except Exception as error:
        return _write_status(
            status="unavailable", provider_id=provider.id,
            message="Automatic model connection recovery failed.",
            error=str(error),
        )
