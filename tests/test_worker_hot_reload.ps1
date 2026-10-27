$ErrorActionPreference='Stop'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('au-worker-hot-reload-'+[guid]::NewGuid().ToString('N'))
$tools=Join-Path $temp 'tools';$source=Join-Path $temp 'source';$state=Join-Path $temp 'state'
$trace=Join-Path $temp 'module-trace.txt';$newModulePath=Join-Path $temp 'new-engine.psm1'
[void][IO.Directory]::CreateDirectory($tools);[void][IO.Directory]::CreateDirectory($source)
[void][IO.Directory]::CreateDirectory((Join-Path $state 'apps\AutoUpdate\versions\0.1.1\source'))
[void][IO.Directory]::CreateDirectory((Join-Path $state 'logs'))
$worker=Join-Path $tools 'update-registered-apps.ps1'
$workerSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\tools\update-registered-apps.ps1'))
$policyReader=Join-Path $PSScriptRoot '..\tools\read-update-policy.ps1'
Copy-Item -LiteralPath $policyReader -Destination (Join-Path $tools 'read-update-policy.ps1')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\tools\shared-cycle-lock.ps1') -Destination (Join-Path $tools 'shared-cycle-lock.ps1')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\tools\guard-local-package-version.ps1') -Destination (Join-Path $tools 'guard-local-package-version.ps1')
$workerSource=$workerSource.Replace('Local\AutoUpdateRegisteredAppsWorker','Local\AuWorkerHotReloadTestWorker').Replace('Local\AutoUpdateRegisteredApps','Local\AuWorkerHotReloadTestCycle')
[IO.File]::WriteAllText($worker,$workerSource,[Text.UTF8Encoding]::new($false))
$moduleTemplate=@'
$script:EngineLabel='@@LABEL@@'
function Get-AuRegisteredApps { param([string]$StateRoot) @([pscustomobject]@{app_id='TEST-APP';owner='sample';repository='app';architecture='x86'},[pscustomobject]@{app_id='2-APP';owner='sample';repository='second-app';architecture='x64'},[pscustomobject]@{app_id='AutoUpdate';owner='sample';repository='engine';architecture='any'}) }
function Register-AuApplication { param($StateRoot,$AppId,$Owner,$Repository,$Architecture); [pscustomobject]@{Status='registered'} }
function Get-AuLatestLocalPackage { param($PackageRoot,$AppId,$Architecture); $null }
function Get-AuLatestReleaseManifest { param($Owner,$Repository,$AppId,$Architecture); $null }
function Publish-AuLocalPackage { param($Owner,$Repository,$AppId,$PackageRoot,$Architecture); $null }
function Get-AuReleaseUploadPlan { param($PackageRoot,$Architecture); $null }
function Save-AuPackageToLocal { param($Owner,$Repository,$AppId,$StateRoot,$Architecture); $null }
function Get-AuVerifiedCurrent { param($StateRoot,$AppId,$Architecture); $null }
function Install-AuLatestAvailable {
    param($Owner,$Repository,$AppId,$StateRoot,$Architecture,$LocalPackageRoot)
    if($AppId -ceq 'AutoUpdate' -and $script:EngineLabel -eq 'old'){
        $versionRoot=Join-Path $StateRoot 'apps\AutoUpdate\versions\0.1.2'
        $source=Join-Path $versionRoot 'source';[void][IO.Directory]::CreateDirectory($source)
        $destination=Join-Path $source 'AutoUpdate.Core.psm1'
        Copy-Item -LiteralPath $env:AU_WORKER_TEST_NEW_MODULE -Destination $destination
        $sha=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest=@{files=@(@{kind='runtime';path='source/AutoUpdate.Core.psm1';sha256=$sha})}
        [IO.File]::WriteAllText((Join-Path $versionRoot 'manifest.json'),($manifest|ConvertTo-Json -Depth 6))
        [IO.File]::WriteAllText((Join-Path $StateRoot 'apps\AutoUpdate\current.json'),('{"schema":1,"app_id":"AutoUpdate","version":"0.1.2"}'))
    }
    if($env:AU_WORKER_TEST_DELAY_MS){Start-Sleep -Milliseconds ([int]$env:AU_WORKER_TEST_DELAY_MS)}
    [IO.File]::AppendAllText($env:AU_WORKER_TEST_TRACE,($script:EngineLabel+':'+$AppId+[char]10))
    [pscustomobject]@{Status='already-current';Version='1.0.0';Message='test'}
}
Export-ModuleMember -Function Register-AuApplication,Install-AuLatestAvailable,Get-AuLatestLocalPackage,Get-AuVerifiedCurrent,Publish-AuLocalPackage,Get-AuReleaseUploadPlan,Save-AuPackageToLocal,Get-AuLatestReleaseManifest,Get-AuRegisteredApps
'@
$oldModule=$moduleTemplate.Replace('@@LABEL@@','old')
$newModule=$moduleTemplate.Replace('@@LABEL@@','new')
$oldPath=Join-Path $state 'apps\AutoUpdate\versions\0.1.1\source\AutoUpdate.Core.psm1'
[IO.File]::WriteAllText($oldPath,$oldModule,[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($newModulePath,$newModule,[Text.UTF8Encoding]::new($false))
$oldSha=(Get-FileHash -LiteralPath $oldPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $state 'apps\AutoUpdate\versions\0.1.1\manifest.json'),(@{files=@(@{kind='runtime';path='source/AutoUpdate.Core.psm1';sha256=$oldSha})}|ConvertTo-Json -Depth 6))
[IO.File]::WriteAllText((Join-Path $state 'apps\AutoUpdate\current.json'),('{"schema":1,"app_id":"AutoUpdate","version":"0.1.1"}'))
$previousState=$env:AU_WORKER_TEST_STATE;$previousTrace=$env:AU_WORKER_TEST_TRACE;$previousModule=$env:AU_WORKER_TEST_NEW_MODULE;$previousMarker=$env:AU_WORKER_TEST_RESTART_MARKER;$previousDelay=$env:AU_WORKER_TEST_DELAY_MS;$previousWaitMarker=$env:AU_WORKER_TEST_WAIT_MARKER
try{
    $env:AU_WORKER_TEST_STATE=$state;$env:AU_WORKER_TEST_TRACE=$trace;$env:AU_WORKER_TEST_NEW_MODULE=$newModulePath
    $shell=Join-Path $PSHOME 'pwsh.exe'
    if(-not (Test-Path -LiteralPath $shell)){$shell=(Get-Command powershell.exe -ErrorAction Stop|Select-Object -First 1).Source}
    & $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $worker -Once -StateRoot $state -Owner sample -Repository engine
    if($LASTEXITCODE -ne 0){throw "Worker exited with code $LASTEXITCODE"}
    if(-not (Test-Path -LiteralPath $trace)){Get-Content -LiteralPath (Join-Path $state 'logs\app-updates.jsonl') -ErrorAction SilentlyContinue|Write-Output;throw 'Worker did not call its registered-app update function.'}
    $rows=@(Get-Content -LiteralPath $trace)
    if($rows -notcontains 'old:AutoUpdate'){throw 'The active engine did not process its own update.'}
    if($rows -notcontains 'new:TEST-APP'){throw 'The remaining app was not processed with the newly installed engine in the same cycle.'}
    if($rows -notcontains 'new:2-APP'){throw 'An app sorted before AutoUpdate was not processed with the newly installed engine.'}
    Write-Output 'PASS AutoUpdate hot reloads first; all other registered apps are handled by the new engine in the same cycle.'
    $logRows=@(Get-Content -LiteralPath (Join-Path $state 'logs\app-updates.jsonl')|ForEach-Object{$_|ConvertFrom-Json})
    $autoRow=@($logRows|Where-Object{$_.app_id -ceq 'AutoUpdate'}|Select-Object -First 1)
    $otherRows=@($logRows|Where-Object{$_.app_id -in @('TEST-APP','2-APP')})
    if($autoRow.Count -ne 1 -or $autoRow[0].engine_version -cne '0.1.1'){throw 'The AutoUpdate app did not record the engine version that performed its own check.'}
    if($otherRows.Count -ne 2 -or @($otherRows|Where-Object{$_.engine_version -cne '0.1.2'}).Count){throw 'The remaining apps did not record the newly loaded engine version.'}
    Write-Output 'PASS each app log records the exact AutoUpdate engine version used for its check.'
    $cadenceWorker=Join-Path $tools 'cadence-worker.ps1';$waitMarker=Join-Path $temp 'cycle-wait-ms.txt'
    $cadenceSource=$workerSource.Replace('if($waitMilliseconds -gt 0){Start-Sleep -Milliseconds $waitMilliseconds}','if($waitMilliseconds -gt 0){[IO.File]::WriteAllText($env:AU_WORKER_TEST_WAIT_MARKER,[string]$waitMilliseconds);exit 0}')
    if($cadenceSource -ceq $workerSource -or $cadenceSource.Contains('Start-Sleep -Milliseconds $waitMilliseconds')){throw 'Could not isolate the worker cadence wait for testing.'}
    [IO.File]::WriteAllText($cadenceWorker,$cadenceSource,[Text.UTF8Encoding]::new($false))
    $env:AU_WORKER_TEST_WAIT_MARKER=$waitMarker;$env:AU_WORKER_TEST_DELAY_MS='700'
    $cadenceArgs=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$cadenceWorker,'-IntervalMinutes','1','-StateRoot',$state,'-Owner','sample','-Repository','engine')
    $cadenceProcess=Start-Process -FilePath $shell -ArgumentList $cadenceArgs -WindowStyle Hidden -PassThru
    try{
        if(-not $cadenceProcess.WaitForExit(10000)){throw 'Cadence worker did not complete the timing check.'}
        if($cadenceProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $waitMarker)){throw 'Cadence worker did not report its next-cycle delay.'}
        $waitMilliseconds=[int](Get-Content -LiteralPath $waitMarker -Raw)
        if($waitMilliseconds -le 0 -or $waitMilliseconds -ge 59000){throw "Worker cadence did not subtract the simulated update time: $waitMilliseconds ms."}
        Write-Output 'PASS registered-app worker schedules 10-minute checks from cycle start, without adding processing time.'
    }finally{if(-not $cadenceProcess.HasExited){Stop-Process -Id $cadenceProcess.Id -Force -ErrorAction SilentlyContinue};Remove-Item Env:AU_WORKER_TEST_DELAY_MS -ErrorAction SilentlyContinue}
    $handoffRoot=Join-Path $temp 'handoff';$handoffTools=Join-Path $handoffRoot 'tools';[void][IO.Directory]::CreateDirectory($handoffTools)
    Copy-Item -LiteralPath $policyReader -Destination (Join-Path $handoffTools 'read-update-policy.ps1')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\tools\shared-cycle-lock.ps1') -Destination (Join-Path $handoffTools 'shared-cycle-lock.ps1')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\tools\guard-local-package-version.ps1') -Destination (Join-Path $handoffTools 'guard-local-package-version.ps1')
    $handoffWorker=Join-Path $handoffTools 'update-registered-apps.ps1';$marker=Join-Path $temp 'runner-restart-requested.txt'
    $handoffSource=$workerSource.Replace('Start-Sleep -Milliseconds $waitMilliseconds','Start-Sleep -Milliseconds 500')
    $startLine='        Start-Process -FilePath $shell -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent (Split-Path -Parent $runnerPath)) -WindowStyle Hidden|Out-Null'
    $handoffSource=$handoffSource.Replace($startLine,'        [IO.File]::WriteAllText($env:AU_WORKER_TEST_RESTART_MARKER,''requested'')')
    if($handoffSource -ceq $workerSource -or $handoffSource.Contains($startLine)){throw 'Could not isolate the shared-worker restart handoff for testing.'}
    [IO.File]::WriteAllText($handoffWorker,$handoffSource,[Text.UTF8Encoding]::new($false))
    $env:AU_WORKER_TEST_RESTART_MARKER=$marker
    $beforeCount=@(Get-Content -LiteralPath $trace).Count
    $workerArgs=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$handoffWorker,'-IntervalMinutes','1','-StateRoot',$state,'-Owner','sample','-Repository','engine')
    $workerProcess=Start-Process -FilePath $shell -ArgumentList $workerArgs -WindowStyle Hidden -PassThru
    try{
        $deadline=[DateTime]::UtcNow.AddSeconds(8)
        while([DateTime]::UtcNow -lt $deadline -and @(Get-Content -LiteralPath $trace).Count -le $beforeCount){Start-Sleep -Milliseconds 100}
        if(@(Get-Content -LiteralPath $trace).Count -le $beforeCount){throw 'Long-running worker did not complete its initial cycle.'}
        [IO.File]::AppendAllText($handoffWorker,"`n# simulated shared-folder update`n")
        $deadline=[DateTime]::UtcNow.AddSeconds(8)
        while([DateTime]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $marker)){Start-Sleep -Milliseconds 100}
        if(-not (Test-Path -LiteralPath $marker)){throw 'Long-running worker did not request a handoff after its script changed.'}
        if(-not (Select-String -LiteralPath (Join-Path $state 'logs\app-updates.jsonl') -SimpleMatch 'runner-restart-requested' -Quiet)){throw 'Long-running worker did not log its restart handoff.'}
        if(-not $workerProcess.WaitForExit(5000)){throw 'Old worker stayed alive after handing off.'}
        Write-Output 'PASS a running worker detects a changed shared script and hands off without a visible console.'
    }finally{if(-not $workerProcess.HasExited){Stop-Process -Id $workerProcess.Id -Force -ErrorAction SilentlyContinue}}
}finally{
    if($null -eq $previousState){Remove-Item Env:AU_WORKER_TEST_STATE -ErrorAction SilentlyContinue}else{$env:AU_WORKER_TEST_STATE=$previousState}
    if($null -eq $previousTrace){Remove-Item Env:AU_WORKER_TEST_TRACE -ErrorAction SilentlyContinue}else{$env:AU_WORKER_TEST_TRACE=$previousTrace}
    if($null -eq $previousModule){Remove-Item Env:AU_WORKER_TEST_NEW_MODULE -ErrorAction SilentlyContinue}else{$env:AU_WORKER_TEST_NEW_MODULE=$previousModule}
    if($null -eq $previousMarker){Remove-Item Env:AU_WORKER_TEST_RESTART_MARKER -ErrorAction SilentlyContinue}else{$env:AU_WORKER_TEST_RESTART_MARKER=$previousMarker}
    if($null -eq $previousDelay){Remove-Item Env:AU_WORKER_TEST_DELAY_MS -ErrorAction SilentlyContinue}else{$env:AU_WORKER_TEST_DELAY_MS=$previousDelay}
    if($null -eq $previousWaitMarker){Remove-Item Env:AU_WORKER_TEST_WAIT_MARKER -ErrorAction SilentlyContinue}else{$env:AU_WORKER_TEST_WAIT_MARKER=$previousWaitMarker}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
