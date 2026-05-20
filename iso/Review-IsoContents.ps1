<# 
.SYNOPSIS
Reviews the contents of an ISO file without mounting it.

.DESCRIPTION
Parses ISO-9660 and Joliet directory records directly from the ISO bytes using
PowerShell only, then writes a combined text report with ISO-visible files,
12-character short SHA256 hashes, and any RPM header metadata that can be read
from directly visible .rpm files.

.EXAMPLE
.\Review-IsoContents.ps1 -Path .\sample.iso

.EXAMPLE
.\Review-IsoContents.ps1 -Path .\sample.iso -Output .\sample-iso-review.txt -CsvOutput .\sample-iso-review.csv
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$Path,

    [string]$Output,

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

function Convert-UInt16BE {
    param([byte[]]$Bytes, [int]$Offset)
    return [uint16](([uint16]$Bytes[$Offset] * 256) + [uint16]$Bytes[$Offset + 1])
}

function Convert-UInt32BE {
    param([byte[]]$Bytes, [int]$Offset)
    return [uint32](([uint32]$Bytes[$Offset] * 16777216) + ([uint32]$Bytes[$Offset + 1] * 65536) + ([uint32]$Bytes[$Offset + 2] * 256) + [uint32]$Bytes[$Offset + 3])
}

function Align-Offset {
    param(
        [Int64]$Offset,
        [int]$Alignment
    )

    $remainder = $Offset % $Alignment
    if ($remainder -eq 0) { return $Offset }
    return $Offset + ($Alignment - $remainder)
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

function Export-ReviewReport {
    param(
        [pscustomobject]$Summary,
        [object[]]$FileManifest,
        [object[]]$RpmManifest,
        [string]$OutputPath
    )

    # The default report is a single text file: a short summary, then all
    # ISO-visible files, then visible RPM metadata and packaged file paths.
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('ISO Review Summary')
    $lines.Add('==================')
    $lines.Add("IsoPath`t$($Summary.IsoPath)")
    $lines.Add("Filesystem`t$($Summary.Filesystem)")
    $lines.Add("VolumeIdentifier`t$($Summary.VolumeIdentifier)")
    $lines.Add("FileCount`t$($Summary.FileCount)")
    $lines.Add("RpmRows`t$($RpmManifest.Count)")
    $lines.Add('')
    $lines.Add('ISO Visible Files')
    $lines.Add('=================')
    $lines.Add("Path`tSize`tModified`tShortSha256")
    foreach ($row in $FileManifest) {
        $modified = if ($null -ne $row.Modified) { $row.Modified.ToString('s') } else { '' }
        $lines.Add("$($row.Path)`t$($row.Size)`t$modified`t$($row.ShortSha256)")
    }
    $lines.Add('')
    $lines.Add('Visible RPM Metadata')
    $lines.Add('====================')
    if ($RpmManifest.Count -eq 0) {
        $lines.Add('No directly visible RPM files were found in the ISO filesystem.')
    }
    else {
        $columns = @('RpmPath', 'Name', 'Version', 'Release', 'Epoch', 'Architecture', 'License', 'Summary', 'SourceRpm', 'PayloadFormat', 'PayloadCompressor', 'PackagedFilePath', 'ParseStatus', 'ParseError')
        $lines.Add(($columns -join "`t"))
        foreach ($row in $RpmManifest) {
            $values = foreach ($column in $columns) {
                (($row.$column -as [string]) -replace "`t", ' ' -replace "`r?`n", ' ')
            }
            $lines.Add(($values -join "`t"))
        }
    }
    [IO.File]::WriteAllLines((Resolve-OutputPath -OutputPath $OutputPath), $lines, [Text.Encoding]::UTF8)
}

function Export-ReviewCsvReport {
    param(
        [object[]]$FileManifest,
        [object[]]$RpmManifest,
        [string]$OutputPath
    )

    # The optional CSV uses one wide schema so callers do not need separate
    # outputs for ISO files and RPM header data.
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $FileManifest) {
        $rows.Add([pscustomobject]@{
            RecordType        = 'ISOFile'
            Path              = $file.Path
            Size              = $file.Size
            Modified          = $file.Modified
            ShortSha256       = $file.ShortSha256
            RpmPath           = ''
            Name              = ''
            Version           = ''
            Release           = ''
            Epoch             = ''
            Architecture      = ''
            License           = ''
            Summary           = ''
            SourceRpm         = ''
            PayloadFormat     = ''
            PayloadCompressor = ''
            PackagedFilePath  = ''
            ParseStatus       = ''
            ParseError        = ''
        })
    }

    foreach ($rpm in $RpmManifest) {
        $rows.Add([pscustomobject]@{
            RecordType        = 'RPMMetadata'
            Path              = $rpm.PackagedFilePath
            Size              = ''
            Modified          = ''
            ShortSha256       = ''
            RpmPath           = $rpm.RpmPath
            Name              = $rpm.Name
            Version           = $rpm.Version
            Release           = $rpm.Release
            Epoch             = $rpm.Epoch
            Architecture      = $rpm.Architecture
            License           = $rpm.License
            Summary           = $rpm.Summary
            SourceRpm         = $rpm.SourceRpm
            PayloadFormat     = $rpm.PayloadFormat
            PayloadCompressor = $rpm.PayloadCompressor
            PackagedFilePath  = $rpm.PackagedFilePath
            ParseStatus       = $rpm.ParseStatus
            ParseError        = $rpm.ParseError
        })
    }

    $resolved = Resolve-OutputPath -OutputPath $OutputPath
    if ($rows.Count -gt 0) {
        $rows | Export-Csv -LiteralPath $resolved -NoTypeInformation
        return
    }

    $header = '"RecordType","Path","Size","Modified","ShortSha256","RpmPath","Name","Version","Release","Epoch","Architecture","License","Summary","SourceRpm","PayloadFormat","PayloadCompressor","PackagedFilePath","ParseStatus","ParseError"'
    [IO.File]::WriteAllLines($resolved, [string[]]@($header), [Text.Encoding]::UTF8)
}

