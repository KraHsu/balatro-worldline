from pathlib import Path
import json
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import build
import migrate_legacy as migration


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(ROOT / "src", self.root / "src")
        shutil.copytree(ROOT / "thunderstore", self.root / "thunderstore")
        for name in ("LICENSE", "NOTICE.md", "CHANGELOG.md", "README.md"):
            shutil.copy2(ROOT / name, self.root / name)

    def test_payloads_allowlist_and_determinism(self):
        (self.root / "src/player.jkr").write_bytes(b"private")
        (self.root / "src/runtime/debug.log").write_bytes(b"private")
        manual = build.package_entries(self.root)
        store = build.package_entries(self.root, "thunderstore")
        self.assertEqual(manual, {k: v for k, v in store.items() if k.startswith("WorldLine/")})
        self.assertIn("WorldLine/runtime/app.lua", manual)
        self.assertIn("WorldLine/workers/encode.lua", manual)
        self.assertNotIn("WorldLine/player.jkr", manual)
        self.assertNotIn("WorldLine/runtime/debug.log", manual)
        self.assertEqual(store["icon.png"], manual["WorldLine/assets/1x/modicon.png"])
        self.assertNotIn(b"](docs/", store["README.md"])
        path = build.build_package(self.root, self.root / "dist")
        before = path.read_bytes()
        self.assertEqual(build.build_package(self.root, self.root / "dist").read_bytes(), before)

    def test_mismatched_manifest_and_missing_runtime_fail(self):
        manifest = self.root / "thunderstore/manifest.json"
        data = json.loads(manifest.read_text());data["version_number"] = "99.0.0"
        manifest.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            build.package_entries(self.root, "thunderstore")
        (self.root / "src/main.lua").unlink()
        with self.assertRaises(ValueError):
            build.package_entries(self.root)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name);self.data = self.root / "game"
        (self.data / "BalatroTree/trees").mkdir(parents=True)
        (self.data / "1").mkdir();(self.data / "config").mkdir()
        self.archive = {"format": "btree-data", "tables": [[{"k": "btree_run_id", "v": "run"},
                         {"k": "rng", "v": {"n": "0.51507869261900003"}}]]}
        (self.data / "BalatroTree/trees/a.a.json").write_text(json.dumps(self.archive))
        self.native = b'return {GAME={btree_run_id="run",btree_node_id=7,dollars=42,rng=0.51507869261900003}}'
        encoder = zlib.compressobj(wbits=-15)
        self.compressed = encoder.compress(self.native) + encoder.flush()
        (self.data / "1/save.jkr").write_bytes(self.compressed)
        (self.data / "config/BalatroTree.jkr").write_bytes(b'return {auto_create=true}')

    @patch.object(migration, "game_is_running", return_value=False)
    def test_conversion_keeps_exact_rng_and_backups(self, _):
        plan = migration.prepare(self.data, self.root / "backup")
        migration.apply(plan)
        self.assertFalse((self.data / "BalatroTree").exists())
        converted = json.loads((self.data / "WorldLine/trees/a.a.json").read_bytes())
        self.assertEqual(converted["format"], "worldline-data")
        self.assertEqual(converted["tables"][0][1]["v"]["n"], "0.51507869261900003")
        native = zlib.decompress((self.data / "1/save.jkr").read_bytes(), -15)
        self.assertEqual(native.replace(b"worldline_", b"btree_"), self.native)
        self.assertEqual((self.root / "backup/original/1/save.jkr").read_bytes(), self.compressed)
        self.assertTrue((self.data / "config/WorldLine.jkr").exists())

    @patch.object(migration, "game_is_running", return_value=False)
    def test_modified_original_is_not_overwritten(self, _):
        plan = migration.prepare(self.data, self.root / "backup")
        (self.data / "1/save.jkr").write_bytes(b"new progress")
        with self.assertRaises(RuntimeError):
            migration.apply(plan)
        self.assertTrue((self.data / "BalatroTree").is_dir())
        self.assertFalse((self.data / "WorldLine").exists())

    def test_running_game_blocks_migration(self):
        plan = migration.prepare(self.data, self.root / "backup")
        with patch.object(migration, "game_is_running", return_value=True), self.assertRaises(RuntimeError):
            migration.apply(plan)

    @patch.object(migration, "game_is_running", return_value=False)
    def test_new_archive_after_preparation_aborts(self, _):
        plan = migration.prepare(self.data, self.root / "backup")
        (self.data / "BalatroTree/trees/new.json").write_text("{}")
        with self.assertRaises(RuntimeError):
            migration.apply(plan)
        self.assertTrue((self.data / "BalatroTree").is_dir())

    @patch.object(migration, "game_is_running", return_value=False)
    def test_report_cannot_redirect_writes(self, _):
        plan = migration.prepare(self.data, self.root / "backup")
        plan["files"][0]["target"] = "../../outside.json"
        with self.assertRaises(ValueError):
            migration.apply(plan)
        self.assertTrue((self.data / "BalatroTree").is_dir())

    @patch.object(migration, "game_is_running", return_value=False)
    def test_failed_replacement_rolls_back_all_original_bytes(self, _):
        plan = migration.prepare(self.data, self.root / "backup")
        replace = Path.replace
        def fail_archive(path, target):
            if target == self.data / "WorldLine/trees/a.a.json":
                raise OSError("Simulated disk failure")
            return replace(path, target)
        with patch.object(Path, "replace", fail_archive), self.assertRaises(OSError):
            migration.apply(plan)
        self.assertEqual((self.data / "1/save.jkr").read_bytes(), self.compressed)
        self.assertEqual(json.loads((self.data / "BalatroTree/trees/a.a.json").read_text()), self.archive)
        self.assertFalse((self.data / "WorldLine").exists())
        self.assertEqual(list(self.data.rglob("*.migration-tmp")), [])


if __name__ == "__main__":
    unittest.main()
