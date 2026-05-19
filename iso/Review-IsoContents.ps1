<# 
.SYNOPSIS
Reviews the contents of an ISO file without mounting it.

.DESCRIPTION
Parses ISO-9660 and Joliet directory records directly from the ISO bytes using
PowerShell only, then writes a compact per-file SHA256 manifest using 12-character
short hashes.

.EXAMPLE
.\Review-IsoContents.ps1 -Path .\sample.iso -CsvOutput .\sample-iso-manifest.csv

.EXAMPLE
.\Review-IsoContents.ps1 -Path .\sample.iso -TextOutput .\sample-iso-manifest.txt
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$Path,

    [string]$TextOutput,

    [string]$CsvOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ISO-9660 uses fixed 2048-byte sectors. File records point to sectors, so
# reading a file later means seeking to Extent * 2048 and streaming Size bytes.
$SectorSize = 2048

function Read-Bytes {
    param(
        [Parameter(Mandatory)][System.IO.FileStream]$Stream,
        [Parameter(Mandatory)][Int64]$Offset,
        [Parameter(Mandatory)][int]$Count
    )

    # All reads are explicit range reads against the ISO stream. This keeps the
    # script mount-free and avoids extracting the full image.
    $buffer = [byte[]]::new($Count)
    $null = $Stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
    $read = $Stream.Read($buffer, 0, $Count)
    if ($read -lt $Count) {
        if ($read -le 0) { return ,([byte[]]::new(0)) }
        $short = [byte[]]::new($read)
        [Array]::Copy($buffer, $short, $read)
        return ,$short
    }
    return ,$buffer
}

function Convert-UInt16LE {
    param([byte[]]$Bytes, [int]$Offset)
    return [BitConverter]::ToUInt16($Bytes, $Offset)
}

function Convert-UInt32LE {
    param([byte[]]$Bytes, [int]$Offset)
    return [BitConverter]::ToUInt32($Bytes, $Offset)
}

function Convert-IsoDate {
    param([byte[]]$Bytes, [int]$Offset)

    try {
        $year = 1900 + $Bytes[$Offset]
        $month = $Bytes[$Offset + 1]
        $day = $Bytes[$Offset + 2]
        $hour = $Bytes[$Offset + 3]
        $minute = $Bytes[$Offset + 4]
        $second = $Bytes[$Offset + 5]
        if ($month -lt 1 -or $month -gt 12 -or $day -lt 1 -or $day -gt 31) {
            return $null
        }
        return [datetime]::new($year, $month, $day, $hour, $minute, $second, [DateTimeKind]::Unspecified)
    }
    catch {
        return $null
    }
}

function Convert-IsoName {
    param(
        [byte[]]$Bytes,
        [int]$Offset,
        [int]$Length,
        [bool]$Joliet
    )

    # Directory records use raw 0 and 1 names for "." and "..".
    if ($Length -eq 1 -and $Bytes[$Offset] -eq 0) { return '.' }
    if ($Length -eq 1 -and $Bytes[$Offset] -eq 1) { return '..' }

    $nameBytes = [byte[]]::new($Length)
    [Array]::Copy($Bytes, $Offset, $nameBytes, 0, $Length)

    if ($Joliet) {
        $name = [Text.Encoding]::BigEndianUnicode.GetString($nameBytes)
    }
    else {
        $name = [Text.Encoding]::ASCII.GetString($nameBytes)
    }

    $name = $name.TrimEnd("`0")
    $name = $name -replace ';1$', ''
    return $name
}

function Convert-DescriptorText {
    param(
        [byte[]]$Bytes,
        [int]$Offset,
        [int]$Length,
        [bool]$Joliet
    )

    $raw = [byte[]]::new($Length)
    [Array]::Copy($Bytes, $Offset, $raw, 0, $Length)

    if ($Joliet) {
        return [Text.Encoding]::BigEndianUnicode.GetString($raw).Trim([char]0, ' ')
    }

    return [Text.Encoding]::ASCII.GetString($raw).Trim([char]0, ' ')
}

function Get-DescriptorText {
    param(
        [byte[]]$Bytes,
        [int]$Offset,
        [int]$Length,
        [bool]$Joliet
    )

    $text = Convert-DescriptorText -Bytes $Bytes -Offset $Offset -Length $Length -Joliet:$Joliet
    if ([string]::IsNullOrWhiteSpace($text)) {
        $text = Convert-DescriptorText -Bytes $Bytes -Offset $Offset -Length $Length -Joliet:$false
    }
    return $text
}

