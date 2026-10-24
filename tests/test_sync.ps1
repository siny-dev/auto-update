$ErrorActionPreference='Stop'
$GitExe=(Get-Command git.exe -ErrorAction Stop|Select-Object -First 1).Source
$sourceRoot=Split-Path -Parent $PSScriptRoot
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot=Join-Path $tempRoot ('AutoUpdate-sync-test-'+[guid]::NewGuid().ToString('N'))
$bare=Join-Path $testRoot 'remote.git';$seed=Join-Path $testRoot 'seed';$local=Join-Path $testRoot 'local';$other=Join-Path $testRoot 'other'
function Quote-TestArg([string]$Value){if($Value -notmatch '[\s"]'){return $Value};return '"' + $Value.Replace('"','\"') + '"'}
function Invoke-TestGit { param([string]$At,[string[]]$GitArguments)
 $psi=New-Object System.Diagnostics.ProcessStartInfo
 $psi.FileName=$GitExe;$psi.WorkingDirectory=$At
 $psi.Arguments=(($GitArguments)|ForEach-Object{Quote-TestArg ([string]$_)}) -join ' '
 $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 $proc=New-Object System.Diagnostics.Process;$proc.StartInfo=$psi
 if(-not $proc.Start()){throw 'test git process could not start'}
 $outTask=$proc.StandardOutput.ReadToEndAsync();$errTask=$proc.StandardError.ReadToEndAsync();$proc.WaitForExit()
 $code=$proc.ExitCode;$text=$outTask.Result+[char]10+$errTask.Result;$proc.Dispose()
 if($code -ne 0){throw ('git '+($GitArguments -join ' ')+' failed: '+$text)}
 return $text
}
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
try{
 [void][IO.Directory]::CreateDirectory($testRoot)
 Invoke-TestGit -At $testRoot -GitArguments @('init','--bare','--initial-branch=main',$bare)|Out-Null
 Invoke-TestGit -At $testRoot -GitArguments @('clone',$bare,$seed)|Out-Null
 Invoke-TestGit -At $seed -GitArguments @('config','user.name','AutoUpdate Test')|Out-Null
 Invoke-TestGit -At $seed -GitArguments @('config','user.email','autoupdate-test@example.invalid')|Out-Null
 foreach($d in @('source','contracts','packages','channels','tools','tests')){[void][IO.Directory]::CreateDirectory((Join-Path $seed $d))}
 [IO.File]::WriteAllText((Join-Path $seed 'README.md'),'test')
 [IO.File]::WriteAllText((Join-Path $seed '.gitignore'),'state/' + [char]10 + 'logs/')
 Invoke-TestGit -At $seed -GitArguments @('add','--all')|Out-Null;Invoke-TestGit -At $seed -GitArguments @('commit','-m','seed')|Out-Null;Invoke-TestGit -At $seed -GitArguments @('push','origin','main')|Out-Null
 Invoke-TestGit -At $testRoot -GitArguments @('clone',$bare,$local)|Out-Null
 foreach($d in @('source','contracts','packages','channels','tools','tests','logs','state')){[void][IO.Directory]::CreateDirectory((Join-Path $local $d))}
 Copy-Item -LiteralPath (Join-Path $sourceRoot 'tools/sync.ps1') -Destination (Join-Path $local 'tools/sync.ps1')
 Copy-Item -LiteralPath (Join-Path $sourceRoot 'tools/credential-helper.ps1') -Destination (Join-Path $local 'tools/credential-helper.ps1')
 [IO.File]::WriteAllText((Join-Path $local 'source/local.txt'),'local')
 . (Join-Path $local 'tools/sync.ps1') -Once -AllowFileRemote
$syncCode=$global:AutoUpdateSyncLastExit;Check ($syncCode -eq 0) ('local-ahead push failed exit='+$syncCode)
 Invoke-TestGit -At $testRoot -GitArguments @('clone',$bare,$other)|Out-Null
 Invoke-TestGit -At $other -GitArguments @('config','user.name','AutoUpdate Test')|Out-Null;Invoke-TestGit -At $other -GitArguments @('config','user.email','autoupdate-test@example.invalid')|Out-Null
 Check ([IO.File]::Exists((Join-Path $other 'source/local.txt'))) 'local change did not reach remote'
 [IO.File]::WriteAllText((Join-Path $other 'source/remote.txt'),'remote')
 Invoke-TestGit -At $other -GitArguments @('add','--all')|Out-Null;Invoke-TestGit -At $other -GitArguments @('commit','-m','remote change')|Out-Null;Invoke-TestGit -At $other -GitArguments @('push','origin','main')|Out-Null
 . (Join-Path $local 'tools/sync.ps1') -Once -AllowFileRemote
$syncCode=$global:AutoUpdateSyncLastExit;Check ($syncCode -eq 0) ('remote-ahead fast-forward failed exit='+$syncCode)
 [IO.File]::WriteAllText((Join-Path $local 'source/local-diverged.txt'),'local')
 [IO.File]::WriteAllText((Join-Path $other 'source/remote-diverged.txt'),'remote')
 Invoke-TestGit -At $other -GitArguments @('add','--all')|Out-Null;Invoke-TestGit -At $other -GitArguments @('commit','-m','remote divergent')|Out-Null;Invoke-TestGit -At $other -GitArguments @('push','origin','main')|Out-Null
 . (Join-Path $local 'tools/sync.ps1') -Once -AllowFileRemote
Check ($global:AutoUpdateSyncLastExit -eq 34) 'divergence was not stopped'
 Check ([IO.File]::Exists((Join-Path $other 'source/remote-diverged.txt'))) 'remote divergent file was lost'
 $log=[IO.File]::ReadAllText((Join-Path $local 'logs/sync.log'))
 Check ($log.Contains('PUSH_LOCAL completed')) 'push outcome was not logged'
 Check ($log.Contains('PULL_REMOTE completed')) 'pull outcome was not logged'
 Check ($log.Contains('CONFLICT diverged')) 'conflict outcome was not logged'
 'PASS: local push, remote fast-forward pull, and divergence preservation'
}finally{
 $resolved=[IO.Path]::GetFullPath($testRoot)
 if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path -Leaf $resolved).StartsWith('AutoUpdate-sync-test-')){throw 'refusing unsafe test cleanup'}
 if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}