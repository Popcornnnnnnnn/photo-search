from __future__ import annotations

import re
from typing import Any

from .db import Database
from .qwen import QwenClient
from .embeddings import EMBEDDING_NAMESPACE, VIDEO_EMBEDDING_NAMESPACE, compatible, embed_query, normalized

LEXICAL_CONFIDENCE_RATIO = 1.5
FUSION_CANDIDATES = 100
# Calibrated on existing positives plus a separate negative-query set.
# Cosine is a retrieval signal, not a probability of a correct match.
MIN_VISUAL_SIMILARITY = 0.40
MIN_UNCORROBORATED_VISUAL_SIMILARITY = 0.45
MIN_VISUAL_TEXT_COVERAGE = 0.25
# Text-encoded video summaries have a higher unrelated-query baseline than
# image vectors. Calibrated separately against password/login false positives
# and relevant cycling videos; lexical matches remain eligible independently.
MIN_VIDEO_SIMILARITY = 0.55
MIN_TEXT_COVERAGE = 0.50


def text_coverage(query: str, text: str) -> float:
    significant = re.sub(r"帮我找|找一下|之前|那张|一张|那个|视频|照片|截图|图片|画面|里面|的|了", "", query.lower())
    positions = {index for index, character in enumerate(significant) if character.isalnum()}
    if not positions:
        return 1.0 if query.lower() in text else 0.0
    covered: set[int] = set()
    for term in fallback_terms(significant):
        if len(term) < 2 or term not in text:
            continue
        for match in re.finditer(re.escape(term), significant):
            covered.update(range(match.start(), match.end()))
    return len(covered & positions) / len(positions)


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


