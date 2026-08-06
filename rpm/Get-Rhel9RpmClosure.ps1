<#
.SYNOPSIS
Downloads an EL9/RHEL-compatible RPM dependency closure from public HTTP repos.

.DESCRIPTION
This script uses only PowerShell and public rpm-md repositories. It does not use
Red Hat CDN, subscription-manager, credentials, cookies, or any sign-on flow.

The default repositories are AlmaLinux 9 BaseOS, AppStream, and CRB for x86_64.
Rocky Linux and Oracle Linux public repositories are also available through
-Provider. Optional EPEL-style packages can be added with -IncludeEpel.

The script downloads repository metadata, resolves package dependencies from
primary.xml.gz and filelists.xml.gz, downloads selected RPMs, then writes a
local DNF repository under the output directory with primary/filelists/other
metadata and repomd.xml.

.EXAMPLE
.\Get-Rhel9RpmClosure.ps1 -Package curl,wget,tar -OutputDirectory .\el9-rpms

.EXAMPLE
.\Get-Rhel9RpmClosure.ps1 `
  -Package nodejs,npm `
  -ModuleStream nodejs:20 `
  -IncludeWeakDependencies `
  -OutputDirectory .\el9-nodejs

.EXAMPLE
.\Get-Rhel9RpmClosure.ps1 `
  -Package jq `
  -IncludeEpel `
  -Provider AlmaLinux `
  -OutputDirectory .\el9-jq

.EXAMPLE
.\Get-Rhel9RpmClosure.ps1 `
  -Package tmux `
  -NoDefaultRepositories `
  -Repository internal=https://mirror.example.com/almalinux/9/BaseOS/x86_64/os/ `
  -Repository appstream=https://mirror.example.com/almalinux/9/AppStream/x86_64/os/
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$Package = @(),

    [ValidateSet('AlmaLinux', 'RockyLinux', 'OracleLinux')]
    [string]$Provider = 'AlmaLinux',

    [ValidateSet('x86_64', 'aarch64', 'ppc64le', 's390x')]
    [string]$Arch = 'x86_64',

    [ValidateSet('9')]
    [string]$Releasever = '9',

    [string]$OutputDirectory = (Join-Path (Get-Location) 'rhel9-rpm-cache'),

    [switch]$IncludeEpel,

    [switch]$IncludeExtras,

    [switch]$IncludeWeakDependencies,

    [string[]]$ModuleStream = @(),

    [string[]]$ModuleProfile = @(),

    [string[]]$Repository = @(),

    [switch]$NoDefaultRepositories,

    [string[]]$AssumeInstalledCapability = @(
        'system-release',
        'system-release(releasever)',
        'redhat-release',
        'redhat-release-eula',
        '/etc/redhat-release'
    ),

    [switch]$SkipFilelists,

    [switch]$AllowUnresolved,

    [switch]$Force,

    [switch]$KeepMetadataCache,

    [switch]$IncludeKernelCapabilities,

    [string]$RepoId = 'airgap-el9'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TargetArch = $Arch
$script:AllPackages = New-Object System.Collections.ArrayList
$script:PackagesById = @{}
$script:PackagesByName = @{}
$script:ProvidesByName = @{}
$script:FileProvidesByName = @{}
$script:SelectedPackages = @{}
$script:SelectedOrder = New-Object System.Collections.ArrayList
$script:SelectedReasons = @{}
$script:UnresolvedDependencies = New-Object System.Collections.ArrayList
$script:ResolutionWarnings = New-Object System.Collections.ArrayList
$script:ModuleRecords = New-Object System.Collections.ArrayList
$script:AllModuleArtifactKeys = @{}
$script:AllModuleArtifactNames = @{}
$script:EnabledModuleArtifactKeys = @{}
$script:EnabledModuleStreams = @{}
$script:RepoById = @{}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
catch {
    # Older hosts may not expose the same protocol enum values. Invoke-WebRequest
    # will still use the platform defaults.
}

function New-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Join-Url {
    param(
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][string]$Path
    )

    return $Base.TrimEnd('/') + '/' + $Path.TrimStart('/')
}

function ConvertTo-SafeName {
    param([Parameter(Mandatory = $true)][string]$Value)

    return ($Value -replace '[^A-Za-z0-9_.-]', '-')
}

function Get-UnixTimestamp {
    $epoch = [DateTime]::SpecifyKind([DateTime]'1970-01-01T00:00:00Z', [DateTimeKind]::Utc)
    return [int64](([DateTime]::UtcNow - $epoch).TotalSeconds)
}

function Get-HashAlgorithmName {
    param([string]$Algorithm)

    switch ($Algorithm.ToLowerInvariant()) {
        'sha256' { return 'SHA256' }
        'sha1' { return 'SHA1' }
        'sha384' { return 'SHA384' }
        'sha512' { return 'SHA512' }
        'md5' { return 'MD5' }
        default { throw "Unsupported checksum algorithm '$Algorithm'." }
    }
}

function Get-FileHashText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Algorithm = 'sha256'
    )

    $hash = Get-FileHash -LiteralPath $Path -Algorithm (Get-HashAlgorithmName -Algorithm $Algorithm)
    return $hash.Hash.ToLowerInvariant()
}

function Invoke-HttpDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [switch]$Overwrite
    )

    if ((Test-Path -LiteralPath $OutFile) -and -not $Overwrite) {
        return
    }

    $parent = Split-Path -Parent $OutFile
    New-Directory -Path $parent

    $temporary = "$OutFile.partial"
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Force
    }

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('PowerShell-EL9-RPM-Closure/1.0')
    $currentUri = [Uri]$Uri
    try {
        for ($redirect = 0; $redirect -lt 10; $redirect++) {
            $response = $client.GetAsync($currentUri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            try {
                $statusCode = [int]$response.StatusCode
                if ($statusCode -ge 300 -and $statusCode -lt 400) {
                    $location = $response.Headers.Location
                    if ($null -eq $location) {
                        throw "HTTP $statusCode redirect from $currentUri did not include a Location header."
                    }

                    if ($location.IsAbsoluteUri) {
                        $currentUri = $location
                    }
                    else {
                        $currentUri = [Uri]::new($currentUri, $location)
                    }
                    continue
                }

                if (-not $response.IsSuccessStatusCode) {
                    throw "HTTP $statusCode from $currentUri"
                }

                $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                try {
                    $outputStream = [System.IO.File]::Create($temporary)
                    try {
                        $inputStream.CopyTo($outputStream)
                    }
                    finally {
                        $outputStream.Dispose()
                    }
                }
                finally {
                    $inputStream.Dispose()
                }

                break
            }
            finally {
                $response.Dispose()
            }
        }

        if (-not (Test-Path -LiteralPath $temporary)) {
            throw "Too many redirects from $Uri"
        }
    }
    catch {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
        throw "Failed to download $Uri. $($_.Exception.Message)"
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }

    if (Test-Path -LiteralPath $OutFile) {
        Remove-Item -LiteralPath $OutFile -Force
    }
    Move-Item -LiteralPath $temporary -Destination $OutFile
}

function Expand-GZipFile {
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $inputStream = [System.IO.File]::OpenRead($InputPath)
    try {
        $gzipStream = New-Object System.IO.Compression.GZipStream($inputStream, [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $outputStream = [System.IO.File]::Create($OutputPath)
            try {
                $gzipStream.CopyTo($outputStream)
            }
            finally {
                $outputStream.Dispose()
            }
        }
        finally {
            $gzipStream.Dispose()
        }
    }
    finally {
        $inputStream.Dispose()
    }
}

function Compress-GZipFile {
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }

    $inputStream = [System.IO.File]::OpenRead($InputPath)
    try {
        $outputStream = [System.IO.File]::Create($OutputPath)
        try {
            $gzipStream = New-Object System.IO.Compression.GZipStream($outputStream, [System.IO.Compression.CompressionLevel]::Optimal)
            try {
                $inputStream.CopyTo($gzipStream)
            }
            finally {
                $gzipStream.Dispose()
            }
        }
        finally {
            $outputStream.Dispose()
        }
    }
    finally {
        $inputStream.Dispose()
    }
}

function New-XmlNamespaceManager {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Document,
        [Parameter(Mandatory = $true)][hashtable]$Namespaces
    )

    $manager = New-Object System.Xml.XmlNamespaceManager($Document.NameTable)
    foreach ($key in $Namespaces.Keys) {
        $manager.AddNamespace($key, $Namespaces[$key])
    }
    return ,$manager
}

function Add-IndexValue {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Index,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)]$Value
    )

    if (-not $Index.ContainsKey($Key)) {
        $Index[$Key] = New-Object System.Collections.ArrayList
    }
    [void]$Index[$Key].Add($Value)
}

function Get-XmlChildText {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlNode]$Node,
        [Parameter(Mandatory = $true)][string]$XPath,
        [Parameter(Mandatory = $true)][System.Xml.XmlNamespaceManager]$NamespaceManager
    )

    $child = $Node.SelectSingleNode($XPath, $NamespaceManager)
    if ($null -eq $child) {
        return ''
    }
    return $child.InnerText
}

function Get-XmlChildAttribute {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlNode]$Node,
        [Parameter(Mandatory = $true)][string]$XPath,
        [Parameter(Mandatory = $true)][string]$AttributeName,
        [Parameter(Mandatory = $true)][System.Xml.XmlNamespaceManager]$NamespaceManager
    )

    $child = $Node.SelectSingleNode($XPath, $NamespaceManager)
    if ($null -eq $child) {
        return ''
    }
    return $child.GetAttribute($AttributeName)
}

function New-RpmEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Flags = '',
        [string]$Epoch = '',
        [string]$Version = '',
        [string]$Release = '',
        [string]$Kind = 'dependency'
    )

    return [pscustomobject]@{
        Name    = $Name
        Flags   = $Flags
        Epoch   = $Epoch
        Version = $Version
        Release = $Release
        Kind    = $Kind
    }
}

