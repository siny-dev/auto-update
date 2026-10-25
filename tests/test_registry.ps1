$ErrorActionPreference='Stop'
$module=Join-Path $PSScriptRoot '..\source\AutoUpdate.Core.psm1'
Import-Module $module -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdateRegistryTest-'+[guid]::NewGuid().ToString('N'))
try{
    $empty=@(Get-AuRegisteredApps -StateRoot $root)
    if($empty.Count -ne 0){throw 'Missing registry must produce an empty app list.'}
    $one=Register-AuApplication -StateRoot $root -AppId 'SampleApp' -Owner 'siny-dev' -Repository 'sample-app' -Architecture 'x64'
    if($one.Status -ne 'registered'){throw 'Registration did not report success.'}
    $apps=@(Get-AuRegisteredApps -StateRoot $root)
    if($apps.Count -ne 1 -or $apps[0].app_id -ne 'SampleApp' -or $apps[0].repository -ne 'sample-app'){throw 'Registered app was not persisted.'}
    Register-AuApplication -StateRoot $root -AppId 'SampleApp' -Owner 'siny-dev' -Repository 'sample-app-v2' -Architecture 'any'|Out-Null
    $apps=@(Get-AuRegisteredApps -StateRoot $root)
    if($apps.Count -ne 1 -or $apps[0].repository -ne 'sample-app-v2' -or $apps[0].architecture -ne 'any'){throw 'Registration update created a duplicate or failed to replace fields.'}
    Register-AuApplication -StateRoot $root -AppId 'SecondApp' -Owner 'siny-dev' -Repository 'second-app' -Architecture 'arm64'|Out-Null
    $apps=@(Get-AuRegisteredApps -StateRoot $root)
    if($apps.Count -ne 2 -or $apps[0].app_id -ne 'SampleApp' -or $apps[1].app_id -ne 'SecondApp'){throw 'Registry entries are not returned in stable order.'}
    $rejected=$false
    try{Register-AuApplication -StateRoot $root -AppId '../Bad' -Owner 'siny-dev' -Repository 'bad'|Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'Invalid application identity was accepted.'}
    $raw=Get-Content -Raw -LiteralPath (Join-Path $root 'registry\apps.json')|ConvertFrom-Json
    if($raw.schema -ne 1 -or $raw.apps.Count -ne 2){throw 'Registry JSON schema is malformed.'}
    'PASS: empty registry, atomic register/upsert, sorted multi-app list, and invalid identity rejection'
}finally{Remove-Module AutoUpdate.Core -ErrorAction SilentlyContinue;if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
