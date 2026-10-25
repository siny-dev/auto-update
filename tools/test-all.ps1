$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$tests=@(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tests') -Filter 'test_*.ps1' -File|Sort-Object Name)
if($tests.Count -eq 0){throw 'No AutoUpdate test scripts were found.'}
$shell=(Get-Process -Id $PID).Path
if(-not $shell -or (Split-Path -Leaf $shell) -notin @('powershell.exe','pwsh.exe')){throw 'Could not identify the current PowerShell executable.'}
$failures=[Collections.Generic.List[string]]::new()
foreach($test in $tests){
    Write-Output ('RUN '+$test.Name)
    try{
        & $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $test.FullName
        $testExitCode=$LASTEXITCODE
        if($testExitCode -ne 0){throw "exit code $testExitCode"}
        Write-Output ('PASS '+$test.Name)
    }catch{
        $failures.Add($test.Name+': '+$_.Exception.Message)
        Write-Output ('FAIL '+$test.Name+': '+$_.Exception.Message)
    }
}
if($failures.Count -gt 0){
    Write-Output ('FAILED '+$failures.Count+' test(s)')
    $failures|ForEach-Object{Write-Output $_}
    exit 1
}
Write-Output ('ALL '+$tests.Count+' AUTUPDATE TESTS PASSED')