function ConvertTo-RpmEntryList {
    param(
        [System.Xml.XmlNode]$ContainerNode,
        [string]$Kind = 'dependency'
    )

    $entries = New-Object System.Collections.ArrayList
    if ($null -eq $ContainerNode) {
        return ,$entries
    }

    foreach ($entryNode in $ContainerNode.ChildNodes) {
        if ($entryNode.NodeType -ne [System.Xml.XmlNodeType]::Element) {
            continue
        }
        if ($entryNode.LocalName -ne 'entry') {
            continue
        }

        $name = $entryNode.GetAttribute('name')
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        [void]$entries.Add((New-RpmEntry `
            -Name $name `
            -Flags $entryNode.GetAttribute('flags') `
            -Epoch $entryNode.GetAttribute('epoch') `
            -Version $entryNode.GetAttribute('ver') `
            -Release $entryNode.GetAttribute('rel') `
            -Kind $Kind))
    }

    return ,$entries
}

function Get-RpmFileName {
    param([Parameter(Mandatory = $true)][string]$Href)

    $normalized = $Href -replace '\\', '/'
    return ($normalized.Split('/') | Select-Object -Last 1)
}

function Get-ArtifactKey {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Epoch = '0',
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Release,
        [Parameter(Mandatory = $true)][string]$Arch
    )

    if ([string]::IsNullOrWhiteSpace($Epoch)) {
        $Epoch = '0'
    }
    return "$Name|$Epoch|$Version|$Release|$Arch"
}

function Get-Nevra {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Epoch = '0',
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Release,
        [Parameter(Mandatory = $true)][string]$Arch
    )

    if ([string]::IsNullOrWhiteSpace($Epoch)) {
        $Epoch = '0'
    }
    return "$Name-$Epoch`:$Version-$Release.$Arch"
}

function ConvertFrom-ModuleArtifact {
    param([Parameter(Mandatory = $true)][string]$Artifact)

    $artifactText = $Artifact.Trim().Trim("'").Trim('"')
    $lastDot = $artifactText.LastIndexOf('.')
    if ($lastDot -lt 1) {
        return $null
    }

    $archPart = $artifactText.Substring($lastDot + 1)
    $withoutArch = $artifactText.Substring(0, $lastDot)
    $lastDash = $withoutArch.LastIndexOf('-')
    if ($lastDash -lt 1) {
        return $null
    }

    $release = $withoutArch.Substring($lastDash + 1)
    $nameEpochVersion = $withoutArch.Substring(0, $lastDash)
    $nameDash = $nameEpochVersion.LastIndexOf('-')
    if ($nameDash -lt 1) {
        return $null
    }

    $name = $nameEpochVersion.Substring(0, $nameDash)
    $epochVersion = $nameEpochVersion.Substring($nameDash + 1)
    $colon = $epochVersion.IndexOf(':')
    if ($colon -lt 0) {
        $epoch = '0'
        $version = $epochVersion
    }
    else {
        $epoch = $epochVersion.Substring(0, $colon)
        $version = $epochVersion.Substring($colon + 1)
    }

    return [pscustomobject]@{
        Name       = $name
        Epoch      = $epoch
        Version    = $version
        Release    = $release
        Arch       = $archPart
        Artifact   = $artifactText
        ArtifactKey = Get-ArtifactKey -Name $name -Epoch $epoch -Version $version -Release $release -Arch $archPart
    }
}

function Parse-ModuleProfilePackages {
    param(
        [Parameter(Mandatory = $true)][string]$DocumentText,
        [Parameter(Mandatory = $true)][string]$ProfileName
    )

    $packages = New-Object System.Collections.ArrayList
    $lines = $DocumentText -split "`r?`n"
    $inProfiles = $false
    $inTargetProfile = $false
    $inRpms = $false
    $profilesIndent = -1
    $profileIndent = -1
    $rpmIndent = -1

    foreach ($line in $lines) {
        if ($line -match '^(\s*)profiles:\s*$') {
            $inProfiles = $true
            $inTargetProfile = $false
            $inRpms = $false
            $profilesIndent = $matches[1].Length
            continue
        }

        if (-not $inProfiles) {
            continue
        }

        $currentIndent = 0
        if ($line -match '^(\s*)') {
            $currentIndent = $matches[1].Length
        }

        if ($line.Trim().Length -gt 0 -and $currentIndent -le $profilesIndent) {
            break
        }

        $profilePattern = '^\s{' + ($profilesIndent + 2) + '}([^:\s]+):\s*$'
        if ($line -match $profilePattern) {
            $inTargetProfile = ($matches[1] -eq $ProfileName)
            $inRpms = $false
            $profileIndent = $profilesIndent + 2
            continue
        }

        if (-not $inTargetProfile) {
            continue
        }

        if ($line.Trim().Length -gt 0 -and $currentIndent -le $profileIndent) {
            $inTargetProfile = $false
            $inRpms = $false
            continue
        }

        if ($line -match '^\s*rpms:\s*$') {
            $inRpms = $true
            $rpmIndent = $currentIndent
            continue
        }

        if ($inRpms -and $line.Trim().Length -gt 0 -and $currentIndent -le $rpmIndent) {
            $inRpms = $false
            continue
        }

        if ($inRpms -and $line -match '^\s*-\s+(.+?)\s*$') {
            $packageName = $matches[1].Trim().Trim("'").Trim('"')
            if ($packageName) {
                [void]$packages.Add($packageName)
            }
        }
    }

    return ,$packages
}

function Parse-ModuleStreamSpec {
    param([Parameter(Mandatory = $true)][string]$Spec)

    $separator = $Spec.IndexOf(':')
    if ($separator -lt 1) {
        throw "Module stream '$Spec' must use name:stream format, for example nodejs:20."
    }

    return [pscustomobject]@{
        Name   = $Spec.Substring(0, $separator)
        Stream = $Spec.Substring($separator + 1)
        Key    = $Spec
    }
}

function Parse-ModuleProfileSpec {
    param([Parameter(Mandatory = $true)][string]$Spec)

    $modulePart = ''
    $profilePart = ''
    if ($Spec.Contains('/')) {
        $pieces = $Spec.Split('/', 2)
        $modulePart = $pieces[0]
        $profilePart = $pieces[1]
    }
    else {
        $lastColon = $Spec.LastIndexOf(':')
        if ($lastColon -lt 1) {
            throw "Module profile '$Spec' must use name:stream/profile or name:stream:profile format."
        }
        $modulePart = $Spec.Substring(0, $lastColon)
        $profilePart = $Spec.Substring($lastColon + 1)
    }

    $streamSpec = Parse-ModuleStreamSpec -Spec $modulePart
    return [pscustomobject]@{
        Name    = $streamSpec.Name
        Stream  = $streamSpec.Stream
        Profile = $profilePart
        Key     = "$($streamSpec.Name):$($streamSpec.Stream)"
    }
}

function Initialize-ModuleStreamSelection {
    foreach ($spec in $ModuleStream) {
        $parsed = Parse-ModuleStreamSpec -Spec $spec
        $script:EnabledModuleStreams[$parsed.Key] = $parsed
    }

    foreach ($spec in $ModuleProfile) {
        $parsed = Parse-ModuleProfileSpec -Spec $spec
        $script:EnabledModuleStreams[$parsed.Key] = [pscustomobject]@{
            Name   = $parsed.Name
            Stream = $parsed.Stream
            Key    = $parsed.Key
        }
    }
}

function New-RepoObject {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [int]$Priority = 50
    )

    return [pscustomobject]@{
        Id                = (ConvertTo-SafeName -Value $Id)
        Name              = $Name
        BaseUrl           = $BaseUrl.TrimEnd('/') + '/'
        Priority          = $Priority
        CacheDirectory    = ''
        RepomdPath        = ''
        Repomd            = $null
        MetadataEntries   = @{}
        PrimaryXmlPath    = ''
        FilelistsXmlPath  = ''
        ModulesYamlPath   = ''
        RawModulesGzPath  = ''
        HasFilelists      = $false
        HasModules        = $false
    }
}

function Get-PresetRepositories {
    $repos = New-Object System.Collections.ArrayList

    if ($Provider -eq 'AlmaLinux') {
        [void]$repos.Add((New-RepoObject -Id 'almalinux-baseos' -Name 'AlmaLinux 9 BaseOS' -BaseUrl "https://repo.almalinux.org/almalinux/$Releasever/BaseOS/$Arch/os/" -Priority 10))
        [void]$repos.Add((New-RepoObject -Id 'almalinux-appstream' -Name 'AlmaLinux 9 AppStream' -BaseUrl "https://repo.almalinux.org/almalinux/$Releasever/AppStream/$Arch/os/" -Priority 20))
        [void]$repos.Add((New-RepoObject -Id 'almalinux-crb' -Name 'AlmaLinux 9 CRB' -BaseUrl "https://repo.almalinux.org/almalinux/$Releasever/CRB/$Arch/os/" -Priority 30))
        if ($IncludeExtras) {
            [void]$repos.Add((New-RepoObject -Id 'almalinux-extras' -Name 'AlmaLinux 9 Extras' -BaseUrl "https://repo.almalinux.org/almalinux/$Releasever/extras/$Arch/os/" -Priority 40))
        }
    }
    elseif ($Provider -eq 'RockyLinux') {
        [void]$repos.Add((New-RepoObject -Id 'rocky-baseos' -Name 'Rocky Linux 9 BaseOS' -BaseUrl "https://dl.rockylinux.org/pub/rocky/$Releasever/BaseOS/$Arch/os/" -Priority 10))
        [void]$repos.Add((New-RepoObject -Id 'rocky-appstream' -Name 'Rocky Linux 9 AppStream' -BaseUrl "https://dl.rockylinux.org/pub/rocky/$Releasever/AppStream/$Arch/os/" -Priority 20))
        [void]$repos.Add((New-RepoObject -Id 'rocky-crb' -Name 'Rocky Linux 9 CRB' -BaseUrl "https://dl.rockylinux.org/pub/rocky/$Releasever/CRB/$Arch/os/" -Priority 30))
        if ($IncludeExtras) {
            [void]$repos.Add((New-RepoObject -Id 'rocky-extras' -Name 'Rocky Linux 9 Extras' -BaseUrl "https://dl.rockylinux.org/pub/rocky/$Releasever/extras/$Arch/os/" -Priority 40))
        }
    }
    elseif ($Provider -eq 'OracleLinux') {
        [void]$repos.Add((New-RepoObject -Id 'ol9-baseos' -Name 'Oracle Linux 9 BaseOS Latest' -BaseUrl "https://yum.oracle.com/repo/OracleLinux/OL$Releasever/baseos/latest/$Arch/" -Priority 10))
        [void]$repos.Add((New-RepoObject -Id 'ol9-appstream' -Name 'Oracle Linux 9 AppStream' -BaseUrl "https://yum.oracle.com/repo/OracleLinux/OL$Releasever/appstream/$Arch/" -Priority 20))
        [void]$repos.Add((New-RepoObject -Id 'ol9-codeready-builder' -Name 'Oracle Linux 9 CodeReady Builder' -BaseUrl "https://yum.oracle.com/repo/OracleLinux/OL$Releasever/codeready/builder/$Arch/" -Priority 30))
        if ($IncludeExtras) {
            [void]$repos.Add((New-RepoObject -Id 'ol9-addons' -Name 'Oracle Linux 9 Addons' -BaseUrl "https://yum.oracle.com/repo/OracleLinux/OL$Releasever/addons/$Arch/" -Priority 40))
        }
    }

    if ($IncludeEpel) {
        [void]$repos.Add((New-RepoObject -Id 'ol9-developer-epel' -Name 'Oracle Linux 9 Developer EPEL' -BaseUrl "https://yum.oracle.com/repo/OracleLinux/OL$Releasever/developer/EPEL/$Arch/" -Priority 80))
    }

    return ,$repos
}

