$ErrorActionPreference='Stop'
$python=(Get-Command python.exe -ErrorAction Stop).Source
$pythonTest=Join-Path $PSScriptRoot 'test_shared_app.py'
$start=New-Object System.Diagnostics.ProcessStartInfo;$start.FileName=$python
$start.Arguments='"'+$pythonTest.Replace('"','\"')+'"'
$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$process=New-Object System.Diagnostics.Process;$process.StartInfo=$start
if(-not $process.Start()){throw 'Could not start shared app runner tests.'}
$stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
$exitCode=$process.ExitCode;$stdout=$stdoutTask.Result;$stderr=$stderrTask.Result;$process.Dispose()
if($stdout){Write-Output $stdout.TrimEnd()};if($stderr){[Console]::Error.WriteLine($stderr.TrimEnd())}
if($exitCode -ne 0){throw "Shared app runner tests failed with exit code $exitCode."}
Write-Output 'PASS: shared app runner.'
