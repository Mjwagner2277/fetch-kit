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
goimports
gofumpt
golangci-lint
staticcheck
govulncheck
gotestsum
golang.org/x/tools/gopls@v0.23.0
github.com/boumenot/gocover-cobertura v1.5.0
```

Bare entries require `-GoVersion`; the script checks proxy module versions from
newest to oldest and selects the first version whose `go` directive is
compatible with the target version. Inputs like `1.26.5-1` are normalized to the
Go language version `1.26.5`. The resolver first checks versions already present
in `-GoProxyDirectory`, then probes the upstream proxy's `@latest` endpoint, and
only falls back to scanning the full version list when latest is not compatible.
Version lists and compatibility checks are cached within a run so aliases that
share a module do not repeat the same proxy requests.

Built-in short names currently include:

- `air`
- `dlv`
- `gocover-cobertura`
- `godoc`
- `gofumpt`
- `goimports`
- `golangci-lint`
- `gopls`
- `gosec`
- `gotestsum`
- `govulncheck`
- `mockgen`
- `protoc-gen-go`
- `protoc-gen-go-grpc`
- `staticcheck`
- `stringer`

Full package paths are also accepted. When a command package lives below its
module root, such as `golang.org/x/tools/cmd/goimports`, the script downloads
and exports the owning module, such as `golang.org/x/tools`, so
`go install package@version` can resolve the command from the static proxy.

See `recommended-go-tools.txt` for a starter package list.

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

## Publishing to Artifactory

After exporting a static proxy tree with `-GoProxyDirectory`, use
[`artifactory-upload/upload-go-proxy-to-artifactory.sh`](artifactory-upload/upload-go-proxy-to-artifactory.sh)
to publish the tree into an Artifactory repository through the REST API.

See [`artifactory-upload/README.md`](artifactory-upload/README.md) for
authentication options, upload ordering details, local testing instructions, and
Artifactory examples.

## Output

For package-list retrieval, output defaults to static Go proxy layout under:

```text
.\go-proxy-cache
```

This means the usual package-list command writes durable `.info`, `.mod`,
`.zip`, and `list` files directly into the folder you can transfer to your
internal static proxy:

```powershell
.\Get-GoLibrary.ps1 `
  -PackageListPath .\go-tools.txt `
  -GoVersion 1.26.5-1
```

Pass `-GoProxyDirectory` only when you want a different proxy-cache folder:

```powershell
.\Get-GoLibrary.ps1 `
  -PackageListPath .\go-tools.txt `
  -GoVersion 1.26.5-1 `
  -GoProxyDirectory .\custom-go-proxy-cache
```

For single-module retrieval without `-GoProxyDirectory`, downloads are written
under:

```text
.\go-library-cache
```

For a single module, pass `-GoProxyDirectory` when you want static proxy output:

```powershell
.\Get-GoLibrary.ps1 `
  -Module "github.com/gorilla/mux" `
  -Version "v1.8.1" `
  -GoProxyDirectory .\go-proxy-cache
```

When `-GoProxyDirectory` is used without `-OutputDirectory` or `-Expand`, the
script uses a temporary working cache and removes it after writing the proxy
tree. Use `-OutputDirectory` when you want to keep the download cache for
debugging, auditing, or expanded source inspection.

The script checks `-GoProxyDirectory` before downloading. If the requested
module version already has complete `.info`, `.mod`, `.zip`, and `list` entries
there, it reuses those files and skips upstream proxy calls. Bare package entries
with `-GoVersion` also check existing proxy-directory versions before asking an
upstream proxy for `@v/list`.

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

For routine tool seeding, leave `-ResolveDependencies` off. A package list of Go
developer tools should usually export only the command modules needed for
`go install package@version`. Dependency graph retrieval is intentionally much
larger and can take a long time behind an internal proxy or inspection gateway;
use it only when you are deliberately trying to pre-seed the full transitive
module closure for an air-gapped install path.

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

Progress messages are written to stderr with a `[go-fetch]` prefix so stdout can
remain valid JSON for automation. During package-list runs, those messages show
when each package is resolved, retrieved, reused from the static proxy cache, and
exported.

## Installing Tools From The Static Proxy

After transferring `go-proxy-cache` into your internal static proxy, Go clients
can install command packages directly:

```bash
go env -w GOPROXY=https://goproxy.internal.example.com
go env -w GOSUMDB=off

go install golang.org/x/tools/gopls@v0.23.0
go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.12.2
```

The package path used with `go install` may be deeper than the module path stored
in the proxy. That is expected. The Go command resolves the package to its owning
module and then fetches that module's `.info`, `.mod`, and `.zip` files from the
proxy.

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
