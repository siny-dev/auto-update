param([switch]$Remove,[ValidateRange(1,1440)][int]$IntervalMinutes=10,[string]$StateRoot=(Join-Path $env:LOCALAPPDATA 'Siny\AutoUpdate'))
$ErrorActionPreference='Stop'
$startup=[Environment]::GetFolderPath('Startup')
if(-not $startup){throw "The current user's Startup folder could not be found."}
$shortcutPath=Join-Path $startup 'AutoUpdate Background.lnk'
$root=Split-Path -Parent $PSScriptRoot
$starter=Join-Path $PSScriptRoot 'start-background.ps1'
$exe=Join-Path $PSHOME 'pwsh.exe'
if(-not (Test-Path -LiteralPath $exe)){$exe=Join-Path $PSHOME 'powershell.exe'}
if(-not (Test-Path -LiteralPath $exe)){$exe=(Get-Command pwsh.exe -ErrorAction SilentlyContinue|Select-Object -First 1).Source}
if(-not $exe){$exe=(Get-Command powershell.exe -ErrorAction Stop|Select-Object -First 1).Source}
if($Remove){
    if(Test-Path -LiteralPath $shortcutPath){Remove-Item -LiteralPath $shortcutPath -Force}
    Write-Output 'AutoUpdate login startup shortcut removed.'
    exit 0
}
$shell=New-Object -ComObject WScript.Shell
$shortcut=$shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath=$exe
$shortcut.Arguments='-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$starter+'" -IntervalMinutes '+$IntervalMinutes+' -StateRoot "'+$StateRoot+'"'
$shortcut.WorkingDirectory=$root
$shortcut.WindowStyle=7
$shortcut.Description='Start AutoUpdate background source sync and app update checks'
$shortcut.Save()
$launchArgs=@('-NoLogo','-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File','"'+$starter+'"','-IntervalMinutes',[string]$IntervalMinutes,'-StateRoot','"'+$StateRoot+'"')
Start-Process -FilePath $exe -ArgumentList ($launchArgs -join ' ') -WorkingDirectory $root -WindowStyle Hidden|Out-Null
Write-Output ('AutoUpdate hidden background startup installed: '+$shortcutPath)
