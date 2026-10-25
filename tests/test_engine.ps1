$ErrorActionPreference='Stop'
$module=Join-Path $PSScriptRoot '..\source\AutoUpdate.Core.psm1'
Import-Module $module -Force
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot=Join-Path $tempRoot ('AutoUpdate-engine-test-'+[guid]::NewGuid().ToString('N'))

function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function New-TestPackage([string]$Version,[string]$Body,[string]$Mode='live',[string]$Kind='resource',[string]$Path='notice.json'){
    $root=Join-Path $testRoot ('pkg-'+$Version+'-'+[guid]::NewGuid().ToString('N'))
    $payload=Join-Path $root 'payload';[void][IO.Directory]::CreateDirectory((Join-Path $payload (Split-Path -Parent $Path)))
    $dataPath=Join-Path $payload $Path;[IO.File]::WriteAllText($dataPath,$Body,[Text.UTF8Encoding]::new($false))
    $hash=Get-AuFileSha256 $dataPath;$size=(Get-Item -LiteralPath $dataPath).Length
    $manifest=[ordered]@{schema=1;contract='autoupdate-app-v1';app_id='demo';version=$Version;mode=$Mode;platform='windows';architecture='x64';minimum_engine='0.1.0';publisher_policy='github-release-asset-https';files=@(@{path=$Path;kind=$Kind;size=$size;sha256=$hash;source=('payload/'+$Path);asset=(Split-Path -Leaf $Path)})}
    [IO.File]::WriteAllText((Join-Path $root 'manifest.json'),($manifest|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    return $root
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $state=Join-Path $testRoot 'state'
    $p1=New-TestPackage '1.0.0' 'v1'
    $r1=Install-AuPackage -PackageRoot $p1 -StateRoot $state -AppId demo -Architecture x64
    Assert ($r1.Status -eq 'staged') 'initial package was not installed'
    Assert ((Get-AuCurrent -StateRoot $state -AppId demo).Version -eq '1.0.0') 'initial current pointer is wrong'

    $p2=New-TestPackage '1.0.1' 'v2'
    [void](Install-AuPackage -PackageRoot $p2 -StateRoot $state -AppId demo -Architecture x64)
    $current=Get-AuCurrent -StateRoot $state -AppId demo
    Assert ($current.Version -eq '1.0.1') 'atomic pointer did not activate latest package'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $state 'apps/demo/previous.json') | ConvertFrom-Json).version -eq '1.0.0') 'previous pointer was not preserved'

    $p3=New-TestPackage '1.0.2' 'bad-hash'
    $m=Get-Content -Raw -LiteralPath (Join-Path $p3 'manifest.json') | ConvertFrom-Json
    $m.files[0].sha256=('0'*64)
    [IO.File]::WriteAllText((Join-Path $p3 'manifest.json'),($m|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    $failed=$false;try{Install-AuPackage -PackageRoot $p3 -StateRoot $state -AppId demo -Architecture x64|Out-Null}catch{$failed=$true}
    Assert $failed 'hash mismatch was accepted'
    Assert ((Get-AuCurrent -StateRoot $state -AppId demo).Version -eq '1.0.1') 'hash failure changed active pointer'

    $p4=New-TestPackage '1.0.2' 'v3'
    $failed=$false;try{Install-AuPackage -PackageRoot $p4 -StateRoot $state -AppId demo -Architecture x64 -FailActivationForTest|Out-Null}catch{$failed=$true}
    Assert $failed 'injected activation failure was ignored'
    Assert ((Get-AuCurrent -StateRoot $state -AppId demo).Version -eq '1.0.1') 'activation rollback changed active pointer'
    Assert (-not (Test-Path -LiteralPath (Join-Path $state 'apps/demo/versions/1.0.2'))) 'failed activation left a partial version'

    $p5=New-TestPackage '1.0.2' 'code' 'live' 'executable' 'app.exe'
    $failed=$false;try{Install-AuPackage -PackageRoot $p5 -StateRoot $state -AppId demo -Architecture x64|Out-Null}catch{$failed=$true}
    Assert $failed 'live executable was accepted'

    $p6=New-TestPackage '1.0.2' 'path' 'restart' 'executable' '../escape.exe'
    $failed=$false;try{Install-AuPackage -PackageRoot $p6 -StateRoot $state -AppId demo -Architecture x64|Out-Null}catch{$failed=$true}
    Assert $failed 'path traversal was accepted'
    'PASS: immutable staging, hash checks, atomic pointer, previous-version retention, and rejection/rollback cases'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path -Leaf $resolved).StartsWith('AutoUpdate-engine-test-')){throw 'refusing unsafe test cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
