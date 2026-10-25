$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\source\AutoUpdate.Core.psm1') -Force
$repoRoot=Split-Path -Parent $PSScriptRoot
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot=Join-Path $tempRoot ('AutoUpdate-engine-release-test-'+[guid]::NewGuid().ToString('N'))
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
try{
    [void][IO.Directory]::CreateDirectory($testRoot)
    $output=Join-Path $testRoot 'release'
    & (Join-Path $repoRoot 'tools\build-engine-release.ps1') -Version '9.8.7' -OutputRoot $output | Out-Null
    $manifest=Get-Content -Raw -LiteralPath (Join-Path $output 'autoupdate-manifest.json')|ConvertFrom-Json
    $expected=@('source/AutoUpdate.Core.psm1','tools/autoupdate.ps1','tools/restart-apply.ps1')
    Assert ($manifest.app_id -ceq 'AutoUpdate' -and $manifest.version -ceq '9.8.7' -and $manifest.mode -ceq 'restart') 'engine release identity or activation mode is wrong'
    Assert ($manifest.files.Count -eq $expected.Count) 'engine release does not contain every shared runtime file'
    foreach($relative in $expected){
        $entry=@($manifest.files|Where-Object{$_.path -ceq $relative})
        Assert ($entry.Count -eq 1) "engine release is missing or duplicates $relative"
        $source=Join-Path $repoRoot ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))
        $payload=Join-Path (Join-Path $output 'payload') ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))
        $asset=Join-Path (Join-Path $output 'assets') $entry[0].asset
        Assert (Test-Path -LiteralPath $payload -PathType Leaf) "engine payload is missing $relative"
        Assert (Test-Path -LiteralPath $asset -PathType Leaf) "GitHub release asset is missing $relative"
        $expectedHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert ((Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $expectedHash) "engine payload differs from source: $relative"
        Assert ((Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $entry[0].sha256) "release asset hash differs from manifest: $relative"
    }
    $state=Join-Path $testRoot 'state'
    $installed=Install-AuPackage -PackageRoot $output -StateRoot $state -AppId AutoUpdate -Architecture x64
    Assert ($installed.Version -ceq '9.8.7') 'shared engine release did not install'
    $verified=Get-AuVerifiedCurrent -StateRoot $state -AppId AutoUpdate -Architecture x64
    foreach($relative in $expected){Assert (Test-Path -LiteralPath (Join-Path $verified.Path ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))) -PathType Leaf) "verified installed engine is missing $relative"}
    $status=& (Join-Path $repoRoot 'tools\autoupdate.ps1') -Command status -StateRoot $state -AppId AutoUpdate -Architecture x64 | ConvertFrom-Json
    Assert ($status.Version -ceq '9.8.7') 'thin AutoUpdate bootstrap did not use the installed shared engine package'
    Write-Output 'PASS: published AutoUpdate release contains the engine, app connector CLI, and restart helper; all three verify and install together.'
}finally{
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notmatch '^AutoUpdate-engine-release-test-[a-f0-9]{32}$'){throw 'refusing unsafe test cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
