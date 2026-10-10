import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from photo_search.db import Database
from photo_search.embeddings import (
    DIMENSIONS, EMBEDDING_MODEL, EMBEDDING_NAMESPACE, EMBEDDING_PROMPT,
    EMBEDDING_REVISION, VIDEO_EMBEDDING_NAMESPACE, VIDEO_EMBEDDING_PROMPT,
    embedding_count,
)
from photo_search.worker import run_full_library_worker


class EmbeddingCountTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.path = self.root / "index.sqlite3"
        self.db = Database(self.path)

    def tearDown(self):
        self.db.close()
        self.temporary.cleanup()

    def add_asset(self, id_, source="apple-photos-full", video=False):
        self.db.upsert_asset(dict(
            id=id_, source_kind=source, source_identifier=id_, file_path="/unused",
            thumbnail_path="/unused", sha256=id_, filename=id_,
            metadata={"media_type": "video" if video else "image"},
        ))
        self.db.upsert_embedding(
            asset_id=id_, namespace=VIDEO_EMBEDDING_NAMESPACE if video else EMBEDDING_NAMESPACE,
            model=EMBEDDING_MODEL, model_revision=EMBEDDING_REVISION,
            prompt_version=VIDEO_EMBEDDING_PROMPT if video else EMBEDDING_PROMPT,
            vector=[1.0] + [0.0] * (DIMENSIONS - 1),
        )

    def test_library_coverage_includes_videos_but_excludes_local_imports(self):
        self.add_asset("photo")
        self.add_asset("video", video=True)
        self.add_asset("local", source="file")
        self.assertEqual(embedding_count(self.db), 3)
        self.assertEqual(embedding_count(self.db, source_kind="apple-photos-full"), 2)

    def test_unavailable_and_obsolete_vectors_do_not_count(self):
        for id_ in ("current", "deleted", "changed", "inactive", "old-model"):
            self.add_asset(id_)
        self.db.reconcile_photos({"current", "changed", "inactive", "old-model"})
        with self.db.transaction() as conn:
            conn.execute("UPDATE assets SET sha256='edited' WHERE id='changed'")
            conn.execute("UPDATE embeddings SET is_active=0 WHERE asset_id='inactive'")
            conn.execute("UPDATE embeddings SET model_revision='old' WHERE asset_id='old-model'")
        self.assertEqual(embedding_count(self.db, source_kind="apple-photos-full"), 1)

    def test_worker_refreshes_coverage_after_deletion_without_encoding_a_batch(self):
        self.add_asset("remaining")
        self.add_asset("deleted")
        self.add_asset("local", source="file")
        self.db.reconcile_photos({"remaining"})
        state = {"status": "complete", "library_images": 1, "embedded": 3}
        provider = SimpleNamespace(id="test", name="Test", model="test")
        with patch("photo_search.worker.ensure_app_dirs"), \
             patch("photo_search.worker.LOCK_PATH", self.root / "worker.lock"), \
             patch("photo_search.worker.load_worker_status", return_value=state), \
             patch("photo_search.worker.load_provider", return_value=provider), \
             patch("photo_search.worker.start_heartbeat", return_value=lambda: None), \
             patch("photo_search.worker.sync_due", return_value=False), \
             patch("photo_search.worker.Database", side_effect=lambda: Database(self.path)), \
             patch("photo_search.embedding_worker.Database", side_effect=lambda: Database(self.path)), \
             patch("photo_search.worker.pending_annotation_assets", return_value=[]), \
             patch("photo_search.worker.load_embedding_status", return_value={
                 "status": "complete", "total": 3, "pending": 99,
             }), \
             patch("photo_search.worker.run_embedding_batch") as encode, \
             patch("photo_search.worker.write_worker_status"):
            result = run_full_library_worker()
        encode.assert_not_called()
        self.assertEqual(result["embedded"], 1)
        self.assertEqual(result["assets"], 1)
        self.assertEqual(result["embedding_pending"], 0)
        self.assertEqual(result["status"], "complete")
