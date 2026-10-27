from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shared_app import SharedAppError, resolve_shared_app


def write_package(root: Path, version: str, executable_text: str, data_text: str = "live") -> str:
    root.mkdir(parents=True, exist_ok=True)
    payloads = {
        "workboard.exe": ("executable", executable_text.encode("utf-8")),
        "live.json": ("resource", data_text.encode("utf-8")),
    }
    files = []
    for rel, (kind, content) in payloads.items():
        target = root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        files.append({
            "path": rel,
            "kind": kind,
            "size": len(content),
            "sha256": hashlib.sha256(content).hexdigest(),
            "source": "payload/" + rel,
            "asset": "asset_" + rel.replace(".", "_"),
        })
    manifest = {
        "schema": 1,
        "contract": "autoupdate-app-v1",
        "app_id": "workboard",
        "version": version,
        "mode": "restart",
        "platform": "windows",
        "architecture": "x86",
        "minimum_engine": "0.1.0",
        "publisher_policy": "github-release-asset-https",
        "files": files,
    }
    manifest_bytes = (json.dumps(manifest, separators=(",", ":")) + "\n").encode("utf-8")
    (root / "manifest.json").write_bytes(manifest_bytes)
    return hashlib.sha256(manifest_bytes).hexdigest()


def activate_local(state_root: Path, version: str, exe_text: str, data_text: str = "live") -> str:
    app_root = state_root / "apps" / "workboard"
    package_root = app_root / "versions" / version
    manifest_hash = write_package(package_root, version, exe_text, data_text)
    manifest = json.loads((package_root / "manifest.json").read_text(encoding="utf-8"))
    pointer = {
        "schema": 1,
        "app_id": "workboard",
        "version": version,
        "mode": manifest["mode"],
        "manifest_sha256": manifest_hash,
        "activated_utc": "2026-10-27T00:00:00Z",
    }
    app_root.mkdir(parents=True, exist_ok=True)
    (app_root / "current.json").write_text(json.dumps(pointer), encoding="utf-8")
    return manifest_hash


class SharedAppTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="autoupdate-shared-app-")
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        self.shared = self.root / "share" / "Workboard" / "실행본"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def resolve(self) -> dict:
        return resolve_shared_app(self.state, self.shared, "workboard", "x86", "workboard.exe")

    def test_first_verified_package_is_published_atomically(self) -> None:
        activate_local(self.state, "1.0.60", "exe-60")
        result = self.resolve()
        self.assertEqual(result["status"], "ready")
        self.assertTrue(result["verified"])
        self.assertTrue(result["changed"])
        self.assertEqual(result["version"], "1.0.60")
        self.assertEqual(Path(result["executable_path"]).read_text(encoding="utf-8"), "exe-60")
        pointer = json.loads((self.shared / "current.json").read_text(encoding="utf-8"))
        self.assertEqual(pointer["manifest_sha256"], result["manifest_sha256"])
        self.assertEqual(result["launch_env"]["SINYAUTOUPDATE_SHARED_VERSION"], "1")

    def test_repeat_is_idempotent_and_keeps_package_immutable(self) -> None:
        activate_local(self.state, "1.0.60", "exe-60")
        self.resolve()
        result = self.resolve()
        self.assertFalse(result["changed"])
        self.assertEqual(result["source_status"], "already-current")
        self.assertEqual(len(list((self.shared / "versions").iterdir())), 1)

    def test_shared_newer_version_cannot_be_downgraded(self) -> None:
        activate_local(self.state, "1.0.10", "exe-10")
        self.resolve()
        activate_local(self.state, "1.0.11", "exe-11")
        self.resolve()
        activate_local(self.state, "1.0.9", "exe-9")
        result = self.resolve()
        self.assertEqual(result["version"], "1.0.11")
        self.assertEqual(result["source_status"], "shared-newer")
        self.assertEqual(Path(result["executable_path"]).read_text(encoding="utf-8"), "exe-11")

    def test_same_version_different_contents_is_a_conflict(self) -> None:
        activate_local(self.state, "1.0.60", "exe-original")
        self.resolve()
        activate_local(self.state, "1.0.60", "exe-mutated")
        with self.assertRaisesRegex(SharedAppError, "Same app version"):
            self.resolve()
        self.assertEqual((self.shared / "versions" / "1.0.60" / "workboard.exe").read_text(encoding="utf-8"), "exe-original")

    def test_bad_local_hash_does_not_publish(self) -> None:
        activate_local(self.state, "1.0.60", "exe-60")
        (self.state / "apps" / "workboard" / "versions" / "1.0.60" / "workboard.exe").write_text("tampered", encoding="utf-8")
        with self.assertRaises(SharedAppError):
            self.resolve()
        self.assertFalse((self.shared / "current.json").exists())
        versions = self.shared / "versions"
        self.assertEqual(list(versions.iterdir()) if versions.exists() else [], [])

    def test_existing_shared_current_runs_without_local_cache(self) -> None:
        activate_local(self.state, "1.0.60", "exe-60")
        self.resolve()
        local_app = self.state / "apps" / "workboard"
        for child in local_app.iterdir():
            if child.name != "current.json":
                if child.is_dir():
                    import shutil
                    shutil.rmtree(child)
                else:
                    child.unlink()
        (local_app / "current.json").unlink()
        result = self.resolve()
        self.assertEqual(result["version"], "1.0.60")
        self.assertEqual(result["source_status"], "shared-current")

    def test_corrupt_current_recovers_only_to_verified_previous(self) -> None:
        activate_local(self.state, "1.0.10", "exe-10")
        self.resolve()
        activate_local(self.state, "1.0.11", "exe-11")
        self.resolve()
        (self.shared / "current.json").write_text("not-json", encoding="utf-8")
        local_app = self.state / "apps" / "workboard"
        for child in list(local_app.iterdir()):
            if child.is_dir():
                import shutil
                shutil.rmtree(child)
            else:
                child.unlink()
        result = self.resolve()
        self.assertEqual(result["version"], "1.0.10")
        self.assertEqual(result["source_status"], "recovered-previous")
        repaired = json.loads((self.shared / "current.json").read_text(encoding="utf-8"))
        self.assertEqual(repaired["version"], "1.0.10")


if __name__ == "__main__":
    unittest.main(verbosity=2)
