$ErrorActionPreference='Stop'
$module=Join-Path $PSScriptRoot '..\source\AutoUpdate.Core.psm1'
$cli=Join-Path $PSScriptRoot '..\tools\autoupdate.ps1'
Import-Module $module -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdateCliTest-'+[guid]::NewGuid().ToString('N'))
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
Assert (Test-AuReleaseTagVersion -Tag 'V1.0.010' -Version '1.0.10') 'Zero-padded uppercase application release tag was not matched semantically'
Assert (Test-AuReleaseTagVersion -Tag 'v0.1.1304' -Version '0.1.1304') 'Standard AutoUpdate release tag was rejected'
Assert (-not (Test-AuReleaseTagVersion -Tag 'V1.0.011' -Version '1.0.10')) 'Mismatched release tag was accepted'
Assert (-not (Test-AuReleaseTagVersion -Tag 'release-1.0.10' -Version '1.0.10')) 'Non-semantic release tag was accepted'
function Quote-ProcessArgument([string]$Value){'"'+$Value.Replace('"','\"')+'"'}
function Invoke-PowerShellProcess([string]$Executable,[string[]]$Arguments){
    $start=New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName=$Executable
    $start.Arguments=(($Arguments|ForEach-Object{Quote-ProcessArgument ([string]$_)}) -join ' ')
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=New-Object System.Diagnostics.Process;$process.StartInfo=$start
    if(-not $process.Start()){throw 'Could not start the PowerShell test process.'}
    $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
    $process.WaitForExit();$exitCode=$process.ExitCode
    $stdout=$stdoutTask.Result;$stderr=$stderrTask.Result;$process.Dispose()
    return [pscustomobject]@{ExitCode=$exitCode;StdOut=$stdout;StdErr=$stderr}
}
$script:PowerShellExecutable=$null
foreach($candidate in @('powershell.exe','pwsh.exe')){
    $command=Get-Command $candidate -ErrorAction SilentlyContinue|Select-Object -First 1
    if(-not $command){continue}
    $probeStart=New-Object System.Diagnostics.ProcessStartInfo
    $probeStart.FileName=$command.Source
    $probeStart.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "exit 0"'
    $probeStart.UseShellExecute=$false;$probeStart.CreateNoWindow=$true
    $probeProcess=New-Object System.Diagnostics.Process;$probeProcess.StartInfo=$probeStart
    if(-not $probeProcess.Start()){continue}
    $probeUsable=$probeProcess.WaitForExit(5000) -and $probeProcess.ExitCode -eq 0
    if(-not $probeProcess.HasExited){$probeProcess.Kill();$probeProcess.WaitForExit()}
    $probeProcess.Dispose()
    if($probeUsable){$script:PowerShellExecutable=$command.Source;break}
}
if(-not $script:PowerShellExecutable){throw 'No usable PowerShell executable is available for the CLI subprocess test.'}
function Invoke-Cli([string]$App,[string]$Architecture='x64'){
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$cli,'-Command','resolve','-StateRoot',(Join-Path $root 'state'),'-AppId',$App,'-Architecture',$Architecture)
    $run=Invoke-PowerShellProcess $script:PowerShellExecutable $arguments
    return [pscustomobject]@{ExitCode=$run.ExitCode;Result=($run.StdOut|ConvertFrom-Json);Error=$run.StdErr}
}
try{
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'payload'))
    $package=Join-Path $root 'package';[void][IO.Directory]::CreateDirectory((Join-Path $package 'payload'))
    $payload=Join-Path $package 'payload\app.json';[IO.File]::WriteAllText($payload,'{"ready":true}',[Text.UTF8Encoding]::new($false))
    $hash=Get-AuFileSha256 $payload;$size=(Get-Item -LiteralPath $payload).Length
    $manifest=[ordered]@{schema=1;contract='autoupdate-app-v1';app_id='cli-demo';version='1.0.0';mode='live';platform='windows';architecture='x86';minimum_engine='0.1.0';publisher_policy='github-release-asset-https';files=@(@{path='app.json';kind='resource';size=$size;sha256=$hash;source='payload/app.json';asset='app_json'})}
    [IO.File]::WriteAllText((Join-Path $package 'manifest.json'),($manifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $missing=Invoke-Cli 'cli-demo';Assert ($missing.ExitCode -eq 2 -and $missing.Result.status -eq 'not-installed') 'resolve did not report a missing package distinctly'
    $state=Join-Path $root 'state'
    $registerArgs=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$cli,'-Command','register','-StateRoot',$state,'-AppId','cli-demo','-Owner','example-owner','-Repository','example-repo','-Architecture','x64')
    $registeredRun=Invoke-PowerShellProcess $script:PowerShellExecutable $registerArgs
    $registered=$registeredRun.StdOut|ConvertFrom-Json
    Assert ($registeredRun.ExitCode -eq 0 -and $registered.Status -eq 'registered') 'CLI registration did not report success'
    $registry=Get-AuRegisteredApps -StateRoot $state
    Assert (@($registry|Where-Object{$_.app_id -eq 'cli-demo' -and $_.owner -eq 'example-owner' -and $_.repository -eq 'example-repo'}).Count -eq 1) 'CLI registration was not persisted'
    Install-AuPackage -PackageRoot $package -StateRoot (Join-Path $root 'state') -AppId 'cli-demo' -Architecture 'x86'|Out-Null
    $resolved=Invoke-Cli 'cli-demo' 'x86';Assert ($resolved.ExitCode -eq 0 -and $resolved.Result.schema -eq 1 -and $resolved.Result.verified -and $resolved.Result.version -eq '1.0.0') 'resolve JSON contract is invalid for x86'
    Assert (Test-Path -LiteralPath (Join-Path $resolved.Result.package_path 'app.json')) 'resolve package_path does not point at installed payload'
    $wrongArch=Invoke-Cli 'cli-demo' 'x64';Assert ($wrongArch.ExitCode -eq 1) 'resolve accepted a mismatched architecture'
    [IO.File]::WriteAllText((Join-Path $resolved.Result.package_path 'app.json'),'tampered',[Text.UTF8Encoding]::new($false))
    $corrupt=Invoke-Cli 'cli-demo' 'x86';Assert ($corrupt.ExitCode -eq 1) 'resolve returned a corrupted payload'
    'PASS: registration and language-neutral resolve JSON, distinct not-installed status, architecture check, and corrupted payload rejection'
}finally{Remove-Module AutoUpdate.Core -ErrorAction SilentlyContinue;if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
