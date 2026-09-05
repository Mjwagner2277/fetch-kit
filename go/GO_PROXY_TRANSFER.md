# Static Go Proxy Transfer

`Get-GoLibrary.py` can write a proxy-native output tree shaped like the Go
module proxy protocol. Copy that tree to a Linux host and merge it into an
existing static internal Go proxy.

## Fetch On The Connected Host

Create a saved package list:

```text
gopls
goimports
gofumpt
gocover-cobertura
golangci-lint
staticcheck
govulncheck
gotestsum
```

Or start with `recommended-go-tools.txt` and remove anything your environment
does not need.

Download the latest versions compatible with your target Go version and export
static proxy files plus a transfer archive:

```bash
python3 Get-GoLibrary.py \
  --package-list-path go-tools.txt \
  --go-version 1.26.5-1 \
  --proxy https://proxy.golang.org \
  --go-proxy-directory go-proxy-cache \
  --archive-output go-proxy-cache.tar.gz
```

In this mode, `--go-proxy-directory` is the local cache root and
`--archive-output` is the artifact you transfer. The archive contains the
contents of the proxy root, not a nested `go-proxy-cache` parent folder. Because
`--output-directory` is not provided and `--expand` is not used, the script uses
a temporary working cache and removes it after the proxy tree is written.

The script checks `--go-proxy-directory` before downloading. If a complete module
version already exists there, it reuses the existing `.info`, `.mod`, `.zip`, and
`list` files. Bare entries resolved with `--go-version` also prefer compatible
versions already present in the proxy directory before calling an upstream proxy.

For dependency closure from each root package, add:

```bash
--resolve-dependencies
```

If you also want a durable download cache or expanded source for inspection,
provide `--output-directory` explicitly:

```bash
python3 Get-GoLibrary.py \
  --package-list-path go-tools.txt \
  --go-version 1.26.5-1 \
  --proxy https://proxy.golang.org \
  --go-proxy-directory go-proxy-cache \
  --output-directory go-library-cache \
  --expand
```

You can still pin exact versions when needed:

```text
golang.org/x/tools/gopls@v0.23.0
github.com/boumenot/gocover-cobertura v1.5.0
```

Pinned entries do not require `--go-version`; bare entries do.

Built-in short names currently include:

- `air`
- `dlv`
- `gopls`
- `godoc`
- `gofumpt`
- `goimports`
- `gocover-cobertura`
- `golangci-lint`
- `gosec`
- `gotestsum`
- `govulncheck`
- `mockgen`
- `protoc-gen-go`
- `protoc-gen-go-grpc`
- `staticcheck`
- `stringer`

## Resulting Proxy Layout

The `--go-proxy-directory` tree uses the protocol layout expected by the Go
command:

```text
go-proxy-cache/
  golang.org/x/tools/gopls/@v/
    list
    v0.23.0.info
    v0.23.0.mod
    v0.23.0.zip
```

Uppercase module path characters are escaped using the Go proxy convention.

## Transfer And Install On Linux

Copy `go-proxy-cache.tar.gz` to the Linux host, then extract into a staging
directory:

```bash
mkdir -p /tmp/go-proxy-cache
tar -xzf go-proxy-cache.tar.gz -C /tmp/go-proxy-cache
```

To merge into an existing static file Go proxy, run:

```bash
sudo ./scripts/install-static-goproxy-cache.sh /tmp/go-proxy-cache /srv/goproxy
```

If your existing static proxy root is already writable by your user or your
deployment account, skip `sudo`:

```bash
./scripts/install-static-goproxy-cache.sh --no-sudo /tmp/go-proxy-cache /srv/goproxy
```

The helper merges files additively. It does not delete existing module versions.
Under the hood, this is equivalent to:

```bash
rsync -a ./go-proxy-cache/ /srv/goproxy/
```

Client configuration:

```bash
go env -w GOPROXY=https://goproxy.internal.example.com
go env -w GOSUMDB=off
```

To upload the same extracted tree into Artifactory instead, run:

```bash
ARTIFACTORY_TOKEN=... ./artifactory-upload/upload-go-proxy-to-artifactory.sh \
  --source-dir /tmp/go-proxy-cache \
  --artifactory-url https://artifactory.example.com/artifactory \
  --repo go-local
```

Use `GOSUMDB=off` only for isolated environments that cannot reach the public
checksum database. If you run an internal checksum database, point `GOSUMDB` at
that instead.

## Vulnerability Report Handoff

For a connected-side run that downloads packages, mirrors the Go vulnerability
database, creates the tar.gz transfer artifact, and writes the CSV report:

```bash
python3 Run-GoAirgapWorkflow.py \
  --package-list-path go-tools.txt \
  --go-version 1.26.5-1 \
  --proxy https://proxy.golang.org \
  --output-directory go-airgap-output
```

Transfer these files together:

```text
go-airgap-output/go-proxy-cache.tar.gz
go-airgap-output/go-vulndb/vulndb.zip
go-airgap-output/go-vuln-report.csv
```

The CSV is a module-version report. It includes every downloaded package/module
version, matching vulnerability count, highest-ranked CVE/advisory, fixed
version, CVE score, and the fixed version's Go directive. The helper can read
the fixed Go directive from the same `--proxy` during the connected-side run
even when the fixed version itself was not downloaded into the transfer cache.

## Local Smoke Test

The smoke test is intentionally separate from `Get-GoLibrary.py`. It uses
local Python HTTP servers and the local Go command, which the production transfer
host may not have.

```bash
./tests/smoke-static-goproxy.sh
```

The test creates a fake upstream Go proxy, downloads one module with
`Get-GoLibrary.py`, exports it to static proxy layout, installs that export
into a temporary static proxy root, and verifies both `go mod download` and
`go install package@version` can consume it.
