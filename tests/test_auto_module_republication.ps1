$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-module-republication-'+[guid]::NewGuid().ToString('N'))
$fixtureRoot=Join-Path $tempRoot 'repo'
$fixtureTools=Join-Path $fixtureRoot 'tools'
$fixtureSource=Join-Path $fixtureRoot 'source'
$publishedRoot=Join-Path $tempRoot 'published-modules'
$stateRoot=Join-Path $tempRoot 'state'

function Quote-ProcessArgument([string]$Value){
    if($Value -notmatch '[\s"]'){return $Value}
    return '"'+$Value.Replace('"','\"')+'"'
}

function Invoke-FixtureModuleSync([string]$ScriptPath,[string]$State,[string]$Modules){
    $shell=(Get-Process -Id $PID).Path
    if(-not $shell){throw 'Could not identify the PowerShell executable.'}
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=$shell
    $psi.Arguments=( @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$ScriptPath,'-StateRoot',$State,'-ModuleSourceRoot',$Modules) | ForEach-Object { Quote-ProcessArgument ([string]$_) } ) -join ' '
    $psi.UseShellExecute=$false
    $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT']='0'
    $process=[Diagnostics.Process]::new()
    $process.StartInfo=$psi
    if(-not $process.Start()){throw 'Could not start the isolated module sync process.'}
    $stdout=$process.StandardOutput.ReadToEndAsync()
    $stderr=$process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $output=$stdout.Result+[Environment]::NewLine+$stderr.Result
    $exitCode=$process.ExitCode
    $process.Dispose()
    if($exitCode -ne 0){throw "Module sync exited $exitCode`: $output"}
    $jsonLine=@($output -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') -and $_.Trim().EndsWith('}') } | Select-Object -Last 1)
    if($jsonLine.Count -ne 1){throw "Module sync returned no JSON result: $output"}
    return ($jsonLine[0] | ConvertFrom-Json -ErrorAction Stop)
}

try{
    [void][IO.Directory]::CreateDirectory($fixtureTools)
    [void][IO.Directory]::CreateDirectory($fixtureSource)
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools\sync-core-module.ps1') -Destination $fixtureTools
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools\build-module-package.ps1') -Destination $fixtureTools
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools\autoupdate.ps1') -Destination $fixtureTools
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools\resolve_modules.py') -Destination $fixtureTools
    Copy-Item -LiteralPath (Join-Path $repoRoot 'source\AutoUpdate.Core.psm1') -Destination $fixtureSource

    $syncScript=Join-Path $fixtureTools 'sync-core-module.ps1'
    $first=Invoke-FixtureModuleSync $syncScript $stateRoot $publishedRoot
    if($first.status -cne 'published' -or $first.version -cne '1.0.0' -or $first.cache_status -cne 'activated'){
        throw 'Initial AutoUpdate module sync did not publish and activate version 1.0.0 in the local PC cache.'
    }
    $localPointer=Get-Content -Raw -LiteralPath (Join-Path $stateRoot 'modules\AutoUpdate\current.json')|ConvertFrom-Json
    if($localPointer.version -cne '1.0.0'){throw 'Initial module publication did not update the local PC cache pointer.'}

    $unchanged=Invoke-FixtureModuleSync $syncScript $stateRoot $publishedRoot
    if($unchanged.status -cne 'unchanged' -or $unchanged.version -cne '1.0.0' -or $unchanged.cache_status -cne 'already-cached'){
        throw 'An unchanged AutoUpdate module source failed to confirm the local cache or created a redundant version.'
    }

    $corePath=Join-Path $fixtureSource 'AutoUpdate.Core.psm1'
    [IO.File]::AppendAllText($corePath,"`n# isolated module source change`n",[Text.UTF8Encoding]::new($false))
    $changed=Invoke-FixtureModuleSync $syncScript $stateRoot $publishedRoot
    if($changed.status -cne 'published' -or $changed.version -cne '1.0.1' -or $changed.cache_status -cne 'activated'){
        throw 'A changed AutoUpdate module source did not publish and activate the next patch in the local PC cache.'
    }
    $localPointer=Get-Content -Raw -LiteralPath (Join-Path $stateRoot 'modules\AutoUpdate\current.json')|ConvertFrom-Json
    if($localPointer.version -cne '1.0.1'){throw 'Changed module publication did not advance the local PC cache pointer.'}

    $moduleRoot=Join-Path $publishedRoot 'AutoUpdate'
    $pointer=Get-Content -Raw -LiteralPath (Join-Path $moduleRoot 'current.json') | ConvertFrom-Json
    if($pointer.version -cne '1.0.1' -or -not (Test-Path -LiteralPath (Join-Path $moduleRoot 'versions\1.0.0') -PathType Container)){
        throw 'Module activation did not advance atomically while preserving the prior immutable version.'
    }
    Write-Output 'PASS: unchanged sources keep their version; changed AutoUpdate sources publish, activate in the local PC cache, and preserve prior versions.'
}finally{
    $full=[IO.Path]::GetFullPath($tempRoot)
    $tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($full.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase)-and (Test-Path -LiteralPath $full)){
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
}
