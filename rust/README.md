# PowerShell Rust Crate Retrieval

`Get-RustCrate.ps1` downloads Rust crates and their registry dependencies without
calling `cargo`, `rustc`, `git`, or any Rust toolchain component. It uses the
Cargo sparse registry protocol over HTTP, reads the same index metadata Cargo
uses for registry packages, resolves semver dependency requirements, and stores
the resulting `.crate` archives in a local cache.

This is useful for air-gap preparation, security review, dependency collection,
and registry mirroring tests where the goal is to retrieve source packages and
their dependency graph rather than build a project.

## Quick Start

Download one exact crate version and its normal/build dependencies:

```powershell
.\rust\Get-RustCrate.ps1 `
  -Crate "serde_json" `
  -Version "1.0.145"
```

Download the newest non-yanked version matching a root requirement:

```powershell
.\rust\Get-RustCrate.ps1 `
  -Crate "tokio" `
  -Version "^1.40"
```

Download the latest available non-yanked version:

```powershell
.\rust\Get-RustCrate.ps1 -Crate "anyhow" -Version latest
```

Download the registry dependencies declared by a Rust project:

```powershell
.\rust\Get-RustCrate.ps1 `
  -ManifestPath ".\Cargo.toml"
```

Enable root crate features while resolving optional dependencies:

```powershell
.\rust\Get-RustCrate.ps1 `
  -Crate "reqwest" `
  -Version "0.12.24" `
  -Features @("json", "rustls-tls")
```

Use all root features:

```powershell
.\rust\Get-RustCrate.ps1 `
  -Crate "clap" `
  -Version "4.5.50" `
  -AllFeatures
```

Expand downloaded `.crate` files after download:

```powershell
.\rust\Get-RustCrate.ps1 `
  -Crate "itoa" `
  -Version "1.0.15" `
  -Expand
```

Use a private sparse registry:

```powershell
$env:CARGO_REGISTRY_TOKEN = "your-token"

.\rust\Get-RustCrate.ps1 `
  -Crate "internal-crate" `
  -Version "2.3.4" `
  -Registry "sparse+https://registry.example.com/index/" `
  -BearerToken $env:CARGO_REGISTRY_TOKEN
```

Run a five-crate random sample from the committed candidate list:

```powershell
.\rust\Test-RustCrateSample.ps1 `
  -SampleSize 5 `
  -SkipTargetSpecificDependencies
```

Fetch every optional dependency listed on the requested root crate, even when
the corresponding feature is not enabled:

```powershell
.\rust\Get-RustCrate.ps1 `
  -Crate "tokio" `
  -Version "1" `
  -IncludeOptionalDependencies
```

## Output

By default the script writes to:

```text
.\crate-cache
```

Each crate is stored under:

```text
crate-cache/
  crates/
    serde_json/
      serde_json-1.0.145.crate
      serde_json-1.0.145.index.json
```

The command prints a JSON summary with:

- `Crates`: resolved crate names, versions, contributing requirements, parent
  edges, and activated feature names.
- `Downloads`: `.crate` paths, saved index metadata paths, and download URLs.
- `Failures`: dependency resolution or download failures.
- `Output`: cache root.
- `Expanded`: whether archive expansion was requested.

## How This Emulates Cargo Retrieval

Cargo fetches registry packages from a registry. The default registry is
crates.io, and registries expose an index containing available crate versions and
dependency metadata. Cargo supports a git index protocol and a sparse protocol;
the sparse protocol fetches `config.json` and individual crate index files over
HTTP. See the Cargo Book sections on
[registries](https://doc.rust-lang.org/cargo/reference/registries.html) and the
[registry index](https://doc.rust-lang.org/cargo/reference/registry-index.html).

This script follows the sparse side of that behavior:

- It treats `https://index.crates.io/` as the default sparse index.
- It accepts `sparse+https://...` registry URLs, matching Cargo config style.
- It fetches `config.json` first.
- It computes crate index paths using Cargo's layout:
  - one-character names: `1/a`
  - two-character names: `2/ab`
  - three-character names: `3/a/abc`
  - longer names: `ab/cd/abcd`
- It reads the crate index file as newline-delimited JSON, one JSON object per
  published version.
- It uses each record's `vers`, `deps`, `features`, `yanked`, and `package`
  fields to choose versions and follow dependencies.
- It uses the registry `dl` template from `config.json` when present. If the
  template has no markers, it appends `/{crate}/{version}/download`, matching
  the registry-index rule. If no `dl` value is available, it falls back to the
  public crates.io static archive URL format.
- It downloads the `.crate` file, which is the same compressed source package
  Cargo places in its registry cache.
- It verifies the downloaded archive against the registry index `cksum` SHA-256
  value unless `-SkipChecksumVerification` is provided.
