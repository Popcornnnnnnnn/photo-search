from __future__ import annotations

import re
import sqlite3
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

_STOPWORDS_RE = re.compile(r"帮我找|找一下|之前|那张|一张|那个|视频|照片|截图|图片|画面|里面|的|了")
_CHUNK_RE = re.compile(r"[A-Za-z0-9_./:+-]{2,}|[\u3400-\u9fff]{2,}")
_CJK_FULL_RE = re.compile(r"[\u3400-\u9fff]+")
_IDENT_RE = re.compile(r"[a-z][a-z0-9]*(?:_[a-z0-9]+)+|\b[a-z]{1,5}\d{2,}[a-z0-9]*\b")


def text_coverage(query: str, text: str) -> float:
    query_lower = query.lower()
    significant = _STOPWORDS_RE.sub("", query_lower)
    positions = {index for index, character in enumerate(significant) if character.isalnum()}
    if not positions:
        return 1.0 if query_lower in text else 0.0
    covered: set[int] = set()
    for term in fallback_terms(significant):
        if len(term) < 2 or term not in text:
            continue
        for match in re.finditer(re.escape(term), significant):
            covered.update(range(match.start(), match.end()))
    return len(covered & positions) / len(positions)


def fallback_terms(query: str) -> list[str]:
    normalized = query.lower().strip()
    chunks = _CHUNK_RE.findall(normalized)
    chinese_ngrams: list[str] = []
    for chunk in chunks:
        if not _CJK_FULL_RE.fullmatch(chunk):
            continue
        for size in (3, 2):
            if len(chunk) > size:
                chinese_ngrams.extend(chunk[index:index + size] for index in range(len(chunk) - size + 1))
    return list(dict.fromkeys([normalized, *chunks, *chinese_ngrams]))


def _fts_quote(term: str) -> str:
    return '"' + term.replace('"', '""') + '"'


def fts_candidate_query(
    query_lower: str,
    terms: list[str],
    identifiers: list[str],
    requested_types: set[str],
) -> str | None:
    """Build a zero-false-negative SQLite FTS5 trigram query, or None to fall back to full scan."""
    if identifiers:
        if all(len(tok) >= 3 and "\x00" not in tok for tok in identifiers):
            return " AND ".join(_fts_quote(tok) for tok in dict.fromkeys(identifiers))
        return None
    if requested_types:
        return None
    candidates = [c for c in dict.fromkeys(([query_lower] if query_lower else []) + terms) if c]
    if not candidates:
        return None
    if all(len(c) >= 3 and "\x00" not in c for c in candidates):
        return " OR ".join(_fts_quote(c) for c in candidates)
    return None


