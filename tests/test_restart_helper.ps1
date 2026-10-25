param([string]$HelperPath)
$ErrorActionPreference='Stop'
$module=Join-Path $PSScriptRoot '..\source\AutoUpdate.Core.psm1'
if(-not $HelperPath){$HelperPath=Join-Path $PSScriptRoot '..\tools\restart-apply.ps1'}
$helper=[IO.Path]::GetFullPath($HelperPath)
Import-Module $module -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdateRestartTest-'+[guid]::NewGuid().ToString('N'))
$systemPowerShell=(Get-Command powershell.exe -ErrorAction Stop).Source
$oldExe=Join-Path $env:WINDIR 'System32\where.exe'
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function New-Package([string]$Version){
    $package=Join-Path $root ('package-'+$Version);$payload=Join-Path $package 'payload';[void][IO.Directory]::CreateDirectory($payload)
    $exe=Join-Path $payload 'demo.exe';[IO.File]::Copy($systemPowerShell,$exe,$false)
    $manifest=[ordered]@{schema=1;contract='autoupdate-app-v1';app_id='restart-demo';version=$Version;mode='restart';platform='windows';architecture='x64';minimum_engine='0.1.0';publisher_policy='github-release-asset-https';files=@(@{path='demo.exe';kind='executable';size=(Get-Item $exe).Length;sha256=(Get-AuFileSha256 $exe);source='payload/demo.exe';asset='demo_exe'})}
    [IO.File]::WriteAllText((Join-Path $package 'manifest.json'),($manifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false));return $package
}
function Invoke-Helper([string]$PackagePath,[string]$ScriptPath,[string]$Target,[int]$ExpectedExit){
    $driver=Join-Path $root ('driver-'+[guid]::NewGuid().ToString('N')+'.ps1')
    $stdout=$driver+'.out';$stderr=$driver+'.err';$state=Join-Path $root 'resume.json'
    $command="& '$helper' -AppId 'restart-demo' -StateRoot '$root\state' -PackagePath '$PackagePath' -EntryRelativePath 'demo.exe' -TargetPath '$Target' -StateFile '$state' -Architecture x64 -HealthTimeoutSeconds 3 -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File','$ScriptPath')"
    [IO.File]::WriteAllText($driver,$command,[Text.UTF8Encoding]::new($true))
    $proc=Start-Process -FilePath $systemPowerShell -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$driver) -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if($ExpectedExit -ge 0 -and $proc.ExitCode -ne $ExpectedExit){$out=if(Test-Path $stdout){Get-Content -Raw $stdout}else{''};$err=if(Test-Path $stderr){Get-Content -Raw $stderr}else{''};throw "Restart helper exit $($proc.ExitCode), expected $ExpectedExit. $out $err"}
    return @{stdout=$stdout;stderr=$stderr}
}
try{
    [void][IO.Directory]::CreateDirectory($root);[void][IO.Directory]::CreateDirectory((Join-Path $root 'state'))
    $state=Join-Path $root 'resume.json';[IO.File]::WriteAllText($state,'{"screen":"settings","draft":"preserve"}',[Text.UTF8Encoding]::new($false))
    $ack=Join-Path $root 'ack.ps1'
    $ackSource=@"
`$healthIndex=[Array]::IndexOf([string[]]`$args,'--autoupdate-health')
`$versionIndex=[Array]::IndexOf([string[]]`$args,'--autoupdate-version')
if(`$healthIndex -lt 0 -or `$versionIndex -lt 0){exit 10}
[IO.File]::WriteAllText(`$args[`$healthIndex+1],`$args[`$versionIndex+1],[Text.UTF8Encoding]::new(`$false))
"@
    [IO.File]::WriteAllText($ack,$ackSource,[Text.UTF8Encoding]::new($false))
    $noAck=Join-Path $root 'no-ack.ps1';[IO.File]::WriteAllText($noAck,'exit 0',[Text.UTF8Encoding]::new($false))
    $package1=New-Package '1.0.0';Install-AuPackage -PackageRoot $package1 -StateRoot (Join-Path $root 'state') -AppId restart-demo -Architecture x64|Out-Null
    $target=Join-Path $root 'install\demo.exe';[void][IO.Directory]::CreateDirectory((Split-Path -Parent $target));[IO.File]::Copy($oldExe,$target,$false)
    $success=Invoke-Helper (Join-Path $root 'state\apps\restart-demo\versions\1.0.0') $ack $target 0
    $ok=Get-Content -Raw $success.stdout|ConvertFrom-Json;Assert ($ok.status -eq 'confirmed') ('restart helper did not confirm healthy process: '+(Get-Content -Raw $success.stdout)+' ERR '+(Get-Content -Raw $success.stderr))
    $packageExe=Join-Path $root 'state\apps\restart-demo\versions\1.0.0\demo.exe';Assert ((Get-AuFileSha256 $target) -eq (Get-AuFileSha256 $packageExe)) 'restart helper did not replace target with the verified executable'
    $package2=New-Package '1.0.1';Install-AuPackage -PackageRoot $package2 -StateRoot (Join-Path $root 'state') -AppId restart-demo -Architecture x64|Out-Null
    [IO.File]::Copy($oldExe,$target,$true);$oldHash=Get-AuFileSha256 $target
    $rollback=Invoke-Helper (Join-Path $root 'state\apps\restart-demo\versions\1.0.1') $noAck $target -1
    $rolled=Get-Content -Raw $rollback.stdout|ConvertFrom-Json;Assert ($rolled.status -eq 'rolled-back') 'restart helper did not report rollback after missing health acknowledgement'
    Assert ((Get-AuFileSha256 $target) -eq $oldHash) 'restart helper did not restore the prior executable after rollback'
    Assert ((Get-Content -Raw $state) -match 'settings' -and (Get-Content -Raw $state) -match 'preserve') 'restart helper modified saved user state'
    'PASS: restart helper confirms after health acknowledgement and restores old executable on failed startup'
}finally{Remove-Module AutoUpdate.Core -ErrorAction SilentlyContinue;if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}