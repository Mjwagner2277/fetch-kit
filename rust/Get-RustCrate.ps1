<#
.SYNOPSIS
Downloads Rust crates and their registry dependencies without invoking Cargo.

.DESCRIPTION
Get-RustCrate.ps1 emulates the crate retrieval portion of the Rust toolchain
with PowerShell HTTP calls. It reads a Cargo-compatible sparse registry index,
resolves crate versions from semver requirements, follows dependency metadata
from the index, and downloads .crate archives into a local cache.

The script does not compile crates, read a workspace Cargo.toml, update
Cargo.lock, run build scripts, or implement Cargo's full feature resolver. It is
intended for air-gap preparation, registry mirroring, and inspection workflows
where downloading the same registry source artifacts is the goal.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Crate,

    [Parameter()]
    [string]$Version = 'latest',

    [Parameter()]
    [string]$ManifestPath = '',

    [Parameter()]
    [string]$Registry = 'https://index.crates.io/',

    [Parameter()]
    [string]$OutputDirectory = (Join-Path (Get-Location) 'crate-cache'),

    [Parameter()]
    [string[]]$Features = @(),

    [Parameter()]
    [switch]$AllFeatures,

    [Parameter()]
    [switch]$NoDefaultFeatures,

    [Parameter()]
    [switch]$IncludeDevDependencies,

    [Parameter()]
    [switch]$ExcludeBuildDependencies,

    [Parameter()]
    [switch]$IncludeYanked,

    [Parameter()]
    [switch]$SkipChecksumVerification,

    [Parameter()]
    [switch]$SkipTargetSpecificDependencies,

    [Parameter()]
    [string]$BearerToken = $env:CARGO_REGISTRY_TOKEN,

    [Parameter()]
    [switch]$Expand
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

function Get-RegistryBase {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value.StartsWith('sparse+')) {
        return $Value.Substring(7)
    }
    return $Value
}