def score_lexical_docs(
    query: str,
    terms: list[str],
    requested_types: list[str],
    docs: list[tuple[str, str, str]],
) -> list[tuple[str, float, list[str], float]]:
    query_lower_full = query.lower()
    query_lower = query_lower_full.strip()
    identifiers = _IDENT_RE.findall(query_lower)
    requested_type_set = set(requested_types)
    weighted_terms = [(term, max(1.0, 5.0 - index * 0.15)) for index, term in enumerate(terms)]

    significant = _STOPWORDS_RE.sub("", query_lower_full)
    pos_mask = 0
    pos_count = 0
    for index, character in enumerate(significant):
        if character.isalnum():
            pos_mask |= 1 << index
            pos_count += 1
    cov_terms: list[tuple[str, int]] = []
    if pos_count > 0:
        for cov_term in fallback_terms(significant):
            if len(cov_term) < 2:
                continue
            span_mask = 0
            for match in re.finditer(re.escape(cov_term), significant):
                span_mask |= ((1 << (match.end() - match.start())) - 1) << match.start()
            span_mask &= pos_mask
            if span_mask:
                cov_terms.append((cov_term, span_mask))

    results: list[tuple[str, float, list[str], float]] = []
    for asset_id, search_text, asset_type in docs:
        text = search_text.lower()
        if identifiers and not all(token in text for token in identifiers):
            continue
        matched: list[str] = []
        score = 0.0
        if query_lower and query_lower in text:
            score += 12.0
            matched.append(query)
        for term, weight in weighted_terms:
            if term in text:
                score += weight
                matched.append(term)
        if requested_type_set and asset_type in requested_type_set:
            score += 2.0
        if score <= 0.0:
            continue
        if pos_count == 0:
            coverage = 1.0 if query_lower_full in text else 0.0
        else:
            hit_mask = 0
            for cov_term, span_mask in cov_terms:
                if cov_term in text:
                    hit_mask |= span_mask
                    if hit_mask == pos_mask:
                        break
            coverage = hit_mask.bit_count() / pos_count
        results.append((asset_id, round(score, 3), list(dict.fromkeys(matched)), coverage))
    return results


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
    query_lower = query.lower().strip()
    identifiers = _IDENT_RE.findall(query_lower)
    fts_query = fts_candidate_query(query_lower, terms, identifiers, requested_types)

    use_fts = False
    documents: dict[str, Any] = {}
    searchable_count = 0
    if fts_query is not None:
        try:
            fts_rows = db.search_docs_fts(fts_query, asset_type=asset_type)
            documents = {row["asset_id"]: row for row in fts_rows}
            searchable_count = db.searchable_count(include_unindexed=hybrid, asset_type=asset_type)
            use_fts = True
        except sqlite3.OperationalError:
            use_fts = False

    if not use_fts:
        documents = {
            row["asset_id"]: row for row in db.search_docs(include_unindexed=hybrid)
            if asset_type is None or row["asset_type"] == asset_type
        }
        searchable_count = len(documents)

    docs = [(row["asset_id"], row["search_text"], row["asset_type"]) for row in documents.values()]
    lexical: list[dict[str, Any]] = []
    for asset_id, score, matched_terms, coverage in score_lexical_docs(
        query, terms, sorted(requested_types), docs
    ):
        row = documents[asset_id]
        lexical.append(
            {
                "asset_id": asset_id,
                "score": score,
                "matched_terms": matched_terms,
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
    plan["searchable_count"] = searchable_count
    if hybrid:
        all_embeddings = (
            db.active_embeddings(EMBEDDING_NAMESPACE, decode_vectors=False)
            + db.active_embeddings(VIDEO_EMBEDDING_NAMESPACE, decode_vectors=False)
        )
        if use_fts:
            if asset_type is None:
                vectors = [row for row in all_embeddings if compatible(row)]
            else:
                allowed_ids = db.available_asset_ids(asset_type=asset_type)
                vectors = [row for row in all_embeddings if compatible(row) and row["asset_id"] in allowed_ids]
        else:
            vectors = [row for row in all_embeddings if compatible(row) and row["asset_id"] in documents]
        plan["embedding_count"] = len(vectors)
        if vectors:
            try:
                query_vector = normalized(list(embed_query(query)))
                ranked = []
                if use_fts and not identifiers:
                    candidates = vectors
                elif use_fts:
                    candidates = [
                        row for row in vectors
                        if row["asset_id"] in documents
                        and all(token in documents[row["asset_id"]]["search_text"].lower() for token in identifiers)
                    ]
                else:
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

    if use_fts and results:
        missing_ids = [result["asset_id"] for result in results[:limit] if result["asset_id"] not in documents]
        if missing_ids:
            for row in db.search_docs_by_ids(missing_ids, include_unindexed=hybrid, asset_type=asset_type):
                documents[row["asset_id"]] = row

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

# >>> fast-anything: photo_search.search.score_lexical_docs >>>
# Uses the verified Rust port. FAST_ANYTHING_DISABLE=1 runs the Python above instead.
# Undo with:  fast-anything disable photo_search.search.score_lexical_docs
def _fast_anything_load():
    import os, sys
    if os.environ.get("FAST_ANYTHING_DISABLE"):
        return None
    lib = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../.fast/lib"))
    if lib not in sys.path:
        sys.path.append(lib)
    try:
        from fa_photo_search_search_score_lexical_docs import score_lexical_docs
    except ImportError:
        return None
    return score_lexical_docs
score_lexical_docs = _fast_anything_load() or score_lexical_docs
del _fast_anything_load
# <<< fast-anything: photo_search.search.score_lexical_docs <<<
