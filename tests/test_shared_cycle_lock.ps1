$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$helperPath=Join-Path $repoRoot 'tools\shared-cycle-lock.ps1'
$lockPath=Join-Path $repoRoot ('outbox\locks\test-'+[guid]::NewGuid().ToString('N')+'.lock')
$childPath=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-lock-child-'+[guid]::NewGuid().ToString('N')+'.ps1')
$shell=(Get-Process -Id $PID).Path
if(-not $shell -or (Split-Path -Leaf $shell) -notin @('powershell.exe','pwsh.exe')){throw 'Could not identify the current PowerShell executable.'}
function Quote-ProcessArg([string]$Value){'"'+$Value.Replace('"','\"')+'"'}
function Invoke-LockChild([switch]$ExpectAvailable){
    $arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '+(Quote-ProcessArg $childPath)+' -HelperPath '+(Quote-ProcessArg $helperPath)+' -LockPath '+(Quote-ProcessArg $lockPath)
    if($ExpectAvailable){$arguments+=' -ExpectAvailable'}
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$shell;$start.Arguments=$arguments;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    if(-not $process.Start()){throw 'Could not start child lock-test process.'}
    $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
    if(-not $process.WaitForExit(15000)){$process.Kill();throw 'Child lock-test process timed out.'}
    $output=$stdoutTask.Result.Trim();$errorOutput=$stderrTask.Result.Trim();$exitCode=$process.ExitCode;$process.Dispose()
    if($exitCode -ne 0){throw ('Child lock-test failed: '+$output+' '+$errorOutput)}
    return $output
}
$lockHandle=$null
try{
    . $helperPath
    $childSource=@'
param([string]$HelperPath,[string]$LockPath,[switch]$ExpectAvailable)
$ErrorActionPreference='Stop'
. $HelperPath
$handle=Enter-AuSharedCycleLock -Path $LockPath -TimeoutMilliseconds 1200
if($ExpectAvailable){
    if($null -eq $handle){Write-Output 'LOCK_UNEXPECTED_BLOCK';exit 4}
    Exit-AuSharedCycleLock -LockHandle $handle
    Write-Output 'LOCK_ACQUIRED'
    exit 0
}
if($null -ne $handle){Exit-AuSharedCycleLock -LockHandle $handle;Write-Output 'LOCK_UNEXPECTED_ACQUIRED';exit 5}
Write-Output 'LOCK_BLOCKED'
exit 0
'@
    [IO.File]::WriteAllText($childPath,$childSource,[Text.UTF8Encoding]::new($false))
    $lockHandle=Enter-AuSharedCycleLock -Path $lockPath -TimeoutMilliseconds 0
    if($null -eq $lockHandle){throw 'Could not acquire the initially free shared lock.'}
    $blocked=Invoke-LockChild
    if($blocked -ne 'LOCK_BLOCKED'){throw 'A second process acquired a lock already held by the first process.'}
    Exit-AuSharedCycleLock -LockHandle $lockHandle;$lockHandle=$null
    $available=Invoke-LockChild -ExpectAvailable
    if($available -ne 'LOCK_ACQUIRED'){throw 'A new cycle could not acquire the lock after the previous cycle released it.'}
    Write-Output 'PASS: the shared-cycle lock excludes a second process and releases cleanly.'
}finally{
    if($lockHandle){Exit-AuSharedCycleLock -LockHandle $lockHandle}
    if(Test-Path -LiteralPath $childPath){Remove-Item -LiteralPath $childPath -Force -ErrorAction SilentlyContinue}
    if(Test-Path -LiteralPath $lockPath){Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue}
}