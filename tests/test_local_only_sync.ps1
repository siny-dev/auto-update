$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$temp=Join-Path ([IO.Path]::GetTempPath()) ('au-local-only-sync-'+[guid]::NewGuid().ToString('N'))
$tools=Join-Path $temp 'tools';$config=Join-Path $temp 'config'
[void][IO.Directory]::CreateDirectory($tools);[void][IO.Directory]::CreateDirectory($config)
Copy-Item -LiteralPath (Join-Path $repo 'tools\sync.ps1') -Destination (Join-Path $tools 'sync.ps1')
Copy-Item -LiteralPath (Join-Path $repo 'tools\read-update-policy.ps1') -Destination (Join-Path $tools 'read-update-policy.ps1')
[IO.File]::WriteAllText((Join-Path $config 'update-policy.json'),'{"schema":1,"local_only":true}',[Text.UTF8Encoding]::new($false))
try{
    $shell=Join-Path $PSHOME 'powershell.exe'
    if(-not (Test-Path -LiteralPath $shell)){$shell=(Get-Command powershell.exe -ErrorAction Stop|Select-Object -First 1).Source}
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $tools 'sync.ps1'),'-Once')
    $start=New-Object System.Diagnostics.ProcessStartInfo;$start.FileName=$shell
    $start.Arguments=(($arguments|ForEach-Object{'"'+([string]$_).Replace('"','\"')+'"'}) -join ' ')
    $start.WorkingDirectory=$temp;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=New-Object System.Diagnostics.Process;$process.StartInfo=$start
    if(-not $process.Start()){throw 'Could not start the local-only source-sync fixture.'}
    $out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
    $code=$process.ExitCode;$stdout=$out.Result;$stderr=$err.Result;$process.Dispose()
    if($code -ne 0){throw "Local-only source sync exited with code $code $stderr"}
    if($stdout -notmatch 'LOCAL_ONLY'){throw 'Source sync did not report the local-only decision.'}
    if(Test-Path -LiteralPath (Join-Path $temp 'state')){throw 'Source sync touched Git state in local-only mode.'}
    if(Test-Path -LiteralPath (Join-Path $temp 'logs')){throw 'Source sync performed work instead of returning before Git access.'}
    Write-Output 'PASS: local-only source sync exits before git discovery, commit, fetch, or push.'
}finally{
    $resolved=[IO.Path]::GetFullPath($temp);$base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $resolved.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path -Leaf $resolved).StartsWith('au-local-only-sync-')){throw 'Refusing unsafe local-only fixture cleanup.'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
