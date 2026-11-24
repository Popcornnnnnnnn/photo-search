import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from photo_search.db import Database
from photo_search.embeddings import DIMENSIONS, embed_query, index_embeddings, local_embedder
from photo_search.embedding_worker import run_embedding_batch


class EmbeddingWorkerTests(unittest.TestCase):
    def test_image_batches_and_queries_reuse_one_model(self):
        local_embedder.cache_clear(); embed_query.cache_clear()
        try:
            with tempfile.TemporaryDirectory() as directory, Database(Path(directory) / "db.sqlite3") as db:
                for id_ in ("a", "b"):
                    db.upsert_asset(dict(id=id_, source_kind="file", source_identifier=id_, file_path="/unused",
                                         thumbnail_path="/unused", sha256=id_, filename=id_, metadata={}))
                with patch("photo_search.embeddings.LocalEmbedder") as factory:
                    factory.return_value.encode.return_value = [1.0] + [0.0] * (DIMENSIONS - 1)
                    index_embeddings(db, limit=1, progress=lambda *a, **kw: None)
                    embed_query("a new query")
                    index_embeddings(db, limit=1, progress=lambda *a, **kw: None)
                    factory.assert_called_once()
                    self.assertEqual(factory.return_value.encode.call_count, 3)
        finally:
            local_embedder.cache_clear(); embed_query.cache_clear()

    def test_model_failure_is_reported_without_stopping_search_process(self):
        states = []
        def fail(*args, **kwargs):
            raise RuntimeError("model unavailable")
        with tempfile.TemporaryDirectory() as directory, \
             patch("photo_search.embedding_worker.Database", side_effect=lambda: Database(Path(directory) / "db.sqlite3")), \
             patch("photo_search.embedding_worker.index_embeddings", side_effect=fail), \
             patch("photo_search.embedding_worker.load_embedding_status", return_value={}), \
             patch("photo_search.embedding_worker.write_embedding_status", side_effect=lambda state: states.append(dict(state))):
            run_embedding_batch()
        self.assertEqual(states[-1]["status"], "unavailable")
        self.assertIn("model unavailable", states[-1]["error"])