function ConvertFrom-CustomRepository {
    param(
        [Parameter(Mandatory = $true)][string]$Spec,
        [Parameter(Mandatory = $true)][int]$Index
    )

    $id = "custom-$Index"
    $url = $Spec
    $equals = $Spec.IndexOf('=')
    if ($equals -gt 0) {
        $id = $Spec.Substring(0, $equals)
        $url = $Spec.Substring($equals + 1)
    }

    if ($url -notmatch '^https?://') {
        throw "Repository '$Spec' must use an http:// or https:// URL."
    }

    return New-RepoObject -Id $id -Name $id -BaseUrl $url -Priority (100 + $Index)
}

function Get-ConfiguredRepositories {
    $repos = New-Object System.Collections.ArrayList

    if (-not $NoDefaultRepositories) {
        foreach ($repo in (Get-PresetRepositories)) {
            [void]$repos.Add($repo)
        }
    }

    $index = 0
    foreach ($repositoryValue in $Repository) {
        foreach ($spec in ($repositoryValue -split ',')) {
            if ([string]::IsNullOrWhiteSpace($spec)) {
                continue
            }
            $index++
            [void]$repos.Add((ConvertFrom-CustomRepository -Spec $spec.Trim() -Index $index))
        }
    }

    if ($repos.Count -eq 0) {
        throw "No repositories configured. Remove -NoDefaultRepositories or pass -Repository id=https://repo/base/url/."
    }

    return ,$repos
}

function Get-RepodataEntry {
    param(
        [Parameter(Mandatory = $true)]$Repo,
        [Parameter(Mandatory = $true)][string]$Type,
        [switch]$Required
    )

    $doc = $Repo.Repomd
    $ns = New-XmlNamespaceManager -Document $doc -Namespaces @{
        repo = 'http://linux.duke.edu/metadata/repo'
    }

    $nodes = $doc.SelectNodes("/repo:repomd/repo:data[@type='$Type']", $ns)
    foreach ($node in $nodes) {
        $location = $node.SelectSingleNode('repo:location', $ns)
        if ($null -eq $location) {
            continue
        }
        $href = $location.GetAttribute('href')
        if ([string]::IsNullOrWhiteSpace($href)) {
            continue
        }

        if (($Type -eq 'primary' -or $Type -eq 'filelists' -or $Type -eq 'other') -and ($href -notmatch '\.xml\.gz$')) {
            continue
        }
        if ($Type -eq 'modules' -and ($href -notmatch '\.ya?ml\.gz$')) {
            continue
        }

        $checksum = $node.SelectSingleNode('repo:checksum', $ns)
        $openChecksum = $node.SelectSingleNode('repo:open-checksum', $ns)
        $timestamp = $node.SelectSingleNode('repo:timestamp', $ns)
        $size = $node.SelectSingleNode('repo:size', $ns)
        $openSize = $node.SelectSingleNode('repo:open-size', $ns)

        return [pscustomobject]@{
            Type             = $Type
            Href             = $href
            Checksum         = if ($checksum) { $checksum.InnerText } else { '' }
            ChecksumType     = if ($checksum) { $checksum.GetAttribute('type') } else { 'sha256' }
            OpenChecksum     = if ($openChecksum) { $openChecksum.InnerText } else { '' }
            OpenChecksumType = if ($openChecksum) { $openChecksum.GetAttribute('type') } else { 'sha256' }
            Timestamp        = if ($timestamp) { $timestamp.InnerText } else { '' }
            Size             = if ($size) { $size.InnerText } else { '' }
            OpenSize         = if ($openSize) { $openSize.InnerText } else { '' }
        }
    }

    if ($Required) {
        throw "Repository '$($Repo.Id)' does not expose $Type XML gzip metadata. This pure PowerShell script can read .xml.gz/.yaml.gz metadata, but not xz, zstd, bzip2, or sqlite metadata."
    }

    return $null
}

function Read-RepositoryMetadata {
    param(
        [Parameter(Mandatory = $true)]$Repo,
        [Parameter(Mandatory = $true)][string]$CacheRoot
    )

    $Repo.CacheDirectory = Join-Path $CacheRoot $Repo.Id
    New-Directory -Path $Repo.CacheDirectory

    $Repo.RepomdPath = Join-Path $Repo.CacheDirectory 'repomd.xml'
    Invoke-HttpDownload -Uri (Join-Url -Base $Repo.BaseUrl -Path 'repodata/repomd.xml') -OutFile $Repo.RepomdPath -Overwrite:$Force

    $repomdDocument = New-Object System.Xml.XmlDocument
    $repomdDocument.Load($Repo.RepomdPath)
    $Repo.Repomd = $repomdDocument

    $primary = Get-RepodataEntry -Repo $Repo -Type 'primary' -Required
    $Repo.MetadataEntries['primary'] = $primary
    $primaryGz = Join-Path $Repo.CacheDirectory (Get-RpmFileName -Href $primary.Href)
    Invoke-HttpDownload -Uri (Join-Url -Base $Repo.BaseUrl -Path $primary.Href) -OutFile $primaryGz -Overwrite:$Force
    if ($primary.Checksum) {
        $actual = Get-FileHashText -Path $primaryGz -Algorithm $primary.ChecksumType
        if ($actual -ne $primary.Checksum.ToLowerInvariant()) {
            throw "Checksum mismatch for $($Repo.Id) primary metadata."
        }
    }
    $Repo.PrimaryXmlPath = Join-Path $Repo.CacheDirectory 'primary.xml'
    Expand-GZipFile -InputPath $primaryGz -OutputPath $Repo.PrimaryXmlPath

    $filelists = Get-RepodataEntry -Repo $Repo -Type 'filelists'
    if ($filelists -and -not $SkipFilelists) {
        $Repo.MetadataEntries['filelists'] = $filelists
        $filelistsGz = Join-Path $Repo.CacheDirectory (Get-RpmFileName -Href $filelists.Href)
        Invoke-HttpDownload -Uri (Join-Url -Base $Repo.BaseUrl -Path $filelists.Href) -OutFile $filelistsGz -Overwrite:$Force
        if ($filelists.Checksum) {
            $actual = Get-FileHashText -Path $filelistsGz -Algorithm $filelists.ChecksumType
            if ($actual -ne $filelists.Checksum.ToLowerInvariant()) {
                throw "Checksum mismatch for $($Repo.Id) filelists metadata."
            }
        }
        $Repo.FilelistsXmlPath = Join-Path $Repo.CacheDirectory 'filelists.xml'
        $Repo.HasFilelists = $true
    }

    $modules = Get-RepodataEntry -Repo $Repo -Type 'modules'
    if ($modules) {
        $Repo.MetadataEntries['modules'] = $modules
        $modulesGz = Join-Path $Repo.CacheDirectory (Get-RpmFileName -Href $modules.Href)
        Invoke-HttpDownload -Uri (Join-Url -Base $Repo.BaseUrl -Path $modules.Href) -OutFile $modulesGz -Overwrite:$Force
        if ($modules.Checksum) {
            $actual = Get-FileHashText -Path $modulesGz -Algorithm $modules.ChecksumType
            if ($actual -ne $modules.Checksum.ToLowerInvariant()) {
                throw "Checksum mismatch for $($Repo.Id) modules metadata."
            }
        }
        $Repo.RawModulesGzPath = $modulesGz
        $Repo.ModulesYamlPath = Join-Path $Repo.CacheDirectory 'modules.yaml'
        Expand-GZipFile -InputPath $modulesGz -OutputPath $Repo.ModulesYamlPath
        $Repo.HasModules = $true
    }
}

function Add-ProvideRecord {
    param(
        [Parameter(Mandatory = $true)]$PackageObject,
        [Parameter(Mandatory = $true)]$Entry,
        [switch]$FileProvide
    )

    $record = [pscustomobject]@{
        Name    = $Entry.Name
        Flags   = $Entry.Flags
        Epoch   = $Entry.Epoch
        Version = $Entry.Version
        Release = $Entry.Release
        Package = $PackageObject
    }

    if ($FileProvide) {
        Add-IndexValue -Index $script:FileProvidesByName -Key $Entry.Name -Value $record
    }
    else {
        Add-IndexValue -Index $script:ProvidesByName -Key $Entry.Name -Value $record
    }
}

function Test-SkipRpmCapabilityForIndex {
    param([AllowNull()][string]$Name)

    if ($IncludeKernelCapabilities) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $true
    }

    return ($Name -match '^(kernel|modalias|kmod|firmware|iucode_rev|iucode_date)\(')
}

