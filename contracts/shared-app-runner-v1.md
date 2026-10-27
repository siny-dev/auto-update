# Shared App Runner contract v1

## Purpose

Use one verified AutoUpdate app package from the common AI-Work project tree on every PC. The runner promotes a locally verified package into an immutable shared version directory and returns the executable path selected by one shared current pointer. It does not run the app itself.

## Invocation

Call the Python standard-library helper without PowerShell:

python.exe \\H255\AI-Work\제작중인 프로그램\AutoUpdate\tools\shared_app.py --state-root "$env:LOCALAPPDATA\Siny\AutoUpdate" --shared-root "C:\AI-Work\제작중인 프로그램\Workboard\실행본" --app-id workboard --entrypoint workboard.exe --architecture x86

The Python executable must be available on that PC. The caller may resolve it from the AutoSync host config or PATH. Run it hidden from the launcher, capture stdout/stderr and wait for completion.

## Shared layout

- current.json: the one pointer read by both PCs.
- previous.json: the last known-good pointer for recovery.
- versions/<version>/: immutable manifest and payload files at the manifest's path values.
- staging/<unique-id>/: private candidate copy; only a verified candidate is renamed into versions.
- .autoupdate-shared.lock: an OS-managed exclusive byte-range lock; it is released automatically if a process exits.

The pointer fields reuse the existing AutoUpdate app pointer contract: schema, app_id, version, mode, manifest_sha256, activated_utc. Package manifests retain autoupdate-app-v1.

## Result contract

Success exits 0 and writes one compact JSON object to stdout:
schema, status=ready, app_id, version, mode, verified=true, changed, source_status, manifest_sha256, executable_path, launch_env.

The launcher sets launch_env variables for the child process. SINYAUTOUPDATE_SHARED_VERSION=1 means legacy in-place app self-updaters must not replace files in the immutable version directory.

Exit 3 means validation, integrity, or version conflict; exit 4 means shared storage or lock I/O failure; argparse uses exit 2 for invalid arguments. On failure the launcher must not run an unverified legacy executable.

## Safety behavior

- Validate the local current pointer, manifest hash, architecture, entry-point kind, every payload size and SHA-256 before staging.
- Copy to a unique staging folder, re-check the staged bytes, then rename within the shared volume.
- Reject same-version/different-content conflicts and never move the shared pointer backwards.
- Atomically replace current.json only after the immutable version is ready. Preserve previous.json and older version directories.
- If current.json is damaged, only use a fully verified previous.json; if neither is valid, fail closed.
- If a PC is offline from the local update source but the shared current is valid, it may run that shared current.