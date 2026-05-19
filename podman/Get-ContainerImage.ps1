<#
.SYNOPSIS
Pulls container images without invoking Podman, Docker, Skopeo, or ORAS.

.DESCRIPTION
Get-ContainerImage.ps1 retrieves public or authenticated container images using
the OCI Distribution / Docker Registry HTTP API. It resolves image references,
negotiates registry bearer tokens, selects a platform from manifest lists or OCI
indexes, and writes an OCI image layout to disk.

The default output is an OCI image layout directory containing oci-layout,
index.json, and blobs/sha256/* entries. This is meant for air-gap staging,
inspection, mirroring workflows, and environments where container CLIs are not
available.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Image,

    [Parameter()]
    [string]$Platform = 'linux/amd64',

    [Parameter()]
    [string]$OutputDirectory = (Join-Path (Get-Location) 'container-image-cache'),

    [Parameter()]
    [string]$Username = $env:REGISTRY_USERNAME,

    [Parameter()]
    [string]$Password = $env:REGISTRY_PASSWORD,

    [Parameter()]
    [string]$BearerToken = $env:REGISTRY_BEARER_TOKEN,

    [Parameter()]
    [switch]$SkipLayers,

    [Parameter()]
    [switch]$Insecure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RegistryScheme = if ($Insecure) { 'http' } else { 'https' }
$script:ManifestAccept = @(
    'application/vnd.oci.image.index.v1+json',
    'application/vnd.docker.distribution.manifest.list.v2+json',
    'application/vnd.oci.image.manifest.v1+json',
    'application/vnd.docker.distribution.manifest.v2+json'
) -join ', '

function New-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function ConvertTo-SafePathPart {
    param([Parameter(Mandatory = $true)][string]$Value)
    return ($Value -replace '[\\/:*?"<>|@]', '_')
}

function Get-UrlEncoded {
    param([Parameter(Mandatory = $true)][string]$Value)
    return [System.Uri]::EscapeDataString($Value)
}

function ConvertFrom-ImageReference {
    param([Parameter(Mandatory = $true)][string]$Reference)

    $value = $Reference.Trim()
    if ($value -match '^[a-z][a-z0-9+.-]*://') {
        $uri = [System.Uri]$value
        $value = $uri.Host + $uri.AbsolutePath
        if ($uri.Fragment) {
            $value += '#' + $uri.Fragment.TrimStart('#')
        }
        if ($uri.Query) {
            throw "Image references must not include a query string: $Reference"
        }
    }

    $digest = ''
    $digestIndex = $value.IndexOf('@')
    if ($digestIndex -ge 0) {
        $digest = $value.Substring($digestIndex + 1)
        $value = $value.Substring(0, $digestIndex)
    }

    $firstSlash = $value.IndexOf('/')
    $firstPart = if ($firstSlash -ge 0) { $value.Substring(0, $firstSlash) } else { $value }
    $registry = 'registry-1.docker.io'
    $repositoryAndTag = $value

    if ($firstSlash -ge 0 -and ($firstPart.Contains('.') -or $firstPart.Contains(':') -or $firstPart -eq 'localhost')) {
        $registry = $firstPart
        $repositoryAndTag = $value.Substring($firstSlash + 1)
    }

    if ($registry -eq 'docker.io') {
        $registry = 'registry-1.docker.io'
    }

    $tag = 'latest'
    $lastSlash = $repositoryAndTag.LastIndexOf('/')
    $lastColon = $repositoryAndTag.LastIndexOf(':')
    if ($lastColon -gt $lastSlash) {
        $tag = $repositoryAndTag.Substring($lastColon + 1)
        $repositoryAndTag = $repositoryAndTag.Substring(0, $lastColon)
    }

    if ($registry -eq 'registry-1.docker.io' -and -not $repositoryAndTag.Contains('/')) {
        $repositoryAndTag = "library/$repositoryAndTag"
    }

    $resolvedReference = if ($digest) { $digest } else { $tag }

    return [pscustomobject]@{
        Original   = $Reference
        Registry   = $registry
        Repository = $repositoryAndTag
        Tag        = $tag
        Digest     = $digest
        Reference  = $resolvedReference
        Name       = "$registry/$repositoryAndTag"
    }
}

function Invoke-Http {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers = @{},
        [string]$OutFile = ''
    )

    $parameters = @{
        Uri             = $Uri
        Method          = $Method
        Headers         = $Headers
        UseBasicParsing = $true
    }
    if ($OutFile) {
        $parameters.OutFile = $OutFile
    }

    try {
        return Invoke-WebRequest @parameters
    }
    catch {
        $response = $null
        if ($_.Exception.PSObject.Properties['Response']) {
            $response = $_.Exception.Response
        }
        if ($response) {
            throw "HTTP $([int]$response.StatusCode) from $Uri"
        }
        throw
    }
}

function Invoke-HttpWithResponse {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers = @{}
    )

    $parameters = @{
        Uri             = $Uri
        Method          = 'GET'
        Headers         = $Headers
        UseBasicParsing = $true
    }
    $body = Invoke-WebRequest @parameters
    return [pscustomobject]@{
        Body    = $body
        Headers = $body.Headers
    }
}

function Invoke-Json {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers = @{}
    )
    $response = Invoke-Http -Uri $Uri -Headers $Headers
    if (-not $response.Content) {
        return $null
    }
    return (ConvertTo-ResponseText -Content $response.Content) | ConvertFrom-Json
}

function ConvertTo-ResponseText {
    param([Parameter(Mandatory = $true)]$Content)

    if ($Content -is [byte[]]) {
        return [System.Text.Encoding]::UTF8.GetString($Content)
    }
    return [string]$Content
}

function ConvertTo-ResponseBytes {
    param([AllowNull()]$Content)

    if ($null -eq $Content) {
        return [byte[]]::new(0)
    }
    if ($Content -is [byte[]]) {
        return [byte[]]$Content
    }
    return [System.Text.Encoding]::UTF8.GetBytes([string]$Content)
}

function Get-HashAlgorithm {
    param([Parameter(Mandatory = $true)][string]$Algorithm)

    switch ($Algorithm.ToLowerInvariant()) {
        'sha256' { return [System.Security.Cryptography.SHA256]::Create() }
        'sha384' { return [System.Security.Cryptography.SHA384]::Create() }
        'sha512' { return [System.Security.Cryptography.SHA512]::Create() }
        default { throw "Unsupported digest algorithm: $Algorithm" }
    }
}

function ConvertTo-HexString {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $builder = [System.Text.StringBuilder]::new($Bytes.Length * 2)
    foreach ($byte in $Bytes) {
        [void]$builder.Append($byte.ToString('x2'))
    }
    return $builder.ToString()
}

function Get-DigestFromBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [string]$Algorithm = 'sha256'
    )

    $hasher = Get-HashAlgorithm -Algorithm $Algorithm
    try {
        return "${Algorithm}:" + (ConvertTo-HexString -Bytes $hasher.ComputeHash($Bytes))
    }
    finally {
        $hasher.Dispose()
    }
}

function Get-DigestFromFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Algorithm
    )

    $stream = [System.IO.File]::OpenRead($Path)
    $hasher = Get-HashAlgorithm -Algorithm $Algorithm
    try {
        return "${Algorithm}:" + (ConvertTo-HexString -Bytes $hasher.ComputeHash($stream))
    }
    finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}

function Test-FileDigest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Digest
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    if ($Digest -notmatch '^([^:]+):(.+)$') {
        throw "Unsupported digest format: $Digest"
    }

    return (Get-DigestFromFile -Path $Path -Algorithm $Matches[1]) -eq $Digest
}

function Get-HeaderValue {
    param(
        [Parameter(Mandatory = $true)]$Headers,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Headers -is [System.Net.WebHeaderCollection]) {
        return [string]$Headers[$Name]
    }

    if ($Headers.PSObject.Methods['ContainsKey']) {
        if (-not $Headers.ContainsKey($Name)) {
            return ''
        }

        $value = $Headers[$Name]
        if ($value -is [array]) {
            return [string]$value[0]
        }
        return [string]$value
    }

    if ($Headers -is [System.Collections.IDictionary]) {
        if (-not $Headers.Contains($Name)) {
            return ''
        }

        $value = $Headers[$Name]
        if ($value -is [array]) {
            return [string]$value[0]
        }
        return [string]$value
    }

    if ($Headers.PSObject.Properties[$Name]) {
        return [string]$Headers.$Name
    }

    return ''
}

function Parse-WwwAuthenticate {
    param([Parameter(Mandatory = $true)][string]$Header)

    $challenge = @{}
    if ($Header -notmatch '^Bearer\s+(.*)$') {
        return $challenge
    }

    foreach ($match in [regex]::Matches($Matches[1], '(\w+)="([^"]*)"')) {
        $challenge[$match.Groups[1].Value] = $match.Groups[2].Value
    }
    return $challenge
}

function Get-BasicAuthHeader {
    if (-not $Username -or -not $Password) {
        return ''
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes("${Username}:${Password}")
    return 'Basic ' + [System.Convert]::ToBase64String($bytes)
}

function Get-RegistryAuthHeaders {
    param(
        [Parameter(Mandatory = $true)][string]$Registry,
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Action
    )

    if ($BearerToken) {
        return @{ Authorization = "Bearer $BearerToken" }
    }

    $pingUri = "${script:RegistryScheme}://$Registry/v2/"
    try {
        Invoke-Http -Uri $pingUri | Out-Null
        return @{}
    }
    catch {
        $request = [System.Net.WebRequest]::Create($pingUri)
        $request.Method = 'GET'
        try {
            $request.GetResponse().Close()
            return @{}
        }
        catch [System.Net.WebException] {
            $response = $_.Exception.Response
            if (-not $response) {
                throw
            }

            $authHeader = Get-HeaderValue -Headers $response.Headers -Name 'WWW-Authenticate'
            if (-not $authHeader) {
                throw "Registry requires authentication but did not send WWW-Authenticate."
            }

            $challenge = Parse-WwwAuthenticate -Header $authHeader
            if (-not $challenge.ContainsKey('realm')) {
                throw "Only bearer-token registry authentication is supported."
            }

            $scope = "repository:${Repository}:${Action}"
            $query = @()
            if ($challenge.ContainsKey('service')) {
                $query += 'service=' + (Get-UrlEncoded -Value $challenge['service'])
            }
            $query += 'scope=' + (Get-UrlEncoded -Value $scope)

            $headers = @{}
            $basic = Get-BasicAuthHeader
            if ($basic) {
                $headers.Authorization = $basic
            }

            $tokenUri = $challenge['realm'] + '?' + ($query -join '&')
            $tokenResponse = Invoke-Json -Uri $tokenUri -Headers $headers
            $token = if ($tokenResponse.token) { $tokenResponse.token } else { $tokenResponse.access_token }
            if (-not $token) {
                throw "Registry token endpoint did not return a token."
            }

            return @{ Authorization = "Bearer $token" }
        }
    }
}

function Get-BlobPath {
    param(
        [Parameter(Mandatory = $true)][string]$LayoutRoot,
        [Parameter(Mandatory = $true)][string]$Digest
    )

    if ($Digest -notmatch '^([^:]+):(.+)$') {
        throw "Unsupported digest format: $Digest"
    }

    $algorithm = $Matches[1]
    $encoded = $Matches[2]
    return Join-Path (Join-Path (Join-Path $LayoutRoot 'blobs') $algorithm) $encoded
}

function Get-DescriptorFromResponse {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][byte[]]$ContentBytes
    )

    $digest = ''
    $digest = Get-HeaderValue -Headers $Response.Headers -Name 'Docker-Content-Digest'
    if (-not $digest) {
        $digest = Get-DigestFromBytes -Bytes $ContentBytes -Algorithm 'sha256'
    }

    $contentType = Get-HeaderValue -Headers $Response.Body.Headers -Name 'Content-Type'
    $mediaType = if ($Manifest.PSObject.Properties['mediaType'] -and $Manifest.mediaType) { $Manifest.mediaType } else { $contentType.Split(';')[0].Trim() }
    return [pscustomobject]@{
        mediaType = $mediaType
        digest    = $digest
        size      = [int64]$ContentBytes.Length
    }
}

function Save-ContentBlob {
    param(
        [Parameter(Mandatory = $true)][string]$LayoutRoot,
        [Parameter(Mandatory = $true)][string]$Digest,
        [Parameter(Mandatory = $true)][byte[]]$ContentBytes
    )

    if (-not $Digest) {
        throw 'Cannot save a content blob without a digest.'
    }

    $path = Get-BlobPath -LayoutRoot $LayoutRoot -Digest $Digest
    New-Directory -Path (Split-Path -Parent $path)
    if (Test-Path -LiteralPath $path) {
        if (Test-FileDigest -Path $path -Digest $Digest) {
            return $path
        }
        Write-Verbose "Replacing cached blob with digest mismatch at $path"
    }

    $temporaryPath = "$path.tmp-$([System.Guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllBytes($temporaryPath, $ContentBytes)
        if (-not (Test-FileDigest -Path $temporaryPath -Digest $Digest)) {
            throw "Downloaded manifest digest did not match $Digest."
        }
        Move-Item -LiteralPath $temporaryPath -Destination $path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
    return $path
}

function Save-RegistryBlob {
    param(
        [Parameter(Mandatory = $true)][string]$Registry,
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Digest,
        [Parameter(Mandatory = $true)][string]$LayoutRoot,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $path = Get-BlobPath -LayoutRoot $LayoutRoot -Digest $Digest
    New-Directory -Path (Split-Path -Parent $path)
    if (Test-Path -LiteralPath $path) {
        if (Test-FileDigest -Path $path -Digest $Digest) {
            return $path
        }
        Write-Verbose "Replacing cached blob with digest mismatch at $path"
    }

    $uri = "${script:RegistryScheme}://$Registry/v2/$Repository/blobs/$Digest"
    $temporaryPath = "$path.tmp-$([System.Guid]::NewGuid().ToString('N'))"
    try {
        Invoke-Http -Uri $uri -Headers $Headers -OutFile $temporaryPath | Out-Null
        if (-not (Test-FileDigest -Path $temporaryPath -Digest $Digest)) {
            throw "Downloaded blob digest did not match $Digest."
        }
        Move-Item -LiteralPath $temporaryPath -Destination $path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
    return $path
}

function Select-ManifestDescriptor {
    param(
        [Parameter(Mandatory = $true)]$Index,
        [Parameter(Mandatory = $true)][string]$RequestedPlatform
    )

    $parts = $RequestedPlatform.Split('/')
    $os = $parts[0]
    $architecture = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    $variant = if ($parts.Count -gt 2) { $parts[2] } else { '' }

    if (-not $Index.PSObject.Properties['manifests']) {
        throw 'The image index did not contain a manifests array.'
    }

    foreach ($manifest in @($Index.manifests)) {
        if (-not $manifest.PSObject.Properties['platform'] -or -not $manifest.platform) {
            continue
        }
        $manifestVariant = if ($manifest.platform.PSObject.Properties['variant']) { $manifest.platform.variant } else { '' }
        if ($manifest.platform.os -eq $os -and
            $manifest.platform.architecture -eq $architecture -and
            (-not $variant -or $manifestVariant -eq $variant)) {
            return $manifest
        }
    }

    if (@($Index.manifests).Count -gt 0) {
        return @($Index.manifests)[0]
    }

    throw "The image index did not contain any manifests."
}

function Test-ImageManifestListMediaType {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$MediaType
    )

    if (-not $MediaType) {
        return $false
    }
    return $MediaType -in @(
        'application/vnd.oci.image.index.v1+json',
        'application/vnd.docker.distribution.manifest.list.v2+json'
    )
}

function Get-RegistryManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Registry,
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Reference,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $requestHeaders = @{}
    foreach ($key in $Headers.Keys) {
        $requestHeaders[$key] = $Headers[$key]
    }
    $requestHeaders.Accept = $script:ManifestAccept

    $uri = "${script:RegistryScheme}://$Registry/v2/$Repository/manifests/$Reference"
    $response = Invoke-HttpWithResponse -Uri $uri -Headers $requestHeaders
    $contentBytes = ConvertTo-ResponseBytes -Content $response.Body.Content
    $content = ConvertTo-ResponseText -Content $response.Body.Content
    $manifest = $content | ConvertFrom-Json
    $descriptor = Get-DescriptorFromResponse -Response $response -Manifest $manifest -ContentBytes $contentBytes
    return [pscustomobject]@{
        Manifest     = $manifest
        Descriptor   = $descriptor
        ContentBytes = $contentBytes
    }
}

function Write-OciLayout {
    param(
        [Parameter(Mandatory = $true)][string]$LayoutRoot,
        [Parameter(Mandatory = $true)]$ImageReference,
        [Parameter(Mandatory = $true)]$Descriptor
    )

    @{ imageLayoutVersion = '1.0.0' } |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $LayoutRoot 'oci-layout') -Encoding UTF8

    $containerImageName = if ($ImageReference.Digest) { "$($ImageReference.Name)@$($ImageReference.Digest)" } else { "$($ImageReference.Name):$($ImageReference.Tag)" }

    $index = [pscustomobject]@{
        schemaVersion = 2
        manifests     = @(
            [pscustomobject]@{
                mediaType   = $Descriptor.mediaType
                digest      = $Descriptor.digest
                size        = $Descriptor.size
                annotations = @{
                    'org.opencontainers.image.ref.name' = $ImageReference.Original
                    'io.containerd.image.name'          = $containerImageName
                }
            }
        )
    }

    $index | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $LayoutRoot 'index.json') -Encoding UTF8
}

function Receive-ContainerImage {
    param(
        [Parameter(Mandatory = $true)][string]$ImageReference,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $parsed = ConvertFrom-ImageReference -Reference $ImageReference
    New-Directory -Path $Destination
    New-Directory -Path (Join-Path (Join-Path $Destination 'blobs') 'sha256')

    $headers = Get-RegistryAuthHeaders -Registry $parsed.Registry -Repository $parsed.Repository -Action 'pull'
    $resolved = Get-RegistryManifest -Registry $parsed.Registry -Repository $parsed.Repository -Reference $parsed.Reference -Headers $headers

    $indexDescriptor = $null
    $manifestResult = $resolved
    if (Test-ImageManifestListMediaType -MediaType $resolved.Descriptor.mediaType) {
        $indexDescriptor = $resolved.Descriptor
        Save-ContentBlob -LayoutRoot $Destination -Digest $indexDescriptor.digest -ContentBytes $resolved.ContentBytes | Out-Null

        $selected = Select-ManifestDescriptor -Index $resolved.Manifest -RequestedPlatform $Platform
        if (-not $selected.digest) {
            throw "Selected platform manifest did not include a digest."
        }
        $manifestResult = Get-RegistryManifest -Registry $parsed.Registry -Repository $parsed.Repository -Reference $selected.digest -Headers $headers
    }

    Save-ContentBlob -LayoutRoot $Destination -Digest $manifestResult.Descriptor.digest -ContentBytes $manifestResult.ContentBytes | Out-Null

    $configFile = ''
    if ($manifestResult.Manifest.PSObject.Properties['config'] -and $manifestResult.Manifest.config -and $manifestResult.Manifest.config.digest) {
        $configFile = Save-RegistryBlob -Registry $parsed.Registry -Repository $parsed.Repository -Digest $manifestResult.Manifest.config.digest -LayoutRoot $Destination -Headers $headers
    }

    $layerFiles = @()
    if (-not $SkipLayers) {
        if (-not $manifestResult.Manifest.PSObject.Properties['layers']) {
            throw 'Image manifest did not include a layers array.'
        }
        foreach ($layer in @($manifestResult.Manifest.layers)) {
            if (-not $layer.digest) {
                throw 'Image manifest contained a layer without a digest.'
            }
            $layerFiles += Save-RegistryBlob -Registry $parsed.Registry -Repository $parsed.Repository -Digest $layer.digest -LayoutRoot $Destination -Headers $headers
        }
    }

    Write-OciLayout -LayoutRoot $Destination -ImageReference $parsed -Descriptor $manifestResult.Descriptor

    return [pscustomobject]@{
        Mode           = 'OciImageLayout'
        Image          = $ImageReference
        Registry       = $parsed.Registry
        Repository     = $parsed.Repository
        Reference      = $parsed.Reference
        Platform       = $Platform
        LayoutPath     = $Destination
        IndexDigest    = if ($indexDescriptor) { $indexDescriptor.digest } else { '' }
        ManifestDigest = $manifestResult.Descriptor.digest
        ConfigFile     = $configFile
        LayerFiles     = $layerFiles
        LayersSkipped  = [bool]$SkipLayers
    }
}

New-Directory -Path $OutputDirectory

$parsedForPath = ConvertFrom-ImageReference -Reference $Image
$imageDirectory = Join-Path $OutputDirectory (ConvertTo-SafePathPart -Value "$($parsedForPath.Registry)/$($parsedForPath.Repository)/$($parsedForPath.Reference)-$Platform")
$result = Receive-ContainerImage -ImageReference $Image -Destination $imageDirectory
$result | ConvertTo-Json -Depth 30
