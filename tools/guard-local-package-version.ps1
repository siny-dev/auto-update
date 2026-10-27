function Resolve-AuGuardPackagePath([string]$Root,[string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^[/\\]|^[A-Za-z]:|(^|[/\\])\.\.([/\\]|$)|:|[\x00-\x1f])') {
        throw 'Unsafe package metadata path.'
    }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath((Join-Path $base ($Relative.Replace('/',[IO.Path]::DirectorySeparatorChar))))
    if (-not $full.StartsWith($base + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Package metadata path escapes its package root.'
    }
    return $full
}

function Test-AuLocalPackageVersionMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$PackageRoot,
        [Parameter(Mandatory=$true)][string]$BuildRecipePath
    )
    if (-not (Test-Path -LiteralPath $BuildRecipePath -PathType Leaf)) {
        return [pscustomobject]@{Valid=$true;Status='version-metadata-not-configured';Message='No build recipe is present; no recipe metadata contract applies.'}
    }
    try {
        $recipe = Get-Content -Raw -LiteralPath $BuildRecipePath | ConvertFrom-Json -ErrorAction Stop
        $contractProperty = $recipe.PSObject.Properties['version_metadata']
        if (-not $contractProperty -or $null -eq $contractProperty.Value) {
            return [pscustomobject]@{Valid=$true;Status='version-metadata-not-configured';Message='The build recipe does not declare version_metadata.'}
        }
        $contract = $contractProperty.Value
        $relative = [string]$contract.path
        $field = [string]$contract.field
        $prefix = [string]$contract.prefix
        if ([string]::IsNullOrWhiteSpace($relative) -or [string]::IsNullOrWhiteSpace($field)) {
            throw 'The build recipe version_metadata contract is incomplete.'
        }
        $manifestPath = Join-Path $PackageRoot 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'The local package manifest is missing.' }
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -ErrorAction Stop
        if ([string]$manifest.version -notmatch '^\d+\.\d+\.\d+$') { throw 'The local package version is invalid.' }
        $normalizedRelative = $relative.Replace('\','/')
        $entries = @($manifest.files | Where-Object { ([string]$_.path).Replace('\','/') -ceq $normalizedRelative })
        if ($entries.Count -ne 1) { throw 'The metadata file is not declared exactly once in the package manifest.' }
        $payloadPath = Resolve-AuGuardPackagePath $PackageRoot ([string]$entries[0].source)
        if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) { throw 'The package metadata payload is missing.' }
        $info = Get-Item -LiteralPath $payloadPath
        if ([long]$info.Length -ne [long]$entries[0].size) { throw 'The package metadata size does not match its manifest.' }
        $hash = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -cne ([string]$entries[0].sha256).ToLowerInvariant()) { throw 'The package metadata hash does not match its manifest.' }
        $document = Get-Content -Raw -LiteralPath $payloadPath | ConvertFrom-Json -ErrorAction Stop
        $property = $document.PSObject.Properties[$field]
        if (-not $property) { throw 'The declared version_metadata field is missing from the payload.' }
        $embedded = [string]$property.Value
        if ($prefix) {
            if (-not $embedded.StartsWith($prefix,[StringComparison]::Ordinal)) { throw 'The embedded version does not use the declared prefix.' }
            $embedded = $embedded.Substring($prefix.Length)
        }
        if ($embedded -notmatch '^\d+\.\d+\.\d+$') { throw 'The embedded application version is invalid.' }
        if (-not ([version]$embedded).Equals([version][string]$manifest.version)) {
            return [pscustomobject]@{Valid=$false;Status='publish-held-version-metadata-mismatch';Message=('Package manifest version '+[string]$manifest.version+' differs from embedded application version '+$embedded+'.')}
        }
        return [pscustomobject]@{Valid=$true;Status='version-metadata-match';Message='Package manifest and embedded application versions match.'}
    } catch {
        return [pscustomobject]@{Valid=$false;Status='publish-held-version-metadata-invalid';Message=$_.Exception.Message}
    }
}