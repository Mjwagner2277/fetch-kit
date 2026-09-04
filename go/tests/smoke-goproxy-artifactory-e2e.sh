#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
uploader="${repo_root}/artifactory-upload/upload-go-proxy-to-artifactory.sh"

for command_name in bash curl go python3 tar mktemp; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "missing required command: $command_name" >&2
    exit 1
  fi
done

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/go-proxy-artifactory-e2e.XXXXXX")"
cleanup() {
  for pid in "${upstream_pid:-}" "${artifactory_pid:-}"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  chmod -R u+w "$tmp_dir" >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

upstream_dir="$tmp_dir/upstream"
download_dir="$tmp_dir/download"
staging_dir="$tmp_dir/staging"
upload_root="$tmp_dir/uploads"
client_download_dir="$tmp_dir/client-download"
client_install_dir="$tmp_dir/client-install"
archive_path="$download_dir/go-proxy-cache.tar.gz"
package_list="$tmp_dir/package-list.txt"
retrieval_result="$tmp_dir/retrieval-result.json"
upload_result="$tmp_dir/upload-result.txt"

mkdir -p \
  "$upstream_dir/example.com/smoke/@v" \
  "$download_dir" \
  "$staging_dir" \
  "$upload_root" \
  "$client_download_dir" \
  "$client_install_dir"

python3 - "$upstream_dir" <<'PY'
import pathlib
import sys
import zipfile

root = pathlib.Path(sys.argv[1])
version_dir = root / "example.com" / "smoke" / "@v"

(version_dir / "list").write_text("v0.0.1\nv0.0.2\n", encoding="utf-8")
(version_dir / "v0.0.1.info").write_text(
    '{"Version":"v0.0.1","Time":"2026-01-01T00:00:00Z"}\n',
    encoding="utf-8",
)
(version_dir / "v0.0.1.mod").write_text("module example.com/smoke\n\ngo 1.26\n", encoding="utf-8")
(version_dir / "v0.0.2.info").write_text(
    '{"Version":"v0.0.2","Time":"2026-02-01T00:00:00Z"}\n',
    encoding="utf-8",
)
(version_dir / "v0.0.2.mod").write_text("module example.com/smoke\n\ngo 1.27\n", encoding="utf-8")

for version, go_version in (("v0.0.1", "1.26"), ("v0.0.2", "1.27")):
    module_root = f"example.com/smoke@{version}"
    with zipfile.ZipFile(version_dir / f"{version}.zip", "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(f"{module_root}/go.mod", f"module example.com/smoke\n\ngo {go_version}\n")
        archive.writestr(f"{module_root}/smoke.go", "package smoke\n\nfunc Message() string { return \"ok\" }\n")
        archive.writestr(
            f"{module_root}/cmd/smoke-tool/main.go",
            'package main\n\nimport "fmt"\n\nfunc main() { fmt.Println("smoke-tool ok") }\n',
        )
PY

cat > "$tmp_dir/static_server.py" <<'PY'
import functools
import http.server
import socketserver
import sys

directory = sys.argv[1]
port_file = sys.argv[2]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=directory)

with socketserver.TCPServer(("127.0.0.1", 0), handler) as httpd:
    with open(port_file, "w", encoding="utf-8") as handle:
        handle.write(str(httpd.server_address[1]))
    httpd.serve_forever()
PY

start_static_server() {
  local directory="$1"
  local port_file="$2"

  python3 "$tmp_dir/static_server.py" "$directory" "$port_file" >"$port_file.log" 2>&1 &
  started_server_pid="$!"
  for _ in {1..50}; do
    if [[ -s "$port_file" ]]; then
      started_server_port="$(cat "$port_file")"
      return 0
    fi
    sleep 0.1
  done
  echo "server did not start: $directory" >&2
  kill "$started_server_pid" >/dev/null 2>&1 || true
  return 1
}

upstream_port_file="$tmp_dir/upstream.port"
start_static_server "$upstream_dir" "$upstream_port_file"
upstream_port="$started_server_port"
upstream_pid="$started_server_pid"

printf 'example.com/smoke\n' > "$package_list"
python3 "$repo_root/Get-GoLibrary.py" \
  --package-list-path "$package_list" \
  --go-version 1.26.5-1 \
  --proxy "http://127.0.0.1:$upstream_port" \
  --go-proxy-directory "$download_dir/go-proxy-cache" \
  --archive-output "$archive_path" >"$retrieval_result"

python3 - "$retrieval_result" "$archive_path" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
archive_path = pathlib.Path(sys.argv[2])
requested_items = result["Requested"]
requested = requested_items if isinstance(requested_items, dict) else requested_items[0]

if requested["Version"] != "v0.0.1":
    raise SystemExit(f"expected compatible version v0.0.1, got {requested['Version']}")
if result.get("ArchiveFile") != str(archive_path):
    raise SystemExit(f"expected ArchiveFile={archive_path}, got {result.get('ArchiveFile')}")
if not archive_path.is_file():
    raise SystemExit(f"missing archive: {archive_path}")
PY

tar -xzf "$archive_path" -C "$staging_dir"

test -f "$staging_dir/example.com/smoke/@v/list"
test -f "$staging_dir/example.com/smoke/@v/v0.0.1.info"
test -f "$staging_dir/example.com/smoke/@v/v0.0.1.mod"
test -f "$staging_dir/example.com/smoke/@v/v0.0.1.zip"
test ! -f "$staging_dir/example.com/smoke/@v/v0.0.2.info"

cat > "$tmp_dir/artifactory_server.py" <<'PY'
import http.server
import pathlib
import socketserver
import sys
import urllib.parse

upload_root = pathlib.Path(sys.argv[1])
port_file = pathlib.Path(sys.argv[2])
log_path = pathlib.Path(sys.argv[3])
upload_root.mkdir(parents=True, exist_ok=True)


def safe_relative_path(request_path):
    parsed = urllib.parse.urlparse(request_path)
    rel = urllib.parse.unquote(parsed.path.lstrip("/"))
    if ".." in pathlib.PurePosixPath(rel).parts:
        return None
    return rel


class Handler(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        if self.headers.get("Authorization") != "Bearer test-token":
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b"bad auth")
            return

        rel = safe_relative_path(self.path)
        if rel is None:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"bad path")
            return

        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        dest = upload_root / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(body)
        with log_path.open("a", encoding="utf-8") as log:
            log.write(rel + "\n")

        self.send_response(201)
        self.end_headers()
        self.wfile.write(b"created")

    def do_GET(self):
        rel = safe_relative_path(self.path)
        if rel is None:
            self.send_response(400)
            self.end_headers()
            return

        source = upload_root / rel
        if not source.is_file():
            self.send_response(404)
            self.end_headers()
            return

        self.send_response(200)
        self.send_header("Content-Length", str(source.stat().st_size))
        self.end_headers()
        with source.open("rb") as handle:
            self.wfile.write(handle.read())

    def log_message(self, fmt, *args):
        return


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