function Read-PrimaryPackageFromCurrentReader {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlReader]$Reader,
        [Parameter(Mandatory = $true)]$Repo
    )

    $name = ''
    $arch = ''
    $epoch = '0'
    $version = ''
    $release = ''
    $checksum = ''
    $checksumType = 'sha256'
    $locationHref = ''
    $provides = New-Object System.Collections.ArrayList
    $requires = New-Object System.Collections.ArrayList
    $weakRequires = New-Object System.Collections.ArrayList
    $primaryFiles = New-Object System.Collections.ArrayList
    $entryContainer = ''

    [void]$Reader.Read()
    while (-not $Reader.EOF) {
        if ($Reader.NodeType -eq [System.Xml.XmlNodeType]::EndElement) {
            if ($Reader.LocalName -eq 'package') {
                [void]$Reader.Read()
                break
            }

            if (@('provides', 'requires', 'recommends', 'suggests', 'supplements', 'enhances') -contains $Reader.LocalName) {
                $entryContainer = ''
            }

            [void]$Reader.Read()
            continue
        }

        if ($Reader.NodeType -ne [System.Xml.XmlNodeType]::Element) {
            [void]$Reader.Read()
            continue
        }

        if ($Reader.NamespaceURI -eq 'http://linux.duke.edu/metadata/common') {
            if ($Reader.LocalName -eq 'name') {
                $name = $Reader.ReadElementContentAsString()
                continue
            }
            elseif ($Reader.LocalName -eq 'arch') {
                $arch = $Reader.ReadElementContentAsString()
                continue
            }
            elseif ($Reader.LocalName -eq 'version') {
                $epochValue = $Reader.GetAttribute('epoch')
                if (-not [string]::IsNullOrWhiteSpace($epochValue)) {
                    $epoch = $epochValue
                }
                $version = $Reader.GetAttribute('ver')
                $release = $Reader.GetAttribute('rel')
                [void]$Reader.Read()
                continue
            }
            elseif ($Reader.LocalName -eq 'checksum') {
                $typeValue = $Reader.GetAttribute('type')
                if (-not [string]::IsNullOrWhiteSpace($typeValue)) {
                    $checksumType = $typeValue
                }
                $checksum = $Reader.ReadElementContentAsString().Trim()
                continue
            }
            elseif ($Reader.LocalName -eq 'location') {
                $locationHref = $Reader.GetAttribute('href')
                [void]$Reader.Read()
                continue
            }
            elseif ($Reader.LocalName -eq 'file') {
                $fileType = $Reader.GetAttribute('type')
                $filePath = $Reader.ReadElementContentAsString()
                if ($filePath) {
                    [void]$primaryFiles.Add([pscustomobject]@{
                        Path = $filePath
                        Type = $fileType
                    })
                }
                continue
            }

            [void]$Reader.Read()
            continue
        }

        if ($Reader.NamespaceURI -eq 'http://linux.duke.edu/metadata/rpm') {
            if ($Reader.LocalName -eq 'provides') {
                $entryContainer = 'provide'
                [void]$Reader.Read()
                continue
            }
            elseif ($Reader.LocalName -eq 'requires') {
                $entryContainer = 'requires'
                [void]$Reader.Read()
                continue
            }
            elseif (@('recommends', 'suggests', 'supplements', 'enhances') -contains $Reader.LocalName) {
                $entryContainer = $Reader.LocalName
                [void]$Reader.Read()
                continue
            }
            elseif ($Reader.LocalName -eq 'entry') {
                if ($entryContainer) {
                    $entryName = $Reader.GetAttribute('name')
                    if (-not (Test-SkipRpmCapabilityForIndex -Name $entryName)) {
                        $entry = New-RpmEntry `
                            -Name $entryName `
                            -Flags $Reader.GetAttribute('flags') `
                            -Epoch $Reader.GetAttribute('epoch') `
                            -Version $Reader.GetAttribute('ver') `
                            -Release $Reader.GetAttribute('rel') `
                            -Kind $entryContainer

                        if ($entryContainer -eq 'provide') {
                            [void]$provides.Add($entry)
                        }
                        elseif ($entryContainer -eq 'requires') {
                            [void]$requires.Add($entry)
                        }
                        else {
                            [void]$weakRequires.Add($entry)
                        }
                    }
                }
                [void]$Reader.Read()
                continue
            }

            [void]$Reader.Read()
            continue
        }

        [void]$Reader.Read()
    }

    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($checksum) -or [string]::IsNullOrWhiteSpace($locationHref)) {
        return $null
    }

    if ($arch -ne $script:TargetArch -and $arch -ne 'noarch') {
        return $null
    }

    $artifactKey = Get-ArtifactKey -Name $name -Epoch $epoch -Version $version -Release $release -Arch $arch
    $nevra = Get-Nevra -Name $name -Epoch $epoch -Version $version -Release $release -Arch $arch
    $fileName = Get-RpmFileName -Href $locationHref
    $localRelativePath = ('packages/{0}/{1}' -f $Repo.Id, $fileName)

    return [pscustomobject]@{
        Id                = $checksum
        ChecksumType      = $checksumType
        Name              = $name
        Arch              = $arch
        Epoch             = $epoch
        Version           = $version
        Release           = $release
        Nevra             = $nevra
        ArtifactKey       = $artifactKey
        RepoId            = $Repo.Id
        RepoName          = $Repo.Name
        RepoBaseUrl       = $Repo.BaseUrl
        RepoPriority      = $Repo.Priority
        LocationHref      = $locationHref
        LocationUrl       = Join-Url -Base $Repo.BaseUrl -Path $locationHref
        LocalRelativePath = $localRelativePath
        LocalPath         = Join-Path $OutputDirectory ($localRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        PrimaryNode       = $null
        PrimaryXmlPath    = $Repo.PrimaryXmlPath
        Provides          = $provides
        Requires          = $requires
        WeakRequires      = $weakRequires
        Files             = $primaryFiles
    }
}

function Add-PackageToIndexes {
    param([Parameter(Mandatory = $true)]$PackageObject)

    if ($script:PackagesById.ContainsKey($PackageObject.Id)) {
        return
    }

    $script:PackagesById[$PackageObject.Id] = $PackageObject
    Add-IndexValue -Index $script:PackagesByName -Key $PackageObject.Name -Value $PackageObject
    [void]$script:AllPackages.Add($PackageObject)

    foreach ($provide in $PackageObject.Provides) {
        Add-ProvideRecord -PackageObject $PackageObject -Entry $provide
    }

    $selfProvide = New-RpmEntry -Name $PackageObject.Name -Flags 'EQ' -Epoch $PackageObject.Epoch -Version $PackageObject.Version -Release $PackageObject.Release -Kind 'provide'
    Add-ProvideRecord -PackageObject $PackageObject -Entry $selfProvide

    foreach ($fileRecord in $PackageObject.Files) {
        $fileEntry = New-RpmEntry -Name $fileRecord.Path -Kind 'file'
        Add-ProvideRecord -PackageObject $PackageObject -Entry $fileEntry -FileProvide
    }
}

function Import-PrimaryMetadata {
    param([Parameter(Mandatory = $true)]$Repo)

    Write-Host "Indexing primary metadata: $($Repo.Id)"
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.IgnoreComments = $true
    $settings.IgnoreWhitespace = $true

    $reader = [System.Xml.XmlReader]::Create($Repo.PrimaryXmlPath, $settings)
    try {
        [void]$reader.Read()
        while (-not $reader.EOF) {
            if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element -or $reader.LocalName -ne 'package') {
                [void]$reader.Read()
                continue
            }

            $packageObject = Read-PrimaryPackageFromCurrentReader -Reader $reader -Repo $Repo
            if ($packageObject) {
                Add-PackageToIndexes -PackageObject $packageObject
            }
        }
    }
    finally {
        $reader.Dispose()
    }
}

function Add-PackageFile {
    param(
        [Parameter(Mandatory = $true)]$PackageObject,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Type = ''
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    foreach ($existing in $PackageObject.Files) {
        if ($existing.Path -eq $Path -and $existing.Type -eq $Type) {
            return
        }
    }

    $record = [pscustomobject]@{
        Path = $Path
        Type = $Type
    }
    [void]$PackageObject.Files.Add($record)
    $entry = New-RpmEntry -Name $Path -Kind 'file'
    Add-ProvideRecord -PackageObject $PackageObject -Entry $entry -FileProvide
}

function Import-FilelistsMetadata {
    param([Parameter(Mandatory = $true)]$Repo)

    if (-not $Repo.HasFilelists) {
        Write-Warning "Repository '$($Repo.Id)' has no readable filelists.xml.gz metadata; file path dependencies may not resolve."
        return
    }

    if (-not (Test-Path -LiteralPath $Repo.FilelistsXmlPath)) {
        $entry = $Repo.MetadataEntries['filelists']
        $gzPath = Join-Path $Repo.CacheDirectory (Get-RpmFileName -Href $entry.Href)
        Write-Host "Expanding filelists metadata: $($Repo.Id)"
        Expand-GZipFile -InputPath $gzPath -OutputPath $Repo.FilelistsXmlPath
    }

    Write-Host "Indexing file path provides: $($Repo.Id)"
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.IgnoreComments = $true
    $settings.IgnoreWhitespace = $true

    $reader = [System.Xml.XmlReader]::Create($Repo.FilelistsXmlPath, $settings)
    try {
        $currentPackage = $null
        while ($reader.Read()) {
            if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element) {
                continue
            }

            if ($reader.LocalName -eq 'package') {
                $pkgid = $reader.GetAttribute('pkgid')
                if ($pkgid -and $script:PackagesById.ContainsKey($pkgid)) {
                    $currentPackage = $script:PackagesById[$pkgid]
                }
                else {
                    $currentPackage = $null
                }
                continue
            }

            if ($reader.LocalName -eq 'file' -and $currentPackage) {
                $type = $reader.GetAttribute('type')
                $path = $reader.ReadElementContentAsString()
                Add-PackageFile -PackageObject $currentPackage -Path $path -Type $type
            }
        }
    }
    finally {
        $reader.Dispose()
    }
}

