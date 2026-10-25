param([ValidateRange(1,1440)][int]$IntervalMinutes=10,[string]$StateRoot=(Join-Path $env:LOCALAPPDATA 'Siny\AutoUpdate'))
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'read-update-policy.ps1')
$IntervalMinutes=Get-AuUpdatePolicyInterval -PolicyPath (Join-Path $root 'config\update-policy.json') -FallbackMinutes $IntervalMinutes
$exe=Join-Path $PSHOME 'pwsh.exe'
if(-not (Test-Path -LiteralPath $exe)){$exe=Join-Path $PSHOME 'powershell.exe'}
if(-not (Test-Path -LiteralPath $exe)){$exe=(Get-Command pwsh.exe -ErrorAction SilentlyContinue|Select-Object -First 1).Source}
if(-not $exe){$exe=(Get-Command powershell.exe -ErrorAction Stop|Select-Object -First 1).Source}
function Quote-Argument([string]$Value){'"'+$Value.Replace('"','\"')+'"'}
function Start-Worker([string]$Script,[string[]]$Extra){
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',(Quote-Argument $Script))+$Extra
    Start-Process -FilePath $exe -ArgumentList ($arguments -join ' ') -WorkingDirectory $root -WindowStyle Hidden|Out-Null
}
Start-Worker (Join-Path $PSScriptRoot 'sync.ps1') @('-IntervalMinutes',[string]$IntervalMinutes)
Start-Worker (Join-Path $PSScriptRoot 'update-registered-apps.ps1') @('-IntervalMinutes',[string]$IntervalMinutes,'-StateRoot',(Quote-Argument $StateRoot))
Write-Output 'AutoUpdate source sync and registered-app updater started hidden in the background.'
