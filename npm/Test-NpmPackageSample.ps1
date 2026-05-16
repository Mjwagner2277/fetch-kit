<#
.SYNOPSIS
Randomly samples popular npm packages and tests Get-NpmPackage.ps1.

.DESCRIPTION
This harness keeps a repository-local list of commonly downloaded npm packages,
samples from that list, and runs the PowerShell-only npm retriever against each
sample. It writes the selected package list, per-package logs, detailed results,
and a summary JSON file.
#>

[CmdletBinding()]
param(
    [int]$SampleSize = 5,
    [int]$BatchSize = 5,
    [int]$MaxDepth = 2,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'sample-results'),
    [string]$CacheDirectory = (Join-Path $PSScriptRoot 'npm-package-cache-sample'),
    [string]$Registry = 'https://registry.npmjs.org/',
    [switch]$IncludeOptionalDependencies,
    [switch]$IncludePeerDependencies,
    [switch]$IncludeDevDependencies
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

$popularPackages = @(
    '@babel/core', '@babel/generator', '@babel/helper-compilation-targets',
    '@babel/helper-module-imports', '@babel/parser', '@babel/runtime',
    '@babel/template', '@babel/traverse', '@babel/types', '@eslint/js',
    '@jridgewell/gen-mapping', '@jridgewell/resolve-uri',
    '@jridgewell/sourcemap-codec', '@jridgewell/trace-mapping',
    '@rollup/rollup-linux-x64-gnu', '@types/estree', '@types/json-schema',
    '@types/node', '@typescript-eslint/eslint-plugin', '@typescript-eslint/parser',
    'acorn', 'ajv', 'ansi-regex', 'ansi-styles', 'argparse', 'axios',
    'balanced-match', 'brace-expansion', 'braces', 'browserslist', 'chalk',
    'chokidar', 'color-convert', 'color-name', 'commander', 'concat-map',
    'cross-spawn', 'debug', 'deepmerge', 'detect-libc', 'dotenv',
    'electron-to-chromium', 'emoji-regex', 'enhanced-resolve', 'esbuild',
    'escalade', 'escape-string-regexp', 'eslint', 'eslint-scope', 'espree',
    'esquery', 'estraverse', 'esutils', 'fast-deep-equal', 'fast-glob',
    'fast-json-stable-stringify', 'fastq', 'fill-range', 'find-up', 'fs-extra',
    'glob', 'glob-parent', 'graceful-fs', 'has-flag', 'ignore', 'import-fresh',
    'is-core-module', 'is-extglob', 'is-fullwidth-code-point', 'is-glob',
    'is-number', 'js-tokens', 'js-yaml', 'json-schema-traverse',
    'json-stable-stringify-without-jsonify', 'json5', 'kind-of', 'levn',
    'locate-path', 'lodash', 'lru-cache', 'merge2', 'micromatch', 'minimatch',
    'ms', 'nanoid', 'node-releases', 'normalize-path', 'optionator', 'p-limit',
    'p-locate', 'parent-module', 'path-exists', 'path-key', 'picocolors',
    'picomatch', 'postcss', 'prelude-ls', 'prettier', 'punycode',
    'queue-microtask', 'react', 'resolve', 'reusify', 'rollup', 'semver',
    'shebang-command', 'shebang-regex', 'source-map-js', 'string-width',
    'strip-ansi', 'supports-color', 'supports-preserve-symlinks-flag',
    'to-regex-range', 'tslib', 'type-check', 'typescript', 'undici-types',
    'update-browserslist-db', 'uri-js', 'vite', 'webpack', 'which',
    'word-wrap', 'wrap-ansi', 'yallist'
)

New-Directory -Path $OutputDirectory

$retriever = Join-Path $PSScriptRoot 'Get-NpmPackage.ps1'
if (-not (Test-Path -LiteralPath $retriever)) {
    throw "Could not find $retriever"
}