function Read-DirectoryRecord {
    param(
        [byte[]]$Sector,
        [int]$Offset,
        [bool]$Joliet
    )

    # A directory record describes one visible file or directory: name, starting
    # sector, byte size, flags, and timestamp.
    $length = $Sector[$Offset]
    if ($length -eq 0) { return $null }
    if (($Offset + $length) -gt $Sector.Length -or $length -lt 34) { return $null }

    $nameLength = $Sector[$Offset + 32]
    if (($Offset + 33 + $nameLength) -gt $Sector.Length) { return $null }

    $extent = Convert-UInt32LE -Bytes $Sector -Offset ($Offset + 2)
    $size = Convert-UInt32LE -Bytes $Sector -Offset ($Offset + 10)
    $flags = $Sector[$Offset + 25]
    $name = Convert-IsoName -Bytes $Sector -Offset ($Offset + 33) -Length $nameLength -Joliet $Joliet

    [pscustomobject]@{
        Length      = $length
        Name        = $name
        Extent      = [Int64]$extent
        Size        = [Int64]$size
        IsDirectory = (($flags -band 0x02) -ne 0)
        Timestamp   = Convert-IsoDate -Bytes $Sector -Offset ($Offset + 18)
    }
}

function Read-VolumeDescriptors {
    param([System.IO.FileStream]$Stream)

    # Volume descriptors begin at sector 16. Prefer a Joliet supplementary
    # descriptor when one exists because it preserves long Unicode names better.
    $descriptors = @()
    for ($sector = 16; $sector -lt 512; $sector++) {
        $bytes = Read-Bytes -Stream $Stream -Offset ([Int64]$sector * $SectorSize) -Count $SectorSize
        if ($bytes.Length -lt 7) { break }

        $signature = [Text.Encoding]::ASCII.GetString($bytes, 1, 5)
        if ($signature -ne 'CD001') { break }

        $type = $bytes[0]
        $escape = [Text.Encoding]::ASCII.GetString($bytes, 88, 32).Trim([char]0, ' ')
        $isJoliet = $type -eq 2 -and ($escape.StartsWith('%/@') -or $escape.StartsWith('%/C') -or $escape.StartsWith('%/E'))

        $root = Read-DirectoryRecord -Sector $bytes -Offset 156 -Joliet:$isJoliet
        $descriptors += [pscustomobject]@{
            Sector             = $sector
            Type               = $type
            TypeName           = switch ($type) {
                0 { 'Boot Record' }
                1 { 'Primary Volume' }
                2 { 'Supplementary Volume' }
                3 { 'Volume Partition' }
                255 { 'Terminator' }
                default { "Unknown ($type)" }
            }
            IsJoliet           = $isJoliet
            SystemIdentifier   = Get-DescriptorText -Bytes $bytes -Offset 8 -Length 32 -Joliet:$isJoliet
            VolumeIdentifier   = Get-DescriptorText -Bytes $bytes -Offset 40 -Length 32 -Joliet:$isJoliet
            VolumeSpaceSectors = Convert-UInt32LE -Bytes $bytes -Offset 80
            RootRecord         = $root
        }

        if ($type -eq 255) { break }
    }

    return $descriptors
}

