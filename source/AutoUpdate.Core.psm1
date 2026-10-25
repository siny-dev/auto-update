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

function Test-AuReleaseTagVersion([string]$Tag,[string]$Version) {
    if($Tag -notmatch '^[vV]?\d+\.\d+\.\d+$' -or $Version -notmatch '^\d+\.\d+\.\d+$'){return $false}
    try{return ([version]$Tag.TrimStart('v','V') -eq [version]$Version)}catch{return $false}
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
    $modeProperty=$Manifest.PSObject.Properties['mode']
    $effectiveMode=if($modeProperty){[string]$modeProperty.Value}else{''}
    if([string]::IsNullOrWhiteSpace($effectiveMode)){
        if(@($Manifest.files|Where-Object{$_.kind -in @('executable','runtime')}).Count -gt 0){$effectiveMode='restart'}else{$effectiveMode='live'}
        $Manifest|Add-Member -NotePropertyName mode -NotePropertyValue $effectiveMode -Force
    }
    if ($effectiveMode -notin @('live','restart')) { throw 'Invalid update mode.' }
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

function Get-AuRegisteredApps {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$StateRoot)
    $registryPath=Get-AuContainedPath $StateRoot 'registry/apps.json'
    if(-not (Test-Path -LiteralPath $registryPath -PathType Leaf)){return @()}
    $registry=Get-Content -Raw -LiteralPath $registryPath|ConvertFrom-Json
    if($registry.schema -ne 1 -or $registry.apps -isnot [System.Array]){throw 'Application registry is invalid.'}
    $seen=@{}
    foreach($app in $registry.apps){
        if($app.app_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $app.owner -notmatch '^[A-Za-z0-9-]+$' -or $app.repository -notmatch '^[A-Za-z0-9._-]+$' -or $app.architecture -notin @('any','x86','x64','arm64')){throw 'Application registry contains an invalid entry.'}
        if($seen.ContainsKey(([string]$app.app_id).ToLowerInvariant())){throw 'Application registry contains duplicate app IDs.'}
        $seen[([string]$app.app_id).ToLowerInvariant()]=$true
    }
    return @($registry.apps|Sort-Object app_id)
}

function Register-AuApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$StateRoot,
        [Parameter(Mandatory=$true)][string]$AppId,
        [Parameter(Mandatory=$true)][string]$Owner,
        [Parameter(Mandatory=$true)][string]$Repository,
        [ValidateSet('any','x86','x64','arm64')][string]$Architecture='x64'
    )
    if($AppId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $Owner -notmatch '^[A-Za-z0-9-]+$' -or $Repository -notmatch '^[A-Za-z0-9._-]+$'){throw 'Invalid application registration.'}
    $registryPath=Get-AuContainedPath $StateRoot 'registry/apps.json'
    $registryRoot=Split-Path -Parent $registryPath
    [void][IO.Directory]::CreateDirectory($registryRoot)
    $mutex=[Threading.Mutex]::new($false,'Local\AutoUpdateRegistry');$owned=$false
    try{
        try{$owned=$mutex.WaitOne(30000)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){throw 'Application registry is busy.'}
        $apps=@(Get-AuRegisteredApps -StateRoot $StateRoot|Where-Object{$_.app_id -ine $AppId})
        $apps+= [pscustomobject]@{app_id=$AppId;owner=$Owner;repository=$Repository;architecture=$Architecture;registered_utc=[DateTime]::UtcNow.ToString('o')}
        $document=[ordered]@{schema=1;apps=@($apps|Sort-Object app_id)}
        $tmp=$registryPath+'.'+[guid]::NewGuid().ToString('N')+'.part'
        [IO.File]::WriteAllText($tmp,($document|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($registryPath)){
            $backup=$registryPath+'.bak'
            [IO.File]::Replace($tmp,$registryPath,$backup,$true)
            if([IO.File]::Exists($backup)){[IO.File]::Delete($backup)}
        }else{[IO.File]::Move($tmp,$registryPath)}
        return [pscustomobject]@{Status='registered';AppId=$AppId;Owner=$Owner;Repository=$Repository;Architecture=$Architecture;Registry=$registryPath}
    }finally{if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
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
        [Parameter(Mandatory=$true)][string]$Architecture,
        [psobject]$Candidate,
        [string]$LocalPackageRoot
    )
    if ($Owner -notmatch '^[A-Za-z0-9-]+$' -or $Repository -notmatch '^[A-Za-z0-9._-]+$') { throw 'Invalid GitHub repository identity.' }
    $token=$null
    if($Candidate){$release=$Candidate.Release;$manifest=$Candidate.Manifest;$manifestBytes=$Candidate.ManifestBytes}
    else{
        $token=Get-AuCredentialToken
        $releaseUri=[uri]"https://api.github.com/repos/$Owner/$Repository/releases/latest"
        $releaseBytes=Invoke-AuGitHubGet -Uri $releaseUri -Token $token -Accept 'application/vnd.github+json' -MaximumBytes 2097152
        $release=[Text.Encoding]::UTF8.GetString($releaseBytes) | ConvertFrom-Json
        if ($release.draft -or $release.prerelease) { throw 'Latest GitHub release is not a stable release.' }
        $manifestAsset=Get-AuReleaseManifestAsset -Release $release
        if (-not $manifestAsset) { throw 'Latest GitHub release has no AutoUpdate package manifest.' }
        $manifestUri=[uri]"https://api.github.com/repos/$Owner/$Repository/releases/assets/$($manifestAsset[0].id)"
        $manifestBytes=Invoke-AuGitHubGet -Uri $manifestUri -Token $token -Accept 'application/octet-stream' -MaximumBytes 1048576
        $manifest=[Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
        Test-AuManifest -Manifest $manifest -ExpectedAppId $AppId | Out-Null
        if ($manifest.architecture -ne 'any' -and $manifest.architecture -ne $Architecture) { throw 'Release architecture mismatch.' }
        if (-not (Test-AuReleaseTagVersion -Tag ([string]$release.tag_name) -Version ([string]$manifest.version))) { throw 'Release tag and manifest version do not match.' }
    }
    $current=Get-AuCurrent -StateRoot $StateRoot -AppId $AppId
    if ($current -and $current.Version -eq [string]$manifest.version) {
        $installedManifest=Get-Content -Raw -LiteralPath (Join-Path $current.Path 'manifest.json')|ConvertFrom-Json
        if((Get-AuManifestFingerprint $installedManifest) -ceq (Get-AuManifestFingerprint $manifest)){
            return [pscustomobject]@{Status='already-current';AppId=$AppId;Version=[string]$manifest.version;Path=$current.Path;Mode=[string]$manifest.mode}
        }
        return [pscustomobject]@{Status='conflict';AppId=$AppId;Version=[string]$manifest.version;Path=$current.Path;Mode=[string]$manifest.mode;Message='The installed package has the same version but different contents; both copies were preserved.'}
    }
    if ($current -and ([version]$manifest.version -lt [version]$current.Version)) { throw 'Downgrades are blocked by default.' }
    $assetMap=@{};foreach($asset in $release.assets){if($assetMap.ContainsKey([string]$asset.name)){throw 'Release contains duplicate asset names.'};$assetMap[[string]$asset.name]=$asset}
    if(-not $token){$token=Get-AuCredentialToken}
    $downloadRoot=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-release-'+[guid]::NewGuid().ToString('N'))
    $payloadRoot=Join-Path $downloadRoot 'payload';[void][IO.Directory]::CreateDirectory($payloadRoot)
    try {
        [IO.File]::WriteAllBytes((Join-Path $downloadRoot 'manifest.json'),$manifestBytes)
        [IO.File]::WriteAllBytes((Join-Path $downloadRoot 'autoupdate-manifest.json'),$manifestBytes)
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
        Test-AuPackagePayload -PackageRoot $downloadRoot -Manifest $manifest -AppId $AppId -Architecture $Architecture|Out-Null
        $installRoot=$downloadRoot
        if($LocalPackageRoot){$installRoot=Save-AuPackageToLocal -PackageRoot $downloadRoot -LocalPackageRoot $LocalPackageRoot -Manifest $manifest -AppId $AppId -Architecture $Architecture}
        Install-AuPackage -PackageRoot $installRoot -StateRoot $StateRoot -AppId $AppId -Architecture $Architecture
    } finally {
        if(Test-Path -LiteralPath $downloadRoot){Remove-Item -LiteralPath $downloadRoot -Recurse -Force}
        $token=$null
    }
}

function Get-AuManifestFingerprint {
    param([Parameter(Mandatory=$true)]$Manifest)
    $parts=@([string]$Manifest.app_id,[string]$Manifest.version,[string]$Manifest.mode,[string]$Manifest.platform,[string]$Manifest.architecture,[string]$Manifest.minimum_engine)
    foreach($file in @($Manifest.files|Sort-Object path)){$parts+=('{0}|{1}|{2}|{3}' -f [string]$file.path,[string]$file.kind,[long]$file.size,([string]$file.sha256).ToLowerInvariant())}
    return [string]::Join("`n",$parts)
}

function Compare-AuPackageCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$LocalManifest,[Parameter(Mandatory=$true)]$RemoteManifest)
    if($LocalManifest.app_id -cne $RemoteManifest.app_id){throw 'Package candidates have different app identities.'}
    $localVersion=[version][string]$LocalManifest.version
    $remoteVersion=[version][string]$RemoteManifest.version
    if($localVersion -gt $remoteVersion){return 'local'}
    if($remoteVersion -gt $localVersion){return 'github'}
    if((Get-AuManifestFingerprint $LocalManifest) -ceq (Get-AuManifestFingerprint $RemoteManifest)){return 'same'}
    return 'conflict'
}

