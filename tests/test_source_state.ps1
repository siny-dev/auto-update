$ErrorActionPreference = 'Stop'
$projectRoot = Get-ChildItem -LiteralPath 'C:\AI-Work' -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'AutoUpdate\source\AutoUpdate.Core.psm1') } |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $projectRoot) { throw 'Could not locate AutoUpdate project root.' }
$core = Join-Path $projectRoot 'AutoUpdate\source\AutoUpdate.Core.psm1'
$builder = Join-Path $projectRoot 'AutoUpdate\tools\build-module-package.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-source-state-test-' + [guid]::NewGuid().ToString('N'))
$sourceRoot = Join-Path $testRoot 'source'
$stateRoot = Join-Path $testRoot 'state'
$appPath = Join-Path $testRoot 'app-modules.json'
$moduleId = 'ProbeLib'

function Assert-State($Result, [string]$State, [string]$Code, [string]$Status = $null) {
    $row = $Result.modules[0]
    if ($row.source_state -cne $State) { throw "Expected source_state=$State; got $($row.source_state)." }
    if ($Code -eq '<null>') {
        if ($null -ne $row.source_error_code) { throw "Expected null source_error_code; got $($row.source_error_code)." }
    } elseif ($row.source_error_code -cne $Code) {
        throw "Expected source_error_code=$Code; got $($row.source_error_code)."
    }
    if ($Status -and $row.source_status -cne $Status) { throw "Expected source_status=$Status; got $($row.source_status)." }
    if (-not $row.verified) { throw 'Resolver returned an unverified module.' }
}

