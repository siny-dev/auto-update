param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')][string]$ModuleId,
    [Parameter(Mandatory=$true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$ApiMajor,
    [Parameter(Mandatory=$true)][string]$SourceRoot,
    [Parameter(Mandatory=$true)][string]$OutputRoot,
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$MinimumEngine='0.1.0',
    [ValidateSet('live','restart')][string]$ActivationMode='restart',
    [ValidateSet('stateless-v1','reload-hook-v1')][string]$ReloadContract
)
$ErrorActionPreference='Stop'
$reservedWindowsNames=@('con','prn','aux','nul','conin$','conout$')
for($i=1;$i -le 9;$i++){$reservedWindowsNames+=('com'+$i);$reservedWindowsNames+=('lpt'+$i)}
foreach($digit in @([char]0x00b9,[char]0x00b2,[char]0x00b3)){$reservedWindowsNames+=('com'+$digit);$reservedWindowsNames+=('lpt'+$digit)}
function Assert-WindowsPathLength([string]$Path,[string]$Field){if($Path.Length -ge 260){throw "$Field exceeds Windows MAX_PATH (259 UTF-16 code units)."}}
function Assert-ModuleRelativeWindowsPath([string]$Relative){
    if([string]::IsNullOrEmpty($Relative)){throw 'Unsafe module payload path.'}
    $normalized=$Relative.Replace('\','/')
    if($normalized.StartsWith('/') -or $normalized -match '^[A-Za-z]:' -or $normalized.Contains(':')){throw 'Unsafe module payload path.'}
    foreach($part in $normalized.Split('/')){
        if([string]::IsNullOrEmpty($part) -or $part -in @('.','..')){throw 'Unsafe module payload path.'}
        if($part.Length -gt 255){throw 'A Windows module path component exceeds 255 UTF-16 code units.'}
        if($part -match '[\x00-\x1f\x7f-\x9f<>:"|?*]' -or $part.StartsWith(' ') -or $part.EndsWith(' ') -or $part.EndsWith('.')){throw 'Unsafe Windows module payload path.'}
        $stem=$part.Split('.')[0].TrimEnd(' ','.')
        if($reservedWindowsNames -contains $stem.ToLowerInvariant()){throw 'A module payload path uses a reserved Windows device name.'}
    }
}
$repoRoot=Split-Path -Parent $PSScriptRoot
$core=Join-Path $repoRoot 'source\AutoUpdate.Core.psm1'
$requiredEngineFunctions=@('Test-AuModuleManifest','Get-AuFileSha256')
$loadedEngine=Get-Module -Name 'AutoUpdate.Core' -ErrorAction SilentlyContinue|Select-Object -First 1
$engineApiReady=$false
if($loadedEngine){
    $availableFunctions=@(Get-Command -Module $loadedEngine.Name -ErrorAction SilentlyContinue|Select-Object -ExpandProperty Name)
    $engineApiReady=@($requiredEngineFunctions|Where-Object{$_ -notin $availableFunctions}).Count -eq 0
}
# Keep the worker's verified installed engine loaded when packaging a module.
if(-not $engineApiReady){Import-Module $core -Force -Scope Local}
$source=[IO.Path]::GetFullPath($SourceRoot)
$output=[IO.Path]::GetFullPath($OutputRoot)
Assert-WindowsPathLength $source 'Module source root'
Assert-WindowsPathLength $output 'Module package output root'
Assert-WindowsPathLength (Join-Path $output 'module.json') 'Module package manifest path'
if(-not (Test-Path -LiteralPath $source -PathType Container)){throw 'Module SourceRoot does not exist.'}
if(Test-Path -LiteralPath $output){throw "OutputRoot already exists; module package output is immutable: $output"}
if($source.StartsWith($output+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $output.StartsWith($source+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'SourceRoot and OutputRoot must not contain one another.'}
$allFiles=@(Get-ChildItem -LiteralPath $source -File -Recurse|Sort-Object FullName)
if($allFiles.Count -eq 0){throw 'A module source folder must contain at least one file.'}
$codeExtensions=@('.exe','.dll','.ps1','.psm1','.bat','.cmd','.py','.js','.mjs','.cjs','.class')
$payload=Join-Path $output 'payload'
$null=Assert-WindowsPathLength $payload 'Module package payload root'
$copyPlan=[Collections.Generic.List[object]]::new()
foreach($file in $allFiles){
    Assert-WindowsPathLength $file.FullName 'Module source payload path'
    $relative=$file.FullName.Substring($source.Length).TrimStart([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar).Replace('\','/')
    Assert-ModuleRelativeWindowsPath $relative
    if($relative -match '(^|/)\.'){throw "Hidden and metadata files must be excluded explicitly: $relative"}
    $kind=if($codeExtensions -contains $file.Extension.ToLowerInvariant()){'executable'}elseif($file.Extension -in @('.json','.xml','.yaml','.yml','.ini','.txt','.csv')){'data'}else{'resource'}
    if($ActivationMode -eq 'live' -and $kind -in @('executable','runtime')){throw "Live activation cannot include code file: $relative"}
    $destination=Join-Path $payload ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))
    Assert-WindowsPathLength $destination 'Packaged module payload path'
    $copyPlan.Add([pscustomobject]@{File=$file;Relative=$relative;Kind=$kind;Destination=$destination})
}
$entries=[Collections.Generic.List[object]]::new()
try{
    [void][IO.Directory]::CreateDirectory($payload)
    foreach($item in $copyPlan){
        $file=$item.File;$relative=$item.Relative;$kind=$item.Kind;$destination=$item.Destination
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        [IO.File]::Copy($file.FullName,$destination,$false)
        $entries.Add([ordered]@{path=$relative;kind=$kind;size=(Get-Item -LiteralPath $destination).Length;sha256=(Get-AuFileSha256 $destination);source=('payload/'+$relative)})
    }
    $manifest=[ordered]@{schema=1;contract='autoupdate-module-v1';module_id=$ModuleId;version=$Version;api_major=$ApiMajor;minimum_engine=$MinimumEngine;publisher_policy='local-share-v1';activation_mode=$ActivationMode;files=@($entries)}
    if($ReloadContract){$manifest.reload_contract=$ReloadContract}
    [IO.File]::WriteAllText((Join-Path $output 'module.json'),($manifest|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    if(-not (Test-AuModuleManifest -Manifest ($manifest|ConvertTo-Json -Depth 12|ConvertFrom-Json) -ExpectedModuleId $ModuleId)){throw 'Module manifest validation failed.'}
    return [pscustomobject]@{Status='built';ModuleId=$ModuleId;Version=$Version;ApiMajor=$ApiMajor;Path=$output;FileCount=$entries.Count}
}catch{
    $resolved=[IO.Path]::GetFullPath($output)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved).StartsWith('AutoUpdate-module-package-')){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}
    throw
}
