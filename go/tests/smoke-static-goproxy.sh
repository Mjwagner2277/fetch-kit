#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for command_name in go python3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "missing required command: $command_name" >&2
    exit 1
  fi
done

tmp_dir="$(mktemp -d)"
cleanup() {
  if [[ -n "${upstream_pid:-}" ]]; then
    kill "$upstream_pid" >/dev/null 2>&1 || true
    wait "$upstream_pid" 2>/dev/null || true
  fi
  if [[ -n "${export_pid:-}" ]]; then
    kill "$export_pid" >/dev/null 2>&1 || true
    wait "$export_pid" 2>/dev/null || true
  fi
  chmod -R u+w "$tmp_dir" >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

upstream_dir="$tmp_dir/upstream"
export_dir="$tmp_dir/export"
client_dir="$tmp_dir/client"
mkdir -p "$upstream_dir/example.com/smoke/@v" "$export_dir" "$client_dir"

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

cat > "$tmp_dir/serve.py" <<'PY'
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

start_server() {
  local directory="$1"
  local port_file="$2"
  python3 "$tmp_dir/serve.py" "$directory" "$port_file" >"$port_file.log" 2>&1 &
  started_server_pid="$!"
  for _ in $(seq 1 50); do
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
start_server "$upstream_dir" "$upstream_port_file"
upstream_port="$started_server_port"
upstream_pid="$started_server_pid"

retrieval_result="$tmp_dir/retrieval-result.json"
package_list="$tmp_dir/package-list.txt"
printf 'example.com/smoke\n' > "$package_list"
python3 "$repo_root/Get-GoLibrary.py" \
  --package-list-path "$package_list" \
  --go-version 1.26.5-1 \
  --proxy "http://127.0.0.1:$upstream_port" \
  --go-proxy-directory "$export_dir" >"$retrieval_result"

python3 - "$retrieval_result" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
working_dir = pathlib.Path(result["WorkingOutputDirectory"])
requested_items = result["Requested"]
if isinstance(requested_items, dict):
    requested = requested_items
else:
    requested = requested_items[0]

if not result["TemporaryOutputDirectory"]:
    raise SystemExit("expected TemporaryOutputDirectory=true")

if working_dir.exists():
    raise SystemExit(f"temporary output directory was not removed: {working_dir}")

if requested["Version"] != "v0.0.1":
    raise SystemExit(f"expected v0.0.1 compatible resolution, got {requested['Version']}")

if requested["CompatibleGoDirective"] != "1.26":
    raise SystemExit(f"expected go directive 1.26, got {requested['CompatibleGoDirective']}")
PY

cached_result="$tmp_dir/cached-result.json"
python3 "$repo_root/Get-GoLibrary.py" \
  --package-list-path "$package_list" \
  --go-version 1.26.5-1 \
  --proxy off \
  --go-proxy-directory "$export_dir" >"$cached_result"

python3 - "$cached_result" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
requested_items = result["Requested"]
requested = requested_items if isinstance(requested_items, dict) else requested_items[0]
results_items = result["Results"]
entry_result = results_items if isinstance(results_items, dict) else results_items[0]

if requested["Version"] != "v0.0.1":
    raise SystemExit(f"expected cached compatible version v0.0.1, got {requested['Version']}")

if entry_result["Result"]["Proxy"] != "GoProxyDirectory":
    raise SystemExit(f"expected retrieval from GoProxyDirectory, got {entry_result['Result']['Proxy']}")

if not entry_result["Result"]["UsedProxyCache"]:
    raise SystemExit("expected UsedProxyCache=true")
PY

"$repo_root/scripts/install-static-goproxy-cache.sh" --no-sudo "$export_dir" "$tmp_dir/static-goproxy" >/dev/null

export_port_file="$tmp_dir/export.port"
start_server "$tmp_dir/static-goproxy" "$export_port_file"
export_port="$started_server_port"
export_pid="$started_server_pid"

(
  cd "$client_dir"
  GOPATH="$tmp_dir/gopath" \
  GOMODCACHE="$tmp_dir/gomodcache" \
  GOCACHE="$tmp_dir/gocache" \
  GOPROXY="http://127.0.0.1:$export_port" \
  GOSUMDB=off \
  go mod init smoke-client >/dev/null

  GOPATH="$tmp_dir/gopath" \
  GOMODCACHE="$tmp_dir/gomodcache" \
  GOCACHE="$tmp_dir/gocache" \
  GOPROXY="http://127.0.0.1:$export_port" \
  GOSUMDB=off \
  go mod download example.com/smoke@v0.0.1

  GOBIN="$tmp_dir/bin" \
  GOPATH="$tmp_dir/gopath" \
  GOMODCACHE="$tmp_dir/gomodcache" \
  GOCACHE="$tmp_dir/gocache" \
  GOPROXY="http://127.0.0.1:$export_port" \
  GOSUMDB=off \
  go install example.com/smoke/cmd/smoke-tool@v0.0.1
)

if [[ "$("$tmp_dir/bin/smoke-tool")" != "smoke-tool ok" ]]; then
  echo "go install smoke binary did not run correctly" >&2
  exit 1
fi

test -f "$tmp_dir/static-goproxy/example.com/smoke/@v/list"
test -f "$tmp_dir/static-goproxy/example.com/smoke/@v/v0.0.1.info"
test -f "$tmp_dir/static-goproxy/example.com/smoke/@v/v0.0.1.mod"
test -f "$tmp_dir/static-goproxy/example.com/smoke/@v/v0.0.1.zip"
test ! -f "$tmp_dir/static-goproxy/example.com/smoke/@v/v0.0.2.info"

echo "static Go proxy smoke test passed"