function Get-IsoEntries {
    param(
        [System.IO.FileStream]$Stream,
        [pscustomobject]$RootRecord,
        [bool]$Joliet
    )

    # Walk directories breadth-first. Each directory is itself a byte range in
    # the ISO containing more directory records.
    $queue = [System.Collections.Queue]::new()
    $queue.Enqueue([pscustomobject]@{ Path = '\'; Record = $RootRecord })
    $entries = [System.Collections.Generic.List[object]]::new()

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $dirBytes = Read-Bytes -Stream $Stream -Offset ([Int64]$current.Record.Extent * $SectorSize) -Count ([int]$current.Record.Size)
        $offset = 0

        while ($offset -lt $dirBytes.Length) {
            $recordLength = $dirBytes[$offset]
            if ($recordLength -eq 0) {
                $offset = (([math]::Floor($offset / $SectorSize) + 1) * $SectorSize)
                continue
            }

            $record = Read-DirectoryRecord -Sector $dirBytes -Offset $offset -Joliet:$Joliet
            if ($null -eq $record) { break }

            if ($record.Name -ne '.' -and $record.Name -ne '..') {
                $childPath = if ($current.Path -eq '\') {
                    '\' + $record.Name
                }
                else {
                    $current.Path.TrimEnd('\') + '\' + $record.Name
                }

                $entry = [pscustomobject]@{
                    Path        = $childPath
                    Name        = $record.Name
                    Size        = [Int64]$record.Size
                    Extent      = [Int64]$record.Extent
                    Type        = if ($record.IsDirectory) { 'Directory' } else { 'File' }
                    Modified    = $record.Timestamp
                    IsDirectory = $record.IsDirectory
                }
                $entries.Add($entry)

                if ($record.IsDirectory) {
                    $queue.Enqueue([pscustomobject]@{ Path = $childPath; Record = $record })
                }
            }

            $offset += $recordLength
        }
    }

    return $entries
}

function New-ChecksumAlgorithm {
    param(
        [ValidateSet('MD5', 'SHA1', 'SHA256', 'SHA384', 'SHA512')]
        [string]$Algorithm
    )

    switch ($Algorithm) {
        'MD5' { return [System.Security.Cryptography.MD5]::Create() }
        'SHA1' { return [System.Security.Cryptography.SHA1]::Create() }
        'SHA256' { return [System.Security.Cryptography.SHA256]::Create() }
        'SHA384' { return [System.Security.Cryptography.SHA384]::Create() }
        'SHA512' { return [System.Security.Cryptography.SHA512]::Create() }
    }
}

function Convert-BytesToHex {
    param([byte[]]$Bytes)

    return -join ($Bytes | ForEach-Object { $_.ToString('x2') })
}

function Get-IsoEntryChecksum {
    param(
        [System.IO.FileStream]$Stream,
        [pscustomobject]$Entry,
        [ValidateSet('MD5', 'SHA1', 'SHA256', 'SHA384', 'SHA512')]
        [string]$Algorithm
    )

    # Stream the file's byte range into the hash algorithm. This hashes the
    # visible ISO file without creating an extracted copy on disk.
    $hash = New-ChecksumAlgorithm -Algorithm $Algorithm
    try {
        $remaining = [Int64]$Entry.Size
        $position = [Int64]$Entry.Extent * $SectorSize
        $bufferSize = [Int64]1MB

        while ($remaining -gt 0) {
            $chunkSize = [int][Math]::Min([Int64]$bufferSize, [Int64]$remaining)
            $chunk = Read-Bytes -Stream $Stream -Offset $position -Count $chunkSize
            if ($chunk.Length -eq 0) {
                throw "Unexpected end of ISO while hashing $($Entry.Path). Expected $($Entry.Size) bytes."
            }

            $null = $hash.TransformBlock($chunk, 0, $chunk.Length, $null, 0)
            $position += $chunk.Length
            $remaining -= $chunk.Length
        }

        $empty = [byte[]]::new(0)
        $null = $hash.TransformFinalBlock($empty, 0, 0)
        return Convert-BytesToHex -Bytes $hash.Hash
    }
    finally {
        $hash.Dispose()
    }
}

function Get-IsoFileManifest {
    param(
        [System.IO.FileStream]$Stream,
        [object[]]$Entries
    )

    # Manifest output is intentionally minimal: the visible path, file size,
    # modified time, and a short SHA256 value for quick comparison.
    $files = @($Entries | Where-Object { -not $_.IsDirectory } | Sort-Object Path)

    $index = 0
    foreach ($entry in $files) {
        $index++
        Write-Progress -Activity 'Hashing ISO files with SHA256' -Status $entry.Path -PercentComplete (($index / [Math]::Max($files.Count, 1)) * 100)
        $sha256 = Get-IsoEntryChecksum -Stream $Stream -Entry $entry -Algorithm SHA256

        [pscustomobject]@{
            Path        = $entry.Path
            Size        = $entry.Size
            Modified    = $entry.Modified
            ShortSha256 = $sha256.Substring(0, 12)
        }
    }

    Write-Progress -Activity 'Hashing ISO files with SHA256' -Completed
}

function Resolve-OutputPath {
    param([string]$OutputPath)

    # Accept relative output paths and create parent directories as needed.
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $parent = Split-Path -Path $resolved -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    return $resolved
}

function Export-TextManifest {
    param(
        [object[]]$Manifest,
        [string]$OutputPath
    )

    # Text output is tab-delimited so it stays simple to parse in PowerShell or
    # spreadsheet tools while preserving paths with spaces.
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Path`tSize`tModified`tShortSha256")
    foreach ($row in $Manifest) {
        $modified = if ($null -ne $row.Modified) { $row.Modified.ToString('s') } else { '' }
        $lines.Add("$($row.Path)`t$($row.Size)`t$modified`t$($row.ShortSha256)")
    }
    [IO.File]::WriteAllLines((Resolve-OutputPath -OutputPath $OutputPath), $lines, [Text.Encoding]::UTF8)
}

function Get-ErrorGuidance {
    param([string]$Message)

    if ($Message -like '*Specify -TextOutput or -CsvOutput*') {
        return [pscustomobject]@{
            Explanation = 'The script only writes manifests to files, and no output path was provided.'
            NextStep    = 'Run again with -CsvOutput, -TextOutput, or both.'
        }
    }

    if ($Message -like '*No readable ISO-9660/Joliet root directory*') {
        return [pscustomobject]@{
            Explanation = 'The image did not expose an ISO-9660 or Joliet root directory to this parser. It may be UDF-only, damaged, encrypted, or not an ISO image.'
            NextStep    = 'Hash and preserve the ISO, verify it against vendor checksums/signatures, then inspect it with a parser that supports the image filesystem.'
        }
    }

    if ($Message -like '*Unexpected end of ISO while hashing*') {
        return [pscustomobject]@{
            Explanation = 'A directory record claimed more bytes than could be read from the ISO. The image may be truncated, sparse, corrupt, or intentionally malformed.'
            NextStep    = 'Re-download or reacquire the ISO, compare the whole-file hash against the source, and only trust manifests generated from complete media.'
        }
    }

    if ($Message -like '*Access*denied*' -or $Message -like '*permission*') {
        return [pscustomobject]@{
            Explanation = 'PowerShell could not read the ISO or write one of the requested output files because of filesystem permissions.'
            NextStep    = 'Check the ISO path, output directory permissions, and whether another process is locking the destination file.'
        }
    }

    return [pscustomobject]@{
        Explanation = 'An unexpected error occurred while parsing or writing the ISO manifest.'
        NextStep    = 'Check that the input is a complete ISO-9660/Joliet image and that the output path is writable. Re-run with a fresh copy if the media may be corrupt.'
    }
}

$resolvedPath = $null
$stream = $null
$stage = 'Start'

try {
    # Main execution flow:
    # 1. Require at least one output file target.
    # 2. Read ISO volume descriptors and choose Joliet when available.
    # 3. Traverse the selected root directory into file entries.
    # 4. Stream-hash each visible file and shorten SHA256 to 12 characters.
    # 5. Write text and/or CSV output, then print a small run summary.
    $stage = 'Validate output arguments'
    if ([string]::IsNullOrWhiteSpace($TextOutput) -and [string]::IsNullOrWhiteSpace($CsvOutput)) {
        throw 'Specify -TextOutput or -CsvOutput.'
    }

    $stage = 'Open ISO file'
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $stream = [System.IO.File]::Open($resolvedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)

    $stage = 'Read ISO volume descriptors'
    $descriptors = @(Read-VolumeDescriptors -Stream $stream)
    $descriptor = $descriptors | Where-Object { $_.IsJoliet -and $_.RootRecord } | Select-Object -First 1
    if ($null -eq $descriptor) {
        $descriptor = $descriptors | Where-Object { $_.Type -eq 1 -and $_.RootRecord } | Select-Object -First 1
    }

    if ($null -eq $descriptor) {
        # At this point the script cannot see individual files. Preserve the ISO
        # as evidence and move to a parser that supports the image's filesystem.
        throw 'No readable ISO-9660/Joliet root directory was found. File contents cannot be listed with this PowerShell-only parser. Next cyber-relevant step: preserve and hash the ISO as an artifact, verify against vendor checksums/signatures, then inspect with a forensic ISO/UDF parser or isolated sandbox.'
    }

    $stage = 'Traverse ISO directory tree'
    $entries = @(Get-IsoEntries -Stream $stream -RootRecord $descriptor.RootRecord -Joliet:$descriptor.IsJoliet)

    $stage = 'Hash ISO-visible files'
    $manifest = @(Get-IsoFileManifest -Stream $stream -Entries $entries)

    if (-not [string]::IsNullOrWhiteSpace($CsvOutput)) {
        $stage = 'Write CSV manifest'
        $manifest | Export-Csv -LiteralPath (Resolve-OutputPath -OutputPath $CsvOutput) -NoTypeInformation
    }

    if (-not [string]::IsNullOrWhiteSpace($TextOutput)) {
        $stage = 'Write text manifest'
        Export-TextManifest -Manifest $manifest -OutputPath $TextOutput
    }

    [pscustomobject]@{
        IsoPath           = $resolvedPath
        Filesystem        = if ($descriptor.IsJoliet) { 'Joliet / ISO-9660' } else { 'ISO-9660' }
        VolumeIdentifier = $descriptor.VolumeIdentifier
        FileCount         = $manifest.Count
        TextOutput        = if ([string]::IsNullOrWhiteSpace($TextOutput)) { $null } else { Resolve-OutputPath -OutputPath $TextOutput }
        CsvOutput         = if ([string]::IsNullOrWhiteSpace($CsvOutput)) { $null } else { Resolve-OutputPath -OutputPath $CsvOutput }
    }
}
catch {
    $guidance = Get-ErrorGuidance -Message $_.Exception.Message
    [pscustomobject]@{
        Status      = 'Failed'
        Stage       = $stage
        IsoPath     = if ($resolvedPath) { $resolvedPath } else { $Path }
        Error       = $_.Exception.Message
        Explanation = $guidance.Explanation
        NextStep    = $guidance.NextStep
    }
}
finally {
    if ($null -ne $stream) {
        $stream.Dispose()
    }
}
