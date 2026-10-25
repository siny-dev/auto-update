$ErrorActionPreference='Stop'
$module=Join-Path $PSScriptRoot '..\source\AutoUpdate.Core.psm1'
$cli=Join-Path $PSScriptRoot '..\tools\autoupdate.ps1'
Import-Module $module -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdateCliTest-'+[guid]::NewGuid().ToString('N'))
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Invoke-Cli([string]$App,[string]$Architecture='x64'){
    $exe=(Get-Command pwsh.exe -ErrorAction Stop).Source
    $output=& $exe -NoLogo -NoProfile -NonInteractive -File $cli -Command resolve -StateRoot (Join-Path $root 'state') -AppId $App -Architecture $Architecture 2>$null
    return [pscustomobject]@{ExitCode=$LASTEXITCODE;Result=($output|ConvertFrom-Json)}
}
try{
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'payload'))
    $package=Join-Path $root 'package';[void][IO.Directory]::CreateDirectory((Join-Path $package 'payload'))
    $payload=Join-Path $package 'payload\app.json';[IO.File]::WriteAllText($payload,'{"ready":true}',[Text.UTF8Encoding]::new($false))
    $hash=Get-AuFileSha256 $payload;$size=(Get-Item -LiteralPath $payload).Length
    $manifest=[ordered]@{schema=1;contract='autoupdate-app-v1';app_id='cli-demo';version='1.0.0';mode='live';platform='windows';architecture='x64';minimum_engine='0.1.0';publisher_policy='github-release-asset-https';files=@(@{path='app.json';kind='resource';size=$size;sha256=$hash;source='payload/app.json';asset='app_json'})}
    [IO.File]::WriteAllText((Join-Path $package 'manifest.json'),($manifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $missing=Invoke-Cli 'cli-demo';Assert ($missing.ExitCode -eq 2 -and $missing.Result.status -eq 'not-installed') 'resolve did not report a missing package distinctly'
    Install-AuPackage -PackageRoot $package -StateRoot (Join-Path $root 'state') -AppId 'cli-demo' -Architecture 'x64'|Out-Null
    $resolved=Invoke-Cli 'cli-demo';Assert ($resolved.ExitCode -eq 0 -and $resolved.Result.schema -eq 1 -and $resolved.Result.verified -and $resolved.Result.version -eq '1.0.0') 'resolve JSON contract is invalid'
    Assert (Test-Path -LiteralPath (Join-Path $resolved.Result.package_path 'app.json')) 'resolve package_path does not point at installed payload'
    $wrongArch=Invoke-Cli 'cli-demo' 'x86';Assert ($wrongArch.ExitCode -eq 1) 'resolve accepted a mismatched architecture'
    [IO.File]::WriteAllText((Join-Path $resolved.Result.package_path 'app.json'),'tampered',[Text.UTF8Encoding]::new($false))
    $corrupt=Invoke-Cli 'cli-demo';Assert ($corrupt.ExitCode -eq 1) 'resolve returned a corrupted payload'
    'PASS: language-neutral resolve JSON, distinct not-installed status, architecture check, and corrupted payload rejection'
}finally{Remove-Module AutoUpdate.Core -ErrorAction SilentlyContinue;if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}