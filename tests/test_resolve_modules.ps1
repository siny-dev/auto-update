$ErrorActionPreference='Stop'
$test=Join-Path $PSScriptRoot 'test_resolve_modules.py'
$launcher=Get-Command 'py.exe' -ErrorAction SilentlyContinue
if($launcher){
    $pythonExecutable=$launcher.Source;$pythonArguments=@('-3','-B',$test)
}else{
    $python=Get-Command 'python.exe' -ErrorAction SilentlyContinue
    if(-not $python){throw 'Python is required for AutoUpdate module resolver tests.'}
    $pythonExecutable=$python.Source;$pythonArguments=@('-B',$test)
}
$start=New-Object System.Diagnostics.ProcessStartInfo;$start.FileName=$pythonExecutable
$start.Arguments=(($pythonArguments|ForEach-Object{$value=[string]$_;if($value -match '\s'){'"'+$value.Replace('"','\"')+'"'}else{$value}}) -join ' ')
$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$process=New-Object System.Diagnostics.Process;$process.StartInfo=$start
if(-not $process.Start()){throw 'Could not start Python resolver tests.'}
$stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
$exitCode=$process.ExitCode;$stdout=$stdoutTask.Result;$stderr=$stderrTask.Result;$process.Dispose()
if($stdout){Write-Output $stdout.TrimEnd()};if($stderr){[Console]::Error.WriteLine($stderr.TrimEnd())}
if($exitCode -ne 0){throw "Python resolver tests failed with exit code $exitCode"}
Write-Output 'PASS: AutoUpdate Python module resolver.'