function Read-IsoEntryPrefix {
    param(
        [System.IO.FileStream]$Stream,
        [pscustomobject]$Entry,
        [Int64]$MaxBytes = 64MB
    )

    $readLength = [int][Math]::Min([Int64]$Entry.Size, [Int64]$MaxBytes)
    if ($readLength -le 0) { return ,([byte[]]::new(0)) }
    return ,(Read-Bytes -Stream $Stream -Offset ([Int64]$Entry.Extent * $SectorSize) -Count $readLength)
}

function Read-RpmHeader {
    param(
        [byte[]]$Bytes,
        [int]$Offset
    )

    if (($Offset + 16) -gt $Bytes.Length) {
        throw "RPM header at offset $Offset is truncated."
    }

    if ($Bytes[$Offset] -ne 0x8E -or $Bytes[$Offset + 1] -ne 0xAD -or $Bytes[$Offset + 2] -ne 0xE8) {
        throw "RPM header magic not found at offset $Offset."
    }

    $indexCount = [int](Convert-UInt32BE -Bytes $Bytes -Offset ($Offset + 8))
    $storeLength = [int](Convert-UInt32BE -Bytes $Bytes -Offset ($Offset + 12))
    $indexOffset = $Offset + 16
    $storeOffset = $indexOffset + ($indexCount * 16)
    $endOffset = $storeOffset + $storeLength

    if ($endOffset -gt $Bytes.Length) {
        throw "RPM header store is truncated. Need $endOffset bytes but only read $($Bytes.Length)."
    }

    $entries = @{}
    for ($i = 0; $i -lt $indexCount; $i++) {
        $entryOffset = $indexOffset + ($i * 16)
        $tag = [int](Convert-UInt32BE -Bytes $Bytes -Offset $entryOffset)
        $type = [int](Convert-UInt32BE -Bytes $Bytes -Offset ($entryOffset + 4))
        $dataOffset = [int](Convert-UInt32BE -Bytes $Bytes -Offset ($entryOffset + 8))
        $count = [int](Convert-UInt32BE -Bytes $Bytes -Offset ($entryOffset + 12))
        $entries[$tag] = [pscustomobject]@{
            Tag         = $tag
            Type        = $type
            Offset      = $dataOffset
            Count       = $count
            StoreOffset = $storeOffset
            StoreLength = $storeLength
        }
    }

    [pscustomobject]@{
        Entries  = $entries
        EndOffset = $endOffset
    }
}

