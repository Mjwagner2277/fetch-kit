<#
.SYNOPSIS
Downloads the latest Grype vulnerability database without invoking Grype.

.DESCRIPTION
Get-GrypeDatabase.ps1 retrieves Anchore's Grype database metadata, resolves the
current database archive URL, downloads the archive, verifies its SHA-256
checksum, and writes provenance metadata next to the archive.

The script uses only PowerShell HTTP, JSON, filesystem, and hashing APIs. It is
intended for air-gap staging workflows where the Grype CLI is unavailable or
intentionally avoided during internet retrieval.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$MetadataUrl = 'https://grype.anchore.io/databases/v6/latest.json',

    [Parameter()]
    [string]$OutputDirectory = (Join-Path (Get-Location) 'grype-db-cache'),

    [Parameter()]
    [string]$OutputFileName = '',

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Invoke-Json {
    param([Parameter(Mandatory = $true)][string]$Uri)

    try {
        return Invoke-RestMethod -Uri $Uri -Headers @{
            'Accept'     = 'application/json'
            'User-Agent' = 'Get-GrypeDatabase.ps1'
        }
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

function Invoke-Download {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    try {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -Headers @{
            'User-Agent' = 'Get-GrypeDatabase.ps1'
        } | Out-Null
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

function Resolve-DatabaseUrl {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$MetadataUrl
    )

    if ($Metadata.PSObject.Properties['url'] -and $Metadata.url) {
        return [string]$Metadata.url
    }

    if (-not ($Metadata.PSObject.Properties['path'] -and $Metadata.path)) {
        throw 'Metadata did not contain either url or path.'
    }

    $baseUri = [System.Uri]$MetadataUrl
    return ([System.Uri]::new($baseUri, [string]$Metadata.path)).AbsoluteUri
}

function Get-ExpectedSha256 {
    param([Parameter(Mandatory = $true)]$Metadata)

    if (-not ($Metadata.PSObject.Properties['checksum'] -and $Metadata.checksum)) {
        throw 'Metadata did not contain checksum.'
    }

    return ([string]$Metadata.checksum) -replace '^sha256:', ''
}

function Get-ArchiveFileName {
    param(
        [Parameter(Mandatory = $true)][string]$DatabaseUrl,
        [string]$OutputFileName
    )

    if ($OutputFileName) {
        return $OutputFileName
    }

    $uri = [System.Uri]$DatabaseUrl
    $name = [System.IO.Path]::GetFileName($uri.AbsolutePath)
    if (-not $name) {
        return 'grype-db.tar.zst'
    }
    return $name
}

New-Directory -Path $OutputDirectory

$metadata = Invoke-Json -Uri $MetadataUrl
$databaseUrl = Resolve-DatabaseUrl -Metadata $metadata -MetadataUrl $MetadataUrl
$expectedSha256 = (Get-ExpectedSha256 -Metadata $metadata).ToLowerInvariant()
$archiveName = Get-ArchiveFileName -DatabaseUrl $databaseUrl -OutputFileName $OutputFileName
$archivePath = Join-Path $OutputDirectory $archiveName
$metadataPath = Join-Path $OutputDirectory 'grype-db-latest.json'
$summaryPath = Join-Path $OutputDirectory 'summary.json'

if ((Test-Path -LiteralPath $archivePath) -and -not $Force) {
    throw "Output file already exists: $archivePath. Use -Force to overwrite."
}

Invoke-Download -Uri $databaseUrl -OutFile $archivePath

$actualSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSha256 -ne $expectedSha256) {
    throw "Checksum mismatch for $archivePath. Expected $expectedSha256 but got $actualSha256."
}

$metadata | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $metadataPath -Encoding UTF8

$summary = [pscustomobject]@{
    MetadataUrl   = $MetadataUrl
    DatabaseUrl   = $databaseUrl
    ArchivePath   = (Resolve-Path -LiteralPath $archivePath).Path
    MetadataPath  = (Resolve-Path -LiteralPath $metadataPath).Path
    SchemaVersion = if ($metadata.PSObject.Properties['schemaVersion']) { $metadata.schemaVersion } else { $null }
    Built         = if ($metadata.PSObject.Properties['built']) { $metadata.built } else { $null }
    Status        = if ($metadata.PSObject.Properties['status']) { $metadata.status } else { $null }
    Sha256        = $actualSha256
    Bytes         = (Get-Item -LiteralPath $archivePath).Length
}

$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
$summary | ConvertTo-Json -Depth 10
