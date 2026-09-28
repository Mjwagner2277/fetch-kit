# Fetch Kit

Portable retrieval scripts for constrained or air-gapped environments
where the usual toolchain is unavailable, restricted, or intentionally avoided.

The goal is to fetch source, module metadata, and OCI-style artifacts with
portable scripting and standard HTTP APIs instead of relying on language or
container CLIs.

## Contents

- `go/` - Python Go module and dependency retrieval without invoking the Go
  toolchain.
- `iso/` - ISO-9660/Joliet short-hash file manifests and visible RPM metadata
  without mounting the ISO.
- `npm/` - HTTP-only JavaScript downloader and a Python standard-library Artifactory
  publisher for transferring npm packages into an airgapped environment.
- `grype/` - Grype vulnerability database retrieval without invoking Grype.
- `podman/` - Python OCI image list retrieval, air-gap transfer bundles, and a
  Bash Artifactory Docker repository uploader without invoking Podman, Docker,
  Skopeo, ORAS, or the JFrog CLI.
- `rpm/` - RHEL-compatible EL9 RPM dependency retrieval without invoking DNF,
  RPM, or Red Hat subscription workflows.
- `rust/` - Cargo crate and dependency retrieval without invoking Cargo.

## Go

See [go/README.md](go/README.md) for examples and limitations.
The Go area also includes an Artifactory REST uploader for publishing exported
static Go proxy trees.

## Rust

See [rust/README.md](rust/README.md) for examples and limitations.

## npm

See [npm/README.md](npm/README.md) for examples and limitations.
Use `download-npm-http-bundle.js` with a package list and a target Node version
to retrieve the full selected registry dependency graph over HTTP, sanitize
lifecycle scripts, and create a transfer archive. The target Node version may
be newer than the connected machine's runtime. No npm CLI is required.
The Python publisher needs only Python's standard library on the airgapped side
and accepts either the bundle or a directory of npm tarballs. The earlier npm
CLI downloader and Bash publisher remain available; the original HTTP-only
PowerShell implementation is under `npm/soon-to-be-deprecated/`.

## RPM

See [rpm/README.md](rpm/README.md) for examples and limitations.
`rpm/Get-Rhel9RpmClosure.ps1` downloads RHEL 9-compatible RPMs and their
dependency closure from public rpm-md repositories, then writes a local DNF repo
that can be transferred to an airgapped environment.

## Grype Database

See [grype/README.md](grype/README.md) for examples. `Get-GrypeDatabase.ps1`
downloads the latest Grype vulnerability database archive and verifies its
SHA-256 checksum without calling the Grype CLI.

## ISO Scan

See [iso/README.md](iso/README.md) for examples and limitations.

`iso/Review-IsoContents.ps1` inspects ISO-9660 and Joliet filesystems directly
from the ISO bytes. It does not mount the image and does not require 7-Zip,
`isoinfo`, `xorriso`, Linux loop devices, Windows image mounting cmdlets, or any
other external tool.

Common use:

```powershell
.\iso\Review-IsoContents.ps1 `
  -Path .\debian-13.5.0-amd64-netinst.iso
```

By default, the script writes `<iso-name>-iso-review.txt` in the current
directory. The report lists each ISO-visible file with its path, size, modified
time, and 12-character `ShortSha256` value, then includes visible RPM metadata
and packaged file paths when directly visible `.rpm` files are present. This is
useful for cyber review, air-gap intake, provenance notes, and quick comparison
of installer media across sources.

CSV exports are optional for spreadsheet or diff workflows:

```powershell
.\iso\Review-IsoContents.ps1 `
  -Path .\rhel-family-dvd.iso `
  -Output .\rhel-family-iso-review.txt `
  -CsvOutput .\rhel-family-iso-review.csv
```

## OCI Image Transfer

See [podman/README.md](podman/README.md) for the Python download, transfer, and
Artifactory upload workflow.