function Read-NullTerminatedString {
    param(
        [byte[]]$Bytes,
        [int]$Offset,
        [int]$Limit
    )

    $end = $Offset
    while ($end -lt $Limit -and $Bytes[$end] -ne 0) {
        $end++
    }
    if ($end -le $Offset) { return '' }
    return [Text.Encoding]::UTF8.GetString($Bytes, $Offset, $end - $Offset)
}

function Get-RpmTagValue {
    param(
        [byte[]]$Bytes,
        [hashtable]$Entries,
        [int]$Tag
    )

    if (-not $Entries.ContainsKey($Tag)) { return $null }
    $entry = $Entries[$Tag]
    $dataStart = [int]$entry.StoreOffset + [int]$entry.Offset
    $dataLimit = [int]$entry.StoreOffset + [int]$entry.StoreLength

    switch ($entry.Type) {
        3 {
            $values = [System.Collections.Generic.List[object]]::new()
            for ($i = 0; $i -lt $entry.Count; $i++) {
                $values.Add((Convert-UInt16BE -Bytes $Bytes -Offset ($dataStart + ($i * 2))))
            }
            return @($values.ToArray())
        }
        4 {
            $values = [System.Collections.Generic.List[object]]::new()
            for ($i = 0; $i -lt $entry.Count; $i++) {
                $values.Add(([int32](Convert-UInt32BE -Bytes $Bytes -Offset ($dataStart + ($i * 4)))))
            }
            return @($values.ToArray())
        }
        6 {
            return Read-NullTerminatedString -Bytes $Bytes -Offset $dataStart -Limit $dataLimit
        }
        { $_ -eq 8 -or $_ -eq 9 } {
            $strings = [System.Collections.Generic.List[string]]::new()
            $cursor = $dataStart
            for ($i = 0; $i -lt $entry.Count -and $cursor -lt $dataLimit; $i++) {
                $value = Read-NullTerminatedString -Bytes $Bytes -Offset $cursor -Limit $dataLimit
                $strings.Add($value)
                $cursor += ([Text.Encoding]::UTF8.GetByteCount($value) + 1)
            }
            return @($strings.ToArray())
        }
        default {
            return $null
        }
    }
}

function Get-RpmScalarTag {
    param(
        [byte[]]$Bytes,
        [hashtable]$Entries,
        [int]$Tag
    )

    $value = Get-RpmTagValue -Bytes $Bytes -Entries $Entries -Tag $Tag
    if ($null -eq $value) { return $null }
    if ($value -is [array]) {
        if ($value.Count -eq 0) { return $null }
        return $value[0]
    }
    return $value
}

