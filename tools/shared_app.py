#!/usr/bin/env python3
"""Verify and publish an AutoUpdate app package to a shared immutable run path.

This helper uses only the Python standard library and never executes PowerShell.
It copies an already verified AutoUpdate app cache entry, then atomically moves a
small pointer so all PCs using the same share select the same package version.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tempfile
import time
import uuid
from pathlib import Path, PurePosixPath
from typing import Any, Iterator


APP_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
VERSION_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
SHA256_RE = re.compile(r"^[A-Fa-f0-9]{64}$")
MANIFEST_LIMIT = 4 * 1024 * 1024
MAX_FILES = 10_000
MAX_FILE_BYTES = 256 * 1024 * 1024
MAX_TOTAL_BYTES = 4 * 1024 * 1024 * 1024
LOCK_TIMEOUT_SECONDS = 30.0


class SharedAppError(Exception):
    """A package, pointer, or shared filesystem failed a safety check."""


def _pairs_no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise SharedAppError("JSON contains a duplicate key.")
        result[key] = value
    return result


def read_json(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_bytes()
        if len(raw) > MANIFEST_LIMIT:
            raise SharedAppError("JSON file exceeds the size limit.")
        value = json.loads(raw.decode("utf-8-sig"), object_pairs_hook=_pairs_no_duplicates)
    except SharedAppError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise SharedAppError("JSON file is missing or invalid.") from exc
    if not isinstance(value, dict):
        raise SharedAppError("JSON root must be an object.")
    return value


def parse_version(value: Any) -> tuple[int, int, int]:
    if not isinstance(value, str):
        raise SharedAppError("Package version is invalid.")
    match = VERSION_RE.fullmatch(value)
    if not match:
        raise SharedAppError("Package version is invalid.")
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def safe_relative(value: Any) -> str:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        raise SharedAppError("Package contains an unsafe relative path.")
    if value.startswith("/") or ":" in value:
        raise SharedAppError("Package contains an unsafe relative path.")
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise SharedAppError("Package contains an unsafe relative path.")
    normalized = PurePosixPath(value).as_posix()
    if normalized != value:
        raise SharedAppError("Package path is not normalized.")
    return value


def contained_path(root: Path, relative: str) -> Path:
    relative = safe_relative(relative)
    root_resolved = root.resolve(strict=False)
    candidate = root_resolved.joinpath(*relative.split("/"))
    resolved = candidate.resolve(strict=False)
    try:
        resolved.relative_to(root_resolved)
    except ValueError as exc:
        raise SharedAppError("Package path escapes its root.") from exc
    current = root_resolved
    for part in relative.split("/"):
        current = current / part
        try:
            info = current.lstat()
        except FileNotFoundError:
            continue
        attributes = getattr(info, "st_file_attributes", 0)
        reparse = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
        if stat.S_ISLNK(info.st_mode) or attributes & reparse:
            raise SharedAppError("Package paths cannot use symbolic links or reparse points.")
    return resolved


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as exc:
        raise SharedAppError("A package file cannot be read.") from exc
    return digest.hexdigest()


def verify_package(package_root: Path, app_id: str, architecture: str,
                   entry_point: str) -> tuple[dict[str, Any], str, Path]:
    manifest_path = package_root / "manifest.json"
    manifest = read_json(manifest_path)
    manifest_hash = sha256_file(manifest_path)
    manifest_app_id = manifest.get("app_id")
    if (manifest.get("schema") != 1 or manifest.get("contract") != "autoupdate-app-v1"
            or not isinstance(manifest_app_id, str) or manifest_app_id.casefold() != app_id.casefold()):
        raise SharedAppError("App manifest identity or contract is invalid.")
    version = manifest.get("version")
    parse_version(version)
    if manifest.get("mode") not in ("live", "restart"):
        raise SharedAppError("App manifest activation mode is invalid.")
    if manifest.get("platform") != "windows":
        raise SharedAppError("App package platform is unsupported.")
    if manifest.get("publisher_policy") != "github-release-asset-https":
        raise SharedAppError("App package publisher policy is unsupported.")
    if manifest.get("architecture") not in ("any", architecture):
        raise SharedAppError("App package architecture does not match this PC.")
    if not isinstance(manifest.get("minimum_engine"), str) or not VERSION_RE.fullmatch(manifest["minimum_engine"]):
        raise SharedAppError("App manifest minimum engine version is invalid.")
    files = manifest.get("files")
    if not isinstance(files, list) or not files or len(files) > MAX_FILES:
        raise SharedAppError("App manifest file list is invalid.")
    names: set[str] = set()
    total_bytes = 0
    resolved_entry: Path | None = None
    for item in files:
        if not isinstance(item, dict):
            raise SharedAppError("App manifest contains an invalid file entry.")
        rel = safe_relative(item.get("path"))
        key = rel.casefold()
        if key in names:
            raise SharedAppError("App manifest contains a duplicate file path.")
        names.add(key)
        if item.get("kind") not in ("data", "resource", "executable", "runtime"):
            raise SharedAppError("App manifest contains an unsupported file kind.")
        size = item.get("size")
        if isinstance(size, bool) or not isinstance(size, int) or not 0 <= size <= MAX_FILE_BYTES:
            raise SharedAppError("App manifest contains an invalid file size.")
        total_bytes += size
        if total_bytes > MAX_TOTAL_BYTES:
            raise SharedAppError("App package exceeds the total size limit.")
        digest = item.get("sha256")
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
            raise SharedAppError("App manifest contains an invalid file hash.")
        path = contained_path(package_root, rel)
        if not path.is_file() or path.stat().st_size != size or sha256_file(path) != digest.lower():
            raise SharedAppError("App package file failed size or SHA-256 verification.")
        if rel.casefold() == entry_point.casefold():
            if item["kind"] != "executable" or Path(rel).suffix.casefold() != ".exe":
                raise SharedAppError("Configured entry point is not a Windows executable payload.")
            resolved_entry = path
    if resolved_entry is None:
        raise SharedAppError("Configured entry point is missing from the app manifest.")
    return manifest, manifest_hash, resolved_entry


def pointer_path(root: Path, app_id: str, version: str) -> Path:
    return contained_path(root, f"versions/{version}/manifest.json").parent


def verify_pointer(root: Path, pointer_name: str, app_id: str, architecture: str,
                   entry_point: str) -> tuple[dict[str, Any], dict[str, Any], Path]:
    pointer = read_json(root / pointer_name)
    version = pointer.get("version")
    parse_version(version)
    pointer_app_id = pointer.get("app_id")
    if (pointer.get("schema") != 1 or not isinstance(pointer_app_id, str)
            or pointer_app_id.casefold() != app_id.casefold()
            or pointer.get("mode") not in ("live", "restart")
            or not isinstance(pointer.get("manifest_sha256"), str)
            or not SHA256_RE.fullmatch(pointer["manifest_sha256"])):
        raise SharedAppError("App current pointer is invalid.")
    package_root = pointer_path(root, app_id, version)
    manifest, manifest_hash, entry = verify_package(package_root, app_id, architecture, entry_point)
    if (manifest_hash != pointer["manifest_sha256"].lower()
            or manifest["version"] != version or manifest["mode"] != pointer["mode"]):
        raise SharedAppError("App current pointer does not match its verified package.")
    return pointer, manifest, entry


@contextlib.contextmanager
def shared_lock(root: Path, timeout: float = LOCK_TIMEOUT_SECONDS) -> Iterator[None]:
    lock_path = root / ".autoupdate-shared.lock"
    root.mkdir(parents=True, exist_ok=True)
    stream = lock_path.open("a+b")
    try:
        stream.seek(0, os.SEEK_END)
        if stream.tell() == 0:
            stream.write(b"\0")
            stream.flush()
        deadline = time.monotonic() + timeout
        while True:
            try:
                stream.seek(0)
                if os.name == "nt":
                    import msvcrt
                    msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except (OSError, BlockingIOError):
                if time.monotonic() >= deadline:
                    raise SharedAppError("Timed out waiting for the shared app publisher lock.")
                time.sleep(0.1)
        try:
            yield
        finally:
            stream.seek(0)
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
    finally:
        stream.close()


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    data = (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    temp = path.with_name(path.name + "." + uuid.uuid4().hex + ".part")
    try:
        with temp.open("xb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        try:
            temp.unlink()
        except FileNotFoundError:
            pass


def make_pointer(app_id: str, manifest: dict[str, Any], manifest_hash: str) -> dict[str, Any]:
    return {
        "schema": 1,
        "app_id": app_id,
        "version": manifest["version"],
        "mode": manifest["mode"],
        "manifest_sha256": manifest_hash,
        "activated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def publish_package(source_root: Path, shared_root: Path, app_id: str, architecture: str,
                    entry_point: str) -> tuple[dict[str, Any], bool]:
    manifest, manifest_hash, _ = verify_package(source_root, app_id, architecture, entry_point)
    version = manifest["version"]
    versions_root = shared_root / "versions"
    staging_root = shared_root / "staging"
    versions_root.mkdir(parents=True, exist_ok=True)
    staging_root.mkdir(parents=True, exist_ok=True)
    destination = contained_path(shared_root, f"versions/{version}")

    if destination.exists():
        _, existing_hash, _ = verify_package(destination, app_id, architecture, entry_point)
        if existing_hash != manifest_hash:
            raise SharedAppError("Immutable shared version already exists with different contents.")
        return manifest, False

    stage = staging_root / ("stage-" + uuid.uuid4().hex)
    stage.mkdir()
    try:
        for item in manifest["files"]:
            rel = item["path"]
            source = contained_path(source_root, rel)
            target = contained_path(stage, rel)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        shutil.copyfile(source_root / "manifest.json", stage / "manifest.json")
        _, staged_hash, _ = verify_package(stage, app_id, architecture, entry_point)
        if staged_hash != manifest_hash:
            raise SharedAppError("Staged shared app manifest changed during copy.")
        try:
            os.rename(stage, destination)
        except OSError:
            if not destination.exists():
                raise
            _, existing_hash, _ = verify_package(destination, app_id, architecture, entry_point)
            if existing_hash != manifest_hash:
                raise SharedAppError("Concurrent publisher created a conflicting immutable version.")
        return manifest, True
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def _read_shared_current(shared_root: Path, app_id: str, architecture: str,
                         entry_point: str) -> tuple[dict[str, Any] | None, dict[str, Any] | None,
                                                   Path | None, str]:
    current_path = shared_root / "current.json"
    if current_path.exists():
        try:
            pointer, manifest, entry = verify_pointer(shared_root, "current.json", app_id, architecture, entry_point)
            return pointer, manifest, entry, "shared-current"
        except SharedAppError as current_error:
            try:
                pointer, manifest, entry = verify_pointer(shared_root, "previous.json", app_id, architecture, entry_point)
                return pointer, manifest, entry, "recovered-previous"
            except SharedAppError:
                raise SharedAppError("Shared current and previous pointers are invalid.") from current_error
    previous_path = shared_root / "previous.json"
    if previous_path.exists():
        pointer, manifest, entry = verify_pointer(shared_root, "previous.json", app_id, architecture, entry_point)
        return pointer, manifest, entry, "recovered-previous"
    return None, None, None, "no-shared-current"


def _activate_pointer(shared_root: Path, pointer: dict[str, Any], previous: dict[str, Any] | None) -> None:
    previous_path = shared_root / "previous.json"
    if previous is not None:
        atomic_write_json(previous_path, previous)
    atomic_write_json(shared_root / "current.json", pointer)


def resolve_shared_app(state_root: Path, shared_root: Path, app_id: str, architecture: str,
                       entry_point: str) -> dict[str, Any]:
    if not APP_ID_RE.fullmatch(app_id):
        raise SharedAppError("App ID is invalid.")
    entry_point = safe_relative(entry_point)
    local_root = state_root / "apps" / app_id
    local_pointer = None
    local_manifest = None
    local_entry = None
    local_error: SharedAppError | None = None
    try:
        local_pointer, local_manifest, local_entry = verify_pointer(local_root, "current.json", app_id, architecture, entry_point)
    except SharedAppError as exc:
        local_error = exc

    shared_root.mkdir(parents=True, exist_ok=True)
    with shared_lock(shared_root):
        shared_pointer, shared_manifest, shared_entry, shared_status = _read_shared_current(
            shared_root, app_id, architecture, entry_point)
        current_recovered = shared_status == "recovered-previous"
        chosen_pointer = shared_pointer
        chosen_manifest = shared_manifest
        chosen_entry = shared_entry
        changed = False
        source_status = shared_status

        if local_pointer is not None and local_manifest is not None:
            local_version = parse_version(local_pointer["version"])
            shared_version = parse_version(shared_pointer["version"]) if shared_pointer else None
            if shared_pointer is None or local_version > shared_version:  # type: ignore[operator]
                published_manifest, _ = publish_package(
                    local_root / "versions" / local_pointer["version"], shared_root,
                    app_id, architecture, entry_point)
                new_pointer = make_pointer(app_id, published_manifest, local_pointer["manifest_sha256"])
                _activate_pointer(shared_root, new_pointer, shared_pointer)
                chosen_pointer, chosen_manifest = new_pointer, published_manifest
                chosen_entry = contained_path(shared_root, f"versions/{new_pointer['version']}/{entry_point}")
                changed, source_status = True, "activated-local"
            elif local_version == shared_version:
                if local_pointer["manifest_sha256"].lower() != shared_pointer["manifest_sha256"].lower():
                    raise SharedAppError("Same app version has different local and shared manifest hashes.")
                source_status = "already-current"
            else:
                source_status = "shared-newer"
        elif shared_pointer is None:
            if local_error is not None:
                raise SharedAppError("No verified local package or shared current is available.") from local_error
            raise SharedAppError("No verified local package or shared current is available.")

        if chosen_pointer is None or chosen_manifest is None or chosen_entry is None:
            raise SharedAppError("No verified shared app version is available.")
        if current_recovered and not changed:
            _activate_pointer(shared_root, chosen_pointer, None)
            changed = True
            source_status = "recovered-previous"
        if not chosen_entry.is_file():
            raise SharedAppError("Verified shared executable is missing.")
        # Verify once more after selection so a damaged share is never launched.
        _, final_manifest, final_entry = verify_pointer(shared_root, "current.json", app_id, architecture, entry_point)
        return {
            "schema": 1,
            "status": "ready",
            "app_id": app_id,
            "version": final_manifest["version"],
            "mode": final_manifest["mode"],
            "verified": True,
            "changed": changed,
            "source_status": source_status,
            "manifest_sha256": sha256_file(final_entry.parent / "manifest.json"),
            "executable_path": str(final_entry),
            "launch_env": {"SINYAUTOUPDATE_SHARED_VERSION": "1"},
        }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Resolve a verified AutoUpdate app into a common immutable run path.")
    parser.add_argument("--state-root", default=os.path.join(os.environ.get("LOCALAPPDATA", str(Path.home())), "Siny", "AutoUpdate"))
    parser.add_argument("--shared-root", required=True)
    parser.add_argument("--app-id", required=True)
    parser.add_argument("--entrypoint", required=True)
    parser.add_argument("--architecture", choices=("x86", "x64", "arm64"), required=True)
    args = parser.parse_args(argv)
    try:
        result = resolve_shared_app(Path(args.state_root), Path(args.shared_root),
                                    args.app_id, args.architecture, args.entrypoint)
        sys.stdout.write(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n")
        return 0
    except SharedAppError as exc:
        sys.stderr.write("AutoUpdate shared app resolution failed: " + str(exc) + "\n")
        return 3
    except OSError:
        sys.stderr.write("AutoUpdate shared app resolution failed: shared storage is unavailable.\n")
        return 4


if __name__ == "__main__":
    raise SystemExit(main())
