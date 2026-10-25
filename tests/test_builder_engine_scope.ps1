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
    [IO.File]::WriteAllText($runtimeModule,"function Get-AuLatestLocalPackage { 'installed-engine' }`nfunction Compare-AuPackageCandidates { 'installed-engine' }",[Text.UTF8Encoding]::new($false))
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
    Write-Output 'PASS: the package builder preserves an already-loaded versioned AutoUpdate engine.'
}finally{
    $full=[IO.Path]::GetFullPath($tempRoot)
    $tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($full.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase)-and (Test-Path -LiteralPath $full)){
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
}