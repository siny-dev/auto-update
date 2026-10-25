$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-builder-engine-scope-'+[guid]::NewGuid().ToString('N'))
$runtimeModule=Join-Path $tempRoot 'state\apps\AutoUpdate\versions\0.1.1805\source\AutoUpdate.Core.psm1'
$sourceModule=Join-Path $tempRoot 'source\AutoUpdate.Core.psm1'
$builder=Join-Path $tempRoot 'tools\build-local-package.ps1'
try{
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $runtimeModule))
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $sourceModule))
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $builder))
    [IO.File]::WriteAllText($runtimeModule,@"
function Get-AuLatestLocalPackage { 'installed-engine' }
function Compare-AuPackageCandidates { 'installed-engine' }
function Get-AuFileSha256([string]`$Path) { (Get-FileHash -LiteralPath `$Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Test-AuModuleManifest([object]`$Manifest,[string]`$ExpectedModuleId) { `$true }
function Publish-AuLocalModulePackage([string]`$PackageRoot,[string]`$ModuleSourceRoot,[string]`$ModuleId) { [pscustomobject]@{Status='published';ModuleId=`$ModuleId;Version='1.0.0';Message='test'} }
"@,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($sourceModule,"function Get-AuLatestLocalPackage { 'source-engine' }`nfunction Compare-AuPackageCandidates { 'source-engine' }",[Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools\build-local-package.ps1') -Destination $builder
    Import-Module $runtimeModule -Force -Global
    $before=(Get-Module -Name 'AutoUpdate.Core'|Select-Object -First 1).Path
    $recipe=Join-Path $tempRoot 'invalid-build.json'
    [IO.File]::WriteAllText($recipe,'{"app_id":"!invalid"}',[Text.UTF8Encoding]::new($false))
    $expectedFailure=$false
    try{& $builder -RecipePath $recipe -PackageRoot (Join-Path $tempRoot 'packages')|Out-Null}catch{$expectedFailure=$_.Exception.Message -match 'Invalid app_id'}
    if(-not $expectedFailure){throw 'Builder did not reach the expected validation point.'}
    $after=(Get-Module -Name 'AutoUpdate.Core'|Select-Object -First 1).Path
    $selected=Get-AuLatestLocalPackage
    if($before -ne $after -or $after -ne $runtimeModule -or $selected -ne 'installed-engine'){
        throw 'Calling the local builder replaced the active versioned engine with the source module.'
    }
    Write-Output 'PASS: the local package builder preserves the already-loaded engine.'

    $moduleRepo=Join-Path $tempRoot 'module-repo'
    $moduleTools=Join-Path $moduleRepo 'tools'
    $moduleSource=Join-Path $tempRoot 'module-input'
    $moduleOutput=Join-Path $tempRoot 'module-output'
    $publishedRoot=Join-Path $tempRoot 'published-modules'
    $marker=Join-Path $tempRoot 'source-engine-imported.txt'
    [void][IO.Directory]::CreateDirectory($moduleTools)
    [void][IO.Directory]::CreateDirectory((Join-Path $moduleRepo 'source'))
    [void][IO.Directory]::CreateDirectory($moduleSource)
    [IO.File]::WriteAllText((Join-Path $moduleSource 'sample.txt'),'module payload',[Text.UTF8Encoding]::new($false))
    $sourceCode=@"
Set-Content -LiteralPath '$marker' -Value 'source module was imported'
function Get-AuFileSha256([string]`$Path) { (Get-FileHash -LiteralPath `$Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Test-AuModuleManifest([object]`$Manifest,[string]`$ExpectedModuleId) { `$true }
function Publish-AuLocalModulePackage([string]`$PackageRoot,[string]`$ModuleSourceRoot,[string]`$ModuleId) { [pscustomobject]@{Status='published';ModuleId=`$ModuleId;Version='1.0.0';Message='test'} }
"@
    [IO.File]::WriteAllText((Join-Path $moduleRepo 'source\AutoUpdate.Core.psm1'),$sourceCode,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $moduleRepo 'tools\autoupdate.ps1'),'# fixture',[Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools\build-module-package.ps1') -Destination $moduleTools
    $moduleBuilder=Join-Path $moduleTools 'build-module-package.ps1'
    & $moduleBuilder -ModuleId TestModule -Version 1.0.0 -ApiMajor 1 -SourceRoot $moduleSource -OutputRoot $moduleOutput | Out-Null
    $afterModuleBuild=(Get-Module -Name 'AutoUpdate.Core'|Select-Object -First 1).Path
    if($afterModuleBuild -ne $runtimeModule -or (Test-Path -LiteralPath $marker)){throw 'The module package builder replaced the active engine with the source module.'}
    Write-Output 'PASS: the module package builder preserves the already-loaded engine.'

    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools\sync-core-module.ps1') -Destination $moduleTools
    [IO.File]::WriteAllText((Join-Path $moduleTools 'build-module-package.ps1'),'param([string]$ModuleId,[string]$Version,[int]$ApiMajor,[string]$MinimumEngine,[string]$SourceRoot,[string]$OutputRoot,[string]$ActivationMode)',[Text.UTF8Encoding]::new($false))
    $syncResult=& (Join-Path $moduleTools 'sync-core-module.ps1') -StateRoot (Join-Path $tempRoot 'sync-state') -ModuleSourceRoot $publishedRoot | Out-String
    $afterSync=(Get-Module -Name 'AutoUpdate.Core'|Select-Object -First 1).Path
    if($afterSync -ne $runtimeModule -or (Test-Path -LiteralPath $marker) -or ($syncResult|ConvertFrom-Json).status -ne 'published'){
        throw 'The core module sync replaced the active engine with the source module.'
    }
    Write-Output 'PASS: the core module sync preserves the engine used by the current worker cycle.'
}finally{
    $full=[IO.Path]::GetFullPath($tempRoot)
    $tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($full.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase)-and (Test-Path -LiteralPath $full)){
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
}
