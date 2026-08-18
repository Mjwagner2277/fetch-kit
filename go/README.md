# PowerShell Go Library Retrieval

`Get-GoLibrary.ps1` retrieves Go module source zips without calling the Go
toolchain or Git. It uses only PowerShell HTTP calls.

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

The script prints a JSON summary containing the paths it wrote.

## Authentication Notes

- GitLab source archives use `-GitLabToken` or `$env:GITLAB_TOKEN`.
- GitHub source archives use `-GitHubToken` or `$env:GITHUB_TOKEN`.

## Limitations

- This does not run `go mod tidy`, compile packages, or resolve every transitive
  dependency exactly the way the Go command does. `-ResolveDependencies` follows
  `require` directives from downloaded `go.mod` files and honors the root
  module's `replace` and `exclude` directives, but it does not evaluate build
  tags, package imports, workspace files, vendoring, checksum database
  verification, or module graph pruning with full Go command fidelity.
- Direct VCS retrieval is implemented for GitHub and GitLab REST archives, not
  arbitrary Git servers.
