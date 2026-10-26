$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$module=Join-Path $repoRoot 'source\AutoUpdate.Core.psm1'
$cli=Join-Path $repoRoot 'tools\autoupdate.ps1'
$engineBuilder=Join-Path $repoRoot 'tools\build-engine-release.ps1'
$moduleBuilder=Join-Path $repoRoot 'tools\build-module-package.ps1'
Import-Module $module -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdateRuntimeVersionTest-'+[guid]::NewGuid().ToString('N'))
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Quote-ProcessArgument([string]$Value){'"'+$Value.Replace('"','\"')+'"'}
function Invoke-PowerShellProcess([string]$Executable,[string[]]$Arguments){
    $start=New-Object System.Diagnostics.ProcessStartInfo;$start.FileName=$Executable
    $start.Arguments=(($Arguments|ForEach-Object{Quote-ProcessArgument ([string]$_)}) -join ' ')
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=New-Object System.Diagnostics.Process;$process.StartInfo=$start
    if(-not $process.Start()){throw 'Could not start the isolated AutoUpdate CLI process.'}
    $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
    $result=[pscustomobject]@{ExitCode=$process.ExitCode;StdOut=$stdoutTask.Result;StdErr=$stderrTask.Result};$process.Dispose();return $result
}
try{
    $state=Join-Path $root 'state';$enginePackage=Join-Path $root 'engine-package';$moduleSource=Join-Path $root 'module-source';$modulePackage=Join-Path $root 'module-package';$appPackage=Join-Path $root 'app-package'
    [void][IO.Directory]::CreateDirectory($root)
    & $engineBuilder -Version '0.1.1809' -OutputRoot $enginePackage|Out-Null
    $engineInstall=Install-AuPackage -PackageRoot $enginePackage -StateRoot $state -AppId 'AutoUpdate' -Architecture 'x64'
    Assert ($engineInstall.Status -eq 'staged' -and $engineInstall.Version -eq '0.1.1809') 'Could not create an isolated installed engine fixture.'
    $sourceFolder=Join-Path $moduleSource 'source';[void][IO.Directory]::CreateDirectory($sourceFolder)
    [IO.File]::Copy($module,(Join-Path $sourceFolder 'AutoUpdate.Core.psm1'),$false)
    & $moduleBuilder -ModuleId 'AutoUpdate' -Version '1.0.6' -ApiMajor 1 -SourceRoot $moduleSource -OutputRoot $modulePackage -ActivationMode restart|Out-Null
    $moduleInstall=Install-AuModulePackage -PackageRoot $modulePackage -StateRoot $state -ModuleId 'AutoUpdate'
    Assert ($moduleInstall.Status -in @('activated','already-cached','activated-cached')) 'Could not create the isolated cached AutoUpdate module fixture.'

    $payload=Join-Path $appPackage 'payload';[void][IO.Directory]::CreateDirectory($payload)
    $payloadFile=Join-Path $payload 'app.json';[IO.File]::WriteAllText($payloadFile,'{"ready":true}',[Text.UTF8Encoding]::new($false))
    $manifest=[ordered]@{schema=1;contract='autoupdate-app-v1';app_id='engine-gated-app';version='1.0.0';mode='live';platform='windows';architecture='any';minimum_engine='0.1.1503';publisher_policy='github-release-asset-https';files=@(@{path='app.json';kind='resource';size=(Get-Item -LiteralPath $payloadFile).Length;sha256=(Get-AuFileSha256 $payloadFile);source='payload/app.json';asset='app_json'})}
    [IO.File]::WriteAllText((Join-Path $appPackage 'manifest.json'),($manifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $appInstall=Install-AuPackage -PackageRoot $appPackage -StateRoot $state -AppId 'engine-gated-app' -Architecture 'x64'
    Assert ($appInstall.Status -eq 'staged') 'The active engine version was not resolved while installing an app with a higher minimum_engine.'

    $pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
    $args=@('-NoLogo','-NoProfile','-NonInteractive','-File',$cli,'-Command','status','-StateRoot',$state,'-AppId','engine-gated-app','-Architecture','x64')
    $run=Invoke-PowerShellProcess $pwsh $args
    if($run.ExitCode -ne 0){throw "CLI status failed with exit $($run.ExitCode): $($run.StdErr) $($run.StdOut)"}
    $status=$run.StdOut|ConvertFrom-Json
    Assert ($status.Verified -and $status.Version -eq '1.0.0') 'The cached AutoUpdate module treated its fallback 0.1.0 as the active engine and rejected a valid installed app.'
    'PASS: cached AutoUpdate module resolves the verified installed engine version and accepts compatible app packages.'
}finally{
    Remove-Module AutoUpdate.Core -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($root);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -match '^AutoUpdateRuntimeVersionTest-[a-f0-9]{32}$' -and (Test-Path -LiteralPath $resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}