function Get-AuReleaseManifestAsset {
    param([Parameter(Mandatory=$true)]$Release)
    $manifestAsset=@($Release.assets|Where-Object{$_.name -ceq 'autoupdate-manifest.json'})
    if($manifestAsset.Count -eq 0){return $null}
    if($manifestAsset.Count -ne 1 -or [long]$manifestAsset[0].size -gt 1048576){throw 'Release must contain exactly one small autoupdate-manifest.json asset.'}
    return $manifestAsset[0]
}
function Select-AuPackageWinner {
    param($LocalManifest,$RemoteManifest)
    if(-not $LocalManifest){if($RemoteManifest){return 'github'};return 'none'}
    if(-not $RemoteManifest){return 'local'}
    return Compare-AuPackageCandidates -LocalManifest $LocalManifest -RemoteManifest $RemoteManifest
}
function Get-AuLatestReleaseManifest {
    param([string]$Owner,[string]$Repository,[string]$AppId,[string]$Architecture)
    if($Owner -notmatch '^[A-Za-z0-9-]+$' -or $Repository -notmatch '^[A-Za-z0-9._-]+$'){throw 'Invalid GitHub repository identity.'}
    $token=Get-AuCredentialToken
    try{
        $releaseBytes=Invoke-AuGitHubGet -Uri ([uri]"https://api.github.com/repos/$Owner/$Repository/releases/latest") -Token $token -Accept 'application/vnd.github+json' -MaximumBytes 2097152
        $release=[Text.Encoding]::UTF8.GetString($releaseBytes)|ConvertFrom-Json
        if($release.draft -or $release.prerelease){throw 'Latest GitHub release is not a stable release.'}
        $manifestAsset=Get-AuReleaseManifestAsset -Release $release
        if(-not $manifestAsset){return $null} # Legacy release: no common package was published.
        $manifestUri=[uri]"https://api.github.com/repos/$Owner/$Repository/releases/assets/$($manifestAsset[0].id)"
        $manifestBytes=Invoke-AuGitHubGet -Uri $manifestUri -Token $token -Accept 'application/octet-stream' -MaximumBytes 1048576
        $manifest=[Text.Encoding]::UTF8.GetString($manifestBytes)|ConvertFrom-Json
        Test-AuManifest -Manifest $manifest -ExpectedAppId $AppId|Out-Null
        if($manifest.architecture -ne 'any' -and $manifest.architecture -ne $Architecture){throw 'Release architecture mismatch.'}
        if(-not (Test-AuReleaseTagVersion -Tag ([string]$release.tag_name) -Version ([string]$manifest.version))){throw 'Release tag and manifest version do not match.'}
        return [pscustomobject]@{Manifest=$manifest;Release=$release;ManifestBytes=$manifestBytes}
    }finally{$token=$null}
}

function Invoke-AuGitHubApiJson {
    [CmdletBinding()]
    param([ValidateSet('GET','POST','PATCH','DELETE')][string]$Method,[Parameter(Mandatory=$true)][uri]$Uri,[Parameter(Mandatory=$true)][string]$Token,$Body)
    if($Uri.Scheme -cne 'https' -or $Uri.Host -cne 'api.github.com'){throw 'GitHub API request must use api.github.com over HTTPS.'}
    $request=[Net.HttpWebRequest]::Create($Uri);$request.Method=$Method;$request.AllowAutoRedirect=$false
    $request.UserAgent='Siny-AutoUpdate/0.1';$request.Accept='application/vnd.github+json';$request.ContentType='application/json; charset=utf-8';$request.Timeout=20000;$request.ReadWriteTimeout=30000
    $request.Headers['Authorization']='Bearer '+$Token;$request.Headers['X-GitHub-Api-Version']='2022-11-28'
    if($null -ne $Body){$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Body|ConvertTo-Json -Depth 16 -Compress));$request.ContentLength=$bytes.Length;$stream=$request.GetRequestStream();try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}
    try{$response=[Net.HttpWebResponse]$request.GetResponse()}
    catch [Net.WebException]{if($_.Exception.Response){$response=[Net.HttpWebResponse]$_.Exception.Response}else{throw 'GitHub API request failed before receiving a response.'}}
    try{
        $status=[int]$response.StatusCode
        if($Method -eq 'DELETE' -and $status -eq 204){return $null}
        if($status -lt 200 -or $status -ge 300){throw "GitHub API returned HTTP $status."}
        $reader=[IO.StreamReader]::new($response.GetResponseStream());try{$json=$reader.ReadToEnd()}finally{$reader.Dispose()}
        if([string]::IsNullOrWhiteSpace($json)){return $null}
        return ($json|ConvertFrom-Json)
    }finally{$response.Dispose()}
}

