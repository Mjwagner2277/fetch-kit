# PowerShell Go Library Retrieval

`Get-GoLibrary.ps1` retrieves Go module source zips or OCI registry artifacts without
calling the Go toolchain, Git, Docker, or ORAS. It uses only PowerShell HTTP calls.

## What It Can Retrieve

- Go modules from a Go module proxy that implements the standard proxy protocol.
- Recursive dependency graphs by reading downloaded `go.mod` files and fetching
  required modules.
- Root module `replace` and `exclude` directives for dependency graph retrieval.
- Selected and superseded version summaries so repeated module requirements are
  visible in the output.
- Public or private GitHub repository archives through the GitHub REST API.
- Public or private GitLab repository archives through the GitLab REST API.
- Basic `go-import` vanity path discovery when the resolved repository is hosted
  on GitHub or GitLab.
- OCI image/artifact blobs from Registry v2-compatible registries, including:
  - Docker Hub, use `registry-1.docker.io` or `docker.io` as the registry host.
  - GitLab Container Registry.
  - Iron Bank-style private registries.

Go modules and OCI/container registries are different protocols. A Docker, GitLab
Container Registry, or Iron Bank registry can store OCI artifacts, but it does not
automatically behave like a Go module proxy unless your organization has published
Go module zips as OCI artifacts.

## Examples

Download a public Go module through the default Go proxy:

```powershell
.\Get-GoLibrary.ps1 -Module "github.com/gorilla/mux" -Version "v1.8.1" -Expand
```

Force direct retrieval from GitHub without a module proxy:

```powershell
.\Get-GoLibrary.ps1 `
  -Module "github.com/gorilla/mux" `
  -Version "v1.8.1" `
  -Proxy @("direct") `
  -Expand
```

Retrieve a module and every dependency listed in the downloaded `go.mod` files:

```powershell
.\Get-GoLibrary.ps1 `
  -Module "github.com/aquasecurity/table" `
  -Version "v1.11.0" `
  -ResolveDependencies `
  -Expand
```

Retrieve a saved list of packages, resolve the latest versions compatible with
a target Go version, and export them in static Go proxy layout:

```powershell
.\Get-GoLibrary.ps1 `
  -PackageListPath .\go-tools.txt `
  -GoVersion 1.26.5-1 `
  -Proxy @("https://proxy.golang.org") `
  -GoProxyDirectory .\go-proxy-cache
```

`go-tools.txt` can contain bare package names, full package paths, or pinned
versions:

```text
gopls
golangci-lint
golang.org/x/tools/gopls@v0.23.0
github.com/boumenot/gocover-cobertura v1.5.0
```

Bare entries require `-GoVersion`; the script checks proxy module versions from
newest to oldest and selects the first version whose `go` directive is
compatible with the target version. Inputs like `1.26.5-1` are normalized to the
Go language version `1.26.5`.

Built-in short names currently include `gopls`, `godoc`,
`gocover-cobertura`, and `golangci-lint`. Full package paths are also accepted.

Run a random 10-module retrieval test. Dependency resolution is enabled by
default for this test workflow:

```powershell
.\Test-GoLibrarySample.ps1 -SampleSize 10 -BatchSize 5
```

Run the same random sample workflow against direct single-module retrieval only:

```powershell
.\Test-GoLibrarySample.ps1 -SampleSize 10 -BatchSize 5 -SkipResolveDependencies
```

Use your own Go proxy chain:

```powershell
.\Get-GoLibrary.ps1 `
  -Module "gitlab.example.com/platform/private-lib" `
  -Version "v1.2.3" `
  -Proxy @("https://go-proxy.example.com", "direct") `
  -GitLabToken $env:GITLAB_TOKEN
```

Fetch directly from a private GitLab project archive:

```powershell
$env:GITLAB_TOKEN = "glpat-..."

.\Get-GoLibrary.ps1 `
  -Module "gitlab.example.com/group/subgroup/private-lib" `
  -Version "v1.2.3" `
  -Proxy @("direct") `
  -GitLabHost "gitlab.example.com" `
  -GitLabProjectPath "group/subgroup/private-lib" `
  -Expand
```

Pull an OCI artifact or image from Docker Hub:

```powershell
.\Get-GoLibrary.ps1 `
  -Registry "docker.io" `
  -Repository "library/alpine" `
  -Reference "3.20"
