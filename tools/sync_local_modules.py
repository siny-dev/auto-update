#!/usr/bin/env python3
"""Build configured local module sources and verify/install them into AutoUpdate's user cache.

This path is intentionally local-only. It never edits outbox module pointers or contacts a remote service.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import time
from typing import Any, List, Optional, Tuple
import uuid

import resolve_modules


SEMVER_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
MODULE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


class LocalModuleSyncError(RuntimeError):
    pass


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise LocalModuleSyncError(f"Cannot read local module configuration: {exc}") from exc
    if not isinstance(value, dict):
        raise LocalModuleSyncError("Local module configuration must be a JSON object.")
    return value


def atomic_json(path: Path, value: dict[str, Any]) -> bytes:
    data = (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=".local-module-", suffix=".tmp", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    return data


def read_module_version(source_root: Path) -> str:
    init_path = source_root / "src" / "__init__.py"
    if init_path.is_symlink() or not init_path.is_file():
        raise LocalModuleSyncError("Local module source is missing src/__init__.py.")
    try:
        parsed = ast.parse(init_path.read_text(encoding="utf-8-sig"), filename=str(init_path))
    except (OSError, UnicodeError, SyntaxError) as exc:
        raise LocalModuleSyncError(f"Local module version declaration cannot be read: {exc}") from exc
    versions: List[str] = []
    for node in parsed.body:
        if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == "__version__" for target in node.targets):
            try:
                value = ast.literal_eval(node.value)
            except (ValueError, TypeError) as exc:
                raise LocalModuleSyncError("Local module __version__ must be a literal string.") from exc
            if not isinstance(value, str):
                raise LocalModuleSyncError("Local module __version__ must be a literal string.")
            versions.append(value)
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.target.id == "__version__":
            try:
                value = ast.literal_eval(node.value)
            except (ValueError, TypeError) as exc:
                raise LocalModuleSyncError("Local module __version__ must be a literal string.") from exc
            if not isinstance(value, str):
                raise LocalModuleSyncError("Local module __version__ must be a literal string.")
            versions.append(value)
    if len(versions) != 1 or not SEMVER_RE.fullmatch(versions[0]):
        raise LocalModuleSyncError("Local module must declare one major.minor.patch __version__.")
    return versions[0]


def module_manifest(spec: dict[str, Any], source_root: Path, version: str) -> Tuple[dict[str, Any], List[Tuple[Path, str]]]:
    module_id = spec.get("module_id")
    if not isinstance(module_id, str) or not MODULE_ID_RE.fullmatch(module_id):
        raise LocalModuleSyncError("Invalid local module ID.")
    api_major = spec.get("api_major")
    if isinstance(api_major, bool) or not isinstance(api_major, int) or api_major < 1:
        raise LocalModuleSyncError("Invalid local module API major.")
    minimum_engine = spec.get("minimum_engine")
    try:
        resolve_modules.parse_version(minimum_engine, "minimum AutoUpdate version")
    except resolve_modules.ResolverError as exc:
        raise LocalModuleSyncError(str(exc)) from exc
    activation = spec.get("activation_mode", "restart")
    if activation not in ("live", "restart"):
        raise LocalModuleSyncError("Invalid local module activation mode.")
    source_dir = source_root / "src"
    if source_dir.is_symlink() or not source_dir.is_dir():
        raise LocalModuleSyncError("Local module src directory is missing or is a symbolic link.")
    sources: List[Tuple[Path, str]] = []
    entries: list[dict[str, Any]] = []
    for source in sorted(source_dir.glob("*.py"), key=lambda item: item.name.casefold()):
        if source.is_symlink() or not source.is_file() or source.resolve().parent != source_dir.resolve():
            raise LocalModuleSyncError("Local module source files must be regular files directly inside src.")
        data = source.read_bytes()
        if len(data) > resolve_modules.MAX_MODULE_FILE_BYTES:
            raise LocalModuleSyncError(f"Local module source file is too large: {source.name}")
        relative = f"src/{source.name}"
        entries.append({
            "path": relative,
            "kind": "executable",
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "source": f"payload/{relative}",
        })
        sources.append((source, relative))
    if len(entries) > resolve_modules.MAX_MODULE_FILES:
        raise LocalModuleSyncError("Local module has more source files than the resolver permits.")
    if not any(entry["path"] == "src/__init__.py" for entry in entries):
        raise LocalModuleSyncError("Local module source is missing src/__init__.py.")
    manifest = {
        "schema": 1,
        "contract": "autoupdate-module-v1",
        "module_id": module_id,
        "version": version,
        "api_major": api_major,
        "minimum_engine": minimum_engine,
        "publisher_policy": "local-share-v1",
        "activation_mode": activation,
        "files": entries,
    }
    return manifest, sources


def build_local_source(spec: dict[str, Any], overlay_root: Path, state_root: Path,
                      engine_version: Tuple[int, int, int]) -> dict[str, Any]:
    source_value = spec.get("source_root")
    if not isinstance(source_value, str) or not source_value.strip():
        raise LocalModuleSyncError("Local module source_root is required.")
    source_root = Path(source_value).expanduser()
    if not source_root.is_absolute() or str(source_root).startswith(("\\\\", "//")):
        raise LocalModuleSyncError("Local module source_root must be an absolute local path, not a network path.")
    source_root = source_root.resolve(strict=True)
    if not source_root.is_dir():
        raise LocalModuleSyncError("Local module source_root is not a directory.")
    module_id = str(spec.get("module_id", ""))
    version = read_module_version(source_root)
    manifest, sources = module_manifest(spec, source_root, version)
    module_root = overlay_root / module_id
    versions_root = module_root / "versions"
    version_root = versions_root / version
    manifest_bytes = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    matching_manifests = [version_root / "module.json",
                          state_root / "modules" / module_id / "versions" / version / "module.json"]
    for existing_manifest_path in matching_manifests:
        if not existing_manifest_path.is_file():
            continue
        existing_root = existing_manifest_path.parent
        try:
            existing_manifest, _ = resolve_modules.validate_manifest(
                existing_root, module_id, engine_version,
                installed=not (existing_root / "payload").is_dir(),
            )
        except resolve_modules.ResolverError as exc:
            raise LocalModuleSyncError(f"Existing immutable local module version is invalid: {version}: {exc}") from exc
        if existing_manifest != manifest:
            raise LocalModuleSyncError(f"Local module {module_id} changed without a version bump ({version}).")
        # Preserve the exact manifest bytes for an immutable package already cached or staged.
        manifest_bytes = existing_manifest_path.read_bytes()
        break
    manifest_hash = hashlib.sha256(manifest_bytes).hexdigest()

    if version_root.exists():
        if version_root.is_symlink() or not version_root.is_dir():
            raise LocalModuleSyncError(f"Local module version path is not a directory: {version}")
        try:
            _, existing_hash = resolve_modules.validate_manifest(version_root, module_id, engine_version)
        except resolve_modules.ResolverError as exc:
            raise LocalModuleSyncError(f"Existing immutable local module version is invalid: {version}: {exc}") from exc
        if existing_hash != manifest_hash:
            raise LocalModuleSyncError(f"Local module {module_id} changed without a version bump ({version}).")
        status = "unchanged"
    else:
        versions_root.mkdir(parents=True, exist_ok=True)
        if versions_root.is_symlink():
            raise LocalModuleSyncError("Local module versions directory cannot be a symbolic link.")
        stage = versions_root / (".stage-" + uuid.uuid4().hex)
        stage.mkdir()
        try:
            for source, relative in sources:
                destination = stage / "payload" / Path(relative)
                destination.parent.mkdir(parents=True, exist_ok=True)
                data = source.read_bytes()
                with destination.open("xb") as stream:
                    stream.write(data)
                    stream.flush()
                    os.fsync(stream.fileno())
            (stage / "module.json").write_bytes(manifest_bytes)
            _, staged_hash = resolve_modules.validate_manifest(stage, module_id, engine_version)
            if staged_hash != manifest_hash:
                raise LocalModuleSyncError("Local module manifest changed while staging.")
            os.replace(stage, version_root)
        finally:
            if stage.exists():
                shutil.rmtree(stage)
        status = "built"

    pointer_path = module_root / "current.json"
    pointer = {
        "schema": 1,
        "module_id": module_id,
        "version": version,
        "api_major": manifest["api_major"],
        "manifest_sha256": manifest_hash,
        "activated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if pointer_path.exists():
        current = read_json(pointer_path)
        if current.get("schema") != 1 or current.get("module_id") != module_id:
            raise LocalModuleSyncError(f"Existing local source pointer is invalid: {module_id}")
        current_version = resolve_modules.parse_version(current.get("version"), "local source pointer version")
        candidate_version = resolve_modules.parse_version(version, "local module version")
        if current_version == candidate_version and current.get("manifest_sha256") != manifest_hash:
            raise LocalModuleSyncError(f"Local module source pointer conflicts at immutable version {version}.")
        if candidate_version < current_version:
            return {"module_id": module_id, "source_version": version, "source_status": "older-source-kept", "manifest_sha256": manifest_hash}
        if candidate_version == current_version:
            pointer = current
            status = "unchanged"
    else:
        module_root.mkdir(parents=True, exist_ok=True)
    atomic_json(pointer_path, pointer)
    return {"module_id": module_id, "source_version": version, "source_status": status, "manifest_sha256": manifest_hash}


def sync_local_modules(config_path: Path, state_root: Path, engine_version_text: str) -> dict[str, Any]:
    config = read_json(config_path)
    if config.get("schema") != 1 or not isinstance(config.get("modules"), list):
        raise LocalModuleSyncError("Unsupported local module source configuration.")
    if not config["modules"]:
        return {"schema": 1, "status": "no-modules", "modules": []}
    try:
        engine_version = resolve_modules.parse_version(engine_version_text, "AutoUpdate engine version")
    except resolve_modules.ResolverError as exc:
        raise LocalModuleSyncError(str(exc)) from exc
    module_ids: set[str] = set()
    overlay_root = state_root / "local-module-source"
    source_rows = []
    requirements = []
    for spec in config["modules"]:
        if not isinstance(spec, dict):
            raise LocalModuleSyncError("Each local module entry must be an object.")
        module_id = spec.get("module_id")
        if not isinstance(module_id, str) or not MODULE_ID_RE.fullmatch(module_id):
            raise LocalModuleSyncError("Invalid local module ID.")
        normalized = module_id.casefold()
        if normalized in module_ids:
            raise LocalModuleSyncError("Local module configuration contains a duplicate ID.")
        module_ids.add(normalized)
        source_rows.append(build_local_source(spec, overlay_root, state_root, engine_version))
        requirements.append({"module_id": module_id, "api_major": spec.get("api_major")})
    app_manifest = {
        "schema": 1,
        "contract": "autoupdate-app-modules-v1",
        "app_id": "local-module-updater",
        "modules": requirements,
    }
    app_manifest_path = overlay_root / "local-module-updater.json"
    atomic_json(app_manifest_path, app_manifest)
    resolution = resolve_modules.resolve_app(app_manifest_path, overlay_root, state_root, engine_version)
    resolved_by_id = {row["module_id"].casefold(): row for row in resolution["modules"]}
    result_rows = []
    for source_row in source_rows:
        resolved = resolved_by_id.get(source_row["module_id"].casefold())
        if not resolved or not resolved.get("verified"):
            raise LocalModuleSyncError(f"Local module did not resolve as verified: {source_row['module_id']}")
        result_rows.append({
            **source_row,
            "installed_version": resolved["version"],
            "install_status": resolved["source_status"],
            "verified": True,
        })
    return {"schema": 1, "status": "ready", "modules": result_rows}


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Apply local AutoUpdate module sources without a remote service.")
    parser.add_argument("--config", required=True)
    parser.add_argument("--state-root", required=True)
    parser.add_argument("--engine-version", required=True)
    args = parser.parse_args(argv)
    try:
        result = sync_local_modules(Path(args.config), Path(args.state_root), args.engine_version)
    except (LocalModuleSyncError, OSError, resolve_modules.ResolverError) as exc:
        sys.stderr.write("Local module sync failed: " + str(exc) + "\n")
        return 1
    sys.stdout.write(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