function Get-RegistryHeaders {
    $headers = @{
        'Accept' = 'application/json,text/plain,*/*'
        'User-Agent' = 'Get-RustCrate.ps1'
    }
    if ($BearerToken) {
        $headers.Authorization = "Bearer $BearerToken"
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

function Get-CrateIndexPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    $lower = $Name.ToLowerInvariant()
    switch ($lower.Length) {
        1 { return "1/$lower" }
        2 { return "2/$lower" }
        3 { return "3/$($lower.Substring(0, 1))/$lower" }
        default { return "$($lower.Substring(0, 2))/$($lower.Substring(2, 2))/$lower" }
    }
}

function Read-CrateIndex {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryBase,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $indexPath = Get-CrateIndexPath -Name $Name
    $uri = Join-Url -Base $RegistryBase -Path $indexPath
    $response = Invoke-Http -Uri $uri
    $records = @()
    foreach ($line in ($response.Content -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed) {
            $records += $trimmed | ConvertFrom-Json
        }
    }
    return $records
}

function ConvertTo-VersionParts {
    param([Parameter(Mandatory = $true)][string]$VersionText)

    $core = ($VersionText -split '[-+]')[0]
    $parts = @($core.Split('.') | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 3) {
        $parts += 0
    }
    return [pscustomobject]@{
        Major = $parts[0]
        Minor = $parts[1]
        Patch = $parts[2]
        Text  = $VersionText
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
    return [string]::CompareOrdinal($Left, $Right)
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
    if ($v.Major -gt 0) {
        return "$($v.Major + 1).0.0"
    }
    if ($v.Minor -gt 0) {
        return "0.$($v.Minor + 1).0"
    }
    return "0.0.$($v.Patch + 1)"
}

function Get-TildeUpperBound {
    param(
        [Parameter(Mandatory = $true)][string]$BaseVersion,
        [Parameter(Mandatory = $true)][int]$ComponentCount
    )

    $v = ConvertTo-VersionParts -VersionText $BaseVersion
    if ($ComponentCount -le 1) {
        return "$($v.Major + 1).0.0"
    }
    return "$($v.Major).$($v.Minor + 1).0"
}

function Test-SingleRequirement {
    param(
        [Parameter(Mandatory = $true)][string]$VersionText,
        [Parameter(Mandatory = $true)][string]$Requirement
    )

    $req = $Requirement.Trim()
    if (-not $req -or $req -eq '*' ) {
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
        $rhs = $Matches[2]
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
        $base = $req.Substring(1).Trim()
        $componentCount = @($base.Split('.')).Count
        $upper = Get-TildeUpperBound -BaseVersion $base -ComponentCount $componentCount
        return (Test-VersionAtLeast -VersionText $VersionText -Minimum $base) -and (Test-VersionLessThan -VersionText $VersionText -Maximum $upper)
    }

    if ($req.StartsWith('^')) {
        $base = $req.Substring(1).Trim()
        $upper = Get-CaretUpperBound -BaseVersion $base
        return (Test-VersionAtLeast -VersionText $VersionText -Minimum $base) -and (Test-VersionLessThan -VersionText $VersionText -Maximum $upper)
    }

    $upperBound = Get-CaretUpperBound -BaseVersion $req
    return (Test-VersionAtLeast -VersionText $VersionText -Minimum $req) -and (Test-VersionLessThan -VersionText $VersionText -Maximum $upperBound)
}

function Test-VersionRequirement {
    param(
        [Parameter(Mandatory = $true)][string]$VersionText,
        [Parameter(Mandatory = $true)][string]$Requirement
    )

    foreach ($alternative in ($Requirement -split '\s*\|\|\s*')) {
        $ok = $true
        foreach ($part in ($alternative -split '\s*,\s*|\s+')) {
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

function Select-CrateVersion {
    param(
        [Parameter(Mandatory = $true)][object[]]$Records,
        [Parameter(Mandatory = $true)][string]$Requirement
    )

    $candidates = @($Records | Where-Object {
        ($IncludeYanked -or -not $_.yanked) -and (Test-VersionRequirement -VersionText $_.vers -Requirement $Requirement)
    })
    if ($candidates.Count -eq 0) {
        throw "No version satisfies '$Requirement'."
    }

    return @($candidates | Sort-Object -Property @{ Expression = { ConvertTo-VersionParts -VersionText $_.vers | Select-Object -ExpandProperty Major } },
        @{ Expression = { ConvertTo-VersionParts -VersionText $_.vers | Select-Object -ExpandProperty Minor } },
        @{ Expression = { ConvertTo-VersionParts -VersionText $_.vers | Select-Object -ExpandProperty Patch } },
        @{ Expression = { $_.vers } })[-1]
}

function ConvertTo-RootRequirement {
    param([Parameter(Mandatory = $true)][string]$RequestedVersion)

    if ($RequestedVersion -eq 'latest') {
        return '*'
    }
    if ($RequestedVersion -match '^(=|<|>|~|\^)|[, *xX]|\|\|') {
        return $RequestedVersion
    }
    return "=$RequestedVersion"
}

function ConvertFrom-InlineTomlTable {
    param([Parameter(Mandatory = $true)][string]$Value)

    $table = @{}
    $inner = $Value.Trim()
    if ($inner.StartsWith('{')) { $inner = $inner.Substring(1) }
    if ($inner.EndsWith('}')) { $inner = $inner.Substring(0, $inner.Length - 1) }

    $pattern = '([A-Za-z0-9_-]+)\s*=\s*(\[[^\]]*\]|"[^"]*"|true|false|[^,]+)'
    foreach ($match in [regex]::Matches($inner, $pattern)) {
        $key = $match.Groups[1].Value
        $raw = $match.Groups[2].Value.Trim()
        if ($raw.StartsWith('"') -and $raw.EndsWith('"')) {
            $table[$key] = $raw.Trim('"')
        }
        elseif ($raw -match '^\[(.*)\]$') {
            $items = @()
            foreach ($item in ($Matches[1] -split ',\s*')) {
                $trimmed = $item.Trim()
                if ($trimmed) {
                    $items += $trimmed.Trim('"')
                }
            }
            $table[$key] = $items
        }
        elseif ($raw -eq 'true' -or $raw -eq 'false') {
            $table[$key] = [bool]::Parse($raw)
        }
        else {
            $table[$key] = $raw
        }
    }
    return $table
}

function Read-CargoManifestDependencies {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Manifest file not found: $Path"
    }

    $section = ''
    $dependencies = @()
    foreach ($line in Get-Content -LiteralPath $Path) {
        $withoutComment = ($line -replace '\s+#.*$', '').Trim()
        if (-not $withoutComment) { continue }

        if ($withoutComment -match '^\[(.+)\]$') {
            $section = $Matches[1]
            continue
        }

        if ($section -notin @('dependencies', 'build-dependencies', 'dev-dependencies')) {
            continue
        }

        if ($withoutComment -match '^([A-Za-z0-9_-]+)\s*=\s*(.+)$') {
            $alias = $Matches[1]
            $value = $Matches[2].Trim()
            $name = $alias
            $requirement = '*'
            $featuresForDependency = @()
            $defaultFeatures = $true

            if ($value.StartsWith('"')) {
                $requirement = $value.Trim('"')
            }
            elseif ($value.StartsWith('{')) {
                $table = ConvertFrom-InlineTomlTable -Value $value
                if ($table.ContainsKey('version')) { $requirement = [string]$table['version'] }
                if ($table.ContainsKey('package')) { $name = [string]$table['package'] }
                if ($table.ContainsKey('features')) { $featuresForDependency = @($table['features']) }
                if ($table.ContainsKey('default-features')) { $defaultFeatures = [bool]$table['default-features'] }
                if ($table.ContainsKey('path') -or $table.ContainsKey('git')) {
                    Write-Warning "Skipping non-registry dependency '$alias' from $Path."
                    continue
                }
            }

            $dependencies += [pscustomobject]@{
                Name              = $name
                Requirement       = $requirement
                Parent            = "manifest:$Path"
                Features          = $featuresForDependency
                NoDefaultFeatures = -not $defaultFeatures
                Root              = $true
                Kind              = $section
            }
        }
    }

    return $dependencies
}

function Get-DownloadUrl {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$VersionText
    )

    if ($Config -and $Config.PSObject.Properties['dl'] -and $Config.dl) {
        $template = [string]$Config.dl
        if ($template.Contains('{crate}') -or $template.Contains('{version}')) {
            return $template.Replace('{crate}', $Name).Replace('{version}', $VersionText).Replace('{prefix}', (Get-CrateIndexPath -Name $Name | Split-Path -Parent).Replace('\', '/')).Replace('{lowerprefix}', (Get-CrateIndexPath -Name $Name | Split-Path -Parent).Replace('\', '/').ToLowerInvariant())
        }
        return (Join-Url -Base $template -Path "$Name/$VersionText/download")
    }

    return "https://static.crates.io/crates/$Name/$Name-$VersionText.crate"
}

function Get-ActiveFeatureSet {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [string[]]$RequestedFeatures,
        [switch]$UseAllFeatures,
        [switch]$DisableDefaultFeatures
    )

    $active = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $queue = [System.Collections.Generic.Queue[string]]::new()

    if ($UseAllFeatures -and $Record.PSObject.Properties['features']) {
        foreach ($property in $Record.features.PSObject.Properties) {
            $queue.Enqueue($property.Name)
        }
    }
    elseif (-not $DisableDefaultFeatures) {
        $queue.Enqueue('default')
    }

    foreach ($feature in $RequestedFeatures) {
        if ($feature) {
            $queue.Enqueue($feature)
        }
    }

    while ($queue.Count -gt 0) {
        $featureName = $queue.Dequeue()
        if (-not $active.Add($featureName)) {
            continue
        }

        if ($Record.PSObject.Properties['features'] -and $Record.features.PSObject.Properties[$featureName]) {
            foreach ($child in @($Record.features.$featureName)) {
                $childText = [string]$child
                if ($childText.Contains('/')) {
                    $childText = $childText.Split('/')[0]
                }
                if ($childText.StartsWith('dep:')) {
                    $childText = $childText.Substring(4)
                }
                if ($childText -and -not $childText.StartsWith('?')) {
                    $queue.Enqueue($childText)
                }
            }
        }
    }

    return ,$active
}

function Test-DependencyEnabled {
    param(
        [Parameter(Mandatory = $true)][object]$Dependency,
        [object]$ActiveFeatures
    )

    if (-not $Dependency.optional) {
        return $true
    }

    $depName = [string]$Dependency.name
    if ($Dependency.PSObject.Properties['package'] -and $Dependency.package) {
        $depName = [string]$Dependency.package
    }
    return $ActiveFeatures -and ($ActiveFeatures.Contains($depName) -or $ActiveFeatures.Contains("dep:$depName") -or $ActiveFeatures.Contains([string]$Dependency.name))
}

function Save-Crate {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    $safeName = ConvertTo-SafeFileName -Value $Record.name
    $destination = Join-Path (Join-Path $DestinationRoot 'crates') $safeName
    New-Directory -Path $destination

    $crateFile = Join-Path $destination "$($Record.name)-$($Record.vers).crate"
    $metadataFile = Join-Path $destination "$($Record.name)-$($Record.vers).index.json"
    $downloadUrl = Get-DownloadUrl -Config $Config -Name $Record.name -VersionText $Record.vers

    if (-not (Test-Path -LiteralPath $crateFile)) {
        Invoke-Http -Uri $downloadUrl -OutFile $crateFile | Out-Null
    }

    if (-not $SkipChecksumVerification -and $Record.PSObject.Properties['cksum'] -and $Record.cksum) {
        $actualHash = (Get-FileHash -LiteralPath $crateFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $expectedHash = ([string]$Record.cksum).ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "Checksum mismatch for $($Record.name) $($Record.vers). Expected $expectedHash but found $actualHash."
        }
    }

    $Record | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $metadataFile -Encoding UTF8

    $expandedPath = $null
    if ($Expand) {
        $expandedPath = Join-Path $destination "$($Record.name)-$($Record.vers)"
        New-Directory -Path $expandedPath
        $tarFile = Join-Path $destination "$($Record.name)-$($Record.vers).tar"
        Copy-Item -LiteralPath $crateFile -Destination $tarFile -Force
        tar -xf $tarFile -C $expandedPath
        Remove-Item -LiteralPath $tarFile -Force
    }

    return [pscustomobject]@{
        Name         = $Record.name
        Version      = $Record.vers
        CrateFile    = $crateFile
        MetadataFile = $metadataFile
        DownloadUrl  = $downloadUrl
        ExpandedTo   = $expandedPath
    }
}

function Resolve-CrateGraph {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryBase,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][object[]]$RootRequests
    )

    $resolved = @{}
    $failures = @()
    $downloads = @()
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($root in $RootRequests) {
        $queue.Enqueue($root)
    }

    while ($queue.Count -gt 0) {
        $request = $queue.Dequeue()
        $name = [string]$request.Name

        try {
            $records = Read-CrateIndex -RegistryBase $RegistryBase -Name $name
            $selected = Select-CrateVersion -Records $records -Requirement ([string]$request.Requirement)
            $key = "$($selected.name)@$($selected.vers)"
            if ($resolved.ContainsKey($key)) {
                continue
            }

            $resolved[$key] = [pscustomobject]@{
                Name        = $selected.name
                Version     = $selected.vers
                Requirement = $request.Requirement
                Parent      = $request.Parent
            }
            $downloads += Save-Crate -Config $Config -Record $selected -DestinationRoot $OutputDirectory

            $activeFeatures = Get-ActiveFeatureSet -Record $selected -RequestedFeatures @($request.Features) -UseAllFeatures:($AllFeatures -and $request.Root) -DisableDefaultFeatures:([bool]$request.NoDefaultFeatures)

            foreach ($dep in @($selected.deps)) {
                $kind = if ($dep.PSObject.Properties['kind'] -and $dep.kind) { [string]$dep.kind } else { 'normal' }
                if ($kind -eq 'dev' -and -not $IncludeDevDependencies) { continue }
                if ($kind -eq 'build' -and $ExcludeBuildDependencies) { continue }
                if ($SkipTargetSpecificDependencies -and $dep.PSObject.Properties['target'] -and $dep.target) { continue }
                if (-not (Test-DependencyEnabled -Dependency $dep -ActiveFeatures $activeFeatures)) { continue }

                $depName = [string]$dep.name
                if ($dep.PSObject.Properties['package'] -and $dep.package) {
                    $depName = [string]$dep.package
                }

                $queue.Enqueue([pscustomobject]@{
                    Name              = $depName
                    Requirement       = [string]$dep.req
                    Parent            = $key
                    Features          = @($dep.features)
                    NoDefaultFeatures = ($dep.PSObject.Properties['default_features'] -and -not $dep.default_features)
                    Root              = $false
                })
            }
        }
        catch {
            $failures += [pscustomobject]@{
                Name        = $name
                Requirement = $request.Requirement
                Parent      = $request.Parent
                Error       = $_.Exception.Message
            }
        }
    }

    return [pscustomobject]@{
        Registry      = $RegistryBase
        RootCrate     = $Crate
        RootVersion   = $Version
        ManifestPath  = $ManifestPath
        Crates        = @($resolved.Values | Sort-Object Name, Version)
        Downloads     = $downloads
        Failures      = $failures
        Output        = $OutputDirectory
        Expanded      = [bool]$Expand
    }
}

New-Directory -Path $OutputDirectory
if (-not $Crate -and -not $ManifestPath) {
    throw "Pass either -Crate or -ManifestPath."
}

$rootRequests = @()
if ($Crate) {
    $rootRequests += [pscustomobject]@{
        Name              = $Crate
        Requirement       = ConvertTo-RootRequirement -RequestedVersion $Version
        Parent            = $null
        Features          = $Features
        NoDefaultFeatures = [bool]$NoDefaultFeatures
        Root              = $true
    }
}
if ($ManifestPath) {
    $rootRequests += Read-CargoManifestDependencies -Path $ManifestPath
}

$registryBase = Get-RegistryBase -Value $Registry
$config = Invoke-Json -Uri (Join-Url -Base $registryBase -Path 'config.json')
$summary = Resolve-CrateGraph -RegistryBase $registryBase -Config $config -RootRequests $rootRequests
$summary | ConvertTo-Json -Depth 80
