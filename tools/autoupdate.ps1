param(
    [Parameter(Mandatory=$true)][ValidateSet('install','install-local','update','status','resolve','register','publish-module','resolve-modules')][string]$Command,
    [string]$PackageRoot,
    [string]$StateRoot=(Join-Path $env:LOCALAPPDATA 'Siny\AutoUpdate'),
    [string]$AppId='AutoUpdate',
    [ValidateSet('x86','x64','arm64')][string]$Architecture='x64',
    [string]$Owner,
    [string]$Repository,
    [string]$ModuleId,
    [string]$ModuleSourceRoot='\\H255\AI-Work\제작중인 프로그램\AutoUpdate\outbox\modules',
    [string]$AppManifestPath
)
$ErrorActionPreference='Stop'
$sourceModule=Join-Path $PSScriptRoot '..\source\AutoUpdate.Core.psm1'
$enginePointerPath=Join-Path $StateRoot 'apps\AutoUpdate\current.json'
if(Test-Path -LiteralPath $enginePointerPath -PathType Leaf){
    $enginePointer=Get-Content -Raw -LiteralPath $enginePointerPath|ConvertFrom-Json
    if($enginePointer.schema -ne 1 -or $enginePointer.app_id -cne 'AutoUpdate' -or $enginePointer.version -notmatch '^\d+\.\d+\.\d+$'){throw 'Installed AutoUpdate pointer is invalid.'}
    $installedRoot=Join-Path $StateRoot ('apps\AutoUpdate\versions\'+$enginePointer.version)
    $engineManifest=Get-Content -Raw -LiteralPath (Join-Path $installedRoot 'manifest.json')|ConvertFrom-Json
    $engineEntry=@($engineManifest.files|Where-Object{$_.kind -eq 'runtime' -and $_.path -ceq 'source/AutoUpdate.Core.psm1'})
    if($engineEntry.Count -ne 1){throw 'Installed AutoUpdate package has no single engine module.'}
    $candidate=Join-Path $installedRoot 'source\AutoUpdate.Core.psm1'
    if((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ine $engineEntry[0].sha256){throw 'Installed AutoUpdate engine hash is invalid.'}
    $requiredFunction=switch($Command){'publish-module'{'function Publish-AuLocalModulePackage'}'resolve-modules'{'function Resolve-AuAppModules'}default{'function Get-AuVerifiedCurrent'}}
    if(Select-String -LiteralPath $candidate -SimpleMatch $requiredFunction -Quiet){$sourceModule=$candidate}
}
Import-Module $sourceModule -Force
try {
    if ($Command -eq 'install') {
        if ([string]::IsNullOrWhiteSpace($PackageRoot)) { throw 'PackageRoot is required for install.' }
        $result = Install-AuPackage -PackageRoot $PackageRoot -StateRoot $StateRoot -AppId $AppId -Architecture $Architecture
    } elseif ($Command -eq 'install-local') {
        if ([string]::IsNullOrWhiteSpace($PackageRoot)) { throw 'PackageRoot is required for install-local.' }
        $localPackage = Get-AuLatestLocalPackage -PackageRoot $PackageRoot -AppId $AppId -Architecture $Architecture
        if (-not $localPackage) { $result = [pscustomobject]@{Status='not-found';AppId=$AppId;Version=$null;Path=$null;Mode=$null;Message='No valid local package is available.'} }
        else { $result = Install-AuPackage -PackageRoot $localPackage.Path -StateRoot $StateRoot -AppId $AppId -Architecture $Architecture }
    } elseif ($Command -eq 'update') {
        if([string]::IsNullOrWhiteSpace($Owner)){$Owner='siny-dev'};if([string]::IsNullOrWhiteSpace($Repository)){$Repository='auto-update'}
        $result = Install-AuLatestRelease -Owner $Owner -Repository $Repository -AppId $AppId -StateRoot $StateRoot -Architecture $Architecture
    } elseif ($Command -eq 'register') {
        if([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($Repository)){throw 'Owner and Repository are required for registration.'}
        $result = Register-AuApplication -StateRoot $StateRoot -AppId $AppId -Owner $Owner -Repository $Repository -Architecture $Architecture
    } elseif ($Command -eq 'publish-module') {
        if([string]::IsNullOrWhiteSpace($PackageRoot) -or [string]::IsNullOrWhiteSpace($ModuleSourceRoot) -or [string]::IsNullOrWhiteSpace($ModuleId)){throw 'PackageRoot, ModuleSourceRoot, and ModuleId are required for publish-module.'}
        $result = Publish-AuLocalModulePackage -PackageRoot $PackageRoot -ModuleSourceRoot $ModuleSourceRoot -ModuleId $ModuleId
    } elseif ($Command -eq 'resolve-modules') {
        if([string]::IsNullOrWhiteSpace($AppManifestPath) -or [string]::IsNullOrWhiteSpace($ModuleSourceRoot)){throw 'AppManifestPath and ModuleSourceRoot are required for resolve-modules.'}
        $result = Resolve-AuAppModules -AppManifestPath $AppManifestPath -ModuleSourceRoot $ModuleSourceRoot -StateRoot $StateRoot
    } else {
        $result = Get-AuVerifiedCurrent -StateRoot $StateRoot -AppId $AppId -Architecture $Architecture
        if (-not $result) { $result = [pscustomobject]@{Status='not-installed';AppId=$AppId} }
        elseif($result.Manifest.architecture -ne 'any' -and $result.Manifest.architecture -ne $Architecture){throw 'Active package architecture does not match this application.'}
        elseif($Command -eq 'resolve') { $result=[pscustomobject]@{schema=1;status='ready';app_id=$result.AppId;version=$result.Version;mode=$result.Mode;package_path=$result.Path;verified=$true;manifest=$result.Manifest} }
    }
    $result | ConvertTo-Json -Depth 8 -Compress
    if($Command -eq 'resolve' -and $result.Status -eq 'not-installed'){exit 2}
    exit 0
} catch {
    [Console]::Error.WriteLine(($_.Exception.Message -replace '(github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+)','[REDACTED]'))
    exit 1
}