function Import-ModuleMetadata {
    param([Parameter(Mandatory = $true)]$Repo)

    if (-not $Repo.HasModules) {
        return
    }

    Write-Host "Indexing module metadata: $($Repo.Id)"
    $text = Get-Content -LiteralPath $Repo.ModulesYamlPath -Raw
    $documents = [regex]::Split($text, '(?m)^---\s*$')

    foreach ($document in $documents) {
        if ($document -notmatch '(?m)^\s*document:\s+modulemd\s*$') {
            continue
        }

        $name = ''
        $stream = ''
        $version = ''
        $context = ''
        $moduleArch = ''

        if ($document -match '(?m)^\s*name:\s*["'']?([^"''\r\n]+)["'']?\s*$') {
            $name = $matches[1].Trim()
        }
        if ($document -match '(?m)^\s*stream:\s*["'']?([^"''\r\n]+)["'']?\s*$') {
            $stream = $matches[1].Trim()
        }
        if ($document -match '(?m)^\s*version:\s*["'']?([^"''\r\n]+)["'']?\s*$') {
            $version = $matches[1].Trim()
        }
        if ($document -match '(?m)^\s*context:\s*["'']?([^"''\r\n]+)["'']?\s*$') {
            $context = $matches[1].Trim()
        }
        if ($document -match '(?m)^\s*arch:\s*["'']?([^"''\r\n]+)["'']?\s*$') {
            $moduleArch = $matches[1].Trim()
        }

        if (-not $name -or -not $stream) {
            continue
        }

        $artifacts = New-Object System.Collections.ArrayList
        foreach ($match in [regex]::Matches($document, '(?m)^\s*-\s+([A-Za-z0-9_.+~-]+-\d+:[^\s]+?\.(?:x86_64|aarch64|ppc64le|s390x|noarch))\s*$')) {
            $artifact = ConvertFrom-ModuleArtifact -Artifact $match.Groups[1].Value
            if ($artifact) {
                [void]$artifacts.Add($artifact)
                $script:AllModuleArtifactKeys[$artifact.ArtifactKey] = $true
                $script:AllModuleArtifactNames[$artifact.Name] = $true
            }
        }

        $record = [pscustomobject]@{
            RepoId    = $Repo.Id
            Name      = $name
            Stream    = $stream
            Version   = $version
            Context   = $context
            Arch      = $moduleArch
            Key       = "$name`:$stream"
            Artifacts = $artifacts
            RawText   = $document.Trim()
        }

        [void]$script:ModuleRecords.Add($record)

        if ($script:EnabledModuleStreams.ContainsKey($record.Key)) {
            foreach ($artifact in $artifacts) {
                $script:EnabledModuleArtifactKeys[$artifact.ArtifactKey] = $true
            }
        }
    }
}

function Add-ModuleProfileRoots {
    param([System.Collections.ArrayList]$RootPackages)

    foreach ($spec in $ModuleProfile) {
        $parsed = Parse-ModuleProfileSpec -Spec $spec
        $matchingRecords = @($script:ModuleRecords | Where-Object { $_.Name -eq $parsed.Name -and $_.Stream -eq $parsed.Stream })
        if ($matchingRecords.Count -eq 0) {
            throw "Module profile '$spec' was requested, but module stream $($parsed.Name):$($parsed.Stream) was not found in the configured repositories."
        }

        $profilePackages = New-Object System.Collections.ArrayList
        foreach ($record in $matchingRecords) {
            $fromRecord = Parse-ModuleProfilePackages -DocumentText $record.RawText -ProfileName $parsed.Profile
            foreach ($packageName in $fromRecord) {
                if (-not $profilePackages.Contains($packageName)) {
                    [void]$profilePackages.Add($packageName)
                }
            }
        }

        if ($profilePackages.Count -eq 0) {
            throw "Module profile '$spec' did not list any RPM package names in module metadata."
        }

        foreach ($packageName in $profilePackages) {
            if (-not $RootPackages.Contains($packageName)) {
                [void]$RootPackages.Add($packageName)
            }
        }
    }
}

function Compare-RpmVersion {
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right
    )

    if ($null -eq $Left) { $Left = '' }
    if ($null -eq $Right) { $Right = '' }

    $i = 0
    $j = 0
    while ($i -lt $Left.Length -or $j -lt $Right.Length) {
        if ($i -lt $Left.Length -and $Left[$i] -eq '~') {
            if ($j -lt $Right.Length -and $Right[$j] -eq '~') {
                $i++
                $j++
                continue
            }
            return -1
        }
        if ($j -lt $Right.Length -and $Right[$j] -eq '~') {
            return 1
        }

        if ($i -lt $Left.Length -and $Left[$i] -eq '^') {
            if ($j -lt $Right.Length -and $Right[$j] -eq '^') {
                $i++
                $j++
                continue
            }
            if ($j -ge $Right.Length) {
                return 1
            }
            return -1
        }
        if ($j -lt $Right.Length -and $Right[$j] -eq '^') {
            if ($i -ge $Left.Length) {
                return -1
            }
            return 1
        }

        while ($i -lt $Left.Length -and -not [char]::IsLetterOrDigit($Left[$i]) -and $Left[$i] -ne '~' -and $Left[$i] -ne '^') {
            $i++
        }
        while ($j -lt $Right.Length -and -not [char]::IsLetterOrDigit($Right[$j]) -and $Right[$j] -ne '~' -and $Right[$j] -ne '^') {
            $j++
        }

        if ($i -ge $Left.Length -and $j -ge $Right.Length) {
            return 0
        }
        if ($i -ge $Left.Length) {
            return -1
        }
        if ($j -ge $Right.Length) {
            return 1
        }

        $leftNumeric = [char]::IsDigit($Left[$i])
        $rightNumeric = [char]::IsDigit($Right[$j])
        if ($leftNumeric -and -not $rightNumeric) {
            return 1
        }
        if (-not $leftNumeric -and $rightNumeric) {
            return -1
        }

        $leftStart = $i
        if ($leftNumeric) {
            while ($i -lt $Left.Length -and [char]::IsDigit($Left[$i])) { $i++ }
        }
        else {
            while ($i -lt $Left.Length -and [char]::IsLetter($Left[$i])) { $i++ }
        }
        $leftSegment = $Left.Substring($leftStart, $i - $leftStart)

        $rightStart = $j
        if ($rightNumeric) {
            while ($j -lt $Right.Length -and [char]::IsDigit($Right[$j])) { $j++ }
        }
        else {
            while ($j -lt $Right.Length -and [char]::IsLetter($Right[$j])) { $j++ }
        }
        $rightSegment = $Right.Substring($rightStart, $j - $rightStart)

        if ($leftNumeric) {
            $leftTrimmed = $leftSegment.TrimStart('0')
            $rightTrimmed = $rightSegment.TrimStart('0')
            if ($leftTrimmed.Length -eq 0) { $leftTrimmed = '0' }
            if ($rightTrimmed.Length -eq 0) { $rightTrimmed = '0' }

            if ($leftTrimmed.Length -gt $rightTrimmed.Length) { return 1 }
            if ($leftTrimmed.Length -lt $rightTrimmed.Length) { return -1 }

            $numericCompare = [string]::CompareOrdinal($leftTrimmed, $rightTrimmed)
            if ($numericCompare -gt 0) { return 1 }
            if ($numericCompare -lt 0) { return -1 }
        }
        else {
            $alphaCompare = [string]::CompareOrdinal($leftSegment, $rightSegment)
            if ($alphaCompare -gt 0) { return 1 }
            if ($alphaCompare -lt 0) { return -1 }
        }
    }

    return 0
}

function Compare-Evr {
    param(
        [string]$LeftEpoch,
        [string]$LeftVersion,
        [string]$LeftRelease,
        [string]$RightEpoch,
        [string]$RightVersion,
        [string]$RightRelease
    )

    if ([string]::IsNullOrWhiteSpace($LeftEpoch)) { $LeftEpoch = '0' }
    if ([string]::IsNullOrWhiteSpace($RightEpoch)) { $RightEpoch = '0' }

    $leftEpochInt = 0
    $rightEpochInt = 0
    [void][int]::TryParse($LeftEpoch, [ref]$leftEpochInt)
    [void][int]::TryParse($RightEpoch, [ref]$rightEpochInt)

    if ($leftEpochInt -gt $rightEpochInt) { return 1 }
    if ($leftEpochInt -lt $rightEpochInt) { return -1 }

    $versionCompare = Compare-RpmVersion -Left $LeftVersion -Right $RightVersion
    if ($versionCompare -ne 0) { return $versionCompare }

    return (Compare-RpmVersion -Left $LeftRelease -Right $RightRelease)
}

function Test-VersionRequirement {
    param(
        [Parameter(Mandatory = $true)]$Provide,
        [Parameter(Mandatory = $true)]$Dependency
    )

    if ([string]::IsNullOrWhiteSpace($Dependency.Flags)) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($Provide.Version)) {
        return $false
    }

    $comparison = Compare-Evr `
        -LeftEpoch $Provide.Epoch `
        -LeftVersion $Provide.Version `
        -LeftRelease $Provide.Release `
        -RightEpoch $Dependency.Epoch `
        -RightVersion $Dependency.Version `
        -RightRelease $Dependency.Release

    switch ($Dependency.Flags) {
        'EQ' { return ($comparison -eq 0) }
        'GE' { return ($comparison -ge 0) }
        'GT' { return ($comparison -gt 0) }
        'LE' { return ($comparison -le 0) }
        'LT' { return ($comparison -lt 0) }
        default { return $true }
    }
}

function Test-PackageAllowedByModuleSelection {
    param([Parameter(Mandatory = $true)]$PackageObject)

    if ($script:EnabledModuleStreams.Count -eq 0) {
        return $true
    }

    if ($script:EnabledModuleArtifactKeys.ContainsKey($PackageObject.ArtifactKey)) {
        return $true
    }

    if ($script:AllModuleArtifactNames.ContainsKey($PackageObject.Name)) {
        return $false
    }

    return $true
}

