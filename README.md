# Fetch Kit

PowerShell-first retrieval scripts for constrained or air-gapped environments
where the usual toolchain is unavailable, restricted, or intentionally avoided.

The goal is to fetch source, module metadata, and OCI-style artifacts with
portable scripting and standard HTTP APIs instead of relying on language or
container CLIs.

## Contents

- `go/` - Go module and dependency retrieval without invoking the Go toolchain.
- `iso/` - ISO-9660/Joliet short-hash file manifests without mounting the ISO.
- `npm/` - npm package and dependency retrieval without invoking npm or Node.js.
- `podman/` - OCI image retrieval without invoking Podman, Docker, Skopeo, or ORAS.
- `rust/` - Cargo crate and dependency retrieval without invoking Cargo.

## Go

See [go/README.md](go/README.md) for examples and limitations.

## Rust

See [rust/README.md](rust/README.md) for examples and limitations.

## npm

See [npm/README.md](npm/README.md) for examples and limitations.
The npm directory also includes `Test-NpmPackageSample.ps1`, which randomly
tests five packages from a checked-in popular-package sample list.

## ISO Scan

See [iso/README.md](iso/README.md) for examples and limitations.

`iso/Review-IsoContents.ps1` inspects ISO-9660 and Joliet filesystems directly
from the ISO bytes. It does not mount the image and does not require 7-Zip,
`isoinfo`, `xorriso`, Linux loop devices, Windows image mounting cmdlets, or any
other external tool.

Common use:

```powershell
.\iso\Review-IsoContents.ps1 `
  -Path .\debian-13.5.0-amd64-netinst.iso `
  -CsvOutput .\debian-13.5.0-amd64-netinst-file-manifest.csv
```

The manifest lists each ISO-visible file with its path, size, modified time, and
12-character `ShortSha256` value. This is useful for cyber review, air-gap
intake, provenance notes, and quick comparison of installer media across
sources.

## Podman Pull Replacement

See [podman/README.md](podman/README.md) for examples and limitations.