function Send-AuGitHubReleaseAsset {
    param([Parameter(Mandatory=$true)][uri]$UploadUri,[Parameter(Mandatory=$true)][string]$Token,[Parameter(Mandatory=$true)][string]$Name,[Parameter(Mandatory=$true)][string]$Path)
    if($UploadUri.Scheme -cne 'https' -or $UploadUri.Host -cne 'uploads.github.com'){throw 'GitHub asset upload URL is not trusted.'}
    if($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$'){throw 'Release asset name is invalid.'}
    $separator=if($UploadUri.Query){'&'}else{'?'};$uri=[uri]($UploadUri.AbsoluteUri+$separator+'name='+[uri]::EscapeDataString($Name))
    $info=Get-Item -LiteralPath $Path;if($info.Length -gt 268435456){throw 'Release asset exceeds 256 MiB.'}
    $request=[Net.HttpWebRequest]::Create($uri);$request.Method='POST';$request.AllowAutoRedirect=$false;$request.UserAgent='Siny-AutoUpdate/0.1';$request.Accept='application/vnd.github+json';$request.ContentType='application/octet-stream';$request.ContentLength=$info.Length;$request.Timeout=30000;$request.ReadWriteTimeout=60000
    $request.Headers['Authorization']='Bearer '+$Token;$request.Headers['X-GitHub-Api-Version']='2022-11-28'
    $input=[IO.File]::OpenRead($Path);$output=$request.GetRequestStream();try{$input.CopyTo($output)}finally{$input.Dispose();$output.Dispose()}
    try{$response=[Net.HttpWebResponse]$request.GetResponse()}
    catch [Net.WebException]{if($_.Exception.Response){$response=[Net.HttpWebResponse]$_.Exception.Response}else{throw 'GitHub asset upload failed before receiving a response.'}}
    try{
        if([int]$response.StatusCode -notin @(200,201)){throw "GitHub asset upload returned HTTP $([int]$response.StatusCode)."}
        $reader=[IO.StreamReader]::new($response.GetResponseStream());try{$asset=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
        if($asset.name -cne $Name -or [long]$asset.size -ne [long]$info.Length){throw 'GitHub uploaded asset metadata does not match the local file.'}
        return $asset
    }finally{$response.Dispose()}
}

function Publish-AuLocalPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Owner,[Parameter(Mandatory=$true)][string]$Repository,[Parameter(Mandatory=$true)][string]$AppId,[Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$Architecture)
    if($Owner -notmatch '^[A-Za-z0-9-]+$' -or $Repository -notmatch '^[A-Za-z0-9._-]+$'){throw 'Invalid GitHub repository identity.'}
    $manifestPath=Join-Path $PackageRoot 'manifest.json';if(-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw 'Local package manifest is missing.'}
    $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
    Test-AuPackagePayload -PackageRoot $PackageRoot -Manifest $manifest -AppId $AppId -Architecture $Architecture|Out-Null
    $token=Get-AuCredentialToken;$base="https://api.github.com/repos/$Owner/$Repository/releases";$tag='v'+[string]$manifest.version;$existing=$null;$draft=$null
    try{
        try{$existing=Invoke-AuGitHubApiJson -Method GET -Uri ([uri]($base+'/tags/'+[uri]::EscapeDataString($tag))) -Token $token}catch{if($_.Exception.Message -notmatch 'HTTP 404'){throw}}
        if($existing -and $existing.draft){
            return [pscustomobject]@{Status='draft-exists';AppId=$AppId;Version=[string]$manifest.version;ReleaseUrl=$existing.html_url;Message='A draft release already uses this version; it was left untouched for review.'}
        }
        if($existing){
            $publishedManifestAsset=@($existing.assets|Where-Object{$_.name -ceq 'autoupdate-manifest.json'})
            if($publishedManifestAsset.Count -eq 1){
                $manifestBytes=Invoke-AuGitHubGet -Uri ([uri]"https://api.github.com/repos/$Owner/$Repository/releases/assets/$($publishedManifestAsset[0].id)") -Token $token -Accept 'application/octet-stream' -MaximumBytes 1048576
                $publishedManifest=[Text.Encoding]::UTF8.GetString($manifestBytes)|ConvertFrom-Json
                if((Get-AuManifestFingerprint $publishedManifest) -ceq (Get-AuManifestFingerprint $manifest)){return [pscustomobject]@{Status='already-published';AppId=$AppId;Version=[string]$manifest.version;ReleaseUrl=$existing.html_url}}
            }
            return [pscustomobject]@{Status='conflict';AppId=$AppId;Version=[string]$manifest.version;ReleaseUrl=$existing.html_url;Message='A GitHub release already uses this version with different contents; local and remote packages were preserved.'}
        }
        $latest=$null
        try{$latest=Get-AuLatestReleaseManifest -Owner $Owner -Repository $Repository -AppId $AppId -Architecture $Architecture}catch{if($_.Exception.Message -notmatch 'HTTP 404'){throw}}
        if($latest -and [version]$latest.Manifest.version -gt [version]$manifest.version){return [pscustomobject]@{Status='remote-newer';AppId=$AppId;Version=[string]$latest.Manifest.version;Message='GitHub already has a newer package; the local package was not published.'}}
        $draft=Invoke-AuGitHubApiJson -Method POST -Uri ([uri]$base) -Token $token -Body ([ordered]@{tag_name=$tag;name="$AppId $($manifest.version)";body='Published by the shared AutoUpdate engine after local manifest and payload verification.';draft=$true;prerelease=$false;make_latest='false'})
        $assets=Get-AuReleaseUploadPlan -PackageRoot $PackageRoot -Manifest $manifest
        $uploadUri=[uri]([string]$draft.upload_url -replace '\{\?name,label\}$','')
        foreach($asset in $assets){[void](Send-AuGitHubReleaseAsset -UploadUri $uploadUri -Token $token -Name $asset.Name -Path $asset.Path)}
        $uploadedAssets=@(Invoke-AuGitHubApiJson -Method GET -Uri ([uri]($base+'/'+$draft.id+'/assets')) -Token $token)
        if($uploadedAssets.Count -ne $assets.Count){throw 'Draft release has a missing or unexpected asset.'}
        $uploadedMap=@{};foreach($asset in $uploadedAssets){if($uploadedMap.ContainsKey([string]$asset.name)){throw 'Draft release has duplicate asset names.'};$uploadedMap[[string]$asset.name]=$asset}
        foreach($planned in $assets){if(-not $uploadedMap.ContainsKey($planned.Name) -or [long]$uploadedMap[$planned.Name].size -ne [long](Get-Item -LiteralPath $planned.Path).Length){throw "Draft release asset metadata does not match: $($planned.Name)"}}
        $remoteManifestAsset=@($uploadedAssets|Where-Object{$_.name -ceq 'autoupdate-manifest.json'})
        if($remoteManifestAsset.Count -ne 1){throw 'Draft release manifest asset verification failed.'}
        $remoteBytes=Invoke-AuGitHubGet -Uri ([uri]"https://api.github.com/repos/$Owner/$Repository/releases/assets/$($remoteManifestAsset[0].id)") -Token $token -Accept 'application/octet-stream' -MaximumBytes 1048576
        $remoteManifest=[Text.Encoding]::UTF8.GetString($remoteBytes)|ConvertFrom-Json
        if((Get-AuManifestFingerprint $remoteManifest) -cne (Get-AuManifestFingerprint $manifest)){throw 'Published draft manifest differs from the verified local package.'}
        foreach($entry in $manifest.files){
            $uploaded=$uploadedMap[[string]$entry.asset];$tempAsset=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-upload-verify-'+[guid]::NewGuid().ToString('N'))
            try{
                Invoke-AuGitHubGet -Uri ([uri]"https://api.github.com/repos/$Owner/$Repository/releases/assets/$($uploaded.id)") -Token $token -Accept 'application/octet-stream' -OutFile $tempAsset -MaximumBytes ([long]$entry.size)|Out-Null
                if((Get-Item -LiteralPath $tempAsset).Length -ne [long]$entry.size -or (Get-AuFileSha256 $tempAsset) -cne ([string]$entry.sha256).ToLowerInvariant()){throw "Uploaded release asset failed SHA-256 verification: $($entry.asset)"}
            }finally{if(Test-Path -LiteralPath $tempAsset){Remove-Item -LiteralPath $tempAsset -Force -ErrorAction SilentlyContinue}}
        }
        $published=Invoke-AuGitHubApiJson -Method PATCH -Uri ([uri]($base+'/'+$draft.id)) -Token $token -Body ([ordered]@{draft=$false})
        $draft=$null
        return [pscustomobject]@{Status='published';AppId=$AppId;Version=[string]$manifest.version;ReleaseUrl=$published.html_url;Message='Verified local package was published as a stable GitHub release.'}
    }catch{
        if($draft){try{Invoke-AuGitHubApiJson -Method DELETE -Uri ([uri]($base+'/'+$draft.id)) -Token $token|Out-Null}catch{}}
        throw
    }finally{$token=$null}
}

function Test-AuPackagePayload {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)]$Manifest,[Parameter(Mandatory=$true)][string]$AppId,[Parameter(Mandatory=$true)][string]$Architecture)
    Test-AuManifest -Manifest $Manifest -ExpectedAppId $AppId | Out-Null
    if($Manifest.architecture -ne 'any' -and $Manifest.architecture -ne $Architecture){throw 'Package architecture mismatch.'}
    $packagePath=[IO.Path]::GetFullPath($PackageRoot)
    foreach($entry in $Manifest.files){
        $sourcePath=Get-AuContainedPath $packagePath ([string]$entry.source)
        if(-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)){throw "Package file is missing: $($entry.path)"}
        $info=Get-Item -LiteralPath $sourcePath
        if($info.Length -ne [long]$entry.size){throw "Package size mismatch: $($entry.path)"}
        if((Get-AuFileSha256 $sourcePath) -cne ([string]$entry.sha256).ToLowerInvariant()){throw "Package hash mismatch: $($entry.path)"}
    }
    return $true
}

