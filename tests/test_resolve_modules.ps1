$ErrorActionPreference='Stop'
$test=Join-Path $PSScriptRoot 'test_resolve_modules.py'
$launcher=Get-Command 'py.exe' -ErrorAction SilentlyContinue
if($launcher){
    & $launcher.Source -3 -B $test
}else{
    $python=Get-Command 'python.exe' -ErrorAction SilentlyContinue
    if(-not $python){throw 'Python is required for AutoUpdate module resolver tests.'}
    & $python.Source -B $test
}
if($LASTEXITCODE -ne 0){throw "Python resolver tests failed with exit code $LASTEXITCODE"}
Write-Output 'PASS: AutoUpdate Python module resolver.'