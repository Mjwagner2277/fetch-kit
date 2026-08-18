<# 
.SYNOPSIS
Retrieves Go modules without using the Go toolchain.

.DESCRIPTION
This script emulates the retrieval part of `go get` with pure PowerShell.
It supports:

  1. Go module proxy protocol downloads (.info, .mod, .zip).
  2. Direct GitHub and GitLab repository archive downloads.
  3. Basic go-import vanity path discovery for GitHub/GitLab-backed modules.

It intentionally does not compile, install, or resolve the full Go module
graph. Passing -Module selects single Go module retrieval. Passing
-PackageListPath selects Go module retrieval for every module/version pair in a text file.
Passing -GoProxyDirectory also writes retrieved proxy modules in static Go
proxy protocol layout for transfer to an internal proxy host. When
-GoProxyDirectory is used without -OutputDirectory or -Expand, the script uses
a temporary working cache and removes it after the proxy export is written.
#>

[CmdletBinding(DefaultParameterSetName = 'Module')]
param(
    [Parameter(ParameterSetName = 'Module', Mandatory = $true)]
    [string]$Module,

    [Parameter(ParameterSetName = 'Module')]
    [string]$Version = 'latest',

    [Parameter(ParameterSetName = 'ModuleList', Mandatory = $true)]
    [string]$PackageListPath,

    [Parameter(ParameterSetName = 'ModuleList')]
    [string]$GoVersion = '',

    [Parameter(ParameterSetName = 'Module')]
    [Parameter(ParameterSetName = 'ModuleList')]
    [string[]]$Proxy = @(),

    [Parameter(ParameterSetName = 'Module')]
    [Parameter(ParameterSetName = 'ModuleList')]
    [string]$GitLabHost = '',

    [Parameter(ParameterSetName = 'Module')]
    [Parameter(ParameterSetName = 'ModuleList')]
    [string]$GitLabProjectPath = '',

    [Parameter()]
    [string]$OutputDirectory = '',

    [Parameter(ParameterSetName = 'Module')]
    [Parameter(ParameterSetName = 'ModuleList')]
    [string]$GoProxyDirectory = '',

    [Parameter()]
    [string]$GitLabToken = $env:GITLAB_TOKEN,

    [Parameter()]
    [string]$GitHubToken = $env:GITHUB_TOKEN,

    [Parameter(ParameterSetName = 'Module')]
    [Parameter(ParameterSetName = 'ModuleList')]
    [switch]$ResolveDependencies,

    [Parameter()]
    [switch]$Expand
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:UsingTemporaryOutputDirectory = $false
if (-not $OutputDirectory) {
    if ($PSCmdlet.ParameterSetName -in @('Module', 'ModuleList') -and $GoProxyDirectory -and -not $Expand) {
        $OutputDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("go-library-cache-" + [System.Guid]::NewGuid().ToString('n'))
        $script:UsingTemporaryOutputDirectory = $true
    }
    else {
        $OutputDirectory = Join-Path (Get-Location) 'go-library-cache'
    }
}

function New-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function ConvertTo-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Value)
    return ($Value -replace '[\\/:*?"<>|@]', '_')
}

function Escape-GoProxySegment {
    param([Parameter(Mandatory = $true)][string]$Value)

    $builder = [System.Text.StringBuilder]::new()
    foreach ($char in $Value.ToCharArray()) {
        if ($char -cmatch '[A-Z]') {
            [void]$builder.Append('!')
            [void]$builder.Append($char.ToString().ToLowerInvariant())
        }
        else {
            [void]$builder.Append($char)
        }
    }
    return $builder.ToString()
}

function ConvertTo-GoProxyRelativePath {
    param([Parameter(Mandatory = $true)][string]$ModulePath)
    return (Escape-GoProxySegment -Value $ModulePath).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

function Join-Url {
    param(
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][string]$Path
    )
    return $Base.TrimEnd('/') + '/' + $Path.TrimStart('/')
}

function Invoke-Http {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers = @{},
        [string]$OutFile = '',
        [switch]$ReturnResponse
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

    if ($ReturnResponse) {
        $parameters.ResponseHeadersVariable = 'responseHeaders'
    }

    try {
        $result = Invoke-WebRequest @parameters
        if ($ReturnResponse) {
            return [pscustomobject]@{
                Body    = $result
                Headers = $responseHeaders
            }
        }
        return $result
    }
    catch {
        $message = $_.Exception.Message
        $response = $null
        if ($_.Exception.PSObject.Properties['Response']) {
            $response = $_.Exception.Response
        }

        if ($response) {
            $statusCode = [int]$response.StatusCode
            $message = "HTTP $statusCode from $Uri"
        }
        throw $message
    }
}

function ConvertFrom-HttpContent {
    param([AllowNull()]$Content)

    if ($null -eq $Content) {
        return ''
    }

    if ($Content -is [byte[]]) {
        return [System.Text.Encoding]::UTF8.GetString($Content)
    }

    return [string]$Content
}

function Invoke-Json {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers = @{}
    )
    $response = Invoke-Http -Uri $Uri -Headers $Headers
    $content = ConvertFrom-HttpContent -Content $response.Content
    if (-not $content) {
        return $null
    }
    return $content | ConvertFrom-Json
}

function Get-DefaultGoProxies {
    if ($Proxy.Count -gt 0) {
        return $Proxy
    }

    if ($env:GOPROXY) {
        return $env:GOPROXY.Split(',') | Where-Object { $_ }
    }

    return @('https://proxy.golang.org', 'direct')
}

