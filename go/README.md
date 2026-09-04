# Python Go Library Retrieval

`Get-GoLibrary.py` retrieves Go module source zips without calling the Go
toolchain or Git. It uses Python HTTP and archive libraries and writes JSON to
stdout. Progress messages are written to stderr with a `[go-fetch]` prefix.

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

The script intentionally does not compile or install Go code.

## Examples

Download a public Go module through the default Go proxy:

```bash
python3 Get-GoLibrary.py --module github.com/gorilla/mux --version v1.8.1 --expand
```

Force direct retrieval from GitHub without a module proxy:

```bash
python3 Get-GoLibrary.py \
  --module github.com/gorilla/mux \
  --version v1.8.1 \
  --proxy direct \
  --expand
```

Retrieve a module and every dependency listed in downloaded `go.mod` files:

```bash
python3 Get-GoLibrary.py \
  --module github.com/aquasecurity/table \
  --version v1.11.0 \
  --resolve-dependencies \
  --expand
```

Retrieve a saved list of packages, resolve latest versions compatible with a
target Go version, and export them in static Go proxy layout:

```bash
python3 Get-GoLibrary.py \
  --package-list-path go-tools.txt \
  --go-version 1.26.5-1 \
  --proxy https://proxy.golang.org \
  --archive-output go-proxy-cache.tar.gz
```

Package-list retrieval defaults to static Go proxy output under:

```text
./go-proxy-cache
```

`--archive-output` creates a tar.gz whose contents are the files inside the
proxy cache root. After transfer, extract it directly into a staging directory
and upload that directory to Artifactory.

Pass `--go-proxy-directory` only when you want a different proxy cache folder:

```bash
python3 Get-GoLibrary.py \
  --package-list-path go-tools.txt \
  --go-version 1.26.5-1 \
  --go-proxy-directory custom-go-proxy-cache
```

`go-tools.txt` can contain bare package names, full package paths, pinned
`package@version` entries, `package version` entries, comments, or copied
`go install package@version` lines:

```text
# Editor tooling
gopls
goimports
gofumpt

# Pinned entries
golang.org/x/tools/gopls@v0.23.0
github.com/boumenot/gocover-cobertura v1.5.0
go install honnef.co/go/tools/cmd/staticcheck@v0.7.0
```

Bare entries require `--go-version`. The resolver normalizes values like
`1.26.5-1` to the Go language version `1.26.5`, checks existing static proxy
cache entries first, probes upstream `@latest`, and only scans the full version
list when latest is not compatible.

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

## Output

For package-list retrieval, output defaults to static Go proxy layout under:

```text
./go-proxy-cache
```

The usual package-list command writes durable `.info`, `.mod`, `.zip`, and
`list` files directly into the folder you can transfer to your internal static
proxy:

```bash
python3 Get-GoLibrary.py \
  --package-list-path go-tools.txt \
  --go-version 1.26.5-1
```

For single-module retrieval without `--go-proxy-directory`, downloads are
written under:

```text
./go-library-cache
```

For a single module, pass `--go-proxy-directory` when you want static proxy
output:

```bash
python3 Get-GoLibrary.py \
  --module github.com/gorilla/mux \
  --version v1.8.1 \
  --go-proxy-directory go-proxy-cache
```

When `--go-proxy-directory` is used without `--output-directory` or `--expand`,
the script uses a temporary working cache and removes it after writing the proxy
tree. Use `--output-directory` when you want to keep the download cache for
debugging, auditing, or expanded source inspection.

The script checks `--go-proxy-directory` before downloading. If the requested
module version already has complete `.info`, `.mod`, `.zip`, and `list` entries,
it reuses those files and skips upstream proxy calls.

Module proxy downloads save:

- `version.info`
- `version.mod`
- `version.zip`
- expanded source, when `--expand` is used

When `--resolve-dependencies` is used, the script prints a dependency graph
summary with every retrieved module, root `replace`/`exclude` directives,
skipped local replacements, and any failures.

