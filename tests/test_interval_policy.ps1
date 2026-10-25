$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\tools\read-update-policy.ps1')
$temp=Join-Path ([IO.Path]::GetTempPath()) ('autoupdate-policy-'+[guid]::NewGuid().ToString('N')+'.json')
try{
    [IO.File]::WriteAllText($temp,'{"schema":1,"interval_minutes":5}',[Text.UTF8Encoding]::new($false))
    if((Get-AuUpdatePolicyInterval -PolicyPath $temp -FallbackMinutes 10) -ne 5){throw 'Five-minute policy was not read.'}
    [IO.File]::WriteAllText($temp,'{"schema":1,"interval_minutes":10}',[Text.UTF8Encoding]::new($false))
    if((Get-AuUpdatePolicyInterval -PolicyPath $temp -FallbackMinutes 5) -ne 10){throw 'Ten-minute policy was not read.'}
    [IO.File]::WriteAllText($temp,'{"schema":1,"interval_minutes":0}',[Text.UTF8Encoding]::new($false))
    if((Get-AuUpdatePolicyInterval -PolicyPath $temp -FallbackMinutes 10) -ne 10){throw 'Invalid policy did not use the safe fallback.'}
}finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
Write-Output 'Shared AutoUpdate interval policy tests passed.'
