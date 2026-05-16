<#
.SYNOPSIS
Randomly samples common public FOSS images and tests Get-ContainerImage.ps1.

.DESCRIPTION
The test uses -SkipLayers by default to validate registry access, image
reference parsing, manifest or index retrieval, platform selection, config blob
download, and OCI layout creation without downloading filesystem layers.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [int]$SampleSize = 5,

    [Parameter()]
    [string]$OutputDirectory = (Join-Path (Get-Location) 'common-foss-image-test-results'),

    [Parameter()]
    [string]$CacheDirectory = (Join-Path (Get-Location) 'common-foss-image-cache-test'),

    [Parameter()]
    [string]$Platform = 'linux/amd64',

    [Parameter()]
    [switch]$FullPull
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function ConvertTo-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Value)
    return ($Value -replace '[\\/:*?"<>|@]', '_')
}

function Assert-FileExists {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw $Message
    }
}

New-Directory -Path $OutputDirectory
New-Directory -Path $CacheDirectory

$puller = Join-Path $PSScriptRoot 'Get-ContainerImage.ps1'
Assert-FileExists -Path $puller -Message "Could not find $puller"

$pool = @(
    [pscustomobject]@{ Image = 'alpine:3.20'; Registry = 'registry-1.docker.io'; Repository = 'library/alpine' },
    [pscustomobject]@{ Image = 'debian:bookworm-slim'; Registry = 'registry-1.docker.io'; Repository = 'library/debian' },
    [pscustomobject]@{ Image = 'ubuntu:24.04'; Registry = 'registry-1.docker.io'; Repository = 'library/ubuntu' },
    [pscustomobject]@{ Image = 'busybox:1.36'; Registry = 'registry-1.docker.io'; Repository = 'library/busybox' },
    [pscustomobject]@{ Image = 'nginx:1.27-alpine'; Registry = 'registry-1.docker.io'; Repository = 'library/nginx' },
    [pscustomobject]@{ Image = 'redis:7-alpine'; Registry = 'registry-1.docker.io'; Repository = 'library/redis' },
    [pscustomobject]@{ Image = 'postgres:16-alpine'; Registry = 'registry-1.docker.io'; Repository = 'library/postgres' },
    [pscustomobject]@{ Image = 'python:3.12-alpine'; Registry = 'registry-1.docker.io'; Repository = 'library/python' },
    [pscustomobject]@{ Image = 'node:22-alpine'; Registry = 'registry-1.docker.io'; Repository = 'library/node' },
    [pscustomobject]@{ Image = 'golang:1.23-alpine'; Registry = 'registry-1.docker.io'; Repository = 'library/golang' },
    [pscustomobject]@{ Image = 'registry.gitlab.com/gitlab-org/gitlab-runner:alpine'; Registry = 'registry.gitlab.com'; Repository = 'gitlab-org/gitlab-runner' },
    [pscustomobject]@{ Image = 'quay.io/prometheus/prometheus:latest'; Registry = 'quay.io'; Repository = 'prometheus/prometheus' }
)

if ($SampleSize -lt 1 -or $SampleSize -gt $pool.Count) {
    throw "SampleSize must be between 1 and $($pool.Count)."
}

$sample = $pool | Get-Random -Count $SampleSize
$sampleFile = Join-Path $OutputDirectory 'sample.json'
$sample | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sampleFile -Encoding UTF8

$results = @()
foreach ($case in $sample) {
    $started = Get-Date
    $safeName = ConvertTo-SafeFileName -Value $case.Image
    $logFile = Join-Path $OutputDirectory "$safeName.log"
    $success = $false
    $errorText = ''
    $summary = $null

    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-File',
        $puller,
        '-Image',
        $case.Image,
        '-Platform',
        $Platform,
        '-OutputDirectory',
        $CacheDirectory
    )
    if (-not $FullPull) {
        $arguments += '-SkipLayers'
    }

    try {
        $output = & pwsh @arguments 2>&1
        $exitCode = $LASTEXITCODE
        $output | Set-Content -LiteralPath $logFile -Encoding UTF8
        if ($exitCode -ne 0) {
            throw "Puller exited $exitCode"
        }

        $summary = ($output -join "`n") | ConvertFrom-Json
        if ($summary.Registry -ne $case.Registry) {
            throw "Expected registry $($case.Registry), got $($summary.Registry)"
        }
        if ($summary.Repository -ne $case.Repository) {
            throw "Expected repository $($case.Repository), got $($summary.Repository)"
        }

        Assert-FileExists -Path (Join-Path $summary.LayoutPath 'oci-layout') -Message 'Missing oci-layout file.'
        Assert-FileExists -Path (Join-Path $summary.LayoutPath 'index.json') -Message 'Missing index.json file.'
        if (-not $summary.ManifestDigest) {
            throw 'Missing selected manifest digest.'
        }
        if (-not $summary.ConfigFile) {
            throw 'Missing image config blob.'
        }
        Assert-FileExists -Path $summary.ConfigFile -Message 'Config blob was not written.'
        if ($FullPull -and @($summary.LayerFiles).Count -eq 0) {
            throw 'Full pull did not download any layer files.'
        }

        $success = $true
    }
    catch {
        $errorText = $_.Exception.Message
        if (-not (Test-Path -LiteralPath $logFile)) {
            $errorText | Set-Content -LiteralPath $logFile -Encoding UTF8
        }
    }

    $finished = Get-Date
    $results += [pscustomobject]@{
        Image          = $case.Image
        Registry       = $case.Registry
        Repository     = $case.Repository
        Platform       = $Platform
        FullPull       = [bool]$FullPull
        Success        = $success
        Started        = $started.ToString('o')
        Finished       = $finished.ToString('o')
        DurationSec    = [Math]::Round(($finished - $started).TotalSeconds, 3)
        ManifestDigest = if ($summary) { $summary.ManifestDigest } else { '' }
        LayoutPath     = if ($summary) { $summary.LayoutPath } else { '' }
        LogFile        = $logFile
        Error          = $errorText
    }
}

$resultsFile = Join-Path $OutputDirectory 'results.json'
$summaryFile = Join-Path $OutputDirectory 'summary.json'

$results | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultsFile -Encoding UTF8

$summaryObject = [pscustomobject]@{
    SampleSize  = $SampleSize
    Successes   = @($results | Where-Object { $_.Success }).Count
    Failures    = @($results | Where-Object { -not $_.Success }).Count
    FullPull    = [bool]$FullPull
    Platform    = $Platform
    SampleFile  = $sampleFile
    ResultsFile = $resultsFile
}

$summaryObject | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $summaryFile -Encoding UTF8
$summaryObject | ConvertTo-Json -Depth 20

if ($summaryObject.Failures -gt 0) {
    exit 1
}
