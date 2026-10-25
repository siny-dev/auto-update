param([switch]$Remove,[ValidateRange(1,1440)][int]$IntervalMinutes=10,[string]$StateRoot=(Join-Path $env:LOCALAPPDATA 'Siny\AutoUpdate'))
$ErrorActionPreference='Stop'
$TaskName='AutoUpdate Registered Apps'
$Root=Split-Path -Parent $PSScriptRoot
$Script=Join-Path $PSScriptRoot 'update-registered-apps.ps1'
$PowerShell=Join-Path $PSHOME 'pwsh.exe'
if(-not (Test-Path -LiteralPath $PowerShell)){$PowerShell=Join-Path $PSHOME 'powershell.exe'}
if(-not (Test-Path -LiteralPath $PowerShell)){$PowerShell=(Get-Command pwsh.exe,powershell.exe -ErrorAction Stop|Select-Object -First 1).Source}
if(-not (Test-Path -LiteralPath $Script)){throw 'update-registered-apps.ps1 is missing'}
if($Remove){Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue;Write-Output 'AutoUpdate app update task removed';exit 0}
[void][IO.Directory]::CreateDirectory((Join-Path $StateRoot 'registry'))
$quotedRoot='"'+$StateRoot.Replace('"','\"')+'"'
$arguments='-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$Script+'" -IntervalMinutes '+$IntervalMinutes+' -StateRoot '+$quotedRoot
$action=New-ScheduledTaskAction -Execute $PowerShell -Argument $arguments -WorkingDirectory $Root
$trigger=New-ScheduledTaskTrigger -AtLogOn -User ($env:USERDOMAIN+'\'+$env:USERNAME)
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries
$principal=New-ScheduledTaskPrincipal -UserId ($env:USERDOMAIN+'\'+$env:USERNAME) -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Check registered AutoUpdate releases in the background at the configured interval' -Force|Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Output 'AutoUpdate registered-app updater installed and started in the background'
