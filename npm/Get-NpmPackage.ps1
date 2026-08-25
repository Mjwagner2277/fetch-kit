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
    [string]$Password = $env:NPM_PASSWORD,

    [Parameter()]
    [switch]$SkipArtifactoryBundle
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

function Remove-JsonMetadataKey {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Key
    )

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Key)) {
            $Object.Remove($Key)
        }
        foreach ($childKey in @($Object.Keys)) {
            if ($null -ne $Object[$childKey]) {
                Remove-JsonMetadataKey -Object $Object[$childKey] -Key $Key
            }
        }
        return
    }

    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        foreach ($item in $Object) {
            if ($null -ne $item) {
                Remove-JsonMetadataKey -Object $item -Key $Key
            }
        }
    }
}

function Invoke-Json {
    param([Parameter(Mandatory = $true)][string]$Uri)
    $response = Invoke-Http -Uri $Uri
    if (-not $response.Content) {
        return $null
    }
    try {
        return $response.Content | ConvertFrom-Json
    }
    catch {
        if ($_.Exception.Message -match '-AsHashTable|different casing') {
            $metadata = $response.Content | ConvertFrom-Json -AsHashtable
            Remove-JsonMetadataKey -Object $metadata -Key 'users'
            $normalizedJson = ConvertTo-Json -InputObject $metadata -Depth 100
            return $normalizedJson | ConvertFrom-Json
        }
        throw
    }
}

function Get-ObjectEntries {
    param([Parameter(Mandatory = $true)][object]$Object)

    $entries = @()
    foreach ($property in $Object.PSObject.Properties) {
        $entries += [pscustomobject]@{
            Name  = [string]$property.Name
            Value = $property.Value
        }
    }
    return $entries
}

function Get-PackageMetadataUrl {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($Name.StartsWith('@')) {
        return Join-Url -Base $Registry -Path ([System.Uri]::EscapeDataString($Name))
    }
    return Join-Url -Base $Registry -Path $Name
}

function Get-PackageVersionMetadataUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$VersionText
    )

    return Join-Url -Base (Get-PackageMetadataUrl -Name $Name) -Path ([System.Uri]::EscapeDataString($VersionText))
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

    $packageName = [string]$Metadata.name
    $distTags = $Metadata.'dist-tags'
    $versionsObject = $Metadata.versions

    if ($distTags -and $distTags.PSObject.Properties[$Requirement]) {
        $tagVersion = [string]$distTags.PSObject.Properties[$Requirement].Value
        return $tagVersion
    }

    $selectedVersionText = ''
    foreach ($property in Get-ObjectEntries -Object $versionsObject) {
        if (-not $IncludePrerelease -and $property.Name.Contains('-')) {
            continue
        }
        # npm still resolves deprecated versions when they satisfy dependency ranges.
        if (Test-VersionRequirement -VersionText $property.Name -Requirement $Requirement) {
            if (-not $selectedVersionText -or (Compare-VersionText -Left $property.Name -Right $selectedVersionText) -gt 0) {
                $selectedVersionText = $property.Name
            }
        }
    }

    if (-not $selectedVersionText) {
        throw "No version of $packageName satisfies '$Requirement'."
    }

    return $selectedVersionText
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
        if (-not $PackageVersion.PSObject.Properties[$section]) {
            continue
        }

        $sectionValue = $PackageVersion.PSObject.Properties[$section].Value
        if (-not $sectionValue) {
            continue
        }

        foreach ($dependency in Get-ObjectEntries -Object $sectionValue) {
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

    $packageNameText = [string]$PackageVersion.name
    $packageVersionText = [string]$PackageVersion.version
    $distProperty = $PackageVersion.PSObject.Properties['dist']
    $dist = if ($distProperty) { $distProperty.Value } else { $null }
    $tarballUrl = if ($dist) { [string]$dist.tarball } else { '' }

    if (-not $dist -or -not $tarballUrl) {
        $typeName = $PackageVersion.GetType().FullName
        $propertyNames = @($PackageVersion.PSObject.Properties.Name) -join ','
        throw "Package $packageNameText $packageVersionText does not include a dist.tarball URL. Object type: $typeName. Properties: $propertyNames"
    }

    $safeName = ConvertTo-SafeFileName -Value $packageNameText
    $destination = Join-Path (Join-Path $OutputDirectory 'packages') (Join-Path $safeName $packageVersionText)
    New-Directory -Path $destination

    $tarballFile = Join-Path $destination "$safeName-$packageVersionText.tgz"
    $metadataFile = Join-Path $destination 'metadata.json'
    $packageFile = Join-Path $destination 'package.json'

    if (-not (Test-Path -LiteralPath $tarballFile)) {
        Invoke-Http -Uri $tarballUrl -OutFile $tarballFile | Out-Null
    }

    if ($dist.PSObject.Properties['shasum']) {
        $actualSha1 = (Get-FileHash -LiteralPath $tarballFile -Algorithm SHA1).Hash.ToLowerInvariant()
        $expectedSha1 = ([string]$dist.shasum).ToLowerInvariant()
        if ($actualSha1 -ne $expectedSha1) {
            throw "Checksum mismatch for $packageNameText $packageVersionText. Expected $expectedSha1 but found $actualSha1."
        }
    }

    $Metadata | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $metadataFile -Encoding UTF8
    $PackageVersion | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $packageFile -Encoding UTF8

    return [pscustomobject]@{
        Name         = $packageNameText
        Version      = $packageVersionText
        TarballFile  = $tarballFile
        MetadataFile = $metadataFile
        PackageFile  = $packageFile
        TarballUrl   = $tarballUrl
    }
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $baseFullPath = [System.IO.Path]::GetFullPath($BasePath)
    $targetFullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $baseFullPath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $baseFullPath += [System.IO.Path]::DirectorySeparatorChar
    }

    $baseUri = [System.Uri]::new($baseFullPath)
    $targetUri = [System.Uri]::new($targetFullPath)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