function Save-AuPackageToLocal {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$LocalPackageRoot,[Parameter(Mandatory=$true)]$Manifest,[Parameter(Mandatory=$true)][string]$AppId,[Parameter(Mandatory=$true)][string]$Architecture)
    Test-AuPackagePayload -PackageRoot $PackageRoot -Manifest $Manifest -AppId $AppId -Architecture $Architecture|Out-Null
    $root=[IO.Path]::GetFullPath($LocalPackageRoot);[void][IO.Directory]::CreateDirectory($root)
    $target=Get-AuContainedPath $root ([string]$Manifest.version)
    if(Test-Path -LiteralPath $target){
        $existing=Get-Content -Raw -LiteralPath (Join-Path $target 'manifest.json')|ConvertFrom-Json
        if((Get-AuManifestFingerprint $existing) -cne (Get-AuManifestFingerprint $Manifest)){throw 'A local package already uses this version with different contents; both copies were preserved.'}
        return $target
    }
    $stage=Get-AuContainedPath $root ('.stage-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($stage)
    try{
        $manifestBytes=[Text.UTF8Encoding]::new($false).GetBytes(($Manifest|ConvertTo-Json -Depth 16))
        [IO.File]::WriteAllBytes((Join-Path $stage 'manifest.json'),$manifestBytes)
        [IO.File]::WriteAllBytes((Join-Path $stage 'autoupdate-manifest.json'),$manifestBytes)
        $payloadRoot=Join-Path $stage 'payload';[void][IO.Directory]::CreateDirectory($payloadRoot)
        foreach($entry in $Manifest.files){
            $source=Get-AuContainedPath $PackageRoot ([string]$entry.source);$destination=Get-AuContainedPath $payloadRoot ([string]$entry.path)
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination));[IO.File]::Copy($source,$destination,$false)
        }
        $staged=Get-Content -Raw -LiteralPath (Join-Path $stage 'manifest.json')|ConvertFrom-Json
        Test-AuPackagePayload -PackageRoot $stage -Manifest $staged -AppId $AppId -Architecture $Architecture|Out-Null
        [IO.Directory]::Move($stage,$target)
        return $target
    }catch{
        if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue}
        throw
    }
}

function Get-AuReleaseUploadPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)]$Manifest)
    $root=[IO.Path]::GetFullPath($PackageRoot);$manifestFile=Join-Path $root 'autoupdate-manifest.json'
    if(-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)){throw 'Release manifest asset is missing.'}
    $assets=@([pscustomobject]@{Name='autoupdate-manifest.json';Path=$manifestFile})
    foreach($entry in $Manifest.files){
        if([string]$entry.asset -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$'){throw 'Package contains an invalid release asset name.'}
        $assetPath=Get-AuContainedPath $root ([string]$entry.source)
        if(-not (Test-Path -LiteralPath $assetPath -PathType Leaf)){throw "Release payload asset is missing: $($entry.path)"}
        $assets+= [pscustomobject]@{Name=[string]$entry.asset;Path=$assetPath}
    }
    $names=@($assets|ForEach-Object{$_.Name});if(@($names|Select-Object -Unique).Count -ne $names.Count){throw 'Package contains duplicate release asset names.'}
    return $assets
}

function Get-AuLatestLocalPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$AppId,[Parameter(Mandatory=$true)][string]$Architecture)
    if(-not (Test-Path -LiteralPath $PackageRoot -PathType Container)){return $null}
    $candidates=@()
    if(Test-Path -LiteralPath (Join-Path $PackageRoot 'manifest.json') -PathType Leaf){$candidates+=Get-Item -LiteralPath $PackageRoot}
    else{$candidates+=@(Get-ChildItem -LiteralPath $PackageRoot -Directory -ErrorAction SilentlyContinue)}
    $valid=@()
    foreach($candidate in $candidates){
        $manifestPath=Join-Path $candidate.FullName 'manifest.json'
        if(-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)){continue}
        try{
            $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
            Test-AuPackagePayload -PackageRoot $candidate.FullName -Manifest $manifest -AppId $AppId -Architecture $Architecture|Out-Null
            $valid+= [pscustomobject]@{Path=$candidate.FullName;Manifest=$manifest}
        }catch{continue}
    }
    return $valid|Sort-Object @{Expression={[version]$_.Manifest.version};Descending=$true}|Select-Object -First 1
}

