# Shared module contract v1

An application declares stable module IDs and required API major versions in an `autoupdate-app-modules-v1` JSON file. AutoUpdate reads the shared-folder source, verifies the immutable version manifest and every SHA-256, and copies each version once into the PC user's common AutoUpdate state root:

```text
%LOCALAPPDATA%\Siny\AutoUpdate\modules\<module-id>\versions\<version>\
```

Apps on that PC resolve the same cached module path. Another PC maintains its own cache and downloads the module once there. `current.json` is only a latest-version pointer; apps resolve the newest intact cached version matching their required `api_major`, so a new incompatible API major does not silently break older apps. Version folders are immutable. A reused version with different content is reported as a conflict; it is never overwritten.

The local source is:

```text
<ModuleSourceRoot>\<module-id>\current.json
<ModuleSourceRoot>\<module-id>\versions\<version>\module.json
<ModuleSourceRoot>\<module-id>\versions\<version>\payload\...
```

Publish a package using `tools/autoupdate.ps1 -Command publish-module -ModuleId <id> -PackageRoot <package> -ModuleSourceRoot <shared-module-root>`. The version folder is written and hash-verified first; the source pointer advances last. Only publish a version once, and do not edit a published version in place.

Resolve requirements using `tools/autoupdate.ps1 -Command resolve-modules -AppManifestPath <app-modules.json> -ModuleSourceRoot <shared-module-root> -StateRoot <shared-PC-state-root>`. The JSON result includes each verified module's version, activation mode, and local cache path. If the shared folder is unavailable, a previously cached compatible version is returned. If there is no compatible cache, resolution fails without modifying the app.

The application must call the resolver at its normal update check (10 minutes in production; 5 minutes while testing) and activate the returned path through its own safe-point adapter. Loading a new path does not replace code already loaded into memory. Resource/data modules can be switched live when the app has a safe boundary; code/runtime modules require a reload hook that actually unloads and reloads the module, otherwise mark the module `restart` and use the existing save-state/restart/restore path. This contract provides shared storage and version selection; it does not claim every existing app is connected automatically. Each app needs a one-time dependency declaration and activation adapter.

The v1 publisher policy is local shared-folder trust (`local-share-v1`); there is no signature/remote trust model yet. SHA-256 detects accidental damage and inconsistent files, but does not authenticate who published a package. Keep the module source folder writable only by the intended maintainers. GitHub publication is deliberately outside this local pilot.
## Delivery and activation evidence (L1/L2/L3)

A resolver result is only delivery evidence: each resolved module reports delivery_level=L1 and runtime_state=not-reported. L1 means a SHA-256-verified immutable version exists in the PC cache; it does not mean the application loaded or activated it.

After an app connector actually loads that version, it reports L2. Only after the app's safe-point reload commits and new calls are using that version may it report L3. A connector may report these transitions through the shared CLI:

- autoupdate.ps1 -Command report-module-status -AppId <app-id> -ModuleId <module-id> -Version <version> -RuntimeState loaded -ApplicationProcessId <app-process-id>
- autoupdate.ps1 -Command report-module-status -AppId <app-id> -ModuleId <module-id> -Version <version> -RuntimeState active -ApplicationProcessId <app-process-id>
- autoupdate.ps1 -Command module-status -AppId <app-id> -ModuleId <module-id>

loaded is reported only after the app loads the verified module path. active is reported only after its actual activation hook succeeds; downloading or changing a pointer is not enough. When the CLI runs as a child process, pass the host application's process ID. Status is saved per PC, app, module, and process under the AutoUpdate state root. The query includes process liveness checked against the process start time, so a stale record from an exited process is not presented as a live instance. Existing apps need a one-time connector change before they can report L2/L3.

## Publisher overlap

Local module publication now holds an exclusive open-file lock at <ModuleSourceRoot>\locks\<module-id>.publish.lock while it validates and stages the immutable version and switches the pointer. Competing publishers fail without changing the pointer and may retry on their next cycle. A leftover lock file is harmless because exclusion is held by the open handle, which the OS releases when the process exits. The current automated test covers concurrent local processes; cross-PC SMB handle-lock behavior still needs a two-PC pilot test.
