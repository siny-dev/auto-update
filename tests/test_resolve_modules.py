import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "resolve_modules.py"
SPEC = importlib.util.spec_from_file_location("resolve_modules", SCRIPT)
resolver = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(resolver)


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")


class AutoUpdatePythonModuleResolverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="autoupdate-python-resolver-test-")
        self.root = Path(self.temp.name)
        self.source = self.root / "shared-modules"
        self.state = self.root / "state"
        self.app_manifest = self.root / "app-modules.json"
        self.engine_version = (0, 1, 1812)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def build_module(self, version: str, api_major: int, payload: bytes = b"autosync api") -> Path:
        module_root = self.source / "AutoSync"
        package_root = module_root / "versions" / version
        payload_path = package_root / "payload" / "src" / "client.py"
        payload_path.parent.mkdir(parents=True, exist_ok=True)
        payload_path.write_bytes(payload)
        manifest = {
            "schema": 1,
            "contract": "autoupdate-module-v1",
            "module_id": "AutoSync",
            "version": version,
            "api_major": api_major,
            "minimum_engine": "0.1.0",
            "publisher_policy": "local-share-v1",
            "activation_mode": "restart",
            "files": [{
                "path": "src/client.py",
                "kind": "runtime",
                "size": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
                "source": "payload/src/client.py",
            }],
        }
        manifest_path = package_root / "module.json"
        write_json(manifest_path, manifest)
        manifest_hash = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        write_json(module_root / "current.json", {
            "schema": 1,
            "module_id": "AutoSync",
            "version": version,
            "api_major": api_major,
            "manifest_sha256": manifest_hash,
        })
        return package_root

    def set_app_api(self, api_major: int = 1) -> None:
        write_json(self.app_manifest, {
            "schema": 1,
            "contract": "autoupdate-app-modules-v1",
            "app_id": "workboard",
            "modules": [{"module_id": "AutoSync", "api_major": api_major}],
        })

    def resolve(self) -> dict:
        return resolver.resolve_app(self.app_manifest, self.source, self.state, self.engine_version)

    def test_fresh_cache_install_then_reuse_is_verified(self) -> None:
        self.build_module("0.1.13", 1)
        self.set_app_api(1)
        first = self.resolve()
        module = first["modules"][0]
        self.assertEqual(first["status"], "ready")
        self.assertEqual(module["version"], "0.1.13")
        self.assertEqual(module["delivery_level"], "L1")
        self.assertEqual(module["runtime_state"], "not-reported")
        self.assertEqual((Path(module["module_path"]) / "src" / "client.py").read_bytes(), b"autosync api")
        self.assertTrue((self.state / "modules" / "AutoSync" / "current.json").is_file())
        second = self.resolve()
        self.assertEqual(second["modules"][0]["source_status"], "already-cached")

    def test_incompatible_published_api_does_not_replace_compatible_cache(self) -> None:
        self.build_module("0.1.12", 1, b"old api")
        self.set_app_api(1)
        self.resolve()
        self.build_module("0.2.0", 2, b"new incompatible api")
        result = self.resolve()
        self.assertEqual(result["modules"][0]["version"], "0.1.12")
        self.assertEqual(result["modules"][0]["api_major"], 1)

    def test_corrupt_source_falls_back_only_to_verified_compatible_cache(self) -> None:
        self.build_module("0.1.12", 1, b"known good")
        self.set_app_api(1)
        self.resolve()
        payload = self.source / "AutoSync" / "versions" / "0.1.12" / "payload" / "src" / "client.py"
        payload.write_bytes(b"tampered")
        result = self.resolve()
        self.assertEqual(result["modules"][0]["version"], "0.1.12")
        self.assertEqual(result["modules"][0]["source_status"], "offline-cache")
        cached_payload = Path(result["modules"][0]["module_path"]) / "src" / "client.py"
        self.assertEqual(cached_payload.read_bytes(), b"known good")

    def test_bad_hash_with_empty_cache_fails_without_partial_version(self) -> None:
        package = self.build_module("0.1.13", 1)
        (package / "payload" / "src" / "client.py").write_bytes(b"tampered")
        self.set_app_api(1)
        with self.assertRaises(resolver.ResolverError):
            self.resolve()
        versions = self.state / "modules" / "AutoSync" / "versions"
        self.assertFalse(versions.exists())

    def test_unsafe_payload_path_is_rejected(self) -> None:
        package = self.build_module("0.1.13", 1)
        manifest_path = package / "module.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["files"][0]["source"] = "payload/../outside.py"
        write_json(manifest_path, manifest)
        module_root = self.source / "AutoSync"
        pointer = json.loads((module_root / "current.json").read_text(encoding="utf-8"))
        pointer["manifest_sha256"] = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        write_json(module_root / "current.json", pointer)
        self.set_app_api(1)
        with self.assertRaises(resolver.ResolverError):
            self.resolve()

    def test_duplicate_json_keys_are_rejected(self) -> None:
        self.app_manifest.write_text(
            '{"schema":1,"schema":1,"contract":"autoupdate-app-modules-v1","app_id":"workboard","modules":[]}',
            encoding="utf-8",
        )
        with self.assertRaises(resolver.ResolverError):
            self.resolve()

    def test_cli_reads_verified_engine_version_and_emits_json(self) -> None:
        self.build_module("0.1.13", 1)
        self.set_app_api(1)
        engine_root = self.state / "apps" / "AutoUpdate"
        engine_package = engine_root / "versions" / "0.1.1812"
        engine_package.mkdir(parents=True)
        engine_manifest_path = engine_package / "manifest.json"
        write_json(engine_manifest_path, {"schema": 1, "contract": "autoupdate-app-v1", "app_id": "AutoUpdate", "version": "0.1.1812", "files": []})
        write_json(engine_root / "current.json", {
            "schema": 1,
            "app_id": "AutoUpdate",
            "version": "0.1.1812",
            "manifest_sha256": hashlib.sha256(engine_manifest_path.read_bytes()).hexdigest(),
        })
        result = subprocess.run([
            sys.executable, str(SCRIPT),
            "--app-manifest", str(self.app_manifest),
            "--module-source-root", str(self.source),
            "--state-root", str(self.state),
        ], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output["modules"][0]["version"], "0.1.13")

    def test_installed_engine_manifest_pointer_hash_is_required(self) -> None:
        engine_root = self.state / "apps" / "AutoUpdate"
        engine_package = engine_root / "versions" / "0.1.1812"
        engine_package.mkdir(parents=True)
        manifest_path = engine_package / "manifest.json"
        write_json(manifest_path, {"app_id": "AutoUpdate", "version": "0.1.1812"})
        write_json(engine_root / "current.json", {
            "schema": 1,
            "app_id": "AutoUpdate",
            "version": "0.1.1812",
            "manifest_sha256": "0" * 64,
        })
        with self.assertRaises(resolver.ResolverError):
            resolver.detect_engine_version(self.state)

    def test_concurrent_resolves_install_one_immutable_version(self) -> None:
        self.build_module("0.1.13", 1)
        self.set_app_api(1)
        command = [
            sys.executable, str(SCRIPT),
            "--app-manifest", str(self.app_manifest),
            "--module-source-root", str(self.source),
            "--state-root", str(self.state),
            "--engine-version", "0.1.1812",
        ]
        first = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        second = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        first_out, first_err = first.communicate(timeout=20)
        second_out, second_err = second.communicate(timeout=20)
        self.assertEqual(first.returncode, 0, first_err)
        self.assertEqual(second.returncode, 0, second_err)
        first_result = json.loads(first_out)
        second_result = json.loads(second_out)
        self.assertEqual(first_result["modules"][0]["version"], "0.1.13")
        self.assertEqual(second_result["modules"][0]["version"], "0.1.13")
        versions = list((self.state / "modules" / "AutoSync" / "versions").iterdir())
        self.assertEqual([path.name for path in versions if path.is_dir()], ["0.1.13"])
        staging = self.state / "modules" / "AutoSync" / "staging"
        self.assertFalse(list(staging.iterdir()))


if __name__ == "__main__":
    unittest.main()