function Get-ProviderRecords {
    param([Parameter(Mandatory = $true)][string]$Name)

    $records = New-Object System.Collections.ArrayList
    if ($script:ProvidesByName.ContainsKey($Name)) {
        foreach ($record in $script:ProvidesByName[$Name]) {
            [void]$records.Add($record)
        }
    }
    if ($script:FileProvidesByName.ContainsKey($Name)) {
        foreach ($record in $script:FileProvidesByName[$Name]) {
            [void]$records.Add($record)
        }
    }
    return ,$records
}

function Test-DependencySatisfied {
    param([Parameter(Mandatory = $true)]$Dependency)

    if ($AssumeInstalledCapability -contains $Dependency.Name) {
        return $true
    }

    foreach ($record in (Get-ProviderRecords -Name $Dependency.Name)) {
        if (-not $script:SelectedPackages.ContainsKey($record.Package.Id)) {
            continue
        }
        if (Test-VersionRequirement -Provide $record -Dependency $Dependency) {
            return $true
        }
    }

    return $false
}

function Compare-PackagePreference {
    param(
        [Parameter(Mandatory = $true)]$Left,
        [Parameter(Mandatory = $true)]$Right,
        [Parameter(Mandatory = $true)]$Dependency
    )

    $leftExact = ($Left.Name -eq $Dependency.Name)
    $rightExact = ($Right.Name -eq $Dependency.Name)
    if ($leftExact -and -not $rightExact) { return 1 }
    if (-not $leftExact -and $rightExact) { return -1 }

    $versionCompare = Compare-Evr `
        -LeftEpoch $Left.Epoch `
        -LeftVersion $Left.Version `
        -LeftRelease $Left.Release `
        -RightEpoch $Right.Epoch `
        -RightVersion $Right.Version `
        -RightRelease $Right.Release
    if ($versionCompare -ne 0) {
        return $versionCompare
    }

    $leftTargetArch = ($Left.Arch -eq $script:TargetArch)
    $rightTargetArch = ($Right.Arch -eq $script:TargetArch)
    if ($leftTargetArch -and -not $rightTargetArch) { return 1 }
    if (-not $leftTargetArch -and $rightTargetArch) { return -1 }

    if ($Left.RepoPriority -lt $Right.RepoPriority) { return 1 }
    if ($Left.RepoPriority -gt $Right.RepoPriority) { return -1 }

    return 0
}

function Select-BestPackage {
    param(
        [Parameter(Mandatory = $true)]$Candidates,
        [Parameter(Mandatory = $true)]$Dependency
    )

    $best = $null
    foreach ($candidate in $Candidates) {
        if ($null -eq $best) {
            $best = $candidate
            continue
        }

        if ((Compare-PackagePreference -Left $candidate -Right $best -Dependency $Dependency) -gt 0) {
            $best = $candidate
        }
    }
    return $best
}

function Find-DependencyProvider {
    param([Parameter(Mandatory = $true)]$Dependency)

    $candidatesById = @{}
    foreach ($record in (Get-ProviderRecords -Name $Dependency.Name)) {
        if (-not (Test-VersionRequirement -Provide $record -Dependency $Dependency)) {
            continue
        }
        if (-not (Test-PackageAllowedByModuleSelection -PackageObject $record.Package)) {
            continue
        }
        $candidatesById[$record.Package.Id] = $record.Package
    }

    return ,@($candidatesById.Values)
}

function Get-NamesFromRichDependency {
    param([Parameter(Mandatory = $true)][string]$Expression)

    $names = New-Object System.Collections.ArrayList
    $operators = @('and', 'or', 'if', 'unless', 'with', 'without', 'else', 'not')
    foreach ($match in [regex]::Matches($Expression, '[A-Za-z0-9_+./-]+(?:\([A-Za-z0-9_+./:-]+\))?')) {
        $token = $match.Value
        if ($operators -contains $token.ToLowerInvariant()) {
            continue
        }
        if ($token -match '^\d+(\.\d+)*$') {
            continue
        }
        if (-not $names.Contains($token)) {
            [void]$names.Add($token)
        }
    }
    return ,$names
}

function Test-IgnoreDependency {
    param(
        [Parameter(Mandatory = $true)]$Dependency,
        [Parameter(Mandatory = $true)]$Queue
    )

    if ($Dependency.Name -match '^rpmlib\(') {
        return $true
    }

    if ($Dependency.Name -match '^\(.+\)$') {
        [void]$script:ResolutionWarnings.Add("Skipped rich dependency expression '$($Dependency.Name)' from $($Dependency.FromPackage); validate the final bundle with DNF.")
        return $true
    }

    return $false
}

function Add-DependencyRequestsForPackage {
    param(
        [Parameter(Mandatory = $true)]$PackageObject,
        [Parameter(Mandatory = $true)]$Queue
    )

    foreach ($dependency in $PackageObject.Requires) {
        $Queue.Enqueue([pscustomobject]@{
            Name        = $dependency.Name
            Flags       = $dependency.Flags
            Epoch       = $dependency.Epoch
            Version     = $dependency.Version
            Release     = $dependency.Release
            Kind        = $dependency.Kind
            FromPackage = $PackageObject.Nevra
            Reason      = "requires $($dependency.Name)"
            IsRoot      = $false
        })
    }

    if ($IncludeWeakDependencies) {
        foreach ($dependency in $PackageObject.WeakRequires) {
            $Queue.Enqueue([pscustomobject]@{
                Name        = $dependency.Name
                Flags       = $dependency.Flags
                Epoch       = $dependency.Epoch
                Version     = $dependency.Version
                Release     = $dependency.Release
                Kind        = $dependency.Kind
                FromPackage = $PackageObject.Nevra
                Reason      = "$($dependency.Kind) $($dependency.Name)"
                IsRoot      = $false
            })
        }
    }
}

function Resolve-PackageClosure {
    param([Parameter(Mandatory = $true)][System.Collections.ArrayList]$RootPackages)

    $queue = New-Object System.Collections.Queue
    foreach ($root in $RootPackages) {
        $queue.Enqueue([pscustomobject]@{
            Name        = $root
            Flags       = ''
            Epoch       = ''
            Version     = ''
            Release     = ''
            Kind        = 'root'
            FromPackage = '<root>'
            Reason      = 'requested'
            IsRoot      = $true
        })
    }

    while ($queue.Count -gt 0) {
        $dependency = $queue.Dequeue()
        if (Test-IgnoreDependency -Dependency $dependency -Queue $queue) {
            continue
        }

        if (Test-DependencySatisfied -Dependency $dependency) {
            continue
        }

        $candidates = Find-DependencyProvider -Dependency $dependency
        if ($candidates.Count -eq 0) {
            [void]$script:UnresolvedDependencies.Add([pscustomobject]@{
                Name        = $dependency.Name
                Flags       = $dependency.Flags
                Epoch       = $dependency.Epoch
                Version     = $dependency.Version
                Release     = $dependency.Release
                Kind        = $dependency.Kind
                FromPackage = $dependency.FromPackage
                Reason      = $dependency.Reason
            })
            continue
        }

        $selected = Select-BestPackage -Candidates $candidates -Dependency $dependency
        if (-not $script:SelectedPackages.ContainsKey($selected.Id)) {
            $script:SelectedPackages[$selected.Id] = $selected
            $script:SelectedReasons[$selected.Id] = $dependency.Reason
            [void]$script:SelectedOrder.Add($selected)
            Write-Host ("Selected {0} ({1})" -f $selected.Nevra, $selected.RepoId)
            Add-DependencyRequestsForPackage -PackageObject $selected -Queue $queue
        }
    }
}

function Download-SelectedPackages {
    $packageRoot = Join-Path $OutputDirectory 'packages'
    New-Directory -Path $packageRoot

    foreach ($packageObject in $script:SelectedOrder) {
        $destination = $packageObject.LocalPath
        $parent = Split-Path -Parent $destination
        New-Directory -Path $parent

        $download = $true
        if ((Test-Path -LiteralPath $destination) -and -not $Force) {
            $actual = Get-FileHashText -Path $destination -Algorithm $packageObject.ChecksumType
            if ($actual -eq $packageObject.Id.ToLowerInvariant()) {
                $download = $false
            }
        }

        if ($download) {
            Write-Host "Downloading $($packageObject.Nevra)"
            Invoke-HttpDownload -Uri $packageObject.LocationUrl -OutFile $destination -Overwrite:$true
        }

        $actualHash = Get-FileHashText -Path $destination -Algorithm $packageObject.ChecksumType
        if ($actualHash -ne $packageObject.Id.ToLowerInvariant()) {
            throw "Checksum mismatch after downloading $($packageObject.Nevra)."
        }
    }
}

function New-XmlWriterSettings {
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $settings.Indent = $true
    $settings.NewLineChars = "`n"
    return $settings
}

function Save-XmlDocument {
    param(
        [Parameter(Mandatory = $true)][xml]$Document,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $settings = New-XmlWriterSettings
    $writer = [System.Xml.XmlWriter]::Create($Path, $settings)
    try {
        $Document.Save($writer)
    }
    finally {
        $writer.Dispose()
    }
}

function Add-XmlNamespaceDeclaration {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Document,
        [Parameter(Mandatory = $true)][System.Xml.XmlElement]$Element,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$Uri
    )

    $attribute = $Document.CreateAttribute('xmlns', $Prefix, 'http://www.w3.org/2000/xmlns/')
    $attribute.Value = $Uri
    [void]$Element.Attributes.Append($attribute)
}