function Get-ModuleFromProxy {
    param(
        [Parameter(Mandatory = $true)][string]$ModulePath,
        [Parameter(Mandatory = $true)][string]$RequestedVersion,
        [Parameter(Mandatory = $true)][string]$ProxyBase,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $escapedModule = Escape-GoProxySegment -Value $ModulePath
    $moduleBaseUrl = Join-Url -Base $ProxyBase -Path $escapedModule

    $resolvedVersion = $RequestedVersion
    if ($RequestedVersion -eq 'latest') {
        $latestUrl = Join-Url -Base $moduleBaseUrl -Path '@latest'
        Write-Verbose "Resolving latest version from $latestUrl"
        $latest = Invoke-Json -Uri $latestUrl
        $resolvedVersion = $latest.Version
    }

    $escapedVersion = Escape-GoProxySegment -Value $resolvedVersion
    $versionBase = Join-Url -Base $moduleBaseUrl -Path '@v'

    New-Directory -Path $Destination

    $infoFile = Join-Path $Destination "$escapedVersion.info"
    $modFile = Join-Path $Destination "$escapedVersion.mod"
    $zipFile = Join-Path $Destination "$escapedVersion.zip"

    Invoke-Http -Uri (Join-Url -Base $versionBase -Path "$escapedVersion.info") -OutFile $infoFile | Out-Null
    Invoke-Http -Uri (Join-Url -Base $versionBase -Path "$escapedVersion.mod") -OutFile $modFile | Out-Null
    Invoke-Http -Uri (Join-Url -Base $versionBase -Path "$escapedVersion.zip") -OutFile $zipFile | Out-Null

    if ($Expand) {
        $expandedPath = Join-Path $Destination $escapedVersion
        New-Directory -Path $expandedPath
        Expand-Archive -LiteralPath $zipFile -DestinationPath $expandedPath -Force
    }

    return [pscustomobject]@{
        Mode        = 'ModuleProxy'
        Module      = $ModulePath
        Version     = $resolvedVersion
        Proxy       = $ProxyBase
        InfoFile    = $infoFile
        ModFile     = $modFile
        ZipFile     = $zipFile
        ExpandedTo  = if ($Expand) { Join-Path $Destination $escapedVersion } else { $null }
    }
}

function Get-GitLabHeaders {
    if (-not $GitLabToken) {
        return @{}
    }
    return @{ 'PRIVATE-TOKEN' = $GitLabToken }
}

function Get-GitHubHeaders {
    $headers = @{ 'User-Agent' = 'PowerShell-Go-Library-Retriever' }
    if ($GitHubToken) {
        $headers.Authorization = "Bearer $GitHubToken"
    }
    return $headers
}

function Get-UrlEncoded {
    param([Parameter(Mandatory = $true)][string]$Value)
    return [System.Uri]::EscapeDataString($Value)
}

function Get-GoImportMeta {
    param([Parameter(Mandatory = $true)][string]$ModulePath)

    $parts = $ModulePath.Split('/')
    for ($length = $parts.Length; $length -ge 2; $length--) {
        $prefix = ($parts[0..($length - 1)] -join '/')
        $uri = "https://$prefix" + '?go-get=1'

        try {
            $response = Invoke-Http -Uri $uri
            $contentText = ConvertFrom-HttpContent -Content $response.Content
            $matches = [regex]::Matches($contentText, '<meta\s+[^>]*name=["'']go-import["''][^>]*content=["'']([^"'']+)["''][^>]*>', 'IgnoreCase')
            foreach ($match in $matches) {
                $content = $match.Groups[1].Value.Trim()
                $fields = $content -split '\s+'
                if ($fields.Count -ge 3 -and $ModulePath.StartsWith($fields[0])) {
                    return [pscustomobject]@{
                        Prefix   = $fields[0]
                        Vcs      = $fields[1]
                        RepoRoot = $fields[2]
                    }
                }
            }
        }
        catch {
            Write-Verbose "go-import probe failed for $prefix"
        }
    }

    return $null
}

function ConvertTo-SemVer {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($Name -match '^v?(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$') {
        return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
    }
    return $null
}

function Select-LatestTagName {
    param([Parameter(Mandatory = $true)]$Tags)

    $versionedTags = @()
    foreach ($tag in $Tags) {
        $name = if ($tag.name) { $tag.name } else { [string]$tag }
        $version = ConvertTo-SemVer -Name $name
        if ($version) {
            $versionedTags += [pscustomobject]@{
                Name    = $name
                Version = $version
            }
        }
    }

    if ($versionedTags.Count -eq 0) {
        return ''
    }

    return ($versionedTags | Sort-Object -Property Version -Descending | Select-Object -First 1).Name
}

function Get-GitHubRepositoryFromPath {
    param([Parameter(Mandatory = $true)][string]$ModulePath)

    $uri = $null
    if ([System.Uri]::TryCreate($ModulePath, [System.UriKind]::Absolute, [ref]$uri)) {
        $path = $uri.AbsolutePath.Trim('/')
        $parts = $path.Split('/')
    }
    else {
        $parts = $ModulePath.Split('/')
        if ($parts.Count -lt 3 -or $parts[0] -ne 'github.com') {
            throw "GitHub module paths must look like github.com/owner/repository."
        }
        $parts = $parts[1..($parts.Count - 1)]
    }

    if ($parts.Count -lt 2) {
        throw "GitHub module paths must include an owner and repository."
    }

    return [pscustomobject]@{
        Owner = $parts[0]
        Repo  = $parts[1] -replace '\.git$', ''
    }
}

function Get-GitHubLatestRef {
    param(
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$Repo
    )

    $headers = Get-GitHubHeaders
    $tagsUri = "https://api.github.com/repos/$Owner/$Repo/tags?per_page=100"
    $tags = Invoke-Json -Uri $tagsUri -Headers $headers
    $latestTag = Select-LatestTagName -Tags $tags
    if ($latestTag) {
        return $latestTag
    }

    $repositoryUri = "https://api.github.com/repos/$Owner/$Repo"
    $repository = Invoke-Json -Uri $repositoryUri -Headers $headers
    if ($repository.default_branch) {
        return $repository.default_branch
    }

    throw "Could not resolve latest ref for github.com/$Owner/$Repo."
}

function Get-ModuleFromGitHub {
    param(
        [Parameter(Mandatory = $true)][string]$ModulePath,
        [Parameter(Mandatory = $true)][string]$RequestedVersion,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $repository = Get-GitHubRepositoryFromPath -ModulePath $ModulePath
    $ref = if ($RequestedVersion -eq 'latest') {
        Get-GitHubLatestRef -Owner $repository.Owner -Repo $repository.Repo
    }
    else {
        $RequestedVersion
    }

    New-Directory -Path $Destination

    $safeRef = ConvertTo-SafeFileName -Value $ref
    $zipFile = Join-Path $Destination "$safeRef.github-archive.zip"
    $escapedRef = [System.Uri]::EscapeDataString($ref)
    $uri = "https://api.github.com/repos/$($repository.Owner)/$($repository.Repo)/zipball/$escapedRef"

    Invoke-Http -Uri $uri -Headers (Get-GitHubHeaders) -OutFile $zipFile | Out-Null

    if ($Expand) {
        $expandedPath = Join-Path $Destination $safeRef
        New-Directory -Path $expandedPath
        Expand-Archive -LiteralPath $zipFile -DestinationPath $expandedPath -Force
    }

    return [pscustomobject]@{
        Mode       = 'GitHubArchive'
        Module     = $ModulePath
        Ref        = $ref
        Owner      = $repository.Owner
        Repository = $repository.Repo
        ZipFile    = $zipFile
        ExpandedTo = if ($Expand) { Join-Path $Destination $safeRef } else { $null }
    }
}

function Find-GitLabProject {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][string]$ModulePath
    )

    if ($GitLabProjectPath) {
        return $GitLabProjectPath
    }

    $pathWithoutHost = $ModulePath
    if ($ModulePath.StartsWith("$HostName/")) {
        $pathWithoutHost = $ModulePath.Substring($HostName.Length + 1)
    }

    $parts = $pathWithoutHost.Split('/')
    for ($length = $parts.Length; $length -ge 2; $length--) {
        $candidate = ($parts[0..($length - 1)] -join '/')
        $encoded = Get-UrlEncoded -Value $candidate
        $uri = "https://$HostName/api/v4/projects/$encoded"

        try {
            Invoke-Json -Uri $uri -Headers (Get-GitLabHeaders) | Out-Null
            return $candidate
        }
        catch {
            Write-Verbose "GitLab project probe failed for $candidate"
        }
    }

    throw "Could not discover GitLab project for $ModulePath. Pass -GitLabProjectPath explicitly."
}

