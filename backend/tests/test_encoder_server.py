import unittest
from unittest.mock import patch

from photo_search import encoder_server


class EncoderServerTests(unittest.TestCase):
    """`embed` must answer with the vector and nothing before it.

    An extra `loaded` line ahead of the vector is read as that request's answer,
    which leaves the real vector in the pipe and desynchronises the next request.
    """

    def test_embed_answers_with_only_the_vector_when_already_loaded(self):
        events = []
        with patch.object(encoder_server, "_emit", side_effect=events.append), \
             patch.object(encoder_server, "is_loaded", return_value=True), \
             patch.object(encoder_server, "embed_query", return_value=(0.5, 0.5)):
            encoder_server._embed("约会")
        self.assertEqual([event["event"] for event in events], ["vector"])
        self.assertEqual(events[0]["vector"], [0.5, 0.5])

    def test_embed_loads_without_announcing_loaded(self):
        events = []
        with patch.object(encoder_server, "_emit", side_effect=events.append), \
             patch.object(encoder_server, "is_loaded", return_value=False), \
             patch.object(encoder_server, "load_local_embedder") as loader, \
             patch.object(encoder_server, "embed_query", return_value=(1.0,)):
            encoder_server._embed("约会")
        loader.assert_called_once()
        self.assertEqual([event["event"] for event in events], ["vector"])

    def test_empty_text_is_rejected_without_loading(self):
        events = []
        with patch.object(encoder_server, "_emit", side_effect=events.append), \
             patch.object(encoder_server, "load_local_embedder") as loader:
            encoder_server._embed("   ")
        loader.assert_not_called()
        self.assertEqual([event["event"] for event in events], ["error"])
