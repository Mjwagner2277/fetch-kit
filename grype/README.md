# PowerShell Grype Database Retrieval

`Get-GrypeDatabase.ps1` downloads the latest Grype vulnerability database
archive without invoking `grype`. It uses Anchore's database metadata endpoint,
downloads the referenced `.tar.zst` archive, verifies the SHA-256 checksum, and
writes metadata for provenance.

## Quick Start

```powershell
.\grype\Get-GrypeDatabase.ps1
```

By default, output is written under:

```text
.\grype-db-cache
```

The output directory contains:

```text
grype-db-cache/
  vulnerability-db_*.tar.zst
  grype-db-latest.json
  summary.json
```

## Use With Offline Grype

Move the downloaded archive into the offline environment and import it there:

```powershell
grype db import .\vulnerability-db_*.tar.zst
```

Then run Grype with database updates disabled, for example with a config file:

```yaml
db:
  auto-update: false
  validate-age: false
```

The metadata JSON is not required at runtime. Keep it with the archive as
provenance evidence for the database build timestamp, schema version, source
path, and expected checksum.

## Parameters

- `-MetadataUrl`: Grype DB metadata endpoint. Defaults to
  `https://grype.anchore.io/databases/v6/latest.json`.
- `-OutputDirectory`: destination directory. Defaults to
  `.\grype-db-cache`.
- `-OutputFileName`: optional archive filename override.
- `-Force`: overwrite an existing archive.