function Get-GitLabLatestRef {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][string]$EncodedProject
    )

    $headers = Get-GitLabHeaders
    $tagsUri = "https://$HostName/api/v4/projects/$EncodedProject/repository/tags?per_page=100"
    try {
        $tags = Invoke-Json -Uri $tagsUri -Headers $headers
        $latestTag = Select-LatestTagName -Tags $tags
        if ($latestTag) {
            return $latestTag
        }
    }
    catch {
        Write-Verbose "GitLab tag lookup failed for $EncodedProject"
    }

    try {
        $projectUri = "https://$HostName/api/v4/projects/$EncodedProject"
        $project = Invoke-Json -Uri $projectUri -Headers $headers
        if ($project.default_branch) {
            return $project.default_branch
        }
    }
    catch {
        Write-Verbose "GitLab default branch lookup failed for $EncodedProject"
    }

    return 'HEAD'
}

function Get-ModuleFromGitLab {
    param(
        [Parameter(Mandatory = $true)][string]$ModulePath,
        [Parameter(Mandatory = $true)][string]$RequestedVersion,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $hostName = $GitLabHost
    if (-not $hostName) {
        $hostName = $ModulePath.Split('/')[0]
    }

    $projectPath = Find-GitLabProject -HostName $hostName -ModulePath $ModulePath
    $encodedProject = Get-UrlEncoded -Value $projectPath
    $ref = if ($RequestedVersion -eq 'latest') {
        Get-GitLabLatestRef -HostName $hostName -EncodedProject $encodedProject
    }
    else {
        $RequestedVersion
    }

    New-Directory -Path $Destination

    $safeRef = ConvertTo-SafeFileName -Value $ref
    $zipFile = Join-Path $Destination "$safeRef.gitlab-archive.zip"
    $uri = "https://$hostName/api/v4/projects/$encodedProject/repository/archive.zip?sha=$([System.Uri]::EscapeDataString($ref))"

    Invoke-Http -Uri $uri -Headers (Get-GitLabHeaders) -OutFile $zipFile | Out-Null

    if ($Expand) {
        $expandedPath = Join-Path $Destination $safeRef
        New-Directory -Path $expandedPath
        Expand-Archive -LiteralPath $zipFile -DestinationPath $expandedPath -Force
    }

    return [pscustomobject]@{
        Mode           = 'GitLabArchive'
        Module         = $ModulePath
        Ref            = $ref
        GitLabHost     = $hostName
        GitLabProject  = $projectPath
        ZipFile        = $zipFile
        ExpandedTo     = if ($Expand) { Join-Path $Destination $safeRef } else { $null }
    }
}

function Get-ModuleDirect {
    param(
        [Parameter(Mandatory = $true)][string]$ModulePath,
        [Parameter(Mandatory = $true)][string]$RequestedVersion,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $hostName = $ModulePath.Split('/')[0]
    if ($hostName -eq 'github.com') {
        return Get-ModuleFromGitHub -ModulePath $ModulePath -RequestedVersion $RequestedVersion -Destination $Destination
    }

    if ($GitLabHost -or $hostName -match '(^|\.)gitlab\.') {
        return Get-ModuleFromGitLab -ModulePath $ModulePath -RequestedVersion $RequestedVersion -Destination $Destination
    }

    $meta = Get-GoImportMeta -ModulePath $ModulePath
    if ($meta -and $meta.Vcs -eq 'git') {
        $repoUri = [System.Uri]$meta.RepoRoot
        if ($repoUri.Host -eq 'github.com') {
            return Get-ModuleFromGitHub -ModulePath $meta.RepoRoot -RequestedVersion $RequestedVersion -Destination $Destination
        }

        if ($repoUri.Host -match '(^|\.)gitlab\.') {
            return Get-ModuleFromGitLab -ModulePath ($repoUri.Host + $repoUri.AbsolutePath.TrimEnd('/')) -RequestedVersion $RequestedVersion -Destination $Destination
        }

        throw "go-import metadata resolved to $($meta.RepoRoot), but direct archive retrieval is only implemented for GitHub and GitLab."
    }

    throw "Direct retrieval for $ModulePath is not supported. Use a Go module proxy or a GitHub/GitLab-backed module path."
}

function Split-GoModDirective {
    param([Parameter(Mandatory = $true)][string]$Line)

    $parts = @()
    foreach ($match in [regex]::Matches($Line, '"[^"]+"|\S+')) {
        $parts += $match.Value.Trim('"')
    }
    return $parts
}

function Test-LocalModulePath {
    param([Parameter(Mandatory = $true)][string]$ModulePath)

    return $ModulePath.StartsWith('.') -or
        $ModulePath.StartsWith('/') -or
        $ModulePath.StartsWith('\') -or
        $ModulePath -match '^[A-Za-z]:[\\/]'
}

function Get-GoModDirectives {
    param([Parameter(Mandatory = $true)][string]$ModFile)

    $requirements = @()
    $replacements = @()
    $exclusions = @()
    $blockDirective = ''

    foreach ($rawLine in Get-Content -LiteralPath $ModFile) {
        $line = ($rawLine -replace '//.*$', '').Trim()
        if (-not $line) {
            continue
        }

        if ($line -match '^(require|replace|exclude)\s+\($') {
            $blockDirective = $Matches[1]
            continue
        }

        if ($blockDirective -and $line -eq ')') {
            $blockDirective = ''
            continue
        }

        $directive = $blockDirective
        if (-not $directive) {
            $partsForDirective = Split-GoModDirective -Line $line
            if ($partsForDirective.Count -eq 0 -or $partsForDirective[0] -notin @('require', 'replace', 'exclude')) {
                continue
            }
            $directive = $partsForDirective[0]
            $line = $line.Substring($directive.Length).Trim()
        }

        $parts = Split-GoModDirective -Line $line
        if ($parts.Count -eq 0) {
            continue
        }

        if ($directive -eq 'require') {
            if ($parts.Count -lt 2) {
                continue
            }

            $requirements += [pscustomobject]@{
                Module  = $parts[0]
                Version = $parts[1]
            }
        }
        elseif ($directive -eq 'exclude') {
            if ($parts.Count -lt 2) {
                continue
            }

            $exclusions += [pscustomobject]@{
                Module  = $parts[0]
                Version = $parts[1]
            }
        }
        elseif ($directive -eq 'replace') {
            $arrowIndex = [array]::IndexOf($parts, '=>')
            if ($arrowIndex -lt 1 -or $arrowIndex -eq ($parts.Count - 1)) {
                continue
            }

            $oldParts = @($parts[0..($arrowIndex - 1)])
            $newParts = @($parts[($arrowIndex + 1)..($parts.Count - 1)])

            $replacements += [pscustomobject]@{
                OldModule  = $oldParts[0]
                OldVersion = if ($oldParts.Count -gt 1) { $oldParts[1] } else { '' }
                NewModule  = $newParts[0]
                NewVersion = if ($newParts.Count -gt 1) { $newParts[1] } else { '' }
                IsLocal    = Test-LocalModulePath -ModulePath $newParts[0]
            }
        }
    }

    return [pscustomobject]@{
        Requirements = $requirements
        Replacements = $replacements
        Exclusions   = $exclusions
    }
}

function Find-GoModReplacement {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Replacements,
        [Parameter(Mandatory = $true)][string]$ModulePath,
        [Parameter(Mandatory = $true)][string]$Version
    )

    foreach ($replacement in $Replacements) {
        if ($replacement.OldModule -eq $ModulePath -and $replacement.OldVersion -eq $Version) {
            return $replacement
        }
    }

    foreach ($replacement in $Replacements) {
        if ($replacement.OldModule -eq $ModulePath -and -not $replacement.OldVersion) {
            return $replacement
        }
    }

    return $null
}

function Test-GoModExcluded {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Exclusions,
        [Parameter(Mandatory = $true)][string]$ModulePath,
        [Parameter(Mandatory = $true)][string]$Version
    )

    foreach ($exclusion in $Exclusions) {
        if ($exclusion.Module -eq $ModulePath -and $exclusion.Version -eq $Version) {
            return $true
        }
    }

    return $false
}

function Compare-GoModuleVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    if ($Left -eq $Right) {
        return 0
    }

    $leftMatch = [regex]::Match($Left, '^v(\d+)\.(\d+)\.(\d+)(-.+)?(?:\+.*)?$')
    $rightMatch = [regex]::Match($Right, '^v(\d+)\.(\d+)\.(\d+)(-.+)?(?:\+.*)?$')

    if (-not $leftMatch.Success -or -not $rightMatch.Success) {
        return [string]::CompareOrdinal($Left, $Right)
    }

    for ($index = 1; $index -le 3; $index++) {
        $leftNumber = [int]$leftMatch.Groups[$index].Value
        $rightNumber = [int]$rightMatch.Groups[$index].Value
        if ($leftNumber -gt $rightNumber) {
            return 1
        }
        if ($leftNumber -lt $rightNumber) {
            return -1
        }
    }

    $leftPreRelease = $leftMatch.Groups[4].Value
    $rightPreRelease = $rightMatch.Groups[4].Value
    if (-not $leftPreRelease -and $rightPreRelease) {
        return 1
    }
    if ($leftPreRelease -and -not $rightPreRelease) {
        return -1
    }

    return [string]::CompareOrdinal($leftPreRelease, $rightPreRelease)
}

