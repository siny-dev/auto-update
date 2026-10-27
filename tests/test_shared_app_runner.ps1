$ErrorActionPreference='Stop'
$python=(Get-Command python.exe -ErrorAction Stop).Source
$pythonTest=Join-Path $PSScriptRoot 'test_shared_app.py'
& $python $pythonTest
if($LASTEXITCODE -ne 0){throw "Shared app runner tests failed with exit code $LASTEXITCODE."}