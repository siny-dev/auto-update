$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$core=Join-Path $repoRoot 'source\AutoUpdate.Core.psm1'
$builder=Join-Path $repoRoot 'tools\build-module-package.ps1'
Import-Module $core -Force
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-module-fanout-test-'+[guid]::NewGuid().ToString('N'))
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function New-AppManifest([string]$AppId){
    $path=Join-Path $testRoot ($AppId+'.json')
    $app=[ordered]@{schema=1;contract='autoupdate-app-modules-v1';app_id=$AppId;modules=@(@{module_id='AutoUpdate';api_major=1})}
    [IO.File]::WriteAllText($path,($app|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    return $path
}
function New-ModulePackage([string]$Version){
    $source=Join-Path $testRoot ('source-'+$Version)
    $package=Join-Path $testRoot ('package-'+$Version)
    [void][IO.Directory]::CreateDirectory($source)
    [IO.File]::WriteAllText((Join-Path $source 'module.txt'),('module version '+$Version),[Text.UTF8Encoding]::new($false))
    & $builder -ModuleId AutoUpdate -Version $Version -ApiMajor 1 -SourceRoot $source -OutputRoot $package -ActivationMode restart|Out-Null
    return $package
}
try{
    [void][IO.Directory]::CreateDirectory($testRoot)
    $sourceRoot=Join-Path $testRoot 'shared-modules'
    $pcOneState=Join-Path $testRoot 'pc-one-state'
    $pcTwoState=Join-Path $testRoot 'pc-two-state'
    $appOne=New-AppManifest 'app-one'
    $appTwo=New-AppManifest 'app-two'

    $v100=New-ModulePackage '1.0.0'
    Assert ((Publish-AuLocalModulePackage -PackageRoot $v100 -ModuleSourceRoot $sourceRoot -ModuleId 'AutoUpdate').Status -eq 'published') 'Initial shared module was not published.'
    $initial=@(
        (Resolve-AuAppModules -AppManifestPath $appOne -ModuleSourceRoot $sourceRoot -StateRoot $pcOneState).modules[0],
        (Resolve-AuAppModules -AppManifestPath $appTwo -ModuleSourceRoot $sourceRoot -StateRoot $pcOneState).modules[0],
        (Resolve-AuAppModules -AppManifestPath $appOne -ModuleSourceRoot $sourceRoot -StateRoot $pcTwoState).modules[0],
        (Resolve-AuAppModules -AppManifestPath $appTwo -ModuleSourceRoot $sourceRoot -StateRoot $pcTwoState).modules[0]
    )
    Assert (@($initial|Where-Object{$_.version -cne '1.0.0' -or -not $_.verified}).Count -eq 0) 'Apps did not receive the initial verified module version on both PC caches.'
    Assert ($initial[0].module_path -ceq $initial[1].module_path -and $initial[2].module_path -ceq $initial[3].module_path) 'Apps on the same PC did not share one module cache path.'
    Assert ($initial[0].module_path -cne $initial[2].module_path) 'Separate PC state roots unexpectedly shared a local cache path.'

    $v110=New-ModulePackage '1.1.0'
    Assert ((Publish-AuLocalModulePackage -PackageRoot $v110 -ModuleSourceRoot $sourceRoot -ModuleId 'AutoUpdate').Status -eq 'published') 'Compatible shared module update was not published.'
    $updated=@(
        (Resolve-AuAppModules -AppManifestPath $appOne -ModuleSourceRoot $sourceRoot -StateRoot $pcOneState).modules[0],
        (Resolve-AuAppModules -AppManifestPath $appTwo -ModuleSourceRoot $sourceRoot -StateRoot $pcOneState).modules[0],
        (Resolve-AuAppModules -AppManifestPath $appOne -ModuleSourceRoot $sourceRoot -StateRoot $pcTwoState).modules[0],
        (Resolve-AuAppModules -AppManifestPath $appTwo -ModuleSourceRoot $sourceRoot -StateRoot $pcTwoState).modules[0]
    )
    Assert (@($updated|Where-Object{$_.version -cne '1.1.0' -or -not $_.verified}).Count -eq 0) 'A connected app did not resolve the latest verified module after publication.'
    Assert ($updated[0].module_path -ceq $updated[1].module_path -and $updated[2].module_path -ceq $updated[3].module_path) 'Apps on one PC diverged to different module cache paths.'
    Assert ($updated[0].module_path -cne $updated[2].module_path) 'Two PC caches unexpectedly point to the same local path.'
    Assert (Test-Path -LiteralPath (Join-Path $pcOneState 'modules\AutoUpdate\versions\1.0.0')) 'Updating the shared pointer removed the prior immutable module version.'
    Assert ((Get-AuCurrentModule -StateRoot $pcOneState -ModuleId 'AutoUpdate').Version -eq '1.1.0' -and (Get-AuCurrentModule -StateRoot $pcTwoState -ModuleId 'AutoUpdate').Version -eq '1.1.0') 'Both PC caches did not advance their current module pointer.'
    'PASS: one shared module publication advances two app IDs on two PC caches while preserving prior versions.'
}finally{
    Remove-Module AutoUpdate.Core -ErrorAction SilentlyContinue
    $resolvedRoot=[IO.Path]::GetFullPath($testRoot)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolvedRoot.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path -Leaf $resolvedRoot).StartsWith('AutoUpdate-module-fanout-test-')){throw 'Refusing unsafe module fanout test cleanup.'}
    if(Test-Path -LiteralPath $resolvedRoot){Remove-Item -LiteralPath $resolvedRoot -Recurse -Force}
}