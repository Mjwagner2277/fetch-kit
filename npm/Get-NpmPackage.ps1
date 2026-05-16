<#
.SYNOPSIS
Downloads npm packages and registry dependencies without invoking npm or Node.js.

.DESCRIPTION
Get-NpmPackage.ps1 emulates the retrieval portion of npm with PowerShell HTTP
calls. It reads npm registry package documents, resolves package versions from
dist-tags or semver ranges, follows dependency metadata recursively, and saves
package tarballs plus metadata into a local cache.

This is not an npm install replacement. It does not create node_modules, run
lifecycle scripts, evaluate package-lock files, apply overrides, or implement
npm's complete peer dependency solver. It is intended for air-gap preparation,
registry mirroring, and source inspection workflows where downloading packages
and their registry dependency graph is the goal.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Package,

    [Parameter()]
    [string]$Version = 'latest',

    [Parameter()]
    [string]$Registry = 'https://registry.npmjs.org/',

    [Parameter()]
    [string]$OutputDirectory = (Join-Path (Get-Location) 'npm-package-cache'),

    [Parameter()]
    [int]$MaxDepth = 0,

    [Parameter()]
    [switch]$IncludeDevDependencies,

    [Parameter()]
    [switch]$IncludeOptionalDependencies,

    [Parameter()]
    [switch]$IncludePeerDependencies,

    [Parameter()]
    [switch]$IncludeDeprecated,

    [Parameter()]
    [switch]$IncludePrerelease,

    [Parameter()]
    [string]$BearerToken = $env:NPM_TOKEN,

    [Parameter()]
    [string]$Username = $env:NPM_USERNAME,

    [Parameter()]
    [string]$Password = $env:NPM_PASSWORD
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Join-Url {
    param(
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][string]$Path
    )
    return $Base.TrimEnd('/') + '/' + $Path.TrimStart('/')
}

function ConvertTo-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Value)
    return ($Value -replace '[\\/:*?"<>|@]', '_')
}

function Get-RegistryHeaders {
    $headers = @{
        'Accept'     = 'application/json'
        'User-Agent' = 'Get-NpmPackage.ps1'
    }

    if ($BearerToken) {
        $headers.Authorization = "Bearer $BearerToken"
    }
    elseif ($Username -and $Password) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("${Username}:${Password}")
        $headers.Authorization = 'Basic ' + [System.Convert]::ToBase64String($bytes)
    }

    return $headers
}

function Invoke-Http {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$OutFile = ''
    )

    $parameters = @{
        Uri             = $Uri
        Headers         = Get-RegistryHeaders
        UseBasicParsing = $true
    }
    if ($OutFile) {
        $parameters.OutFile = $OutFile
    }

    try {
        return Invoke-WebRequest @parameters
    }
    catch {
        $response = $null
        if ($_.Exception.PSObject.Properties['Response']) {
            $response = $_.Exception.Response
        }
        if ($response) {
            throw "HTTP $([int]$response.StatusCode) from $Uri"
        }
        throw
    }
}

function Invoke-Json {
    param([Parameter(Mandatory = $true)][string]$Uri)
    $response = Invoke-Http -Uri $Uri
    if (-not $response.Content) {
        return $null
    }
    return $response.Content | ConvertFrom-Json
}

function Get-PackageMetadataUrl {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($Name.StartsWith('@')) {
        return Join-Url -Base $Registry -Path ([System.Uri]::EscapeDataString($Name))
    }
    return Join-Url -Base $Registry -Path $Name
}

function ConvertTo-VersionParts {
    param([Parameter(Mandatory = $true)][string]$VersionText)

    $core = ($VersionText -split '[-+]')[0]
    $rawParts = @($core.Split('.'))
    $parts = @()
    foreach ($part in $rawParts) {
        if ($part -match '^\d+$') {
            $parts += [int]$part
        }
        else {
            $parts += 0
        }
    }
    while ($parts.Count -lt 3) {
        $parts += 0
    }

    $preRelease = ''
    if ($VersionText -match '^\d+(?:\.\d+){0,2}-([^+]+)') {
        $preRelease = $Matches[1]
    }

    return [pscustomobject]@{
        Major      = $parts[0]
        Minor      = $parts[1]
        Patch      = $parts[2]
        PreRelease = $preRelease
        Text       = $VersionText
    }
}