function ConvertTo-GoVersionObject {
    param([Parameter(Mandatory = $true)][string]$Value)

    $match = [regex]::Match($Value.Trim(), '(\d+)(?:\.(\d+))?(?:\.(\d+))?')
    if (-not $match.Success) {
        throw "Could not parse Go version '$Value'. Use a value like 1.26.5-1, 1.26.5, or 1.26."
    }

    $major = [int]$match.Groups[1].Value
    $minor = if ($match.Groups[2].Success) { [int]$match.Groups[2].Value } else { 0 }
    $patch = if ($match.Groups[3].Success) { [int]$match.Groups[3].Value } else { 0 }

    return [version]"$major.$minor.$patch"
}

function Test-GoDirectiveCompatible {
    param(
        [Parameter(Mandatory = $true)][string]$Directive,
        [Parameter(Mandatory = $true)][version]$TargetVersion
    )

    if (-not $Directive) {
        return $true
    }

    return ((ConvertTo-GoVersionObject -Value $Directive).CompareTo($TargetVersion) -le 0)
}

function Get-PackageAliasMap {
    return @{
        'air'                 = 'github.com/air-verse/air'
        'dlv'                 = 'github.com/go-delve/delve/cmd/dlv'
        'gocover-cobertura'   = 'github.com/boumenot/gocover-cobertura'
        'godoc'               = 'golang.org/x/tools/cmd/godoc'
        'gofumpt'             = 'mvdan.cc/gofumpt'
        'goimports'           = 'golang.org/x/tools/cmd/goimports'
        'golangci-lint'       = 'github.com/golangci/golangci-lint/v2/cmd/golangci-lint'
        'gopls'               = 'golang.org/x/tools/gopls'
        'gosec'               = 'github.com/securego/gosec/v2/cmd/gosec'
        'gotestsum'           = 'gotest.tools/gotestsum'
        'govulncheck'         = 'golang.org/x/vuln/cmd/govulncheck'
        'mockgen'             = 'go.uber.org/mock/mockgen'
        'protoc-gen-go'       = 'google.golang.org/protobuf/cmd/protoc-gen-go'
        'protoc-gen-go-grpc'  = 'google.golang.org/grpc/cmd/protoc-gen-go-grpc'
        'staticcheck'         = 'honnef.co/go/tools/cmd/staticcheck'
        'stringer'            = 'golang.org/x/tools/cmd/stringer'
    }
}

