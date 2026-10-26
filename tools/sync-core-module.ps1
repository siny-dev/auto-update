param(
    [string]$StateRoot=(Join-Path $env:LOCALAPPDATA 'Siny\AutoUpdate'),
    [string]$ModuleSourceRoot=(Join-Path (Split-Path -Parent $PSScriptRoot) 'outbox\modules')
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$moduleRoot=Join-Path $ModuleSourceRoot 'AutoUpdate'
$pointerPath=Join-Path $moduleRoot 'current.json'
$version='1.0.0'
$unchanged=$false
if(Test-Path -LiteralPath $pointerPath -PathType Leaf){
    $pointer=Get-Content -Raw -LiteralPath $pointerPath|ConvertFrom-Json
    if($pointer.schema -ne 1 -or $pointer.module_id -cne 'AutoUpdate' -or $pointer.version -notmatch '^\d+\.\d+\.\d+$'){throw 'AutoUpdate module pointer is invalid.'}
    $currentVersion=[version]$pointer.version
    $version='{0}.{1}.{2}' -f $currentVersion.Major,$currentVersion.Minor,($currentVersion.Build+1)
    $packageRoot=Join-Path (Join-Path $moduleRoot 'versions') ([string]$pointer.version)
    $manifestPath=Join-Path $packageRoot 'module.json'
    if(Test-Path -LiteralPath $manifestPath -PathType Leaf){
        $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        $unchanged=$manifest.module_id -ceq 'AutoUpdate' -and [int]$manifest.api_major -eq 1 -and @($manifest.files).Count -eq 2
        foreach($entry in @($manifest.files)){
            $relative=[string]$entry.path
            if($relative -notin @('tools/autoupdate.ps1','source/AutoUpdate.Core.psm1')){$unchanged=$false;break}
            $source=Join-Path $root ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))
            $published=Join-Path (Join-Path $packageRoot 'payload') ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))
            if(-not (Test-Path -LiteralPath $source -PathType Leaf) -or -not (Test-Path -LiteralPath $published -PathType Leaf) -or
               (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ine [string]$entry.sha256 -or
               (Get-FileHash -LiteralPath $published -Algorithm SHA256).Hash -ine [string]$entry.sha256){$unchanged=$false;break}
        }
    }
}
$core=Join-Path $root 'source\AutoUpdate.Core.psm1'
$requiredEngineFunctions=@('Publish-AuLocalModulePackage')
$loadedEngine=Get-Module -Name 'AutoUpdate.Core' -ErrorAction SilentlyContinue|Select-Object -First 1
$engineCanPublish=$false
$engineCanInstall=$false
if($loadedEngine){
    $availableFunctions=@(Get-Command -Module $loadedEngine.Name -ErrorAction SilentlyContinue|Select-Object -ExpandProperty Name)
    $engineCanPublish='Publish-AuLocalModulePackage' -in $availableFunctions
    $engineCanInstall='Install-AuModulePackage' -in $availableFunctions
}
# Keep an already-running worker's engine untouched. Import source into this sync scope only if no publisher is loaded.
if(-not $engineCanPublish){
    Import-Module $core -Force -Scope Local
    $engineCanPublish=$null -ne (Get-Command -Name 'Publish-AuLocalModulePackage' -ErrorAction SilentlyContinue)
    $engineCanInstall=$null -ne (Get-Command -Name 'Install-AuModulePackage' -ErrorAction SilentlyContinue)
}
if(-not $engineCanPublish){throw 'The active AutoUpdate engine cannot publish the shared module.'}
if($unchanged){
    $cache=$null
    if($engineCanInstall){$cache=Install-AuModulePackage -PackageRoot $packageRoot -StateRoot $StateRoot -ModuleId AutoUpdate}
    [pscustomobject]@{status='unchanged';module_id='AutoUpdate';version=[string]$pointer.version;cache_status=$(if($cache){[string]$cache.Status}else{'installer-unavailable'});cache_version=$(if($cache){[string]$cache.Version}else{$null});message='Shared AutoUpdate module matches its source; local cache activation was attempted when supported by the loaded engine.'}|ConvertTo-Json -Compress
    exit 0
}
$work=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-module-package-'+[guid]::NewGuid().ToString('N'))
$sourceRoot=Join-Path $work 'source';$package=Join-Path $work 'package'
try{
    foreach($relative in @('tools/autoupdate.ps1','source/AutoUpdate.Core.psm1')){
        $source=Join-Path $root ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))
        if(-not (Test-Path -LiteralPath $source -PathType Leaf)){throw "AutoUpdate module source is missing: $relative"}
        $target=Join-Path $sourceRoot ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        [IO.File]::Copy($source,$target,$false)
    }
    & (Join-Path $PSScriptRoot 'build-module-package.ps1') -ModuleId AutoUpdate -Version $version -ApiMajor 1 -MinimumEngine '0.1.0' -SourceRoot $sourceRoot -OutputRoot $package -ActivationMode restart | Out-Null
    $result=Publish-AuLocalModulePackage -PackageRoot $package -ModuleSourceRoot $ModuleSourceRoot -ModuleId AutoUpdate
    $cache=$null
    if($result.Status -in @('published','already-published') -and $engineCanInstall){$cache=Install-AuModulePackage -PackageRoot $package -StateRoot $StateRoot -ModuleId AutoUpdate}
    [pscustomobject]@{status=[string]$result.Status;module_id='AutoUpdate';version=$version;cache_status=$(if($cache){[string]$cache.Status}elseif($result.Status -in @('published','already-published')){'installer-unavailable'}else{'not-installed'});cache_version=$(if($cache){[string]$cache.Version}else{$null});message=[string]$result.Message}|ConvertTo-Json -Compress
}finally{
    if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
}