$uniquePackages = @($popularPackages | Sort-Object -Unique)
if ($uniquePackages.Count -lt $SampleSize) {
    throw "Only found $($uniquePackages.Count) packages; need $SampleSize."
}

$sample = @($uniquePackages | Get-Random -Count $SampleSize | ForEach-Object {
    [pscustomobject]@{
        Package = $_
        Version = 'latest'
    }
})

$sampleFile = Join-Path $OutputDirectory 'sample.json'
$sample | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sampleFile -Encoding UTF8

$results = @()
$batchNumber = 0

for ($index = 0; $index -lt $sample.Count; $index += $BatchSize) {
    $batchNumber++
    $end = [Math]::Min($index + $BatchSize - 1, $sample.Count - 1)
    $batch = @($sample[$index..$end])

    foreach ($item in $batch) {
        $packageName = [string]$item.Package
        $version = [string]$item.Version
        $safeName = ConvertTo-SafeFileName -Value "$packageName@$version"
        $logFile = Join-Path $OutputDirectory "$safeName.log"

        $arguments = @(
            '-NoLogo', '-NoProfile', '-File', $retriever,
            '-Package', $packageName,
            '-Version', $version,
            '-Registry', $Registry,
            '-OutputDirectory', $CacheDirectory,
            '-MaxDepth', $MaxDepth
        )

        if ($IncludeOptionalDependencies) { $arguments += '-IncludeOptionalDependencies' }
        if ($IncludePeerDependencies) { $arguments += '-IncludePeerDependencies' }
        if ($IncludeDevDependencies) { $arguments += '-IncludeDevDependencies' }

        $started = Get-Date
        $output = & pwsh @arguments 2>&1
        $exitCode = $LASTEXITCODE
        $finished = Get-Date

        $output | Set-Content -LiteralPath $logFile -Encoding UTF8

        $packageCount = 0
        $failureCount = 0
        if ($exitCode -eq 0 -and $output) {
            try {
                $json = ($output -join "`n") | ConvertFrom-Json
                $packageCount = [int]$json.PackageCount
                $failureCount = [int]$json.FailureCount
            }
            catch {
                $failureCount = 1
            }
        }

        $results += [pscustomobject]@{
            Batch        = $batchNumber
            Package      = $packageName
            Version      = $version
            Success      = ($exitCode -eq 0)
            ExitCode     = $exitCode
            PackageCount = $packageCount
            FailureCount = $failureCount
            Started      = $started.ToString('o')
            Finished     = $finished.ToString('o')
            DurationSec  = [Math]::Round(($finished - $started).TotalSeconds, 3)
            LogFile      = $logFile
            Error        = if ($exitCode -eq 0) { '' } else { ($output -join "`n") }
        }
    }
}

$resultsFile = Join-Path $OutputDirectory 'results.json'
$summaryFile = Join-Path $OutputDirectory 'summary.json'

$results | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultsFile -Encoding UTF8

$summary = [pscustomobject]@{
    SampleSize                  = $SampleSize
    BatchSize                   = $BatchSize
    MaxDepth                    = $MaxDepth
    Registry                    = $Registry
    IncludeOptionalDependencies = [bool]$IncludeOptionalDependencies
    IncludePeerDependencies     = [bool]$IncludePeerDependencies
    IncludeDevDependencies      = [bool]$IncludeDevDependencies
    CandidateCount              = $uniquePackages.Count
    Successes                   = @($results | Where-Object { $_.Success }).Count
    Failures                    = @($results | Where-Object { -not $_.Success }).Count
    RetrievedPackages           = (@($results | Measure-Object -Property PackageCount -Sum).Sum)
    DependencyFailures          = (@($results | Measure-Object -Property FailureCount -Sum).Sum)
    SampleFile                  = $sampleFile
    ResultsFile                 = $resultsFile
    CacheDirectory              = $CacheDirectory
}

$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $summaryFile -Encoding UTF8
$summary | ConvertTo-Json -Depth 20
