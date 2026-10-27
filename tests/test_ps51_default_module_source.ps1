$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$cli=Join-Path $repoRoot 'tools\autoupdate.ps1'
$exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$manifest='\\H255\AI-Work\제작중인 프로그램\AutoSync\examples\app-modules.json'
$moduleSource='\\H255\AI-Work\제작중인 프로그램\AutoUpdate\outbox\modules'
if(-not (Test-Path -LiteralPath $exe -PathType Leaf)){throw 'Windows PowerShell 5.1 executable is missing.'}
if(-not (Test-Path -LiteralPath (Join-Path $moduleSource 'AutoSync\current.json') -PathType Leaf)){throw 'Shared AutoSync module source is unavailable for the integration test.'}
function Quote-ProcessArgument([string]$Value){'"'+$Value.Replace('"','\"')+'"'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdatePs51DefaultSource-'+[guid]::NewGuid().ToString('N'))
$state=Join-Path $root 'state'
$arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$cli,'-Command','resolve-modules','-StateRoot',$state,'-AppManifestPath',$manifest)
$start=New-Object System.Diagnostics.ProcessStartInfo
$start.FileName=$exe
$start.Arguments=(($arguments|ForEach-Object{Quote-ProcessArgument ([string]$_)}) -join ' ')
$start.UseShellExecute=$false
$start.CreateNoWindow=$true
$start.RedirectStandardOutput=$true
$start.RedirectStandardError=$true
$process=New-Object System.Diagnostics.Process
$process.StartInfo=$start
try{
    if(-not $process.Start()){throw 'Could not start Windows PowerShell 5.1.'}
    $stdoutTask=$process.StandardOutput.ReadToEndAsync()
    $stderrTask=$process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout=$stdoutTask.Result
    $stderr=$stderrTask.Result
    if($process.ExitCode -ne 0){throw ('PowerShell 5.1 resolve-modules failed with exit '+$process.ExitCode+': '+$stderr+' '+$stdout)}
    $result=$stdout|ConvertFrom-Json
    if($result.status -cne 'ready' -or @($result.modules).Count -ne 1 -or $result.modules[0].module_id -cne 'AutoSync' -or -not $result.modules[0].verified){throw ('Default UNC module source did not resolve a verified module: '+$stdout)}
    'PASS: Windows PowerShell 5.1 resolved the shared default UNC module source from an empty StateRoot without an explicit ModuleSourceRoot.'
}finally{
    $process.Dispose()
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}