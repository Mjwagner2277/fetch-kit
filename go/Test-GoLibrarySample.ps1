<# 
.SYNOPSIS
Randomly samples Go modules from index.golang.org and tests Get-GoLibrary.ps1.

.DESCRIPTION
By default, each sampled module is tested with -ResolveDependencies. Use
-SkipResolveDependencies only when testing direct single-module retrieval.
#>

[CmdletBinding()]
param(
    [int]$SampleSize = 50,
    [int]$BatchSize = 10,
    [string]$OutputDirectory = (Join-Path (Get-Location) 'sample-results'),
    [switch]$ResolveDependencies,
    [switch]$SkipResolveDependencies,
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

function Invoke-ModuleIndex {
    param([int]$Limit = 2000)

    $uri = "https://index.golang.org/index?limit=$Limit"
    $response = Invoke-WebRequest -Uri $uri -UseBasicParsing
    $entries = @()

    foreach ($line in ($response.Content -split "`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed) {
            continue
        }
        $entries += $trimmed | ConvertFrom-Json
    }

    return $entries
}

function ConvertTo-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Value)
    return ($Value -replace '[\\/:*?"<>|@]', '_')
}

New-Directory -Path $OutputDirectory

$retriever = Join-Path $PSScriptRoot 'Get-GoLibrary.ps1'
if (-not (Test-Path -LiteralPath $retriever)) {
    throw "Could not find $retriever"
}

$entries = Invoke-ModuleIndex
$unique = $entries |
    Where-Object { $_.Path -and $_.Version } |
    Group-Object -Property Path |
    ForEach-Object { $_.Group | Select-Object -First 1 }

if ($unique.Count -lt $SampleSize) {
    throw "Only found $($unique.Count) unique modules; need $SampleSize."
}

$sample = $unique | Get-Random -Count $SampleSize
$sampleFile = Join-Path $OutputDirectory 'sample.json'
$sample | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sampleFile -Encoding UTF8

$results = @()
$batchNumber = 0
$resolveDependencyGraph = -not [bool]$SkipResolveDependencies

for ($index = 0; $index -lt $sample.Count; $index += $BatchSize) {
    $batchNumber++
    $end = [Math]::Min($index + $BatchSize - 1, $sample.Count - 1)
    $batch = @($sample[$index..$end])

    foreach ($item in $batch) {
        $module = [string]$item.Path
        $version = [string]$item.Version
        $safeName = ConvertTo-SafeFileName -Value "$module@$version"
        $logFile = Join-Path $OutputDirectory "$safeName.log"

        $arguments = @(
            '-NoLogo',
            '-NoProfile',
            $retriever,
            '-Module',
            $module,
            '-Version',
            $version,
            '-OutputDirectory',
            (Join-Path (Get-Location) 'go-library-cache-sample')
        )

        if ($resolveDependencyGraph) {
            $arguments += '-ResolveDependencies'
        }

        if ($Expand) {
            $arguments += '-Expand'
        }

        $started = Get-Date
        $output = & pwsh @arguments 2>&1
        $exitCode = $LASTEXITCODE
        $finished = Get-Date

        $output | Set-Content -LiteralPath $logFile -Encoding UTF8

        $results += [pscustomobject]@{
            Batch       = $batchNumber
            Module      = $module
            Version     = $version
            Success     = ($exitCode -eq 0)
            ExitCode    = $exitCode
            Started     = $started.ToString('o')
            Finished    = $finished.ToString('o')
            DurationSec = [Math]::Round(($finished - $started).TotalSeconds, 3)
            LogFile     = $logFile
            Error       = if ($exitCode -eq 0) { '' } else { ($output -join "`n") }
        }
    }
}

$resultsFile = Join-Path $OutputDirectory 'results.json'
$summaryFile = Join-Path $OutputDirectory 'summary.json'

$results | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultsFile -Encoding UTF8

$batchSummary = @(
    $results |
        Group-Object Batch |
        ForEach-Object {
            [pscustomobject]@{
                Batch     = [int]$_.Name
                Successes = @($_.Group | Where-Object { $_.Success }).Count
                Failures  = @($_.Group | Where-Object { -not $_.Success }).Count
            }
        } |
        Sort-Object Batch
)

$failedModules = @(
    $results |
        Where-Object { -not $_.Success } |
        Select-Object Module, Version, ExitCode, LogFile, Error
)

$summary = [pscustomobject]@{
    SampleSize          = $SampleSize
    BatchSize           = $BatchSize
    ResolveDependencies = $resolveDependencyGraph
    Expand              = [bool]$Expand
    Successes           = @($results | Where-Object { $_.Success }).Count
    Failures            = @($results | Where-Object { -not $_.Success }).Count
    BatchSummary        = $batchSummary
    FailedModules       = $failedModules
    SampleFile          = $sampleFile
    ResultsFile         = $resultsFile
}

$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $summaryFile -Encoding UTF8
$summary | ConvertTo-Json -Depth 20
