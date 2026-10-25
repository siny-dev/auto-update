Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:AutoUpdateEngineVersion = '0.1.0'
foreach($candidate in @((Join-Path (Split-Path -Parent $PSScriptRoot) 'VERSION'),(Join-Path (Split-Path -Parent $PSScriptRoot) 'manifest.json'))){
    if(Test-Path -LiteralPath $candidate -PathType Leaf){
        $raw=Get-Content -Raw -LiteralPath $candidate
        if($raw.Trim() -match '^\d+\.\d+\.\d+$'){$script:AutoUpdateEngineVersion=$raw.Trim();break}
        try{$metadata=$raw|ConvertFrom-Json;if($metadata.version -match '^\d+\.\d+\.\d+$'){$script:AutoUpdateEngineVersion=[string]$metadata.version;break}}catch{}
    }
}

function Test-AuVersionAtLeast([string]$Current,[string]$Minimum) {
    try { return ([version]$Current -ge [version]$Minimum) }
    catch { return $false }
}

function Test-AuManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Manifest,
        [Parameter(Mandatory=$true)][string]$ExpectedAppId
    )
    if ($Manifest.schema -ne 1 -or $Manifest.contract -ne 'autoupdate-app-v1') { throw 'Unsupported manifest schema or contract.' }
    if ($Manifest.app_id -cne $ExpectedAppId -or $ExpectedAppId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw 'Application identity mismatch.' }
    if ($Manifest.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid package version.' }
    if ($Manifest.mode -notin @('live','restart')) { throw 'Invalid update mode.' }
    if ($Manifest.platform -ne 'windows' -or $Manifest.architecture -notin @('any','x86','x64','arm64')) { throw 'Unsupported platform or architecture.' }
    if ($Manifest.minimum_engine -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid minimum engine version.' }
    if (-not (Test-AuVersionAtLeast $script:AutoUpdateEngineVersion ([string]$Manifest.minimum_engine))) { throw 'This package requires a newer AutoUpdate engine.' }
    if ($Manifest.publisher_policy -ne 'github-release-asset-https') { throw 'Unrecognized publisher policy.' }
    if ($Manifest.files -isnot [System.Array] -or $Manifest.files.Count -lt 1) { throw 'A package must contain at least one file.' }
    $seen = @{}
    foreach ($file in $Manifest.files) {
        foreach ($field in @('path','kind','size','sha256','source','asset')) {
            if ($null -eq $file.$field) { throw "Manifest file entry is missing $field." }
        }
        $relative = [string]$file.path
        if ([string]::IsNullOrWhiteSpace($relative) -or $relative -match '(^[/\\]|^[A-Za-z]:|(^|[/\\])\.\.([/\\]|$)|:|[\x00-\x1f])') { throw 'Unsafe package path.' }
        $normalized = $relative.Replace('\','/').ToLowerInvariant()
        if ($seen.ContainsKey($normalized)) { throw 'Duplicate package path.' }
        $seen[$normalized] = $true
        if ($file.kind -notin @('data','resource','executable','runtime')) { throw 'Unsupported file kind.' }
        if ([long]$file.size -lt 0 -or [long]$file.size -gt 268435456) { throw 'Invalid or excessive file size.' }
        if ([string]$file.sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Invalid SHA-256.' }
        if ([string]$file.source -match '(^[/\\]|^[A-Za-z]:|(^|[/\\])\.\.([/\\]|$)|:|[\x00-\x1f])') { throw 'Unsafe package source.' }
        if ($Manifest.mode -eq 'live' -and $file.kind -in @('executable','runtime')) { throw 'Live packages cannot contain executable code or the updater runtime.' }
    }
    return $true
}

function Get-AuContainedPath {
    param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Relative)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $fullRoot ($Relative.Replace('/',[IO.Path]::DirectorySeparatorChar))))
    if (-not $candidate.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Resolved path escapes its root.' }
    return $candidate
}

function Get-AuFileSha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try { $sha = [Security.Cryptography.SHA256]::Create(); try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() } }
    finally { $stream.Dispose() }
}

