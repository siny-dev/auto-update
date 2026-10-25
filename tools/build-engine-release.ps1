param(
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][string]$OutputRoot
)
$ErrorActionPreference='Stop'
if($Version -notmatch '^\d+\.\d+\.\d+$'){throw 'Version must use major.minor.patch form.'}
$repoRoot=Split-Path -Parent $PSScriptRoot
$spec=[ordered]@{
    app_id='AutoUpdate'
    version=$Version
    mode='restart'
    platform='windows'
    architecture='any'
    minimum_engine='0.1.0'
    files=@(
        @{path='source/AutoUpdate.Core.psm1';kind='runtime'},
        @{path='tools/autoupdate.ps1';kind='runtime'},
        @{path='tools/restart-apply.ps1';kind='runtime'}
    )
}
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-engine-spec-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempRoot)
try{
    $specPath=Join-Path $tempRoot 'engine-spec.json'
    [IO.File]::WriteAllText($specPath,($spec|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    & (Join-Path $PSScriptRoot 'new-release-package.ps1') -SpecPath $specPath -PayloadRoot $repoRoot -OutputRoot $OutputRoot
}finally{
    $resolved=[IO.Path]::GetFullPath($tempRoot)
    $systemTemp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $resolved.StartsWith($systemTemp,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notmatch '^AutoUpdate-engine-spec-[a-f0-9]{32}$'){throw 'Refusing unsafe temporary cleanup.'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
