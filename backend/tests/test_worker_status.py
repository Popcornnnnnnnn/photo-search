import threading
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import MagicMock, patch

from photo_search import worker
from photo_search.providers import ModelProvider
from photo_search.worker import start_heartbeat


class WorkerStatusTests(unittest.TestCase):
    def test_embedding_only_work_does_not_load_an_unused_annotation_model(self):
        for has_annotations in (False, True):
            with self.subTest(annotations_pending=has_annotations), tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
                events = []
                provider = ModelProvider("local", "Local", "local", "http://127.0.0.1:1234/v1", "vision", "local")
                db = MagicMock()
                db.__enter__.return_value = db
                db.release_processing_skips.return_value = 0
                db.pipeline_counts.return_value = {"skipped": 0, "annotated": 0}
                for name, value in {
                    "ensure_app_dirs": None, "load_worker_status": {}, "sync_due": False,
                    "load_provider": provider, "load_fallback_provider": None,
                    "Database": db, "start_heartbeat": lambda: None,
                    "write_worker_status": None, "uses_lm_studio": True,
                    "load_embedding_status": {"status": "complete"}, "embedding_count": 1,
                    "_confirm_model_reachable": None,
                }.items():
                    stack.enter_context(patch.object(worker, name, return_value=value))
                stack.enter_context(patch.object(worker, "LOCK_PATH", Path(tmp) / "worker.lock"))
                stack.enter_context(patch.object(worker, "pending_annotation_assets",
                    side_effect=[[{"id": "pending"}], []] if has_annotations else [[]]))
                stack.enter_context(patch.object(worker, "pending_embedding_count", side_effect=[1, 0]))
                stack.enter_context(patch.object(worker, "run_embedding_batch", side_effect=lambda: events.append("embedding")))
                stack.enter_context(patch.object(worker, "index_assets", side_effect=lambda *a, **k: events.append("annotation")))

                def load_model(_):
                    if not has_annotations:
                        raise RuntimeError("unused annotation model is unavailable")
                    events.append("model")

                load = stack.enter_context(patch.object(worker, "ensure_local_model", side_effect=load_model))
                state = worker.run_full_library_worker()
                self.assertEqual(state["status"], "complete")
                self.assertEqual(events, ["embedding", "model", "annotation"] if has_annotations else ["embedding"])
                self.assertEqual(load.call_count, int(has_annotations))

    def test_a_long_stage_keeps_its_status_fresh_until_it_finishes(self):
        state = {"status": "running", "stage": "indexing"}
        written = threading.Event()
        with patch("photo_search.worker.write_worker_status", side_effect=lambda _: written.set()) as write:
            stop = start_heartbeat(state, interval=0.01)
            try:
                self.assertTrue(written.wait(timeout=1))
            finally:
                stop()
            count = write.call_count
            self.assertGreater(count, 0)
            self.assertFalse(any(t.name == "photo-search-worker-heartbeat" for t in threading.enumerate()))

    def test_a_waiting_pipeline_is_not_reported_as_active_by_heartbeat(self):
        with patch("photo_search.worker.write_worker_status") as write:
            stop = start_heartbeat({"status": "waiting"}, interval=0.01)
            stop()
            write.assert_not_called()