function Compare-VersionText {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $a = ConvertTo-VersionParts -VersionText $Left
    $b = ConvertTo-VersionParts -VersionText $Right
    foreach ($part in @('Major', 'Minor', 'Patch')) {
        if ($a.$part -lt $b.$part) { return -1 }
        if ($a.$part -gt $b.$part) { return 1 }
    }

    if (-not $a.PreRelease -and $b.PreRelease) { return 1 }
    if ($a.PreRelease -and -not $b.PreRelease) { return -1 }
    return [string]::CompareOrdinal($a.PreRelease, $b.PreRelease)
}

function Test-VersionAtLeast {
    param([string]$VersionText, [string]$Minimum)
    return (Compare-VersionText -Left $VersionText -Right $Minimum) -ge 0
}

function Test-VersionLessThan {
    param([string]$VersionText, [string]$Maximum)
    return (Compare-VersionText -Left $VersionText -Right $Maximum) -lt 0
}

function Get-CaretUpperBound {
    param([Parameter(Mandatory = $true)][string]$BaseVersion)

    $v = ConvertTo-VersionParts -VersionText $BaseVersion
    if ($v.Major -gt 0) { return "$($v.Major + 1).0.0" }
    if ($v.Minor -gt 0) { return "0.$($v.Minor + 1).0" }
    return "0.0.$($v.Patch + 1)"
}

function Get-TildeUpperBound {
    param(
        [Parameter(Mandatory = $true)][string]$BaseVersion,
        [Parameter(Mandatory = $true)][int]$ComponentCount
    )

    $v = ConvertTo-VersionParts -VersionText $BaseVersion
    if ($ComponentCount -le 1) { return "$($v.Major + 1).0.0" }
    return "$($v.Major).$($v.Minor + 1).0"
}

function Normalize-VersionBase {
    param([Parameter(Mandatory = $true)][string]$Value)

    $text = $Value.Trim()
    if ($text -match '^\d+$') { return "$text.0.0" }
    if ($text -match '^\d+\.\d+$') { return "$text.0" }
    return $text
}

function Test-SingleRequirement {
    param(
        [Parameter(Mandatory = $true)][string]$VersionText,
        [Parameter(Mandatory = $true)][string]$Requirement
    )

    $req = $Requirement.Trim()
    if (-not $req -or $req -in @('*', 'x', 'X', 'latest')) {
        return $true
    }

    if ($req.Contains('*') -or $req.Contains('x') -or $req.Contains('X')) {
        $segments = @($req.TrimStart('=').Split('.'))
        $version = ConvertTo-VersionParts -VersionText $VersionText
        if ($segments.Count -ge 1 -and $segments[0] -notmatch '^[*xX]$' -and $version.Major -ne [int]$segments[0]) { return $false }
        if ($segments.Count -ge 2 -and $segments[1] -notmatch '^[*xX]$' -and $version.Minor -ne [int]$segments[1]) { return $false }
        if ($segments.Count -ge 3 -and $segments[2] -notmatch '^[*xX]$' -and $version.Patch -ne [int]$segments[2]) { return $false }
        return $true
    }

    if ($req -match '^(>=|<=|>|<|=)\s*(.+)$') {
        $op = $Matches[1]
        $rhs = Normalize-VersionBase -Value $Matches[2]
        $cmp = Compare-VersionText -Left $VersionText -Right $rhs
        switch ($op) {
            '>=' { return $cmp -ge 0 }
            '<=' { return $cmp -le 0 }
            '>'  { return $cmp -gt 0 }
            '<'  { return $cmp -lt 0 }
            '='  { return $cmp -eq 0 }
        }
    }

    if ($req.StartsWith('~')) {
        $base = Normalize-VersionBase -Value $req.Substring(1)
        $componentCount = @($req.Substring(1).Trim().Split('.')).Count
        $upper = Get-TildeUpperBound -BaseVersion $base -ComponentCount $componentCount
        return (Test-VersionAtLeast -VersionText $VersionText -Minimum $base) -and (Test-VersionLessThan -VersionText $VersionText -Maximum $upper)
    }

    if ($req.StartsWith('^')) {
        $base = Normalize-VersionBase -Value $req.Substring(1)
        $upper = Get-CaretUpperBound -BaseVersion $base
        return (Test-VersionAtLeast -VersionText $VersionText -Minimum $base) -and (Test-VersionLessThan -VersionText $VersionText -Maximum $upper)
    }

    $baseVersion = Normalize-VersionBase -Value $req.TrimStart('v')
    if ($baseVersion -match '^\d+\.\d+\.\d+') {
        return (Compare-VersionText -Left $VersionText -Right $baseVersion) -eq 0
    }

    return $false
}