def search(
    db: Database,
    query: str,
    *,
    limit: int = 20,
    expand: bool = False,
    hybrid: bool = True,
    asset_type: str | None = None,
) -> dict[str, Any]:
    query = query.strip()
    if not query:
        return {"query": query, "plan": {"terms": [], "retrieval": "lexical"}, "results": []}
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
    documents = {
        row["asset_id"]: row for row in db.search_docs(include_unindexed=hybrid)
        if asset_type is None or row["asset_type"] == asset_type
    }
    lexical: list[dict[str, Any]] = []
    query_lower = query.lower().strip()
    identifiers = re.findall(r"[a-z][a-z0-9]*(?:_[a-z0-9]+)+|\b[a-z]{1,5}\d{2,}[a-z0-9]*\b", query_lower)
    for row in documents.values():
        text = row["search_text"].lower()
        if not all(token in text for token in identifiers):
            continue
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
        coverage = text_coverage(query, text)
        if score <= 0:
            continue
        lexical.append(
            {
                "asset_id": row["asset_id"],
                "score": round(score, 3),
                "matched_terms": list(dict.fromkeys(matched)),
                "text_coverage": coverage,
                "asset_type": row["asset_type"],
                "short_caption": row["short_caption"],
                "captured_at": row["captured_at"],
                "filename": row["filename"],
                "thumbnail_path": row["thumbnail_path"],
            }
        )
    lexical.sort(key=lambda item: (item.get("captured_at") or "", item["asset_id"]), reverse=True)
    lexical.sort(key=lambda item: -item["score"])
    strong_text_ids = {item["asset_id"] for item in lexical if item["text_coverage"] >= MIN_TEXT_COVERAGE}
    supported_text_ids = {item["asset_id"] for item in lexical if item["text_coverage"] >= MIN_VISUAL_TEXT_COVERAGE}
    results = [item for item in lexical if item["asset_id"] in strong_text_ids]
    plan["retrieval"] = "lexical"
    plan["embedding_count"] = 0
    plan["searchable_count"] = len(documents)
    if hybrid:
        vectors = [
            row for row in (db.active_embeddings(EMBEDDING_NAMESPACE, decode_vectors=False) + db.active_embeddings(VIDEO_EMBEDDING_NAMESPACE, decode_vectors=False))
            if compatible(row) and row["asset_id"] in documents
        ]
        plan["embedding_count"] = len(vectors)
        if vectors:
            try:
                query_vector = normalized(list(embed_query(query)))
                ranked = []
                candidates = [row for row in vectors if all(
                    token in documents[row["asset_id"]]["search_text"].lower() for token in identifiers
                )]
                if candidates:
                    # Keep SQLite's packed float32 buffers until the numeric operation;
                    # expanding every component into Python floats dominates warm searches.
                    import numpy as np

                    if any(len(row["vector"]) != len(query_vector) * 4 for row in candidates):
                        raise ValueError("Query and image embedding dimensions differ")
                    # float64 preserves the precision of the former Python scalar path.
                    matrix = np.frombuffer(b"".join(row["vector"] for row in candidates), dtype=np.float32)
                    matrix = matrix.reshape(len(candidates), len(query_vector)).astype(np.float64)
                    if not np.isfinite(matrix).all():
                        raise ValueError("Embedding contains invalid values")
                    norms = np.linalg.norm(matrix, axis=1)
                    if (norms == 0).any():
                        raise ValueError("Embedding has zero length")
                    matrix /= norms[:, None]
                    similarities = matrix @ np.asarray(query_vector)
                    thresholds = np.asarray([
                        MIN_VIDEO_SIMILARITY if row["namespace"] == VIDEO_EMBEDDING_NAMESPACE
                        else MIN_VISUAL_SIMILARITY if row["asset_id"] in supported_text_ids
                        else MIN_UNCORROBORATED_VISUAL_SIMILARITY for row in candidates
                    ])
                    for index in np.flatnonzero(similarities >= thresholds):
                        similarity = float(similarities[index])
                        ranked.append({"asset_id": candidates[index]["asset_id"], "score": similarity,
                                       "visual_similarity": similarity})
                ranked.sort(key=lambda item: (-item["score"], item["asset_id"]))
                eligible = strong_text_ids | {item["asset_id"] for item in ranked}
                results = [item for item in merge_rankings(lexical, ranked, FUSION_CANDIDATES)
                           if item["asset_id"] in eligible]
                plan["retrieval"] = "hybrid"
            except Exception as error:
                plan["embedding_error"] = f"{type(error).__name__}: {error}"

    output = []
    for result in results[:limit]:
        row = documents[result["asset_id"]]
        artifact = db.active_artifact(row["asset_id"], "annotation")
        output.append({
            **result,
            "asset_type": row["asset_type"], "short_caption": row["short_caption"],
            "captured_at": row["captured_at"], "filename": row["filename"],
            "thumbnail_path": row["thumbnail_path"], "file_path": row["file_path"],
            "width": row["width"], "height": row["height"],
            "model": artifact["model"] if artifact else None,
            "annotation": artifact["data"] if artifact else None,
            "match_evidence": {
                "text_matched": result.get("text_coverage", 0) > 0,
                "visual_matched": result.get("visual_similarity") is not None,
                "is_video": row["asset_type"] == "video",
            },
        })
    plan["match_status"] = "none" if not output else "matches" if (
        output[0].get("text_coverage", 0) >= 0.8 or output[0].get("visual_similarity", 0) >= 0.5
    ) else "possible"
    return {"query": query, "plan": plan, "results": output}


def merge_rankings(lexical: list[dict], visual: list[dict], limit: int) -> list[dict]:
    """Fuse ranks rather than adding incompatible lexical and cosine scores."""
    combined: dict[str, dict] = {}
    for ranking in (lexical[:limit], visual[:limit]):
        for rank, item in enumerate(ranking, 1):
            result = combined.setdefault(item["asset_id"], {
                "asset_id": item["asset_id"], "score": 0.0, "matched_terms": [],
            })
            result["score"] += 1.0 / (60 + rank)
            if "matched_terms" in item:
                result["matched_terms"] = item["matched_terms"]
                result["text_coverage"] = item.get("text_coverage", 0)
            if "visual_similarity" in item:
                result["visual_similarity"] = item["visual_similarity"]
    results = sorted(combined.values(), key=lambda item: (-item["score"], item["asset_id"]))
    # Preserve the existing benchmark's strong lexical match ahead of visual lookalikes.
    if lexical and (len(lexical) == 1 or lexical[0]["score"] >= LEXICAL_CONFIDENCE_RATIO * lexical[1]["score"]):
        preferred = lexical[0]["asset_id"]
        results.sort(key=lambda item: item["asset_id"] != preferred)
    return results
