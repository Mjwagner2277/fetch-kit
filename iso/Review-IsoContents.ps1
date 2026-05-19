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

$SectorSize = 2048

function Read-Bytes {
    param(
        [Parameter(Mandatory)][System.IO.FileStream]$Stream,
        [Parameter(Mandatory)][Int64]$Offset,
        [Parameter(Mandatory)][int]$Count
    )

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

function Test-ProbablyText {
    param([byte[]]$Bytes)

    if ($Bytes.Length -eq 0) { return $false }
    $sampleLength = [Math]::Min($Bytes.Length, 512)
    $printable = 0
    $control = 0

    for ($i = 0; $i -lt $sampleLength; $i++) {
        $b = $Bytes[$i]
        if ($b -eq 9 -or $b -eq 10 -or $b -eq 13 -or ($b -ge 32 -and $b -le 126)) {
            $printable++
        }
        elseif ($b -lt 32 -or $b -eq 127) {
            $control++
        }
    }

    return (($printable / $sampleLength) -ge 0.85 -and $control -le 8)
}

function Get-TextPreview {
    param(
        [System.IO.FileStream]$Stream,
        [pscustomobject]$Entry,
        [int]$MaxBytes
    )

    $readLength = [Math]::Min([int64]$MaxBytes, [int64]$Entry.Size)
    if ($readLength -le 0) { return $null }

    $bytes = Read-Bytes -Stream $Stream -Offset ([Int64]$Entry.Extent * $SectorSize) -Count ([int]$readLength)
    if (-not (Test-ProbablyText -Bytes $bytes)) { return $null }

    return ([Text.Encoding]::UTF8.GetString($bytes) -replace "`0", '' -replace '\p{C}&&[^\r\n\t]', '').Trim()
}

function Export-IsoEntry {
    param(
        [System.IO.FileStream]$Stream,
        [pscustomobject]$Entry,
        [string]$DestinationRoot
    )

    $targetRoot = Resolve-Path -LiteralPath $DestinationRoot -ErrorAction SilentlyContinue
    if ($null -eq $targetRoot) {
        $null = New-Item -ItemType Directory -Path $DestinationRoot -Force
        $targetRoot = Resolve-Path -LiteralPath $DestinationRoot
    }

    $safeRelative = $Entry.Path.TrimStart('\') -replace '[\\/:*?"<>|]', '_'
    $target = Join-Path -Path $targetRoot.Path -ChildPath $safeRelative
    $parent = Split-Path -Path $target -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }

    $out = [System.IO.File]::Open($target, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $remaining = [Int64]$Entry.Size
        $position = [Int64]$Entry.Extent * $SectorSize
        $bufferSize = [Int64]1MB
        while ($remaining -gt 0) {
            $chunkSize = [int][Math]::Min([Int64]$bufferSize, [Int64]$remaining)
            $chunk = Read-Bytes -Stream $Stream -Offset $position -Count $chunkSize
            if ($chunk.Length -eq 0) {
                throw "Unexpected end of ISO while extracting $($Entry.Path). Expected $($Entry.Size) bytes."
            }
            $out.Write($chunk, 0, $chunk.Length)
            $position += $chunk.Length
            $remaining -= $chunk.Length
        }
    }
    finally {
        $out.Dispose()
    }

    return $target
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

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Path`tSize`tModified`tShortSha256")
    foreach ($row in $Manifest) {
        $modified = if ($null -ne $row.Modified) { $row.Modified.ToString('s') } else { '' }
        $lines.Add("$($row.Path)`t$($row.Size)`t$modified`t$($row.ShortSha256)")
    }
    [IO.File]::WriteAllLines((Resolve-OutputPath -OutputPath $OutputPath), $lines, [Text.Encoding]::UTF8)
}

function Find-IsoEntry {
    param(
        [object[]]$Entries,
        [string[]]$Patterns
    )

    foreach ($pattern in $Patterns) {
        $match = $Entries | Where-Object { $_.Path -like $pattern } | Select-Object -First 1
        if ($null -ne $match) { return $match }
    }

    return $null
}

function Get-RhelIsoSummary {
    param(
        [System.IO.FileStream]$Stream,
        [object[]]$Entries
    )

    $treeInfo = Find-IsoEntry -Entries $Entries -Patterns @('\.treeinfo')
    $mediaRepo = Find-IsoEntry -Entries $Entries -Patterns @('\media.repo')
    $installImage = Find-IsoEntry -Entries $Entries -Patterns @('\images\install.img')
    $kernel = Find-IsoEntry -Entries $Entries -Patterns @('\isolinux\vmlinuz', '\images\pxeboot\vmlinuz')
    $initrd = Find-IsoEntry -Entries $Entries -Patterns @('\isolinux\initrd.img', '\images\pxeboot\initrd.img')
    $biosLoader = Find-IsoEntry -Entries $Entries -Patterns @('\isolinux\isolinux.bin')
    $uefiLoader = Find-IsoEntry -Entries $Entries -Patterns @('\EFI\BOOT\BOOTX64.EFI', '\EFI\BOOT\BOOTAA64.EFI')
    $baseOs = Find-IsoEntry -Entries $Entries -Patterns @('\BaseOS', '\BaseOS\Packages')
    $appStream = Find-IsoEntry -Entries $Entries -Patterns @('\AppStream', '\AppStream\Packages')
    $rpmCount = @($Entries | Where-Object { -not $_.IsDirectory -and $_.Path -like '*.rpm' }).Count

    $treeInfoPreview = $null
    if ($null -ne $treeInfo) {
        $treeInfoPreview = Get-TextPreview -Stream $Stream -Entry $treeInfo -MaxBytes 8192
    }

    [pscustomobject]@{
        LooksLikeRhelFamilyInstaller = [bool]($treeInfo -or $installImage -or ($kernel -and $initrd))
        TreeInfo                     = if ($treeInfo) { $treeInfo.Path } else { $null }
        MediaRepo                    = if ($mediaRepo) { $mediaRepo.Path } else { $null }
        InstallImage                 = if ($installImage) { $installImage.Path } else { $null }
        Kernel                       = if ($kernel) { $kernel.Path } else { $null }
        Initrd                       = if ($initrd) { $initrd.Path } else { $null }
        BiosBootloader               = if ($biosLoader) { $biosLoader.Path } else { $null }
        UefiBootloader               = if ($uefiLoader) { $uefiLoader.Path } else { $null }
        BaseOSRepoPresent            = [bool]$baseOs
        AppStreamRepoPresent         = [bool]$appStream
        RpmFileCount                 = $rpmCount
        TreeInfoPreview              = $treeInfoPreview
    }
}

function Get-LinuxIsoSummary {
    param(
        [System.IO.FileStream]$Stream,
        [object[]]$Entries
    )

    $debianInfo = Find-IsoEntry -Entries $Entries -Patterns @('\.disk\info')
    $debianDists = Find-IsoEntry -Entries $Entries -Patterns @('\dists\*')
    $debianPool = Find-IsoEntry -Entries $Entries -Patterns @('\pool\*')
    $debianKernel = Find-IsoEntry -Entries $Entries -Patterns @('\install.*\vmlinuz', '\install.*\gtk\vmlinuz')
    $debianInitrd = Find-IsoEntry -Entries $Entries -Patterns @('\install.*\initrd.gz', '\install.*\gtk\initrd.gz')

    $rhelTreeInfo = Find-IsoEntry -Entries $Entries -Patterns @('\.treeinfo')
    $rhelInstallImage = Find-IsoEntry -Entries $Entries -Patterns @('\images\install.img')
    $rhelKernel = Find-IsoEntry -Entries $Entries -Patterns @('\isolinux\vmlinuz', '\images\pxeboot\vmlinuz')
    $rhelInitrd = Find-IsoEntry -Entries $Entries -Patterns @('\isolinux\initrd.img', '\images\pxeboot\initrd.img')

    $isolinux = Find-IsoEntry -Entries $Entries -Patterns @('\isolinux\isolinux.bin')
    $syslinuxCfg = Find-IsoEntry -Entries $Entries -Patterns @('\isolinux\isolinux.cfg', '\isolinux\txt.cfg')
    $grubCfg = Find-IsoEntry -Entries $Entries -Patterns @('\boot\grub\grub.cfg', '\EFI\BOOT\grub.cfg', '\EFI\debian\grub.cfg')
    $uefiLoader = Find-IsoEntry -Entries $Entries -Patterns @('\EFI\BOOT\BOOTX64.EFI', '\EFI\boot\bootx64.efi', '\EFI\BOOT\BOOTAA64.EFI', '\EFI\boot\bootaa64.efi')

    $packageCount = @($Entries | Where-Object { -not $_.IsDirectory -and ($_.Path -like '*.deb' -or $_.Path -like '*.udeb' -or $_.Path -like '*.rpm') }).Count
    $checksumManifests = @($Entries | Where-Object { -not $_.IsDirectory -and ($_.Path -like '*SHA*SUM*' -or $_.Path -like '*MD5SUM*' -or $_.Path -like '\md5sum.txt') } | Select-Object -ExpandProperty Path)

    $infoPreview = $null
    if ($null -ne $debianInfo) {
        $infoPreview = Get-TextPreview -Stream $Stream -Entry $debianInfo -MaxBytes 2048
    }
    elseif ($null -ne $rhelTreeInfo) {
        $infoPreview = Get-TextPreview -Stream $Stream -Entry $rhelTreeInfo -MaxBytes 4096
    }

    [pscustomobject]@{
        LooksLikeLinuxInstaller = [bool]($debianInfo -or $debianDists -or $rhelTreeInfo -or $rhelInstallImage -or ($uefiLoader -and ($debianKernel -or $rhelKernel)))
        LikelyFamily            = if ($debianInfo -or $debianDists) { 'Debian-family' } elseif ($rhelTreeInfo -or $rhelInstallImage) { 'RHEL-family' } else { 'Unknown Linux installer' }
        InstallerInfo           = if ($debianInfo) { $debianInfo.Path } elseif ($rhelTreeInfo) { $rhelTreeInfo.Path } else { $null }
        InstallerInfoPreview    = $infoPreview
        Kernel                  = if ($debianKernel) { $debianKernel.Path } elseif ($rhelKernel) { $rhelKernel.Path } else { $null }
        Initrd                  = if ($debianInitrd) { $debianInitrd.Path } elseif ($rhelInitrd) { $rhelInitrd.Path } else { $null }
        BiosBootloader          = if ($isolinux) { $isolinux.Path } else { $null }
        UefiBootloader          = if ($uefiLoader) { $uefiLoader.Path } else { $null }
        GrubConfig              = if ($grubCfg) { $grubCfg.Path } else { $null }
        SyslinuxConfig          = if ($syslinuxCfg) { $syslinuxCfg.Path } else { $null }
        DebianDistsPresent      = [bool]$debianDists
        DebianPoolPresent       = [bool]$debianPool
        PackageFileCount        = $packageCount
        ChecksumManifests       = $checksumManifests
    }
}

function Get-Entropy {
    param([byte[]]$Bytes)

    if ($Bytes.Length -eq 0) { return 0 }
    $counts = [int[]]::new(256)
    foreach ($byte in $Bytes) { $counts[$byte]++ }

    $entropy = 0.0
    foreach ($count in $counts) {
        if ($count -gt 0) {
            $p = $count / $Bytes.Length
            $entropy -= $p * [Math]::Log($p, 2)
        }
    }
    return [Math]::Round($entropy, 3)
}

function Get-PrintableStrings {
    param(
        [System.IO.FileStream]$Stream,
        [int]$Limit
    )

    $interesting = [regex]'(?i)(powershell|cmd\.exe|wscript|cscript|mshta|rundll32|regsvr32|schtasks|autorun\.inf|setup\.exe|\.ps1|\.vbs|\.js|\.hta|password|credential|token|http://|https://|[a-z0-9.-]+\.(exe|dll|sys|scr|bat|cmd))'
    $results = [System.Collections.Generic.List[string]]::new()
    $buffer = [byte[]]::new(1MB)
    $carry = ''
    $null = $Stream.Seek(0, [System.IO.SeekOrigin]::Begin)

    while (($read = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0 -and $results.Count -lt $Limit) {
        $chunkBytes = if ($read -eq $buffer.Length) { $buffer } else { $buffer[0..($read - 1)] }
        $text = $carry + ([Text.Encoding]::ASCII.GetString($chunkBytes) -replace '[^\x20-\x7e]', "`n")
        $parts = $text -split "`n"
        $carry = $parts[-1]
        foreach ($part in $parts[0..([Math]::Max(0, $parts.Count - 2))]) {
            if ($part.Length -ge 5 -and $interesting.IsMatch($part)) {
                $results.Add($part.Trim())
                if ($results.Count -ge $Limit) { break }
            }
        }
    }

    return $results
}

function Get-SignatureHits {
    param([System.IO.FileStream]$Stream)

    $signatures = @(
        @{ Name = 'MZ executable'; Bytes = [byte[]](0x4D, 0x5A) },
        @{ Name = 'ZIP/JAR/DOCX/APK'; Bytes = [byte[]](0x50, 0x4B, 0x03, 0x04) },
        @{ Name = 'RAR archive'; Bytes = [byte[]](0x52, 0x61, 0x72, 0x21) },
        @{ Name = '7z archive'; Bytes = [byte[]](0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C) },
        @{ Name = 'ELF binary'; Bytes = [byte[]](0x7F, 0x45, 0x4C, 0x46) },
        @{ Name = 'PDF'; Bytes = [byte[]](0x25, 0x50, 0x44, 0x46) }
    )

    $hits = [System.Collections.Generic.List[object]]::new()
    $buffer = [byte[]]::new(1MB)
    $overlap = [byte[]]::new(16)
    $absolute = [Int64]0
    $null = $Stream.Seek(0, [System.IO.SeekOrigin]::Begin)

    while (($read = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $combined = [byte[]]::new($overlap.Length + $read)
        [Array]::Copy($overlap, 0, $combined, 0, $overlap.Length)
        [Array]::Copy($buffer, 0, $combined, $overlap.Length, $read)

        foreach ($sig in $signatures) {
            $needle = [byte[]]$sig.Bytes
            for ($i = 0; $i -le ($combined.Length - $needle.Length); $i++) {
                $matched = $true
                for ($j = 0; $j -lt $needle.Length; $j++) {
                    if ($combined[$i + $j] -ne $needle[$j]) {
                        $matched = $false
                        break
                    }
                }
                if ($matched) {
                    $offset = $absolute + $i - $overlap.Length
                    if ($offset -ge 0) {
                        $hits.Add([pscustomobject]@{ Signature = $sig.Name; Offset = $offset })
                    }
                    if ($hits.Count -ge 200) { return $hits }
                }
            }
        }

        $copy = [Math]::Min($overlap.Length, $read)
        [Array]::Copy($buffer, $read - $copy, $overlap, $overlap.Length - $copy, $copy)
        $absolute += $read
    }

    return $hits
}

function Invoke-IsoTriage {
    param(
        [string]$LiteralPath,
        [System.IO.FileStream]$Stream,
        [object[]]$Descriptors,
        [int]$StringLimit
    )

    $fileInfo = Get-Item -LiteralPath $LiteralPath
    $sampleLength = [int][Math]::Min($fileInfo.Length, 4MB)
    $sample = Read-Bytes -Stream $Stream -Offset 0 -Count $sampleLength

    [pscustomobject]@{
        Path                 = $fileInfo.FullName
        SizeBytes            = $fileInfo.Length
        SHA256               = (Get-FileHash -LiteralPath $fileInfo.FullName -Algorithm SHA256).Hash
        SHA1                 = (Get-FileHash -LiteralPath $fileInfo.FullName -Algorithm SHA1).Hash
        MD5                  = (Get-FileHash -LiteralPath $fileInfo.FullName -Algorithm MD5).Hash
        SampleEntropy        = Get-Entropy -Bytes $sample
        VolumeDescriptors    = $Descriptors | Select-Object Sector, TypeName, IsJoliet, VolumeIdentifier, SystemIdentifier, VolumeSpaceSectors
        SignatureHits        = Get-SignatureHits -Stream $Stream | Select-Object -First 50
        InterestingStrings   = Get-PrintableStrings -Stream $Stream -Limit $StringLimit
        RecommendedNextStep  = 'If file-level inspection fails, treat this as opaque media: preserve the ISO, hash it, scan it with AV/YARA in an isolated analysis VM, compare hashes against known-good/vendor sources, inspect boot records and embedded executable signatures, and only then detonate/extract with a dedicated forensic ISO/UDF parser or sandbox.'
    }
}

$resolvedPath = (Resolve-Path -LiteralPath $Path).Path
$stream = [System.IO.File]::Open($resolvedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)

try {
    if ([string]::IsNullOrWhiteSpace($TextOutput) -and [string]::IsNullOrWhiteSpace($CsvOutput)) {
        throw 'Specify -TextOutput or -CsvOutput.'
    }

    $descriptors = @(Read-VolumeDescriptors -Stream $stream)
    $descriptor = $descriptors | Where-Object { $_.IsJoliet -and $_.RootRecord } | Select-Object -First 1
    if ($null -eq $descriptor) {
        $descriptor = $descriptors | Where-Object { $_.Type -eq 1 -and $_.RootRecord } | Select-Object -First 1
    }

    if ($null -eq $descriptor) {
        throw 'No readable ISO-9660/Joliet root directory was found. File contents cannot be listed with this PowerShell-only parser. Next cyber-relevant step: preserve and hash the ISO as an artifact, verify against vendor checksums/signatures, then inspect with a forensic ISO/UDF parser or isolated sandbox.'
    }

    $entries = @(Get-IsoEntries -Stream $stream -RootRecord $descriptor.RootRecord -Joliet:$descriptor.IsJoliet)
    $manifest = @(Get-IsoFileManifest -Stream $stream -Entries $entries)

    if (-not [string]::IsNullOrWhiteSpace($CsvOutput)) {
        $manifest | Export-Csv -LiteralPath (Resolve-OutputPath -OutputPath $CsvOutput) -NoTypeInformation
    }

    if (-not [string]::IsNullOrWhiteSpace($TextOutput)) {
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
finally {
    $stream.Dispose()
}
