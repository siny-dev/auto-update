param(
    [Parameter(Mandatory=$true)][string]$RecipePath,
    [Parameter(Mandatory=$true)][string]$PackageRoot,
    [string]$RemoteVersion
)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$requiredEngineFunctions=@('Compare-AuPackageCandidates','Get-AuLatestLocalPackage')
$loadedEngine=Get-Module -Name 'AutoUpdate.Core' -ErrorAction SilentlyContinue|Select-Object -First 1
$engineApiReady=$false
if($loadedEngine){
    $availableFunctions=@(Get-Command -Module $loadedEngine.Name -ErrorAction SilentlyContinue|Select-Object -ExpandProperty Name)
    $engineApiReady=@($requiredEngineFunctions|Where-Object{$_ -notin $availableFunctions}).Count -eq 0
}
# The background worker loads a versioned engine before calling this builder. Keep
# that engine active; importing the checkout with -Force would replace it mid-cycle.
if(-not $engineApiReady){Import-Module (Join-Path $repoRoot 'source\AutoUpdate.Core.psm1') -Force -Scope Local}
$recipeFile=[IO.Path]::GetFullPath($RecipePath)
$packageDirectory=[IO.Path]::GetFullPath($PackageRoot)
$spec=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($recipeFile))|ConvertFrom-Json
if($spec.app_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'){throw 'Invalid app_id in build recipe.'}
$seed=[string]$spec.version_seed
if(-not $seed){$seed=[string]$spec.version}
if($seed -notmatch '^\d+\.\d+\.\d+$'){throw 'Recipe must define version_seed as major.minor.patch.'}
if($RemoteVersion -and $RemoteVersion -notmatch '^\d+\.\d+\.\d+$'){throw 'RemoteVersion must be major.minor.patch.'}
if(-not $spec.files -or $spec.files.Count -lt 1){throw 'Build recipe must list at least one package file.'}
$payloadRoot=[string]$spec.payload_root
if([string]::IsNullOrWhiteSpace($payloadRoot)){throw 'Build recipe must set payload_root.'}
if(-not [IO.Path]::IsPathRooted($payloadRoot)){$payloadRoot=Join-Path (Split-Path -Parent $recipeFile) $payloadRoot}
$payloadRoot=[IO.Path]::GetFullPath($payloadRoot)
[void][IO.Directory]::CreateDirectory($packageDirectory)
$versionRoot=$packageDirectory
$statePath=Join-Path $packageDirectory '.build-state.json'
$state=$null;if(Test-Path -LiteralPath $statePath -PathType Leaf){$state=Get-Content -Raw -LiteralPath $statePath|ConvertFrom-Json;if($state.app_id -cne $spec.app_id){throw 'Build state app identity mismatch.'}}
function Resolve-PayloadFile([string]$Root,[string]$Relative){
    if([string]::IsNullOrWhiteSpace($Relative) -or $Relative -match '(^[/\\]|^[A-Za-z]:|(^|[/\\])\.\.([/\\]|$)|:|[\x00-\x1f])'){throw 'Unsafe build payload path.'}
    $base=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $full=[IO.Path]::GetFullPath((Join-Path $base ($Relative.Replace('/',[IO.Path]::DirectorySeparatorChar))))
    if(-not $full.StartsWith($base+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Payload file escapes payload_root.'}
    if(-not (Test-Path -LiteralPath $full -PathType Leaf)){throw "Build payload is missing: $Relative"}
    return $full
}
function Get-RecipeVersionMetadataVersion($Recipe,[string]$Root){
    $contract=$Recipe.version_metadata
    if(-not $contract){return $null}
    $path=[string]$contract.path;$field=[string]$contract.field;$prefix=[string]$contract.prefix
    if([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($field)){throw 'version_metadata must define path and field.'}
    $metadataPath=Resolve-PayloadFile $Root $path
    $document=Get-Content -Raw -LiteralPath $metadataPath|ConvertFrom-Json
    $property=$document.PSObject.Properties[$field]
    if(-not $property){throw 'version_metadata field is missing from the payload.'}
    $embedded=[string]$property.Value
    if($prefix){
        if(-not $embedded.StartsWith($prefix,[StringComparison]::Ordinal)){return $null}
        $embedded=$embedded.Substring($prefix.Length)
    }
    if($embedded -notmatch '^\d+\.\d+\.\d+$'){throw 'version_metadata value must resolve to major.minor.patch.'}
    return [version]$embedded
}
function Test-RecipeVersionMetadataMatches($Recipe,[string]$Root,[string]$ExpectedVersion){
    if(-not $Recipe.version_metadata){return $true}
    $embeddedVersion=Get-RecipeVersionMetadataVersion $Recipe $Root
    if($null -eq $embeddedVersion){return $false}
    return $embeddedVersion.Equals([version]$ExpectedVersion)
}
function Get-RecipeFingerprint($Recipe,[string]$Root){
    $items=@([string]$Recipe.app_id,[string]$Recipe.platform,[string]$Recipe.architecture,[string]$Recipe.mode,[string]$Recipe.minimum_engine)
    if($Recipe.version_metadata){$items+=("version_metadata|{0}|{1}|{2}" -f [string]$Recipe.version_metadata.path,[string]$Recipe.version_metadata.field,[string]$Recipe.version_metadata.prefix)}
    foreach($file in @($Recipe.files|Sort-Object path)){
        if($file.kind -notin @('data','resource','executable','runtime')){throw 'Unsupported package file kind in build recipe.'}
        $path=Resolve-PayloadFile $Root ([string]$file.path);$info=Get-Item -LiteralPath $path;$hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $items+=('{0}|{1}|{2}|{3}' -f ([string]$file.path).Replace('\','/'),[string]$file.kind,[long]$info.Length,$hash)
    }
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes([string]::Join("`n",$items));$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Get-RecipeMode($Recipe){
    if($Recipe.mode -in @('live','restart')){return [string]$Recipe.mode}
    if(@($Recipe.files|Where-Object{$_.kind -in @('executable','runtime')}).Count -gt 0){return 'restart'}
    return 'live'
}
function Test-RecipeMatchesManifest($Recipe,[string]$Root,$Manifest){
    if(-not (Test-RecipeVersionMetadataMatches $Recipe $Root ([string]$Manifest.version))){return $false}
    if($Manifest.app_id -cne $Recipe.app_id -or $Manifest.platform -cne $Recipe.platform -or $Manifest.architecture -cne $Recipe.architecture -or $Manifest.minimum_engine -cne $Recipe.minimum_engine -or $Manifest.mode -cne (Get-RecipeMode $Recipe)){return $false}
    if(@($Manifest.files).Count -ne @($Recipe.files).Count){return $false}
    foreach($entry in $Manifest.files){
        $declared=@($Recipe.files|Where-Object{$_.path -ceq $entry.path})
        if($declared.Count -ne 1 -or [string]$declared[0].kind -cne [string]$entry.kind){return $false}
        $path=Resolve-PayloadFile $Root ([string]$entry.path);$info=Get-Item -LiteralPath $path
        if([long]$info.Length -ne [long]$entry.size -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine [string]$entry.sha256){return $false}
    }
    return $true
}
function Write-BuildState($Path,$Document){
    $tmp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.part';[IO.File]::WriteAllText($tmp,($Document|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    if([IO.File]::Exists($Path)){$backup=$Path+'.bak';[IO.File]::Replace($tmp,$Path,$backup,$true);if([IO.File]::Exists($backup)){[IO.File]::Delete($backup)}}else{[IO.File]::Move($tmp,$Path)}
}
function Get-NextPackageVersion([version]$Current){
    if($Current.Build -lt 2147483647){return '{0}.{1}.{2}' -f $Current.Major,$Current.Minor,($Current.Build+1)}
    if($Current.Minor -lt 2147483647){return '{0}.{1}.0' -f $Current.Major,($Current.Minor+1)}
    if($Current.Major -lt 2147483647){return '{0}.0.0' -f ($Current.Major+1)}
    throw 'Package version counter exhausted.'
}
function Copy-PackageDirectoryAtomically([string]$Source,[string]$Destination){
    if(Test-Path -LiteralPath $Destination){throw 'Package destination already exists; packages are immutable.'}
    $parent=Split-Path -Parent $Destination;[void][IO.Directory]::CreateDirectory($parent)
    $temporary=Join-Path $parent ((Split-Path -Leaf $Destination)+'.'+[guid]::NewGuid().ToString('N')+'.part')
    [void][IO.Directory]::CreateDirectory($temporary)
    try{
        foreach($child in (Get-ChildItem -LiteralPath $Source -Force)){
            Copy-Item -LiteralPath $child.FullName -Destination $temporary -Recurse -Force
        }
        [IO.Directory]::Move($temporary,$Destination)
    }catch{
        if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue}
        throw
    }
}
$fingerprint=Get-RecipeFingerprint $spec $payloadRoot
$architecture=[string]$spec.architecture;if($architecture -notin @('any','x86','x64','arm64')){throw 'Build recipe has an invalid architecture.'}
$existingPackage=Get-AuLatestLocalPackage -PackageRoot $packageDirectory -AppId ([string]$spec.app_id) -Architecture $architecture
if($state -and $state.source_fingerprint -ceq $fingerprint -and $existingPackage -and [string]$existingPackage.Manifest.version -ceq [string]$state.version -and (-not $RemoteVersion -or [version]$existingPackage.Manifest.version -ge [version]$RemoteVersion) -and (Test-RecipeMatchesManifest $spec $payloadRoot $existingPackage.Manifest)){
    [pscustomobject]@{status='unchanged';app_id=$spec.app_id;version=$state.version;message='Source files and the last built package are unchanged.'}|ConvertTo-Json -Compress
    exit 0
}
if($existingPackage -and (-not $RemoteVersion -or [version]$existingPackage.Manifest.version -ge [version]$RemoteVersion) -and (Test-RecipeMatchesManifest $spec $payloadRoot $existingPackage.Manifest)){
    Write-BuildState $statePath ([ordered]@{schema=1;app_id=[string]$spec.app_id;version=[string]$existingPackage.Manifest.version;source_fingerprint=$fingerprint;updated_utc=[DateTime]::UtcNow.ToString('o')})
    [pscustomobject]@{status='unchanged';app_id=$spec.app_id;version=[string]$existingPackage.Manifest.version;message='Source files already match an existing package.'}|ConvertTo-Json -Compress
    exit 0
}
$latestVersion=$null
if($state -and $state.version -match '^\d+\.\d+\.\d+$'){$latestVersion=[version]$state.version}
foreach($versionPath in (Get-ChildItem -LiteralPath $versionRoot -Directory -ErrorAction SilentlyContinue)){
    if($versionPath.Name -match '^\d+\.\d+\.\d+$'){$candidate=[version]$versionPath.Name;if(-not $latestVersion -or $candidate -gt $latestVersion){$latestVersion=$candidate}}
}
if($RemoteVersion){$remote=[version]$RemoteVersion;if(-not $latestVersion -or $remote -gt $latestVersion){$latestVersion=$remote}}
$embeddedVersion=Get-RecipeVersionMetadataVersion $spec $payloadRoot
if($embeddedVersion -and (-not $latestVersion -or $embeddedVersion -gt $latestVersion)){
    $packageVersion='{0}.{1}.{2}' -f $embeddedVersion.Major,$embeddedVersion.Minor,$embeddedVersion.Build
}elseif(-not $latestVersion){$packageVersion=$seed}else{$packageVersion=Get-NextPackageVersion $latestVersion}
if(-not (Test-RecipeVersionMetadataMatches $spec $payloadRoot $packageVersion)){throw ('Embedded version metadata does not match package version '+$packageVersion+'.')}
if($spec.PSObject.Properties['version']){$spec.version=$packageVersion}else{$spec|Add-Member -NotePropertyName version -NotePropertyValue $packageVersion}
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('AutoUpdate-local-build-'+[guid]::NewGuid().ToString('N'));$tempOutput=Join-Path $tempRoot 'package';$tempSpec=Join-Path $tempRoot 'build.json';[void][IO.Directory]::CreateDirectory($tempRoot)
$preserveOutput=$false
try{
    [IO.File]::WriteAllText($tempSpec,($spec|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    & (Join-Path $PSScriptRoot 'new-release-package.ps1') -SpecPath $tempSpec -PayloadRoot $payloadRoot -OutputRoot $tempOutput|Out-Null
    $target=Join-Path $versionRoot $packageVersion
    if(Test-Path -LiteralPath $target){
        $existing=Get-Content -Raw -LiteralPath (Join-Path $target 'manifest.json')|ConvertFrom-Json
        $candidate=Get-Content -Raw -LiteralPath (Join-Path $tempOutput 'manifest.json')|ConvertFrom-Json
        $comparison=Compare-AuPackageCandidates -LocalManifest $existing -RemoteManifest $candidate
        if($comparison -eq 'same'){$result=[pscustomobject]@{status='unchanged';app_id=$spec.app_id;version=$packageVersion;message='Identical package version already exists.'}}
        else{
            $conflictRoot=Join-Path $packageDirectory 'conflicts';[void][IO.Directory]::CreateDirectory($conflictRoot)
            $conflict=Join-Path $conflictRoot ($packageVersion+'-'+[guid]::NewGuid().ToString('N'));Copy-PackageDirectoryAtomically $tempOutput $conflict;$preserveOutput=$true
            $result=[pscustomobject]@{status='conflict';app_id=$spec.app_id;version=$packageVersion;message='Same version contains different content; both package copies were preserved.'}
        }
    }else{
        Copy-PackageDirectoryAtomically $tempOutput $target;$manifest=Get-Content -Raw -LiteralPath (Join-Path $target 'manifest.json')|ConvertFrom-Json
        Write-BuildState $statePath ([ordered]@{schema=1;app_id=[string]$spec.app_id;version=$packageVersion;source_fingerprint=$fingerprint;updated_utc=[DateTime]::UtcNow.ToString('o')})
        $result=[pscustomobject]@{status='built';app_id=$spec.app_id;version=$packageVersion;package_path=$target;message='Changed source files were packaged and validated.'}
    }
    $result|ConvertTo-Json -Compress
}finally{
    if(-not $preserveOutput -and (Test-Path -LiteralPath $tempOutput)){Remove-Item -LiteralPath $tempOutput -Recurse -Force -ErrorAction SilentlyContinue}
    if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
