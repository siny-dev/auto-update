import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

repo_root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(repo_root / "tools"))
import sync_local_modules


class LocalModuleSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="au-local-module-")
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.src = self.source / "src"
        self.src.mkdir(parents=True)
        self.state = self.root / "state"
        self.config = self.root / "local-module-sources.json"
        self.official_pointer = repo_root / "outbox" / "modules" / "AutoSync" / "current.json"
        self.official_pointer_before = self.official_pointer.read_bytes()
        self.write_source("1.0.0", "local patch one")
        self.write_config(str(self.source))

    def tearDown(self):
        self.assertEqual(self.official_pointer.read_bytes(), self.official_pointer_before)
        self.temp.cleanup()

    def write_source(self, version, payload):
        (self.src / "__init__.py").write_text(f'__version__ = "{version}"\n', encoding="utf-8")
        (self.src / "engine.py").write_text(f'PATCH = "{payload}"\n', encoding="utf-8")

    def write_config(self, source_root):
        self.config.write_text(json.dumps({
            "schema": 1,
            "modules": [{
                "module_id": "AutoSync",
                "source_root": source_root,
                "api_major": 1,
                "minimum_engine": "0.1.0",
                "activation_mode": "restart",
            }],
        }), encoding="utf-8")

    def pointer(self):
        path = self.state / "modules" / "AutoSync" / "current.json"
        return json.loads(path.read_text(encoding="utf-8"))

    def test_builds_verifies_and_activates_only_in_local_cache(self):
        result = sync_local_modules.sync_local_modules(self.config, self.state, "1.0.0")
        pointer = self.pointer()
        self.assertEqual(result["status"], "ready")
        self.assertTrue(result["modules"][0]["verified"])
        self.assertEqual(pointer["version"], "1.0.0")
        version_root = self.state / "modules" / "AutoSync" / "versions" / "1.0.0"
        module_json = version_root / "module.json"
        self.assertEqual(hashlib.sha256(module_json.read_bytes()).hexdigest(), pointer["manifest_sha256"])
        self.assertEqual((version_root / "src" / "engine.py").read_text(encoding="utf-8"), 'PATCH = "local patch one"\n')
        self.assertFalse((repo_root / "outbox" / "modules" / "AutoSync" / "versions" / "1.0.0").exists())

        again = sync_local_modules.sync_local_modules(self.config, self.state, "1.0.0")
        self.assertEqual(again["modules"][0]["installed_version"], "1.0.0")
        self.assertEqual(self.pointer()["version"], "1.0.0")

    def test_immutable_version_conflict_preserves_current_and_new_version_applies(self):
        sync_local_modules.sync_local_modules(self.config, self.state, "1.0.0")
        old_pointer = self.pointer()
        old_payload = self.state / "modules" / "AutoSync" / "versions" / "1.0.0" / "src" / "engine.py"
        self.write_source("1.0.0", "changed without bump")
        with self.assertRaisesRegex(sync_local_modules.LocalModuleSyncError, "without a version bump"):
            sync_local_modules.sync_local_modules(self.config, self.state, "1.0.0")
        self.assertEqual(self.pointer(), old_pointer)
        self.assertEqual(old_payload.read_text(encoding="utf-8"), 'PATCH = "local patch one"\n')

        self.write_source("1.0.1", "local patch two")
        result = sync_local_modules.sync_local_modules(self.config, self.state, "1.0.0")
        self.assertEqual(result["modules"][0]["installed_version"], "1.0.1")
        self.assertEqual(self.pointer()["version"], "1.0.1")
        self.assertTrue(old_payload.is_file())
        new_payload = self.state / "modules" / "AutoSync" / "versions" / "1.0.1" / "src" / "engine.py"
        self.assertEqual(new_payload.read_text(encoding="utf-8"), 'PATCH = "local patch two"\n')

    def test_rejects_network_source_root_without_touching_cache(self):
        self.write_config(r"\\H255\AI-Work\AutoSync")
        with self.assertRaisesRegex(sync_local_modules.LocalModuleSyncError, "network path"):
            sync_local_modules.sync_local_modules(self.config, self.state, "1.0.0")
        self.assertFalse((self.state / "modules" / "AutoSync" / "current.json").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
