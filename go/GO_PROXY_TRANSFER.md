# Static Go Proxy Transfer

`Get-GoLibrary.ps1` can write a proxy-native output tree shaped like the Go
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
static proxy files:

```powershell
.\Get-GoLibrary.ps1 `
  -PackageListPath .\go-tools.txt `
  -GoVersion 1.26.5-1 `
  -Proxy @("https://proxy.golang.org") `
  -GoProxyDirectory .\go-proxy-cache
```

In this mode, `-GoProxyDirectory` is the artifact you transfer. Because
`-OutputDirectory` is not provided and `-Expand` is not used, the script uses a
temporary working cache and removes it after the proxy tree is written.

The script checks `-GoProxyDirectory` before downloading. If a complete module
version already exists there, it reuses the existing `.info`, `.mod`, `.zip`, and
`list` files. Bare entries resolved with `-GoVersion` also prefer compatible
versions already present in the proxy directory before calling an upstream proxy.

For dependency closure from each root package, add:

```powershell
-ResolveDependencies
```

If you also want a durable download cache or expanded source for inspection,
provide `-OutputDirectory` explicitly:

```powershell
.\Get-GoLibrary.ps1 `
  -PackageListPath .\go-tools.txt `
  -GoVersion 1.26.5-1 `
  -Proxy @("https://proxy.golang.org") `
  -GoProxyDirectory .\go-proxy-cache `
  -OutputDirectory .\go-library-cache `
  -Expand
```

You can still pin exact versions when needed:

```text
golang.org/x/tools/gopls@v0.23.0
github.com/boumenot/gocover-cobertura v1.5.0
```

Pinned entries do not require `-GoVersion`; bare entries do.

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

The `-GoProxyDirectory` tree uses the protocol layout expected by the Go
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

Copy `go-proxy-cache` to the Linux host, then run:

```bash
sudo ./scripts/install-static-goproxy-cache.sh ./go-proxy-cache /srv/goproxy
```

If your existing static proxy root is already writable by your user or your
deployment account, skip `sudo`:

```bash
./scripts/install-static-goproxy-cache.sh --no-sudo ./go-proxy-cache /srv/goproxy
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

Use `GOSUMDB=off` only for isolated environments that cannot reach the public
checksum database. If you run an internal checksum database, point `GOSUMDB` at
that instead.

## Local Smoke Test

The smoke test is intentionally separate from `Get-GoLibrary.ps1`. It uses
local Python HTTP servers and the local Go command, which the production transfer
host may not have.

```bash
./tests/smoke-static-goproxy.sh
```

The test creates a fake upstream Go proxy, downloads one module with
`Get-GoLibrary.ps1`, exports it to static proxy layout, installs that export
into a temporary static proxy root, and verifies both `go mod download` and
`go install package@version` can consume it.
