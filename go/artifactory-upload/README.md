# Go Proxy Artifactory Upload

This folder contains a Bash uploader for publishing a static Go module proxy
tree into a JFrog Artifactory repository through Artifactory's artifact REST
API.

It is intended for the second half of an air-gap or constrained-network flow:

1. Use `../Get-GoLibrary.ps1 -GoProxyDirectory` to create a static Go proxy
   directory.
2. Transfer that directory to the environment that can reach Artifactory.
3. Run `upload-go-proxy-to-artifactory.sh` to publish the proxy tree.
4. Point Go clients at the Artifactory repository URL with `GOPROXY`.

The script does not require the Go toolchain, the JFrog CLI, or any Artifactory
client library. It uses standard Unix tools and `curl`.

## Files

- `upload-go-proxy-to-artifactory.sh` - Uploads static Go proxy files to
  Artifactory.
- `smoke-static-goproxy-artifactory-upload.sh` - Local smoke test. It starts a
  small HTTP server that behaves like Artifactory's upload endpoint and verifies
  paths, content, authentication, filtering, and upload order.

## Source Layout

The source directory should be a static Go proxy root. Typical contents look
like this:

```text
github.com/example/project/@v/list
github.com/example/project/@v/v1.2.3.info
github.com/example/project/@v/v1.2.3.mod
github.com/example/project/@v/v1.2.3.zip
```

`Get-GoLibrary.ps1 -GoProxyDirectory` writes this layout directly. A directory
already served by nginx as a static Go proxy is also suitable.

## Artifactory Repository

Use a local repository that can store generic artifacts or Go proxy artifacts.
The uploader sends one REST request per file:

```text
PUT <artifactory-url>/<repo>/<optional-prefix>/<relative-go-proxy-path>
```

For example, this local file:

```text
example.com/mod/@v/v1.0.0.mod
```

uploaded with:

```text
--artifactory-url https://artifactory.example.com/artifactory
--repo go-local
--target-prefix mirrored
```

becomes:

```text
https://artifactory.example.com/artifactory/go-local/mirrored/example.com/mod/@v/v1.0.0.mod
```

If you do not want an extra path segment in the repository, omit
`--target-prefix`.

## Basic Upload

Use an access token through the environment:

```bash
ARTIFACTORY_TOKEN=... ./upload-go-proxy-to-artifactory.sh \
  --source-dir ./go-proxy-cache \
  --artifactory-url https://artifactory.example.com/artifactory \
  --repo go-local
```

Run a preview first with `--dry-run`:

```bash
ARTIFACTORY_TOKEN=... ./upload-go-proxy-to-artifactory.sh \
  --source-dir ./go-proxy-cache \
  --artifactory-url https://artifactory.example.com/artifactory \
  --repo go-local \
  --dry-run
```

## Authentication

The script supports three Artifactory authentication styles.

Bearer token:

```bash
ARTIFACTORY_TOKEN=... ./upload-go-proxy-to-artifactory.sh \
  --source-dir ./go-proxy-cache \
  --artifactory-url https://artifactory.example.com/artifactory \
  --repo go-local
```

Legacy API key:

```bash
ARTIFACTORY_API_KEY=... ./upload-go-proxy-to-artifactory.sh \
  --source-dir ./go-proxy-cache \
  --artifactory-url https://artifactory.example.com/artifactory \
  --repo go-local
```

Basic auth:

```bash
ARTIFACTORY_USER=deployer ARTIFACTORY_PASSWORD=... \
  ./upload-go-proxy-to-artifactory.sh \
    --source-dir ./go-proxy-cache \
    --artifactory-url https://artifactory.example.com/artifactory \
    --repo go-local
```

Command-line equivalents are available with `--token`, `--api-key`, `--user`,
and `--password`, but environment variables are usually better for avoiding
shell history leaks.

## Published Files

By default, only standard Go proxy artifacts are uploaded:

- `@v/list`
- `@v/*.info`
- `@v/*.mod`
- `@v/*.zip`

Other files are skipped. This intentionally excludes local cache helper files
such as `.ziphash`.

