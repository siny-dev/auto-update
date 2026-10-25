param(
    [switch]$Once,
    [ValidateRange(1,1440)][int]$IntervalMinutes=10,
    [string]$StateRoot=(Join-Path $env:LOCALAPPDATA 'Siny\AutoUpdate'),
    [string]$Owner='siny-dev',
    [string]$Repository='auto-update'
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$sourceModule=Join-Path $root 'source\AutoUpdate.Core.psm1'
$logRoot=Join-Path $StateRoot 'logs';[void][IO.Directory]::CreateDirectory($logRoot)
$logPath=Join-Path $logRoot 'app-updates.jsonl'
function Write-UpdateLog($Record){
    $line=([ordered]@{utc=[DateTime]::UtcNow.ToString('o');app_id=$Record.AppId;status=$Record.Status;version=$Record.Version;message=$Record.Message}|ConvertTo-Json -Compress)
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
    $requiredFunctions=@('function Register-AuApplication','function Install-AuLatestAvailable','function Get-AuLatestLocalPackage','function Publish-AuLocalPackage','function Get-AuReleaseUploadPlan','function Save-AuPackageToLocal','function Get-AuLatestReleaseManifest')
    foreach($required in $requiredFunctions){if(-not (Select-String -LiteralPath $candidate -SimpleMatch $required -Quiet)){return $sourceModule}}
    return $candidate
}
function Invoke-UpdateCycle{
    $modulePath=Resolve-EngineModule
    Remove-Module AutoUpdate.Core -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -Global
    $mutex=[Threading.Mutex]::new($false,'Local\AutoUpdateRegisteredApps');$owned=$false
    try{
        try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){return}
        $registered=@(Get-AuRegisteredApps -StateRoot $StateRoot)
        if(-not @($registered|Where-Object{$_.app_id -ceq 'AutoUpdate'}).Count){
            Register-AuApplication -StateRoot $StateRoot -AppId 'AutoUpdate' -Owner $Owner -Repository $Repository -Architecture 'any'|Out-Null
        }
        foreach($app in (Get-AuRegisteredApps -StateRoot $StateRoot)){
            $localPackageRoot=Join-Path $root ('outbox\apps\'+$app.app_id)
            $buildRecipe=Join-Path $localPackageRoot 'build.json'
            if(Test-Path -LiteralPath $buildRecipe -PathType Leaf){
                try{
                    $remoteVersion=$null
                    try{$remoteManifest=Get-AuLatestReleaseManifest -Owner $app.owner -Repository $app.repository -AppId $app.app_id -Architecture $app.architecture;$remoteVersion=[string]$remoteManifest.Manifest.version}catch{if($_.Exception.Message -notmatch 'HTTP 404'){throw}}
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
                try{
                    $publish=Publish-AuLocalPackage -Owner $app.owner -Repository $app.repository -AppId $app.app_id -PackageRoot $localPackage.Path -Architecture $app.architecture
                    Write-UpdateLog ([pscustomobject]@{AppId=$app.app_id;Status=$publish.Status;Version=$publish.Version;Message=$publish.Message})
                }catch{
                    $publishMessage=$_.Exception.Message -replace '(github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+)','[REDACTED]'
                    Write-UpdateLog ([pscustomobject]@{AppId=$app.app_id;Status='publish-failed';Version=$localPackage.Manifest.version;Message=$publishMessage})
                }
            }
            try{
                $result=Install-AuLatestAvailable -Owner $app.owner -Repository $app.repository -AppId $app.app_id -StateRoot $StateRoot -Architecture $app.architecture -LocalPackageRoot $localPackageRoot
                $message=if($result.Message){[string]$result.Message}else{'Local and GitHub package check completed'}
                Write-UpdateLog ([pscustomobject]@{AppId=$app.app_id;Status=$result.Status;Version=$result.Version;Message=$message})
            }catch{
                $message=$_.Exception.Message -replace '(github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+)','[REDACTED]'
                Write-UpdateLog ([pscustomobject]@{AppId=$app.app_id;Status='failed';Version=$null;Message=$message})
            }
        }
    }finally{if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
$workerMutex=[Threading.Mutex]::new($false,'Local\AutoUpdateRegisteredAppsWorker');$workerOwned=$false
try{
    try{$workerOwned=$workerMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$workerOwned=$true}
    if(-not $workerOwned){exit 0}
    do{
        try{Invoke-UpdateCycle}catch{
            $message=$_.Exception.Message -replace '(github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+)','[REDACTED]'
            Write-UpdateLog ([pscustomobject]@{AppId=$null;Status='failed';Version=$null;Message=$message})
        }
        if(-not $Once){Start-Sleep -Seconds ($IntervalMinutes*60)}
    }while(-not $Once)
}finally{if($workerOwned){$workerMutex.ReleaseMutex()};$workerMutex.Dispose()}
