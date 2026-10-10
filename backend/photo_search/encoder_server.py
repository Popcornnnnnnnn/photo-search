"""Line-delimited JSON encoder host for the native app.

The app owns this process: it starts it, asks for query vectors, and can ask it
to release the model when memory is tight. Nothing here listens on a port, so
there is no service to discover, keep alive, or uninstall separately.

Requests are one JSON object per line on stdin, replies are one JSON object per
line on stdout. Diagnostics go to stderr.
"""

from __future__ import annotations

import json
import sys
import traceback
from typing import Any

from .embeddings import (
    DIMENSIONS,
    embed_query,
    load_local_embedder,
    local_embedder,
    resident_bytes,
    unload_local_embedder,
)


def _emit(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def is_loaded() -> bool:
    """Report whether this process is currently holding the encoder in memory."""
    return local_embedder.cache_info().currsize > 0


def _report(fraction: float, stage: str) -> None:
    _emit({"event": "progress", "progress": round(fraction, 3), "stage": stage})


def _loaded_event(reused: bool) -> dict[str, Any]:
    return {
        "event": "loaded", "dimensions": DIMENSIONS, "reused": reused,
        "resident_bytes": resident_bytes(),
    }


def _load(announce: bool = True) -> None:
    """Load the encoder, optionally announcing the loaded event.

    `embed` loads without announcing: a stray `loaded` line before the vector
    would be read as that request's answer and desynchronise the stream.
    """
    if is_loaded():
        if announce:
            _emit(_loaded_event(reused=True))
        return
    load_local_embedder(progress=_report)
    if announce:
        _emit(_loaded_event(reused=False))


def _offload() -> None:
    unload_local_embedder()
    _emit({"event": "offloaded", "dimensions": DIMENSIONS, "resident_bytes": resident_bytes()})


def _embed(text: str) -> None:
    if not text.strip():
        _emit({"event": "error", "error": "empty text"})
        return
    # A query needs the model; load it first and stream the stages to the app.
    _load(announce=False)
    _emit({"event": "vector", "dimensions": DIMENSIONS, "vector": list(embed_query(text))})


def serve() -> int:
    """Serve requests until stdin closes or a quit request arrives."""
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except ValueError as error:
            _emit({"event": "error", "error": f"invalid request: {error}"})
            continue
        command = str(request.get("command", ""))
        try:
            if command == "status":
                _emit({
                    "event": "status", "loaded": is_loaded(), "dimensions": DIMENSIONS,
                    "resident_bytes": resident_bytes(),
                })
            elif command == "load":
                _load()
            elif command == "offload":
                _offload()
            elif command == "embed":
                _embed(str(request.get("text", "")))
            elif command == "quit":
                _offload()
                return 0
            else:
                _emit({"event": "error", "error": f"unknown command: {command}"})
        except Exception as error:  # a bad request must not kill the host
            traceback.print_exc(file=sys.stderr)
            _emit({"event": "error", "error": f"{type(error).__name__}: {error}"})
    return 0
