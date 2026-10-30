$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$module=Join-Path $repoRoot 'source\AutoUpdate.Core.psm1'
$builder=Join-Path $repoRoot 'tools\build-module-package.ps1'
Import-Module $module -Force
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-source-state-test-'+[guid]::NewGuid().ToString('N'))
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
try{
    [void][IO.Directory]::CreateDirectory($testRoot)
    $source=Join-Path $testRoot 'module-source';[void][IO.Directory]::CreateDirectory($source)
    [IO.File]::WriteAllText((Join-Path $source 'client.psm1'),'function Get-ProbeValue { "ok" }',[Text.UTF8Encoding]::new($false))
    $package=Join-Path $testRoot 'package'
    & $builder -ModuleId ProbeLib -Version '1.0.0' -ApiMajor 1 -MinimumEngine '0.1.0' -SourceRoot $source -OutputRoot $package -ActivationMode restart|Out-Null
    $moduleSourceRoot=Join-Path $testRoot 'shared-modules';$state=Join-Path $testRoot 'state'
    $published=Publish-AuLocalModulePackage -PackageRoot $package -ModuleSourceRoot $moduleSourceRoot -ModuleId ProbeLib
    Assert ($published.Status -eq 'published') 'Fixture module was not published to the isolated source root.'
    $manifestPath=Join-Path $testRoot 'app-modules.json'
    $app=[ordered]@{schema=1;contract='autoupdate-app-modules-v1';app_id='source-state-test-app';modules=@(@{module_id='ProbeLib';api_major=1})}
    [IO.File]::WriteAllText($manifestPath,($app|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $available=Resolve-AuAppModules -AppManifestPath $manifestPath -ModuleSourceRoot $moduleSourceRoot -StateRoot $state
    Assert ($available.modules[0].source_state -eq 'available' -and $null -eq $available.modules[0].source_error_code) 'Compatible source was not classified as available.'
    Assert ($available.modules[0].verified -and $available.modules[0].version -eq '1.0.0') 'Resolver did not install the verified module into the isolated cache.'
    Remove-Item -LiteralPath (Join-Path $moduleSourceRoot 'ProbeLib/current.json') -Force
    $fallback=Resolve-AuAppModules -AppManifestPath $manifestPath -ModuleSourceRoot $moduleSourceRoot -StateRoot $state
    Assert ($fallback.modules[0].source_status -eq 'offline-cache' -and $fallback.modules[0].version -eq '1.0.0') 'Missing source pointer did not preserve the verified cache.'
    Assert ($fallback.modules[0].source_state -eq 'unavailable' -and $fallback.modules[0].source_error_code -eq 'source_unavailable') 'Missing pointer classification fields are incorrect.'
    Write-Output 'PASS: PowerShell resolver available source and missing-pointer verified-cache fallback classifications.'
}finally{
    Remove-Module AutoUpdate.Core -ErrorAction SilentlyContinue
    $resolvedRoot=[IO.Path]::GetFullPath($testRoot);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $resolvedRoot.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path -Leaf $resolvedRoot).StartsWith('AutoUpdate-source-state-test-')){throw 'Refusing unsafe source-state test cleanup.'}
    if(Test-Path -LiteralPath $resolvedRoot){Remove-Item -LiteralPath $resolvedRoot -Recurse -Force}
}