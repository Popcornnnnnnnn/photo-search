import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from photo_search.db import Database
from photo_search.embeddings import (DIMENSIONS, EMBEDDING_MODEL, EMBEDDING_REVISION,
                                     EMBEDDING_NAMESPACE, EMBEDDING_PROMPT,
                                     VIDEO_EMBEDDING_NAMESPACE, VIDEO_EMBEDDING_PROMPT, index_embeddings)
from photo_search.native import NativeHelperError, export_library_photos
from photo_search.search import search
from photo_search.sources import import_photos_manifest
from photo_search.video import extract_frame, frame_times, index_video, probe_video, run_local, transcribe_video


class VideoTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        # These tests simulate decoding/transcription via run_local mocks. Tool
        # discovery must also be isolated from the developer machine's installs.
        tools = patch("photo_search.video.local_tool", side_effect=lambda name: str(self.root / name))
        tools.start()
        self.addCleanup(tools.stop)
        self.db = Database(self.root / "index.sqlite3")
        self.assets = self.root / "assets"
        self.assets.mkdir()
        self.video = self.root / "video.mov"
        self.video.write_bytes(b"video with audio")
        self.cover = self.root / "cover.jpg"
        self.cover.write_bytes(b"cover")
        self.record = {"id": "v", "local_identifier": "v/0", "path": str(self.video),
                       "thumbnail_path": str(self.cover), "filename": "video.mov", "media_type": "video",
                       "duration": 65, "width": 100, "height": 100}
        self.import_records([self.record])

    def tearDown(self):
        self.db.close()
        self.temporary.cleanup()

    def import_records(self, records, snapshot=None):
        manifest = self.root / "manifest.jsonl"
        manifest.write_text("".join(json.dumps(r) + "\n" for r in records))
        with patch("photo_search.sources.ASSET_DIR", self.assets):
            import_photos_manifest(self.db, manifest, "apple-photos-full", snapshot=snapshot)

    def enrich(self):
        a = self.db.get_asset("v")
        self.db.add_artifact(asset_id="v", kind="annotation", producer="test", input_sha256=a["sha256"],
                             data={"asset_type": "video", "short_caption": "海边骑行"})
        self.db.rebuild_search_doc("v")

    def test_video_content_edit_invalidates_speech_summary_and_vectors(self):
        self.enrich()
        a = self.db.get_asset("v")
        self.db.add_artifact(asset_id="v", kind="transcript", producer="local", input_sha256=a["sha256"],
                             data={"text": "original speech"})
        self.db.upsert_embedding(asset_id="v", namespace=VIDEO_EMBEDDING_NAMESPACE, model=EMBEDDING_MODEL,
                                 model_revision=EMBEDDING_REVISION, prompt_version=VIDEO_EMBEDDING_PROMPT,
                                 vector=[1] + [0] * (DIMENSIONS - 1))
        self.video.write_bytes(b"edited audio with identical cover")
        self.import_records([self.record])
        self.assertIsNone(self.db.active_artifact("v", "transcript"))
        self.assertIsNone(self.db.active_artifact("v", "annotation"))
        self.assertEqual(self.db.active_embeddings(VIDEO_EMBEDDING_NAMESPACE), [])
        self.assertEqual(self.db.search_docs(), [])

    def test_only_complete_mixed_inventory_can_hide_missing_video(self):
        self.enrich()
        self.import_records([], {"full_snapshot": True, "strategy": "all", "library_images": 0,
                                 "present_ids": [], "failed_ids": []})
        self.assertEqual(self.db.get_asset("v")["is_available"], 1)
        self.import_records([], {"full_snapshot": True, "strategy": "all", "library_assets": 0,
                                 "library_images": 0, "present_ids": [], "failed_ids": []})
        self.assertEqual(self.db.get_asset("v")["is_available"], 0)

    def test_permission_failure_cannot_reuse_a_previous_successful_manifest(self):
        output = self.root / "sync"
        output.mkdir()
        (output / "manifest.jsonl").write_text(json.dumps(self.record) + "\n")
        def denied(arguments, **kwargs):
            self.assertIn("--no-prompt", arguments)
            (output / "result.json").write_text(json.dumps({"error": "Photos access was not granted (status: 0)"}))
            return Mock(returncode=0, stderr="")
        with patch("photo_search.native.ensure_native"), patch("photo_search.native.subprocess.run", side_effect=denied):
            with self.assertRaisesRegex(NativeHelperError, "Photos access was not granted"):
                export_library_photos(output, 1, "all")

    def test_silent_video_does_not_require_speech_model(self):
        with patch("photo_search.video.run_local", side_effect=AssertionError("ASR should not run")):
            result = transcribe_video(self.video, {"has_audio": False}, self.root)
        self.assertEqual(result["status"], "no_audio")
        self.assertEqual(result["text"], "")

    def test_probe_uses_video_duration_when_audio_outlasts_picture(self):
        info = {"format": {"duration": "15.03"}, "streams": [
            {"codec_type": "video", "duration": "15.0"}, {"codec_type": "audio"}]}
        with patch("photo_search.video.run_local", return_value=json.dumps(info)):
            self.assertEqual(probe_video(self.video), {"duration": 15, "has_audio": True})

    def test_frame_times_are_ordered_and_do_not_sample_past_video_tail(self):
        for duration in (0.03, 5.077, 15.023, 65):
            times = frame_times(duration)
            self.assertEqual(times, sorted(set(times)))
            self.assertLessEqual(times[-1], max(0, duration - 0.1))

    def test_end_seek_retries_earlier_and_never_reuses_a_stale_frame(self):
        frame = self.root / "frame.jpg"
        frame.write_bytes(b"stale frame")
        def extract(arguments):
            self.assertFalse(frame.exists())
            if float(arguments[arguments.index("-ss") + 1]) == 12.41:
                frame.write_bytes(b"decoded frame")
        with patch("photo_search.video.run_local", side_effect=extract) as run:
            self.assertEqual(extract_frame(self.video, 12.66, frame), 12.41)
        self.assertEqual(run.call_count, 2)
        self.assertEqual(frame.read_bytes(), b"decoded frame")

    def test_unreadable_video_still_fails_instead_of_counting_as_indexed(self):
        with patch("photo_search.video.run_local"):
            with self.assertRaisesRegex(ValueError, "Unable to decode video frame"):
                extract_frame(self.video, 12.66, self.root / "missing.jpg")

    def test_malformed_console_utf8_does_not_hide_success_or_process_failure(self):
        command = [sys.executable, "-c", "import os; os.write(1, b'valid \\xe0\\xbc'); os.write(2, b'error \\xe0\\xbc')"]
        self.assertEqual(run_local(command), "valid \ufffd")
        with self.assertRaisesRegex(RuntimeError, "error"):
            run_local([*command[:-1], command[-1] + "; raise SystemExit(1)"])

    def test_speech_retains_readable_text_when_whisper_json_contains_bad_utf8(self):
        model = self.root / "model.bin"
        model.touch()
        def whisper(arguments, **kwargs):
            if "-oj" in arguments:
                data = {"result": {"language": "zh"}, "transcription": [
                    {"text": "蓝色灯塔 BAD", "offsets": {"from": 0, "to": 1000}}]}
                raw = json.dumps(data, ensure_ascii=False).encode("utf-8").replace(b"BAD", b"\xe0\xbc")
                (self.root / "speech.json").write_bytes(raw)
            return ""
        with patch.dict("os.environ", {"PHOTO_SEARCH_WHISPER_MODEL_PATH": str(model)}), \
             patch("photo_search.video.run_local", side_effect=whisper), \
             patch("photo_search.video.simplify_chinese", side_effect=lambda text: text):
            result = transcribe_video(self.video, {"duration": 2, "has_audio": True}, self.root)
        self.assertEqual(result["text"], "蓝色灯塔 \ufffd")
        self.assertIn("decode_warning", result)
        self.assertEqual(result["segments"][0]["end"], 1)

    def test_malformed_json_is_not_treated_as_an_empty_successful_transcript(self):
        model = self.root / "model.bin"
        model.touch()
        (self.root / "speech.json").write_bytes(b'{"transcription":')
        with patch.dict("os.environ", {"PHOTO_SEARCH_WHISPER_MODEL_PATH": str(model)}), \
             patch("photo_search.video.run_local"):
            with self.assertRaises(json.JSONDecodeError):
                transcribe_video(self.video, {"duration": 2, "has_audio": True}, self.root)

    def test_whole_video_resume_keeps_speech_and_details_missing_from_summary(self):
        self.assertEqual(frame_times(65)[0], 0)
        self.assertAlmostEqual(frame_times(65)[-1], 64.9)
        speech = {"text": "明天去蓝色灯塔", "segments": [{"start": 55, "end": 60, "text": "明天去蓝色灯塔"}],
                  "status": "transcribed"}
        provider = Mock(producer="test", model="vision")
        client = Mock()
        client.annotate_video_frames.side_effect = [({"short_caption": "海边骑车"}, ""), RuntimeError("interrupted")]
        client.summarize_video.return_value = ({"short_caption": "海边旅行"}, "{}")
        asset = self.db.get_asset("v")
        with patch("photo_search.video.probe_video", return_value={"duration": 65, "has_audio": True}), \
             patch("photo_search.video.transcribe_video", return_value=speech) as asr, \
             patch("photo_search.video.extract_frame", side_effect=lambda path, timestamp, destination: timestamp), \
             patch("photo_search.video.run_ocr", return_value={"text": "滨海公路"}):
            with self.assertRaisesRegex(RuntimeError, "interrupted"):
                index_video(self.db, asset, client, provider, lambda _: None)
            client.annotate_video_frames.side_effect = [({"short_caption": "灯塔和自行车"}, "")]
            index_video(self.db, asset, client, provider, lambda _: None)
        self.assertEqual(asr.call_count, 1)
        self.assertEqual(client.annotate_video_frames.call_count, 3)
        self.assertEqual(client.annotate_video_frames.call_args.args[0][0][0], 40)
        self.assertEqual(client.annotate_video_frames.call_args.args[1], "明天去蓝色灯塔")
        self.assertEqual(len(client.summarize_video.call_args.args[0]), 2)
        results = search(self.db, "蓝色灯塔", hybrid=False)["results"]
        self.assertEqual([r["asset_id"] for r in results], ["v"])
        self.assertEqual(results[0]["asset_type"], "video")
        self.assertIn("滨海公路", self.db.search_docs()[0]["search_text"])
        self.assertEqual(len(self.db.search_docs()), 1)

    def test_both_chinese_scripts_remain_searchable_without_summary_coverage(self):
        self.enrich()
        asset = self.db.get_asset("v")
        self.db.add_artifact(asset_id="v", kind="transcript", producer="local", input_sha256=asset["sha256"],
                             data={"text": "蓝色灯塔", "original_text": "藍色燈塔"})
        self.db.rebuild_search_doc("v")
        for query in ("蓝色灯塔", "藍色燈塔"):
            self.assertEqual([r["asset_id"] for r in search(self.db, query, hybrid=False)["results"]], ["v"])

    def test_video_vector_uses_whole_description_after_annotation(self):
        image_contract = dict(namespace=EMBEDDING_NAMESPACE, model=EMBEDDING_MODEL,
                              revision=EMBEDDING_REVISION, prompt=EMBEDDING_PROMPT, dimensions=DIMENSIONS)
        self.assertEqual(self.db.embedding_pending(**image_contract, count=True), 0)
        self.enrich()
        encoder = Mock()
        encoder.encode.return_value = [1] + [0] * (DIMENSIONS - 1)
        with patch("photo_search.embeddings.local_embedder", return_value=encoder):
            result = index_embeddings(self.db, progress=lambda *a, **k: None)
        self.assertEqual(result["embedded"], 1)
        self.assertEqual(encoder.encode.call_args.kwargs, {"text": "video\n海边骑行", "document": True})
        self.assertEqual(len(self.db.active_embeddings(VIDEO_EMBEDDING_NAMESPACE)), 1)
        with patch("photo_search.search.embed_query", return_value=tuple(encoder.encode.return_value)):
            results = search(self.db, "沙滩自行车", hybrid=True)["results"]
        self.assertEqual([r["asset_id"] for r in results], ["v"])
        # Replacing a summary also invalidates its dependent semantic vector.
        self.enrich()
        self.assertEqual(self.db.active_embeddings(VIDEO_EMBEDDING_NAMESPACE), [])


if __name__ == "__main__":
    unittest.main()
