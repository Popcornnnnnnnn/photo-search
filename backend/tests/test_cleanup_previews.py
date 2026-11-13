import fcntl
import sqlite3
import tempfile
import unittest
from pathlib import Path

from photo_search.cleanup_previews import cleanup


class CleanupPreviewTests(unittest.TestCase):
    def test_only_unreferenced_identical_regular_files_move_to_trash(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "home"
            assets, imports = home / "assets", home / "imports/photos-full"
            assets.mkdir(parents=True); imports.mkdir(parents=True)
            trash = Path(temporary) / "Trash"; trash.mkdir()
            db = home / "index.sqlite3"
            names = [f"photos-{index:024x}.jpg" for index in range(4)]
            for name in names:
                (assets / name).write_bytes(b"photo preview")
                (imports / name).write_bytes(b"photo preview")
            (imports / names[2]).write_bytes(b"not the same!!")
            (imports / names[3]).unlink()
            (imports / names[3]).symlink_to(imports / names[0])
            with sqlite3.connect(db) as conn:
                conn.execute("CREATE TABLE assets (file_path TEXT, thumbnail_path TEXT)")
                conn.execute("INSERT INTO assets VALUES (?, ?)", (str(assets / names[1]), str(assets / names[1])))
            preview = cleanup(home, db, trash)
            self.assertEqual(preview["files"], 1)
            self.assertTrue((assets / names[0]).exists())
            result = cleanup(home, db, trash, apply=True)
            self.assertEqual(result["files"], 1)
            self.assertFalse((assets / names[0]).exists())
            self.assertEqual((Path(result["trash_folder"]) / names[0]).read_bytes(), b"photo preview")
            self.assertTrue((imports / names[0]).exists())
            for name in names[1:]:
                self.assertTrue((assets / name).exists())

    def test_refuses_to_run_during_background_sync(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            (home / "assets").mkdir(); (home / "imports/photos-full").mkdir(parents=True)
            db = home / "index.sqlite3"
            with sqlite3.connect(db) as conn:
                conn.execute("CREATE TABLE assets (file_path TEXT, thumbnail_path TEXT)")
            with (home / "worker.lock").open("a+") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaises(BlockingIOError):
                    cleanup(home, db, home, apply=True)


if __name__ == "__main__":
    unittest.main()
