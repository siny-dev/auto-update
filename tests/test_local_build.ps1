$ErrorActionPreference='Stop'
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot=Join-Path $tempRoot ('AutoUpdate-local-build-test-'+[guid]::NewGuid().ToString('N'))
$recipePath=Join-Path $testRoot 'build.json';$payloadRoot=Join-Path $testRoot 'payload';$packageRoot=Join-Path $testRoot 'outbox'
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Invoke-Build([string]$RemoteVersion){$args=@('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot '..\tools\build-local-package.ps1'),'-RecipePath',$recipePath,'-PackageRoot',$packageRoot);if($RemoteVersion){$args+=@('-RemoteVersion',$RemoteVersion)};$output=& (Get-Command pwsh.exe -ErrorAction Stop).Source @args;if($LASTEXITCODE -ne 0){throw "Build script failed: $output"};return ($output|ConvertFrom-Json)}
try{
    [void][IO.Directory]::CreateDirectory((Join-Path $payloadRoot 'resources'))
    [IO.File]::WriteAllText((Join-Path $payloadRoot 'resources\notice.json'),'first',[Text.UTF8Encoding]::new($false))
    $recipe=[ordered]@{app_id='demo-build';version_seed='1.2.3';platform='windows';architecture='any';minimum_engine='0.1.0';mode='live';payload_root='payload';files=@(@{path='resources/notice.json';kind='resource'})}
    [IO.File]::WriteAllText($recipePath,($recipe|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $first=Invoke-Build $null;Assert ($first.status -eq 'built' -and $first.version -eq '1.2.3') 'first local build did not use its seed version'
    $same=Invoke-Build $null;Assert ($same.status -eq 'unchanged' -and $same.version -eq '1.2.3') 'unchanged source produced another package'
    [IO.File]::WriteAllText((Join-Path $payloadRoot 'resources\notice.json'),'second',[Text.UTF8Encoding]::new($false))
    $next=Invoke-Build $null;Assert ($next.status -eq 'built' -and $next.version -eq '1.2.4') 'changed source did not increment the package version'
    [IO.File]::WriteAllText((Join-Path $payloadRoot 'resources\notice.json'),'third',[Text.UTF8Encoding]::new($false))
    $remote=Invoke-Build '2.0.0';Assert ($remote.status -eq 'built' -and $remote.version -eq '2.0.1') 'local build did not advance beyond a newer GitHub version'
    Import-Module (Join-Path $PSScriptRoot '..\source\AutoUpdate.Core.psm1') -Force
    $latest=Get-AuLatestLocalPackage -PackageRoot $packageRoot -AppId demo-build -Architecture x64
    Assert ($latest.Manifest.version -eq '2.0.1') 'latest generated package is not visible to the updater candidate scanner'
    Remove-Item -LiteralPath (Join-Path $packageRoot '2.0.1') -Recurse -Force
    $recovered=Invoke-Build '2.0.0';Assert ($recovered.status -eq 'built' -and $recovered.version -eq '2.0.2') 'missing last package was incorrectly treated as unchanged'
    'PASS: recipe builds first package, skips unchanged source, increments changed content, advances past remote version, and rebuilds after package loss'
}finally{
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path -Leaf $resolved).StartsWith('AutoUpdate-local-build-test-')){throw 'refusing unsafe test cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
