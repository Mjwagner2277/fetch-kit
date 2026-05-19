# ISO Scan

`Review-IsoContents.ps1` reviews ISO contents without mounting the image. It
parses ISO-9660 and Joliet directory records directly from the ISO bytes using
PowerShell only, then writes a compact per-file manifest.

The public interface is intentionally small:

- `-Path` - ISO file to inspect.
- `-TextOutput` - write a tab-delimited text manifest.
- `-CsvOutput` - write a CSV manifest.

Specify `-TextOutput`, `-CsvOutput`, or both.

## Quick Start

From the `fetch-kit` repository root:

```powershell
.\iso\Review-IsoContents.ps1 `
  -Path .\debian-13.5.0-amd64-netinst.iso `
  -CsvOutput .\debian-13.5.0-amd64-netinst-file-manifest.csv
```

Write both text and CSV:

```powershell
.\iso\Review-IsoContents.ps1 `
  -Path .\debian-13.5.0-amd64-netinst.iso `
  -TextOutput .\debian-13.5.0-amd64-netinst-file-manifest.txt `
  -CsvOutput .\debian-13.5.0-amd64-netinst-file-manifest.csv
```

## Output

The manifest lists one ISO-visible file per row with:

- `Path`
- `Size`
- `Modified`
- `ShortSha256`

`ShortSha256` is the first 12 hexadecimal characters of the file's SHA256 hash,
similar in spirit to a short Git SHA. It is intended for quick review and
comparison, not as a full cryptographic identifier.

Example CSV rows:

```csv
"Path","Size","Modified","ShortSha256"
"\.disk\base_components","5","5/16/2026 10:10:55 AM","6403203dd5a0"
"\.disk\base_installable","0","5/16/2026 10:12:17 AM","e3b0c44298fc"
```

After writing the requested output files, the script prints a short run summary
with the ISO path, filesystem type, volume identifier, file count, and output
paths.

## Validation

The scanner was validated against Debian 13.5.0 amd64 netinst from Debian's
official download site. The script generated a compact per-file manifest for
1,011 ISO-visible files.

It was also smoke-tested against a RHEL-family public Rocky Linux boot ISO and a
synthetic ISO record with a file size above `Int32.MaxValue`.

## Limitations

- The script hashes ISO-visible files, not every file inside nested payloads.
  For example, `install.img`, `initrd.gz`, `.deb`, `.rpm`, SquashFS images, and
  archives are hashed as container files.
- `ShortSha256` is a shortened review value. Use full SHA256 if you need strong
  identity or collision-resistant matching.
- It does not unpack package files, initramfs images, SquashFS images, or
  installer stage images.
- It parses ISO-9660 and Joliet. It does not implement UDF, HFS, APFS, or other
  filesystem parsers.
- It does not fully implement Rock Ridge metadata. When both ISO-9660 and Joliet
  are present, the script prefers Joliet names.
- It does not verify distribution signatures or compare against upstream
  checksum/signature files. It only produces local short-hash manifest data.
- Hashing a full installer ISO can take time because every visible file is read
  from the ISO byte stream.
- The parser expects ordinary single-extent directory records. Unusual or
  intentionally malformed ISO structures may not be listed correctly.
