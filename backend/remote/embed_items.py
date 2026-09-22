#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import torch

from src.models.qwen3_vl_embedding import Qwen3VLEmbedder


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--batch-size", type=int, default=2)
    args = parser.parse_args()

    root = args.manifest.parent
    items = [json.loads(line) for line in args.manifest.read_text().splitlines() if line.strip()]
    embedder = Qwen3VLEmbedder(
        args.model,
        max_length=4096,
        max_pixels=1024 * 1024,
        dtype=torch.bfloat16,
        attn_implementation="sdpa",
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        for start in range(0, len(items), args.batch_size):
            batch = items[start:start + args.batch_size]
            inputs = []
            for item in batch:
                if item["kind"] == "image":
                    inputs.append({"image": str((root / item["image"]).resolve())})
                else:
                    inputs.append(
                        {"text": item["text"], "instruction": item.get("instruction")}
                    )
            before = time.perf_counter()
            vectors = embedder.process(inputs).detach().cpu().float().tolist()
            elapsed = time.perf_counter() - before
            for item, vector in zip(batch, vectors):
                handle.write(
                    json.dumps(
                        {
                            "id": item["id"],
                            "kind": item["kind"],
                            "dimensions": len(vector),
                            "elapsed_seconds": elapsed / len(batch),
                            "vector": vector,
                        },
                        ensure_ascii=False,
                    ) + "\n"
                )
                handle.flush()
            print(f"embedded {min(start + len(batch), len(items))}/{len(items)}", flush=True)


if __name__ == "__main__":
    main()
