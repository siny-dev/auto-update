$ErrorActionPreference='Stop'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('autoupdate-publish-plan-'+[guid]::NewGuid().ToString('N'))
$modulePath=Join-Path (Split-Path -Parent $PSScriptRoot) 'source\AutoUpdate.Core.psm1'
New-Item -ItemType Directory -Force -Path (Join-Path $testRoot 'payload\data')|Out-Null
$payloadPath=Join-Path $testRoot 'payload\data\notice.json';[IO.File]::WriteAllText($payloadPath,'{"test":true}')
$hash=(Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant();$size=(Get-Item -LiteralPath $payloadPath).Length
$manifest=[pscustomobject]@{app_id='demo';version='1.0.0';mode='live';platform='windows';architecture='any';minimum_engine='0.1.0';publisher_policy='github-release-asset-https';schema=1;contract='autoupdate-app-v1';files=@([pscustomobject]@{path='data/notice.json';kind='resource';size=$size;sha256=$hash;source='payload/data/notice.json';asset='asset_data_notice_json'})}
[IO.File]::WriteAllText((Join-Path $testRoot 'manifest.json'),($manifest|ConvertTo-Json -Depth 8))
[IO.File]::WriteAllText((Join-Path $testRoot 'autoupdate-manifest.json'),($manifest|ConvertTo-Json -Depth 8))
$module=Import-Module $modulePath -Force -PassThru
try{
    $plan=@(Get-AuReleaseUploadPlan -PackageRoot $testRoot -Manifest $manifest)
    if($plan.Count -ne 2 -or $plan[0].Name -cne 'autoupdate-manifest.json' -or $plan[1].Name -cne 'asset_data_notice_json'){throw 'Release upload plan does not preserve manifest asset names.'}
    if((Get-FileHash -LiteralPath $plan[1].Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hash){throw 'Release upload plan points at the wrong payload file.'}
    $manifest.files[0].asset='autoupdate-manifest.json'
    $failed=$false;try{Get-AuReleaseUploadPlan -PackageRoot $testRoot -Manifest $manifest|Out-Null}catch{$failed=$true}
    if(-not $failed){throw 'Duplicate release asset names were accepted.'}
    'PASS: local release upload plan maps verified package files to declared asset names and rejects duplicates'
}finally{
    Remove-Module AutoUpdate.Core -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
