param(
    [Parameter(Mandatory=$true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [int]$ApiMajor=1,
    [string]$StateRoot=(Join-Path $env:LOCALAPPDATA 'Siny\AutoUpdate')
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$work=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-module-package-'+[guid]::NewGuid().ToString('N'))
$source=Join-Path $work 'source'
$package=Join-Path $work 'package'
[void][IO.Directory]::CreateDirectory((Join-Path $source 'tools'))
[void][IO.Directory]::CreateDirectory((Join-Path $source 'source'))
try{
    foreach($relative in @('tools/autoupdate.ps1','source/AutoUpdate.Core.psm1')){
        $from=Join-Path $root ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))
        if(-not (Test-Path -LiteralPath $from -PathType Leaf)){throw "AutoUpdate module source is missing: $relative"}
        $to=Join-Path $source ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))
        [IO.File]::Copy($from,$to,$false)
    }
    & (Join-Path $PSScriptRoot 'build-module-package.ps1') -ModuleId AutoUpdate -Version $Version -ApiMajor $ApiMajor -MinimumEngine '0.1.0' -SourceRoot $source -OutputRoot $package -ActivationMode restart | Out-Null
    $result=& (Join-Path $PSScriptRoot 'autoupdate.ps1') -Command publish-module -ModuleId AutoUpdate -PackageRoot $package -StateRoot $StateRoot
    if($LASTEXITCODE -ne 0){throw 'AutoUpdate module publication failed.'}
    $result
}finally{
    if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
}