function Install-AuLatestAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Owner,[Parameter(Mandatory=$true)][string]$Repository,
        [Parameter(Mandatory=$true)][string]$AppId,[Parameter(Mandatory=$true)][string]$StateRoot,
        [Parameter(Mandatory=$true)][string]$Architecture,[Parameter(Mandatory=$true)][string]$LocalPackageRoot
    )
    $local=Get-AuLatestLocalPackage -PackageRoot $LocalPackageRoot -AppId $AppId -Architecture $Architecture
    $remote=Get-AuLatestReleaseManifest -Owner $Owner -Repository $Repository -AppId $AppId -Architecture $Architecture
    if(-not $local){
        if(-not $remote){return [pscustomobject]@{Status='legacy-release';AppId=$AppId;Version=$null;Path=$null;Mode=$null;Message='The latest GitHub release has no AutoUpdate package manifest; waiting for a compatible package.'}}
        return Install-AuLatestRelease -Owner $Owner -Repository $Repository -AppId $AppId -StateRoot $StateRoot -Architecture $Architecture -Candidate $remote -LocalPackageRoot $LocalPackageRoot
    }
    $remoteManifest=if($remote){$remote.Manifest}else{$null}
    $winner=Select-AuPackageWinner -LocalManifest $local.Manifest -RemoteManifest $remoteManifest
    if($winner -eq 'conflict'){return [pscustomobject]@{Status='conflict';AppId=$AppId;Version=[string]$local.Manifest.version;Path=$null;Mode=$null;Message='Local and GitHub packages have the same version but different contents; both were preserved.'}}
    $selectedVersion=if($winner -eq 'github'){[string]$remote.Manifest.version}else{[string]$local.Manifest.version}
    $current=Get-AuCurrent -StateRoot $StateRoot -AppId $AppId
    if($current -and [version]$current.Version -gt [version]$selectedVersion){return [pscustomobject]@{Status='already-current';AppId=$AppId;Version=$current.Version;Path=$current.Path;Mode=$current.Mode}}
    if($winner -eq 'github'){return Install-AuLatestRelease -Owner $Owner -Repository $Repository -AppId $AppId -StateRoot $StateRoot -Architecture $Architecture -Candidate $remote -LocalPackageRoot $LocalPackageRoot}
    if($current -and $current.Version -eq $selectedVersion){
        $installedManifest=Get-Content -Raw -LiteralPath (Join-Path $current.Path 'manifest.json')|ConvertFrom-Json
        if((Get-AuManifestFingerprint $installedManifest) -ceq (Get-AuManifestFingerprint $local.Manifest)){return [pscustomobject]@{Status='already-current';AppId=$AppId;Version=$selectedVersion;Path=$current.Path;Mode=[string]$local.Manifest.mode}}
        return [pscustomobject]@{Status='conflict';AppId=$AppId;Version=$selectedVersion;Path=$current.Path;Mode=[string]$local.Manifest.mode;Message='An installed package already uses this version with different contents; both copies were preserved.'}
    }
    return Install-AuPackage -PackageRoot $local.Path -StateRoot $StateRoot -AppId $AppId -Architecture $Architecture
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

function Get-AuVerifiedCurrent {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$StateRoot,[Parameter(Mandatory=$true)][string]$AppId,[ValidateSet('x86','x64','arm64')][string]$Architecture='x64')
    $current=Get-AuCurrent -StateRoot $StateRoot -AppId $AppId
    if(-not $current){return $null}
    $manifestPath=Join-Path $current.Path 'manifest.json'
    if(-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw 'Active package manifest is missing.'}
    if((Get-AuFileSha256 $manifestPath) -cne ([string]$current.Pointer.manifest_sha256).ToLowerInvariant()){throw 'Active package manifest hash is invalid.'}
    $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
    Test-AuManifest -Manifest $manifest -ExpectedAppId $AppId|Out-Null
    if($manifest.architecture -ne 'any' -and $manifest.architecture -ne $Architecture){throw 'Active package architecture does not match this application.'}
    if([string]$manifest.version -cne $current.Version -or [string]$manifest.mode -cne $current.Mode){throw 'Active package pointer does not match its manifest.'}
    foreach($entry in $manifest.files){
        $filePath=Get-AuContainedPath $current.Path ([string]$entry.path)
        if(-not (Test-Path -LiteralPath $filePath -PathType Leaf)){throw "Active package file is missing: $($entry.path)"}
        $file=Get-Item -LiteralPath $filePath
        if($file.Length -ne [long]$entry.size){throw "Active package size is invalid: $($entry.path)"}
        if((Get-AuFileSha256 $filePath) -cne ([string]$entry.sha256).ToLowerInvariant()){throw "Active package hash is invalid: $($entry.path)"}
    }
    return [pscustomobject]@{AppId=$current.AppId;Version=$current.Version;Mode=$current.Mode;Path=$current.Path;Pointer=$current.Pointer;Manifest=$manifest;Verified=$true}
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
    if ($current -and $current.Version -eq $manifest.version) {
        $installedManifest=Get-Content -Raw -LiteralPath (Join-Path $current.Path 'manifest.json')|ConvertFrom-Json
        if((Get-AuManifestFingerprint $installedManifest) -ceq (Get-AuManifestFingerprint $manifest)){return [pscustomobject]@{Status='already-current';AppId=$AppId;Version=$manifest.version;Path=$current.Path;Mode=$manifest.mode}}
        return [pscustomobject]@{Status='conflict';AppId=$AppId;Version=$manifest.version;Path=$current.Path;Mode=$manifest.mode;Message='An installed package has the same version but different contents; both copies were preserved.'}
    }
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

