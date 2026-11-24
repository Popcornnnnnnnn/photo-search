from __future__ import annotations

import json
import math
import os
import fcntl
import gc
import threading
from functools import lru_cache
from pathlib import Path

from .config import APP_HOME


EMBEDDING_MODEL = "Qwen/Qwen3-VL-Embedding-2B"
EMBEDDING_REVISION = "9f2f7e710d6d81056aa5c0a4f04764fec6bb7bda"
WRAPPER_REVISION = "393e2978d27852b0d0230d6994f37f9c15bed73c"
EMBEDDING_NAMESPACE = "image-retrieval-v1"
EMBEDDING_PROMPT = f"official-wrapper-{WRAPPER_REVISION[:8]}:document-default-v1"
QUERY_INSTRUCTION = "Retrieve the personal image that best matches this search query."
VIDEO_EMBEDDING_NAMESPACE = "video-retrieval-v1"
VIDEO_EMBEDDING_PROMPT = f"official-wrapper-{WRAPPER_REVISION[:8]}:video-summary-v1"
DIMENSIONS = 2048
_lock = threading.Lock()
_query_condition = threading.Condition()
_query_waiters = 0


def normalized(vector: list[float]) -> list[float]:
    if not vector or not all(math.isfinite(v) for v in vector):
        raise ValueError("Embedding contains invalid values")
    norm = math.sqrt(sum(v * v for v in vector))
    if norm == 0:
        raise ValueError("Embedding has zero length")
    return [v / norm for v in vector]


class LocalEmbedder:
    """Pinned Qwen image/text encoding, with the official last-token pooling."""

    def __init__(self, progress=None):
        import torch
        from transformers import Qwen3VLModel, Qwen3VLProcessor
        from transformers.models.qwen3_vl.modeling_qwen3_vl import Qwen3VLPreTrainedModel

        def report(fraction: float, stage: str) -> None:
            if progress is not None:
                progress(fraction, stage)

        class EmbeddingModel(Qwen3VLPreTrainedModel):
            # The embedding checkpoint uses the official wrapper's model.* keys.
            _checkpoint_conversion_mapping = {}

            def __init__(self, config):
                super().__init__(config)
                self.model = Qwen3VLModel(config)
                self.post_init()

            def forward(self, **inputs):
                return self.model(**inputs)

        path = Path(os.environ.get(
            "PHOTO_SEARCH_EMBEDDING_MODEL_PATH",
            APP_HOME / "models" / "Qwen3-VL-Embedding-2B",
        ))
        if not (path / "model.safetensors").is_file():
            raise RuntimeError("Download the pinned Qwen3-VL-Embedding-2B model before vector search")
        report(0.05, "Reading the pinned encoder checkpoint")
        self.device = "mps" if torch.backends.mps.is_available() else "cuda" if torch.cuda.is_available() else "cpu"
        dtype = torch.bfloat16 if self.device != "cpu" else torch.float32
        self.model, loading = EmbeddingModel.from_pretrained(
            path, local_files_only=True, dtype=dtype, attn_implementation="sdpa",
            output_loading_info=True,
        )
        if loading["missing_keys"] or loading["unexpected_keys"] or loading["mismatched_keys"]:
            raise RuntimeError("Embedding checkpoint does not match the pinned model architecture")
        report(0.70, f"Moving 4 GB of weights to {self.device.upper()}")
        self.model = self.model.to(self.device).eval()
        report(0.92, "Loading the image and text processor")
        self.processor = Qwen3VLProcessor.from_pretrained(
            path, local_files_only=True, padding_side="right",
            min_pixels=4096, max_pixels=1024 * 1024,
        )
        report(1.0, "Visual search is ready")

    def encode(self, *, text: str | None = None, image: Path | None = None, document: bool = False) -> list[float]:
        import torch
        from PIL import Image

        content = [{"type": "text", "text": text}] if text is not None else [{"type": "image"}]
        conversation = [
            {"role": "system", "content": [{"type": "text", "text": QUERY_INSTRUCTION if text is not None and not document else "Represent the user's input."}]},
            {"role": "user", "content": content},
        ]
        prompt = self.processor.apply_chat_template(conversation, add_generation_prompt=True, tokenize=False)
        images = None
        if image is not None:
            with Image.open(image) as source:
                images = [source.convert("RGB")]
        inputs = self.processor(text=[prompt], images=images, padding=True, return_tensors="pt").to(self.device)
        with torch.inference_mode():
            output = self.model(**inputs, use_cache=False)
            last = int(inputs["attention_mask"][0].sum().item()) - 1
            vector = output.last_hidden_state[0, last].float().cpu().tolist()
        return normalized(vector)


_progress_hook = None


@lru_cache(maxsize=1)
def local_embedder() -> LocalEmbedder:
    return LocalEmbedder(progress=_progress_hook)


def load_local_embedder(progress=None) -> LocalEmbedder:
    """Load the pinned encoder once and keep it resident in this process."""
    global _progress_hook
    _progress_hook = progress
    try:
        return local_embedder()
    finally:
        _progress_hook = None


