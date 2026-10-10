from __future__ import annotations

import json
import shutil
import time
from pathlib import Path
from typing import Any

from .db import Database
from .search import search, LEXICAL_CONFIDENCE_RATIO, MIN_VISUAL_SIMILARITY, MIN_TEXT_COVERAGE
from .embeddings import (
    EMBEDDING_MODEL, EMBEDDING_REVISION, WRAPPER_REVISION,
    EMBEDDING_NAMESPACE, QUERY_INSTRUCTION,
)


def evaluate_search(db: Database, directory: Path) -> dict[str, Any]:
    """Evaluate the same live search path used by the native app, over the current index."""
    cases = json.loads((directory / "cases.json").read_text(encoding="utf-8"))
    if not cases:
        raise ValueError("No search evaluation cases provided")
    metrics = {f"{mode}_hit_at_{k}": 0 for mode in ("lexical", "hybrid") for k in (1, 3)}
    positive_count = sum(bool(case["expected"]) for case in cases)
    negative_count = len(cases) - positive_count
    rejected = {mode: 0 for mode in ("lexical", "hybrid")}
    rows = []
    for case in cases:
        row = {"id": case["id"], "query": case["query"], "expected": case["expected"]}
        for mode in ("lexical", "hybrid"):
            started = time.monotonic()
            result = search(db, case["query"], limit=100, expand=False, hybrid=mode == "hybrid")
            ids = [item["asset_id"] for item in result["results"]]
            row[f"{mode}_top3"] = ids[:3]
            row[f"{mode}_seconds"] = round(time.monotonic() - started, 3)
            row[f"{mode}_result_count"] = len(ids)
            if not case["expected"]:
                rejected[mode] += not ids
            for k in (1, 3):
                metrics[f"{mode}_hit_at_{k}"] += bool(set(case["expected"]) & set(ids[:k]))
            if mode == "hybrid":
                row["retrieval"] = result["plan"]["retrieval"]
                row["embedding_count"] = result["plan"]["embedding_count"]
                row["match_status"] = result["plan"]["match_status"]
        rows.append(row)
    report = {
        "query_count": len(cases), "positive_query_count": positive_count, "negative_query_count": negative_count,
        "indexed_count": db.stats()["search_docs"],
        "thresholds": {"visual_similarity": MIN_VISUAL_SIMILARITY, "text_coverage": MIN_TEXT_COVERAGE},
        "metrics": {**{key: value / positive_count if positive_count else None for key, value in metrics.items()},
                    **{f"{mode}_negative_empty_rate": count / negative_count if negative_count else None for mode, count in rejected.items()}},
        "cases": rows,
    }
    (directory / "search-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return report



CASES = [
    {
        "id": "bridge-cycling-selfie",
        "query": "那张在高架水泥柱旁边骑车时拍的自拍",
        "expected": ["file-2f50143465b932ffc23be180"],
    },
    {
        "id": "bike-in-car",
        "query": "自行车塞在车里，人坐后排玩手机的照片",
        "expected": ["file-f0ba04e87e4af90f53eb4dca"],
    },
    {
        "id": "opencode-api-error",
        "query": "之前问模型身份却一直重试连接的 OpenCode 界面",
        "expected": ["file-6ff71dc3712d69e493089a85"],
    },
    {
        "id": "desk2shell-chinese",
        "query": "给 Windows 远程 SSH 节点做配置的中文向导",
        "expected": ["file-5428d09a5a4a58ae677e6bda"],
    },
    {
        "id": "port-tools",
        "query": "哪个深色软件页面列出了正在监听的开发端口",
        "expected": ["file-f26d1129410baf427f3b4106"],
    },
    {
        "id": "purple-cycling-watch",
        "query": "穿紫衣服从自己视角拍到头盔和手表的骑行照",
        "expected": [
            "file-22a971f18644a8ec5e69acc3",
            "file-aacf4ed27b347b393b89dc8d",
            "file-e439008faf9788c6396203ad",
        ],
    },
]


def prepare_benchmark(
    db: Database,
    output: Path,
    *,
    cases: list[dict[str, Any]] | None = None,
    source_kind: str | None = None,
) -> dict[str, Any]:
    output.mkdir(parents=True, exist_ok=True)
    images = output / "images"
    images.mkdir(exist_ok=True)
    manifest: list[dict[str, Any]] = []
    assets = [
        asset for asset in db.assets()
        if source_kind is None or asset["source_kind"] == source_kind
    ]
    for asset in assets:
        destination = images / f"{asset['id']}.jpg"
        shutil.copy2(asset["file_path"], destination)
        manifest.append(
            {
                "id": f"image:{asset['id']}",
                "kind": "image",
                "image": f"images/{destination.name}",
            }
        )
    available = {row["id"] for row in assets}
    selected_cases = [
        case for case in (cases or CASES) if set(case["expected"]) & available
    ]
    for case in selected_cases:
        manifest.append(
            {
                "id": f"query:{case['id']}",
                "kind": "query",
                "text": case["query"],
                "instruction": QUERY_INSTRUCTION,
            }
        )
    manifest_path = output / "manifest.jsonl"
    manifest_path.write_text(
        "".join(json.dumps(item, ensure_ascii=False) + "\n" for item in manifest),
        encoding="utf-8",
    )
    (output / "cases.json").write_text(
        json.dumps(selected_cases, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return {
        "images": len(available), "queries": len(selected_cases),
        "source_kind": source_kind, "manifest": str(manifest_path),
    }


def _dot(left: list[float], right: list[float]) -> float:
    return sum(a * b for a, b in zip(left, right))


def evaluate_benchmark(db: Database, directory: Path) -> dict[str, Any]:
    vectors: dict[str, list[float]] = {}
    metadata: dict[str, dict[str, Any]] = {}
    for line in (directory / "vectors.jsonl").read_text(encoding="utf-8").splitlines():
        item = json.loads(line)
        vectors[item["id"]] = [float(value) for value in item["vector"]]
        metadata[item["id"]] = item

    cases = json.loads((directory / "cases.json").read_text(encoding="utf-8"))
    image_vectors = {
        key.removeprefix("image:"): vector
        for key, vector in vectors.items()
        if key.startswith("image:")
    }
    for asset_id, vector in image_vectors.items():
        db.upsert_embedding(
            asset_id=asset_id,
            namespace=EMBEDDING_NAMESPACE,
            model=EMBEDDING_MODEL,
            model_revision=EMBEDDING_REVISION,
            prompt_version=f"official-wrapper-{WRAPPER_REVISION[:8]}:document-default-v1",
            vector=vector,
        )

    rows: list[dict[str, Any]] = []
    embedding_top1 = embedding_top3 = lexical_top1 = lexical_top3 = 0
    hybrid_top1 = hybrid_top3 = 0
    for case in cases:
        query_vector = vectors[f"query:{case['id']}"]
        ranked = sorted(
            (
                {"asset_id": asset_id, "score": round(_dot(query_vector, vector), 6)}
                for asset_id, vector in image_vectors.items()
            ),
            key=lambda item: item["score"],
            reverse=True,
        )
        lexical_all = [
            item for item in search(db, case["query"], limit=max(100, len(image_vectors)), expand=False, hybrid=False)["results"]
            if item["asset_id"] in image_vectors
        ]
        lexical = lexical_all[:3]
        second_score = float(lexical_all[1]["score"]) if len(lexical_all) > 1 else 0.0
        lexical_ratio = (
            float(lexical_all[0]["score"]) / second_score
            if lexical_all and second_score > 0
            else float("inf") if lexical_all else 0.0
        )
        if lexical_ratio >= LEXICAL_CONFIDENCE_RATIO:
            lexical_ids = {item["asset_id"] for item in lexical_all}
            hybrid = [
                {"asset_id": item["asset_id"], "score": item["score"]}
                for item in lexical_all
            ] + [item for item in ranked if item["asset_id"] not in lexical_ids]
            hybrid_route = "lexical"
        else:
            hybrid = ranked
            hybrid_route = "embedding"
        expected = set(case["expected"])
        emb_ids = [item["asset_id"] for item in ranked]
        lex_ids = [item["asset_id"] for item in lexical]
        hybrid_ids = [item["asset_id"] for item in hybrid]
        embedding_top1 += int(bool(emb_ids[:1] and expected & set(emb_ids[:1])))
        embedding_top3 += int(bool(expected & set(emb_ids[:3])))
        lexical_top1 += int(bool(lex_ids[:1] and expected & set(lex_ids[:1])))
        lexical_top3 += int(bool(expected & set(lex_ids[:3])))
        hybrid_top1 += int(bool(hybrid_ids[:1] and expected & set(hybrid_ids[:1])))
        hybrid_top3 += int(bool(expected & set(hybrid_ids[:3])))
        rows.append(
            {
                **case,
                "embedding_top3": ranked[:3],
                "lexical_top3": lexical[:3],
                "hybrid_top3": hybrid[:3],
                "hybrid_route": hybrid_route,
                "lexical_confidence_ratio": round(lexical_ratio, 4),
            }
        )

    count = max(1, len(cases))
    report = {
        "model": EMBEDDING_MODEL,
        "model_revision": EMBEDDING_REVISION,
        "wrapper_revision": WRAPPER_REVISION,
        "namespace": EMBEDDING_NAMESPACE,
        "hybrid_lexical_confidence_ratio": LEXICAL_CONFIDENCE_RATIO,
        "image_count": len(image_vectors),
        "query_count": len(cases),
        "dimensions": len(next(iter(image_vectors.values()))) if image_vectors else 0,
        "metrics": {
            "embedding_hit_at_1": embedding_top1 / count,
            "embedding_hit_at_3": embedding_top3 / count,
            "lexical_hit_at_1": lexical_top1 / count,
            "lexical_hit_at_3": lexical_top3 / count,
            "hybrid_hit_at_1": hybrid_top1 / count,
            "hybrid_hit_at_3": hybrid_top3 / count,
        },
        "elapsed_seconds": sum(float(item.get("elapsed_seconds", 0)) for item in metadata.values()),
        "cases": rows,
    }
    (directory / "report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return report


def evaluate_query_expansion(db: Database, directory: Path) -> dict[str, Any]:
    cases = json.loads((directory / "cases.json").read_text(encoding="utf-8"))
    image_ids = {
        item["id"].removeprefix("image:")
        for line in (directory / "manifest.jsonl").read_text(encoding="utf-8").splitlines()
        if (item := json.loads(line))["kind"] == "image"
    }
    rows: list[dict[str, Any]] = []
    hit_at_1 = hit_at_3 = 0
    for case in cases:
        result = search(db, case["query"], limit=max(100, len(image_ids)), expand=True, hybrid=False)
        ranked = [item for item in result["results"] if item["asset_id"] in image_ids]
        ids = [item["asset_id"] for item in ranked]
        expected = set(case["expected"])
        hit_at_1 += int(bool(expected & set(ids[:1])))
        hit_at_3 += int(bool(expected & set(ids[:3])))
        rows.append(
            {
                **case,
                "plan": result["plan"],
                "top3": ranked[:3],
            }
        )
    count = max(1, len(cases))
    report = {
        "query_count": len(cases),
        "metrics": {
            "expanded_lexical_hit_at_1": hit_at_1 / count,
            "expanded_lexical_hit_at_3": hit_at_3 / count,
        },
        "cases": rows,
    }
    (directory / "query-expansion-report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return report
