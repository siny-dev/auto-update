$ErrorActionPreference='Stop'
$guardPath=Join-Path $PSScriptRoot '..\tools\guard-local-package-version.ps1'
. $guardPath
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot=Join-Path $tempRoot ('AutoUpdate-publish-guard-test-'+[guid]::NewGuid().ToString('N'))
$appRoot=Join-Path $testRoot 'apps\workboard';[void][IO.Directory]::CreateDirectory($appRoot)
$recipePath=Join-Path $appRoot 'build.json'
$recipe=[ordered]@{app_id='workboard';version_metadata=[ordered]@{path='version.json';field='version';prefix='v'}}
[IO.File]::WriteAllText($recipePath,($recipe|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
function New-FixturePackage([string]$PackageVersion,[string]$EmbeddedVersion,[switch]$BadHash,[switch]$DuplicateEntry){
    $package=Join-Path $appRoot $PackageVersion;$payload=Join-Path $package 'payload';[void][IO.Directory]::CreateDirectory($payload)
    $metadataPath=Join-Path $payload 'version.json';[IO.File]::WriteAllText($metadataPath,(('{"version":"'+$EmbeddedVersion+'"}')+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    $info=Get-Item -LiteralPath $metadataPath;$hash=(Get-FileHash -LiteralPath $metadataPath -Algorithm SHA256).Hash.ToLowerInvariant();if($BadHash){$hash='0'*64}
    $entry=[ordered]@{path='version.json';source='payload/version.json';kind='data';size=[long]$info.Length;sha256=$hash}
    $files=@($entry);if($DuplicateEntry){$files+=@($entry)}
    $manifest=[ordered]@{schema=1;app_id='workboard';version=$PackageVersion;platform='windows';architecture='x86';minimum_engine='0.1.0';mode='restart';files=$files}
    [IO.File]::WriteAllText((Join-Path $package 'manifest.json'),($manifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    return $package
}
try{
    $good=New-FixturePackage '1.0.47' 'v1.0.47';$goodCheck=Test-AuLocalPackageVersionMetadata -PackageRoot $good -BuildRecipePath $recipePath
    Assert ($goodCheck.Valid -and $goodCheck.Status -eq 'version-metadata-match') 'matching package metadata was not accepted'
    $stale=New-FixturePackage '1.0.49' 'v1.0.47';$staleCheck=Test-AuLocalPackageVersionMetadata -PackageRoot $stale -BuildRecipePath $recipePath
    Assert (-not $staleCheck.Valid -and $staleCheck.Status -eq 'publish-held-version-metadata-mismatch') 'manifest/embedded version mismatch was not held'
    $badHash=New-FixturePackage '1.0.50' 'v1.0.50' -BadHash;$hashCheck=Test-AuLocalPackageVersionMetadata -PackageRoot $badHash -BuildRecipePath $recipePath
    Assert (-not $hashCheck.Valid -and $hashCheck.Status -eq 'publish-held-version-metadata-invalid') 'metadata hash mismatch was not held'
    $duplicate=New-FixturePackage '1.0.51' 'v1.0.51' -DuplicateEntry;$duplicateCheck=Test-AuLocalPackageVersionMetadata -PackageRoot $duplicate -BuildRecipePath $recipePath
    Assert (-not $duplicateCheck.Valid) 'duplicate metadata manifest entry was not held'
    $recipe.version_metadata.path='../version.json';[IO.File]::WriteAllText($recipePath,($recipe|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $traversalCheck=Test-AuLocalPackageVersionMetadata -PackageRoot $good -BuildRecipePath $recipePath
    Assert (-not $traversalCheck.Valid) 'traversal metadata path was not held'
    $recipe.Remove('version_metadata');[IO.File]::WriteAllText($recipePath,($recipe|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $unconfigured=Test-AuLocalPackageVersionMetadata -PackageRoot $good -BuildRecipePath $recipePath
    Assert ($unconfigured.Valid -and $unconfigured.Status -eq 'version-metadata-not-configured') 'legacy app without a metadata contract was not allowed'

    $realRecipe='\\H255\AI-Work\제작중인 프로그램\AutoUpdate\outbox\apps\workboard\build.json'
    $realRoot='\\H255\AI-Work\제작중인 프로그램\AutoUpdate\outbox\apps\workboard'
    foreach($version in @('1.0.48','1.0.49')){
        $realPackage=Join-Path $realRoot $version
        $realResult=Test-AuLocalPackageVersionMetadata -PackageRoot $realPackage -BuildRecipePath $realRecipe
        Assert (-not $realResult.Valid -and $realResult.Status -eq 'publish-held-version-metadata-mismatch') ("existing Workboard package $version was not held: "+$realResult.Message)
    }
    $worker=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\tools\update-registered-apps.ps1')
    $guardAt=$worker.IndexOf('Test-AuLocalPackageVersionMetadata',[StringComparison]::Ordinal)
    $publishAt=$worker.IndexOf('Publish-AuLocalPackage -Owner',[StringComparison]::Ordinal)
    Assert ($guardAt -ge 0 -and $publishAt -gt $guardAt -and $worker.Contains('if(-not $versionGuard.Valid)')) 'registered-app worker does not hold mismatched packages before publish'
    'PASS: matching package allowed; mismatched, malformed, unhashed, duplicate, and traversal metadata denied; existing Workboard .48/.49 denied; worker guard precedes publisher.'
}finally{
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path -Leaf $resolved).StartsWith('AutoUpdate-publish-guard-test-')){throw 'refusing unsafe test cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}