function Expand-ComparatorSet {
    param([Parameter(Mandatory = $true)][string]$Requirement)

    $req = $Requirement.Trim()
    if ($req -match '^(.+)\s+-\s+(.+)$') {
        return ">= $($Matches[1]) <= $($Matches[2])"
    }
    return $req
}

function Test-VersionRequirement {
    param(
        [Parameter(Mandatory = $true)][string]$VersionText,
        [Parameter(Mandatory = $true)][string]$Requirement
    )

    foreach ($alternative in ($Requirement -split '\s*\|\|\s*')) {
        $expanded = Expand-ComparatorSet -Requirement $alternative
        $expanded = $expanded -replace '(>=|<=|>|<|=)\s+', '$1'
        $ok = $true
        foreach ($part in ($expanded -split '\s+(?=[<>=~^*xXv\d])|,\s*')) {
            if ($part.Trim()) {
                if (-not (Test-SingleRequirement -VersionText $VersionText -Requirement $part)) {
                    $ok = $false
                    break
                }
            }
        }
        if ($ok) {
            return $true
        }
    }
    return $false
}

function Select-NpmVersion {
    param(
        [Parameter(Mandatory = $true)][object]$Metadata,
        [Parameter(Mandatory = $true)][string]$Requirement
    )

    if ($Metadata.'dist-tags' -and $Metadata.'dist-tags'.PSObject.Properties[$Requirement]) {
        $tagVersion = [string]$Metadata.'dist-tags'.$Requirement
        return $Metadata.versions.$tagVersion
    }

    $versions = @()
    foreach ($property in $Metadata.versions.PSObject.Properties) {
        $versionObject = $property.Value
        if (-not $IncludePrerelease -and $property.Name.Contains('-')) {
            continue
        }
        if (-not $IncludeDeprecated -and $versionObject.PSObject.Properties['deprecated']) {
            continue
        }
        if (Test-VersionRequirement -VersionText $property.Name -Requirement $Requirement) {
            $versions += $versionObject
        }
    }

    if ($versions.Count -eq 0) {
        throw "No version of $($Metadata.name) satisfies '$Requirement'."
    }

    $selected = $versions[0]
    foreach ($candidate in $versions) {
        if ((Compare-VersionText -Left ([string]$candidate.version) -Right ([string]$selected.version)) -gt 0) {
            $selected = $candidate
        }
    }
    return $selected
}

function Get-DependencyEntries {
    param(
        [Parameter(Mandatory = $true)][object]$PackageVersion,
        [Parameter(Mandatory = $true)][string]$ParentKey,
        [Parameter(Mandatory = $true)][int]$Depth
    )

    $entries = @()
    $sections = @('dependencies')
    if ($IncludeOptionalDependencies) { $sections += 'optionalDependencies' }
    if ($IncludePeerDependencies) { $sections += 'peerDependencies' }
    if ($IncludeDevDependencies -and $Depth -eq 0) { $sections += 'devDependencies' }

    foreach ($section in $sections) {
        if (-not $PackageVersion.PSObject.Properties[$section] -or -not $PackageVersion.$section) {
            continue
        }

        foreach ($dependency in $PackageVersion.$section.PSObject.Properties) {
            $entries += [pscustomobject]@{
                Name        = $dependency.Name
                Requirement = [string]$dependency.Value
                Parent      = $ParentKey
                Kind        = $section
                Depth       = $Depth + 1
            }
        }
    }

    return $entries
}