function Test-AuModuleManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Manifest,[Parameter(Mandatory=$true)][string]$ExpectedModuleId)
    if($Manifest.schema -ne 1 -or $Manifest.contract -cne 'autoupdate-module-v1'){throw 'Unsupported module manifest schema or contract.'}
    if($ExpectedModuleId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $Manifest.module_id -cne $ExpectedModuleId){throw 'Module identity mismatch.'}
    if([string]$Manifest.version -notmatch '^\d+\.\d+\.\d+$'){throw 'Invalid module version.'}
    if([string]$Manifest.api_major -notmatch '^[1-9]\d*$'){throw 'Invalid module API major version.'}
    if([string]$Manifest.minimum_engine -notmatch '^\d+\.\d+\.\d+$'){throw 'Invalid minimum AutoUpdate version.'}
    if(-not (Test-AuVersionAtLeast $script:AutoUpdateEngineVersion ([string]$Manifest.minimum_engine))){throw 'This module requires a newer AutoUpdate version.'}
    if($Manifest.publisher_policy -cne 'local-share-v1'){throw 'Unrecognized local module publisher policy.'}
    if($Manifest.activation_mode -notin @('live','restart')){throw 'Invalid module activation mode.'}
    if($Manifest.activation_mode -eq 'live' -and $Manifest.reload_contract -notin @('stateless-v1','reload-hook-v1')){throw 'Live modules must declare a supported reload contract.'}
    if($Manifest.files -isnot [System.Array] -or $Manifest.files.Count -lt 1){throw 'A module package must contain at least one file.'}
    $seen=@{}
    foreach($file in $Manifest.files){
        foreach($field in @('path','kind','size','sha256','source')){if($null -eq $file.$field){throw \"Module manifest file entry is missing $field.\"}}
        $relative=[string]$file.path
        if([string]::IsNullOrWhiteSpace($relative) -or $relative -match '(^[/\\]|^[A-Za-z]:|(^|[/\\])\.\.([/\\]|$)|:|[\x00-\x1f])'){throw 'Unsafe module payload path.'}
        $normalized=$relative.Replace('\','/').ToLowerInvariant()
        if($seen.ContainsKey($normalized)){throw 'Duplicate module payload path.'}
        $seen[$normalized]=$true
        if($file.kind -notin @('data','resource','executable','runtime')){throw 'Unsupported module payload kind.'}
        if($Manifest.activation_mode -eq 'live' -and $file.kind -in @('executable','runtime') -and $Manifest.reload_contract -notin @('stateless-v1','reload-hook-v1')){throw 'Executable live modules require an explicit reload contract.'}
        if([long]$file.size -lt 0 -or [long]$file.size -gt 268435456){throw 'Invalid or excessive module payload size.'}
        if([string]$file.sha256 -notmatch '^[A-Fa-f0-9]{64}$'){throw 'Invalid module payload SHA-256.'}
        if([string]$file.source -match '(^[/\\]|^[A-Za-z]:|(^|[/\\])\.\.([/\\]|$)|:|[\x00-\x1f])'){throw 'Unsafe module package source.'}
    }
    return $true
}

function Get-AuModuleManifestFromPackage {
    param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$ModuleId,[switch]$InstalledLayout)
    $manifestPath=Get-AuContainedPath $PackageRoot 'module.json'
    if(-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw 'Module package manifest is missing.'}
    $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
    Test-AuModuleManifest -Manifest $manifest -ExpectedModuleId $ModuleId|Out-Null
    foreach($entry in $manifest.files){
        $contentPath=if($InstalledLayout){[string]$entry.path}else{[string]$entry.source}
        $source=Get-AuContainedPath $PackageRoot $contentPath
        if(-not (Test-Path -LiteralPath $source -PathType Leaf)){throw \"Module package file is missing: $($entry.path)\"}
        $info=Get-Item -LiteralPath $source
        if($info.Length -ne [long]$entry.size){throw \"Module package size mismatch: $($entry.path)\"}
        if((Get-AuFileSha256 $source) -cne ([string]$entry.sha256).ToLowerInvariant()){throw \"Module package hash mismatch: $($entry.path)\"}
    }
    return [pscustomobject]@{Manifest=$manifest;ManifestPath=$manifestPath;ManifestHash=(Get-AuFileSha256 $manifestPath)}
}

function Get-AuCurrentModule {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$StateRoot,[Parameter(Mandatory=$true)][string]$ModuleId)
    if($ModuleId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'){throw 'Invalid module identity.'}
    $moduleRoot=Get-AuContainedPath $StateRoot \"modules/$ModuleId\"
    $pointerPath=Join-Path $moduleRoot 'current.json'
    if(-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)){return $null}
    $pointer=Get-Content -Raw -LiteralPath $pointerPath|ConvertFrom-Json
    if($pointer.schema -ne 1 -or $pointer.module_id -cne $ModuleId -or [string]$pointer.version -notmatch '^\d+\.\d+\.\d+$' -or [string]$pointer.manifest_sha256 -notmatch '^[A-Fa-f0-9]{64}$'){throw 'Module cache pointer is invalid.'}
    $versionRoot=Get-AuContainedPath (Join-Path $moduleRoot 'versions') ([string]$pointer.version)
    if(-not (Test-Path -LiteralPath $versionRoot -PathType Container)){throw 'Active module version directory is missing.'}
    $verified=Get-AuVerifiedModuleVersion -StateRoot $StateRoot -ModuleId $ModuleId -Version ([string]$pointer.version)
    if($verified.ManifestHash -cne ([string]$pointer.manifest_sha256).ToLowerInvariant() -or [int]$verified.ApiMajor -ne [int]$pointer.api_major){throw 'Active module pointer does not match its verified manifest.'}
    return [pscustomobject]@{ModuleId=$ModuleId;Version=[string]$pointer.version;Path=$versionRoot;Pointer=$pointer}
}

function Get-AuVerifiedModuleVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$StateRoot,[Parameter(Mandatory=$true)][string]$ModuleId,[Parameter(Mandatory=$true)][string]$Version,[int]$ApiMajor=0)
    if($Version -notmatch '^\d+\.\d+\.\d+$'){throw 'Invalid module version.'}
    $versionRoot=Get-AuContainedPath (Get-AuContainedPath $StateRoot \"modules/$ModuleId/versions\") $Version
    if(-not (Test-Path -LiteralPath $versionRoot -PathType Container)){return $null}
    $info=Get-AuModuleManifestFromPackage -PackageRoot $versionRoot -ModuleId $ModuleId -InstalledLayout
    if([string]$info.Manifest.version -cne $Version){throw 'Module directory version does not match its manifest.'}
    if($ApiMajor -gt 0 -and [int]$info.Manifest.api_major -ne $ApiMajor){throw \"Cached module $ModuleId/$Version has an incompatible API major.\"}
    return [pscustomobject]@{ModuleId=$ModuleId;Version=$Version;ApiMajor=[int]$info.Manifest.api_major;ActivationMode=[string]$info.Manifest.activation_mode;Path=$versionRoot;Manifest=$info.Manifest;ManifestHash=$info.ManifestHash;Verified=$true}
}

function Get-AuCachedModuleVersions {
    param([Parameter(Mandatory=$true)][string]$StateRoot,[Parameter(Mandatory=$true)][string]$ModuleId,[int]$ApiMajor=0)
    $versionsRoot=Get-AuContainedPath $StateRoot \"modules/$ModuleId/versions\"
    if(-not (Test-Path -LiteralPath $versionsRoot -PathType Container)){return @()}
    $available=[Collections.Generic.List[object]]::new()
    foreach($directory in Get-ChildItem -LiteralPath $versionsRoot -Directory -ErrorAction SilentlyContinue){
        if($directory.Name -notmatch '^\d+\.\d+\.\d+$'){continue}
        try{
            $version=Get-AuVerifiedModuleVersion -StateRoot $StateRoot -ModuleId $ModuleId -Version $directory.Name -ApiMajor $ApiMajor
            if($version){$available.Add($version)}
        }catch{}
    }
    return @($available|Sort-Object { [version]$_.Version } -Descending)
}

function Install-AuModulePackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$PackageRoot,
        [Parameter(Mandatory=$true)][string]$StateRoot,
        [Parameter(Mandatory=$true)][string]$ModuleId,
        [switch]$FailActivationForTest
    )
    if($ModuleId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'){throw 'Invalid module identity.'}
    $mutex=[Threading.Mutex]::new($false,('Local\AutoUpdateModule_'+$ModuleId));$owned=$false
    try{
        try{$owned=$mutex.WaitOne(30000)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){throw 'Another updater is installing this module.'}
        $package=[IO.Path]::GetFullPath($PackageRoot)
        $packageInfo=Get-AuModuleManifestFromPackage -PackageRoot $package -ModuleId $ModuleId
        $manifest=$packageInfo.Manifest
        $version=[string]$manifest.version
        $moduleRoot=Get-AuContainedPath $StateRoot \"modules/$ModuleId\"
        $versionsRoot=Join-Path $moduleRoot 'versions';$stagingRoot=Join-Path $moduleRoot 'staging'
        [void][IO.Directory]::CreateDirectory($versionsRoot);[void][IO.Directory]::CreateDirectory($stagingRoot)
        $versionPath=Get-AuContainedPath $versionsRoot $version
        if(Test-Path -LiteralPath $versionPath -PathType Container){
            $existing=Get-AuModuleManifestFromPackage -PackageRoot $versionPath -ModuleId $ModuleId -InstalledLayout
            if($existing.ManifestHash -cne $packageInfo.ManifestHash){return [pscustomobject]@{Status='conflict';ModuleId=$ModuleId;Version=$version;Path=$versionPath;Message='This module version already exists with different contents; both source copies were preserved.'}}
            $installed=[pscustomobject]@{Status='already-cached';ModuleId=$ModuleId;Version=$version;Path=$versionPath;Message='This immutable module version is already cached.'}
        }else{
            $stage=Join-Path $stagingRoot ([guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($stage)
            try{
                foreach($entry in $manifest.files){
                    $source=Get-AuContainedPath $package ([string]$entry.source)
                    $destination=Get-AuContainedPath $stage ([string]$entry.path)
                    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
                    [IO.File]::Copy($source,$destination,$false)
                }
                [IO.File]::WriteAllBytes((Join-Path $stage 'module.json'),[IO.File]::ReadAllBytes($packageInfo.ManifestPath))
                [void](Get-AuModuleManifestFromPackage -PackageRoot $stage -ModuleId $ModuleId -InstalledLayout)
                if($FailActivationForTest){throw 'Injected module installation failure.'}
                [IO.Directory]::Move($stage,$versionPath)
            }catch{
                if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}
                throw
            }
            $installed=[pscustomobject]@{Status='cached';ModuleId=$ModuleId;Version=$version;Path=$versionPath;Message='Verified immutable module version was cached.'}
        }
        $pointerPath=Join-Path $moduleRoot 'current.json'
        $current=Get-AuCurrentModule -StateRoot $StateRoot -ModuleId $ModuleId
        if(-not $current -or [version]$version -gt [version]$current.Version){
            $pointer=[ordered]@{schema=1;module_id=$ModuleId;version=$version;api_major=[int]$manifest.api_major;manifest_sha256=$packageInfo.ManifestHash;activated_utc=[DateTime]::UtcNow.ToString('o')}
            $temporary=$pointerPath+'.'+[guid]::NewGuid().ToString('N')+'.part'
            $previous=Join-Path $moduleRoot 'previous.json'
            [IO.File]::WriteAllText($temporary,($pointer|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
            try{
                if(Test-Path -LiteralPath $pointerPath -PathType Leaf){
                    if(Test-Path -LiteralPath $previous -PathType Leaf){Remove-Item -LiteralPath $previous -Force}
                    [IO.File]::Replace($temporary,$pointerPath,$previous,$true)
                }else{[IO.File]::Move($temporary,$pointerPath)}
            }catch{
                if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}
                if($installed.Status -eq 'cached' -and (Test-Path -LiteralPath $versionPath)){Remove-Item -LiteralPath $versionPath -Recurse -Force}
                throw
            }
            $installed.Status=if($installed.Status -eq 'already-cached'){'activated-cached'}else{'activated'}
        }elseif([version]$version -lt [version]$current.Version){
            $installed.Status=if($installed.Status -eq 'already-cached'){'compatible-cache-ready'}else{'cached-compatible'}
        }
        return $installed
    }finally{if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
}

function Publish-AuLocalModulePackage {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$ModuleSourceRoot,[Parameter(Mandatory=$true)][string]$ModuleId)
    $package=[IO.Path]::GetFullPath($PackageRoot)
    $info=Get-AuModuleManifestFromPackage -PackageRoot $package -ModuleId $ModuleId
    $moduleRoot=Get-AuContainedPath $ModuleSourceRoot $ModuleId
    $versionsRoot=Join-Path $moduleRoot 'versions';$stageRoot=Join-Path $moduleRoot 'staging'
    [void][IO.Directory]::CreateDirectory($versionsRoot);[void][IO.Directory]::CreateDirectory($stageRoot)
    $version=[string]$info.Manifest.version
    $target=Get-AuContainedPath $versionsRoot $version
    $pointerPath=Join-Path $moduleRoot 'current.json'
    $currentVersion=$null
    if(Test-Path -LiteralPath $pointerPath -PathType Leaf){
        $current=Get-Content -Raw -LiteralPath $pointerPath|ConvertFrom-Json
        if($current.schema -ne 1 -or $current.module_id -cne $ModuleId -or [string]$current.version -notmatch '^\d+\.\d+\.\d+$' -or [string]$current.manifest_sha256 -notmatch '^[A-Fa-f0-9]{64}$'){throw 'Published module pointer is invalid.'}
        $currentVersion=[string]$current.version
        $currentPackage=Get-AuModuleManifestFromPackage -PackageRoot (Get-AuContainedPath $versionsRoot $currentVersion) -ModuleId $ModuleId
        if($currentPackage.ManifestHash -cne ([string]$current.manifest_sha256).ToLowerInvariant()){throw 'Published module pointer does not match its manifest.'}
        if([version]$currentVersion -gt [version]$version){throw 'Publishing an older module version is blocked.'}
    }
    if(Test-Path -LiteralPath $target -PathType Container){
        $existing=Get-AuModuleManifestFromPackage -PackageRoot $target -ModuleId $ModuleId
        if($existing.ManifestHash -cne $info.ManifestHash){return [pscustomobject]@{Status='conflict';ModuleId=$ModuleId;Version=$version;Path=$target;Message='This published module version already contains different content; neither copy was overwritten.'}}
    }else{
        $stage=Join-Path $stageRoot ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($stage)
        try{
            foreach($entry in $info.Manifest.files){
                $source=Get-AuContainedPath $package ([string]$entry.source)
                $destination=Get-AuContainedPath $stage ([string]$entry.source)
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
                [IO.File]::Copy($source,$destination,$false)
            }
            [IO.File]::WriteAllBytes((Join-Path $stage 'module.json'),[IO.File]::ReadAllBytes($info.ManifestPath))
            [void](Get-AuModuleManifestFromPackage -PackageRoot $stage -ModuleId $ModuleId)
            [IO.Directory]::Move($stage,$target)
        }catch{
            if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}
            throw
        }
    }
    if(-not $currentVersion -or [version]$version -gt [version]$currentVersion){
        $pointer=[ordered]@{schema=1;module_id=$ModuleId;version=$version;api_major=[int]$info.Manifest.api_major;manifest_sha256=$info.ManifestHash;published_utc=[DateTime]::UtcNow.ToString('o')}
        $temporary=$pointerPath+'.'+[guid]::NewGuid().ToString('N')+'.part';$previous=Join-Path $moduleRoot 'previous.json'
        [IO.File]::WriteAllText($temporary,($pointer|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        try{
            if(Test-Path -LiteralPath $pointerPath -PathType Leaf){
                if(Test-Path -LiteralPath $previous -PathType Leaf){Remove-Item -LiteralPath $previous -Force}
                [IO.File]::Replace($temporary,$pointerPath,$previous,$true)
            }else{[IO.File]::Move($temporary,$pointerPath)}
        }catch{
            if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}
            throw
        }
        return [pscustomobject]@{Status='published';ModuleId=$ModuleId;Version=$version;Path=$target;Message='Immutable module version was verified and the source pointer was advanced.'}
    }
    return [pscustomobject]@{Status='already-published';ModuleId=$ModuleId;Version=$version;Path=$target;Message='Identical immutable module version is already published.'}
}

function Update-AuModuleFromLocalSource {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ModuleSourceRoot,[Parameter(Mandatory=$true)][string]$StateRoot,[Parameter(Mandatory=$true)][string]$ModuleId,[Parameter(Mandatory=$true)][int]$ApiMajor)
    if($ApiMajor -lt 1){throw 'Required module API major must be positive.'}
    $moduleRoot=Get-AuContainedPath $ModuleSourceRoot $ModuleId
    $pointerPath=Join-Path $moduleRoot 'current.json'
    if(-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)){throw \"Local module source has no current pointer: $ModuleId\"}
    $pointer=Get-Content -Raw -LiteralPath $pointerPath|ConvertFrom-Json
    if($pointer.schema -ne 1 -or $pointer.module_id -cne $ModuleId -or [string]$pointer.version -notmatch '^\d+\.\d+\.\d+$' -or [string]$pointer.manifest_sha256 -notmatch '^[A-Fa-f0-9]{64}$'){throw 'Local module source pointer is invalid.'}
    $publishedVersion=[version]$pointer.version
    $versionsRoot=Get-AuContainedPath $moduleRoot 'versions'
    $candidates=[Collections.Generic.List[object]]::new()
    foreach($directory in Get-ChildItem -LiteralPath $versionsRoot -Directory -ErrorAction SilentlyContinue){
        if($directory.Name -notmatch '^\d+\.\d+\.\d+$' -or [version]$directory.Name -gt $publishedVersion){continue}
        try{
            $info=Get-AuModuleManifestFromPackage -PackageRoot $directory.FullName -ModuleId $ModuleId
            if($directory.Name -ceq [string]$pointer.version -and $info.ManifestHash -cne ([string]$pointer.manifest_sha256).ToLowerInvariant()){throw 'Published pointer does not match current module manifest.'}
            if([int]$info.Manifest.api_major -eq $ApiMajor){$candidates.Add([pscustomobject]@{Version=$directory.Name;Path=$directory.FullName;Manifest=$info.Manifest;ManifestHash=$info.ManifestHash})}
        }catch{
            if($directory.Name -ceq [string]$pointer.version){throw}
        }
    }
    $candidate=@($candidates|Sort-Object { [version]$_.Version } -Descending|Select-Object -First 1)
    if($candidate.Count -eq 0){throw \"No valid local module version supports API ${ApiMajor}: $ModuleId\"}
    return Install-AuModulePackage -PackageRoot $candidate[0].Path -StateRoot $StateRoot -ModuleId $ModuleId
}

function Resolve-AuAppModules {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$AppManifestPath,[Parameter(Mandatory=$true)][string]$ModuleSourceRoot,[Parameter(Mandatory=$true)][string]$StateRoot)
    if(-not (Test-Path -LiteralPath $AppManifestPath -PathType Leaf)){throw 'App module manifest is missing.'}
    $app=Get-Content -Raw -LiteralPath $AppManifestPath|ConvertFrom-Json
    if($app.schema -ne 1 -or $app.contract -cne 'autoupdate-app-modules-v1' -or [string]$app.app_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'){throw 'Unsupported app module manifest.'}
    if($app.modules -isnot [System.Array]){throw 'App module list must be an array.'}
    $seen=@{};$resolved=[Collections.Generic.List[object]]::new()
    foreach($requirement in $app.modules){
        $moduleId=[string]$requirement.module_id;$apiMajor=[int]$requirement.api_major
        if($moduleId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $apiMajor -lt 1){throw 'App module requirement is invalid.'}
        if($seen.ContainsKey($moduleId.ToLowerInvariant())){throw 'App module list contains a duplicate module ID.'}
        $seen[$moduleId.ToLowerInvariant()]=$true
        $sourceStatus='offline-cache';$sourceError=$null
        try{
            $update=Update-AuModuleFromLocalSource -ModuleSourceRoot $ModuleSourceRoot -StateRoot $StateRoot -ModuleId $moduleId -ApiMajor $apiMajor
            $sourceStatus=[string]$update.Status
        }catch{$sourceError=$_.Exception.Message}
        $cached=@(Get-AuCachedModuleVersions -StateRoot $StateRoot -ModuleId $moduleId -ApiMajor $apiMajor)
        if($cached.Count -eq 0){
            if($sourceError){throw \"Required module $moduleId API $apiMajor is unavailable. $sourceError\"}
            throw \"Required module $moduleId API $apiMajor is not cached.\"
        }
        $chosen=$cached[0]
        $resolved.Add([pscustomobject]@{module_id=$moduleId;version=$chosen.Version;api_major=$chosen.ApiMajor;activation_mode=$chosen.ActivationMode;module_path=$chosen.Path;verified=$true;source_status=$sourceStatus;source_error=$sourceError})
    }
    return [pscustomobject]@{schema=1;status='ready';app_id=[string]$app.app_id;modules=@($resolved)}
}

Export-ModuleMember -Function Test-AuManifest,Test-AuModuleManifest,Test-AuReleaseTagVersion,Install-AuPackage,Install-AuModulePackage,Publish-AuLocalModulePackage,Update-AuModuleFromLocalSource,Resolve-AuAppModules,Install-AuLatestRelease,Install-AuLatestAvailable,Publish-AuLocalPackage,Save-AuPackageToLocal,Get-AuReleaseUploadPlan,Get-AuLatestReleaseManifest,Compare-AuPackageCandidates,Get-AuLatestLocalPackage,Get-AuCurrent,Get-AuVerifiedCurrent,Get-AuCurrentModule,Get-AuVerifiedModuleVersion,Get-AuCachedModuleVersions,Get-AuFileSha256,Get-AuRegisteredApps,Register-AuApplication
