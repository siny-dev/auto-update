$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$cli=Join-Path $root 'tools\autoupdate.ps1'
$builder=Join-Path $root 'tools\build-module-package.ps1'
$core=Join-Path $root 'source\AutoUpdate.Core.psm1'
$state=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-core-module-test-'+[guid]::NewGuid().ToString('N'))
$source=Join-Path $state 'module-source'
$buildSource=Join-Path $state 'module-build-source'
$package=Join-Path $state 'module-package'
$manifest=Join-Path $state 'app-modules.json'
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
try{
    $files=@('source\AutoUpdate.Core.psm1','tools\autoupdate.ps1','tools\resolve_modules.py','tools\shared_app.py')
    foreach($relative in $files){
        $destination=Join-Path $buildSource $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        [IO.File]::Copy((Join-Path $root $relative),$destination,$false)
    }
    & $builder -ModuleId AutoUpdate -Version '1.0.0' -ApiMajor 1 -MinimumEngine '0.1.0' -SourceRoot $buildSource -OutputRoot $package -ActivationMode restart|Out-Null
    Import-Module -Name $core -Force
    $published=Publish-AuLocalModulePackage -PackageRoot $package -ModuleSourceRoot $source -ModuleId AutoUpdate
    if($published.Status -cne 'published'){throw 'Synthetic AutoUpdate module source publish failed.'}
    Remove-Module AutoUpdate.Core -ErrorAction SilentlyContinue
    $app=[ordered]@{schema=1;contract='autoupdate-app-modules-v1';app_id='core-module-test';modules=@(@{module_id='AutoUpdate';api_major=1})}
    [IO.File]::WriteAllText($manifest,($app|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $resultText=& $cli -Command resolve-modules -AppManifestPath $manifest -ModuleSourceRoot $source -StateRoot $state
    if($LASTEXITCODE -ne 0){throw 'Source CLI could not resolve the published AutoUpdate module.'}
    $result=([string]::Join([Environment]::NewLine,@($resultText|ForEach-Object{[string]$_}))|ConvertFrom-Json)
    Assert ($result.status -ceq 'ready' -and $result.app_id -ceq 'core-module-test') 'Module resolution returned the wrong app identity.'
    Assert (@($result.modules).Count -eq 1 -and $result.modules[0].module_id -ceq 'AutoUpdate' -and $result.modules[0].verified -eq $true) 'The AutoUpdate dependency was not verified.'
    $moduleRoot=[string]$result.modules[0].module_path
    $moduleCli=Join-Path $moduleRoot 'tools\autoupdate.ps1'
    Assert (Test-Path -LiteralPath $moduleCli -PathType Leaf) 'Resolved AutoUpdate module CLI is missing.'
    $statusText=& $moduleCli -Command status -StateRoot $state -AppId 'not-installed-fixture'
    if($LASTEXITCODE -ne 0){throw 'The cached AutoUpdate module CLI did not start.'}
    $status=([string]::Join([Environment]::NewLine,@($statusText|ForEach-Object{[string]$_}))|ConvertFrom-Json)
    Assert ($status.Status -ceq 'not-installed') 'The cached module did not run its own packaged AutoUpdate code.'
    $againText=& $cli -Command resolve-modules -AppManifestPath $manifest -ModuleSourceRoot $source -StateRoot $state
    if($LASTEXITCODE -ne 0){throw 'The repeated module resolve failed.'}
    $again=([string]::Join([Environment]::NewLine,@($againText|ForEach-Object{[string]$_}))|ConvertFrom-Json)
    Assert ($again.modules[0].source_status -ceq 'already-cached') 'A second app check did not reuse the per-PC module cache.'
    'PASS: AutoUpdate is published, verified, cached once, and executed through its shared module path.'
}finally{
    if(Test-Path -LiteralPath $state){Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction SilentlyContinue}
}
