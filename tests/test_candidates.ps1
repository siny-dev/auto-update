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
    $syncedRoot=Join-Path $testRoot 'synced-outbox'
    [void](Save-AuPackageToLocal -PackageRoot $latest.Path -LocalPackageRoot $syncedRoot -Manifest $latest.Manifest -AppId demo -Architecture x64)
    $synced=Get-AuLatestLocalPackage -PackageRoot $syncedRoot -AppId demo -Architecture x64
    Assert ($synced.Manifest.version -eq '1.0.2') 'remote package was not saved into local outbox'
    $syncConflict=$false
    try{$conflictManifest=New-Package (Join-Path $testRoot 'sync-conflict') '1.0.2' 'different-content';Save-AuPackageToLocal -PackageRoot (Join-Path $testRoot 'sync-conflict') -LocalPackageRoot $syncedRoot -Manifest $conflictManifest -AppId demo -Architecture x64|Out-Null}catch{$syncConflict=$true}
    Assert $syncConflict 'same-version local outbox content conflict was overwritten'
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
    $module=Get-Module AutoUpdate.Core|Select-Object -Last 1
    $remoteLookup=& $module {(Get-Item Function:\Get-AuLatestReleaseManifest).ScriptBlock}
    & $module {Set-Item Function:\Get-AuLatestReleaseManifest -Value {throw 'Missing Windows credential target AutoUpdate/github.'}}
    try{
        $offlineState=Join-Path $testRoot 'offline-state'
        $offline=Install-AuLatestAvailable -Owner siny-dev -Repository auto-update -AppId demo -StateRoot $offlineState -Architecture x64 -LocalPackageRoot $localRoot
        Assert ($offline.Status -eq 'staged' -and $offline.Version -eq '1.0.2') 'verified local package was not installed when GitHub was unavailable'
        Assert ($offline.Message -match 'GitHub could not be checked' -and $offline.Message -match 'next cycle') 'offline local install did not report that GitHub will be retried'
        $newerState=Join-Path $testRoot 'newer-state'
        Install-AuPackage -PackageRoot (Join-Path $testRoot 'remote-newer') -StateRoot $newerState -AppId demo -Architecture x64|Out-Null
        $noDowngrade=Install-AuLatestAvailable -Owner siny-dev -Repository auto-update -AppId demo -StateRoot $newerState -Architecture x64 -LocalPackageRoot $localRoot
        Assert ($noDowngrade.Status -eq 'already-current' -and $noDowngrade.Version -eq '1.0.3') 'offline local fallback downgraded a newer installed version'
        $conflictState=Join-Path $testRoot 'offline-conflict-state'
        Install-AuPackage -PackageRoot (Join-Path $testRoot 'conflicting') -StateRoot $conflictState -AppId demo -Architecture x64|Out-Null
        $offlineConflict=Install-AuLatestAvailable -Owner siny-dev -Repository auto-update -AppId demo -StateRoot $conflictState -Architecture x64 -LocalPackageRoot $localRoot
        Assert ($offlineConflict.Status -eq 'conflict') 'offline local fallback overwrote different contents with the same version'
        'PASS: verified local update during GitHub outage, retry visibility, no downgrade, and same-version conflict preservation'
    }finally{
        & $module {param($lookup) Set-Item Function:\Get-AuLatestReleaseManifest -Value $lookup} $remoteLookup
    }
    'PASS: highest local version, GitHub/local winner, same-hash equality, same-version conflict, and local staging'
    $module=Get-Module AutoUpdate.Core | Select-Object -Last 1
    $legacyRelease=[pscustomobject]@{assets=@([pscustomobject]@{name='workboard.exe';size=123})}
    $legacyAsset=& $module {param($release) Get-AuReleaseManifestAsset -Release $release} $legacyRelease
    Assert ($null -eq $legacyAsset) 'legacy GitHub release without a common manifest was not recognized'
    $validRelease=[pscustomobject]@{assets=@([pscustomobject]@{name='autoupdate-manifest.json';size=64})}
    Assert ((& $module {param($release) Get-AuReleaseManifestAsset -Release $release} $validRelease).name -eq 'autoupdate-manifest.json') 'valid common manifest asset was rejected'
    $duplicateRelease=[pscustomobject]@{assets=@([pscustomobject]@{name='autoupdate-manifest.json';size=64},[pscustomobject]@{name='autoupdate-manifest.json';size=64})}
    $assetFailed=$false;try{& $module {param($release) Get-AuReleaseManifestAsset -Release $release} $duplicateRelease|Out-Null}catch{$assetFailed=$true}
    Assert $assetFailed 'duplicate common manifest assets were accepted'
    Assert ((& $module {param($local,$remote) Select-AuPackageWinner -LocalManifest $local -RemoteManifest $remote} $m2 $null) -eq 'local') 'verified local package did not win when GitHub has no AutoUpdate manifest'
    Assert ((& $module {param($local,$remote) Select-AuPackageWinner -LocalManifest $local -RemoteManifest $remote} $null $m2) -eq 'github') 'GitHub package was not selected when no local package exists'
    'PASS: legacy manifest detection, verified candidate selection, and malformed manifest rejection'
}finally{
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path -Leaf $resolved).StartsWith('AutoUpdate-candidate-test-')){throw 'refusing unsafe test cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
