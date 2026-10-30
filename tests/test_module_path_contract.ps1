$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$modulePath=Join-Path $repoRoot 'source\AutoUpdate.Core.psm1'
$builder=Join-Path $repoRoot 'tools\build-module-package.ps1'
Import-Module $modulePath -Force
$module=Get-Module -Name 'AutoUpdate.Core'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-path-contract-'+[guid]::NewGuid().ToString('N'))
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Invoke-ModulePathCheck([string]$Root,[string]$Relative){
    & $module {param($r,$p) Get-AuContainedPath $r $p} $Root $Relative
}
function Invoke-RelativePathCheck([string]$Relative){
    & $module {param($p) Assert-AuModuleRelativePath $p} $Relative
}
function New-RelativeAtLength([string]$Root,[int]$TargetLength){
    $full=[IO.Path]::GetFullPath($Root)
    if($full.Length -gt 3){$full=$full.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)}
    $remaining=$TargetLength-$full.Length-1
    if($remaining -lt 1){throw 'Temporary root is too long for the path boundary fixture.'}
    $parts=New-Object 'System.Collections.Generic.List[string]'
    while($remaining -gt 255){$parts.Add(('x'*240));$remaining-=241}
    $parts.Add(('x'*$remaining))
    return ($parts -join [IO.Path]::DirectorySeparatorChar)
}
try{
    [void][IO.Directory]::CreateDirectory($testRoot)
    foreach($rootName in @('source','cache')){
        $root=Join-Path $testRoot $rootName
        $relative259=New-RelativeAtLength $root 259
        $resolved=Invoke-ModulePathCheck $root $relative259
        Assert ($resolved.Length -eq 259) "$rootName path of 259 UTF-16 units was not accepted."
        $relative260=New-RelativeAtLength $root 260
        $rejected=$false
        try{[void](Invoke-ModulePathCheck $root $relative260)}catch{$rejected=$_.Exception.Message -like '*MAX_PATH*'}
        Assert $rejected "$rootName path of 260 UTF-16 units was not rejected."
    }

    Invoke-RelativePathCheck ('x'*255)
    $rejected=$false
    try{Invoke-RelativePathCheck ('x'*256)}catch{$rejected=$_.Exception.Message -like '*255 UTF-16*'}
    Assert $rejected 'A 256-unit component was not rejected.'
    $emoji=[char]::ConvertFromUtf32(0x1F600)
    Invoke-RelativePathCheck (('x'*253)+$emoji)
    $rejected=$false
    try{Invoke-RelativePathCheck (('x'*254)+$emoji)}catch{$rejected=$_.Exception.Message -like '*255 UTF-16*'}
    Assert $rejected 'UTF-16 surrogate pairs were not counted as two units.'

    foreach($relative in @('payload/CON','payload/nul.txt','payload/CONIN$','payload/CONOUT$.txt','payload/NUL .txt','payload/COM1.log',('payload/LPT'+[char]0x00b3+'.dat'))){
        $rejected=$false
        try{Invoke-RelativePathCheck $relative}catch{$rejected=$_.Exception.Message -like '*reserved Windows device*'}
        Assert $rejected "Reserved device path was not rejected: $relative"
    }
    $hangul=([char]0xd55c).ToString()+([char]0xae00).ToString()
    Invoke-RelativePathCheck ('payload/'+$hangul+' notes/empty file.txt')

    $source=Join-Path $testRoot 'source-for-builder'
    [void][IO.Directory]::CreateDirectory($source)
    $hangul=([char]0xd55c).ToString()+([char]0xae00).ToString()
    $spaceDir=Join-Path $source ($hangul+' notes')
    [void][IO.Directory]::CreateDirectory($spaceDir)
    $emptyFile=Join-Path $spaceDir 'empty file.txt'
    [IO.File]::WriteAllBytes($emptyFile,[byte[]]@())
    $builtPackage=Join-Path $testRoot 'package-output'
    [void](& $builder -ModuleId PathTest -Version '1.0.0' -ApiMajor 1 -SourceRoot $source -OutputRoot $builtPackage)
    $builtManifestText=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes((Join-Path $builtPackage 'module.json')))
    $builtManifest=$builtManifestText|ConvertFrom-Json
    Assert ($builtManifest.files.Count -eq 1 -and [long]$builtManifest.files[0].size -eq 0) 'The package builder did not preserve a zero-byte payload.'
    $expectedBuiltPath=$hangul+' notes/empty file.txt'
    Assert ($builtManifest.files[0].path -eq $expectedBuiltPath) ("The package builder changed path; actual units=$(([int[]][char[]]$builtManifest.files[0].path) -join ','); expected units=$(([int[]][char[]]$expectedBuiltPath) -join ',').")
    $verifiedSource=& $module {param($r) Get-AuModuleManifestFromPackage -PackageRoot $r -ModuleId 'PathTest'} $builtPackage
    Assert ($verifiedSource.Manifest.files[0].path -eq $expectedBuiltPath) 'The PowerShell resolver did not parse the UTF-8 package manifest.'
    $cacheState=Join-Path $testRoot 'cache-state'
    $installed=Install-AuModulePackage -PackageRoot $builtPackage -StateRoot $cacheState -ModuleId PathTest
    Assert ($installed.Status -eq 'activated') 'The verified package did not install into the temporary cache.'
    Assert ((Get-Item -LiteralPath (Join-Path $installed.Path $expectedBuiltPath)).Length -eq 0) 'The cache install changed the zero-byte payload.'

    $longSource=Join-Path $testRoot (New-RelativeAtLength $testRoot 260)
    $rejected=$false
    try{& $builder -ModuleId PathTest -Version '1.0.0' -ApiMajor 1 -SourceRoot $longSource -OutputRoot (Join-Path $testRoot 'unused-source-output')|Out-Null}catch{$rejected=$_.Exception.Message -like '*MAX_PATH*'}
    Assert $rejected 'The package builder did not reject a source root at MAX_PATH.'
    $longOutput=Join-Path $testRoot (New-RelativeAtLength $testRoot 260)
    $rejected=$false
    try{& $builder -ModuleId PathTest -Version '1.0.0' -ApiMajor 1 -SourceRoot $source -OutputRoot $longOutput|Out-Null}catch{$rejected=$_.Exception.Message -like '*MAX_PATH*'}
    Assert $rejected 'The package builder did not reject an output root at MAX_PATH.'
    'PASS: source/cache MAX_PATH boundaries, 255-unit components, reserved names, Unicode and package roots.'
}finally{
    Remove-Module -Name 'AutoUpdate.Core' -Force -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
