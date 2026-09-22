from __future__ import annotations

import json
import re
from typing import Any

from .db import Database
from .qwen import QwenClient


def fallback_terms(query: str) -> list[str]:
    normalized = query.lower().strip()
    chunks = re.findall(r"[A-Za-z0-9_./:+-]{2,}|[\u3400-\u9fff]{2,}", normalized)
    chinese_ngrams: list[str] = []
    for chunk in chunks:
        if not re.fullmatch(r"[\u3400-\u9fff]+", chunk):
            continue
        for size in (3, 2):
            if len(chunk) > size:
                chinese_ngrams.extend(chunk[index:index + size] for index in range(len(chunk) - size + 1))
    return list(dict.fromkeys([normalized, *chunks, *chinese_ngrams]))


def _annotation_payload(db: Database, asset_id: str) -> dict[str, Any]:
    artifact = db.active_artifact(asset_id, "annotation")
    return artifact["data"] if artifact else {}


def search(
    db: Database,
    query: str,
    *,
    limit: int = 20,
    expand: bool = True,
) -> dict[str, Any]:
    plan: dict[str, Any] = {"terms": fallback_terms(query), "asset_types": [], "intent": query}
    if expand:
        try:
            expanded = QwenClient().expand_query(query)
            terms = [str(term).strip().lower() for term in expanded.get("terms", []) if str(term).strip()]
            plan = expanded
            plan["terms"] = list(dict.fromkeys([query.lower(), *terms, *fallback_terms(query)]))
        except Exception as error:
            plan["expansion_error"] = str(error)

    terms = [term for term in plan.get("terms", []) if len(term.strip()) >= 2]
    requested_types = {str(value) for value in plan.get("asset_types", [])}
    results: list[dict[str, Any]] = []
    query_lower = query.lower().strip()
    for row in db.search_docs():
        text = row["search_text"].lower()
        matched: list[str] = []
        score = 0.0
        if query_lower and query_lower in text:
            score += 12.0
            matched.append(query)
        for index, term in enumerate(terms):
            if term in text:
                score += max(1.0, 5.0 - index * 0.15)
                matched.append(term)
        if requested_types and row["asset_type"] in requested_types:
            score += 2.0
        if score <= 0:
            continue
        annotation = _annotation_payload(db, row["asset_id"])
        results.append(
            {
                "asset_id": row["asset_id"],
                "score": round(score, 3),
                "matched_terms": list(dict.fromkeys(matched)),
                "asset_type": row["asset_type"],
                "short_caption": row["short_caption"],
                "captured_at": row["captured_at"],
                "filename": row["filename"],
                "thumbnail_path": row["thumbnail_path"],
                "annotation": annotation,
            }
        )
    results.sort(key=lambda item: (-item["score"], item.get("captured_at") or ""), reverse=False)
    return {"query": query, "plan": plan, "results": results[:limit]}
