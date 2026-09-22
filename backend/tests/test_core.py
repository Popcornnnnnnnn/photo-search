from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from photo_search.db import Database
from photo_search.benchmark import EMBEDDING_NAMESPACE
from photo_search.qwen import extract_json
from photo_search.search import fallback_terms, search
from photo_search.providers import load_provider


class CoreTests(unittest.TestCase):
    def test_model_provider_config_selects_active_profile(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "providers.json"
            path.write_text(json.dumps({
                "active_provider_id": "cloud",
                "reprocess_existing": True,
                "providers": [{
                    "id": "cloud", "name": "Cloud", "kind": "cloud",
                    "base_url": "https://example.com/v1", "model": "vision-model",
                    "json_mode": False,
                }],
            }))
            provider = load_provider(path)
            self.assertEqual(provider.id, "cloud")
            self.assertEqual(provider.model, "vision-model")
            self.assertTrue(provider.reprocess_existing)
            self.assertFalse(provider.json_mode)

    def test_fallback_terms_include_chinese_ngrams(self) -> None:
        terms = fallback_terms("立交桥下面戴头盔")
        self.assertIn("立交桥", terms)
        self.assertIn("头盔", terms)

    def test_extract_json_accepts_fenced_output(self) -> None:
        self.assertEqual(extract_json('```json\n{"asset_type":"photo"}\n```')["asset_type"], "photo")

    def test_versioned_artifacts_build_search_document(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = root / "sample.jpg"
            image.write_bytes(b"test")
            with Database(root / "test.sqlite3") as db:
                db.upsert_asset(
                    {
                        "id": "a1",
                        "source_kind": "file",
                        "source_identifier": str(image),
                        "file_path": str(image),
                        "thumbnail_path": str(image),
                        "sha256": "abc",
                        "filename": "sample.jpg",
                        "metadata": {},
                    }
                )
                db.add_artifact(
                    asset_id="a1",
                    kind="ocr",
                    producer="test",
                    input_sha256="abc",
                    data={"text": "张三 讨论 RTX 4090"},
                )
                db.add_artifact(
                    asset_id="a1",
                    kind="annotation",
                    producer="test",
                    model="model-v1",
                    prompt_version="prompt-v1",
                    schema_version="1",
                    input_sha256="abc",
                    data={
                        "asset_type": "chat_screenshot",
                        "short_caption": "与张三讨论显卡的聊天截图",
                        "topics": ["购买电脑"],
                    },
                )
                db.rebuild_search_doc("a1")
                result = search(db, "张三 显卡", expand=False)
                self.assertEqual(result["results"][0]["asset_id"], "a1")
                self.assertEqual(db.stats()["artifacts"], 2)
                stored = db.search_docs()[0]["search_text"]
                self.assertNotIn("asset_type", stored)
                self.assertNotIn("short_caption", stored)

    def test_embedding_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = root / "sample.jpg"
            image.write_bytes(b"test")
            with Database(root / "test.sqlite3") as db:
                db.upsert_asset(
                    {
                        "id": "a1", "source_kind": "file", "source_identifier": str(image),
                        "file_path": str(image), "thumbnail_path": str(image), "sha256": "abc",
                        "filename": "sample.jpg", "metadata": {},
                    }
                )
                db.upsert_embedding(
                    asset_id="a1", namespace=EMBEDDING_NAMESPACE, model="model",
                    model_revision="rev", prompt_version="prompt", vector=[0.25, -0.5, 1.0],
                )
                stored = db.active_embeddings(EMBEDDING_NAMESPACE)
                self.assertEqual(stored[0]["asset_id"], "a1")
                self.assertEqual(stored[0]["vector"], [0.25, -0.5, 1.0])

    def test_processing_skip_is_durable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = root / "sample.jpg"
            image.write_bytes(b"test")
            with Database(root / "test.sqlite3") as db:
                db.upsert_asset(
                    {
                        "id": "a1", "source_kind": "apple-photos-full",
                        "source_identifier": "photos-id", "file_path": str(image),
                        "thumbnail_path": str(image), "sha256": "abc",
                        "filename": "sample.jpg", "metadata": {},
                    }
                )
                for _ in range(3):
                    db.record_error("a1", "index", "bad image")
                self.assertEqual(db.error_count("a1", "index"), 3)
                db.mark_processing_skip("a1", "index", "bad image")
                self.assertTrue(db.is_processing_skipped("a1", "index"))
                self.assertEqual(db.pipeline_counts()["skipped"], 1)
                self.assertEqual(db.release_processing_skips("index", "9999-01-01"), 1)
                self.assertFalse(db.is_processing_skipped("a1", "index"))

    def test_pending_artifacts_are_filtered_before_batch_limit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with Database(root / "test.sqlite3") as db:
                for number in range(3):
                    image = root / f"{number}.jpg"
                    image.write_bytes(f"image-{number}".encode())
                    db.upsert_asset(
                        {
                            "id": f"a{number}", "source_kind": "apple-photos-full",
                            "source_identifier": f"photos-{number}", "file_path": str(image),
                            "thumbnail_path": str(image), "sha256": f"sha-{number}",
                            "filename": image.name, "metadata": {},
                        }
                    )
                db.add_artifact(
                    asset_id="a0", kind="annotation", producer="qwen-vlm",
                    model="model", prompt_version="prompt", schema_version="1",
                    preprocess_version="preview", input_sha256="sha-0", data={},
                )
                db.mark_processing_skip("a1", "index", "unsupported")

                pending = db.assets_missing_artifact(
                    kind="annotation", producer="qwen-vlm", model="model",
                    prompt_version="prompt", schema_version="1",
                    preprocess_version="preview", source_kinds={"apple-photos-full"},
                    skip_stage="index", limit=1,
                )
                self.assertEqual([row["id"] for row in pending], ["a2"])

    def test_full_library_import_upgrades_benchmark_source_without_downgrade(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = root / "sample.jpg"
            image.write_bytes(b"test")
            base = {
                "id": "a1", "source_identifier": "photos-id",
                "file_path": str(image), "thumbnail_path": str(image),
                "sha256": "abc", "filename": image.name, "metadata": {},
            }
            with Database(root / "test.sqlite3") as db:
                db.upsert_asset({**base, "source_kind": "apple-photos-benchmark"})
                db.upsert_asset({**base, "source_kind": "apple-photos-full"})
                self.assertEqual(db.get_asset("a1")["source_kind"], "apple-photos-full")

                db.upsert_asset({**base, "source_kind": "apple-photos-benchmark"})
                self.assertEqual(db.get_asset("a1")["source_kind"], "apple-photos-full")


if __name__ == "__main__":
    unittest.main()
