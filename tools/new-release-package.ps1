param(
    [Parameter(Mandatory=$true)][string]$SpecPath,
    [Parameter(Mandatory=$true)][string]$PayloadRoot,
    [Parameter(Mandatory=$true)][string]$OutputRoot
)
$ErrorActionPreference='Stop'
$spec=Get-Content -Raw -LiteralPath $SpecPath | ConvertFrom-Json
if($spec.app_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'){throw 'Invalid app_id.'}
if($spec.version -notmatch '^\d+\.\d+\.\d+$'){throw 'Invalid version.'}
if($spec.mode -notin @('live','restart')){throw 'Invalid mode.'}
if($spec.platform -ne 'windows' -or $spec.architecture -notin @('any','x86','x64','arm64')){throw 'Invalid platform or architecture.'}
if($spec.minimum_engine -notmatch '^\d+\.\d+\.\d+$' -or -not $spec.files -or $spec.files.Count -lt 1){throw 'Invalid engine minimum or empty file list.'}
$payload=[IO.Path]::GetFullPath($PayloadRoot);$output=[IO.Path]::GetFullPath($OutputRoot)
if(Test-Path -LiteralPath $output){throw 'OutputRoot already exists; package builds are immutable.'}
[void][IO.Directory]::CreateDirectory($output)
$assetsRoot=Join-Path $output 'assets';[void][IO.Directory]::CreateDirectory($assetsRoot)
$packagePayloadRoot=Join-Path $output 'payload';[void][IO.Directory]::CreateDirectory($packagePayloadRoot)
$entries=@();$seen=@{}
try {
    foreach($sourceEntry in $spec.files){
        $relative=[string]$sourceEntry.path
        if([string]::IsNullOrWhiteSpace($relative) -or $relative -match '(^[/\\]|^[A-Za-z]:|(^|[/\\])\.\.([/\\]|$)|:|[\x00-\x1f])'){throw 'Unsafe package file path.'}
        if($sourceEntry.kind -notin @('data','resource','executable','runtime')){throw 'Unsupported package file kind.'}
        if($spec.mode -eq 'live' -and $sourceEntry.kind -in @('executable','runtime')){throw 'Live packages cannot contain executable code or updater runtime files.'}
        $key=$relative.Replace('\','/').ToLowerInvariant();if($seen.ContainsKey($key)){throw 'Duplicate package path.'};$seen[$key]=$true
        $source=Join-Path $payload ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))
        if(-not (Test-Path -LiteralPath $source -PathType Leaf)){throw "Missing package payload: $relative"}
        $info=Get-Item -LiteralPath $source;if($info.Length -gt 268435456){throw "Package file exceeds 256 MiB: $relative"}
        $assetName='asset_'+$key.Replace('/','_').Replace('.','_')
        $dest=Join-Path $assetsRoot $assetName;[IO.File]::Copy($source,$dest,$false)
        $localPayload=Join-Path $packagePayloadRoot ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $localPayload));[IO.File]::Copy($source,$localPayload,$false)
        $sha=(Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
        $packagePath=$relative.Replace('\','/')
        $entries+=@([ordered]@{path=$packagePath;kind=[string]$sourceEntry.kind;size=[long]$info.Length;sha256=$sha;source=('payload/'+$packagePath);asset=$assetName})
    }
    $manifest=[ordered]@{schema=1;contract='autoupdate-app-v1';app_id=[string]$spec.app_id;version=[string]$spec.version;mode=[string]$spec.mode;platform='windows';architecture=[string]$spec.architecture;minimum_engine=[string]$spec.minimum_engine;publisher_policy='github-release-asset-https';files=$entries}
    $manifestBytes=[Text.UTF8Encoding]::new($false).GetBytes(($manifest|ConvertTo-Json -Depth 12))
    [IO.File]::WriteAllBytes((Join-Path $output 'autoupdate-manifest.json'),$manifestBytes)
    [IO.File]::WriteAllBytes((Join-Path $output 'manifest.json'),$manifestBytes)
    $manifestPath=Join-Path $output 'autoupdate-manifest.json'
    (Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json) | Out-Null
    "PASS: package created for $($spec.app_id) $($spec.version) with $($entries.Count) hashed assets"
} catch {
    if(Test-Path -LiteralPath $output){Remove-Item -LiteralPath $output -Recurse -Force}
    throw
}
