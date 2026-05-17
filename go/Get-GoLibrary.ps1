<# 
.SYNOPSIS
Retrieves Go modules or OCI artifacts without using the Go toolchain.

.DESCRIPTION
This script emulates the retrieval part of `go get` with pure PowerShell.
It supports:

  1. Go module proxy protocol downloads (.info, .mod, .zip).
  2. Direct GitHub and GitLab repository archive downloads.
  3. Basic go-import vanity path discovery for GitHub/GitLab-backed modules.
  4. Generic OCI Registry v2 artifact/image pulls, including Docker Hub,
     GitLab Container Registry, and Iron Bank-style private registries.

It intentionally does not compile, install, or resolve the full Go module
graph. Passing -Module selects Go module retrieval; passing -Registry and
-Repository selects OCI artifact/image retrieval.
#>

[CmdletBinding(DefaultParameterSetName = 'Module')]
param(
    [Parameter(ParameterSetName = 'Module', Mandatory = $true)]
    [string]$Module,

    [Parameter(ParameterSetName = 'Module')]
    [string]$Version = 'latest',

    [Parameter(ParameterSetName = 'Module')]
    [string[]]$Proxy = @(),

    [Parameter(ParameterSetName = 'Module')]
    [string]$GitLabHost = '',

    [Parameter(ParameterSetName = 'Module')]
    [string]$GitLabProjectPath = '',

    [Parameter(ParameterSetName = 'Oci', Mandatory = $true)]
    [string]$Registry,

    [Parameter(ParameterSetName = 'Oci', Mandatory = $true)]
    [string]$Repository,

    [Parameter(ParameterSetName = 'Oci')]
    [string]$Reference = 'latest',

    [Parameter(ParameterSetName = 'Oci')]
    [string]$Platform = 'linux/amd64',

    [Parameter()]
    [string]$OutputDirectory = (Join-Path (Get-Location) 'go-library-cache'),

    [Parameter()]
    [string]$Username = $env:REGISTRY_USERNAME,

    [Parameter()]
    [string]$Password = $env:REGISTRY_PASSWORD,

    [Parameter()]
    [string]$BearerToken = $env:REGISTRY_BEARER_TOKEN,

    [Parameter()]
    [string]$GitLabToken = $env:GITLAB_TOKEN,

    [Parameter()]
    [string]$GitHubToken = $env:GITHUB_TOKEN,

    [Parameter(ParameterSetName = 'Module')]
    [switch]$ResolveDependencies,

    [Parameter()]
    [switch]$Expand
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Invoke-Json {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers = @{}
    )
    $response = Invoke-Http -Uri $Uri -Headers $Headers
    if (-not $response.Content) {
        return $null
    }
    return $response.Content | ConvertFrom-Json
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
            $matches = [regex]::Matches($response.Content, '<meta\s+[^>]*name=["'']go-import["''][^>]*content=["'']([^"'']+)["''][^>]*>', 'IgnoreCase')
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
        Selected   = @($selected | Sort-Object -Property Module, Version)
        Superseded = @($superseded | Sort-Object -Property Module, Version)
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
            if ($proxyBase -eq 'direct') {
                return Get-ModuleDirect -ModulePath $ModulePath -RequestedVersion $RequestedVersion -Destination $moduleDestination
            }

            return Get-ModuleFromProxy -ModulePath $ModulePath -RequestedVersion $RequestedVersion -ProxyBase $proxyBase -Destination $moduleDestination
        }
        catch {
            $errors += "${proxyBase}: $($_.Exception.Message)"
            Write-Verbose "Retrieval via $proxyBase failed for ${ModulePath}@${RequestedVersion}: $($_.Exception.Message)"
        }
    }

    throw "Could not retrieve module $ModulePath. Attempts: $($errors -join ' | ')"
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
    $selectedVersions = @($versionSelection.Selected)
    $supersededVersions = @($versionSelection.Superseded)
    $retrievedModules = @($retrieved)
    $failedModules = @($failures)
    $skippedModules = @($skipped)

    return [pscustomobject]@{
        Mode           = 'ModuleDependencyGraph'
        RootModule     = $RootModule
        RootVersion    = $RootVersion
        RetrievedCount = $retrievedModules.Count
        SelectedCount  = $selectedVersions.Count
        SupersededCount = $supersededVersions.Count
        FailureCount   = $failedModules.Count
        SkippedCount   = $skippedModules.Count
        Replacements   = $replacements
        Exclusions     = $exclusions
        Skipped        = $skippedModules
        Selected       = $selectedVersions
        Superseded     = $supersededVersions
        Retrieved      = $retrievedModules
        Failures       = $failedModules
    }
}