def unload_local_embedder() -> None:
    """Release the resident encoder so the process returns its memory."""
    local_embedder.cache_clear()
    embed_query.cache_clear()
    gc.collect()
    try:
        import torch

        if torch.backends.mps.is_available():
            torch.mps.empty_cache()
    except Exception:  # pragma: no cover - only reachable without a local accelerator
        pass


def resident_bytes() -> int:
    """Bytes the resident encoder holds on its compute device, or 0 when idle."""
    if local_embedder.cache_info().currsize == 0:
        return 0
    try:
        import torch

        if torch.backends.mps.is_available():
            return int(torch.mps.driver_allocated_memory())
        if torch.cuda.is_available():
            return int(torch.cuda.memory_allocated())
    except Exception:  # pragma: no cover - only reachable without a local accelerator
        pass
    return 0


@lru_cache(maxsize=128)
def embed_query(query: str) -> tuple[float, ...]:
    global _query_waiters
    with _query_condition:
        _query_waiters += 1
    try:
        with _lock:
            return tuple(local_embedder().encode(text=query))
    finally:
        with _query_condition:
            _query_waiters -= 1
            _query_condition.notify_all()


def embedding_count(db, *, source_kind: str | None = None) -> int:
    """Count current compatible assets, optionally within one source library."""
    sql = """SELECT COUNT(DISTINCT a.id) FROM embeddings e JOIN assets a ON a.id=e.asset_id
        WHERE ((e.namespace=? AND e.prompt_version=?) OR (e.namespace=? AND e.prompt_version=?))
        AND e.model=? AND e.model_revision=? AND e.dimensions=?
        AND e.input_sha256=a.sha256 AND e.is_active=1 AND a.is_available=1"""
    args = [EMBEDDING_NAMESPACE, EMBEDDING_PROMPT, VIDEO_EMBEDDING_NAMESPACE,
            VIDEO_EMBEDDING_PROMPT, EMBEDDING_MODEL, EMBEDDING_REVISION, DIMENSIONS]
    if source_kind is not None:
        sql += " AND a.source_kind=?"
        args.append(source_kind)
    return int(db.conn.execute(sql, args).fetchone()[0])


def index_embeddings(db, *, limit: int = 100, progress=print, stop: threading.Event | None = None) -> dict[str, int]:
    """Index photos and whole-video descriptions under distinct encoding contracts."""
    contract = dict(namespace=EMBEDDING_NAMESPACE, model=EMBEDDING_MODEL,
                    revision=EMBEDDING_REVISION, prompt=EMBEDDING_PROMPT, dimensions=DIMENSIONS)
    stop = stop or threading.Event()
    with (db.path.parent / "embedding.lock").open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {"embedded": 0, "busy": 1}
        video_contract = {**contract, "namespace": VIDEO_EMBEDDING_NAMESPACE, "prompt": VIDEO_EMBEDDING_PROMPT}
        pending = db.embedding_pending(**contract, limit=limit)
        pending += db.embedding_pending(**video_contract, media_type="video", limit=max(0, limit - len(pending)))
        processed = failed = 0
        for asset in pending:
            if stop.is_set():
                break
            with _query_condition:
                _query_condition.wait_for(lambda: _query_waiters == 0 or stop.is_set())
            if stop.is_set():
                break
            try:
                with _lock:
                    is_video = json.loads(asset["metadata_json"]).get("media_type") == "video"
                    if is_video:
                        from .db import search_values
                        annotation = db.active_artifact(asset["id"], "annotation")
                        text = "\n".join(search_values(annotation["data"]))
                        vector = local_embedder().encode(text=text, document=True)
                    else:
                        vector = local_embedder().encode(image=Path(asset["file_path"]))
                db.upsert_embedding(
                    asset_id=asset["id"], namespace=VIDEO_EMBEDDING_NAMESPACE if is_video else EMBEDDING_NAMESPACE,
                    model=EMBEDDING_MODEL, model_revision=EMBEDDING_REVISION,
                    prompt_version=VIDEO_EMBEDDING_PROMPT if is_video else EMBEDDING_PROMPT, vector=vector, input_sha256=asset["sha256"],
                )
                processed += 1
                progress(f"Embedded {processed}/{len(pending)}", flush=True)
            except (OSError, ValueError) as error:
                db.record_error(asset["id"], "embedding", repr(error))
                db.mark_processing_skip(asset["id"], "embedding", repr(error))
                failed += 1
            if stop.wait(0.1):
                break
        remaining = db.embedding_pending(**contract, count=True) + db.embedding_pending(**video_contract, media_type="video", count=True)
        total = embedding_count(db)
        return {"embedded": processed, "total": total, "pending": remaining, "failed": failed}


def compatible(row: dict) -> bool:
    return (
        row["model"] == EMBEDDING_MODEL
        and row["model_revision"] == EMBEDDING_REVISION
        and ((row.get("namespace", EMBEDDING_NAMESPACE) == EMBEDDING_NAMESPACE and row["prompt_version"] == EMBEDDING_PROMPT)
             or (row.get("namespace") == VIDEO_EMBEDDING_NAMESPACE and row["prompt_version"] == VIDEO_EMBEDDING_PROMPT))
        and row["dimensions"] == DIMENSIONS
    )
