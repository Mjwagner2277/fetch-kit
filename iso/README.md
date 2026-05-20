# ISO Scan

`Review-IsoContents.ps1` reviews ISO contents without mounting the image. It
parses ISO-9660 and Joliet directory records directly from the ISO bytes using
PowerShell only, then writes one combined text report with visible file hashes
and whatever RPM header data can be extracted from directly visible `.rpm`
files.

The public interface is intentionally small:

- `-Path` - ISO file to inspect.
- `-Output` - optional combined text report path. Defaults to
  `<iso-name>-iso-review.txt` in the current directory.
- `-CsvOutput` - optional combined CSV export with ISO-visible files and visible
  RPM metadata rows.

## Quick Start

From the `fetch-kit` repository root:

```powershell
.\iso\Review-IsoContents.ps1 `
  -Path .\debian-13.5.0-amd64-netinst.iso
```

This writes `.\debian-13.5.0-amd64-netinst-iso-review.txt` by default. The
report includes a summary, every ISO-visible file with a short SHA256 value, and
a visible RPM metadata section. Debian installer media normally has no directly
visible RPMs, so that section will say none were found.

Choose the report path:

```powershell
.\iso\Review-IsoContents.ps1 `
  -Path .\debian-13.5.0-amd64-netinst.iso `
  -Output .\debian-iso-review.txt
```

Optionally write CSVs for spreadsheet or diff workflows:

```powershell
.\iso\Review-IsoContents.ps1 `
  -Path .\rhel-family-dvd.iso `
  -Output .\rhel-family-iso-review.txt `
  -CsvOutput .\rhel-family-iso-review.csv
```

## Output

The default text report has three sections:

- `ISO Review Summary`
- `ISO Visible Files`
- `Visible RPM Metadata`

The file section lists one ISO-visible file per row with:

- `Path`
- `Size`
- `Modified`
- `ShortSha256`

`ShortSha256` is the first 12 hexadecimal characters of the file's SHA256 hash,
similar in spirit to a short Git SHA. It is intended for quick review and
comparison, not as a full cryptographic identifier.

Example report rows:

```text
Path	Size	Modified	ShortSha256
\.disk\base_components	5	2026-05-16T10:10:55	6403203dd5a0
\.disk\base_installable	0	2026-05-16T10:12:17	e3b0c44298fc
```

After writing the output files, the script prints a short run summary
with the ISO path, filesystem type, volume identifier, file count, and output
paths.

The optional CSV uses one wide schema. ISO file rows use `RecordType` =
`ISOFile`; RPM rows use `RecordType` = `RPMMetadata`.

## RPM Metadata Output

The default text report always looks for `.rpm` files that are directly visible
in the ISO filesystem and parses their RPM headers. The output repeats package
metadata next to each packaged file path when the RPM header exposes a file
list. `-CsvOutput` includes these rows in the same CSV as the ISO file list.

RPM output columns are:

- `RpmPath`
- `Name`
- `Version`
- `Release`
- `Epoch`
- `Architecture`
- `License`
- `Summary`
- `SourceRpm`
- `PayloadFormat`
- `PayloadCompressor`
- `PackagedFilePath`
- `ParseStatus`
- `ParseError`

This reads RPM metadata only. It does not decompress or unpack the RPM payload.

## Error Output

Failures are reported as a structured PowerShell object instead of a raw stack
trace. The object includes:

- `Status`
- `Stage`
- `IsoPath`
- `Error`
- `Explanation`
- `NextStep`

For example, if the ISO-visible directory record claims more bytes than the
script can read, the error explains that the media may be truncated, sparse,
corrupt, or intentionally malformed, and recommends reacquiring the ISO and
checking the whole-file hash against the source.

## Limitations

- The script hashes ISO-visible files, not every file inside nested payloads.
  For example, `install.img`, `initrd.gz`, `.deb`, `.rpm`, SquashFS images, and
  archives are hashed as container files.
- RPM metadata parsing only applies to `.rpm` files directly visible in the ISO
  filesystem. RPMs inside `install.img`, SquashFS images, or other nested
  payloads are not reached.
- RPM output comes from header metadata. The script does not unpack RPM payloads
  or verify payload file contents.
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