Use `--all-files` only when you deliberately want every file under
`--source-dir` uploaded.

## Upload Ordering

The script uploads version artifacts first, then uploads `@v/list` files last.
That ordering matters because Go clients read `@v/list` to discover versions. If
the list appeared before the matching `.info`, `.mod`, and `.zip` files, a
client could briefly see a version that is not fully available yet.

## Client Configuration

After upload, point Go clients at the repository path that contains the static
proxy tree:

```bash
go env -w GOPROXY=https://artifactory.example.com/artifactory/go-local
```

If you used `--target-prefix mirrored`, include that prefix:

```bash
go env -w GOPROXY=https://artifactory.example.com/artifactory/go-local/mirrored
```

For fully offline environments, also disable the public checksum database unless
you have mirrored it separately:

```bash
go env -w GOSUMDB=off
```

## Local Smoke Test

Run the included smoke test from the `go/artifactory-upload` folder:

```bash
./smoke-static-goproxy-artifactory-upload.sh
```

The smoke test creates a temporary proxy tree, starts a local HTTP server that
accepts Artifactory-style `PUT` requests, runs the uploader, and verifies:

- expected files were uploaded
- bearer authentication was sent
- paths were preserved under the repository and target prefix
- `.ziphash` was skipped
- uploaded content matches the source
- `@v/list` files were uploaded last

The smoke test does not require Docker or Artifactory.

## Real Local Artifactory Test

For a full end-to-end local test, Docker Desktop must be running. Current
Artifactory OSS images require PostgreSQL rather than the old embedded Derby
database.

A minimal test flow is:

```bash
docker network create codex-artifactory-test-net

docker run -d --name codex-artifactory-postgres \
  --network codex-artifactory-test-net \
  -e POSTGRES_DB=artifactory \
  -e POSTGRES_USER=artifactory \
  -e POSTGRES_PASSWORD=artifactory \
  postgres:16-alpine

docker run -d --name codex-artifactory-oss-test \
  --network codex-artifactory-test-net \
  -p 127.0.0.1:8081:8081 \
  -p 127.0.0.1:8082:8082 \
  -e JF_SHARED_DATABASE_TYPE=postgresql \
  -e JF_SHARED_DATABASE_DRIVER=org.postgresql.Driver \
  -e JF_SHARED_DATABASE_URL=jdbc:postgresql://codex-artifactory-postgres:5432/artifactory \
  -e JF_SHARED_DATABASE_USERNAME=artifactory \
  -e JF_SHARED_DATABASE_PASSWORD=artifactory \
  -e JF_SHARED_SECURITY_JOINKEY=12345678901234567890123456789012 \
  -e JF_SHARED_SECURITY_MASTERKEY=1234567890123456789012345678901234567890123456789012345678901234 \
  releases-docker.jfrog.io/jfrog/artifactory-oss:latest

until curl -fsS http://127.0.0.1:8082/artifactory/api/system/ping; do
  sleep 2
done
```

Fresh Artifactory OSS containers include `example-repo-local`, which can be
used for throwaway testing:

```bash
./upload-go-proxy-to-artifactory.sh \
  --source-dir ./go-proxy-cache \
  --artifactory-url http://127.0.0.1:8082/artifactory \
  --repo example-repo-local \
  --target-prefix codex-go-proxy-test \
  --user admin \
  --password password
```

Clean up the throwaway containers when finished:

```bash
docker rm -f codex-artifactory-oss-test codex-artifactory-postgres
docker network rm codex-artifactory-test-net
```

## Troubleshooting

`401 Unauthorized`: verify the token, API key, or username/password. The token
must be allowed to deploy artifacts to the target repository.

`403 Forbidden`: the credentials are valid but do not have deploy permission.

`404 Not Found`: check `--artifactory-url` and `--repo`. The URL normally
includes `/artifactory`, and `--repo` should be only the repository key.

`400 Bad Request` while creating repositories in Artifactory OSS: repository
management APIs may require Artifactory Pro. Use an existing local repository
for OSS testing.

`curl: (60) SSL certificate problem`: install the Artifactory CA certificate in
the host trust store. Use `--insecure` only for disposable local testing.
