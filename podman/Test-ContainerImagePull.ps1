<#
.SYNOPSIS
Exercises Get-ContainerImage.ps1 against public registry images.

.DESCRIPTION
The default test set includes the GitLab container scanning analyzer image from
GitLab's offline container scanning documentation and a Docker Hub shorthand
image. Tests run with -SkipLayers by default so they validate reference parsing,
registry authentication, manifest-list platform selection, config retrieval, and
OCI layout creation without downloading every image layer.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDirectory = (Join-Path (Get-Location) 'container-image-test-results'),

    [Parameter()]
    [string]$CacheDirectory = (Join-Path (Get-Location) 'container-image-cache-test'),

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

function Get-BlobPathFromDigest {
    param(
        [Parameter(Mandatory = $true)][string]$LayoutPath,
        [Parameter(Mandatory = $true)][string]$Digest
    )

    if ($Digest -notmatch '^([^:]+):(.+)$') {
        throw "Unsupported digest format: $Digest"
    }
    return Join-Path (Join-Path (Join-Path $LayoutPath 'blobs') $Matches[1]) $Matches[2]
}

New-Directory -Path $OutputDirectory
New-Directory -Path $CacheDirectory

$puller = Join-Path $PSScriptRoot 'Get-ContainerImage.ps1'
Assert-FileExists -Path $puller -Message "Could not find $puller"

$cases = @(
    [pscustomobject]@{
        Name          = 'GitLabOfflineContainerScanningAnalyzer'
        Image         = 'registry.gitlab.com/security-products/container-scanning:8'
        ExpectedHost  = 'registry.gitlab.com'
        ExpectedRepo  = 'security-products/container-scanning'
        Source        = 'GitLab offline container scanning SOURCE_IMAGE'
    },
    [pscustomobject]@{
        Name          = 'DockerHubShortName'
        Image         = 'alpine:3.20'
        ExpectedHost  = 'registry-1.docker.io'
        ExpectedRepo  = 'library/alpine'
        Source        = 'Docker Hub public image shorthand'
    }
)

$results = @()
foreach ($case in $cases) {
    $started = Get-Date
    $safeName = ConvertTo-SafeFileName -Value $case.Name
    $logFile = Join-Path $OutputDirectory "$safeName.log"

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

    $success = $false
    $errorText = ''
    $summary = $null

    try {
        $output = & pwsh @arguments 2>&1
        $exitCode = $LASTEXITCODE
        $output | Set-Content -LiteralPath $logFile -Encoding UTF8
        if ($exitCode -ne 0) {
            throw "Puller exited $exitCode"
        }

        $summary = ($output -join "`n") | ConvertFrom-Json
        if ($summary.Registry -ne $case.ExpectedHost) {
            throw "Expected registry $($case.ExpectedHost), got $($summary.Registry)"
        }
        if ($summary.Repository -ne $case.ExpectedRepo) {
            throw "Expected repository $($case.ExpectedRepo), got $($summary.Repository)"
        }

        Assert-FileExists -Path (Join-Path $summary.LayoutPath 'oci-layout') -Message 'Missing oci-layout file.'
        Assert-FileExists -Path (Join-Path $summary.LayoutPath 'index.json') -Message 'Missing index.json file.'
        if (-not $summary.ManifestDigest) {
            throw 'Missing selected manifest digest.'
        }
        Assert-FileExists -Path (Get-BlobPathFromDigest -LayoutPath $summary.LayoutPath -Digest $summary.ManifestDigest) -Message 'Selected manifest blob was not written.'
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
        Name           = $case.Name
        Image          = $case.Image
        Source         = $case.Source
        Platform       = $Platform
        FullPull       = [bool]$FullPull
        Success        = $success
        Started        = $started.ToString('o')
        Finished       = $finished.ToString('o')
        DurationSec    = [Math]::Round(($finished - $started).TotalSeconds, 3)
        LogFile        = $logFile
        ManifestDigest = if ($summary) { $summary.ManifestDigest } else { '' }
        LayoutPath     = if ($summary) { $summary.LayoutPath } else { '' }
        Error          = $errorText
    }
}

$resultsFile = Join-Path $OutputDirectory 'results.json'
$summaryFile = Join-Path $OutputDirectory 'summary.json'

$results | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultsFile -Encoding UTF8

$summaryObject = [pscustomobject]@{
    Total       = $results.Count
    Successes   = @($results | Where-Object { $_.Success }).Count
    Failures    = @($results | Where-Object { -not $_.Success }).Count
    FullPull    = [bool]$FullPull
    Platform    = $Platform
    ResultsFile = $resultsFile
}

$summaryObject | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $summaryFile -Encoding UTF8
$summaryObject | ConvertTo-Json -Depth 20

if ($summaryObject.Failures -gt 0) {
    exit 1
}
