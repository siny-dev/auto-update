$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\source\AutoUpdate.Core.psm1') -Force
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot=Join-Path $tempRoot ('AutoUpdate-candidate-test-'+[guid]::NewGuid().ToString('N'))
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function New-Package([string]$Root,[string]$Version,[string]$Body){
    $payload=Join-Path $Root 'payload';[void][IO.Directory]::CreateDirectory($payload)
    $file=Join-Path $payload 'notice.json';[IO.File]::WriteAllText($file,$Body,[Text.UTF8Encoding]::new($false))
    $entry=[ordered]@{path='notice.json';kind='resource';size=(Get-Item -LiteralPath $file).Length;sha256=(Get-AuFileSha256 $file);source='payload/notice.json';asset='notice'}
    $manifest=[ordered]@{schema=1;contract='autoupdate-app-v1';app_id='demo';version=$Version;mode='live';platform='windows';architecture='any';minimum_engine='0.1.0';publisher_policy='github-release-asset-https';files=@($entry)}
    $json=$manifest|ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText((Join-Path $Root 'manifest.json'),$json,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'autoupdate-manifest.json'),$json,[Text.UTF8Encoding]::new($false))
    return Get-Content -Raw -LiteralPath (Join-Path $Root 'manifest.json')|ConvertFrom-Json
}
try{
    [void][IO.Directory]::CreateDirectory($testRoot)
    $localRoot=Join-Path $testRoot 'outbox/apps/demo'
    $v1=Join-Path $localRoot '1.0.0';[void][IO.Directory]::CreateDirectory($v1);$m1=New-Package $v1 '1.0.0' 'local-1'
    $v2=Join-Path $localRoot '1.0.2';[void][IO.Directory]::CreateDirectory($v2);$m2=New-Package $v2 '1.0.2' 'local-2'
    $corrupt=Join-Path $localRoot '1.0.9';[void][IO.Directory]::CreateDirectory($corrupt);[void](New-Package $corrupt '1.0.9' 'expected-content')
    [IO.File]::WriteAllText((Join-Path $corrupt 'payload\notice.json'),'tampered-after-manifest',[Text.UTF8Encoding]::new($false))
    $latest=Get-AuLatestLocalPackage -PackageRoot $localRoot -AppId demo -Architecture x64
    Assert ($latest.Manifest.version -eq '1.0.2') 'local discovery did not ignore a higher but corrupted package'
    $remoteOlder=New-Package (Join-Path $testRoot 'remote-older') '1.0.1' 'github-1'
    Assert ((Compare-AuPackageCandidates $latest.Manifest $remoteOlder) -eq 'local') 'newer local package did not win'
    $remoteNewer=New-Package (Join-Path $testRoot 'remote-newer') '1.0.3' 'github-2'
    Assert ((Compare-AuPackageCandidates $latest.Manifest $remoteNewer) -eq 'github') 'newer GitHub package did not win'
    $same=New-Package (Join-Path $testRoot 'same') '1.0.2' 'local-2'
    Assert ((Compare-AuPackageCandidates $latest.Manifest $same) -eq 'same') 'identical same-version packages were not recognized'
    $conflicting=New-Package (Join-Path $testRoot 'conflicting') '1.0.2' 'other-content'
    Assert ((Compare-AuPackageCandidates $latest.Manifest $conflicting) -eq 'conflict') 'same-version different-content conflict was not detected'
    $installed=Install-AuPackage -PackageRoot $latest.Path -StateRoot (Join-Path $testRoot 'state') -AppId demo -Architecture x64
    Assert ($installed.Version -eq '1.0.2' -and $installed.Status -eq 'staged') 'selected local latest package did not install'
    $sameContent=Install-AuPackage -PackageRoot (Join-Path $localRoot '1.0.2') -StateRoot (Join-Path $testRoot 'state') -AppId demo -Architecture x64
    Assert ($sameContent.Status -eq 'already-current') 'same-version identical installed package was not recognized'
    $sameVersionConflict=Install-AuPackage -PackageRoot (Join-Path $testRoot 'conflicting') -StateRoot (Join-Path $testRoot 'state') -AppId demo -Architecture x64
    Assert ($sameVersionConflict.Status -eq 'conflict') 'same-version changed installed package was silently accepted'
    'PASS: highest local version, GitHub/local winner, same-hash equality, same-version conflict, and local staging'
}finally{
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path -Leaf $resolved).StartsWith('AutoUpdate-candidate-test-')){throw 'refusing unsafe test cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
