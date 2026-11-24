import fcntl
import json
import shutil
import sqlite3
import tempfile
import unittest
from array import array
from pathlib import Path
from unittest.mock import patch

from photo_search.cleanup_previews import prune_superseded_previews
from photo_search.db import Database
from photo_search.sources import import_full_photos_library, import_photos_manifest, sha256_file


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.db = Database(self.root / "index.sqlite3")
        self.assets = self.root / "assets"
        self.assets.mkdir()

    def tearDown(self):
        self.db.close()
        self.tmp.cleanup()

    def record(self, id_="photo", data=b"original", name="preview.jpg"):
        source = self.root / name
        source.write_bytes(data)
        return {"id": id_, "local_identifier": id_, "path": str(source), "filename": name,
                "width": 100, "height": 100, "modified_at": "2026-09-22T00:00:00Z"}

    def ingest(self, records, snapshot=None):
        manifest = self.root / "manifest.jsonl"
        manifest.write_text("".join(json.dumps(r) + "\n" for r in records))
        with patch("photo_search.sources.ASSET_DIR", self.assets):
            return import_photos_manifest(self.db, manifest, "apple-photos-full", snapshot=snapshot)

    def enrich(self):
        digest = self.db.get_asset("photo")["sha256"]
        self.db.add_artifact(asset_id="photo", kind="annotation", producer="test", input_sha256=digest,
                             data={"short_caption": "old blue bicycle", "asset_type": "photo"})
        self.db.rebuild_search_doc("photo")
        self.db.upsert_embedding(asset_id="photo", namespace="test", model="model", model_revision="1",
                                 prompt_version="1", vector=[1.0, 0.0], input_sha256=digest)
        return digest

    def test_edit_replaces_preview_and_invalidates_derived_data(self):
        self.ingest([self.record()])
        old_hash = self.enrich()
        changed = self.record(data=b"edited red bicycle", name="preview-v2.jpg")
        self.ingest([changed])
        asset = self.db.get_asset("photo")
        self.assertNotEqual(asset["sha256"], old_hash)
        self.assertEqual(Path(asset["file_path"]).read_bytes(), b"edited red bicycle")
        self.assertIsNone(self.db.active_artifact("photo", "annotation"))
        self.assertEqual(self.db.search_docs(), [])
        self.assertEqual(self.db.active_embeddings("test"), [])
        self.assertEqual(self.db.conn.execute("SELECT COUNT(*) FROM artifacts").fetchone()[0], 1)

        # Results computed before the edit must not reactivate the old content.
        self.db.add_artifact(asset_id="photo", kind="annotation", producer="test", input_sha256=old_hash,
                             data={"short_caption": "stale result"})
        self.db.upsert_embedding(asset_id="photo", namespace="test", model="model", model_revision="1",
                                 prompt_version="1", vector=[1.0, 0.0], input_sha256=old_hash)
        self.db.rebuild_search_doc("photo")
        self.assertEqual(self.db.search_docs(), [])
        self.assertEqual(self.db.active_embeddings("test"), [])
        self.db.upsert_embedding(asset_id="photo", namespace="test", model="model", model_revision="1",
                                 prompt_version="1", vector=[0.0, 1.0], input_sha256=asset["sha256"])
        self.assertEqual(self.db.active_embeddings("test")[0]["vector"], [0.0, 1.0])
        self.assertEqual(self.db.conn.execute("SELECT COUNT(*) FROM embeddings").fetchone()[0], 2)

    def test_unchanged_scan_does_not_rehash_or_rewrite_preview(self):
        record = self.record()
        self.ingest([record])
        self.enrich()
        with patch("photo_search.sources.sha256_file", side_effect=AssertionError("unchanged preview rehashed")), \
             patch("photo_search.sources.shutil.copy2", side_effect=AssertionError("unchanged preview copied")):
            self.ingest([record])
            # Metadata-only modified_at bump reusing the same preview file updates metadata without rehashing or invalidating index data.
            bumped = {**record, "modified_at": "2026-11-15T04:00:00Z"}
            self.ingest([bumped])
        asset = self.db.get_asset("photo")
        self.assertEqual(json.loads(asset["metadata_json"])["source_modified_at"], "2026-11-15T04:00:00Z")
        self.assertIsNotNone(self.db.active_artifact("photo", "annotation"))
        self.assertEqual(len(self.db.search_docs()), 1)
        self.assertEqual(len(self.db.active_embeddings("test")), 1)

    def test_legacy_duplicate_migrates_to_one_preview_without_losing_index(self):
        record = self.record()
        self.ingest([record])
        original_hash = self.enrich()
        duplicate = self.assets / "preview.jpg"
        shutil.copy2(record["path"], duplicate)
        with self.db.conn:
            self.db.conn.execute("UPDATE assets SET file_path=?, thumbnail_path=? WHERE id='photo'",
                                 (str(duplicate), str(duplicate)))
        with patch("photo_search.sources.shutil.copy2", side_effect=AssertionError("preview copied again")):
            self.ingest([record])
        asset = self.db.get_asset("photo")
        self.assertEqual(asset["file_path"], record["path"])
        self.assertEqual(asset["thumbnail_path"], record["path"])
        self.assertEqual(asset["sha256"], original_hash)
        self.assertEqual(len(self.db.search_docs()), 1)
        self.assertEqual(len(self.db.active_embeddings("test")), 1)
        self.assertTrue(duplicate.exists())  # Migration does not delete existing files.

    def test_full_snapshot_hides_deleted_assets_and_restore_recovers_them(self):
        record = self.record()
        self.ingest([record]); self.enrich()
        self.ingest([], {"full_snapshot": True, "strategy": "all", "library_images": 0,
                         "present_ids": [], "failed_ids": []})
        self.assertEqual(self.db.get_asset("photo")["is_available"], 0)
        self.assertTrue(Path(self.db.get_asset("photo")["file_path"]).exists())
        self.assertEqual(self.db.search_docs(), [])
        self.assertEqual(self.db.active_embeddings("test"), [])
        self.ingest([record])
        self.assertEqual(len(self.db.search_docs()), 1)
        self.assertEqual(len(self.db.active_embeddings("test")), 1)

    def test_partial_or_broken_inventory_cannot_imply_deletion(self):
        self.ingest([self.record()]); self.enrich()
        self.ingest([], {"full_snapshot": False, "present_ids": [], "failed_ids": []})
        self.assertEqual(self.db.get_asset("photo")["is_available"], 1)
        with self.assertRaises(ValueError):
            self.ingest([], {"full_snapshot": True, "strategy": "all", "library_images": 1,
                             "present_ids": ["photo"], "failed_ids": []})
        self.assertEqual(self.db.get_asset("photo")["is_available"], 1)

    def test_failed_updated_preview_is_hidden_without_deleting_history(self):
        self.ingest([self.record()]); self.enrich()
        self.ingest([], {"full_snapshot": True, "strategy": "all", "library_images": 1,
                         "present_ids": ["photo"], "failed_ids": ["photo"]})
        self.assertEqual(self.db.search_docs(), [])
        self.assertEqual(self.db.conn.execute("SELECT COUNT(*) FROM artifacts").fetchone()[0], 1)

    def test_sync_prunes_superseded_previews_under_worker_lock(self):
        imports = self.root / "imports/photos-full"
        imports.mkdir(parents=True)
        asset_id = f"photos-{1:024x}"
        deleted_id = f"photos-{2:024x}"
        v1 = imports / f"{asset_id}-{'1' * 12}.jpg"
        v2 = imports / f"{asset_id}-{'2' * 12}.jpg"
        deleted_preview = imports / f"{deleted_id}-{'9' * 12}.jpg"
        v1.write_bytes(b"v1")
        deleted_preview.write_bytes(b"deleted")

        manifest = imports / "manifest.jsonl"
        manifest.write_text(
            json.dumps({"id": asset_id, "local_identifier": asset_id, "path": str(v1),
                        "filename": f"{asset_id}.jpg", "width": 100, "height": 100,
                        "modified_at": "2026-11-14T00:00:00Z"}) + "\n"
            + json.dumps({"id": deleted_id, "local_identifier": deleted_id, "path": str(deleted_preview),
                          "filename": f"{deleted_id}.jpg", "width": 100, "height": 100,
                          "modified_at": "2026-11-14T00:00:00Z"}) + "\n",
            encoding="utf-8",
        )
        import_photos_manifest(self.db, manifest, "apple-photos-full")

        # Before SQLite updates to v2, v1 is still referenced by SQLite and must not be removed.
        v2.write_bytes(b"v2")
        manifest.write_text(
            json.dumps({"id": asset_id, "local_identifier": asset_id, "path": str(v2),
                        "filename": f"{asset_id}.jpg", "width": 100, "height": 100,
                        "modified_at": "2026-11-15T00:00:00Z"}) + "\n",
            encoding="utf-8",
        )
        self.assertEqual(prune_superseded_previews(self.db.conn, imports, manifest), 0)
        self.assertTrue(v1.exists())

        def fake_export(output, limit, strategy):
            return {
                "manifest": str(manifest),
                "full_snapshot": True,
                "strategy": strategy,
                "library_assets": 1,
                "present_ids": [asset_id],
                "failed_ids": [],
            }

        with patch("photo_search.sources.APP_HOME", self.root), \
             patch("photo_search.sources.IMPORT_DIR", self.root / "imports"), \
             patch("photo_search.sources.ensure_app_dirs"), \
             patch("photo_search.sources.export_library_photos", side_effect=fake_export):
            with (self.root / "worker.lock").open("a+") as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaises(BlockingIOError):
                    import_full_photos_library(self.db)
                self.assertTrue(v1.exists())

            summary = import_full_photos_library(self.db)
            self.assertEqual(summary["pruned_previews"], 1)
            self.assertFalse(v1.exists())
            self.assertTrue(v2.exists())
            # Hidden/deleted asset previews remain intact until explicit cleanup.
            self.assertEqual(self.db.get_asset(deleted_id)["is_available"], 0)
            self.assertTrue(deleted_preview.exists())


