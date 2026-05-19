# ISO Scan

`Review-IsoContents.ps1` reviews ISO contents without mounting the image. It
parses ISO-9660 and Joliet directory records directly from the ISO bytes using
PowerShell only.

This is intended for constrained systems where mounting is unavailable or
undesirable, and for cyber intake workflows where the first useful artifact is a
file manifest with hashes.

## Quick Start

From the `fetch-kit` repository root:

```powershell
.\iso\Review-IsoContents.ps1 -Path .\debian-13.5.0-amd64-netinst.iso
```

Generate a Linux installer summary:

```powershell
.\iso\Review-IsoContents.ps1 `
  -Path .\debian-13.5.0-amd64-netinst.iso `
  -LinuxSummary `
  -MaxEntries 25
```

Generate one checksum row per ISO-visible file:

```powershell
.\iso\Review-IsoContents.ps1 `
  -Path .\debian-13.5.0-amd64-netinst.iso `
  -FileChecksums
```

Export the full file manifest to CSV:

```powershell
.\iso\Review-IsoContents.ps1 `
  -Path .\debian-13.5.0-amd64-netinst.iso `
  -FileChecksums `
  -ChecksumCsv .\debian-13.5.0-amd64-netinst-file-manifest.csv
```

Choose a hash algorithm:

```powershell
.\iso\Review-IsoContents.ps1 `
  -Path .\debian-13.5.0-amd64-netinst.iso `
  -FileChecksums `
  -ChecksumAlgorithm SHA512
```

Supported algorithms are `MD5`, `SHA1`, `SHA256`, `SHA384`, and `SHA512`.
`SHA256` is the default.

## Output

Basic listing mode prints an ISO summary followed by entries with:

- `Type`
- `Size`
- `Modified`
- `Path`

Checksum mode prints one row per file with:

- `Path`
- `Size`
- `Modified`
- `Algorithm`
- `Checksum`

PowerShell table output may visually truncate long checksums. The CSV output
contains the full value. For console review, use:

```powershell
.\iso\Review-IsoContents.ps1 `
  -Path .\debian-13.5.0-amd64-netinst.iso `
  -FileChecksums |
  Format-List
```

## Linux Installer Summary

`-LinuxSummary` looks for common Linux installer signals, including:

- Debian-family metadata such as `\.disk\info`, `\dists`, `\pool`, package
  files, `\install.*\vmlinuz`, and `\install.*\initrd.gz`.
- RHEL-family metadata such as `\.treeinfo`, `\images\install.img`,
  `\images\pxeboot`, `\isolinux\vmlinuz`, and `\isolinux\initrd.img`.
- BIOS and UEFI boot files such as `\isolinux\isolinux.bin`,
  `\EFI\BOOT\BOOTX64.EFI`, and GRUB configuration files.

The summary is a triage aid, not a distribution verifier.

## Extraction

Extract one ISO-visible file without mounting the ISO:

```powershell
.\iso\Review-IsoContents.ps1 `
  -Path .\debian-13.5.0-amd64-netinst.iso `
  -ExtractPath '\.disk\info' `
  -Destination .\iso-extract
```

## Cyber Triage Fallback

If the script cannot parse an ISO-9660 or Joliet root directory, it cannot list
files. In that case it falls back to cyber-relevant triage:

- ISO file SHA256, SHA1, and MD5.
- Volume descriptor summary when descriptors are present.
- File-signature hits for common embedded binaries and archives.
- Interesting printable strings.
- Sample entropy.
- Recommended next analysis steps.

Run fallback triage explicitly with:

```powershell
.\iso\Review-IsoContents.ps1 -Path .\image.iso -IncludeTriage
```

## Validation

The scanner was validated against Debian 13.5.0 amd64 netinst from Debian's
official download site. The script identified the image as a Debian-family Linux
installer, found kernel/initrd and BIOS/UEFI boot files, and generated a full
per-file SHA256 manifest for 1,011 ISO-visible files.

It was also smoke-tested against a RHEL-family public Rocky Linux boot ISO to
verify Anaconda-style installer markers such as `\images\install.img`,
`\isolinux\vmlinuz`, `\isolinux\initrd.img`, and UEFI boot files.

## Limitations

- The script hashes ISO-visible files, not every file inside nested payloads.
  For example, `install.img`, `initrd.gz`, `.deb`, `.rpm`, SquashFS images, and
  archives are hashed as container files.
- It does not unpack package files, initramfs images, SquashFS images, or
  installer stage images.
- It parses ISO-9660 and Joliet. It does not implement UDF, HFS, APFS, or other
  filesystem parsers.
- It does not fully implement Rock Ridge metadata. When both ISO-9660 and Joliet
  are present, the script prefers Joliet names.
- It does not verify distribution signatures or compare against upstream
  checksum/signature files. It only produces local hashes and manifest data.
- It does not emulate a forensic suite. Suspicious string and signature scans
  are triage helpers, not malware detection.
- Hashing a full installer ISO can take time because every visible file is read
  from the ISO byte stream.
- The parser expects ordinary single-extent directory records. Unusual or
  intentionally malformed ISO structures may not be listed correctly.