function Resolve-PackageModulePath {
    param([Parameter(Mandatory = $true)][string]$PackagePath)

    $aliases = Get-PackageAliasMap
    if ($aliases.ContainsKey($PackagePath)) {
        $PackagePath = $aliases[$PackagePath]
    }

    if ($PackagePath -in @(
            'golang.org/x/tools/cmd/godoc',
            'golang.org/x/tools/cmd/goimports',
            'golang.org/x/tools/cmd/stringer'
        )) {
        return [pscustomobject]@{
            PackagePath = $PackagePath
            ModulePath  = 'golang.org/x/tools'
        }
    }

    if ($PackagePath -eq 'github.com/golangci/golangci-lint/v2/cmd/golangci-lint') {
        return [pscustomobject]@{
            PackagePath = $PackagePath
            ModulePath  = 'github.com/golangci/golangci-lint/v2'
        }
    }

    if ($PackagePath -eq 'github.com/go-delve/delve/cmd/dlv') {
        return [pscustomobject]@{
            PackagePath = $PackagePath
            ModulePath  = 'github.com/go-delve/delve'
        }
    }

    if ($PackagePath -eq 'github.com/securego/gosec/v2/cmd/gosec') {
        return [pscustomobject]@{
            PackagePath = $PackagePath
            ModulePath  = 'github.com/securego/gosec/v2'
        }
    }

    if ($PackagePath -eq 'go.uber.org/mock/mockgen') {
        return [pscustomobject]@{
            PackagePath = $PackagePath
            ModulePath  = 'go.uber.org/mock'
        }
    }

    if ($PackagePath -eq 'golang.org/x/vuln/cmd/govulncheck') {
        return [pscustomobject]@{
            PackagePath = $PackagePath
            ModulePath  = 'golang.org/x/vuln'
        }
    }

    if ($PackagePath -eq 'google.golang.org/protobuf/cmd/protoc-gen-go') {
        return [pscustomobject]@{
            PackagePath = $PackagePath
            ModulePath  = 'google.golang.org/protobuf'
        }
    }

    if ($PackagePath -eq 'honnef.co/go/tools/cmd/staticcheck') {
        return [pscustomobject]@{
            PackagePath = $PackagePath
            ModulePath  = 'honnef.co/go/tools'
        }
    }

    return [pscustomobject]@{
        PackagePath = $PackagePath
        ModulePath  = $PackagePath
    }
}

function Get-GoDirectiveFromModContent {
    param([Parameter(Mandatory = $true)][string]$Content)

    foreach ($line in ($Content -split "`n")) {
        $clean = ($line -replace '//.*$', '').Trim()
        if ($clean -match '^go\s+([0-9]+(?:\.[0-9]+){1,2})$') {
            return $Matches[1]
        }
    }

    return ''
}

