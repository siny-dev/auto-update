function Get-AuUpdatePolicyInterval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$PolicyPath,
        [ValidateRange(1,1440)][int]$FallbackMinutes=10
    )
    try {
        $policy=Get-Content -Raw -LiteralPath $PolicyPath | ConvertFrom-Json
        if($policy.schema -ne 1){return $FallbackMinutes}
        $raw=[string]$policy.interval_minutes
        if($raw -notmatch '^\d{1,4}$'){return $FallbackMinutes}
        $minutes=[int]$raw
        if($minutes -lt 1 -or $minutes -gt 1440){return $FallbackMinutes}
        return $minutes
    } catch { return $FallbackMinutes }
}

function Get-AuUpdatePolicyLocalOnly {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PolicyPath)
    if(-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)){return $false}
    try {
        $policy=Get-Content -Raw -LiteralPath $PolicyPath | ConvertFrom-Json
        if($policy.schema -ne 1){return $true}
        if(-not $policy.PSObject.Properties['local_only']){return $false}
        if($policy.local_only -isnot [bool]){return $true}
        return $policy.local_only
    } catch { return $true }
}