function Parse-WwwAuthenticate {
    param([Parameter(Mandatory = $true)][string]$Header)

    $challenge = @{}
    if ($Header -notmatch '^Bearer\s+(.*)$') {
        return $challenge
    }

    $pairs = $Matches[1]
    foreach ($match in [regex]::Matches($pairs, '(\w+)="([^"]*)"')) {
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

function Get-RegistryAuthHeader {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryHost,
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Action
    )

    if ($BearerToken) {
        return @{ Authorization = "Bearer $BearerToken" }
    }

    $pingUri = "https://$RegistryHost/v2/"
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

            $authHeader = $response.Headers['WWW-Authenticate']
            if (-not $authHeader) {
                throw "Registry requires authentication but did not send WWW-Authenticate."
            }

            $challenge = Parse-WwwAuthenticate -Header $authHeader
            if (-not $challenge.ContainsKey('realm')) {
                throw "Only Bearer-token registry authentication is supported by this script."
            }

            $scope = if ($challenge.ContainsKey('scope')) { $challenge['scope'] } else { "repository:${Repo}:${Action}" }
            $tokenQuery = '?scope=' + [System.Uri]::EscapeDataString($scope)
            if ($challenge.ContainsKey('service')) {
                $tokenQuery = '?service=' + [System.Uri]::EscapeDataString($challenge['service']) + '&scope=' + [System.Uri]::EscapeDataString($scope)
            }
            $tokenUri = $challenge['realm'] + $tokenQuery
            $headers = @{}
            $basic = Get-BasicAuthHeader
            if ($basic) {
                $headers.Authorization = $basic
            }

            $tokenResponse = Invoke-Json -Uri $tokenUri -Headers $headers
            $token = if ($tokenResponse.token) { $tokenResponse.token } else { $tokenResponse.access_token }
            if (-not $token) {
                throw "Registry token endpoint did not return a token."
            }
            return @{ Authorization = "Bearer $token" }
        }
    }
}

function Invoke-RegistryJson {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $response = Invoke-Http -Uri $Uri -Headers $Headers
    return $response.Content | ConvertFrom-Json
}

function Get-RegistryBlob {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryHost,
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Digest,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $safeDigest = ConvertTo-SafeFileName -Value $Digest
    $outFile = Join-Path $Destination $safeDigest
    if (Test-Path -LiteralPath $outFile) {
        return $outFile
    }

    $uri = "https://$RegistryHost/v2/$Repo/blobs/$Digest"
    Invoke-Http -Uri $uri -Headers $Headers -OutFile $outFile | Out-Null
    return $outFile
}

function Select-OciManifest {
    param(
        [Parameter(Mandatory = $true)]$Index,
        [Parameter(Mandatory = $true)][string]$RequestedPlatform
    )

    $parts = $RequestedPlatform.Split('/')
    $os = $parts[0]
    $architecture = if ($parts.Count -gt 1) { $parts[1] } else { '' }

    foreach ($manifest in $Index.manifests) {
        if (-not $manifest.platform) {
            continue
        }
        if ($manifest.platform.os -eq $os -and $manifest.platform.architecture -eq $architecture) {
            return $manifest.digest
        }
    }

    if ($Index.manifests.Count -gt 0) {
        return $Index.manifests[0].digest
    }

    throw "OCI index did not contain any manifests."
}

function Get-OciArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryHost,
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Ref,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if ($RegistryHost -eq 'docker.io') {
        $RegistryHost = 'registry-1.docker.io'
    }

    if ($RegistryHost -eq 'registry-1.docker.io' -and $Repo.Split('/').Count -eq 1) {
        $Repo = "library/$Repo"
    }

    New-Directory -Path $Destination
    $headers = Get-RegistryAuthHeader -RegistryHost $RegistryHost -Repo $Repo -Action 'pull'
    $headers.Accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

    $manifestUri = "https://$RegistryHost/v2/$Repo/manifests/$Ref"
    $manifest = Invoke-RegistryJson -Uri $manifestUri -Headers $headers

    if ($manifest.mediaType -in @('application/vnd.oci.image.index.v1+json', 'application/vnd.docker.distribution.manifest.list.v2+json')) {
        $digest = Select-OciManifest -Index $manifest -RequestedPlatform $Platform
        $manifestUri = "https://$RegistryHost/v2/$Repo/manifests/$digest"
        $manifest = Invoke-RegistryJson -Uri $manifestUri -Headers $headers
        $Ref = $digest
    }

    $manifestFile = Join-Path $Destination 'manifest.json'
    $manifest | ConvertTo-Json -Depth 100 | Set-Content -Path $manifestFile -Encoding UTF8

    $configFile = $null
    if ($manifest.config -and $manifest.config.digest) {
        $configFile = Get-RegistryBlob -RegistryHost $RegistryHost -Repo $Repo -Digest $manifest.config.digest -Destination $Destination -Headers $headers
    }

    $layerFiles = @()
    foreach ($layer in $manifest.layers) {
        $layerFiles += Get-RegistryBlob -RegistryHost $RegistryHost -Repo $Repo -Digest $layer.digest -Destination $Destination -Headers $headers
    }

    return [pscustomobject]@{
        Mode         = 'OciRegistry'
        Registry     = $RegistryHost
        Repository   = $Repo
        Reference    = $Ref
        Platform     = $Platform
        ManifestFile = $manifestFile
        ConfigFile   = $configFile
        LayerFiles   = $layerFiles
        OutputPath   = $Destination
    }
}

New-Directory -Path $OutputDirectory

if ($PSCmdlet.ParameterSetName -eq 'Module') {
    if ($ResolveDependencies) {
        Resolve-ModuleDependencyGraph -RootModule $Module -RootVersion $Version | ConvertTo-Json -Depth 30
        exit 0
    }

    Invoke-ModuleRetrieval -ModulePath $Module -RequestedVersion $Version | ConvertTo-Json -Depth 20
    exit 0
}

$ociDestination = Join-Path (Join-Path $OutputDirectory 'oci') (Join-Path (ConvertTo-SafeFileName -Value $Registry) (ConvertTo-SafeFileName -Value "$Repository-$Reference"))
$ociResult = Get-OciArtifact -RegistryHost $Registry -Repo $Repository -Ref $Reference -Destination $ociDestination
$ociResult | ConvertTo-Json -Depth 20
