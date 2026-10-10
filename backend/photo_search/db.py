from __future__ import annotations

import json
import os
import sqlite3
from array import array
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

from .config import DATABASE_PATH, ensure_app_dirs


SCHEMA = """
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS assets (
    id TEXT PRIMARY KEY,
    source_kind TEXT NOT NULL,
    source_identifier TEXT NOT NULL,
    file_path TEXT NOT NULL,
    thumbnail_path TEXT NOT NULL,
    sha256 TEXT NOT NULL,
    filename TEXT NOT NULL,
    captured_at TEXT,
    width INTEGER,
    height INTEGER,
    metadata_json TEXT NOT NULL,
    imported_at TEXT NOT NULL,
    is_available INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS assets_sha256_idx ON assets(sha256);
CREATE INDEX IF NOT EXISTS assets_captured_at_idx ON assets(captured_at);

CREATE TABLE IF NOT EXISTS artifacts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    producer TEXT NOT NULL,
    model TEXT NOT NULL DEFAULT '',
    prompt_version TEXT NOT NULL DEFAULT '',
    schema_version TEXT NOT NULL DEFAULT '',
    preprocess_version TEXT NOT NULL DEFAULT '',
    input_sha256 TEXT NOT NULL,
    data_json TEXT NOT NULL,
    raw_text TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    is_active INTEGER NOT NULL DEFAULT 1,
    UNIQUE(asset_id, kind, producer, model, prompt_version, schema_version, preprocess_version, input_sha256)
);

CREATE INDEX IF NOT EXISTS artifacts_active_idx ON artifacts(asset_id, kind, is_active);

CREATE TABLE IF NOT EXISTS embeddings (
    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    namespace TEXT NOT NULL,
    model TEXT NOT NULL,
    model_revision TEXT NOT NULL DEFAULT '',
    prompt_version TEXT NOT NULL DEFAULT '',
    input_sha256 TEXT NOT NULL,
    dimensions INTEGER NOT NULL,
    vector BLOB NOT NULL,
    created_at TEXT NOT NULL,
    is_active INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY(asset_id, namespace, model, model_revision, prompt_version, input_sha256)
);

CREATE TABLE IF NOT EXISTS search_docs (
    asset_id TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
    asset_type TEXT NOT NULL DEFAULT 'other',
    short_caption TEXT NOT NULL DEFAULT '',
    search_text TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(
    asset_id UNINDEXED,
    search_text,
    tokenize='trigram'
);

CREATE TABLE IF NOT EXISTS processing_errors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    asset_id TEXT REFERENCES assets(id) ON DELETE CASCADE,
    stage TEXT NOT NULL,
    error TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS processing_skips (
    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    stage TEXT NOT NULL,
    reason TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY(asset_id, stage)
);
"""


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def search_values(value: Any) -> Iterator[str]:
    """Yield searchable leaf values without indexing schema field names."""
    if isinstance(value, str):
        cleaned = value.strip()
        if cleaned:
            yield cleaned
    elif isinstance(value, dict):
        for child in value.values():
            yield from search_values(child)
    elif isinstance(value, (list, tuple)):
        for child in value:
            yield from search_values(child)
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        yield str(value)


