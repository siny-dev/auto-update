param([switch]$Remove)
$ErrorActionPreference='Stop'
$TaskName='AutoUpdate Source Sync'
$Root=Split-Path -Parent $PSScriptRoot
$Script=Join-Path $PSScriptRoot 'sync.ps1'
$PowerShell=Join-Path $PSHOME 'powershell.exe'
if(-not (Test-Path -LiteralPath $Script)){throw 'sync.ps1 is missing'}
if($Remove){
 Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
 Write-Output 'AutoUpdate source sync task removed'
 exit 0
}
$arguments='-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$Script+'" -IntervalMinutes 5'
$action=New-ScheduledTaskAction -Execute $PowerShell -Argument $arguments -WorkingDirectory $Root
$trigger=New-ScheduledTaskTrigger -AtLogOn -User ($env:USERDOMAIN+'\'+$env:USERNAME)
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries
$principal=New-ScheduledTaskPrincipal -UserId ($env:USERDOMAIN+'\'+$env:USERNAME) -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Sync AutoUpdate local source with its GitHub main branch without opening a browser' -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Output 'AutoUpdate source sync task installed and started in the background'