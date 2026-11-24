import fcntl
import json
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

from photo_search.cleanup_previews import cleanup


class CleanupPreviewTests(unittest.TestCase):
    def test_only_unreferenced_identical_regular_files_move_to_trash(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "home"
            assets, imports = home / "assets", home / "imports/photos-full"
            assets.mkdir(parents=True)
            imports.mkdir(parents=True)
            trash = Path(temporary) / "Trash"
            trash.mkdir()
            db = home / "index.sqlite3"
            names = [f"photos-{index:024x}.jpg" for index in range(4)]
            for name in names:
                (assets / name).write_bytes(b"photo preview")
                (imports / name).write_bytes(b"photo preview")
            (imports / names[2]).write_bytes(b"not the same!!")
            (imports / names[3]).unlink()
            (imports / names[3]).symlink_to(imports / names[0])
            with closing(sqlite3.connect(db)) as conn, conn:
                conn.execute("CREATE TABLE assets (file_path TEXT, thumbnail_path TEXT)")
                conn.execute("INSERT INTO assets VALUES (?, ?)", (str(assets / names[1]), str(assets / names[1])))
            preview = cleanup(home, db, trash)
            self.assertEqual(preview["files"], 1)
            self.assertTrue((assets / names[0]).exists())
            result = cleanup(home, db, trash, apply=True)
            self.assertEqual(result["files"], 1)
            self.assertEqual(result["assets_files"], 1)
            self.assertFalse((assets / names[0]).exists())
            self.assertEqual((Path(result["trash_folder"]) / "assets" / names[0]).read_bytes(), b"photo preview")
            self.assertTrue((imports / names[0]).exists())
            for name in names[1:]:
                self.assertTrue((assets / name).exists())

    def test_prunes_legacy_mov_superseded_jpg_and_deleted_previews_preserving_active_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "home"
            assets, imports = home / "assets", home / "imports/photos-full"
            models = home / "models"
            assets.mkdir(parents=True)
            imports.mkdir(parents=True)
            models.mkdir(parents=True)
            trash = Path(temporary) / "Trash"
            trash.mkdir()

            model_file = models / "encoder.safetensors"
            model_file.write_bytes(b"weights")
            config_file = home / "model-providers.json"
            config_file.write_text('{"active":"qwen"}', encoding="utf-8")

            active_id = f"photos-{1:024x}"
            video_id = f"photos-{2:024x}"
            deleted_id = f"photos-{3:024x}"
            deleted_video_id = f"photos-{4:024x}"
            failed_id = f"photos-{5:024x}"

            active_v2 = imports / f"{active_id}-{'b' * 12}.jpg"
            superseded_v1 = imports / f"{active_id}-{'a' * 12}.jpg"
            legacy_unversioned = imports / f"{active_id}.jpg"
            video_cover = imports / f"{video_id}-{'c' * 12}.jpg"
            legacy_video_mov = imports / f"{video_id}-{'c' * 12}.mov"
            deleted_video_mov = imports / f"{deleted_video_id}-{'d' * 12}.mov"
            deleted_import_jpg = imports / f"{deleted_id}.jpg"
            deleted_asset_jpg = assets / f"{deleted_id}.jpg"
            deleted_video_thumb = assets / f"{deleted_video_id}-{'d' * 12}.jpg"
            failed_asset_jpg = assets / f"{failed_id}-{'e' * 12}.jpg"
            file_import_jpg = assets / f"file-{9:024x}.jpg"
            symlink_jpg = imports / f"photos-{8:024x}.jpg"

            for path in (
                active_v2, superseded_v1, legacy_unversioned, video_cover,
                deleted_import_jpg, deleted_asset_jpg, deleted_video_thumb,
                failed_asset_jpg, file_import_jpg,
            ):
                path.write_bytes(f"bytes:{path.name}".encode())
            legacy_video_mov.write_bytes(b"legacy active video mov")
            deleted_video_mov.write_bytes(b"legacy deleted video mov")
            symlink_jpg.symlink_to(active_v2)

            manifest_records = [
                {"id": active_id, "path": str(active_v2), "thumbnail_path": str(active_v2)},
                {"id": video_id, "path": str(video_cover), "thumbnail_path": str(video_cover)},
            ]
            (imports / "manifest.jsonl").write_text(
                "".join(json.dumps(item) + "\n" for item in manifest_records), encoding="utf-8"
            )
            (imports / "result.json").write_text(
                json.dumps({
                    "full_snapshot": True,
                    "strategy": "all",
                    "library_assets": 3,
                    "present_ids": [active_id, video_id, failed_id],
                    "failed_ids": [failed_id],
                }),
                encoding="utf-8",
            )

            db = home / "photo-search.sqlite3"
            with closing(sqlite3.connect(db)) as conn, conn:
                conn.execute(
                    "CREATE TABLE assets (id TEXT PRIMARY KEY, file_path TEXT, thumbnail_path TEXT, is_available INTEGER)"
                )
                conn.executemany(
                    "INSERT INTO assets VALUES (?, ?, ?, ?)",
                    [
                        (active_id, str(active_v2), str(active_v2), 1),
                        (video_id, str(video_cover), str(video_cover), 1),
                        ("file-import", str(file_import_jpg), str(file_import_jpg), 1),
                        (deleted_id, str(deleted_asset_jpg), str(deleted_asset_jpg), 0),
                        (deleted_video_id, str(deleted_video_mov), str(deleted_video_thumb), 0),
                        (failed_id, str(failed_asset_jpg), str(failed_asset_jpg), 0),
                    ],
                )

            dry = cleanup(home, db, trash, apply=False)
            self.assertEqual(dry["assets_files"], 2)
            self.assertEqual(dry["imports_jpg_files"], 3)
            self.assertEqual(dry["imports_mov_files"], 2)
            self.assertEqual(dry["files"], 7)
            self.assertIsNone(dry["trash_folder"])
            self.assertTrue(superseded_v1.exists())

            applied = cleanup(home, db, trash, apply=True)
            self.assertEqual(applied["files"], 7)
            trash_root = Path(applied["trash_folder"])

            # Pruned files moved into non-colliding relative folders in Trash.
            for moved in (
                superseded_v1, legacy_unversioned, deleted_import_jpg,
                legacy_video_mov, deleted_video_mov, deleted_asset_jpg, deleted_video_thumb,
            ):
                self.assertFalse(moved.exists(), f"expected pruned: {moved}")
                trashed = trash_root / moved.relative_to(home)
                self.assertTrue(trashed.is_file(), f"expected in Trash: {trashed}")

            # Active previews, failed-export preview, symlinks, DB, models, and config remain untouched.
            for kept in (
                active_v2, video_cover, file_import_jpg, failed_asset_jpg,
                db, model_file, config_file, imports / "manifest.jsonl", imports / "result.json",
            ):
                self.assertTrue(kept.is_file(), f"expected preserved: {kept}")
            self.assertTrue(symlink_jpg.is_symlink())

    def test_refuses_cleanup_when_manifest_or_active_preview_is_missing(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "home"
            assets, imports = home / "assets", home / "imports/photos-full"
            assets.mkdir(parents=True)
            imports.mkdir(parents=True)
            trash = Path(temporary) / "Trash"
            trash.mkdir()
            db = home / "photo-search.sqlite3"
            missing = imports / f"photos-{1:024x}.jpg"
            with closing(sqlite3.connect(db)) as conn, conn:
                conn.execute(
                    "CREATE TABLE assets (id TEXT PRIMARY KEY, file_path TEXT, thumbnail_path TEXT, is_available INTEGER)"
                )
                conn.execute("INSERT INTO assets VALUES (?, ?, ?, 1)", (f"photos-{1:024x}", str(missing), str(missing)))
            with self.assertRaises(ValueError):
                cleanup(home, db, trash, apply=True)

            missing.write_bytes(b"ok")
            (imports / "manifest.jsonl").write_text("{broken json\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                cleanup(home, db, trash, apply=True)

            # Non-dict manifest lines are rejected cleanly.
            (imports / "manifest.jsonl").write_text("[]\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                cleanup(home, db, trash, apply=True)

            # Exporter error in result.json refuses cleanup even if an old manifest exists.
            (imports / "manifest.jsonl").write_text(
                json.dumps({"id": f"photos-{1:024x}", "path": str(missing)}) + "\n", encoding="utf-8"
            )
            (imports / "result.json").write_text(json.dumps({"error": "unauthorized"}), encoding="utf-8")
            with self.assertRaises(ValueError):
                cleanup(home, db, trash, apply=True)

            # Inconsistent full_snapshot inventory is rejected.
            (imports / "result.json").write_text(
                json.dumps({
                    "full_snapshot": True,
                    "strategy": "all",
                    "library_assets": 2,
                    "present_ids": [f"photos-{1:024x}", f"photos-{2:024x}"],
                    "failed_ids": [],
                }),
                encoding="utf-8",
            )
            with self.assertRaises(ValueError):
                cleanup(home, db, trash, apply=True)

    def test_partial_or_legacy_photo_only_snapshots_do_not_prune_imports_or_hidden_videos(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "HomeCase"
            assets, imports = home / "assets", home / "imports/photos-full"
            assets.mkdir(parents=True)
            imports.mkdir(parents=True)
            trash = Path(temporary) / "Trash"
            trash.mkdir()

            photo_id = f"photos-{1:024x}"
            video_id = f"photos-{2:024x}"
            unimported_id = f"photos-{3:024x}"

            active_jpg = imports / f"{photo_id}.jpg"
            unimported_jpg = imports / f"{unimported_id}.jpg"
            hidden_video_thumb = assets / f"{video_id}.jpg"
            for item in (active_jpg, unimported_jpg, hidden_video_thumb):
                item.write_bytes(b"data")

            (imports / "manifest.jsonl").write_text(
                json.dumps({"id": photo_id, "path": str(active_jpg)}) + "\n", encoding="utf-8"
            )
            # Legacy photo-only snapshot (library_images without library_assets): must not prune imports or hidden videos.
            (imports / "result.json").write_text(
                json.dumps({
                    "full_snapshot": True,
                    "strategy": "all",
                    "library_images": 1,
                    "present_ids": [photo_id],
                    "failed_ids": [],
                }),
                encoding="utf-8",
            )
            db = home / "photo-search.sqlite3"
            with closing(sqlite3.connect(db)) as conn, conn:
                conn.execute(
                    "CREATE TABLE assets (id TEXT PRIMARY KEY, file_path TEXT, thumbnail_path TEXT, is_available INTEGER)"
                )
                conn.executemany(
                    "INSERT INTO assets VALUES (?, ?, ?, ?)",
                    [
                        (photo_id, str(active_jpg), str(active_jpg), 1),
                        (video_id, str(hidden_video_thumb), str(hidden_video_thumb), 0),
                    ],
                )

            result = cleanup(home, db, trash, apply=True)
            self.assertEqual(result["files"], 0)
            self.assertTrue(unimported_jpg.exists())
            self.assertTrue(hidden_video_thumb.exists())

            # Partial snapshot (full_snapshot=False) also leaves imports/ untouched.
            (imports / "result.json").write_text(
                json.dumps({
                    "full_snapshot": False,
                    "strategy": "recent",
                    "library_assets": 10,
                    "present_ids": [photo_id],
                    "failed_ids": [],
                }),
                encoding="utf-8",
            )
            self.assertEqual(cleanup(home, db, trash, apply=True)["files"], 0)
            self.assertTrue(unimported_jpg.exists())

    def test_inode_identity_protects_active_previews_across_path_aliases_or_case_differences(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "MixedCaseHome"
            assets, imports = home / "assets", home / "imports/photos-full"
            assets.mkdir(parents=True)
            imports.mkdir(parents=True)
            trash = Path(temporary) / "Trash"
            trash.mkdir()

            photo_id = f"photos-{1:024x}"
            active_jpg = imports / f"{photo_id}-{'a' * 12}.jpg"
            superseded_jpg = imports / f"{photo_id}-{'b' * 12}.jpg"
            active_jpg.write_bytes(b"active")
            superseded_jpg.write_bytes(b"old")

            # Use a hardlink alias (and lowercase path if case-insensitive FS) in DB/manifest
            # to verify inode-based protection even when Path.resolve() strings differ.
            alias_dir = Path(temporary) / "alias"
            alias_dir.mkdir()
            alias_jpg = alias_dir / active_jpg.name
            alias_jpg.hardlink_to(active_jpg)

            (imports / "manifest.jsonl").write_text(
                json.dumps({"id": photo_id, "path": str(alias_jpg)}) + "\n", encoding="utf-8"
            )
            (imports / "result.json").write_text(
                json.dumps({
                    "full_snapshot": True,
                    "strategy": "all",
                    "library_assets": 1,
                    "present_ids": [photo_id],
                    "failed_ids": [],
                }),
                encoding="utf-8",
            )
            db = home / "photo-search.sqlite3"
            with closing(sqlite3.connect(db)) as conn, conn:
                conn.execute(
                    "CREATE TABLE assets (id TEXT PRIMARY KEY, file_path TEXT, thumbnail_path TEXT, is_available INTEGER)"
                )
                conn.execute(
                    "INSERT INTO assets VALUES (?, ?, ?, 1)",
                    (photo_id, str(alias_jpg), str(alias_jpg)),
                )

            result = cleanup(home, db, trash, apply=True)
            self.assertEqual(result["files"], 1)
            self.assertTrue(active_jpg.exists())
            self.assertFalse(superseded_jpg.exists())

    def test_refuses_to_run_during_background_sync(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            (home / "assets").mkdir()
            (home / "imports/photos-full").mkdir(parents=True)
            db = home / "index.sqlite3"
            with closing(sqlite3.connect(db)) as conn, conn:
                conn.execute("CREATE TABLE assets (file_path TEXT, thumbnail_path TEXT)")
            with (home / "worker.lock").open("a+") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaises(BlockingIOError):
                    cleanup(home, db, home, apply=True)


if __name__ == "__main__":
    unittest.main()
