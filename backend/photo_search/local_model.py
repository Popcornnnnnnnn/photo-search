"""Start the configured, installed LM Studio model without changing providers."""
from __future__ import annotations

import fcntl
import json
import subprocess
from pathlib import Path
from urllib.parse import urlsplit

from .config import APP_HOME, ensure_app_dirs
from .providers import ModelProvider


def uses_lm_studio(provider: ModelProvider) -> bool:
    url = urlsplit(provider.base_url)
    return (provider.kind == "local" and not provider.requires_tailscale
            and url.scheme == "http" and url.hostname in {"127.0.0.1", "localhost", "::1"}
            and url.port == 1234 and url.path.rstrip("/") == "/v1")


def ensure_local_model(provider: ModelProvider) -> None:
    if not uses_lm_studio(provider):
        return
    binary = Path.home() / ".lmstudio/bin/lms"
    if not binary.is_file():
        raise RuntimeError("LM Studio CLI was not found at ~/.lmstudio/bin/lms.")

    def run(*arguments: str, timeout: int = 30) -> str:
        try:
            result = subprocess.run([str(binary), *arguments], capture_output=True,
                                    text=True, timeout=timeout, check=False)
        except (OSError, subprocess.SubprocessError) as error:
            raise RuntimeError(f"LM Studio {arguments[0]} failed: {error}") from error
        if result.returncode:
            raise RuntimeError(f"LM Studio {arguments[0]} failed: {result.stderr.strip() or result.stdout.strip()}")
        return result.stdout

    ensure_app_dirs()
    # Network recovery and the indexing worker can request the same cold model.
    # Serialise their check/load sequence; never unload other applications' models.
    with (APP_HOME / "local-model.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        run("server", "start", "--port", "1234", "--bind", "127.0.0.1")
        loaded = json.loads(run("ps", "--json"))
        if any(item.get("identifier") == provider.model for item in loaded):
            return
        installed = json.loads(run("ls", "--json"))
        model = next((item for item in installed if item.get("type") == "llm"
                      and provider.model in {item.get("modelKey"), item.get("path"),
                                             item.get("indexedModelIdentifier")}), None)
        if model is None:
            raise RuntimeError(f"The configured model {provider.model!r} is not installed in LM Studio.")
        if not model.get("vision"):
            raise RuntimeError(f"The configured model {provider.model!r} does not support images.")
        run("load", model["modelKey"], "--identifier", provider.model,
            "--context-length", "16384", "--gpu", "max", "--yes", timeout=300)
        loaded = json.loads(run("ps", "--json"))
        if not any(item.get("identifier") == provider.model for item in loaded):
            raise RuntimeError(f"LM Studio did not load {provider.model!r}.")
