#!/usr/bin/env bash
#
# Smoke-test upload-go-proxy-to-artifactory.sh without requiring Docker,
# Artifactory, or network access.
#
# The test starts a tiny local HTTP server that implements the subset of
# Artifactory's artifact deployment API needed by the uploader:
#
#   PUT /artifactory/<repo>/<path>
#
# It verifies that authentication is sent, expected files are written, .ziphash
# is skipped by default, file contents are preserved, and @v/list files are
# uploaded after version artifacts.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
script="${script_dir}/upload-go-proxy-to-artifactory.sh"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/go-proxy-artifactory-smoke.XXXXXX")"
server_log="${tmpdir}/server.log"
server_ready="${tmpdir}/ready"
port_file="${tmpdir}/port"
upload_root="${tmpdir}/uploads"
source_root="${tmpdir}/source"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" >/dev/null 2>&1; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

for required_cmd in bash curl python3 mktemp tail grep cmp; do
  command -v "$required_cmd" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$required_cmd" >&2
    exit 1
  }
done

[[ -x "$script" ]] || {
  printf 'uploader is not executable: %s\n' "$script" >&2
  exit 1
}

mkdir -p \
  "${source_root}/example.com/mod/@v" \
  "${source_root}/example.com/other/@v"

printf '{"Version":"v1.0.0","Time":"2026-08-20T00:00:00Z"}\n' > "${source_root}/example.com/mod/@v/v1.0.0.info"
printf 'module example.com/mod\n' > "${source_root}/example.com/mod/@v/v1.0.0.mod"
printf 'zip-content\n' > "${source_root}/example.com/mod/@v/v1.0.0.zip"
printf 'v1.0.0\n' > "${source_root}/example.com/mod/@v/list"
printf 'hash-that-should-not-upload\n' > "${source_root}/example.com/mod/@v/v1.0.0.ziphash"

printf '{"Version":"v2.0.0","Time":"2026-08-20T00:00:00Z"}\n' > "${source_root}/example.com/other/@v/v2.0.0.info"
printf 'v2.0.0\n' > "${source_root}/example.com/other/@v/list"

python3 - "${upload_root}" "${server_ready}" "${port_file}" "${server_log}" <<'PY' &
import http.server
import pathlib
import socketserver
import sys
import urllib.parse

upload_root = pathlib.Path(sys.argv[1])
ready_path = pathlib.Path(sys.argv[2])
port_path = pathlib.Path(sys.argv[3])
log_path = pathlib.Path(sys.argv[4])
upload_root.mkdir(parents=True, exist_ok=True)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        if self.headers.get("Authorization") != "Bearer test-token":
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b"bad auth")
            return

        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        rel = urllib.parse.unquote(self.path.lstrip("/"))
        if ".." in pathlib.PurePosixPath(rel).parts:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"bad path")
            return

        dest = upload_root / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(body)
        with log_path.open("a", encoding="utf-8") as log:
            log.write(rel + "\n")

        self.send_response(201)
        self.end_headers()
        self.wfile.write(b"created")

    def log_message(self, fmt, *args):
        return


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


server = Server(("127.0.0.1", 0), Handler)
port_path.write_text(str(server.server_address[1]), encoding="utf-8")
ready_path.write_text("ready\n", encoding="utf-8")
server.serve_forever()
PY
server_pid=$!

for _ in {1..50}; do
  [[ -f "$server_ready" ]] && break
  sleep 0.1
done
[[ -f "$server_ready" ]] || {
  printf 'server did not become ready\n' >&2
  exit 1
}

port="$(cat "$port_file")"

ARTIFACTORY_TOKEN=test-token "${script}" \
  --source-dir "$source_root" \
  --artifactory-url "http://127.0.0.1:${port}/artifactory" \
  --repo go-local \
  --target-prefix mirrored \
  > "${tmpdir}/upload.out"

expected_files=(
  "artifactory/go-local/mirrored/example.com/mod/@v/v1.0.0.info"
  "artifactory/go-local/mirrored/example.com/mod/@v/v1.0.0.mod"
  "artifactory/go-local/mirrored/example.com/mod/@v/v1.0.0.zip"
  "artifactory/go-local/mirrored/example.com/mod/@v/list"
  "artifactory/go-local/mirrored/example.com/other/@v/v2.0.0.info"
  "artifactory/go-local/mirrored/example.com/other/@v/list"
)

for rel in "${expected_files[@]}"; do
  [[ -f "${upload_root}/${rel}" ]] || {
    printf 'missing uploaded file: %s\n' "$rel" >&2
    exit 1
  }
done

[[ ! -e "${upload_root}/artifactory/go-local/mirrored/example.com/mod/@v/v1.0.0.ziphash" ]] || {
  printf 'ziphash file should not have uploaded\n' >&2
  exit 1
}

cmp "${source_root}/example.com/mod/@v/v1.0.0.mod" \
  "${upload_root}/artifactory/go-local/mirrored/example.com/mod/@v/v1.0.0.mod"

last_two="$(tail -n 2 "$server_log")"
expected_last_two=$'artifactory/go-local/mirrored/example.com/mod/@v/list\nartifactory/go-local/mirrored/example.com/other/@v/list'
[[ "$last_two" == "$expected_last_two" ]] || {
  printf 'list files were not uploaded last\n' >&2
  printf 'last uploads:\n%s\n' "$last_two" >&2
  exit 1
}

grep -q 'Summary: uploaded=6 skipped=1 failed=0 considered=6' "${tmpdir}/upload.out" || {
  printf 'unexpected upload summary\n' >&2
  cat "${tmpdir}/upload.out" >&2
  exit 1
}

printf 'Artifactory Go proxy upload smoke test passed\n'
