$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'source\AutoUpdate.Core.psm1') -Force
$module=Get-Module -Name AutoUpdate.Core
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$now=[DateTimeOffset]::new(2026,10,26,0,0,0,[TimeSpan]::Zero)
$reset=$now.ToUnixTimeSeconds()+90
$primary=& $module {param($time,$epoch) Get-AuGitHubRateLimitDelaySeconds -StatusCode 403 -RateLimitRemaining '0' -RateLimitReset ([string]$epoch) -NowUtc $time} $now $reset
Assert ($primary -eq 90) 'Primary rate limit did not wait for X-RateLimit-Reset.'
$retryHeader=& $module {param($time,$epoch) Get-AuGitHubRateLimitDelaySeconds -StatusCode 429 -RetryAfter '45' -RateLimitRemaining '0' -RateLimitReset ([string]$epoch) -NowUtc $time} $now ($reset+1000)
Assert ($retryHeader -eq 45) 'Retry-After did not take precedence over the later reset time.'
$secondary1=& $module {param($time) Get-AuGitHubRateLimitDelaySeconds -StatusCode 403 -RateLimitIndicated -RetryNumber 1 -NowUtc $time} $now
$secondary2=& $module {param($time) Get-AuGitHubRateLimitDelaySeconds -StatusCode 403 -RateLimitIndicated -RetryNumber 2 -NowUtc $time} $now
$secondary3=& $module {param($time) Get-AuGitHubRateLimitDelaySeconds -StatusCode 429 -RetryNumber 3 -NowUtc $time} $now
Assert ($secondary1 -eq 60 -and $secondary2 -eq 120 -and $secondary3 -eq 240) 'Secondary rate limits did not use at-least-one-minute exponential backoff.'
$permission=& $module {param($time) Get-AuGitHubRateLimitDelaySeconds -StatusCode 403 -RateLimitRemaining '100' -NowUtc $time} $now
Assert ($null -eq $permission) 'A normal permission-related 403 was misclassified as a rate limit.'
$notLimited=& $module {param($time) Get-AuGitHubRateLimitDelaySeconds -StatusCode 404 -NowUtc $time} $now
Assert ($null -eq $notLimited) 'A non-rate-limit response was classified for retry.'
Remove-Module AutoUpdate.Core -ErrorAction SilentlyContinue
'PASS: primary reset, Retry-After precedence, secondary exponential backoff, and non-rate-limit 403 handling'