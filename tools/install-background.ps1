param([switch]$Remove,[ValidateRange(1,1440)][int]$IntervalMinutes=10,[string]$StateRoot=(Join-Path $env:LOCALAPPDATA 'Siny\AutoUpdate'))
$ErrorActionPreference='Stop'
$startup=[Environment]::GetFolderPath('Startup')
if(-not $startup){throw "The current user's Startup folder could not be found."}
$shortcutPath=Join-Path $startup 'AutoUpdate Background.lnk'
$vbsLauncher=Join-Path $StateRoot 'start-background-hidden.vbs'
$root=Split-Path -Parent $PSScriptRoot
$starter=Join-Path $PSScriptRoot 'start-background.ps1'
$exe=Join-Path $PSHOME 'pwsh.exe'
if(-not (Test-Path -LiteralPath $exe)){$exe=Join-Path $PSHOME 'powershell.exe'}
if(-not (Test-Path -LiteralPath $exe)){$exe=(Get-Command pwsh.exe -ErrorAction SilentlyContinue|Select-Object -First 1).Source}
if(-not $exe){$exe=(Get-Command powershell.exe -ErrorAction Stop|Select-Object -First 1).Source}
if($Remove){
    if(Test-Path -LiteralPath $shortcutPath){Remove-Item -LiteralPath $shortcutPath -Force}
    if(Test-Path -LiteralPath $vbsLauncher){Remove-Item -LiteralPath $vbsLauncher -Force}
    Write-Output 'AutoUpdate login startup shortcut removed.'
    exit 0
}
$wscript=Join-Path $env:WINDIR 'System32\wscript.exe'
if(-not (Test-Path -LiteralPath $wscript)){$wscript=(Get-Command wscript.exe -ErrorAction Stop|Select-Object -First 1).Source}
[void][IO.Directory]::CreateDirectory($StateRoot)
$quote=[string][char]34
$command=$quote+$exe+$quote+' -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File '+$quote+$starter+$quote+' -IntervalMinutes '+$IntervalMinutes+' -StateRoot '+$quote+$StateRoot+$quote
$vbsCommand=$quote+$command.Replace($quote,$quote+$quote)+$quote
$vbsContent=@(
    'Option Explicit',
    'Dim shell, command',
    'Set shell = CreateObject("WScript.Shell")',
    ('command = '+$vbsCommand),
    'shell.Run command, 0, False'
) -join "`r`n"
[IO.File]::WriteAllText($vbsLauncher,$vbsContent,[Text.Encoding]::Unicode)
$shell=New-Object -ComObject WScript.Shell
$shortcut=$shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath=$wscript
$shortcut.Arguments='//B //NoLogo '+$quote+$vbsLauncher+$quote
$shortcut.WorkingDirectory=$root
$shortcut.WindowStyle=7
$shortcut.Description='Start AutoUpdate background source sync and app update checks'
$shortcut.Save()
Start-Process -FilePath $wscript -ArgumentList ('//B //NoLogo '+$quote+$vbsLauncher+$quote) -WorkingDirectory $root -WindowStyle Hidden|Out-Null
Write-Output ('AutoUpdate hidden background startup installed: '+$shortcutPath)