function Write-ArtifactoryBundle {
    param([Parameter(Mandatory = $true)][object]$Summary)

    $bundleRoot = Join-Path $OutputDirectory 'artifactory-upload'
    $tarballRoot = Join-Path $bundleRoot 'tarballs'
    New-Directory -Path $bundleRoot
    New-Directory -Path $tarballRoot

    $manifestItems = @()
    foreach ($download in @($Summary.Downloads | Sort-Object Name, Version)) {
        $safeName = ConvertTo-SafeFileName -Value $download.Name
        $publishFileName = "$safeName-$($download.Version).tgz"
        $publishTarball = Join-Path $tarballRoot $publishFileName
        Copy-Item -LiteralPath $download.TarballFile -Destination $publishTarball -Force

        $sha1 = (Get-FileHash -LiteralPath $publishTarball -Algorithm SHA1).Hash.ToLowerInvariant()
        $sha512 = (Get-FileHash -LiteralPath $publishTarball -Algorithm SHA512).Hash.ToLowerInvariant()

        $manifestItems += [pscustomobject]@{
            Name                = $download.Name
            Version             = $download.Version
            Package             = "$($download.Name)@$($download.Version)"
            Tarball             = (Get-RelativePath -BasePath $bundleRoot -Path $publishTarball).Replace('\', '/')
            SourceTarball       = (Get-RelativePath -BasePath $OutputDirectory -Path $download.TarballFile).Replace('\', '/')
            SourceMetadata      = (Get-RelativePath -BasePath $OutputDirectory -Path $download.MetadataFile).Replace('\', '/')
            SourcePackageJson   = (Get-RelativePath -BasePath $OutputDirectory -Path $download.PackageFile).Replace('\', '/')
            SourceTarballUrl    = $download.TarballUrl
            Sha1                = $sha1
            Sha512              = $sha512
        }
    }

    $manifestFile = Join-Path $bundleRoot 'packages.json'
    $tsvFile = Join-Path $bundleRoot 'packages.tsv'
    $summaryFile = Join-Path $bundleRoot 'retrieval-summary.json'
    $readmeFile = Join-Path $bundleRoot 'README.txt'
    $bashPublishScript = Join-Path $bundleRoot 'publish-npm-package-bundle.sh'
    $sourceBashPublishScript = Join-Path $PSScriptRoot 'publish-npm-package-bundle.sh'

    $manifestItems | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestFile -Encoding UTF8
    $Summary | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $summaryFile -Encoding UTF8

    $tsvRows = @('Name	Version	Package	Tarball	Sha1	Sha512')
    foreach ($item in $manifestItems) {
        $tsvRows += "$($item.Name)`t$($item.Version)`t$($item.Package)`t$($item.Tarball)`t$($item.Sha1)`t$($item.Sha512)"
    }
    $tsvRows | Set-Content -LiteralPath $tsvFile -Encoding UTF8

    if (Test-Path -LiteralPath $sourceBashPublishScript) {
        Copy-Item -LiteralPath $sourceBashPublishScript -Destination $bashPublishScript -Force
    }

    @(
        'npm Artifactory upload bundle',
        '',
        'Transfer this whole artifactory-upload directory into the airgapped environment.',
        '',
        'Publish from a Linux airgapped asset with:',
        '  ./publish-npm-package-bundle.sh --registry-url "https://art.example.com/artifactory/api/npm/npm-local/" --token "$ARTIFACTORY_TOKEN" --skip-existing',
        '',
        'Files:',
        '  packages.json             Machine-readable publish manifest.',
        '  packages.tsv              Human-readable package list.',
        '  retrieval-summary.json    Original resolver output.',
        '  tarballs/                 Flat publish-ready npm .tgz files.',
        '  publish-npm-package-bundle.sh  Bash offline publishing helper.'
    ) | Set-Content -LiteralPath $readmeFile -Encoding UTF8

    return [pscustomobject]@{
        BundleRoot       = $bundleRoot
        TarballDirectory = $tarballRoot
        ManifestFile     = $manifestFile
        TsvFile          = $tsvFile
        SummaryFile      = $summaryFile
        ReadmeFile       = $readmeFile
        BashPublishScript = if (Test-Path -LiteralPath $bashPublishScript) { $bashPublishScript } else { $null }
        PackageCount     = $manifestItems.Count
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
            $selectedVersion = [string](Select-NpmVersion -Metadata $metadata -Requirement ([string]$request.Requirement))
            $selected = Invoke-Json -Uri (Get-PackageVersionMetadataUrl -Name $request.Name -VersionText $selectedVersion)
            $selectedName = [string]$selected.name
            $key = "$selectedName@$selectedVersion"
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
                Name        = $selectedName
                Version     = $selectedVersion
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
if (-not $SkipArtifactoryBundle) {
    $summary | Add-Member -NotePropertyName ArtifactoryBundle -NotePropertyValue (Write-ArtifactoryBundle -Summary $summary)
}
$summary | ConvertTo-Json -Depth 100
