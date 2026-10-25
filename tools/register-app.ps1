param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')][string]$AppId,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9-]+$')][string]$Owner,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$Repository,
    [ValidateSet('any','x86','x64','arm64')][string]$Architecture='x64',
    [string]$StateRoot=(Join-Path $env:LOCALAPPDATA 'Siny\AutoUpdate')
)
$ErrorActionPreference='Stop'
$module=Join-Path $PSScriptRoot '..\source\AutoUpdate.Core.psm1'
Import-Module $module -Force
Register-AuApplication -StateRoot $StateRoot -AppId $AppId -Owner $Owner -Repository $Repository -Architecture $Architecture | ConvertTo-Json -Compress
