# Fetch Kit

PowerShell-first retrieval scripts for constrained or air-gapped environments
where the usual toolchain is unavailable, restricted, or intentionally avoided.

The goal is to fetch source, module metadata, and OCI-style artifacts with
portable scripting and standard HTTP APIs instead of relying on language or
container CLIs.

## Contents

- `go/` - Go module and dependency retrieval without invoking the Go toolchain.
- `podman/` - OCI image retrieval without invoking Podman, Docker, Skopeo, or ORAS.
- `rust/` - Cargo crate and dependency retrieval without invoking Cargo.

## Go

See [go/README.md](go/README.md) for examples and limitations.

## Rust

See [rust/README.md](rust/README.md) for examples and limitations.

## Podman Pull Replacement

See [podman/README.md](podman/README.md) for examples and limitations.