server = Server(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_address[1]), encoding="utf-8")
server.serve_forever()
PY

artifactory_port_file="$tmp_dir/artifactory.port"
artifactory_log="$tmp_dir/artifactory-upload.log"
python3 "$tmp_dir/artifactory_server.py" "$upload_root" "$artifactory_port_file" "$artifactory_log" \
  >"$tmp_dir/artifactory-server.out" 2>&1 &
artifactory_pid="$!"
for _ in {1..50}; do
  [[ -s "$artifactory_port_file" ]] && break
  sleep 0.1
done
[[ -s "$artifactory_port_file" ]] || {
  echo "Artifactory test server did not start" >&2
  exit 1
}
artifactory_port="$(cat "$artifactory_port_file")"

ARTIFACTORY_TOKEN=test-token "$uploader" \
  --source-dir "$staging_dir" \
  --artifactory-url "http://127.0.0.1:$artifactory_port/artifactory" \
  --repo go-local \
  --target-prefix mirrored >"$upload_result"

grep -q 'Summary: uploaded=4 skipped=0 failed=0 considered=4' "$upload_result" || {
  echo "unexpected upload summary" >&2
  cat "$upload_result" >&2
  exit 1
}

test -f "$upload_root/artifactory/go-local/mirrored/example.com/smoke/@v/list"
test -f "$upload_root/artifactory/go-local/mirrored/example.com/smoke/@v/v0.0.1.info"
test -f "$upload_root/artifactory/go-local/mirrored/example.com/smoke/@v/v0.0.1.mod"
test -f "$upload_root/artifactory/go-local/mirrored/example.com/smoke/@v/v0.0.1.zip"

goproxy_url="http://127.0.0.1:$artifactory_port/artifactory/go-local/mirrored"

(
  cd "$client_download_dir"
  GOPATH="$tmp_dir/gopath-download" \
  GOMODCACHE="$tmp_dir/gomodcache-download" \
  GOCACHE="$tmp_dir/gocache-download" \
  GOPROXY="$goproxy_url" \
  GOSUMDB=off \
  go mod init smoke-client >/dev/null

  GOPATH="$tmp_dir/gopath-download" \
  GOMODCACHE="$tmp_dir/gomodcache-download" \
  GOCACHE="$tmp_dir/gocache-download" \
  GOPROXY="$goproxy_url" \
  GOSUMDB=off \
  go mod download example.com/smoke@v0.0.1
)

(
  cd "$client_install_dir"
  GOBIN="$tmp_dir/bin" \
  GOPATH="$tmp_dir/gopath-install" \
  GOMODCACHE="$tmp_dir/gomodcache-install" \
  GOCACHE="$tmp_dir/gocache-install" \
  GOPROXY="$goproxy_url" \
  GOSUMDB=off \
  go install example.com/smoke/cmd/smoke-tool@v0.0.1
)

if [[ "$("$tmp_dir/bin/smoke-tool")" != "smoke-tool ok" ]]; then
  echo "go install smoke binary did not run correctly" >&2
  exit 1
fi

echo "Go proxy Artifactory end-to-end smoke test passed"