function Get-GoProxyVersions {
    param(
        [Parameter(Mandatory = $true)][string]$ModulePath,
        [Parameter(Mandatory = $true)][string]$ProxyBase
    )

    $escapedModule = Escape-GoProxySegment -Value $ModulePath
    $moduleBaseUrl = Join-Url -Base $ProxyBase -Path $escapedModule
    $listUrl = Join-Url -Base (Join-Url -Base $moduleBaseUrl -Path '@v') -Path 'list'
    $response = Invoke-Http -Uri $listUrl
    $content = ConvertFrom-HttpContent -Content $response.Content

    return @($content -split "`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ })
}

function Resolve-LatestCompatibleModuleVersion {
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][string]$ModulePath,
        [Parameter(Mandatory = $true)][version]$TargetGoVersion
    )

    $errors = @()
    foreach ($proxyBase in Get-DefaultGoProxies) {
        if ($proxyBase -eq 'off') {
            break
        }
        if ($proxyBase -eq 'direct') {
            continue
        }

        try {
            $versions = @(Get-GoProxyVersions -ModulePath $ModulePath -ProxyBase $proxyBase)
            $candidateChecks = @()
            $sortedVersions = @($versions)
            for ($index = 0; $index -lt $sortedVersions.Count; $index++) {
                for ($inner = $index + 1; $inner -lt $sortedVersions.Count; $inner++) {
                    if ((Compare-GoModuleVersion -Left $sortedVersions[$inner] -Right $sortedVersions[$index]) -gt 0) {
                        $tmp = $sortedVersions[$index]
                        $sortedVersions[$index] = $sortedVersions[$inner]
                        $sortedVersions[$inner] = $tmp
                    }
                }
            }

            $escapedModule = Escape-GoProxySegment -Value $ModulePath
            $moduleBaseUrl = Join-Url -Base $proxyBase -Path $escapedModule
            $versionBase = Join-Url -Base $moduleBaseUrl -Path '@v'

            foreach ($candidateVersion in $sortedVersions) {
                $escapedVersion = Escape-GoProxySegment -Value $candidateVersion
                try {
                    $modResponse = Invoke-Http -Uri (Join-Url -Base $versionBase -Path "$escapedVersion.mod")
                    $goDirective = Get-GoDirectiveFromModContent -Content (ConvertFrom-HttpContent -Content $modResponse.Content)
                    $compatible = Test-GoDirectiveCompatible -Directive $goDirective -TargetVersion $TargetGoVersion
                    $candidateChecks += "${candidateVersion}: go $goDirective compatible=$compatible"
                    if ($compatible) {
                        return [pscustomobject]@{
                            PackagePath = $PackagePath
                            ModulePath  = $ModulePath
                            Version     = $candidateVersion
                            GoDirective = $goDirective
                            Proxy       = $proxyBase
                        }
                    }
                }
                catch {
                    $candidateChecks += "${candidateVersion}: $($_.Exception.Message)"
                    Write-Verbose "Compatibility check failed for ${ModulePath}@${candidateVersion}: $($_.Exception.Message)"
                }
            }

            throw "No compatible versions found for $ModulePath on $proxyBase. Checked: $($candidateChecks -join '; ')"
        }
        catch {
            $errors += "${proxyBase}: $($_.Exception.Message)"
        }
    }

    throw "Could not resolve latest compatible version for $PackagePath using Go $TargetGoVersion. Attempts: $($errors -join ' | ')"
}

function Get-SelectedModuleVersions {
    param([Parameter(Mandatory = $true)][array]$Retrieved)

    $selectedByModule = @{}
    foreach ($item in $Retrieved) {
        if (-not $item.Module -or -not $item.Version) {
            continue
        }

        if (-not $selectedByModule.ContainsKey($item.Module) -or
            (Compare-GoModuleVersion -Left $item.Version -Right $selectedByModule[$item.Module].Version) -gt 0) {
            $selectedByModule[$item.Module] = $item
        }
    }

    $selected = @()
    $superseded = @()
    foreach ($item in $Retrieved) {
        if (-not $item.Module -or -not $item.Version) {
            continue
        }

        $chosen = $selectedByModule[$item.Module]
        if ($chosen.Version -eq $item.Version) {
            if (-not ($selected | Where-Object { $_.Module -eq $item.Module -and $_.Version -eq $item.Version })) {
                $selected += [pscustomobject]@{
                    Module  = $item.Module
                    Version = $item.Version
                }
            }
        }
        else {
            $superseded += [pscustomobject]@{
                Module            = $item.Module
                Version           = $item.Version
                SelectedVersion   = $chosen.Version
            }
        }
    }

    return [pscustomobject]@{
        Selected   = $selected | Sort-Object -Property Module, Version
        Superseded = $superseded | Sort-Object -Property Module, Version
    }
}