class Database:
    def __init__(self, path: Path = DATABASE_PATH):
        ensure_app_dirs()
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.conn = sqlite3.connect(self.path)
        self.conn.row_factory = sqlite3.Row
        self.conn.executescript(SCHEMA)
        self.conn.commit()
        self._migrate()
        try:
            os.chmod(self.path, 0o600)
        except FileNotFoundError:
            pass

    def _migrate(self) -> None:
        if self.conn.execute("PRAGMA user_version").fetchone()[0] >= 1:
            return
        with self.conn:
            self.conn.execute("BEGIN IMMEDIATE")
            columns = {row[1] for row in self.conn.execute("PRAGMA table_info(assets)")}
            if "is_available" not in columns:
                self.conn.execute("ALTER TABLE assets ADD COLUMN is_available INTEGER NOT NULL DEFAULT 1")
            columns = {row[1] for row in self.conn.execute("PRAGMA table_info(embeddings)")}
            if "input_sha256" not in columns:
                self.conn.execute("ALTER TABLE embeddings RENAME TO embeddings_legacy")
                self.conn.execute("""
                    CREATE TABLE embeddings (
                        asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                        namespace TEXT NOT NULL, model TEXT NOT NULL,
                        model_revision TEXT NOT NULL DEFAULT '', prompt_version TEXT NOT NULL DEFAULT '',
                        input_sha256 TEXT NOT NULL, dimensions INTEGER NOT NULL, vector BLOB NOT NULL,
                        created_at TEXT NOT NULL, is_active INTEGER NOT NULL DEFAULT 1,
                        PRIMARY KEY(asset_id, namespace, model, model_revision, prompt_version, input_sha256)
                    )
                """)
                # Previous imports never replaced cached previews. Bind those vectors
                # to the existing cache hash before enabling source-change detection.
                self.conn.execute("""
                    INSERT INTO embeddings
                    SELECT e.asset_id,e.namespace,e.model,e.model_revision,e.prompt_version,
                           a.sha256,e.dimensions,e.vector,e.created_at,e.is_active
                    FROM embeddings_legacy e JOIN assets a ON a.id=e.asset_id
                """)
                self.conn.execute("DROP TABLE embeddings_legacy")
            self.conn.execute("PRAGMA user_version=1")

    def close(self) -> None:
        self.conn.close()

    def __enter__(self) -> "Database":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        with self.conn:
            yield self.conn

    def upsert_asset(self, asset: dict[str, Any]) -> None:
        previous = self.get_asset(asset["id"])
        changed = previous is not None and previous["sha256"] != asset["sha256"]
        with self.transaction() as conn:
            if changed:
                conn.execute("UPDATE artifacts SET is_active=0 WHERE asset_id=?", (asset["id"],))
                conn.execute("UPDATE embeddings SET is_active=0 WHERE asset_id=?", (asset["id"],))
                conn.execute("DELETE FROM search_docs WHERE asset_id=?", (asset["id"],))
                conn.execute("DELETE FROM search_fts WHERE asset_id=?", (asset["id"],))
                conn.execute("DELETE FROM processing_skips WHERE asset_id=?", (asset["id"],))
            elif previous and not previous["is_available"]:
                conn.execute("DELETE FROM processing_skips WHERE asset_id=?", (asset["id"],))
            conn.execute(
                """
                INSERT INTO assets(
                    id, source_kind, source_identifier, file_path, thumbnail_path,
                    sha256, filename, captured_at, width, height, metadata_json, imported_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_kind=CASE
                        WHEN assets.source_kind='apple-photos-full' THEN assets.source_kind
                        ELSE excluded.source_kind
                    END,
                    source_identifier=excluded.source_identifier,
                    file_path=excluded.file_path,
                    thumbnail_path=excluded.thumbnail_path,
                    sha256=excluded.sha256,
                    filename=excluded.filename,
                    captured_at=excluded.captured_at,
                    width=excluded.width,
                    height=excluded.height,
                    metadata_json=excluded.metadata_json,
                    is_available=1
                """,
                (
                    asset["id"], asset["source_kind"], asset["source_identifier"],
                    asset["file_path"], asset["thumbnail_path"], asset["sha256"],
                    asset["filename"], asset.get("captured_at"), asset.get("width"),
                    asset.get("height"), json.dumps(asset.get("metadata", {}), ensure_ascii=False),
                    now_iso(),
                ),
            )
        if previous and not changed and self.active_artifact(asset["id"], "annotation") and (
            not previous["is_available"] or previous["metadata_json"] != json.dumps(asset.get("metadata", {}), ensure_ascii=False)
            or previous["captured_at"] != asset.get("captured_at")
        ):
            self.rebuild_search_doc(asset["id"])

    def reconcile_photos(self, present_ids: set[str], *, failed_ids: set[str] | None = None,
                         media_types: set[str] | None = None) -> int:
        """Hide missing/inaccessible source assets; keep previews and derived history."""
        unavailable = [row["id"] for row in self.conn.execute(
            "SELECT id, metadata_json FROM assets WHERE source_kind IN ('apple-photos','apple-photos-full','apple-photos-benchmark') AND is_available=1"
        ) if (media_types is None or json.loads(row["metadata_json"]).get("media_type", "image") in media_types)
             and (row["id"] not in present_ids or row["id"] in (failed_ids or set()))]
        with self.transaction() as conn:
            conn.executemany("UPDATE assets SET is_available=0 WHERE id=?", ((id_,) for id_ in unavailable))
        return len(unavailable)

    def assets(self, limit: int | None = None) -> list[sqlite3.Row]:
        sql = "SELECT * FROM assets WHERE is_available=1 ORDER BY captured_at DESC, imported_at DESC"
        params: tuple[Any, ...] = ()
        if limit is not None:
            sql += " LIMIT ?"
            params = (limit,)
        return list(self.conn.execute(sql, params))

    def assets_missing_artifact(
        self,
        *,
        kind: str,
        producer: str,
        model: str,
        prompt_version: str,
        schema_version: str,
        preprocess_version: str,
        source_kinds: set[str] | None = None,
        skip_stage: str | None = None,
        limit: int | None = None,
    ) -> list[sqlite3.Row]:
        conditions = ["a.is_available=1",
            """
            NOT EXISTS (
                SELECT 1 FROM artifacts r
                WHERE r.asset_id=a.id AND r.kind=? AND r.producer=? AND r.model=? AND r.is_active=1
                  AND r.prompt_version=? AND r.schema_version=?
                  AND r.preprocess_version=? AND r.input_sha256=a.sha256
            )
            """
        ]
        params: list[Any] = [
            kind, producer, model, prompt_version, schema_version, preprocess_version,
        ]
        if source_kinds:
            placeholders = ", ".join("?" for _ in source_kinds)
            conditions.append(f"a.source_kind IN ({placeholders})")
            params.extend(sorted(source_kinds))
        if skip_stage:
            conditions.append(
                "NOT EXISTS (SELECT 1 FROM processing_skips s WHERE s.asset_id=a.id AND s.stage=?)"
            )
            params.append(skip_stage)

        sql = f"""
            SELECT a.* FROM assets a
            WHERE {' AND '.join(conditions)}
            ORDER BY a.captured_at DESC, a.imported_at DESC
        """
        if limit is not None:
            sql += " LIMIT ?"
            params.append(limit)
        return list(self.conn.execute(sql, params))

    def assets_missing_active_artifact(
        self,
        *,
        kind: str,
        source_kinds: set[str] | None = None,
        skip_stage: str | None = None,
        limit: int | None = None,
    ) -> list[sqlite3.Row]:
        conditions = ["a.is_available=1",
            """
            NOT EXISTS (
                SELECT 1 FROM artifacts r
                WHERE r.asset_id=a.id AND r.kind=? AND r.is_active=1
                  AND r.input_sha256=a.sha256
            )
            """
        ]
        params: list[Any] = [kind]
        if source_kinds:
            placeholders = ", ".join("?" for _ in source_kinds)
            conditions.append(f"a.source_kind IN ({placeholders})")
            params.extend(sorted(source_kinds))
        if skip_stage:
            conditions.append(
                "NOT EXISTS (SELECT 1 FROM processing_skips s WHERE s.asset_id=a.id AND s.stage=?)"
            )
            params.append(skip_stage)
        sql = f"""
            SELECT a.* FROM assets a
            WHERE {' AND '.join(conditions)}
            ORDER BY a.captured_at DESC, a.imported_at DESC
        """
        if limit is not None:
            sql += " LIMIT ?"
            params.append(limit)
        return list(self.conn.execute(sql, params))

    def get_asset(self, asset_id: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM assets WHERE id = ?", (asset_id,)).fetchone()

    def has_artifact(
        self,
        asset_id: str,
        kind: str,
        producer: str,
        model: str,
        prompt_version: str,
        schema_version: str,
        preprocess_version: str,
        input_sha256: str,
    ) -> bool:
        row = self.conn.execute(
            """
            SELECT 1 FROM artifacts
            WHERE asset_id=? AND kind=? AND producer=? AND model=?
              AND prompt_version=? AND schema_version=? AND preprocess_version=?
              AND input_sha256=? AND is_active=1
            """,
            (
                asset_id, kind, producer, model, prompt_version, schema_version,
                preprocess_version, input_sha256,
            ),
        ).fetchone()
        return row is not None

    def add_artifact(
        self,
        *,
        asset_id: str,
        kind: str,
        producer: str,
        model: str = "",
        prompt_version: str = "",
        schema_version: str = "",
        preprocess_version: str = "",
        input_sha256: str,
        data: dict[str, Any],
        raw_text: str = "",
    ) -> None:
        with self.transaction() as conn:
            asset = self.get_asset(asset_id)
            active = int(asset is not None and asset["sha256"] == input_sha256 and asset["is_available"])
            if active:
                conn.execute("UPDATE artifacts SET is_active=0 WHERE asset_id=? AND kind=?", (asset_id, kind))
            conn.execute(
                """
                INSERT INTO artifacts(
                    asset_id, kind, producer, model, prompt_version, schema_version,
                    preprocess_version, input_sha256, data_json, raw_text, created_at, is_active
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(asset_id, kind, producer, model, prompt_version, schema_version, preprocess_version, input_sha256)
                DO UPDATE SET data_json=excluded.data_json, raw_text=excluded.raw_text,
                              created_at=excluded.created_at, is_active=excluded.is_active
                """,
                (
                    asset_id, kind, producer, model, prompt_version, schema_version,
                    preprocess_version, input_sha256,
                    json.dumps(data, ensure_ascii=False), raw_text, now_iso(), active,
                ),
            )

            if active and kind == "annotation" and json.loads(asset["metadata_json"]).get("media_type") == "video":
                conn.execute("UPDATE embeddings SET is_active=0 WHERE asset_id=? AND namespace='video-retrieval-v1'", (asset_id,))

    def active_artifact(self, asset_id: str, kind: str) -> dict[str, Any] | None:
        row = self.conn.execute(
            """
            SELECT r.* FROM artifacts r JOIN assets a ON a.id=r.asset_id
            WHERE r.asset_id=? AND r.kind=? AND r.is_active=1
              AND r.input_sha256=a.sha256 AND a.is_available=1
            ORDER BY r.id DESC LIMIT 1
            """,
            (asset_id, kind),
        ).fetchone()
        if row is None:
            return None
        result = dict(row)
        result["data"] = json.loads(result.pop("data_json"))
        return result

    def rebuild_search_doc(self, asset_id: str) -> None:
        asset = self.get_asset(asset_id)
        if asset is None or not asset["is_available"]:
            return
        ocr = self.active_artifact(asset_id, "ocr")
        annotation = self.active_artifact(asset_id, "annotation")
        transcript = self.active_artifact(asset_id, "transcript")
        scenes = self.active_artifact(asset_id, "video-scenes")
        if ocr is None and annotation is None:
            return
        ocr_data = ocr["data"] if ocr else {}
        ann_data = annotation["data"] if annotation else {}
        searchable = [
            asset["filename"],
            asset["captured_at"] or "",
            {key: value for key, value in json.loads(asset["metadata_json"]).items()
             if key not in {"preview_mtime_ns", "preview_size", "source_modified_at", "preprocess_version", "sampling_strategy"}},
            ocr_data.get("text", ""),
            transcript["data"].get("text", "") if transcript else "",
            transcript["data"].get("original_text", "") if transcript else "",
            scenes["data"].get("chunks", []) if scenes else [],
            ann_data,
        ]
        search_text = "\n".join(search_values(searchable)).lower()
        asset_type = "video" if json.loads(asset["metadata_json"]).get("media_type") == "video" else str(ann_data.get("asset_type") or "other")
        short_caption = str(ann_data.get("short_caption") or "")
        with self.transaction() as conn:
            conn.execute(
                """
                INSERT INTO search_docs(asset_id, asset_type, short_caption, search_text, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET
                    asset_type=excluded.asset_type,
                    short_caption=excluded.short_caption,
                    search_text=excluded.search_text,
                    updated_at=excluded.updated_at
                """,
                (asset_id, asset_type, short_caption, search_text, now_iso()),
            )
            conn.execute("DELETE FROM search_fts WHERE asset_id=?", (asset_id,))
            conn.execute(
                "INSERT INTO search_fts(asset_id, search_text) VALUES (?, ?)",
                (asset_id, search_text),
            )

    def search_docs(self, *, include_unindexed: bool = False) -> list[sqlite3.Row]:
        return list(
            self.conn.execute(
                """
                SELECT a.id AS asset_id, COALESCE(d.asset_type, CASE WHEN json_extract(a.metadata_json, '$.media_type')='video' THEN 'video' ELSE 'other' END) AS asset_type,
                       COALESCE(d.short_caption, '') AS short_caption,
                       COALESCE(d.search_text, '') AS search_text, d.updated_at,
                       a.thumbnail_path, a.file_path, a.filename, a.captured_at, a.width, a.height
                FROM assets a LEFT JOIN search_docs d ON a.id=d.asset_id
                WHERE a.is_available=1 AND (? OR d.asset_id IS NOT NULL)
                """,
                (include_unindexed,),
            )
        )

    def upsert_embedding(
        self,
        *,
        asset_id: str,
        namespace: str,
        model: str,
        model_revision: str,
        prompt_version: str,
        vector: list[float],
        input_sha256: str | None = None,
    ) -> None:
        packed = array("f", vector).tobytes()
        with self.transaction() as conn:
            asset = self.get_asset(asset_id)
            if asset is None:
                raise ValueError("Embedding asset does not exist")
            input_sha256 = input_sha256 if input_sha256 is not None else asset["sha256"]
            active = int(asset["sha256"] == input_sha256 and asset["is_available"])
            if active:
                conn.execute("UPDATE embeddings SET is_active=0 WHERE asset_id=? AND namespace=?", (asset_id, namespace))
            conn.execute(
                """
                INSERT INTO embeddings(
                    asset_id, namespace, model, model_revision, prompt_version,
                    input_sha256, dimensions, vector, created_at, is_active
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(asset_id, namespace, model, model_revision, prompt_version, input_sha256)
                DO UPDATE SET dimensions=excluded.dimensions, vector=excluded.vector,
                              created_at=excluded.created_at, is_active=excluded.is_active
                """,
                (
                    asset_id, namespace, model, model_revision, prompt_version,
                    input_sha256, len(vector), packed, now_iso(), active,
                ),
            )

    def active_embeddings(self, namespace: str, *, decode_vectors: bool = True) -> list[dict[str, Any]]:
        rows = self.conn.execute(
            """
            SELECT e.*, a.filename, a.thumbnail_path
            FROM embeddings e JOIN assets a ON a.id=e.asset_id
            WHERE e.namespace=? AND e.is_active=1 AND e.input_sha256=a.sha256 AND a.is_available=1
            """,
            (namespace,),
        )
        result: list[dict[str, Any]] = []
        for row in rows:
            item = dict(row)
            if decode_vectors:
                values = array("f")
                values.frombytes(item.pop("vector"))
                item["vector"] = list(values)
            result.append(item)
        return result

    def record_error(self, asset_id: str | None, stage: str, error: str) -> None:
        with self.transaction() as conn:
            conn.execute(
                "INSERT INTO processing_errors(asset_id, stage, error, created_at) VALUES (?, ?, ?, ?)",
                (asset_id, stage, error[:8000], now_iso()),
            )

    def error_count(self, asset_id: str, stage: str) -> int:
        return int(
            self.conn.execute(
                "SELECT COUNT(*) FROM processing_errors WHERE asset_id=? AND stage=?",
                (asset_id, stage),
            ).fetchone()[0]
        )

    def mark_processing_skip(self, asset_id: str, stage: str, reason: str) -> None:
        with self.transaction() as conn:
            conn.execute(
                """
                INSERT INTO processing_skips(asset_id, stage, reason, created_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(asset_id, stage) DO UPDATE SET
                    reason=excluded.reason, created_at=excluded.created_at
                """,
                (asset_id, stage, reason[:8000], now_iso()),
            )

    def is_processing_skipped(self, asset_id: str, stage: str) -> bool:
        return self.conn.execute(
            "SELECT 1 FROM processing_skips WHERE asset_id=? AND stage=?",
            (asset_id, stage),
        ).fetchone() is not None

    def release_processing_skips(self, stage: str, before: str) -> int:
        with self.transaction() as conn:
            cursor = conn.execute(
                "DELETE FROM processing_skips WHERE stage=? AND created_at<=?",
                (stage, before),
            )
        return max(0, cursor.rowcount)

    def embedding_pending(self, *, namespace: str, model: str, revision: str,
                          prompt: str, dimensions: int, limit: int | None = None,
                          count: bool = False, media_type: str = "image"):
        columns = "COUNT(*)" if count else "a.*"
        sql = f"""SELECT {columns} FROM assets a WHERE a.is_available=1
            AND NOT EXISTS (
                SELECT 1 FROM embeddings e WHERE e.asset_id=a.id AND e.namespace=?
                AND e.model=? AND e.model_revision=? AND e.prompt_version=? AND e.dimensions=?
                AND e.input_sha256=a.sha256 AND e.is_active=1)
            AND NOT EXISTS (SELECT 1 FROM processing_skips s WHERE s.asset_id=a.id AND s.stage='embedding')
        """
        sql += " AND COALESCE(json_extract(a.metadata_json, '$.media_type'), 'image')=?"
        args: list[Any] = [namespace, model, revision, prompt, dimensions, media_type]
        if media_type == "video":
            sql += " AND EXISTS (SELECT 1 FROM artifacts r WHERE r.asset_id=a.id AND r.kind='annotation' AND r.is_active=1 AND r.input_sha256=a.sha256)"
        if not count:
            sql += " ORDER BY a.captured_at DESC, a.imported_at DESC"
            if limit is not None:
                sql += " LIMIT ?"
                args.append(limit)
        cursor = self.conn.execute(sql, args)
        return int(cursor.fetchone()[0]) if count else list(cursor)

    def stats(self) -> dict[str, int]:
        names = ("assets", "artifacts", "search_docs", "embeddings", "processing_errors")
        counts = {
            name: int(self.conn.execute(f"SELECT COUNT(*) FROM {name}").fetchone()[0])
            for name in names
        }
        counts["assets"] = self.conn.execute("SELECT COUNT(*) FROM assets WHERE is_available=1").fetchone()[0]
        counts["search_docs"] = self.conn.execute("SELECT COUNT(*) FROM search_docs d JOIN assets a ON a.id=d.asset_id WHERE a.is_available=1").fetchone()[0]
        return counts

    def pipeline_counts(self, source_prefix: str = "apple-photos-") -> dict[str, int]:
        pattern = source_prefix + "%"
        assets = int(
            self.conn.execute(
                "SELECT COUNT(*) FROM assets WHERE source_kind LIKE ? AND is_available=1", (pattern,)
            ).fetchone()[0]
        )
        ocr = int(
            self.conn.execute(
                """
                SELECT COUNT(DISTINCT a.id)
                FROM assets a JOIN artifacts r ON r.asset_id=a.id
                WHERE a.source_kind LIKE ? AND a.is_available=1 AND r.kind='ocr' AND r.is_active=1 AND r.input_sha256=a.sha256
                """,
                (pattern,),
            ).fetchone()[0]
        )
        annotated = int(
            self.conn.execute(
                """
                SELECT COUNT(DISTINCT a.id)
                FROM assets a JOIN artifacts r ON r.asset_id=a.id
                WHERE a.source_kind LIKE ? AND a.is_available=1 AND r.kind='annotation' AND r.is_active=1 AND r.input_sha256=a.sha256
                """,
                (pattern,),
            ).fetchone()[0]
        )
        skipped = int(
            self.conn.execute(
                """
                SELECT COUNT(DISTINCT a.id)
                FROM assets a JOIN processing_skips s ON s.asset_id=a.id
                WHERE a.source_kind LIKE ? AND a.is_available=1 AND s.stage='index'
                """,
                (pattern,),
            ).fetchone()[0]
        )
        videos_annotated = int(self.conn.execute(
            """SELECT COUNT(DISTINCT a.id) FROM assets a JOIN artifacts r ON r.asset_id=a.id
               WHERE a.source_kind LIKE ? AND a.is_available=1
                 AND json_extract(a.metadata_json, '$.media_type')='video'
                 AND r.kind='annotation' AND r.is_active=1 AND r.input_sha256=a.sha256""",
            (pattern,),
        ).fetchone()[0])
        return {"assets": assets, "ocr": ocr, "annotated": annotated, "skipped": skipped,
                "videos_annotated": videos_annotated}
