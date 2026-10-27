#!/usr/bin/env python3
"""Policy-neutral AutoUpdate module resolver for hosts where PowerShell scripts are disabled.

This is an AutoUpdate engine entry point, not an app-specific installer. It implements
the same immutable module package and per-PC cache contract as AutoUpdate.Core.psm1.
It never changes PowerShell execution policy and does not download or execute payloads.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


MAX_JSON_BYTES = 1024 * 1024
MAX_MODULE_FILE_BYTES = 256 * 1024 * 1024
MAX_MODULE_FILES = 4096
IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
VERSION_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
SHA256_RE = re.compile(r"^[A-Fa-f0-9]{64}$")


class ResolverError(Exception):
    """A safe-to-report resolver failure."""


def _no_duplicate_keys(pairs: Iterable[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ResolverError("JSON contains a duplicate key.")
        result[key] = value
    return result


def read_json(path: Path) -> Dict[str, Any]:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise ResolverError("A required JSON file cannot be read.") from exc
    if len(raw) > MAX_JSON_BYTES:
        raise ResolverError("A JSON file exceeds the size limit.")
    try:
        value = json.loads(raw.decode("utf-8-sig"), object_pairs_hook=_no_duplicate_keys)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ResolverError("A JSON file is invalid.") from exc
    if not isinstance(value, dict):
        raise ResolverError("A JSON document must be an object.")
    return value


def write_json_atomic(path: Path, value: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    fd, temporary_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".part", dir=str(path.parent))
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(str(temporary), str(path))
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def parse_version(value: Any, field: str) -> Tuple[int, int, int]:
    if not isinstance(value, str):
        raise ResolverError("Invalid " + field + ".")
    match = VERSION_RE.fullmatch(value)
    if not match:
        raise ResolverError("Invalid " + field + ".")
    parts = tuple(int(part) for part in match.groups())
    if any(part > 2147483647 for part in parts):
        raise ResolverError("Invalid " + field + ".")
    return parts  # type: ignore[return-value]


def valid_id(value: Any, field: str) -> str:
    if not isinstance(value, str) or not IDENTIFIER_RE.fullmatch(value):
        raise ResolverError("Invalid " + field + ".")
    return value


def contained_path(root: Path, relative: Any) -> Path:
    if not isinstance(relative, str) or not relative or any(ord(ch) < 32 for ch in relative):
        raise ResolverError("Unsafe module path.")
    normalized = relative.replace("\\", "/")
    pieces = normalized.split("/")
    if normalized.startswith("/") or ":" in normalized or any(piece in ("", ".", "..") for piece in pieces):
        raise ResolverError("Unsafe module path.")
    base = root.resolve(strict=False)
    candidate = (base.joinpath(*pieces)).resolve(strict=False)
    try:
        candidate.relative_to(base)
    except ValueError as exc:
        raise ResolverError("Module path escapes its root.") from exc
    return candidate


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        raise ResolverError("A module payload cannot be read.") from exc
    return digest.hexdigest()


def validate_manifest(package_root: Path, module_id: str, engine_version: Tuple[int, int, int], installed: bool = False) -> Tuple[Dict[str, Any], str]:
    manifest_path = contained_path(package_root, "module.json")
    manifest = read_json(manifest_path)
    if manifest.get("schema") != 1 or manifest.get("contract") != "autoupdate-module-v1":
        raise ResolverError("Unsupported module manifest.")
    if manifest.get("module_id") != module_id:
        raise ResolverError("Module identity mismatch.")
    version = parse_version(manifest.get("version"), "module version")
    if manifest.get("version") != ".".join(str(part) for part in version):
        raise ResolverError("Invalid module version.")
    api_major = manifest.get("api_major")
    if isinstance(api_major, bool) or not isinstance(api_major, int) or api_major < 1:
        raise ResolverError("Invalid module API major.")
    minimum = parse_version(manifest.get("minimum_engine"), "minimum AutoUpdate version")
    if engine_version < minimum:
        raise ResolverError("The module requires a newer AutoUpdate engine.")
    if manifest.get("publisher_policy") != "local-share-v1":
        raise ResolverError("Unsupported module publisher policy.")
    activation = manifest.get("activation_mode")
    if activation not in ("live", "restart"):
        raise ResolverError("Invalid module activation mode.")
    if activation == "live" and manifest.get("reload_contract") not in ("stateless-v1", "reload-hook-v1"):
        raise ResolverError("Live module reload contract is missing or unsupported.")
    files = manifest.get("files")
    if not isinstance(files, list) or not files or len(files) > MAX_MODULE_FILES:
        raise ResolverError("Invalid module file list.")

    seen = set()
    for entry in files:
        if not isinstance(entry, dict):
            raise ResolverError("Invalid module file entry.")
        for field in ("path", "kind", "size", "sha256", "source"):
            if field not in entry:
                raise ResolverError("Module file entry is incomplete.")
        relative_path = entry["path"]
        source_path = entry["path"] if installed else entry["source"]
        # Validate both paths before touching the filesystem.
        normalized = relative_path.replace("\\", "/").casefold() if isinstance(relative_path, str) else ""
        if normalized in seen:
            raise ResolverError("Duplicate module payload path.")
        seen.add(normalized)
        if entry["kind"] not in ("data", "resource", "executable", "runtime"):
            raise ResolverError("Unsupported module payload kind.")
        size = entry["size"]
        if isinstance(size, bool) or not isinstance(size, int) or size < 0 or size > MAX_MODULE_FILE_BYTES:
            raise ResolverError("Invalid module payload size.")
        if not isinstance(entry["sha256"], str) or not SHA256_RE.fullmatch(entry["sha256"]):
            raise ResolverError("Invalid module payload hash.")
        payload = contained_path(package_root, source_path)
        if not payload.is_file():
            raise ResolverError("A module payload is missing.")
        try:
            actual_size = payload.stat().st_size
        except OSError as exc:
            raise ResolverError("A module payload cannot be inspected.") from exc
        if actual_size != size or sha256_file(payload) != entry["sha256"].lower():
            raise ResolverError("A module payload failed size or SHA-256 verification.")
    return manifest, sha256_file(manifest_path)


def validate_source_pointer(module_root: Path, module_id: str, engine_version: Tuple[int, int, int]) -> Tuple[Dict[str, Any], Path]:
    pointer = read_json(contained_path(module_root, "current.json"))
    if pointer.get("schema") != 1 or pointer.get("module_id") != module_id:
        raise ResolverError("Invalid module source pointer.")
    version = pointer.get("version")
    version_parts = parse_version(version, "module source version")
    if not isinstance(pointer.get("manifest_sha256"), str) or not SHA256_RE.fullmatch(pointer["manifest_sha256"]):
        raise ResolverError("Invalid module source pointer hash.")
    if isinstance(pointer.get("api_major"), bool) or not isinstance(pointer.get("api_major"), int) or pointer["api_major"] < 1:
        raise ResolverError("Invalid module source pointer API.")
    package_root = contained_path(contained_path(module_root, "versions"), version)
    manifest, manifest_hash = validate_manifest(package_root, module_id, engine_version)
    if manifest.get("version") != ".".join(str(part) for part in version_parts):
        raise ResolverError("Module source directory and manifest versions differ.")
    if manifest_hash != pointer["manifest_sha256"].lower() or manifest["api_major"] != pointer["api_major"]:
        raise ResolverError("Module source pointer does not match its manifest.")
    return pointer, package_root


def verified_cached_versions(state_root: Path, module_id: str, api_major: int, engine_version: Tuple[int, int, int]) -> List[Dict[str, Any]]:
    versions_root = contained_path(contained_path(state_root, "modules"), module_id).joinpath("versions")
    if not versions_root.is_dir():
        return []
    candidates: List[Dict[str, Any]] = []
    for child in versions_root.iterdir():
        if not child.is_dir():
            continue
        try:
            version = parse_version(child.name, "cached module version")
            manifest, manifest_hash = validate_manifest(child, module_id, engine_version, installed=True)
            if manifest["version"] != child.name or manifest["api_major"] != api_major:
                continue
            candidates.append({"version_parts": version, "version": child.name, "api_major": api_major,
                               "activation_mode": manifest["activation_mode"], "path": child,
                               "manifest": manifest, "manifest_hash": manifest_hash})
        except (OSError, ResolverError):
            continue
    return sorted(candidates, key=lambda item: item["version_parts"], reverse=True)


class ModuleInstallLock:
    """Per-PC cross-process lock. Uses Windows byte-range locking; no policy changes."""

    def __init__(self, lock_path: Path, timeout: float = 30.0) -> None:
        self.lock_path = lock_path
        self.timeout = timeout
        self.stream = None

    def __enter__(self) -> "ModuleInstallLock":
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        self.stream = self.lock_path.open("a+b")
        if os.name == "nt":
            import msvcrt
            self.stream.seek(0, os.SEEK_END)
            if self.stream.tell() == 0:
                self.stream.write(b"\0")
                self.stream.flush()
            deadline = time.monotonic() + self.timeout
            while True:
                try:
                    self.stream.seek(0)
                    msvcrt.locking(self.stream.fileno(), msvcrt.LK_NBLCK, 1)
                    return self
                except OSError:
                    if time.monotonic() >= deadline:
                        self.stream.close()
                        self.stream = None
                        raise ResolverError("Another AutoUpdate process is installing this module.")
                    time.sleep(0.05)
        else:
            import fcntl
            fcntl.flock(self.stream.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        if self.stream is None:
            return
        try:
            if os.name == "nt":
                import msvcrt
                self.stream.seek(0)
                msvcrt.locking(self.stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.stream.fileno(), fcntl.LOCK_UN)
        finally:
            self.stream.close()
            self.stream = None


def install_candidate(candidate: Dict[str, Any], state_root: Path, module_id: str, engine_version: Tuple[int, int, int]) -> str:
    module_root = state_root / "modules" / module_id
    versions_root = module_root / "versions"
    staging_root = module_root / "staging"
    versions_root.mkdir(parents=True, exist_ok=True)
    staging_root.mkdir(parents=True, exist_ok=True)
    version = candidate["version"]
    version_path = versions_root / version
    with ModuleInstallLock(module_root / "install.lock"):
        status = "cached"
        if version_path.is_dir():
            try:
                _, existing_hash = validate_manifest(version_path, module_id, engine_version, installed=True)
            except ResolverError:
                existing_hash = ""
            if existing_hash != candidate["manifest_hash"]:
                return "conflict"
            status = "already-cached"
        else:
            stage = Path(tempfile.mkdtemp(prefix="stage-", dir=str(staging_root)))
            try:
                source_root = candidate["path"]
                manifest = candidate["manifest"]
                for entry in manifest["files"]:
                    source_path = contained_path(source_root, entry["source"])
                    destination = contained_path(stage, entry["path"])
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    # Copy first, then validate the copied bytes in the staged tree.
                    with source_path.open("rb") as incoming, destination.open("xb") as outgoing:
                        shutil.copyfileobj(incoming, outgoing, length=1024 * 1024)
                        outgoing.flush()
                        os.fsync(outgoing.fileno())
                (stage / "module.json").write_bytes((source_root / "module.json").read_bytes())
                _, staged_hash = validate_manifest(stage, module_id, engine_version, installed=True)
                if staged_hash != candidate["manifest_hash"]:
                    raise ResolverError("Staged module manifest changed during installation.")
                try:
                    os.replace(str(stage), str(version_path))
                except OSError:
                    if version_path.exists():
                        _, raced_hash = validate_manifest(version_path, module_id, engine_version, installed=True)
                        if raced_hash != candidate["manifest_hash"]:
                            return "conflict"
                        status = "already-cached"
                    else:
                        raise
            finally:
                if stage.exists():
                    shutil.rmtree(stage)

        pointer_path = module_root / "current.json"
        current = None
        try:
            current_doc = read_json(pointer_path)
            current_version = parse_version(current_doc.get("version"), "cached pointer version")
            current_root = versions_root / current_doc["version"]
            _, current_hash = validate_manifest(current_root, module_id, engine_version, installed=True)
            if current_hash == current_doc.get("manifest_sha256"):
                current = current_version
        except (OSError, KeyError, ResolverError):
            current = None
        if current is None or candidate["version_parts"] > current:
            pointer = {"schema": 1, "module_id": module_id, "version": version,
                       "api_major": candidate["api_major"], "manifest_sha256": candidate["manifest_hash"],
                       "activated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
            write_json_atomic(pointer_path, pointer)
            return "activated" if status == "cached" else "activated-cached"
        if candidate["version_parts"] < current:
            return "cached-compatible" if status == "cached" else "compatible-cache-ready"
        return "already-cached" if status == "already-cached" else status


def source_candidates(module_source_root: Path, module_id: str, api_major: int, engine_version: Tuple[int, int, int]) -> Tuple[List[Dict[str, Any]], Optional[str]]:
    try:
        module_root = contained_path(module_source_root, module_id)
        pointer, _ = validate_source_pointer(module_root, module_id, engine_version)
        max_version = parse_version(pointer["version"], "module source version")
        versions_root = contained_path(module_root, "versions")
        candidates: List[Dict[str, Any]] = []
        for child in versions_root.iterdir():
            if not child.is_dir():
                continue
            try:
                version = parse_version(child.name, "published module version")
                if version > max_version:
                    continue
                manifest, manifest_hash = validate_manifest(child, module_id, engine_version)
                if manifest.get("version") != child.name:
                    raise ResolverError("Published module directory and manifest differ.")
                if child.name == pointer["version"] and (manifest_hash != pointer["manifest_sha256"].lower() or manifest["api_major"] != pointer["api_major"]):
                    raise ResolverError("Published pointer does not match its current manifest.")
                if manifest["api_major"] == api_major:
                    candidates.append({"version_parts": version, "version": child.name, "api_major": api_major,
                                       "activation_mode": manifest["activation_mode"], "path": child,
                                       "manifest": manifest, "manifest_hash": manifest_hash})
            except (OSError, ResolverError):
                if child.name == pointer["version"]:
                    raise
        if not candidates:
            return [], None
        return sorted(candidates, key=lambda item: item["version_parts"], reverse=True), None
    except (OSError, ResolverError) as exc:
        return [], str(exc)


def resolve_app(app_manifest_path: Path, module_source_root: Path, state_root: Path,
                engine_version: Tuple[int, int, int]) -> Dict[str, Any]:
    state_root.mkdir(parents=True, exist_ok=True)
    app = read_json(app_manifest_path)
    if app.get("schema") != 1 or app.get("contract") != "autoupdate-app-modules-v1":
        raise ResolverError("Unsupported app module manifest.")
    app_id = valid_id(app.get("app_id"), "app ID")
    requirements = app.get("modules")
    if not isinstance(requirements, list):
        raise ResolverError("App module list must be an array.")
    resolved: List[Dict[str, Any]] = []
    seen = set()
    for requirement in requirements:
        if not isinstance(requirement, dict):
            raise ResolverError("Invalid app module requirement.")
        module_id = valid_id(requirement.get("module_id"), "module ID")
        api_major = requirement.get("api_major")
        if isinstance(api_major, bool) or not isinstance(api_major, int) or api_major < 1:
            raise ResolverError("Invalid required API major.")
        normalized_id = module_id.casefold()
        if normalized_id in seen:
            raise ResolverError("App module list contains a duplicate module ID.")
        seen.add(normalized_id)

        candidates, source_error = source_candidates(module_source_root, module_id, api_major, engine_version)
        source_status = "offline-cache"
        if candidates:
            try:
                source_status = install_candidate(candidates[0], state_root, module_id, engine_version)
            except (OSError, ResolverError) as exc:
                source_error = str(exc)
        cached = verified_cached_versions(state_root, module_id, api_major, engine_version)
        if not cached:
            reason = source_error or "No valid published version supports the requested API major."
            raise ResolverError("Required module " + module_id + " API " + str(api_major) + " is unavailable. " + reason)
        chosen = cached[0]
        resolved.append({"module_id": module_id, "version": chosen["version"], "api_major": chosen["api_major"],
                         "activation_mode": chosen["activation_mode"], "module_path": str(chosen["path"]),
                         "verified": True, "delivery_level": "L1", "runtime_state": "not-reported",
                         "source_status": source_status, "source_error": source_error})
    return {"schema": 1, "status": "ready", "app_id": app_id, "modules": resolved}


def detect_engine_version(state_root: Path) -> Tuple[int, int, int]:
    app_root = contained_path(state_root, "apps/AutoUpdate")
    pointer = read_json(contained_path(app_root, "current.json"))
    if pointer.get("schema") != 1 or pointer.get("app_id") != "AutoUpdate":
        raise ResolverError("Installed AutoUpdate pointer is invalid.")
    version = pointer.get("version")
    version_parts = parse_version(version, "AutoUpdate version")
    if not isinstance(pointer.get("manifest_sha256"), str) or not SHA256_RE.fullmatch(pointer["manifest_sha256"]):
        raise ResolverError("Installed AutoUpdate pointer hash is invalid.")
    package_root = contained_path(contained_path(app_root, "versions"), version)
    manifest_path = contained_path(package_root, "manifest.json")
    manifest = read_json(manifest_path)
    if manifest.get("app_id") != "AutoUpdate" or manifest.get("version") != version:
        raise ResolverError("Installed AutoUpdate manifest does not match its pointer.")
    if sha256_file(manifest_path) != pointer["manifest_sha256"].lower():
        raise ResolverError("Installed AutoUpdate manifest failed its pointer hash check.")
    return version_parts


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Resolve and verify AutoUpdate shared modules.")
    parser.add_argument("--app-manifest", required=True)
    parser.add_argument("--module-source-root", required=True)
    parser.add_argument("--state-root", default=os.path.join(os.environ.get("LOCALAPPDATA", str(Path.home())), "Siny", "AutoUpdate"))
    parser.add_argument("--engine-version", help="Use only when the caller independently verified the active AutoUpdate engine version.")
    args = parser.parse_args(argv)
    try:
        engine_version = parse_version(args.engine_version, "AutoUpdate version") if args.engine_version else detect_engine_version(Path(args.state_root))
        result = resolve_app(Path(args.app_manifest), Path(args.module_source_root), Path(args.state_root), engine_version)
        sys.stdout.write(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n")
        return 0
    except (OSError, ResolverError) as exc:
        sys.stderr.write("AutoUpdate module resolution failed: " + str(exc) + "\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
