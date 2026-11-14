param([switch]$Once,[switch]$AllowFileRemote,[ValidateRange(1,1440)][int]$IntervalMinutes=10,[string]$MutexName='Local\AutoUpdateSourceSync',[ValidateRange(0,300000)][int]$SharedLockTimeoutMilliseconds=60000)
$ErrorActionPreference='Stop'
$script:GitExe=(Get-Command git.exe -ErrorAction SilentlyContinue|Select-Object -First 1).Source
if(-not $script:GitExe){$candidate='C:\Program Files\Git\cmd\git.exe';if(Test-Path -LiteralPath $candidate){$script:GitExe=$candidate}}
if(-not $script:GitExe){throw 'git.exe is unavailable'}
if(-not (Get-Command git.exe -ErrorAction SilentlyContinue)){
 $gitCandidates=@('C:\Program Files\Git\cmd\git.exe',(Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe'))
 $gitFound=$gitCandidates|Where-Object{Test-Path -LiteralPath $_}|Select-Object -First 1
 if($gitFound){$env:Path=(Split-Path -Parent $gitFound)+';'+$env:Path}
}
$Root=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'read-update-policy.ps1')
. (Join-Path $PSScriptRoot 'shared-cycle-lock.ps1')
$Logs=Join-Path $Root 'logs'
$LogFile=Join-Path $Logs 'sync.log'
[void][IO.Directory]::CreateDirectory((Join-Path $Root 'state'))
[void][IO.Directory]::CreateDirectory($Logs)
function Write-Log([string]$Message){
 $safe=$Message -replace '(github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+)','[REDACTED]'
 $line='{0} {1}' -f ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')),$safe
 [IO.File]::AppendAllText($LogFile,$line+[char]10,[Text.UTF8Encoding]::new($false))
}
function Quote-ProcessArg([string]$Value){
 if($Value -notmatch '[\s"]'){return $Value}
 return '"' + $Value.Replace('"','\"') + '"'
}
function Invoke-Git([string[]]$GitArgs,[switch]$Network){
 $safeRoot=if($Root.StartsWith('\\',[StringComparison]::Ordinal)){'%(prefix)///'+$Root.TrimStart([char[]]@('\')).Replace('\','/')}else{$Root}
 $effectiveGitArgs=@('-c',('safe.directory='+$safeRoot))+$GitArgs
 $helperArgs=@()
 if($Network){
  $powershellExe=Join-Path $PSHOME 'pwsh.exe'
  if(-not (Test-Path -LiteralPath $powershellExe)){$powershellExe=Join-Path $PSHOME 'powershell.exe'}
  if(-not (Test-Path -LiteralPath $powershellExe)){$powershellExe=(Get-Command pwsh.exe,powershell.exe -ErrorAction Stop|Select-Object -First 1).Source}
  $helper='!' + '"' + $powershellExe + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tools/credential-helper.ps1'
  $helperArgs=@('-c','credential.helper=','-c',('credential.helper='+$helper),'-c','credential.interactive=never')
 }
 $psi=New-Object System.Diagnostics.ProcessStartInfo
 $psi.FileName=$script:GitExe
 $psi.WorkingDirectory=$Root
 $psi.Arguments=(($helperArgs+$effectiveGitArgs)|ForEach-Object{Quote-ProcessArg ([string]$_)}) -join ' '
 $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
 $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT']='0'
 $psi.EnvironmentVariables['GCM_INTERACTIVE']='Never'
 $proc=New-Object System.Diagnostics.Process
 $proc.StartInfo=$psi
 if(-not $proc.Start()){return [pscustomobject]@{Code=127;Text='git process could not start'}}
 $outTask=$proc.StandardOutput.ReadToEndAsync();$errTask=$proc.StandardError.ReadToEndAsync()
 $proc.WaitForExit()
 $text=$outTask.Result+[char]10+$errTask.Result
 $exit=$proc.ExitCode;$proc.Dispose()
 $text=$text -replace '(github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+)','[REDACTED]'
 return [pscustomobject]@{Code=$exit;Text=$text.Trim()}
}
function Sync-Once{
 if(Get-AuUpdatePolicyLocalOnly -PolicyPath (Join-Path $Root 'config\update-policy.json')){Write-Log 'LOCAL_ONLY source synchronization is disabled';return 0}
 $branch=Invoke-Git @('branch','--show-current')
 if($branch.Code -ne 0 -or $branch.Text.Trim() -ne 'main'){Write-Log 'STOP branch must be main';return 20}
 $remote=Invoke-Git @('remote','get-url','origin')
 if($remote.Code -ne 0 -or [string]::IsNullOrWhiteSpace($remote.Text)){Write-Log 'STOP origin remote is not configured';return 21}
    $remoteUrl=$remote.Text.Trim()
    if($remoteUrl -match '^https?://[^/]*@' -or ($remoteUrl -notmatch '^(https://github\.com/|git@github\.com:)' -and -not $AllowFileRemote)){Write-Log 'STOP origin must be a GitHub URL without embedded credentials';return 21}
 $status=Invoke-Git @('status','--porcelain')
 if($status.Code -ne 0){Write-Log 'STOP git status failed';return 22}
 if(-not [string]::IsNullOrWhiteSpace($status.Text)){
  $name=Invoke-Git @('config','user.name')
  if($name.Code -ne 0 -or [string]::IsNullOrWhiteSpace($name.Text)){[void](Invoke-Git @('config','user.name','AutoUpdate Sync'))}
  $email=Invoke-Git @('config','user.email')
  if($email.Code -ne 0 -or [string]::IsNullOrWhiteSpace($email.Text)){[void](Invoke-Git @('config','user.email','autoupdate-sync@users.noreply.github.com'))}
  $stagePaths=@('README.md','.gitignore','.github/workflows','source','contracts','packages','channels','config','tools','tests')|Where-Object{Test-Path -LiteralPath (Join-Path $Root $_)}
  $stage=Invoke-Git (@('add','--')+$stagePaths)
  if($stage.Code -ne 0){Write-Log ('STOP stage failed: '+$stage.Text);return 23}
  $staged=Invoke-Git @('diff','--cached','--quiet')
  if($staged.Code -eq 1){
   $commit=Invoke-Git @('commit','-m',('AutoUpdate sync '+[DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss UTC')))
   if($commit.Code -ne 0){Write-Log ('STOP local commit failed: '+$commit.Text);return 24}
   Write-Log 'LOCAL_COMMIT created'
  }elseif($staged.Code -ne 0){Write-Log 'STOP staged diff check failed';return 25}
 }
 $head=Invoke-Git @('rev-parse','--verify','HEAD')
 if($head.Code -ne 0){Write-Log 'STOP local repository has no initial commit';return 26}
 $remoteMain=Invoke-Git @('ls-remote','--exit-code','--heads','origin','main') -Network
 if($remoteMain.Code -eq 2 -and [string]::IsNullOrWhiteSpace($remoteMain.Text)){
  $push=Invoke-Git @('push','-u','origin','main') -Network
  if($push.Code -eq 0){Write-Log 'PUSH_INITIAL completed';return 0}
  Write-Log ('SYNC_RETRY initial push failed: '+$push.Text);return 27
 }
 if($remoteMain.Code -ne 0){Write-Log ('SYNC_RETRY remote check failed: '+$remoteMain.Text);return 28}
 $fetch=Invoke-Git @('fetch','--prune','origin','main') -Network
 if($fetch.Code -ne 0){Write-Log ('SYNC_RETRY fetch failed: '+$fetch.Text);return 29}
 $counts=Invoke-Git @('rev-list','--left-right','--count','HEAD...origin/main')
 if($counts.Code -ne 0){Write-Log 'STOP commit graph comparison failed';return 30}
 $parts=$counts.Text.Trim() -split '\s+'
 if($parts.Count -ne 2){Write-Log 'STOP malformed commit graph result';return 31}
 $ahead=[int]$parts[0];$behind=[int]$parts[1]
 if($ahead -eq 0 -and $behind -eq 0){Write-Log 'SYNC_EQUAL no changes';return 0}
 if($ahead -gt 0 -and $behind -eq 0){
  $push=Invoke-Git @('push','origin','main') -Network
  if($push.Code -eq 0){Write-Log ('PUSH_LOCAL completed commits='+$ahead);return 0}
  Write-Log ('SYNC_RETRY push failed: '+$push.Text);return 32
 }
 if($ahead -eq 0 -and $behind -gt 0){
  $pull=Invoke-Git @('merge','--ff-only','origin/main')
  if($pull.Code -eq 0){Write-Log ('PULL_REMOTE completed commits='+$behind);return 0}
  Write-Log ('STOP fast-forward failed: '+$pull.Text);return 33
 }
 Write-Log ('CONFLICT diverged local='+$ahead+' remote='+$behind+'; both histories preserved')
 return 34
}
function Test-IgnoredChange([string]$FullPath){
 $relative=$FullPath.Substring([Math]::Min($FullPath.Length,$Root.Length)).TrimStart([char[]]@('\','/')).ToLowerInvariant()
 return $relative.StartsWith('.git\') -or $relative.StartsWith('state\') -or $relative.StartsWith('logs\') -or $relative.StartsWith('outbox\') -or $relative -eq '.git'
}
function Wait-ForSyncTrigger([int]$PollSeconds,[int]$DebounceSeconds){
 $deadline=(Get-Date).AddSeconds([Math]::Max(1,$PollSeconds));$lastChange=$null
 do{
  $now=Get-Date;$remaining=[int][Math]::Ceiling(($deadline-$now).TotalSeconds)
  if($remaining -le 0){return $false}
  if($lastChange){$stable=[int][Math]::Ceiling(($lastChange.AddSeconds($DebounceSeconds)-$now).TotalSeconds);if($stable -le 0){return $true};$remaining=[Math]::Min($remaining,$stable)}
  $event=Wait-Event -Timeout ([Math]::Max(1,$remaining))
  if($event){
   $path=$event.SourceEventArgs.FullPath
   Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
   if($path -and -not (Test-IgnoredChange $path)){$lastChange=Get-Date}
  }
 }while($true)
}
$dotSourced=($MyInvocation.InvocationName -eq '.')
$mutex=[Threading.Mutex]::new($false,$MutexName);$owned=$false;$code=0;$retryMinutes=1;$watcher=$null;$subscriptions=@()
try{
 try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
 if(-not $owned){Write-Log 'SKIP another sync worker is active';$code=0}
 else{
  if(-not $Once){
   try{
    $watcher=New-Object System.IO.FileSystemWatcher
    $watcher.Path=$Root;$watcher.Filter='*';$watcher.IncludeSubdirectories=$true
    $watcher.NotifyFilter=[IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size
    $watcher.InternalBufferSize=32768;$watcher.EnableRaisingEvents=$true
    foreach($name in @('Changed','Created','Deleted','Renamed')){
     $id='AutoUpdateSourceSync.'+$name
     Register-ObjectEvent -InputObject $watcher -EventName $name -SourceIdentifier $id | Out-Null
     $subscriptions+=$id
    }
   }catch{Write-Log 'WATCHER unavailable; periodic checks remain enabled';if($watcher){$watcher.Dispose();$watcher=$null}}
  }
  do{
   $sharedLock=$null
   try{
    $sharedLockPath=Join-Path $Root 'outbox\locks\source-sync.lock'
    $sharedLock=Enter-AuSharedCycleLock -Path $sharedLockPath -TimeoutMilliseconds $SharedLockTimeoutMilliseconds
    if($null -eq $sharedLock){Write-Log 'SKIP shared source-sync lock timeout; retry at next interval';$code=36}
    else{try{$code=Sync-Once}finally{Exit-AuSharedCycleLock -LockHandle $sharedLock}}
   }catch{Write-Log ('SYNC_RETRY unexpected error: '+$_.Exception.GetType().Name);if($Once){$code=35}}
   if($Once){break}
   if($code -eq 0){$delayMinutes=Get-AuUpdatePolicyInterval -PolicyPath (Join-Path $Root 'config\update-policy.json') -FallbackMinutes $IntervalMinutes;$retryMinutes=1}
   else{$delayMinutes=$retryMinutes;$retryMinutes=[Math]::Min(30,$retryMinutes*2)}
   $delaySeconds=[Math]::Min(1800,$delayMinutes*60)
   if($code -ne 0){$jitter=[Math]::Max(1,[int]($delaySeconds*0.15));$delaySeconds=[Math]::Max(1,[Math]::Min(1800,$delaySeconds+(Get-Random -Minimum (-$jitter) -Maximum ($jitter+1))))}
   if($watcher){[void](Wait-ForSyncTrigger $delaySeconds 90)}else{Start-Sleep -Seconds $delaySeconds}
  }while(-not $Once)
 }
}finally{
 foreach($id in $subscriptions){Unregister-Event -SourceIdentifier $id -ErrorAction SilentlyContinue;Get-Event -SourceIdentifier $id -ErrorAction SilentlyContinue|Remove-Event -ErrorAction SilentlyContinue}
 if($watcher){$watcher.EnableRaisingEvents=$false;$watcher.Dispose()}
 if($owned){$mutex.ReleaseMutex()}
 $mutex.Dispose()
}
if($dotSourced){$global:AutoUpdateSyncLastExit=$code;return}
exit $code