function Populate-SelectedPrimaryNodes {
    $selectedByRepo = @{}
    foreach ($packageObject in $script:SelectedOrder) {
        if ($packageObject.PrimaryNode) {
            continue
        }
        if (-not $selectedByRepo.ContainsKey($packageObject.RepoId)) {
            $selectedByRepo[$packageObject.RepoId] = @{}
        }
        $selectedByRepo[$packageObject.RepoId][$packageObject.Id] = $packageObject
    }

    foreach ($repoIdValue in $selectedByRepo.Keys) {
        if (-not $script:RepoById.ContainsKey($repoIdValue)) {
            continue
        }

        $repo = $script:RepoById[$repoIdValue]
        Write-Host "Loading selected primary metadata nodes: $($repo.Id)"

        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.IgnoreComments = $true
        $settings.IgnoreWhitespace = $true

        $reader = [System.Xml.XmlReader]::Create($repo.PrimaryXmlPath, $settings)
        try {
            [void]$reader.Read()
            while (-not $reader.EOF) {
                if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element -or $reader.LocalName -ne 'package') {
                    [void]$reader.Read()
                    continue
                }

                $packageXml = $reader.ReadOuterXml()
                if ([string]::IsNullOrWhiteSpace($packageXml)) {
                    continue
                }

                $doc = New-Object System.Xml.XmlDocument
                $doc.LoadXml($packageXml)
                $ns = New-XmlNamespaceManager -Document $doc -Namespaces @{
                    common = 'http://linux.duke.edu/metadata/common'
                }
                $checksumNode = $doc.DocumentElement.SelectSingleNode('common:checksum', $ns)
                if ($null -eq $checksumNode) {
                    continue
                }

                $checksum = $checksumNode.InnerText.Trim()
                if ($selectedByRepo[$repoIdValue].ContainsKey($checksum)) {
                    $selectedByRepo[$repoIdValue][$checksum].PrimaryNode = $doc.DocumentElement.CloneNode($true)
                }
            }
        }
        finally {
            $reader.Dispose()
        }
    }

    $missing = @($script:SelectedOrder | Where-Object { -not $_.PrimaryNode })
    if ($missing.Count -gt 0) {
        $names = ($missing | Select-Object -First 10 | ForEach-Object { $_.Nevra }) -join ', '
        throw "Could not reload primary metadata nodes for $($missing.Count) selected packages: $names"
    }
}

function Write-PrimaryMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)

    $doc = New-Object System.Xml.XmlDocument
    $declaration = $doc.CreateXmlDeclaration('1.0', 'UTF-8', $null)
    [void]$doc.AppendChild($declaration)
    $root = $doc.CreateElement('metadata', 'http://linux.duke.edu/metadata/common')
    Add-XmlNamespaceDeclaration -Document $doc -Element $root -Prefix 'rpm' -Uri 'http://linux.duke.edu/metadata/rpm'
    $root.SetAttribute('packages', [string]$script:SelectedOrder.Count)
    [void]$doc.AppendChild($root)

    $ns = New-XmlNamespaceManager -Document $doc -Namespaces @{
        common = 'http://linux.duke.edu/metadata/common'
    }

    foreach ($packageObject in $script:SelectedOrder) {
        if (-not $packageObject.PrimaryNode) {
            throw "Selected package $($packageObject.Nevra) is missing primary metadata."
        }

        $imported = $doc.ImportNode($packageObject.PrimaryNode, $true)
        $location = $imported.SelectSingleNode('common:location', $ns)
        if ($location) {
            for ($i = $location.Attributes.Count - 1; $i -ge 0; $i--) {
                $attribute = $location.Attributes.Item($i)
                if ($attribute.LocalName -ne 'href') {
                    [void]$location.Attributes.Remove($attribute)
                }
            }
            $location.SetAttribute('href', $packageObject.LocalRelativePath)
        }
        [void]$root.AppendChild($imported)
    }

    Save-XmlDocument -Document $doc -Path $Path
}

function Write-FilelistsMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)

    $doc = New-Object System.Xml.XmlDocument
    $declaration = $doc.CreateXmlDeclaration('1.0', 'UTF-8', $null)
    [void]$doc.AppendChild($declaration)
    $root = $doc.CreateElement('filelists', 'http://linux.duke.edu/metadata/filelists')
    $root.SetAttribute('packages', [string]$script:SelectedOrder.Count)
    [void]$doc.AppendChild($root)

    foreach ($packageObject in $script:SelectedOrder) {
        $packageNode = $doc.CreateElement('package', 'http://linux.duke.edu/metadata/filelists')
        $packageNode.SetAttribute('pkgid', $packageObject.Id)
        $packageNode.SetAttribute('name', $packageObject.Name)
        $packageNode.SetAttribute('arch', $packageObject.Arch)

        $versionNode = $doc.CreateElement('version', 'http://linux.duke.edu/metadata/filelists')
        $versionNode.SetAttribute('epoch', $packageObject.Epoch)
        $versionNode.SetAttribute('ver', $packageObject.Version)
        $versionNode.SetAttribute('rel', $packageObject.Release)
        [void]$packageNode.AppendChild($versionNode)

        foreach ($fileRecord in ($packageObject.Files | Sort-Object Path, Type)) {
            $fileNode = $doc.CreateElement('file', 'http://linux.duke.edu/metadata/filelists')
            if ($fileRecord.Type) {
                $fileNode.SetAttribute('type', $fileRecord.Type)
            }
            $fileNode.InnerText = $fileRecord.Path
            [void]$packageNode.AppendChild($fileNode)
        }

        [void]$root.AppendChild($packageNode)
    }

    Save-XmlDocument -Document $doc -Path $Path
}

function Write-OtherMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)

    $doc = New-Object System.Xml.XmlDocument
    $declaration = $doc.CreateXmlDeclaration('1.0', 'UTF-8', $null)
    [void]$doc.AppendChild($declaration)
    $root = $doc.CreateElement('otherdata', 'http://linux.duke.edu/metadata/other')
    $root.SetAttribute('packages', [string]$script:SelectedOrder.Count)
    [void]$doc.AppendChild($root)

    foreach ($packageObject in $script:SelectedOrder) {
        $packageNode = $doc.CreateElement('package', 'http://linux.duke.edu/metadata/other')
        $packageNode.SetAttribute('pkgid', $packageObject.Id)
        $packageNode.SetAttribute('name', $packageObject.Name)
        $packageNode.SetAttribute('arch', $packageObject.Arch)

        $versionNode = $doc.CreateElement('version', 'http://linux.duke.edu/metadata/other')
        $versionNode.SetAttribute('epoch', $packageObject.Epoch)
        $versionNode.SetAttribute('ver', $packageObject.Version)
        $versionNode.SetAttribute('rel', $packageObject.Release)
        [void]$packageNode.AppendChild($versionNode)

        [void]$root.AppendChild($packageNode)
    }

    Save-XmlDocument -Document $doc -Path $Path
}

function Get-ReposNeedingModuleMetadata {
    $repoIds = @{}
    if ($script:EnabledModuleStreams.Count -gt 0) {
        foreach ($record in $script:ModuleRecords) {
            if ($script:EnabledModuleStreams.ContainsKey($record.Key)) {
                $repoIds[$record.RepoId] = $true
            }
        }
    }

    foreach ($packageObject in $script:SelectedOrder) {
        if ($script:AllModuleArtifactKeys.ContainsKey($packageObject.ArtifactKey)) {
            $repoIds[$packageObject.RepoId] = $true
        }
    }

    return ,@($repoIds.Keys)
}

function Write-ModulesMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)

    $repoIds = Get-ReposNeedingModuleMetadata
    if ($repoIds.Count -eq 0) {
        return $false
    }

    $builder = New-Object System.Text.StringBuilder
    foreach ($repoIdValue in $repoIds) {
        if (-not $script:RepoById.ContainsKey($repoIdValue)) {
            continue
        }
        $repo = $script:RepoById[$repoIdValue]
        if (-not $repo.HasModules) {
            continue
        }
        $raw = Get-Content -LiteralPath $repo.ModulesYamlPath -Raw
        [void]$builder.AppendLine($raw.Trim())
        [void]$builder.AppendLine()
    }

    if ($builder.Length -eq 0) {
        return $false
    }

    [System.IO.File]::WriteAllText($Path, $builder.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

function Write-CompressedMetadataFile {
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$RawPath,
        [Parameter(Mandatory = $true)][string]$RepodataDirectory
    )

    $openChecksum = Get-FileHashText -Path $RawPath -Algorithm 'sha256'
    $openSize = (Get-Item -LiteralPath $RawPath).Length
    $temporaryGz = Join-Path $RepodataDirectory "$Type.xml.gz"
    if ($Type -eq 'modules') {
        $temporaryGz = Join-Path $RepodataDirectory 'modules.yaml.gz'
    }

    Compress-GZipFile -InputPath $RawPath -OutputPath $temporaryGz
    $checksum = Get-FileHashText -Path $temporaryGz -Algorithm 'sha256'
    $size = (Get-Item -LiteralPath $temporaryGz).Length
    $extension = if ($Type -eq 'modules') { 'modules.yaml.gz' } else { "$Type.xml.gz" }
    $finalName = "$checksum-$extension"
    $finalPath = Join-Path $RepodataDirectory $finalName
    if (Test-Path -LiteralPath $finalPath) {
        Remove-Item -LiteralPath $finalPath -Force
    }
    Move-Item -LiteralPath $temporaryGz -Destination $finalPath

    return [pscustomobject]@{
        Type         = $Type
        LocationHref = "repodata/$finalName"
        Checksum     = $checksum
        OpenChecksum = $openChecksum
        Size         = $size
        OpenSize     = $openSize
        Timestamp    = Get-UnixTimestamp
    }
}

