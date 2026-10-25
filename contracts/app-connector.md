# AutoUpdate app connector contract v1

The common updater stores immutable, verified package versions and atomically changes one `current.json` pointer per app. The app reads the selected version from the returned package path. It must never execute files from the shared source checkout or from a staging directory.

Each connector supplies its stable `app_id`, platform architecture, writable per-user `StateRoot`, current app version, and callbacks for safe application. The current core exposes `Install-AuPackage` and `Get-AuCurrent`; the connector remains responsible for app-specific UI state and the actual live/restart boundary.

For a `live` package, every entry must be data or a resource, and the app must declare the compatible schema and a safe activation point. The connector switches resources as a complete set and keeps the current process, windows, unsaved input, timers, and work state intact. A package containing executable or updater-runtime code cannot be marked `live`.

For a `restart` package, the app first captures and durably writes its UI/work state, then asks the updater helper to apply it after normal shutdown. The new process restores the same state and acknowledges health. Only then may the previous executable be retired. If startup or restoration fails, return to the previous version and state. User settings, credentials, cache, and user data are outside package paths.

The engine core is loaded by versioned path, not copied into each app. Updating the common engine installs a new immutable engine version and switches its pointer. Connectors reload it at a safe update boundary. An app needs a one-time connector integration; existing apps without it do not receive common-engine changes automatically.

The package schema uses SHA-256 and an explicit publisher policy. Production downloads must come from the configured GitHub release API over validated HTTPS; credentials are read from Windows Credential Manager and are never included in app configuration, arguments, logs, or package files. File/temporary package installation is reserved for local verification.
