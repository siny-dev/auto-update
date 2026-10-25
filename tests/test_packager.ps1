$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\source\AutoUpdate.Core.psm1') -Force
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot=Join-Path $tempRoot ('AutoUpdate-package-test-'+[guid]::NewGuid().ToString('N'))
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $payload=Join-Path $testRoot 'payload';[void][IO.Directory]::CreateDirectory((Join-Path $payload 'source'))
    $engineSource=Join-Path $PSScriptRoot '..\source\AutoUpdate.Core.psm1'
    Copy-Item -LiteralPath $engineSource -Destination (Join-Path $payload 'source\AutoUpdate.Core.psm1')
    $spec=[ordered]@{app_id='AutoUpdate';version='0.1.0';mode='restart';platform='windows';architecture='any';minimum_engine='0.1.0';files=@(@{path='source/AutoUpdate.Core.psm1';kind='runtime'})}
    $specPath=Join-Path $testRoot 'spec.json';[IO.File]::WriteAllText($specPath,($spec|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    $output=Join-Path $testRoot 'release'
    & (Join-Path $PSScriptRoot '..\tools\new-release-package.ps1') -SpecPath $specPath -PayloadRoot $payload -OutputRoot $output | Out-Null
    $manifest=Get-Content -Raw -LiteralPath (Join-Path $output 'autoupdate-manifest.json')|ConvertFrom-Json
    Assert ($manifest.app_id -eq 'AutoUpdate' -and $manifest.version -eq '0.1.0') 'package identity was not preserved'
    Assert ($manifest.files.Count -eq 1 -and $manifest.files[0].kind -eq 'runtime') 'package file contract is wrong'
    $asset=Join-Path (Join-Path $output 'assets') $manifest.files[0].asset
    Assert (Test-Path -LiteralPath $asset -PathType Leaf) 'release asset was not generated'
    Assert ((Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash.ToLowerInvariant() -eq $manifest.files[0].sha256) 'release asset hash differs from manifest'
    $state=Join-Path $testRoot 'state'
    $installed=Install-AuPackage -PackageRoot $output -StateRoot $state -AppId AutoUpdate -Architecture x64
    Assert ($installed.Version -eq '0.1.0') 'packaged updater runtime did not install through the common core'
    Assert (Test-Path -LiteralPath (Join-Path $installed.Path 'source\AutoUpdate.Core.psm1')) 'installed runtime module is missing'
    $active=& (Join-Path $PSScriptRoot '..\tools\autoupdate.ps1') -Command status -StateRoot $state -AppId AutoUpdate -Architecture x64 | ConvertFrom-Json
    Assert ($active.Version -eq '0.1.0') 'thin bootstrap did not load the installed common runtime'
    'PASS: release packager emits a versioned manifest and exact hashed assets'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path -Leaf $resolved).StartsWith('AutoUpdate-package-test-')){throw 'refusing unsafe test cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