function Read-PackageList {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Package list file does not exist: $Path"
    }

    $entries = @()
    $lineNumber = 0
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $lineNumber++
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#')) {
            continue
        }

        $line = ($line -replace '\s+#.*$', '').Trim()
        if (-not $line) {
            continue
        }

        if ($line -match '^[A-Za-z_][A-Za-z0-9_]*=\($') {
            continue
        }

        if ($line -match '^go\s+install\s+') {
            $parts = @($line -split '\s+' | Where-Object { $_ })
            $line = $parts[-1]
        }

        $line = $line.Trim().TrimEnd(',').Trim('"', "'")
        if (-not $line -or $line -in @('(', ')')) {
            continue
        }

        $packagePath = ''
        $modulePath = ''
        $requestedVersion = ''
        $goDirective = ''
        $resolvedByCompatibility = $false

        if ($line -match '^(?<module>\S+)@(?<version>\S+)$') {
            $packagePath = $Matches.module
            $resolvedPath = Resolve-PackageModulePath -PackagePath $packagePath
            $modulePath = $resolvedPath.ModulePath
            $packagePath = $resolvedPath.PackagePath
            $requestedVersion = $Matches.version
        }
        else {
            $parts = @($line -split '[,\s]+' | Where-Object { $_ })
            if ($parts.Count -eq 2) {
                $packagePath = $parts[0].Trim('"', "'")
                $resolvedPath = Resolve-PackageModulePath -PackagePath $packagePath
                $modulePath = $resolvedPath.ModulePath
                $packagePath = $resolvedPath.PackagePath
                $requestedVersion = $parts[1].Trim('"', "'")
            }
            elseif ($parts.Count -eq 1) {
                if (-not $GoVersion) {
                    throw "Package list entry at ${Path}:$lineNumber does not include a version. Pass -GoVersion to resolve the latest compatible version."
                }

                $packagePath = $parts[0].Trim('"', "'")
                $resolvedPath = Resolve-PackageModulePath -PackagePath $packagePath
                $compatibility = Resolve-LatestCompatibleModuleVersion `
                    -PackagePath $resolvedPath.PackagePath `
                    -ModulePath $resolvedPath.ModulePath `
                    -TargetGoVersion (ConvertTo-GoVersionObject -Value $GoVersion)

                $packagePath = $compatibility.PackagePath
                $modulePath = $compatibility.ModulePath
                $requestedVersion = $compatibility.Version
                $goDirective = $compatibility.GoDirective
                $resolvedByCompatibility = $true
            }
        }

        if (-not $modulePath -or -not $requestedVersion) {
            throw "Invalid package list entry at ${Path}:$lineNumber. Use 'package', 'package@version', or 'package version'."
        }

        $entries += [pscustomobject]@{
            LineNumber               = $lineNumber
            Package                  = $packagePath
            Module                   = $modulePath
            Version                  = $requestedVersion
            ResolvedByCompatibility  = $resolvedByCompatibility
            CompatibleGoDirective    = $goDirective
        }
    }

    if ($entries.Count -eq 0) {
        throw "Package list file did not contain any package/version entries: $Path"
    }

    return $entries
}

function Export-GoProxyArtifact {
    param([Parameter(Mandatory = $true)]$RetrievalResult)

    if (-not $GoProxyDirectory) {
        return $null
    }

    if ($RetrievalResult.Mode -ne 'ModuleProxy') {
        return [pscustomobject]@{
            Exported = $false
            Reason   = "Only ModuleProxy retrievals can be exported to static Go proxy layout."
            Mode     = $RetrievalResult.Mode
        }
    }

    foreach ($path in @($RetrievalResult.InfoFile, $RetrievalResult.ModFile, $RetrievalResult.ZipFile)) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) {
            throw "Cannot export $($RetrievalResult.Module)@$($RetrievalResult.Version): missing proxy artifact $path"
        }
    }

    $escapedVersion = Escape-GoProxySegment -Value $RetrievalResult.Version
    $moduleRelativePath = ConvertTo-GoProxyRelativePath -ModulePath $RetrievalResult.Module
    $moduleProxyDirectory = Join-Path (Join-Path $GoProxyDirectory $moduleRelativePath) '@v'
    New-Directory -Path $moduleProxyDirectory

    $infoFile = Join-Path $moduleProxyDirectory "$escapedVersion.info"
    $modFile = Join-Path $moduleProxyDirectory "$escapedVersion.mod"
    $zipFile = Join-Path $moduleProxyDirectory "$escapedVersion.zip"
    $listFile = Join-Path $moduleProxyDirectory 'list'

    Copy-Item -LiteralPath $RetrievalResult.InfoFile -Destination $infoFile -Force
    Copy-Item -LiteralPath $RetrievalResult.ModFile -Destination $modFile -Force
    Copy-Item -LiteralPath $RetrievalResult.ZipFile -Destination $zipFile -Force

    $versions = @()
    if (Test-Path -LiteralPath $listFile) {
        $versions = @(Get-Content -LiteralPath $listFile | Where-Object { $_ })
    }
    if ($versions -notcontains $RetrievalResult.Version) {
        $versions += $RetrievalResult.Version
    }
    $versions | Sort-Object -Unique | Set-Content -LiteralPath $listFile -Encoding ASCII

    return [pscustomobject]@{
        Exported        = $true
        Module          = $RetrievalResult.Module
        Version         = $RetrievalResult.Version
        ModuleDirectory = $moduleProxyDirectory
        ListFile        = $listFile
        InfoFile        = $infoFile
        ModFile         = $modFile
        ZipFile         = $zipFile
    }
}

function Invoke-ModuleRetrieval {
    param(
        [Parameter(Mandatory = $true)][string]$ModulePath,
        [Parameter(Mandatory = $true)][string]$RequestedVersion
    )

    $moduleDestination = Join-Path (Join-Path $OutputDirectory 'modules') (ConvertTo-SafeFileName -Value $ModulePath)
    $errors = @()

    foreach ($proxyBase in Get-DefaultGoProxies) {
        if ($proxyBase -eq 'off') {
            break
        }

        try {
            $result = $null
            if ($proxyBase -eq 'direct') {
                $result = Get-ModuleDirect -ModulePath $ModulePath -RequestedVersion $RequestedVersion -Destination $moduleDestination
            }
            else {
                $result = Get-ModuleFromProxy -ModulePath $ModulePath -RequestedVersion $RequestedVersion -ProxyBase $proxyBase -Destination $moduleDestination
            }

            $goProxyExport = Export-GoProxyArtifact -RetrievalResult $result
            if ($goProxyExport) {
                $result | Add-Member -NotePropertyName GoProxyExport -NotePropertyValue $goProxyExport
            }
            return $result
        }
        catch {
            $errors += "${proxyBase}: $($_.Exception.Message)"
            Write-Verbose "Retrieval via $proxyBase failed for ${ModulePath}@${RequestedVersion}: $($_.Exception.Message)"
        }
    }

    if ($errors.Count -eq 0) {
        throw "Could not retrieve module $ModulePath because the proxy list disabled retrieval."
    }

    throw "Could not retrieve module $ModulePath. Attempts: $($errors -join ' | ')"
}

function Invoke-PackageListRetrieval {
    param([Parameter(Mandatory = $true)][string]$Path)

    $entries = Read-PackageList -Path $Path
    $results = @()
    $failures = @()

    foreach ($entry in $entries) {
        try {
            $retrieval = if ($ResolveDependencies) {
                Resolve-ModuleDependencyGraph -RootModule $entry.Module -RootVersion $entry.Version
            }
            else {
                Invoke-ModuleRetrieval -ModulePath $entry.Module -RequestedVersion $entry.Version
            }

            $results += [pscustomobject]@{
                LineNumber              = $entry.LineNumber
                Package                 = $entry.Package
                Module                  = $entry.Module
                Version                 = $entry.Version
                ResolvedByCompatibility = $entry.ResolvedByCompatibility
                CompatibleGoDirective   = $entry.CompatibleGoDirective
                Success                 = $true
                Result                  = $retrieval
            }
        }
        catch {
            $failure = [pscustomobject]@{
                LineNumber = $entry.LineNumber
                Package    = $entry.Package
                Module     = $entry.Module
                Version    = $entry.Version
                Error      = $_.Exception.Message
            }
            $failures += $failure
            $results += [pscustomobject]@{
                LineNumber              = $entry.LineNumber
                Package                 = $entry.Package
                Module                  = $entry.Module
                Version                 = $entry.Version
                ResolvedByCompatibility = $entry.ResolvedByCompatibility
                CompatibleGoDirective   = $entry.CompatibleGoDirective
                Success                 = $false
                Error                   = $failure.Error
            }
        }
    }

    return [pscustomobject]@{
        Mode         = 'ModulePackageList'
        PackageList  = (Resolve-Path -LiteralPath $Path).Path
        TargetGoVersion = if ($GoVersion) { (ConvertTo-GoVersionObject -Value $GoVersion).ToString() } else { '' }
        Requested    = $entries
        SuccessCount = @($results | Where-Object { $_.Success }).Count
        FailureCount = $failures.Count
        Results      = $results
        Failures     = $failures
    }
}

function Resolve-ModuleDependencyGraph {
    param(
        [Parameter(Mandatory = $true)][string]$RootModule,
        [Parameter(Mandatory = $true)][string]$RootVersion
    )

    $queue = [System.Collections.Queue]::new()
    $seen = @{}
    $retrieved = @()
    $failures = @()
    $replacements = @()
    $exclusions = @()
    $skipped = @()
    $isRoot = $true

    $queue.Enqueue([pscustomobject]@{
        Module  = $RootModule
        Version = $RootVersion
        Parent  = ''
    })

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $key = "$($current.Module)@$($current.Version)"
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true

        try {
            $result = Invoke-ModuleRetrieval -ModulePath $current.Module -RequestedVersion $current.Version
            $retrieved += $result

            if ($result.ModFile -and (Test-Path -LiteralPath $result.ModFile)) {
                $directives = Get-GoModDirectives -ModFile $result.ModFile
                if ($isRoot) {
                    $replacements = @($directives.Replacements)
                    $exclusions = @($directives.Exclusions)
                    $isRoot = $false
                }

                foreach ($requirement in $directives.Requirements) {
                    $childModule = $requirement.Module
                    $childVersion = $requirement.Version

                    if (Test-GoModExcluded -Exclusions $exclusions -ModulePath $childModule -Version $childVersion) {
                        $skipped += [pscustomobject]@{
                            Module  = $childModule
                            Version = $childVersion
                            Parent  = $key
                            Reason  = 'ExcludedByRootGoMod'
                        }
                        continue
                    }

                    $replacement = Find-GoModReplacement -Replacements $replacements -ModulePath $childModule -Version $childVersion
                    if ($replacement) {
                        if ($replacement.IsLocal) {
                            $skipped += [pscustomobject]@{
                                Module      = $childModule
                                Version     = $childVersion
                                Parent      = $key
                                Reason      = 'LocalReplaceCannotBeDownloaded'
                                Replacement = $replacement.NewModule
                            }
                            continue
                        }

                        $childModule = $replacement.NewModule
                        if ($replacement.NewVersion) {
                            $childVersion = $replacement.NewVersion
                        }
                    }

                    $childKey = "$childModule@$childVersion"
                    if (-not $seen.ContainsKey($childKey)) {
                        $queue.Enqueue([pscustomobject]@{
                            Module  = $childModule
                            Version = $childVersion
                            Parent  = $key
                        })
                    }
                }
            }
        }
        catch {
            $failures += [pscustomobject]@{
                Module  = $current.Module
                Version = $current.Version
                Parent  = $current.Parent
                Error   = $_.Exception.Message
            }
        }
    }

    $versionSelection = Get-SelectedModuleVersions -Retrieved $retrieved

    return [pscustomobject]@{
        Mode           = 'ModuleDependencyGraph'
        RootModule     = $RootModule
        RootVersion    = $RootVersion
        RetrievedCount = $retrieved.Count
        SelectedCount  = $versionSelection.Selected.Count
        SupersededCount = $versionSelection.Superseded.Count
        FailureCount   = $failures.Count
        SkippedCount   = $skipped.Count
        Replacements   = $replacements
        Exclusions     = $exclusions
        Skipped        = $skipped
        Selected       = $versionSelection.Selected
        Superseded     = $versionSelection.Superseded
        Retrieved      = $retrieved
        Failures       = $failures
    }
}

function Remove-TemporaryOutputDirectory {
    if ($script:UsingTemporaryOutputDirectory -and
        $OutputDirectory -and
        (Test-Path -LiteralPath $OutputDirectory)) {
        Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
    }
}

function Write-ResultAndExit {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][int]$Depth,
        [int]$ExitCode = 0
    )

    if ($Result -is [psobject]) {
        $Result | Add-Member -NotePropertyName WorkingOutputDirectory -NotePropertyValue $OutputDirectory -Force
        $Result | Add-Member -NotePropertyName TemporaryOutputDirectory -NotePropertyValue $script:UsingTemporaryOutputDirectory -Force
    }

    $json = $Result | ConvertTo-Json -Depth $Depth
    $json
    Remove-TemporaryOutputDirectory
    exit $ExitCode
}

New-Directory -Path $OutputDirectory

if ($PSCmdlet.ParameterSetName -eq 'Module') {
    if ($ResolveDependencies) {
        Write-ResultAndExit -Result (Resolve-ModuleDependencyGraph -RootModule $Module -RootVersion $Version) -Depth 30
    }

    Write-ResultAndExit -Result (Invoke-ModuleRetrieval -ModulePath $Module -RequestedVersion $Version) -Depth 20
}

if ($PSCmdlet.ParameterSetName -eq 'ModuleList') {
    $packageListResult = Invoke-PackageListRetrieval -Path $PackageListPath
    if ($packageListResult.FailureCount -gt 0) {
        Write-ResultAndExit -Result $packageListResult -Depth 40 -ExitCode 1
    }
    Write-ResultAndExit -Result $packageListResult -Depth 40
}
