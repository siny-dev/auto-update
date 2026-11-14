param(
    [switch]$Once,
    [switch]$LocalOnly,
    [ValidateRange(1,1440)][int]$IntervalMinutes=10,
    [string]$StateRoot=(Join-Path $env:LOCALAPPDATA 'Siny\AutoUpdate'),
    [string]$Owner='siny-dev',
    [string]$Repository='auto-update'
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'read-update-policy.ps1')
. (Join-Path $PSScriptRoot 'shared-cycle-lock.ps1')
. (Join-Path $PSScriptRoot 'guard-local-package-version.ps1')
$sourceModule=Join-Path $root 'source\AutoUpdate.Core.psm1'
$logRoot=Join-Path $StateRoot 'logs';[void][IO.Directory]::CreateDirectory($logRoot)
$logPath=Join-Path $logRoot 'app-updates.jsonl'
$script:activeEngineVersion='source'
function Write-UpdateLog($Record){
    $line=([ordered]@{utc=[DateTime]::UtcNow.ToString('o');engine_version=$script:activeEngineVersion;app_id=$Record.AppId;status=$Record.Status;version=$Record.Version;message=$Record.Message}|ConvertTo-Json -Compress)
    [IO.File]::AppendAllText($logPath,$line+[char]10,[Text.UTF8Encoding]::new($false))
}
function Resolve-EngineModule{
    $pointerPath=Join-Path $StateRoot 'apps\AutoUpdate\current.json'
    if(-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)){return $sourceModule}
    $pointer=Get-Content -Raw -LiteralPath $pointerPath|ConvertFrom-Json
    if($pointer.schema -ne 1 -or $pointer.app_id -cne 'AutoUpdate' -or $pointer.version -notmatch '^\d+\.\d+\.\d+$'){throw 'Installed AutoUpdate pointer is invalid.'}
    $versionRoot=Join-Path $StateRoot ('apps\AutoUpdate\versions\'+$pointer.version)
    $manifest=Get-Content -Raw -LiteralPath (Join-Path $versionRoot 'manifest.json')|ConvertFrom-Json
    $entry=@($manifest.files|Where-Object{$_.kind -eq 'runtime' -and $_.path -ceq 'source/AutoUpdate.Core.psm1'})
    if($entry.Count -ne 1){throw 'Installed AutoUpdate package has no single engine module.'}
    $candidate=Join-Path $versionRoot 'source\AutoUpdate.Core.psm1'
    if((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ine $entry[0].sha256){throw 'Installed AutoUpdate engine hash is invalid.'}
    $requiredFunctions=@('function Register-AuApplication','function Install-AuLatestAvailable','function Get-AuLatestLocalPackage','function Get-AuVerifiedCurrent','function Publish-AuLocalPackage','function Get-AuReleaseUploadPlan','function Save-AuPackageToLocal','function Get-AuLatestReleaseManifest')
    foreach($required in $requiredFunctions){if(-not (Select-String -LiteralPath $candidate -SimpleMatch $required -Quiet)){return $sourceModule}}
    if($script:cycleLocalOnly -and -not (Select-String -LiteralPath $candidate -SimpleMatch '[switch]$LocalOnly' -Quiet)){return $sourceModule}
    return $candidate
}
function Import-EngineModule([string]$ModulePath){
    Remove-Module AutoUpdate.Core -ErrorAction SilentlyContinue
    Import-Module $ModulePath -Force -Global
    if($ModulePath -match '[\\/]versions[\\/](\d+\.\d+\.\d+)[\\/]') {$script:activeEngineVersion=$Matches[1]} else {$script:activeEngineVersion='source'}
}
function Invoke-UpdateCycle{
    $script:cycleLocalOnly=$LocalOnly -or (Get-AuUpdatePolicyLocalOnly -PolicyPath (Join-Path $root 'config\update-policy.json'))
    $sharedLockPath=Join-Path $root 'outbox\locks\registered-apps.lock'
    $sharedLock=Enter-AuSharedCycleLock -Path $sharedLockPath -TimeoutMilliseconds 60000
    if($null -eq $sharedLock){
        Write-UpdateLog ([pscustomobject]@{AppId=$null;Status='shared-cycle-lock-timeout';Version=$null;Message='Another PC is updating shared packages; this cycle will retry at the next interval.'})
        return
    }
    try{
    $modulePath=Resolve-EngineModule
    Import-EngineModule $modulePath
    $mutex=[Threading.Mutex]::new($false,'Local\AutoUpdateRegisteredApps');$owned=$false
    try{
        try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){return}
        $registered=@(Get-AuRegisteredApps -StateRoot $StateRoot)
        if(-not @($registered|Where-Object{$_.app_id -ceq 'AutoUpdate'}).Count){
            Register-AuApplication -StateRoot $StateRoot -AppId 'AutoUpdate' -Owner $Owner -Repository $Repository -Architecture 'any'|Out-Null
        }
        $apps=@(Get-AuRegisteredApps -StateRoot $StateRoot)
        $orderedApps=@($apps|Where-Object{$_.app_id -ceq 'AutoUpdate'})+@($apps|Where-Object{$_.app_id -cne 'AutoUpdate'})
        try{
            $moduleOutput=& (Join-Path $root 'tools\sync-core-module.ps1') -StateRoot $StateRoot
            $moduleResult=([string]::Join([Environment]::NewLine,@($moduleOutput|ForEach-Object{[string]$_}))|ConvertFrom-Json -ErrorAction Stop)
            $moduleMessage=[string]$moduleResult.message
            if($moduleResult.cache_status){$moduleMessage+=' Local PC module cache: '+[string]$moduleResult.cache_status+' ('+[string]$moduleResult.cache_version+').'}
            Write-UpdateLog ([pscustomobject]@{AppId='AutoUpdate';Status=('module-'+$moduleResult.status);Version=$moduleResult.version;Message=$moduleMessage})
        }catch{
            $moduleMessage=$_.Exception.Message -replace '(github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+)','[REDACTED]'
            Write-UpdateLog ([pscustomobject]@{AppId='AutoUpdate';Status='module-sync-failed';Version=$null;Message=$moduleMessage})
        }
        foreach($app in $orderedApps){
            $localPackageRoot=Join-Path $root ('outbox\apps\'+$app.app_id)
            $buildRecipe=Join-Path $localPackageRoot 'build.json'
            if(Test-Path -LiteralPath $buildRecipe -PathType Leaf){
                try{
                    $remoteVersion=$null
                    if(-not $script:cycleLocalOnly){try{$remoteManifest=Get-AuLatestReleaseManifest -Owner $app.owner -Repository $app.repository -AppId $app.app_id -Architecture $app.architecture;if($remoteManifest){$remoteVersion=[string]$remoteManifest.Manifest.version}}catch{if($_.Exception.Message -notmatch 'HTTP 404'){throw}}}
                    $buildResultText=& (Join-Path $root 'tools\build-local-package.ps1') -RecipePath $buildRecipe -PackageRoot $localPackageRoot -RemoteVersion $remoteVersion
                    $buildResult=$buildResultText|ConvertFrom-Json
                    Write-UpdateLog ([pscustomobject]@{AppId=$app.app_id;Status=('build-'+$buildResult.status);Version=$buildResult.version;Message=$buildResult.message})
                }catch{
                    $buildMessage=$_.Exception.Message -replace '(github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+)','[REDACTED]'
                    Write-UpdateLog ([pscustomobject]@{AppId=$app.app_id;Status='build-failed';Version=$null;Message=$buildMessage})
                }
            }
            $localPackage=Get-AuLatestLocalPackage -PackageRoot $localPackageRoot -AppId $app.app_id -Architecture $app.architecture
            if($localPackage){
                $versionGuard=Test-AuLocalPackageVersionMetadata -PackageRoot $localPackage.Path -BuildRecipePath $buildRecipe
                if(-not $versionGuard.Valid){
                    Write-UpdateLog ([pscustomobject]@{AppId=$app.app_id;Status=$versionGuard.Status;Version=$localPackage.Manifest.version;Message=$versionGuard.Message})
                    continue
                }elseif(-not $script:cycleLocalOnly){
                    try{
                        $publish=Publish-AuLocalPackage -Owner $app.owner -Repository $app.repository -AppId $app.app_id -PackageRoot $localPackage.Path -Architecture $app.architecture
                        Write-UpdateLog ([pscustomobject]@{AppId=$app.app_id;Status=$publish.Status;Version=$publish.Version;Message=$publish.Message})
                    }catch{
                        $publishMessage=$_.Exception.Message -replace '(github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+)','[REDACTED]'
                        Write-UpdateLog ([pscustomobject]@{AppId=$app.app_id;Status='publish-failed';Version=$localPackage.Manifest.version;Message=$publishMessage})
                    }
                }
            }
            try{
                $installOptions=@{}
                if($script:cycleLocalOnly){$installOptions.LocalOnly=$true}
                $result=Install-AuLatestAvailable -Owner $app.owner -Repository $app.repository -AppId $app.app_id -StateRoot $StateRoot -Architecture $app.architecture -LocalPackageRoot $localPackageRoot @installOptions
                $message=if($result.Message){[string]$result.Message}elseif($script:cycleLocalOnly){'Local package check completed'}else{'Local and GitHub package check completed'}
                Write-UpdateLog ([pscustomobject]@{AppId=$app.app_id;Status=$result.Status;Version=$result.Version;Message=$message})
                if($app.app_id -ceq 'AutoUpdate'){
                    $newModulePath=Resolve-EngineModule
                    if(-not [string]::Equals([IO.Path]::GetFullPath($modulePath),[IO.Path]::GetFullPath($newModulePath),[StringComparison]::OrdinalIgnoreCase)){
                        Import-EngineModule $newModulePath
                        $modulePath=$newModulePath
                        Write-UpdateLog ([pscustomobject]@{AppId='AutoUpdate';Status='engine-hot-reloaded';Version=$null;Message='The newly installed common engine will handle the remaining apps in this cycle.'})
                    }
                }
            }catch{
                $message=$_.Exception.Message -replace '(github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+)','[REDACTED]'
                Write-UpdateLog ([pscustomobject]@{AppId=$app.app_id;Status='failed';Version=$null;Message=$message})
            }
        }
    }finally{if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
    }finally{Exit-AuSharedCycleLock -LockHandle $sharedLock}
}
$workerMutex=[Threading.Mutex]::new($false,'Local\AutoUpdateRegisteredAppsWorker');$workerOwned=$false
$runnerPath=$PSCommandPath
$runnerHash=(Get-FileHash -LiteralPath $runnerPath -Algorithm SHA256).Hash
$restartForSourceChange=$false
try{
    try{$workerOwned=$workerMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$workerOwned=$true}
    if(-not $workerOwned){exit 0}
    do{
        $cycleTimer=[Diagnostics.Stopwatch]::StartNew()
        try{Invoke-UpdateCycle}catch{
            $message=$_.Exception.Message -replace '(github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+)','[REDACTED]'
            Write-UpdateLog ([pscustomobject]@{AppId=$null;Status='failed';Version=$null;Message=$message})
        }
        if(-not $Once){
            $cycleTimer.Stop()
            $effectiveInterval=Get-AuUpdatePolicyInterval -PolicyPath (Join-Path $root 'config\update-policy.json') -FallbackMinutes $IntervalMinutes
            $waitMilliseconds=[Math]::Max(0,[int][Math]::Ceiling(($effectiveInterval*60000)-$cycleTimer.Elapsed.TotalMilliseconds))
            if($waitMilliseconds -gt 0){Start-Sleep -Milliseconds $waitMilliseconds}
            try{if((Get-FileHash -LiteralPath $runnerPath -Algorithm SHA256).Hash -cne $runnerHash){$restartForSourceChange=$true;break}}
            catch{Write-UpdateLog ([pscustomobject]@{AppId='AutoUpdate';Status='runner-hash-check-failed';Version=$null;Message='Could not check the shared worker file; it will retry after the next interval.'})}
        }
    }while(-not $Once)
}finally{if($workerOwned){$workerMutex.ReleaseMutex()};$workerMutex.Dispose()}
if($restartForSourceChange){
    $shell=Join-Path $PSHOME 'pwsh.exe'
    if(-not (Test-Path -LiteralPath $shell)){$shell=Join-Path $PSHOME 'powershell.exe'}
    if(-not (Test-Path -LiteralPath $shell)){$shell=(Get-Command pwsh.exe -ErrorAction SilentlyContinue|Select-Object -First 1).Source}
    if(-not $shell){$shell=(Get-Command powershell.exe -ErrorAction Stop|Select-Object -First 1).Source}
    $quote={param([string]$Value) '"'+$Value.Replace('"','\"')+'"'}
    $arguments='-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File '+(& $quote $runnerPath)+' -IntervalMinutes '+$IntervalMinutes+' -StateRoot '+(& $quote $StateRoot)
    if($LocalOnly){$arguments+=' -LocalOnly'}
    $arguments+=' -Owner '+(& $quote $Owner)+' -Repository '+(& $quote $Repository)
    try{
        Start-Process -FilePath $shell -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent (Split-Path -Parent $runnerPath)) -WindowStyle Hidden|Out-Null
        Write-UpdateLog ([pscustomobject]@{AppId='AutoUpdate';Status='runner-restart-requested';Version=$null;Message='The shared worker changed; the current worker handed off to the updated script.'})
    }catch{
        $message=$_.Exception.Message -replace '(github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+)','[REDACTED]'
        Write-UpdateLog ([pscustomobject]@{AppId='AutoUpdate';Status='runner-restart-failed';Version=$null;Message=$message})
    }
}