- When `-ManifestPath` is used, it reads `[dependencies]`,
  `[build-dependencies]`, and `[dev-dependencies]` declarations from a
  `Cargo.toml` and uses those as graph roots.

## Dependency Resolution Behavior

For the root `-Crate`, a plain `-Version "1.0.15"` means exact version
`=1.0.15`, because command-line retrieval usually means "get this release."
Requirement syntax such as `^1.0`, `~1.2`, `>=1.2,<2`, `1.*`, or `latest`
is treated as a resolver request.

For dependencies, the script uses the semver requirements from the registry
index, which is what Cargo uses for published registry packages. It chooses the
highest non-yanked matching version by default. Use `-IncludeYanked` to allow
yanked versions when a graph explicitly needs them.

Prerelease versions are only eligible when the requirement explicitly includes a
prerelease marker. This matches Cargo's practical behavior and prevents broad
stable ranges such as `^1.6.1` from selecting `2.0.0-alpha` releases.

For `-ManifestPath`, the script reads straightforward registry dependency
entries from `[dependencies]`, `[build-dependencies]`, and
`[dev-dependencies]`. It supports string requirements and common inline tables
with `version`, `features`, `default-features`, and `package`. It skips `path`
and `git` dependencies because they are not registry crates.

The resolver includes:

- normal dependencies by default
- build dependencies by default
- dev dependencies only with `-IncludeDevDependencies`
- target-specific dependencies by default
- optional dependencies when activated by selected features, or root-crate
  optional dependencies with `-IncludeOptionalDependencies`

Feature handling is intentionally pragmatic. The script activates the root
default feature unless `-NoDefaultFeatures` is provided, activates any root
features passed with `-Features`, and can activate every root feature with
`-AllFeatures`. Dependency feature lists are carried to the dependency node, and
feature requests are unified when the same crate/version is reached through
multiple edges. This approximates the retrieval behavior needed to collect
source archives, but it is not Cargo's full feature resolver.

## Important Differences From Cargo

This is a retrieval tool, not a Cargo replacement for builds. It does not:

- parse a workspace `Cargo.toml`
- fully parse every TOML construct or inherited workspace dependency
- create or update `Cargo.lock`
- implement Cargo resolver v1/v2/v3 exactly
- evaluate platform `cfg(...)` expressions
- run build scripts or inspect generated dependencies
- support git/path dependencies
- verify extracted file manifests against `.cargo-checksum.json`
- cache sparse index entries with `ETag` or `Last-Modified`
- use Cargo credential providers
- implement source replacement or vendoring layout

Those omissions are deliberate: they keep the tool PowerShell-only and focused
on fetching registry source artifacts. Cargo remains the source of truth for
compilation, lockfile generation, package selection across a workspace, and
exact platform-aware feature unification.

## Parameters

- `-Crate`: root crate name.
- `-Version`: exact version, semver requirement, or `latest`.
- `-ManifestPath`: optional `Cargo.toml` to use as project dependency roots.
- `-Registry`: sparse registry URL. Defaults to `https://index.crates.io/`.
- `-OutputDirectory`: cache destination. Defaults to `.\crate-cache`.
- `-Features`: root features to activate.
- `-AllFeatures`: activate all root crate features.
- `-NoDefaultFeatures`: do not activate the root crate's default feature.
- `-IncludeDevDependencies`: include dev dependency edges.
- `-IncludeOptionalDependencies`: include optional dependency edges from the
  requested root crate even when their features are not active.
- `-ExcludeBuildDependencies`: skip build dependency edges.
- `-IncludeYanked`: allow yanked versions during selection.
- `-SkipChecksumVerification`: do not compare downloads to index `cksum`.
- `-SkipTargetSpecificDependencies`: skip dependencies with a non-null target.
- `-BearerToken`: bearer token for private registries.
- `-Expand`: extract downloaded `.crate` archives with `tar`.

## Sample Test Harness

`Test-RustCrateSample.ps1` contains a curated list of roughly 100 common crates
and randomly selects five by default. It runs `Get-RustCrate.ps1` for each
selected crate, writes per-crate logs, stores `sample.json`, `results.json`, and
`summary.json`, and downloads crate archives into `crate-cache-sample`.

## Notes For Air-Gapped Use

Run this script in a connected environment, copy the `crate-cache` directory to
the disconnected environment, then use the downloaded `.crate` files for review,
internal registry seeding, or custom mirroring workflows.

If you need a layout that Cargo can consume directly with `cargo vendor` or
source replacement, run Cargo's own vendoring commands in a connected build
environment. This script intentionally preserves the raw registry artifacts and
index metadata instead of inventing a Cargo vendor directory.
