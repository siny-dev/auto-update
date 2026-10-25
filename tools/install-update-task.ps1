param([switch]$Remove,[ValidateRange(1,1440)][int]$IntervalMinutes=10,[string]$StateRoot=(Join-Path $env:LOCALAPPDATA 'Siny\AutoUpdate'))
$ErrorActionPreference='Stop'
$installer=Join-Path $PSScriptRoot 'install-background.ps1'
if(-not (Test-Path -LiteralPath $installer)){throw 'install-background.ps1 is missing'}
& $installer -Remove:$Remove -IntervalMinutes $IntervalMinutes -StateRoot $StateRoot
