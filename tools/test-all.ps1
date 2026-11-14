$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$tests=@(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tests') -Filter 'test_*.ps1' -File|Sort-Object Name)
if($tests.Count -eq 0){throw 'No AutoUpdate test scripts were found.'}
$shell=(Get-Process -Id $PID).Path
if(-not $shell -or (Split-Path -Leaf $shell) -notin @('powershell.exe','pwsh.exe')){throw 'Could not identify the current PowerShell executable.'}
$failures=[Collections.Generic.List[string]]::new()
foreach($test in $tests){
    Write-Output ('RUN '+$test.Name)
    $stdoutPath=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-test-'+[guid]::NewGuid().ToString('N')+'.stdout')
    $stderrPath=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-test-'+[guid]::NewGuid().ToString('N')+'.stderr')
    try{
        $arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$test.FullName.Replace('"','\"')+'"'
        $child=Start-Process -FilePath $shell -ArgumentList $arguments -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $testExitCode=$child.ExitCode
        if(Test-Path -LiteralPath $stdoutPath){Get-Content -LiteralPath $stdoutPath}
        if(Test-Path -LiteralPath $stderrPath){Get-Content -LiteralPath $stderrPath|ForEach-Object{[Console]::Error.WriteLine($_)}}
        if($testExitCode -ne 0){throw "exit code $testExitCode"}
        Write-Output ('PASS '+$test.Name)
    }catch{
        $failures.Add($test.Name+': '+$_.Exception.Message)
        Write-Output ('FAIL '+$test.Name+': '+$_.Exception.Message)
    }finally{
        Remove-Item -LiteralPath $stdoutPath,$stderrPath -Force -ErrorAction SilentlyContinue
    }
}
$pythonTestCount=0
$pythonTest=Join-Path $repoRoot 'tests\test_local_module_sync.py'
if(Test-Path -LiteralPath $pythonTest -PathType Leaf){
    $stdoutPath=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-test-'+[guid]::NewGuid().ToString('N')+'.stdout')
    $stderrPath=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-test-'+[guid]::NewGuid().ToString('N')+'.stderr')
    try{
        $python=(Get-Command python.exe -ErrorAction Stop|Select-Object -First 1).Source
        Write-Output 'RUN test_local_module_sync.py'
        $arguments='-B "'+$pythonTest.Replace('"','\"')+'"'
        $child=Start-Process -FilePath $python -ArgumentList $arguments -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $testExitCode=$child.ExitCode
        if(Test-Path -LiteralPath $stdoutPath){Get-Content -LiteralPath $stdoutPath}
        if(Test-Path -LiteralPath $stderrPath){Get-Content -LiteralPath $stderrPath|ForEach-Object{[Console]::Error.WriteLine($_)}}
        if($testExitCode -ne 0){throw "exit code $testExitCode"}
        $pythonTestCount=1
        Write-Output 'PASS test_local_module_sync.py'
    }catch{
        $failures.Add('test_local_module_sync.py: '+$_.Exception.Message)
        Write-Output ('FAIL test_local_module_sync.py: '+$_.Exception.Message)
    }finally{
        Remove-Item -LiteralPath $stdoutPath,$stderrPath -Force -ErrorAction SilentlyContinue
    }
}
if($failures.Count -gt 0){
    Write-Output ('FAILED '+$failures.Count+' test(s)')
    $failures|ForEach-Object{Write-Output $_}
    exit 1
}
Write-Output ('ALL '+($tests.Count+$pythonTestCount)+' AUTOUPDATE TESTS PASSED')