function Get-RpmPackagedFiles {
    param(
        [byte[]]$Bytes,
        [hashtable]$Entries
    )

    $oldFileNamesValue = Get-RpmTagValue -Bytes $Bytes -Entries $Entries -Tag 1027
    [object[]]$oldFileNames = @()
    if ($null -ne $oldFileNamesValue) { $oldFileNames = @($oldFileNamesValue) }
    if ($oldFileNames.Count -gt 0) {
        return $oldFileNames
    }

    $dirIndexesValue = Get-RpmTagValue -Bytes $Bytes -Entries $Entries -Tag 1116
    $baseNamesValue = Get-RpmTagValue -Bytes $Bytes -Entries $Entries -Tag 1117
    $dirNamesValue = Get-RpmTagValue -Bytes $Bytes -Entries $Entries -Tag 1118
    [object[]]$dirIndexes = @()
    [object[]]$baseNames = @()
    [object[]]$dirNames = @()
    if ($null -ne $dirIndexesValue) { $dirIndexes = @($dirIndexesValue) }
    if ($null -ne $baseNamesValue) { $baseNames = @($baseNamesValue) }
    if ($null -ne $dirNamesValue) { $dirNames = @($dirNamesValue) }
    if ($baseNames.Count -eq 0 -or $dirNames.Count -eq 0 -or $dirIndexes.Count -eq 0) {
        return @()
    }

    $files = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $baseNames.Count; $i++) {
        $dirIndex = [int]$dirIndexes[$i]
        $dirName = if ($dirIndex -ge 0 -and $dirIndex -lt $dirNames.Count) { $dirNames[$dirIndex] } else { '' }
        $files.Add($dirName + $baseNames[$i])
    }
    return @($files.ToArray())
}

function Read-RpmMetadata {
    param(
        [System.IO.FileStream]$Stream,
        [pscustomobject]$Entry
    )

    $bytes = Read-IsoEntryPrefix -Stream $Stream -Entry $Entry
    if ($bytes.Length -lt 120) {
        throw "RPM file $($Entry.Path) is too small to contain RPM headers."
    }

    if ($bytes[0] -ne 0xED -or $bytes[1] -ne 0xAB -or $bytes[2] -ne 0xEE -or $bytes[3] -ne 0xDB) {
        throw "RPM lead magic not found in $($Entry.Path)."
    }

    $signatureHeader = Read-RpmHeader -Bytes $bytes -Offset 96
    $mainHeaderOffset = [int](Align-Offset -Offset $signatureHeader.EndOffset -Alignment 8)
    $mainHeader = Read-RpmHeader -Bytes $bytes -Offset $mainHeaderOffset
    $entries = $mainHeader.Entries

    $files = @(Get-RpmPackagedFiles -Bytes $bytes -Entries $entries)
    [pscustomobject]@{
        RpmPath           = $Entry.Path
        Name              = Get-RpmScalarTag -Bytes $bytes -Entries $entries -Tag 1000
        Version           = Get-RpmScalarTag -Bytes $bytes -Entries $entries -Tag 1001
        Release           = Get-RpmScalarTag -Bytes $bytes -Entries $entries -Tag 1002
        Epoch             = Get-RpmScalarTag -Bytes $bytes -Entries $entries -Tag 1003
        Architecture      = Get-RpmScalarTag -Bytes $bytes -Entries $entries -Tag 1022
        License           = Get-RpmScalarTag -Bytes $bytes -Entries $entries -Tag 1014
        Summary           = Get-RpmScalarTag -Bytes $bytes -Entries $entries -Tag 1004
        SourceRpm         = Get-RpmScalarTag -Bytes $bytes -Entries $entries -Tag 1044
        PayloadFormat     = Get-RpmScalarTag -Bytes $bytes -Entries $entries -Tag 1124
        PayloadCompressor = Get-RpmScalarTag -Bytes $bytes -Entries $entries -Tag 1125
        PackagedFiles     = $files
    }
}

