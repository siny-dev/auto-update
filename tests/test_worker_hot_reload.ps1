$ErrorActionPreference='Stop'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('au-worker-hot-reload-'+[guid]::NewGuid().ToString('N'))
$tools=Join-Path $temp 'tools';$source=Join-Path $temp 'source';$state=Join-Path $temp 'state'
$trace=Join-Path $temp 'module-trace.txt';$newModulePath=Join-Path $temp 'new-engine.psm1'
[void][IO.Directory]::CreateDirectory($tools);[void][IO.Directory]::CreateDirectory($source)
[void][IO.Directory]::CreateDirectory((Join-Path $state 'apps\AutoUpdate\versions\0.1.1\source'))
[void][IO.Directory]::CreateDirectory((Join-Path $state 'logs'))
$worker=Join-Path $tools 'update-registered-apps.ps1'
$workerSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\tools\update-registered-apps.ps1'))
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
$previousState=$env:AU_WORKER_TEST_STATE;$previousTrace=$env:AU_WORKER_TEST_TRACE;$previousModule=$env:AU_WORKER_TEST_NEW_MODULE
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
}finally{
    if($null -eq $previousState){Remove-Item Env:AU_WORKER_TEST_STATE -ErrorAction SilentlyContinue}else{$env:AU_WORKER_TEST_STATE=$previousState}
    if($null -eq $previousTrace){Remove-Item Env:AU_WORKER_TEST_TRACE -ErrorAction SilentlyContinue}else{$env:AU_WORKER_TEST_TRACE=$previousTrace}
    if($null -eq $previousModule){Remove-Item Env:AU_WORKER_TEST_NEW_MODULE -ErrorAction SilentlyContinue}else{$env:AU_WORKER_TEST_NEW_MODULE=$previousModule}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