function Build-AndPublish([string]$Version, [int]$ApiMajor, [string]$Body, [string]$MinimumEngine = '0.1.0') {
    $source = Join-Path $testRoot ('src-' + $Version + '-' + $ApiMajor + '-' + [guid]::NewGuid().ToString('N'))
    $package = Join-Path $testRoot ('pkg-' + $Version + '-' + $ApiMajor + '-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($source)
    [IO.File]::WriteAllText((Join-Path $source 'module.psm1'), $Body, [Text.UTF8Encoding]::new($false))
    & $builder -ModuleId $moduleId -Version $Version -ApiMajor $ApiMajor -MinimumEngine $MinimumEngine `
        -SourceRoot $source -OutputRoot $package -ActivationMode restart | Out-Null
    $published = Publish-AuLocalModulePackage -PackageRoot $package -ModuleSourceRoot $sourceRoot -ModuleId $moduleId
    if ($published.Status -cne 'published') { throw "Synthetic source publish failed: $($published.Status)." }
    return $package
}

function Build-AndStageSource([string]$Version, [int]$ApiMajor, [string]$Body, [string]$MinimumEngine) {
    $source = Join-Path $testRoot ('src-' + $Version + '-' + $ApiMajor + '-' + [guid]::NewGuid().ToString('N'))
    $package = Join-Path $testRoot ('pkg-' + $Version + '-' + $ApiMajor + '-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($source)
    [IO.File]::WriteAllText((Join-Path $source 'module.psm1'), $Body, [Text.UTF8Encoding]::new($false))
    & $builder -ModuleId $moduleId -Version $Version -ApiMajor $ApiMajor `
        -SourceRoot $source -OutputRoot $package -ActivationMode restart | Out-Null
    $versionRoot = Join-Path (Join-Path (Join-Path $sourceRoot $moduleId) 'versions') $Version
    [void][IO.Directory]::CreateDirectory($versionRoot)
    Get-ChildItem -LiteralPath $package -Force | Copy-Item -Destination $versionRoot -Recurse -Force
    $manifestPath = Join-Path $versionRoot 'module.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.minimum_engine = $MinimumEngine
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $pointer = [ordered]@{schema=1;module_id=$moduleId;version=$Version;api_major=$ApiMajor;manifest_sha256=(Get-AuFileSha256 $manifestPath)}
    [IO.File]::WriteAllText((Join-Path (Join-Path $sourceRoot $moduleId) 'current.json'),
        ($pointer | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

try {
    if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) { throw "Expected Windows PowerShell 5.1; got $($PSVersionTable.PSVersion)." }
    Import-Module -Name $core -Force
    [void][IO.Directory]::CreateDirectory($testRoot)
    [void][IO.Directory]::CreateDirectory($sourceRoot)
    $app = [ordered]@{schema=1;contract='autoupdate-app-modules-v1';app_id='source-state-test';modules=@(@{module_id=$moduleId;api_major=1})}
    [IO.File]::WriteAllText($appPath, ($app | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

    $null = Build-AndPublish '1.0.0' 1 'function Get-Probe { "good" }'
    $available = Resolve-AuAppModules -AppManifestPath $appPath -ModuleSourceRoot $sourceRoot -StateRoot $stateRoot
    Assert-State $available 'available' '<null>'
    if ($available.modules[0].version -cne '1.0.0') { throw 'Available source selected the wrong version.' }

    $payload = Join-Path $sourceRoot 'ProbeLib\versions\1.0.0\payload\module.psm1'
    $originalPayload = [IO.File]::ReadAllText($payload)
    [IO.File]::WriteAllText($payload, ('X' + $originalPayload.Substring(1)), [Text.UTF8Encoding]::new($false))
    $badHash = Resolve-AuAppModules -AppManifestPath $appPath -ModuleSourceRoot $sourceRoot -StateRoot $stateRoot
    Assert-State $badHash 'invalid' 'payload_hash_mismatch' 'offline-cache'
    if ($badHash.modules[0].version -cne '1.0.0') { throw 'Invalid source did not retain the verified cache.' }

    Remove-Item -LiteralPath $payload -Force
    $missingPayload = Resolve-AuAppModules -AppManifestPath $appPath -ModuleSourceRoot $sourceRoot -StateRoot $stateRoot
    Assert-State $missingPayload 'invalid' 'missing_payload' 'offline-cache'

    Remove-Item -LiteralPath (Join-Path $sourceRoot 'ProbeLib\versions\1.0.0\module.json') -Force
    $missingManifest = Resolve-AuAppModules -AppManifestPath $appPath -ModuleSourceRoot $sourceRoot -StateRoot $stateRoot
    Assert-State $missingManifest 'invalid' 'missing_manifest' 'offline-cache'

    Remove-Item -LiteralPath (Join-Path $sourceRoot 'ProbeLib\current.json') -Force
    $unavailable = Resolve-AuAppModules -AppManifestPath $appPath -ModuleSourceRoot $sourceRoot -StateRoot $stateRoot
    Assert-State $unavailable 'unavailable' 'source_unavailable' 'offline-cache'

    [IO.File]::WriteAllText((Join-Path $sourceRoot 'ProbeLib\current.json'), '{broken', [Text.UTF8Encoding]::new($false))
    $invalidPointer = Resolve-AuAppModules -AppManifestPath $appPath -ModuleSourceRoot $sourceRoot -StateRoot $stateRoot
    Assert-State $invalidPointer 'invalid' 'invalid_pointer' 'offline-cache'

    Remove-Item -LiteralPath (Join-Path $sourceRoot 'ProbeLib') -Recurse -Force
    [void](Build-AndPublish '2.0.0' 2 'function Get-Probe { "api two" }')
    $apiMismatch = Resolve-AuAppModules -AppManifestPath $appPath -ModuleSourceRoot $sourceRoot -StateRoot $stateRoot
    Assert-State $apiMismatch 'incompatible' 'api_incompatible' 'offline-cache'

    Remove-Item -LiteralPath (Join-Path $sourceRoot 'ProbeLib') -Recurse -Force
    Build-AndStageSource '1.1.0' 1 'function Get-Probe { "newer engine" }' '9.9.9'
    $engineMismatch = Resolve-AuAppModules -AppManifestPath $appPath -ModuleSourceRoot $sourceRoot -StateRoot $stateRoot
    Assert-State $engineMismatch 'incompatible' 'minimum_engine' 'offline-cache'

    Remove-Item -LiteralPath (Join-Path $sourceRoot 'ProbeLib') -Recurse -Force
    [void](Build-AndPublish '1.0.0' 1 'function Get-Probe { "different same version" }')
    $installConflict = Resolve-AuAppModules -AppManifestPath $appPath -ModuleSourceRoot $sourceRoot -StateRoot $stateRoot
    Assert-State $installConflict 'install_conflict' 'install_conflict' 'conflict'
    if ($installConflict.modules[0].version -cne '1.0.0') { throw 'Install conflict replaced the verified cached version.' }

    "PASS: Windows PowerShell $($PSVersionTable.PSVersion); 9 source_state outcomes (available, unavailable, invalid/missing manifest/payload, invalid pointer, API/minimum-engine incompatibility, install conflict)"
} finally {
    Remove-Module AutoUpdate.Core -ErrorAction SilentlyContinue
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolvedRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Split-Path -Leaf $resolvedRoot).StartsWith('AutoUpdate-source-state-test-', [StringComparison]::Ordinal)) {
        throw 'Refusing unsafe source-state fixture cleanup.'
    }
    if (Test-Path -LiteralPath $resolvedRoot) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
}
