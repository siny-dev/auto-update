$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$module=Join-Path $repoRoot 'source\AutoUpdate.Core.psm1'
$cli=Join-Path $repoRoot 'tools\autoupdate.ps1'
$builder=Join-Path $repoRoot 'tools\build-module-package.ps1'
Import-Module $module -Force
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-module-test-'+[guid]::NewGuid().ToString('N'))
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function New-ModuleSource([string]$Name,[string]$Body){$path=Join-Path $testRoot ('source-'+$Name);[void][IO.Directory]::CreateDirectory($path);[IO.File]::WriteAllText((Join-Path $path 'module.psm1'),$Body,[Text.UTF8Encoding]::new($false));return $path}
function Build-Module([string]$Version,[int]$ApiMajor,[string]$Body,[string]$ModuleId='SharedLib'){
    $source=New-ModuleSource ($Version.Replace('.','-')+'-'+$ApiMajor) $Body
    $package=Join-Path $testRoot ('package-'+$Version+'-'+$ApiMajor+'-'+[guid]::NewGuid().ToString('N'))
    & $builder -ModuleId $ModuleId -Version $Version -ApiMajor $ApiMajor -SourceRoot $source -OutputRoot $package -ActivationMode restart|Out-Null
    return $package
}
function Write-AppManifest([int]$ApiMajor){
    $path=Join-Path $testRoot ('app-api-'+$ApiMajor+'.json')
    $app=[ordered]@{schema=1;contract='autoupdate-app-modules-v1';app_id='module-test-app';modules=@(@{module_id='SharedLib';api_major=$ApiMajor})}
    [IO.File]::WriteAllText($path,($app|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    return $path
}
function Quote-ProcessArgument([string]$Value){'"'+$Value.Replace('"','\"')+'"'}
function Invoke-JsonProcess([string[]]$Arguments){
    $exe=(Get-Command pwsh.exe -ErrorAction Stop).Source
    $start=New-Object System.Diagnostics.ProcessStartInfo;$start.FileName=$exe;$start.Arguments=(($Arguments|ForEach-Object{Quote-ProcessArgument ([string]$_)}) -join ' ');$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=New-Object System.Diagnostics.Process;$process.StartInfo=$start
    if(-not $process.Start()){throw 'Could not start a module CLI test process.'}
    $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync();$process.WaitForExit();$result=[pscustomobject]@{ExitCode=$process.ExitCode;StdOut=$stdoutTask.Result;StdErr=$stderrTask.Result};$process.Dispose();return $result
}
try{
    [void][IO.Directory]::CreateDirectory($testRoot)
    $sourceRoot=Join-Path $testRoot 'published';$state=Join-Path $testRoot 'state'
    $p100=Build-Module '1.0.0' 1 'function Get-SharedValue { "one" }'
    $lockPath=Join-Path (Join-Path $sourceRoot 'locks') 'SharedLib.publish.lock';[void][IO.Directory]::CreateDirectory((Split-Path -Parent $lockPath))
$heldLock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
    $blocked=$false;try{Publish-AuLocalModulePackage -PackageRoot $p100 -ModuleSourceRoot $sourceRoot -ModuleId SharedLib -LockTimeoutMilliseconds 0|Out-Null}catch{$blocked=$_.Exception.Message -like 'Another publisher*'}
    Assert $blocked 'Concurrent module publication was not blocked.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'SharedLib/current.json'))) 'Blocked publication changed the module pointer.'
}finally{$heldLock.Dispose()}
$publish=Publish-AuLocalModulePackage -PackageRoot $p100 -ModuleSourceRoot $sourceRoot -ModuleId SharedLib
    Assert ($publish.Status -eq 'published') 'Initial module version did not publish.'
    $appV1=Write-AppManifest 1
    $resolved=Resolve-AuAppModules -AppManifestPath $appV1 -ModuleSourceRoot $sourceRoot -StateRoot $state
    Assert ($resolved.modules[0].delivery_level -eq 'L1' -and $resolved.modules[0].runtime_state -eq 'not-reported') 'Module resolution claimed activation before the app reported loading it.'
    $loadedStatus=Set-AuModuleRuntimeStatus -StateRoot $state -AppId module-test-app -ModuleId SharedLib -Version 1.0.0 -RuntimeState loaded
    Assert ($loadedStatus.delivery_level -eq 'L2') 'Loaded module status did not report L2.'
    $activeStatus=Set-AuModuleRuntimeStatus -StateRoot $state -AppId module-test-app -ModuleId SharedLib -Version 1.0.0 -RuntimeState active
    Assert ($activeStatus.delivery_level -eq 'L3') 'Active module status did not report L3.'
    $runtimeRows=@(Get-AuModuleRuntimeStatus -StateRoot $state -AppId module-test-app -ModuleId SharedLib)
    Assert ($runtimeRows.Count -eq 1 -and $runtimeRows[0].runtime_state -eq 'active' -and $runtimeRows[0].process_alive) 'Runtime status did not preserve the current process and active version.'
    Assert ($resolved.status -eq 'ready' -and $resolved.modules[0].version -eq '1.0.0' -and $resolved.modules[0].verified) 'First module resolve did not return the verified published version.'
    Assert (Test-Path -LiteralPath (Join-Path $resolved.modules[0].module_path 'module.psm1')) 'Resolved cache path does not contain module payload.'
    $repeat=Resolve-AuAppModules -AppManifestPath $appV1 -ModuleSourceRoot $sourceRoot -StateRoot $state
    Assert ($repeat.modules[0].source_status -eq 'already-cached') 'A second resolve did not reuse the common PC cache.'

    $p110=Build-Module '1.1.0' 1 'function Get-SharedValue { "one point one" }'
    Assert ((Publish-AuLocalModulePackage -PackageRoot $p110 -ModuleSourceRoot $sourceRoot -ModuleId SharedLib).Status -eq 'published') 'Compatible update did not publish.'
    $p200=Build-Module '2.0.0' 2 'function Get-SharedValue { "two" }'
    Assert ((Publish-AuLocalModulePackage -PackageRoot $p200 -ModuleSourceRoot $sourceRoot -ModuleId SharedLib).Status -eq 'published') 'New API major did not publish.'
    $oldApp=Resolve-AuAppModules -AppManifestPath $appV1 -ModuleSourceRoot $sourceRoot -StateRoot $state
    Assert ($oldApp.modules[0].version -eq '1.1.0' -and $oldApp.modules[0].api_major -eq 1) 'New API major displaced the newest compatible module.'
    $appV2=Write-AppManifest 2
    $newApp=Resolve-AuAppModules -AppManifestPath $appV2 -ModuleSourceRoot $sourceRoot -StateRoot $state
    Assert ($newApp.modules[0].version -eq '2.0.0' -and $newApp.modules[0].api_major -eq 2) 'New API client did not resolve the new module major.'

    $p210=Build-Module '2.1.0' 2 'function Get-SharedValue { "failure test" }'
    $failed=$false;try{Install-AuModulePackage -PackageRoot $p210 -StateRoot $state -ModuleId SharedLib -FailActivationForTest|Out-Null}catch{$failed=$true}
    Assert $failed 'Injected module activation failure was ignored.'
    Assert ((Get-AuCurrentModule -StateRoot $state -ModuleId SharedLib).Version -eq '2.0.0') 'Failed install changed the active module pointer.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $state 'modules/SharedLib/versions/2.1.0'))) 'Failed install left a partial immutable module folder.'

    $tampered=Build-Module '2.2.0' 2 'function Get-SharedValue { "tamper" }'
    [IO.File]::WriteAllText((Join-Path $tampered 'payload/module.psm1'),'changed',[Text.UTF8Encoding]::new($false))
    $failed=$false;try{Publish-AuLocalModulePackage -PackageRoot $tampered -ModuleSourceRoot $sourceRoot -ModuleId SharedLib|Out-Null}catch{$failed=$true}
    Assert $failed 'Publisher accepted a payload whose hash did not match its manifest.'

    $conflict=Build-Module '2.0.0' 2 'function Get-SharedValue { "different same version" }'
    $conflictResult=Publish-AuLocalModulePackage -PackageRoot $conflict -ModuleSourceRoot $sourceRoot -ModuleId SharedLib
    Assert ($conflictResult.Status -eq 'conflict') 'Different contents under a published version were not reported as a conflict.'
    Assert ((Get-AuCurrentModule -StateRoot $state -ModuleId SharedLib).Version -eq '2.0.0') 'Same-version conflict affected the cached active pointer.'

    $cliPackage=Build-Module '3.0.0' 3 'function Get-SharedValue { "cli" }' 'CliLib'
    $publishArgs=@('-NoLogo','-NoProfile','-NonInteractive','-File',$cli,'-Command','publish-module','-ModuleId','CliLib','-PackageRoot',$cliPackage,'-ModuleSourceRoot',$sourceRoot)
    $cliPublish=Invoke-JsonProcess $publishArgs
    Assert ($cliPublish.ExitCode -eq 0 -and ($cliPublish.StdOut|ConvertFrom-Json).Status -eq 'published') 'publish-module CLI did not publish a module.'
    $cliAppPath=Join-Path $testRoot 'cli-app.json'
    $cliApp=[ordered]@{schema=1;contract='autoupdate-app-modules-v1';app_id='cli-module-app';modules=@(@{module_id='CliLib';api_major=3})}
    [IO.File]::WriteAllText($cliAppPath,($cliApp|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $resolveArgs=@('-NoLogo','-NoProfile','-NonInteractive','-File',$cli,'-Command','resolve-modules','-AppManifestPath',$cliAppPath,'-ModuleSourceRoot',$sourceRoot,'-StateRoot',(Join-Path $testRoot 'cli-state'))
    $cliResolve=Invoke-JsonProcess $resolveArgs
    Assert ($cliResolve.ExitCode -eq 0 -and ($cliResolve.StdOut|ConvertFrom-Json).modules[0].version -eq '3.0.0') 'resolve-modules CLI did not resolve the published module.'
    $reportArgs=@('-NoLogo','-NoProfile','-NonInteractive','-File',$cli,'-Command','report-module-status','-AppId','cli-module-app','-ModuleId','CliLib','-Version','3.0.0','-RuntimeState','active','-ApplicationProcessId',[string]$PID,'-StateRoot',(Join-Path $testRoot 'cli-state'))
    $cliReport=Invoke-JsonProcess $reportArgs
    Assert ($cliReport.ExitCode -eq 0 -and ($cliReport.StdOut|ConvertFrom-Json).delivery_level -eq 'L3') 'report-module-status CLI did not record an active app version.'
    $statusArgs=@('-NoLogo','-NoProfile','-NonInteractive','-File',$cli,'-Command','module-status','-AppId','cli-module-app','-ModuleId','CliLib','-StateRoot',(Join-Path $testRoot 'cli-state'))
    $cliStatus=Invoke-JsonProcess $statusArgs
    $statusResult=$cliStatus.StdOut|ConvertFrom-Json
    Assert ($cliStatus.ExitCode -eq 0 -and $statusResult.records.Count -eq 1 -and $statusResult.records[0].delivery_level -eq 'L3') ('module-status CLI failed. Exit=' + $cliStatus.ExitCode + ' stdout=' + $cliStatus.StdOut + ' stderr=' + $cliStatus.StdErr)

    $sourcePointer=Join-Path $sourceRoot 'SharedLib/current.json';Remove-Item -LiteralPath $sourcePointer -Force
    $offline=Resolve-AuAppModules -AppManifestPath $appV1 -ModuleSourceRoot $sourceRoot -StateRoot $state
    Assert ($offline.modules[0].source_status -eq 'offline-cache' -and $offline.modules[0].version -eq '1.1.0') 'Unavailable shared storage did not fall back to the newest verified compatible PC cache.'
    'PASS: immutable local publishing, shared per-PC cache reuse, API compatibility, failed-install rollback, hash/conflict rejection, CLI, and offline cache resolution'
}finally{
    Remove-Module AutoUpdate.Core -ErrorAction SilentlyContinue
    $resolvedRoot=[IO.Path]::GetFullPath($testRoot);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $resolvedRoot.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path -Leaf $resolvedRoot).StartsWith('AutoUpdate-module-test-')){throw 'Refusing unsafe module-test cleanup.'}
    if(Test-Path -LiteralPath $resolvedRoot){Remove-Item -LiteralPath $resolvedRoot -Recurse -Force}
}
