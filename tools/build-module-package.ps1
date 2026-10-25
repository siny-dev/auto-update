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
$repoRoot=Split-Path -Parent $PSScriptRoot
$core=Join-Path $repoRoot 'source\AutoUpdate.Core.psm1'
Import-Module $core -Force
$source=[IO.Path]::GetFullPath($SourceRoot)
$output=[IO.Path]::GetFullPath($OutputRoot)
if(-not (Test-Path -LiteralPath $source -PathType Container)){throw 'Module SourceRoot does not exist.'}
if(Test-Path -LiteralPath $output){throw "OutputRoot already exists; module package output is immutable: $output"}
if($source.StartsWith($output+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $output.StartsWith($source+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'SourceRoot and OutputRoot must not contain one another.'}
$allFiles=@(Get-ChildItem -LiteralPath $source -File -Recurse|Sort-Object FullName)
if($allFiles.Count -eq 0){throw 'A module source folder must contain at least one file.'}
$codeExtensions=@('.exe','.dll','.ps1','.psm1','.bat','.cmd','.py','.js','.mjs','.cjs','.class')
$payload=Join-Path $output 'payload'
[void][IO.Directory]::CreateDirectory($payload)
$entries=[Collections.Generic.List[object]]::new()
try{
    foreach($file in $allFiles){
        $relative=$file.FullName.Substring($source.Length).TrimStart([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar).Replace('\','/')
        if($relative -match '(^|/)\.'){throw "Hidden and metadata files must be excluded explicitly: $relative"}
        $kind=if($codeExtensions -contains $file.Extension.ToLowerInvariant()){'executable'}elseif($file.Extension -in @('.json','.xml','.yaml','.yml','.ini','.txt','.csv')){'data'}else{'resource'}
        if($ActivationMode -eq 'live' -and $kind -in @('executable','runtime')){throw "Live activation cannot include code file: $relative"}
        $destination=Join-Path $payload ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))
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