class MigrationTests(unittest.TestCase):
    def test_existing_vectors_survive_idempotent_hash_migration(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "legacy.sqlite3"
            with sqlite3.connect(path) as c:
                c.executescript("""
                    CREATE TABLE assets(id TEXT PRIMARY KEY, source_kind TEXT, source_identifier TEXT,
                        file_path TEXT, thumbnail_path TEXT, sha256 TEXT, filename TEXT, captured_at TEXT,
                        width INTEGER, height INTEGER, metadata_json TEXT, imported_at TEXT);
                    CREATE TABLE embeddings(asset_id TEXT, namespace TEXT, model TEXT, model_revision TEXT,
                        prompt_version TEXT, dimensions INTEGER, vector BLOB, created_at TEXT, is_active INTEGER,
                        PRIMARY KEY(asset_id,namespace,model,model_revision,prompt_version));
                    INSERT INTO assets VALUES('a','file','a','a','a','hash-a','a',NULL,1,1,'{}','now');
                """)
                c.execute("INSERT INTO embeddings VALUES('a','ns','model','v','p',2,?,'now',1)", (array("f", [1, 0]).tobytes(),))
            for _ in range(2):
                with Database(path) as db:
                    vector = db.active_embeddings("ns")[0]
                    self.assertEqual(vector["input_sha256"], "hash-a")
                    self.assertEqual(vector["vector"], [1, 0])
                    self.assertEqual(db.get_asset("a")["is_available"], 1)