function Get-AuCredentialToken {
    if (-not ('AutoUpdateCoreCredentialReader' -as [type])) {
        $source=@"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class AutoUpdateCoreCredentialReader {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct CREDENTIAL { public UInt32 Flags; public UInt32 Type; public IntPtr TargetName; public IntPtr Comment; public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten; public UInt32 CredentialBlobSize; public IntPtr CredentialBlob; public UInt32 Persist; public UInt32 AttributeCount; public IntPtr Attributes; public IntPtr TargetAlias; public IntPtr UserName; }
 [DllImport("Advapi32.dll",EntryPoint="CredReadW",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool CredRead(string target,UInt32 type,UInt32 flags,out IntPtr credential);
 [DllImport("Advapi32.dll",EntryPoint="CredFree",SetLastError=false)] public static extern void CredFree(IntPtr buffer);
}
"@
        Add-Type -TypeDefinition $source -ErrorAction Stop | Out-Null
    }
    $pointer=[IntPtr]::Zero
    if (-not [AutoUpdateCoreCredentialReader]::CredRead('AutoUpdate/github',1,0,[ref]$pointer)) { throw 'Missing Windows credential target AutoUpdate/github.' }
    try {
        $credential=[Runtime.InteropServices.Marshal]::PtrToStructure($pointer,[type][AutoUpdateCoreCredentialReader+CREDENTIAL])
        if ($credential.CredentialBlobSize -lt 20 -or ($credential.CredentialBlobSize % 2) -ne 0) { throw 'Stored GitHub credential has an invalid format.' }
        $token=[Runtime.InteropServices.Marshal]::PtrToStringUni($credential.CredentialBlob,[int]($credential.CredentialBlobSize/2)).TrimEnd([char]0)
        if ([string]::IsNullOrWhiteSpace($token) -or $token -match '\s') { throw 'Stored GitHub credential is empty or malformed.' }
        return $token
    } finally { [AutoUpdateCoreCredentialReader]::CredFree($pointer) }
}

function Invoke-AuGitHubGet {
    param([Parameter(Mandatory=$true)][uri]$Uri,[Parameter(Mandatory=$true)][string]$Token,[Parameter(Mandatory=$true)][string]$Accept,[string]$OutFile,[long]$MaximumBytes=16777216)
    $current=$Uri
    for ($hop=0; $hop -lt 5; $hop++) {
        if ($current.Scheme -ne 'https' -or $current.Host -notin @('api.github.com','github.com','release-assets.githubusercontent.com','objects.githubusercontent.com')) { throw 'GitHub response used an untrusted or non-HTTPS host.' }
        $request=[Net.HttpWebRequest]::Create($current)
        $request.Method='GET';$request.AllowAutoRedirect=$false;$request.UserAgent='Siny-AutoUpdate/0.1';$request.Accept=$Accept;$request.Timeout=20000;$request.ReadWriteTimeout=30000
        $request.Headers['X-GitHub-Api-Version']='2022-11-28'
        if ($current.Host -eq 'api.github.com') { $request.Headers['Authorization']='Bearer '+$Token }
        try { $response=[Net.HttpWebResponse]$request.GetResponse() }
        catch [Net.WebException] { if ($_.Exception.Response) {$response=[Net.HttpWebResponse]$_.Exception.Response}else{throw 'GitHub request failed before receiving a response.'} }
        try {
            if ([int]$response.StatusCode -in @(301,302,303,307,308)) {
                $location=$response.Headers['Location'];if(-not $location){throw 'GitHub redirect did not include a location.'}
                $current=[uri]::new($current,$location);continue
            }
            if ([int]$response.StatusCode -ne 200) { throw "GitHub returned HTTP $([int]$response.StatusCode)." }
            if ($response.ContentLength -gt $MaximumBytes) { throw 'GitHub asset exceeds the configured size limit.' }
            if ($OutFile) {
                $destination=[IO.File]::Open($OutFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try {
                    $inputStream=$response.GetResponseStream();$buffer=New-Object byte[] 65536;$total=0
                    while(($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0) { $total += $read;if($total -gt $MaximumBytes){throw 'GitHub asset exceeds the configured size limit.'};$destination.Write($buffer,0,$read) }
                } finally { if($inputStream){$inputStream.Dispose()};$destination.Dispose() }
                return $null
            }
            $stream=$response.GetResponseStream();$memory=New-Object IO.MemoryStream
            try { $buffer=New-Object byte[] 65536;$total=0;while(($read=$stream.Read($buffer,0,$buffer.Length)) -gt 0){$total+=$read;if($total -gt $MaximumBytes){throw 'GitHub response exceeds the configured size limit.'};$memory.Write($buffer,0,$read)};return $memory.ToArray() }
            finally { $stream.Dispose();$memory.Dispose() }
        } finally { $response.Dispose() }
    }
    throw 'GitHub redirect limit was exceeded.'
}

function Install-AuLatestRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Owner,
        [Parameter(Mandatory=$true)][string]$Repository,
        [Parameter(Mandatory=$true)][string]$AppId,
        [Parameter(Mandatory=$true)][string]$StateRoot,
        [Parameter(Mandatory=$true)][string]$Architecture
    )
    if ($Owner -notmatch '^[A-Za-z0-9-]+$' -or $Repository -notmatch '^[A-Za-z0-9._-]+$') { throw 'Invalid GitHub repository identity.' }
    $token=Get-AuCredentialToken
    $releaseUri=[uri]"https://api.github.com/repos/$Owner/$Repository/releases/latest"
    $releaseBytes=Invoke-AuGitHubGet -Uri $releaseUri -Token $token -Accept 'application/vnd.github+json' -MaximumBytes 2097152
    $release=[Text.Encoding]::UTF8.GetString($releaseBytes) | ConvertFrom-Json
    if ($release.draft -or $release.prerelease) { throw 'Latest GitHub release is not a stable release.' }
    $manifestAsset=@($release.assets | Where-Object { $_.name -ceq 'autoupdate-manifest.json' })
    if ($manifestAsset.Count -ne 1 -or $manifestAsset[0].size -gt 1048576) { throw 'Release must contain exactly one small autoupdate-manifest.json asset.' }
    $manifestUri=[uri]"https://api.github.com/repos/$Owner/$Repository/releases/assets/$($manifestAsset[0].id)"
    $manifestBytes=Invoke-AuGitHubGet -Uri $manifestUri -Token $token -Accept 'application/octet-stream' -MaximumBytes 1048576
    $manifest=[Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
    Test-AuManifest -Manifest $manifest -ExpectedAppId $AppId | Out-Null
    if ($manifest.architecture -ne 'any' -and $manifest.architecture -ne $Architecture) { throw 'Release architecture mismatch.' }
    if ($release.tag_name -ne ('v'+$manifest.version)) { throw 'Release tag and manifest version do not match.' }
    $assetMap=@{};foreach($asset in $release.assets){if($assetMap.ContainsKey([string]$asset.name)){throw 'Release contains duplicate asset names.'};$assetMap[[string]$asset.name]=$asset}
    $downloadRoot=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-release-'+[guid]::NewGuid().ToString('N'))
    $payloadRoot=Join-Path $downloadRoot 'payload';[void][IO.Directory]::CreateDirectory($payloadRoot)
    try {
        [IO.File]::WriteAllBytes((Join-Path $downloadRoot 'manifest.json'),$manifestBytes)
        foreach($entry in $manifest.files){
            $assetName=[string]$entry.asset
            if(-not $assetName -or -not $assetMap.ContainsKey($assetName)){throw "Release asset is missing: $assetName"}
            $asset=$assetMap[$assetName]
            if([long]$asset.size -ne [long]$entry.size){throw "Release asset size differs from manifest: $assetName"}
            $apiUri=[uri]"https://api.github.com/repos/$Owner/$Repository/releases/assets/$($asset.id)"
            $destination=Get-AuContainedPath $payloadRoot ([string]$entry.path)
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
            Invoke-AuGitHubGet -Uri $apiUri -Token $token -Accept 'application/octet-stream' -OutFile $destination -MaximumBytes ([long]$entry.size) | Out-Null
        }
        Install-AuPackage -PackageRoot $downloadRoot -StateRoot $StateRoot -AppId $AppId -Architecture $Architecture
    } finally {
        if(Test-Path -LiteralPath $downloadRoot){Remove-Item -LiteralPath $downloadRoot -Recurse -Force}
        $token=$null
    }
}

function Get-AuCurrent {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$StateRoot,[Parameter(Mandatory=$true)][string]$AppId)
    $appRoot = Get-AuContainedPath $StateRoot "apps/$AppId"
    $pointer = Join-Path $appRoot 'current.json'
    if (-not (Test-Path -LiteralPath $pointer -PathType Leaf)) { return $null }
    $active = Get-Content -Raw -LiteralPath $pointer | ConvertFrom-Json
    if ($active.schema -ne 1 -or $active.app_id -cne $AppId -or $active.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Active package pointer is invalid.' }
    $versionPath = Get-AuContainedPath (Join-Path $appRoot 'versions') ([string]$active.version)
    if (-not (Test-Path -LiteralPath $versionPath -PathType Container)) { throw 'Active package directory is missing.' }
    return [pscustomobject]@{ AppId=$AppId; Version=[string]$active.version; Mode=[string]$active.mode; Path=$versionPath; Pointer=$active }
}

function Install-AuPackageUnlocked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$PackageRoot,
        [Parameter(Mandatory=$true)][string]$StateRoot,
        [Parameter(Mandatory=$true)][string]$AppId,
        [Parameter(Mandatory=$true)][string]$Architecture,
        [switch]$FailActivationForTest
    )
    $packagePath = [IO.Path]::GetFullPath($PackageRoot)
    $manifestPath = Join-Path $packagePath 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Package manifest is missing.' }
    $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    $manifest = [Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
    Test-AuManifest -Manifest $manifest -ExpectedAppId $AppId | Out-Null
    if ($manifest.architecture -ne 'any' -and $manifest.architecture -ne $Architecture) { throw 'Package architecture mismatch.' }

    $appRoot = Get-AuContainedPath $StateRoot "apps/$AppId"
    $versionsRoot = Join-Path $appRoot 'versions'
    $stagingRoot = Join-Path $appRoot 'staging'
    [void][IO.Directory]::CreateDirectory($versionsRoot)
    [void][IO.Directory]::CreateDirectory($stagingRoot)
    $versionPath = Get-AuContainedPath $versionsRoot ([string]$manifest.version)
    $current = Get-AuCurrent -StateRoot $StateRoot -AppId $AppId
    if ($current -and $current.Version -eq $manifest.version) { return [pscustomobject]@{Status='already-current';AppId=$AppId;Version=$manifest.version;Path=$current.Path;Mode=$manifest.mode} }
    if ($current -and ([version]$manifest.version -lt [version]$current.Version)) { throw 'Downgrades are blocked by default.' }
    if (Test-Path -LiteralPath $versionPath) { throw 'This version already exists; refusing to overwrite an immutable package.' }

    $stage = Join-Path $stagingRoot ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    try {
        foreach ($entry in $manifest.files) {
            $sourcePath = Get-AuContainedPath $packagePath ([string]$entry.source)
            $destinationPath = Get-AuContainedPath $stage ([string]$entry.path)
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Package file is missing: $($entry.path)" }
            $info = Get-Item -LiteralPath $sourcePath
            if ($info.Length -ne [long]$entry.size) { throw "Package size mismatch: $($entry.path)" }
            if ((Get-AuFileSha256 $sourcePath) -ne ([string]$entry.sha256).ToLowerInvariant()) { throw "Package hash mismatch: $($entry.path)" }
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destinationPath))
            [IO.File]::Copy($sourcePath,$destinationPath,$false)
        }
        [IO.File]::WriteAllBytes((Join-Path $stage 'manifest.json'),$manifestBytes)
        [IO.Directory]::Move($stage,$versionPath)
    } catch {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        throw
    }

    $pointerPath = Join-Path $appRoot 'current.json'
    $tempPointer = Join-Path $appRoot ('current.' + [guid]::NewGuid().ToString('N') + '.part')
    $backupPointer = Join-Path $appRoot 'previous.json'
    $manifestHash = (Get-AuFileSha256 $manifestPath)
    $pointerObject = [ordered]@{schema=1;app_id=$AppId;version=[string]$manifest.version;mode=[string]$manifest.mode;manifest_sha256=$manifestHash;activated_utc=[DateTime]::UtcNow.ToString('o')}
    $pointerBytes = [Text.UTF8Encoding]::new($false).GetBytes(($pointerObject | ConvertTo-Json -Depth 8))
    [IO.File]::WriteAllBytes($tempPointer,$pointerBytes)
    try {
        if ($FailActivationForTest) { throw 'Injected pointer activation failure.' }
        if ([IO.File]::Exists($pointerPath)) { [IO.File]::Replace($tempPointer,$pointerPath,$backupPointer,$true) }
        else { [IO.File]::Move($tempPointer,$pointerPath) }
    } catch {
        if ([IO.File]::Exists($tempPointer)) { [IO.File]::Delete($tempPointer) }
        if (Test-Path -LiteralPath $versionPath) { Remove-Item -LiteralPath $versionPath -Recurse -Force }
        throw
    }
    return [pscustomobject]@{Status='staged';AppId=$AppId;Version=[string]$manifest.version;Path=$versionPath;Mode=[string]$manifest.mode}
}

function Install-AuPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$PackageRoot,
        [Parameter(Mandatory=$true)][string]$StateRoot,
        [Parameter(Mandatory=$true)][string]$AppId,
        [Parameter(Mandatory=$true)][string]$Architecture,
        [switch]$FailActivationForTest
    )
    $mutex=[Threading.Mutex]::new($false,('Local\AutoUpdateInstall_'+$AppId));$owned=$false
    try {
        try{$owned=$mutex.WaitOne(30000)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){throw 'Another updater is applying a package for this app.'}
        return Install-AuPackageUnlocked @PSBoundParameters
    } finally { if($owned){$mutex.ReleaseMutex()};$mutex.Dispose() }
}

Export-ModuleMember -Function Test-AuManifest,Install-AuPackage,Install-AuLatestRelease,Get-AuCurrent,Get-AuFileSha256