function Write-Repomd {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$MetadataFiles
    )

    $doc = New-Object System.Xml.XmlDocument
    $declaration = $doc.CreateXmlDeclaration('1.0', 'UTF-8', $null)
    [void]$doc.AppendChild($declaration)
    $root = $doc.CreateElement('repomd', 'http://linux.duke.edu/metadata/repo')
    Add-XmlNamespaceDeclaration -Document $doc -Element $root -Prefix 'rpm' -Uri 'http://linux.duke.edu/metadata/rpm'
    [void]$doc.AppendChild($root)

    $revision = $doc.CreateElement('revision', 'http://linux.duke.edu/metadata/repo')
    $revision.InnerText = [string](Get-UnixTimestamp)
    [void]$root.AppendChild($revision)

    foreach ($metadata in $MetadataFiles) {
        $data = $doc.CreateElement('data', 'http://linux.duke.edu/metadata/repo')
        $data.SetAttribute('type', $metadata.Type)

        $checksum = $doc.CreateElement('checksum', 'http://linux.duke.edu/metadata/repo')
        $checksum.SetAttribute('type', 'sha256')
        $checksum.InnerText = $metadata.Checksum
        [void]$data.AppendChild($checksum)

        $openChecksum = $doc.CreateElement('open-checksum', 'http://linux.duke.edu/metadata/repo')
        $openChecksum.SetAttribute('type', 'sha256')
        $openChecksum.InnerText = $metadata.OpenChecksum
        [void]$data.AppendChild($openChecksum)

        $location = $doc.CreateElement('location', 'http://linux.duke.edu/metadata/repo')
        $location.SetAttribute('href', $metadata.LocationHref)
        [void]$data.AppendChild($location)

        $timestamp = $doc.CreateElement('timestamp', 'http://linux.duke.edu/metadata/repo')
        $timestamp.InnerText = [string]$metadata.Timestamp
        [void]$data.AppendChild($timestamp)

        $size = $doc.CreateElement('size', 'http://linux.duke.edu/metadata/repo')
        $size.InnerText = [string]$metadata.Size
        [void]$data.AppendChild($size)

        $openSize = $doc.CreateElement('open-size', 'http://linux.duke.edu/metadata/repo')
        $openSize.InnerText = [string]$metadata.OpenSize
        [void]$data.AppendChild($openSize)

        [void]$root.AppendChild($data)
    }

    Save-XmlDocument -Document $doc -Path $Path
}

function Write-LocalRepositoryMetadata {
    Populate-SelectedPrimaryNodes

    $repodata = Join-Path $OutputDirectory 'repodata'
    New-Directory -Path $repodata

    foreach ($existing in Get-ChildItem -LiteralPath $repodata -File -ErrorAction SilentlyContinue) {
        Remove-Item -LiteralPath $existing.FullName -Force
    }

    $work = Join-Path $OutputDirectory '.repodata-work'
    New-Directory -Path $work

    $metadataFiles = New-Object System.Collections.ArrayList

    $primaryPath = Join-Path $work 'primary.xml'
    Write-PrimaryMetadata -Path $primaryPath
    [void]$metadataFiles.Add((Write-CompressedMetadataFile -Type 'primary' -RawPath $primaryPath -RepodataDirectory $repodata))

    $filelistsPath = Join-Path $work 'filelists.xml'
    Write-FilelistsMetadata -Path $filelistsPath
    [void]$metadataFiles.Add((Write-CompressedMetadataFile -Type 'filelists' -RawPath $filelistsPath -RepodataDirectory $repodata))

    $otherPath = Join-Path $work 'other.xml'
    Write-OtherMetadata -Path $otherPath
    [void]$metadataFiles.Add((Write-CompressedMetadataFile -Type 'other' -RawPath $otherPath -RepodataDirectory $repodata))

    $modulesPath = Join-Path $work 'modules.yaml'
    if (Write-ModulesMetadata -Path $modulesPath) {
        [void]$metadataFiles.Add((Write-CompressedMetadataFile -Type 'modules' -RawPath $modulesPath -RepodataDirectory $repodata))
    }

    Write-Repomd -Path (Join-Path $repodata 'repomd.xml') -MetadataFiles $metadataFiles

    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}

function Write-Manifests {
    $manifestRoot = Join-Path $OutputDirectory 'manifests'
    New-Directory -Path $manifestRoot

    $packageManifest = foreach ($packageObject in $script:SelectedOrder) {
        [pscustomobject]@{
            name          = $packageObject.Name
            arch          = $packageObject.Arch
            epoch         = $packageObject.Epoch
            version       = $packageObject.Version
            release       = $packageObject.Release
            nevra         = $packageObject.Nevra
            repo_id       = $packageObject.RepoId
            source_url    = $packageObject.LocationUrl
            local_path    = $packageObject.LocalRelativePath
            checksum_type = $packageObject.ChecksumType
            checksum      = $packageObject.Id
            selected_by   = $script:SelectedReasons[$packageObject.Id]
        }
    }

    $packageManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $manifestRoot 'resolved-packages.json') -Encoding UTF8
    $script:UnresolvedDependencies | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $manifestRoot 'unresolved-dependencies.json') -Encoding UTF8
    $script:ResolutionWarnings | Set-Content -LiteralPath (Join-Path $manifestRoot 'resolution-warnings.txt') -Encoding UTF8

    $repoManifest = foreach ($repo in $script:RepoById.Values) {
        [pscustomobject]@{
            id       = $repo.Id
            name     = $repo.Name
            base_url = $repo.BaseUrl
            priority = $repo.Priority
        }
    }
    $repoManifest | Sort-Object priority, id | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $manifestRoot 'repo-sources.json') -Encoding UTF8

    $summary = [pscustomobject]@{
        generated_at_utc              = [DateTime]::UtcNow.ToString('o')
        target_releasever             = $Releasever
        target_arch                   = $Arch
        provider                      = $Provider
        include_epel                  = [bool]$IncludeEpel
        include_weak_dependencies     = [bool]$IncludeWeakDependencies
        package_count                 = $script:SelectedOrder.Count
        unresolved_dependency_count   = $script:UnresolvedDependencies.Count
        assumed_installed_capabilities = $AssumeInstalledCapability
        module_streams                = @($script:EnabledModuleStreams.Keys)
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $manifestRoot 'bundle-summary.json') -Encoding UTF8

    $sums = New-Object System.Collections.ArrayList
    foreach ($packageObject in $script:SelectedOrder) {
        if (Test-Path -LiteralPath $packageObject.LocalPath) {
            $sha256 = Get-FileHashText -Path $packageObject.LocalPath -Algorithm 'sha256'
            [void]$sums.Add(('{0}  {1}' -f $sha256, $packageObject.LocalRelativePath))
        }
    }
    $sums | Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS') -Encoding ASCII

    $repoFile = @"
[$RepoId]
name=Airgap EL9 RPM bundle
baseurl=file:///mnt/airgap/$(Split-Path -Leaf (Resolve-Path -LiteralPath $OutputDirectory))
enabled=1
gpgcheck=0
repo_gpgcheck=0
metadata_expire=-1
"@
    $repoFile | Set-Content -LiteralPath (Join-Path $manifestRoot "$RepoId.repo") -Encoding ASCII
}

function Remove-MetadataCacheIfRequested {
    param([Parameter(Mandatory = $true)][string]$CacheRoot)

    if ($KeepMetadataCache) {
        return
    }

    if (Test-Path -LiteralPath $CacheRoot) {
        Remove-Item -LiteralPath $CacheRoot -Recurse -Force
    }
}

Initialize-ModuleStreamSelection

$rootPackages = New-Object System.Collections.ArrayList
foreach ($packageValue in $Package) {
    foreach ($packageName in ($packageValue -split ',')) {
        if (-not [string]::IsNullOrWhiteSpace($packageName)) {
            [void]$rootPackages.Add($packageName.Trim())
        }
    }
}

if ($rootPackages.Count -eq 0 -and $ModuleProfile.Count -eq 0) {
    throw "Pass at least one -Package value or one -ModuleProfile value."
}

New-Directory -Path $OutputDirectory
$metadataCacheRoot = Join-Path $OutputDirectory 'metadata-cache'
New-Directory -Path $metadataCacheRoot

$repositories = Get-ConfiguredRepositories
foreach ($repo in $repositories) {
    if ($script:RepoById.ContainsKey($repo.Id)) {
        throw "Duplicate repository id '$($repo.Id)'. Use unique ids in -Repository id=url arguments."
    }
    $script:RepoById[$repo.Id] = $repo
}

Write-Host "Configured repositories:"
foreach ($repo in ($repositories | Sort-Object Priority, Id)) {
    Write-Host ("  {0}: {1}" -f $repo.Id, $repo.BaseUrl)
}

foreach ($repo in $repositories) {
    Read-RepositoryMetadata -Repo $repo -CacheRoot $metadataCacheRoot
    Import-PrimaryMetadata -Repo $repo
}

foreach ($repo in $repositories) {
    Import-ModuleMetadata -Repo $repo
}

if ($script:EnabledModuleStreams.Count -gt 0) {
    foreach ($key in $script:EnabledModuleStreams.Keys) {
        $found = $false
        foreach ($record in $script:ModuleRecords) {
            if ($record.Key -eq $key) {
                $found = $true
                break
            }
        }
        if (-not $found) {
            throw "Requested module stream '$key' was not found in the configured repositories."
        }
    }
}

Add-ModuleProfileRoots -RootPackages $rootPackages

if (-not $SkipFilelists) {
    foreach ($repo in $repositories) {
        Import-FilelistsMetadata -Repo $repo
    }
}
else {
    Write-Warning "Skipping filelists metadata. Dependencies expressed as full file paths may be unresolved."
}

Write-Host "Resolving dependency closure..."
Resolve-PackageClosure -RootPackages $rootPackages

Write-Manifests

if ($script:UnresolvedDependencies.Count -gt 0 -and -not $AllowUnresolved) {
    Remove-MetadataCacheIfRequested -CacheRoot $metadataCacheRoot
    $unresolvedPath = Join-Path (Join-Path $OutputDirectory 'manifests') 'unresolved-dependencies.json'
    throw "Dependency resolution found $($script:UnresolvedDependencies.Count) unresolved dependencies. Review $unresolvedPath or rerun with -AllowUnresolved to write an incomplete repo."
}

Download-SelectedPackages
Write-LocalRepositoryMetadata
Write-Manifests
Remove-MetadataCacheIfRequested -CacheRoot $metadataCacheRoot

Write-Host ""
Write-Host "Complete."
Write-Host ("RPMs:      {0}" -f (Join-Path $OutputDirectory 'packages'))
Write-Host ("Repo data: {0}" -f (Join-Path $OutputDirectory 'repodata'))
Write-Host ("Manifests: {0}" -f (Join-Path $OutputDirectory 'manifests'))