For routine tool seeding, leave `--resolve-dependencies` off. A package list of
Go developer tools should usually export only the command modules needed for
`go install package@version`. Dependency graph retrieval is much larger and can
take a long time behind an internal proxy or inspection gateway; use it only
when intentionally pre-seeding the full transitive module closure.

## Static Proxy Transfer

After transferring `go-proxy-cache` into your internal static proxy, Go clients
can install command packages directly:

```bash
go env -w GOPROXY=https://goproxy.internal.example.com
go env -w GOSUMDB=off

go install golang.org/x/tools/gopls@v0.23.0
go install honnef.co/go/tools/cmd/staticcheck@v0.7.0
```

Use `GOSUMDB=off` only for isolated environments that cannot reach the public
checksum database. If you run an internal checksum database, point `GOSUMDB` at
that instead.

## Artifactory

After exporting a static proxy tree or transfer archive, use
[`artifactory-upload/upload-go-proxy-to-artifactory.sh`](artifactory-upload/upload-go-proxy-to-artifactory.sh)
to publish it into an Artifactory repository.

```bash
mkdir -p /tmp/go-proxy-cache
tar -xzf go-proxy-cache.tar.gz -C /tmp/go-proxy-cache

ARTIFACTORY_TOKEN=... ./artifactory-upload/upload-go-proxy-to-artifactory.sh \
  --source-dir /tmp/go-proxy-cache \
  --artifactory-url https://artifactory.example.com/artifactory \
  --repo go-local
```

See [`artifactory-upload/README.md`](artifactory-upload/README.md) for
authentication options, upload ordering details, local testing instructions, and
Artifactory examples.

## Vulnerability CSV

`Get-GoVulnDb.py` mirrors the Go vulnerability database zip so it can be moved
with the package archive:

```bash
python3 Get-GoVulnDb.py --output go-vulndb/vulndb.zip
```

`Scan-GoProxyVulns.py` scans downloaded module versions in a static proxy cache
against that offline database and writes a CSV:

```bash
python3 Scan-GoProxyVulns.py \
  --go-proxy-directory go-proxy-cache \
  --vuln-db go-vulndb/vulndb.zip \
  --output-csv go-vuln-report.csv
```

The scanner is a module-version scan. It does not do `govulncheck` reachability
or symbol analysis, so findings mean the downloaded version matches an affected
range, not necessarily that an application calls vulnerable code.

The CSV includes every downloaded package/module version, its `go` directive,
the number of matching advisories, the highest-ranked CVE/advisory, fixed
version, and the fixed version's `go` directive. The fixed Go directive comes
from the local proxy cache when present; when the helper is given `--proxy`, it
can also look up the fixed version's `.mod` file from that proxy during the
connected-side run.

Run the whole connected-side workflow with one helper:

```bash
python3 Run-GoAirgapWorkflow.py \
  --package-list-path go-tools.txt \
  --go-version 1.26.5-1 \
  --proxy https://proxy.golang.org \
  --output-directory go-airgap-output
```

That writes:

```text
go-airgap-output/go-proxy-cache/
go-airgap-output/go-proxy-cache.tar.gz
go-airgap-output/go-vulndb/vulndb.zip
go-airgap-output/go-vuln-report.csv
go-airgap-output/go-vuln-report.json
```

## Local Smoke Test

The smoke test uses local Python HTTP servers and the local Go command. It does
not require PowerShell.

```bash
./tests/smoke-static-goproxy.sh
./tests/smoke-goproxy-artifactory-e2e.sh
./tests/smoke-go-vuln-workflow.sh
```

The first test verifies static proxy output can be consumed by `go`. The second
test verifies the full handoff flow: download, tar, extract, upload to a local
Artifactory-style endpoint, then consume that endpoint with `go mod download`
and `go install package@version`. The third test verifies the wrapper and
offline vulnerability CSV generation with a synthetic vuln DB.
