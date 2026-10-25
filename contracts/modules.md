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

Resolve requirements using `tools/autoupdate.ps1 -Command resolve-modules -AppManifestPath <app.json> -ModuleSourceRoot <shared-module-root> -StateRoot <shared-PC-state-root>`. The JSON result includes each verified module's version, activation mode, and local cache path. If the shared folder is unavailable, a previously cached compatible version is returned. If there is no compatible cache, resolution fails without modifying the app.

The application must call the resolver at its normal update check (10 minutes in production; 5 minutes while testing) and activate the returned path through its own safe-point adapter. Loading a new path does not replace code already loaded into memory. Resource/data modules can be switched live when the app has a safe boundary; code/runtime modules require a reload hook that actually unloads and reloads the module, otherwise mark the module `restart` and use the existing save-state/restart/restore path. This contract provides shared storage and version selection; it does not claim every existing app is connected automatically. Each app needs a one-time dependency declaration and activation adapter.

The v1 publisher policy is local shared-folder trust (`local-share-v1`); there is no signature/remote trust model yet. SHA-256 detects accidental damage and inconsistent files, but does not authenticate who published a package. Keep the module source folder writable only by the intended maintainers. GitHub publication is deliberately outside this local pilot.