function Get-RpmMetadataManifest {
    param(
        [System.IO.FileStream]$Stream,
        [object[]]$Entries
    )

    $rpms = @($Entries | Where-Object { -not $_.IsDirectory -and $_.Path -like '*.rpm' } | Sort-Object Path)
    $rows = [System.Collections.Generic.List[object]]::new()
    $index = 0

    foreach ($rpm in $rpms) {
        $index++
        Write-Progress -Activity 'Parsing visible RPM headers' -Status $rpm.Path -PercentComplete (($index / [Math]::Max($rpms.Count, 1)) * 100)

        try {
            $metadata = Read-RpmMetadata -Stream $Stream -Entry $rpm
            $files = @($metadata.PackagedFiles)
            if ($files.Count -eq 0) {
                $files = @('')
            }

            foreach ($file in $files) {
                $rows.Add([pscustomobject]@{
                    RpmPath           = $metadata.RpmPath
                    Name              = $metadata.Name
                    Version           = $metadata.Version
                    Release           = $metadata.Release
                    Epoch             = $metadata.Epoch
                    Architecture      = $metadata.Architecture
                    License           = $metadata.License
                    Summary           = $metadata.Summary
                    SourceRpm         = $metadata.SourceRpm
                    PayloadFormat     = $metadata.PayloadFormat
                    PayloadCompressor = $metadata.PayloadCompressor
                    PackagedFilePath  = $file
                    ParseStatus       = 'OK'
                    ParseError        = ''
                })
            }
        }
        catch {
            $rows.Add([pscustomobject]@{
                RpmPath           = $rpm.Path
                Name              = ''
                Version           = ''
                Release           = ''
                Epoch             = ''
                Architecture      = ''
                License           = ''
                Summary           = ''
                SourceRpm         = ''
                PayloadFormat     = ''
                PayloadCompressor = ''
                PackagedFilePath  = ''
                ParseStatus       = 'Failed'
                ParseError        = $_.Exception.Message
            })
        }
    }

    Write-Progress -Activity 'Parsing visible RPM headers' -Completed
    return @($rows)
}

function Get-ErrorGuidance {
    param([string]$Message)

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
    # 1. Resolve the default output path if the caller did not provide one.
    # 2. Read ISO volume descriptors and choose Joliet when available.
    # 3. Traverse the selected root directory into file entries.
    # 4. Stream-hash visible files and parse visible RPM headers.
    # 5. Write one text report, plus one optional combined CSV export.
    $stage = 'Open ISO file'
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    if ([string]::IsNullOrWhiteSpace($Output)) {
        $baseName = [IO.Path]::GetFileNameWithoutExtension($resolvedPath)
        $Output = Join-Path -Path (Get-Location).Path -ChildPath "$baseName-iso-review.txt"
    }
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

    $stage = 'Parse visible RPM headers'
    $rpmManifest = @(Get-RpmMetadataManifest -Stream $stream -Entries $entries)

    $summary = [pscustomobject]@{
        IsoPath           = $resolvedPath
        Filesystem        = if ($descriptor.IsJoliet) { 'Joliet / ISO-9660' } else { 'ISO-9660' }
        VolumeIdentifier = $descriptor.VolumeIdentifier
        FileCount         = @($entries | Where-Object { -not $_.IsDirectory }).Count
    }

    $stage = 'Write text report'
    Export-ReviewReport -Summary $summary -FileManifest $manifest -RpmManifest $rpmManifest -OutputPath $Output

    if (-not [string]::IsNullOrWhiteSpace($CsvOutput)) {
        $stage = 'Write optional CSV report'
        Export-ReviewCsvReport -FileManifest $manifest -RpmManifest $rpmManifest -OutputPath $CsvOutput
    }

    [pscustomobject]@{
        IsoPath           = $resolvedPath
        Filesystem        = if ($descriptor.IsJoliet) { 'Joliet / ISO-9660' } else { 'ISO-9660' }
        VolumeIdentifier = $descriptor.VolumeIdentifier
        FileCount         = @($entries | Where-Object { -not $_.IsDirectory }).Count
        FileManifestRows  = $manifest.Count
        RpmManifestRows   = $rpmManifest.Count
        Output            = Resolve-OutputPath -OutputPath $Output
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