function Save-NpmPackage {
    param(
        [Parameter(Mandatory = $true)][object]$Metadata,
        [Parameter(Mandatory = $true)][object]$PackageVersion
    )

    if (-not $PackageVersion.dist -or -not $PackageVersion.dist.tarball) {
        throw "Package $($PackageVersion.name) $($PackageVersion.version) does not include a dist.tarball URL."
    }

    $safeName = ConvertTo-SafeFileName -Value $PackageVersion.name
    $destination = Join-Path (Join-Path $OutputDirectory 'packages') (Join-Path $safeName $PackageVersion.version)
    New-Directory -Path $destination

    $tarballFile = Join-Path $destination "$safeName-$($PackageVersion.version).tgz"
    $metadataFile = Join-Path $destination 'metadata.json'
    $packageFile = Join-Path $destination 'package.json'

    if (-not (Test-Path -LiteralPath $tarballFile)) {
        Invoke-Http -Uri ([string]$PackageVersion.dist.tarball) -OutFile $tarballFile | Out-Null
    }

    if ($PackageVersion.dist.PSObject.Properties['shasum'] -and $PackageVersion.dist.shasum) {
        $actualSha1 = (Get-FileHash -LiteralPath $tarballFile -Algorithm SHA1).Hash.ToLowerInvariant()
        $expectedSha1 = ([string]$PackageVersion.dist.shasum).ToLowerInvariant()
        if ($actualSha1 -ne $expectedSha1) {
            throw "Checksum mismatch for $($PackageVersion.name) $($PackageVersion.version). Expected $expectedSha1 but found $actualSha1."
        }
    }

    $Metadata | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $metadataFile -Encoding UTF8
    $PackageVersion | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $packageFile -Encoding UTF8

    return [pscustomobject]@{
        Name         = $PackageVersion.name
        Version      = $PackageVersion.version
        TarballFile  = $tarballFile
        MetadataFile = $metadataFile
        PackageFile  = $packageFile
        TarballUrl   = [string]$PackageVersion.dist.tarball
    }
}

function Resolve-NpmDependencyGraph {
    param(
        [Parameter(Mandatory = $true)][string]$RootPackage,
        [Parameter(Mandatory = $true)][string]$RootRequirement
    )

    $resolved = @{}
    $downloads = @()
    $failures = @()
    $edges = @()
    $metadataCache = @{}
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{
        Name        = $RootPackage
        Requirement = $RootRequirement
        Parent      = $null
        Kind        = 'root'
        Depth       = 0
    })

    while ($queue.Count -gt 0) {
        $request = $queue.Dequeue()
        if ($MaxDepth -gt 0 -and $request.Depth -gt $MaxDepth) {
            continue
        }

        try {
            if (-not $metadataCache.ContainsKey($request.Name)) {
                $metadataCache[$request.Name] = Invoke-Json -Uri (Get-PackageMetadataUrl -Name $request.Name)
            }

            $metadata = $metadataCache[$request.Name]
            $selected = Select-NpmVersion -Metadata $metadata -Requirement ([string]$request.Requirement)
            $key = "$($selected.name)@$($selected.version)"
            $edges += [pscustomobject]@{
                From        = $request.Parent
                To          = $key
                Name        = $request.Name
                Requirement = $request.Requirement
                Kind        = $request.Kind
                Depth       = $request.Depth
            }

            if ($resolved.ContainsKey($key)) {
                continue
            }

            $resolved[$key] = [pscustomobject]@{
                Name        = $selected.name
                Version     = $selected.version
                Requirement = $request.Requirement
                Parent      = $request.Parent
                Kind        = $request.Kind
                Depth       = $request.Depth
            }
            $downloads += Save-NpmPackage -Metadata $metadata -PackageVersion $selected

            foreach ($dependency in Get-DependencyEntries -PackageVersion $selected -ParentKey $key -Depth $request.Depth) {
                $queue.Enqueue($dependency)
            }
        }
        catch {
            $failures += [pscustomobject]@{
                Name        = $request.Name
                Requirement = $request.Requirement
                Parent      = $request.Parent
                Kind        = $request.Kind
                Depth       = $request.Depth
                Error       = $_.Exception.Message
            }
        }
    }

    return [pscustomobject]@{
        Mode                        = 'NpmDependencyGraph'
        Registry                    = $Registry
        RootPackage                 = $RootPackage
        RootRequirement             = $RootRequirement
        PackageCount                = $resolved.Count
        FailureCount                = $failures.Count
        IncludeDevDependencies      = [bool]$IncludeDevDependencies
        IncludeOptionalDependencies = [bool]$IncludeOptionalDependencies
        IncludePeerDependencies     = [bool]$IncludePeerDependencies
        MaxDepth                    = $MaxDepth
        Packages                    = @($resolved.Values | Sort-Object Name, Version)
        Edges                       = $edges
        Downloads                   = $downloads
        Failures                    = $failures
        Output                      = $OutputDirectory
    }
}

New-Directory -Path $OutputDirectory
$summary = Resolve-NpmDependencyGraph -RootPackage $Package -RootRequirement $Version
$summary | ConvertTo-Json -Depth 100
