import threading
import unittest
from unittest.mock import patch

from photo_search.worker import start_heartbeat


class WorkerStatusTests(unittest.TestCase):
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
