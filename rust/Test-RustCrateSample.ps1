<#
.SYNOPSIS
Randomly tests Get-RustCrate.ps1 against a small sample from a curated crate list.

.DESCRIPTION
This script carries a curated list of common crates and randomly selects a
subset to test. Each selected crate is fetched through Get-RustCrate.ps1 with
dependency resolution enabled by default, then a per-crate log plus JSON summary
are written to the output directory.
#>

[CmdletBinding()]
param(
    [int]$SampleSize = 5,
    [string]$OutputDirectory = (Join-Path (Get-Location) 'rust-sample-results'),
    [string]$CacheDirectory = (Join-Path (Get-Location) 'crate-cache-sample'),
    [switch]$SkipTargetSpecificDependencies,
    [switch]$IncludeDevDependencies,
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

function ConvertTo-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Value)
    return ($Value -replace '[\\/:*?"<>|@]', '_')
}

$crateCandidates = @(
    'anyhow',
    'async-trait',
    'axum',
    'base64',
    'bitflags',
    'bytes',
    'camino',
    'cfg-if',
    'chrono',
    'clap',
    'color-eyre',
    'criterion',
    'crossbeam-channel',
    'crossbeam-utils',
    'csv',
    'dashmap',
    'derive_more',
    'dirs',
    'either',
    'env_logger',
    'eyre',
    'futures',
    'futures-util',
    'getrandom',
    'glob',
    'hashbrown',
    'heck',
    'hex',
    'humantime',
    'hyper',
    'indexmap',
    'indicatif',
    'itertools',
    'itoa',
    'lazy_static',
    'libc',
    'log',
    'memchr',
    'mime',
    'mio',
    'nom',
    'num-traits',
    'once_cell',
    'parking_lot',
    'percent-encoding',
    'pin-project',
    'pin-project-lite',
    'pretty_assertions',
    'proc-macro2',
    'prost',
    'quote',
    'rand',
    'rayon',
    'regex',
    'reqwest',
    'ring',
    'rustls',
    'rustversion',
    'ryu',
    'same-file',
    'schemars',
    'scopeguard',
    'semver',
    'serde',
    'serde_json',
    'serde_with',
    'serde_yaml',
    'sha2',
    'signal-hook',
    'smallvec',
    'socket2',
    'strsim',
    'syn',
    'tempfile',
    'termcolor',
    'textwrap',
    'thiserror',
    'time',
    'tinyvec',
    'tokio',
    'tokio-stream',
    'tokio-util',
    'toml',
    'tower',
    'tower-http',
    'tracing',
    'tracing-subscriber',
    'trybuild',
    'typenum',
    'unicode-ident',
    'url',
    'uuid',
    'walkdir',
    'want',
    'which',
    'winapi',
    'winnow',
    'zeroize',
    'zstd'
)

if ($SampleSize -lt 1) {
    throw '-SampleSize must be at least 1.'
}

if ($SampleSize -gt $crateCandidates.Count) {
    throw "Sample size $SampleSize is larger than the candidate list count $($crateCandidates.Count)."
}

New-Directory -Path $OutputDirectory
New-Directory -Path $CacheDirectory

$retriever = Join-Path $PSScriptRoot 'Get-RustCrate.ps1'
if (-not (Test-Path -LiteralPath $retriever)) {
    throw "Could not find $retriever"
}

$sample = $crateCandidates | Get-Random -Count $SampleSize
$sampleFile = Join-Path $OutputDirectory 'sample.json'
$sample |
    ForEach-Object { [pscustomobject]@{ Crate = $_; Version = 'latest' } } |
    ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $sampleFile -Encoding UTF8

$results = @()
foreach ($crate in $sample) {
    $safeName = ConvertTo-SafeFileName -Value "$crate@latest"
    $logFile = Join-Path $OutputDirectory "$safeName.log"

    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        $retriever,
        '-Crate',
        $crate,
        '-Version',
        'latest',
        '-OutputDirectory',
        $CacheDirectory
    )

    if ($SkipTargetSpecificDependencies) {
        $arguments += '-SkipTargetSpecificDependencies'
    }

    if ($IncludeDevDependencies) {
        $arguments += '-IncludeDevDependencies'
    }

    if ($Expand) {
        $arguments += '-Expand'
    }

    $started = Get-Date
    $output = & pwsh @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $finished = Get-Date

    $output | Set-Content -LiteralPath $logFile -Encoding UTF8

    $resolvedCount = 0
    $downloadCount = 0
    if ($exitCode -eq 0) {
        try {
            $json = ($output -join "`n") | ConvertFrom-Json
            $resolvedCount = @($json.Crates).Count
            $downloadCount = @($json.Downloads).Count
        }
        catch {
            $resolvedCount = 0
            $downloadCount = 0
        }
    }

    $results += [pscustomobject]@{
        Crate         = $crate
        Version       = 'latest'
        Success       = ($exitCode -eq 0)
        ExitCode      = $exitCode
        Started       = $started.ToString('o')
        Finished      = $finished.ToString('o')
        DurationSec   = [Math]::Round(($finished - $started).TotalSeconds, 3)
        ResolvedCount = $resolvedCount
        DownloadCount = $downloadCount
        LogFile       = $logFile
        Error         = if ($exitCode -eq 0) { '' } else { ($output -join "`n") }
    }
}

$resultsFile = Join-Path $OutputDirectory 'results.json'
$summaryFile = Join-Path $OutputDirectory 'summary.json'

$results | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultsFile -Encoding UTF8

$summary = [pscustomobject]@{
    SampleSize                     = $SampleSize
    CandidateCount                 = $crateCandidates.Count
    SkipTargetSpecificDependencies = [bool]$SkipTargetSpecificDependencies
    IncludeDevDependencies         = [bool]$IncludeDevDependencies
    Expand                         = [bool]$Expand
    Successes                      = @($results | Where-Object { $_.Success }).Count
    Failures                       = @($results | Where-Object { -not $_.Success }).Count
    TotalResolvedCrates            = (@($results | Measure-Object -Property ResolvedCount -Sum).Sum)
    TotalDownloadedCrates          = (@($results | Measure-Object -Property DownloadCount -Sum).Sum)
    SampleFile                     = $sampleFile
    ResultsFile                    = $resultsFile
    CacheDirectory                 = $CacheDirectory
}

$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $summaryFile -Encoding UTF8
$summary | ConvertTo-Json -Depth 20
