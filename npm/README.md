# PowerShell npm Package Retrieval

`Get-NpmPackage.ps1` downloads npm package tarballs and registry dependency
metadata without calling `npm`, `node`, `npx`, or any JavaScript toolchain. It
uses the npm registry HTTP API, resolves dist-tags and common semver ranges, and
recursively downloads the selected dependency graph.

## Quick Start

Download the latest version of a package and its regular dependencies:

```powershell
.\npm\Get-NpmPackage.ps1 -Package "lodash"
```

Download an exact version:

```powershell
.\npm\Get-NpmPackage.ps1 `
  -Package "react" `
  -Version "18.2.0"
```

Download a scoped package:

```powershell
.\npm\Get-NpmPackage.ps1 `
  -Package "@babel/core" `
  -Version "^7.24.0"
```

Include optional and peer dependency edges:

```powershell
.\npm\Get-NpmPackage.ps1 `
  -Package "webpack" `
  -Version "latest" `
  -IncludeOptionalDependencies `
  -IncludePeerDependencies
```

Use a private registry:

```powershell
$env:NPM_TOKEN = "npm_..."

.\npm\Get-NpmPackage.ps1 `
  -Package "@company/internal-lib" `
  -Version "2.3.4" `
  -Registry "https://registry.example.com/" `
  -BearerToken $env:NPM_TOKEN
```

Run a random five-package sample from the repository's popular-package list:

```powershell
.\npm\Test-NpmPackageSample.ps1
```

## Output

By default, downloads are written under:

```text
.\npm-package-cache
```

Each selected package version is stored under:

```text
npm-package-cache/
  packages/
    _babel_core/
      7.24.9/
        _babel_core-7.24.9.tgz
        metadata.json
        package.json
```

The command prints a JSON summary with:

- `Packages`: resolved package names, versions, requirements, parents, and
  dependency kinds.
- `Edges`: dependency graph edges.
- `Downloads`: tarball and metadata paths.
- `Failures`: resolution or download failures.
- `Output`: cache root.

## Dependency Resolution Behavior

The resolver downloads the root package, then follows its `dependencies`
recursively. Optional, peer, and root development dependencies are controlled by
switches:

- `-IncludeOptionalDependencies`
- `-IncludePeerDependencies`
- `-IncludeDevDependencies`

Version selection supports dist-tags such as `latest`, exact versions, wildcard
ranges, caret ranges, tilde ranges, comparator ranges like `>=1 <2`, hyphen
ranges like `1.2.0 - 1.4.0`, and `||` alternatives. For a matching range, it
chooses the highest matching non-prerelease and non-deprecated version by
default.

Use `-IncludePrerelease` or `-IncludeDeprecated` when those versions must be
eligible during selection.

## Important Differences From npm

This is a retrieval tool, not an installer. It does not:

- create `node_modules`
- run lifecycle scripts
- read or write `package-lock.json`, `npm-shrinkwrap.json`, or workspaces
- implement npm's full peer dependency placement and conflict solver
- evaluate `os`, `cpu`, `engines`, or package manager constraints
- apply `overrides`, aliases, bundled dependencies, or registry config files
- verify Subresource Integrity strings beyond SHA-1 `dist.shasum`
- unpack `.tgz` files

Those omissions keep the implementation PowerShell-only and focused on
collecting npm registry source artifacts for offline review or mirroring.

## Parameters

- `-Package`: root npm package name, including scoped names such as
  `@scope/name`.
- `-Version`: exact version, dist-tag, or semver range. Defaults to `latest`.
- `-Registry`: npm-compatible registry URL. Defaults to
  `https://registry.npmjs.org/`.
- `-OutputDirectory`: cache destination. Defaults to `.\npm-package-cache`.
- `-MaxDepth`: maximum dependency depth. `0` means unlimited.
- `-IncludeDevDependencies`: include root package `devDependencies`.
- `-IncludeOptionalDependencies`: include `optionalDependencies`.
- `-IncludePeerDependencies`: include `peerDependencies`.
- `-IncludeDeprecated`: allow deprecated versions during selection.
- `-IncludePrerelease`: allow prerelease versions during selection.
- `-BearerToken`: bearer token for private registries, defaults to
  `$env:NPM_TOKEN`.
- `-Username` and `-Password`: basic authentication fallback.

## Sample Test Harness

`Test-NpmPackageSample.ps1` keeps a checked-in list of 100+ commonly downloaded
npm packages, samples five by default, and runs `Get-NpmPackage.ps1` for each
selected package. It writes:

- `sample-results/sample.json`
- one log file per sampled package
- `sample-results/results.json`
- `sample-results/summary.json`

The harness defaults to `-MaxDepth 2` so random samples stay bounded while still
testing recursive dependency retrieval. Pass `-MaxDepth 0` to walk the full
registry dependency graph for each sampled package.