```

Pull from GitLab Container Registry:

```powershell
$env:REGISTRY_USERNAME = "oauth2"
$env:REGISTRY_PASSWORD = "glpat-..."

.\Get-GoLibrary.ps1 `
  -Registry "registry.gitlab.example.com" `
  -Repository "group/project/private-artifact" `
  -Reference "v1.2.3"
```

Pull from Iron Bank or another private OCI registry:

```powershell
$env:REGISTRY_USERNAME = "your-user"
$env:REGISTRY_PASSWORD = "your-token-or-password"

.\Get-GoLibrary.ps1 `
  -Registry "registry1.dso.mil" `
  -Repository "ironbank/namespace/artifact-name" `
  -Reference "1.0.0"
```

If your registry gives you a bearer token directly:

```powershell
.\Get-GoLibrary.ps1 `
  -Registry "registry.example.com" `
  -Repository "team/go-module-artifact" `
  -Reference "v1.2.3" `
  -BearerToken $env:REGISTRY_BEARER_TOKEN
```

## Output

By default, downloads are written under:

```text
.\go-library-cache
```

For routine static Go proxy updates, prefer `-GoProxyDirectory`:

```powershell
.\Get-GoLibrary.ps1 `
  -PackageListPath .\go-tools.txt `
  -GoVersion 1.26.5-1 `
  -GoProxyDirectory .\go-proxy-cache
```

When `-GoProxyDirectory` is used without `-OutputDirectory` or `-Expand`, the
script uses a temporary working cache and removes it after writing the proxy
tree. Use `-OutputDirectory` when you want to keep the download cache for
debugging, auditing, or expanded source inspection.

```powershell
.\Get-GoLibrary.ps1 `
  -PackageListPath .\go-tools.txt `
  -GoVersion 1.26.5-1 `
  -GoProxyDirectory .\go-proxy-cache `
  -OutputDirectory .\go-library-cache `
  -Expand
```

Module proxy downloads save:

- `version.info`
- `version.mod`
- `version.zip`
- expanded source, when `-Expand` is used

When `-ResolveDependencies` is used, the script prints a dependency graph
summary with every retrieved module, root `replace`/`exclude` directives,
skipped local replacements, and any failures.

The dependency graph summary includes:

- `RetrievedCount`: every module version downloaded.
- `SelectedCount`: the selected module set after highest-version selection.
- `SupersededCount`: downloaded module versions that were superseded by a newer
  version of the same module.
- `FailureCount`: modules that could not be retrieved.
- `SkippedCount`: modules intentionally skipped, such as local path
  replacements that cannot be fetched over HTTP.

`Test-GoLibrarySample.ps1` writes:

- `sample.json`: the randomly selected modules.
- `results.json`: one row per sampled module.
- `summary.json`: success/failure counts, batch counts, and failed module
  details.
- one `.log` file per sampled module.

OCI downloads save:

- `manifest.json`
- config blob
- layer blobs

The script prints a JSON summary containing the paths it wrote.

## Authentication Notes

- GitLab source archives use `-GitLabToken` or `$env:GITLAB_TOKEN`.
- GitHub source archives use `-GitHubToken` or `$env:GITHUB_TOKEN`.
- OCI registries use `-Username` and `-Password`, or the environment variables
  `$env:REGISTRY_USERNAME` and `$env:REGISTRY_PASSWORD`.
- For GitLab Container Registry, a personal access token, deploy token, or CI job
  token can be used as the password, depending on your GitLab setup.
- Iron Bank access usually depends on your organization-issued registry
  credentials or token.

## Limitations

- This does not run `go mod tidy`, compile packages, or resolve every transitive
  dependency exactly the way the Go command does. `-ResolveDependencies` follows
  `require` directives from downloaded `go.mod` files and honors the root
  module's `replace` and `exclude` directives, but it does not evaluate build
  tags, package imports, workspace files, vendoring, checksum database
  verification, or module graph pruning with full Go command fidelity.
- Direct VCS retrieval is implemented for GitHub and GitLab REST archives, not
  arbitrary Git servers.
- OCI artifact layers are downloaded as blobs. If you publish Go modules as OCI
  artifacts, your organization will need a convention for which layer contains
  the module zip or source archive.
