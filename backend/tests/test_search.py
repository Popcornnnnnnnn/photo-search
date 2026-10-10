import json
import math
import random
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from photo_search.db import Database
from photo_search.embeddings import (
    DIMENSIONS, EMBEDDING_MODEL, EMBEDDING_NAMESPACE, EMBEDDING_PROMPT,
    EMBEDDING_REVISION, index_embeddings,
    VIDEO_EMBEDDING_NAMESPACE, VIDEO_EMBEDDING_PROMPT,
    normalized,
)
from photo_search.search import search, text_coverage
from photo_search.worker import sync_due


class SearchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name) / "test.sqlite3"
        self.db = Database(self.path)

    def tearDown(self):
        self.db.close()
        self.temporary.cleanup()

    def add_photo(self, asset_id, caption, asset_type="photo", axis=None, model=EMBEDDING_MODEL):
        self.db.upsert_asset({
            "id": asset_id, "source_kind": "file", "source_identifier": asset_id,
            "file_path": "/unused.jpg", "thumbnail_path": "/unused.jpg",
            "sha256": asset_id, "filename": asset_id + ".jpg", "metadata": {},
        })
        self.db.add_artifact(
            asset_id=asset_id, kind="annotation", producer="test", input_sha256=asset_id,
            data={"asset_type": asset_type, "short_caption": caption},
        )
        self.db.rebuild_search_doc(asset_id)
        if axis is not None:
            vector = [0.0] * DIMENSIONS
            vector[axis] = 1.0
            self.db.upsert_embedding(
                asset_id=asset_id, namespace=EMBEDDING_NAMESPACE, model=model,
                model_revision=EMBEDDING_REVISION, prompt_version=EMBEDDING_PROMPT, vector=vector,
            )

    def test_shared_ranking_cases_match_the_native_contract(self):
        fixture = Path(__file__).resolve().parents[2] / "Tests/LiquidGlassDemoTests/Fixtures/search-ranking.json"
        sections = {"chatScreenshot": "chat_screenshot"}
        for sample in json.loads(fixture.read_text())["cases"]:
            with self.subTest(case=sample["id"]), tempfile.TemporaryDirectory() as directory, Database(Path(directory) / "index.sqlite3") as db:
                for asset in sample["assets"]:
                    db.upsert_asset({
                        "id": asset["id"], "source_kind": "file", "source_identifier": asset["id"],
                        "file_path": "/unused.jpg", "thumbnail_path": "/unused.jpg", "sha256": asset["id"],
                        "filename": asset["id"] + ".jpg", "metadata": {},
                        "captured_at": asset.get("capturedAt", "2025-01-01T00:00:00Z"),
                    })
                    db.add_artifact(asset_id=asset["id"], kind="annotation", producer="test",
                                    input_sha256=asset["id"],
                                    data={"asset_type": asset.get("type", "photo"), "short_caption": asset["caption"]})
                    db.rebuild_search_doc(asset["id"])
                    if "similarity" in asset:
                        video = asset.get("type") == "video"
                        similarity = asset["similarity"]
                        db.upsert_embedding(asset_id=asset["id"],
                                            namespace=VIDEO_EMBEDDING_NAMESPACE if video else EMBEDDING_NAMESPACE,
                                            model=EMBEDDING_MODEL, model_revision=EMBEDDING_REVISION,
                                            prompt_version=VIDEO_EMBEDDING_PROMPT if video else EMBEDDING_PROMPT,
                                            vector=[similarity, math.sqrt(1 - similarity * similarity)] + [0.0] * (DIMENSIONS - 2))
                with patch("photo_search.search.embed_query", return_value=[1.0] + [0.0] * (DIMENSIONS - 1)):
                    output = search(db, sample["query"], limit=100, hybrid=sample.get("hybrid", False),
                                    asset_type=sections.get(sample.get("section")))
                self.assertEqual([r["asset_id"] for r in output["results"]], sample["expected"])

    def test_visual_match_without_shared_words(self):
        self.add_photo("scene", "高架水泥柱旁的骑行者", axis=0)
        self.add_photo("other", "室内桌面", axis=1)
        with patch("photo_search.search.embed_query", return_value=[1.0] + [0.0] * (DIMENSIONS - 1)):
            result = search(self.db, "桥下休息", expand=False)
        self.assertEqual(result["plan"]["retrieval"], "hybrid")
        self.assertEqual(result["results"][0]["asset_id"], "scene")

    def test_password_rejects_weak_video_recall_without_losing_text_or_semantics(self):
        def add(asset_id, caption, similarity, video=False):
            self.add_photo(asset_id, caption, "video" if video else "photo")
            vector = [similarity, (1 - similarity ** 2) ** 0.5] + [0.0] * (DIMENSIONS - 2)
            self.db.upsert_embedding(
                asset_id=asset_id,
                namespace=VIDEO_EMBEDDING_NAMESPACE if video else EMBEDDING_NAMESPACE,
                model=EMBEDDING_MODEL, model_revision=EMBEDDING_REVISION,
                prompt_version=VIDEO_EMBEDDING_PROMPT if video else EMBEDDING_PROMPT,
                vector=vector,
            )

        add("password-photo", "密码输入框", 0.47)
        add("cycling", "夜间公路自行车骑行", 0.46, video=True)
        add("weak-video", "户外运动", 0.54, video=True)
        add("semantic-video", "登录认证界面", 0.56, video=True)
        add("spoken-password", "讲解密码设置步骤", 0.20, video=True)
        add("semantic-photo", "账号安全窗口", 0.47)
        add("weak-photo", "工伤保险咨询聊天", 0.41)
        with patch("photo_search.search.embed_query", return_value=[1.0] + [0.0] * (DIMENSIONS - 1)):
            result = search(self.db, "密码", limit=100)
            videos = search(self.db, "密码", asset_type="video")
        self.assertEqual({r["asset_id"] for r in result["results"]},
                         {"password-photo", "semantic-video", "spoken-password", "semantic-photo"})
        self.assertEqual({r["asset_id"] for r in videos["results"]},
                         {"semantic-video", "spoken-password"})

    def test_partial_text_evidence_preserves_lower_confidence_image_recall(self):
        query = "从副驾驶看别人开宝马走在林荫路上"
        caption = "宝马林荫路"
        coverage = text_coverage(query, caption)
        self.assertGreaterEqual(coverage, 0.25)
        self.assertLess(coverage, 0.50)
        self.add_photo("car", caption, axis=0)
        vector = [0.42, (1 - 0.42 ** 2) ** 0.5] + [0.0] * (DIMENSIONS - 2)
        with patch("photo_search.search.embed_query", return_value=vector):
            result = search(self.db, query)
        self.assertEqual([r["asset_id"] for r in result["results"]], ["car"])

    def test_category_filter_precedes_ranking_and_limit(self):
        self.add_photo("scene", "headphones", "photo", axis=0)
        self.add_photo("chat", "headphones discussion", "chat_screenshot", axis=1)
        with patch("photo_search.search.embed_query", return_value=[1.0] + [0.0] * (DIMENSIONS - 1)):
            result = search(self.db, "headphones", expand=False, asset_type="chat_screenshot", limit=1)
        self.assertEqual([r["asset_id"] for r in result["results"]], ["chat"])
        self.assertEqual(result["plan"]["embedding_count"], 1)

    def test_visual_search_does_not_wait_for_annotation(self):
        self.db.upsert_asset({
            "id": "unannotated", "source_kind": "file", "source_identifier": "unannotated",
            "file_path": "/unused.jpg", "thumbnail_path": "/unused.jpg",
            "sha256": "new", "filename": "new.jpg", "metadata": {},
        })
        vector = [1.0] + [0.0] * (DIMENSIONS - 1)
        self.db.upsert_embedding(
            asset_id="unannotated", namespace=EMBEDDING_NAMESPACE, model=EMBEDDING_MODEL,
            model_revision=EMBEDDING_REVISION, prompt_version=EMBEDDING_PROMPT, vector=vector,
        )
        with patch("photo_search.search.embed_query", return_value=vector):
            result = search(self.db, "桥下休息")
            categorized = search(self.db, "桥下休息", asset_type="photo")
        self.assertEqual(result["results"][0]["asset_id"], "unannotated")
        self.assertIsNone(result["results"][0]["annotation"])
        self.assertEqual(result["plan"]["searchable_count"], 1)
        self.assertEqual(result["plan"]["embedding_count"], 1)
        self.assertEqual(categorized["results"], [])
        self.assertEqual(self.db.stats()["search_docs"], 0)

    def test_embedding_failure_returns_chinese_text_matches_with_notice(self):
        self.add_photo("scene", "一位骑行者戴着头盔站在立交桥下", axis=0)
        with patch("photo_search.search.embed_query", side_effect=RuntimeError("model unavailable")):
            result = search(self.db, "立交桥下面戴头盔", expand=False)
        self.assertEqual(result["results"][0]["asset_id"], "scene")
        self.assertEqual(result["plan"]["retrieval"], "lexical")
        self.assertIn("embedding_error", result["plan"])

    def test_incompatible_vectors_are_not_compared(self):
        self.add_photo("scene", "骑车", axis=0, model="unrelated-model")
        with patch("photo_search.search.embed_query") as encoder:
            result = search(self.db, "骑车", expand=False)
        encoder.assert_not_called()
        self.assertEqual(result["plan"]["embedding_count"], 0)

    def test_unrelated_vectors_and_incidental_words_return_no_results(self):
        self.add_photo("scene", "一张普通的照片，骑车的男子", axis=1)
        with patch("photo_search.search.embed_query", return_value=[1.0] + [0.0] * (DIMENSIONS - 1)):
            result = search(self.db, "月球表面弹钢琴的章鱼照片")
        self.assertEqual(result["results"], [])
        self.assertEqual(result["plan"]["match_status"], "none")

    def test_unknown_identifier_cannot_be_replaced_by_visual_lookalike(self):
        self.add_photo("scene", "An ERROR in an editor", axis=0)
        with patch("photo_search.search.embed_query", return_value=[1.0] + [0.0] * (DIMENSIONS - 1)):
            result = search(self.db, "ZXQ_UNSEEN_942761_ERROR")
        self.assertEqual(result["results"], [])

    def test_borderline_visual_match_is_labelled_possible(self):
        self.add_photo("scene", "sunrise", axis=0)
        vector = [0.47, (1 - 0.47 ** 2) ** 0.5] + [0.0] * (DIMENSIONS - 2)
        with patch("photo_search.search.embed_query", return_value=vector):
            result = search(self.db, "morning light")
        self.assertEqual(result["plan"]["match_status"], "possible")

    def test_batched_visual_scores_and_order_match_scalar_cosine(self):
        rng = random.Random(42)
        for index in range(24):
            asset_id = f"scene-{index:02}"
            self.add_photo(asset_id, "unrelated caption")
            # Exercise non-unit vectors, close scores, and both sides of the cutoff.
            vector = [rng.uniform(-1, 1) for _ in range(DIMENSIONS)]
            vector[0] = index * 3
            self.db.upsert_embedding(
                asset_id=asset_id, namespace=EMBEDDING_NAMESPACE, model=EMBEDDING_MODEL,
                model_revision=EMBEDDING_REVISION, prompt_version=EMBEDDING_PROMPT, vector=vector,
            )
        query_vector = [1.0] + [0.0] * (DIMENSIONS - 1)
        expected = []
        for row in self.db.active_embeddings(EMBEDDING_NAMESPACE):
            score = sum(a * b for a, b in zip(query_vector, normalized(row["vector"])))
            if score >= 0.45:
                expected.append((row["asset_id"], score))
        expected.sort(key=lambda item: (-item[1], item[0]))
        with patch("photo_search.search.embed_query", return_value=query_vector):
            result = search(self.db, "visual-only query", limit=100)
        self.assertEqual([row["asset_id"] for row in result["results"]], [item[0] for item in expected])
        for row, (_, score) in zip(result["results"], expected):
            self.assertAlmostEqual(row["visual_similarity"], score, places=12)

    def test_invalid_packed_vectors_preserve_text_fallback(self):
        self.add_photo("scene", "骑行头盔")
        for vector in ([0.0] * DIMENSIONS, [float("nan")] * DIMENSIONS, [1.0, 0.0]):
            with self.subTest(vector_length=len(vector)):
                self.db.upsert_embedding(
                    asset_id="scene", namespace=EMBEDDING_NAMESPACE, model=EMBEDDING_MODEL,
                    model_revision=EMBEDDING_REVISION, prompt_version=EMBEDDING_PROMPT, vector=vector,
                )
                # A corrupt payload can disagree with its declared dimensions.
                self.db.conn.execute("UPDATE embeddings SET dimensions=?", (DIMENSIONS,))
                self.db.conn.commit()
                with patch("photo_search.search.embed_query", return_value=[1.0] + [0.0] * (DIMENSIONS - 1)):
                    result = search(self.db, "骑行头盔")
                self.assertEqual(result["plan"]["retrieval"], "lexical")
                self.assertIn("embedding_error", result["plan"])
                self.assertEqual([row["asset_id"] for row in result["results"]], ["scene"])

    def test_one_unreadable_photo_does_not_block_the_next_vector(self):
        self.add_photo("bad", "broken")
        self.add_photo("good", "working")
        with patch("photo_search.embeddings.local_embedder") as encoder:
            encoder.return_value.encode.side_effect = [OSError("unreadable"), [1.0] + [0.0] * (DIMENSIONS - 1)]
            result = index_embeddings(self.db, limit=2, progress=lambda *a, **kw: None)
        self.assertEqual(result["failed"], 1)
        self.assertEqual(result["embedded"], 1)
        self.assertEqual(result["pending"], 0)

    def test_exact_error_code_keeps_priority_over_visual_lookalike(self):
        self.add_photo("correct", "OpenCode ECONNREFUSED", axis=1)
        self.add_photo("lookalike", "OpenCode editor", axis=0)
        with patch("photo_search.search.embed_query", return_value=[1.0] + [0.0] * (DIMENSIONS - 1)):
            result = search(self.db, "ECONNREFUSED", expand=False)
        self.assertEqual(result["results"][0]["asset_id"], "correct")

    def test_resuming_batch_skips_existing_vectors(self):
        self.add_photo("existing", "indexed", axis=0)
        self.add_photo("pending", "new")
        with patch("photo_search.embeddings.local_embedder") as encoder:
            encoder.return_value.encode.return_value = [1.0] + [0.0] * (DIMENSIONS - 1)
            first = index_embeddings(self.db, limit=1, progress=lambda *a, **kw: None)
            second = index_embeddings(self.db, limit=1, progress=lambda *a, **kw: None)
        self.assertEqual(first["embedded"], 1)
        self.assertEqual(second["embedded"], 0)
        encoder.return_value.encode.assert_called_once()

    def test_result_payload_carries_the_fields_the_app_reads(self):
        self.add_photo("scene", "骑行头盔", axis=0)
        with patch("photo_search.search.embed_query", return_value=[1.0] + [0.0] * (DIMENSIONS - 1)):
            result = search(self.db, "cycling", limit=1, asset_type="photo")
        self.assertEqual(result["plan"]["retrieval"], "hybrid")
        self.assertEqual(result["results"][0]["asset_id"], "scene")
        self.assertEqual(result["results"][0]["file_path"], "/unused.jpg")

    def test_sync_is_separate_from_annotation_batches(self):
        from datetime import datetime, timedelta, timezone
        now = datetime.now(timezone.utc)
        self.assertFalse(sync_due({"last_sync_at": now.isoformat()}))
        self.assertTrue(sync_due({"last_sync_at": (now - timedelta(minutes=6)).isoformat()}))
        self.assertTrue(sync_due({}))
