#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

for command_name in python3 tar mktemp; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "missing required command: $command_name" >&2
    exit 1
  fi
done

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/go-vuln-workflow.XXXXXX")"
cleanup() {
  if [[ -n "${upstream_pid:-}" ]]; then
    kill "$upstream_pid" >/dev/null 2>&1 || true
    wait "$upstream_pid" 2>/dev/null || true
  fi
  chmod -R u+w "$tmp_dir" >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

upstream_dir="$tmp_dir/upstream"
vuln_db_dir="$tmp_dir/vulndb"
package_list="$tmp_dir/package-list.txt"
output_dir="$tmp_dir/output"
source_vuln_db_zip="$upstream_dir/vulndb.zip"
downloaded_vuln_db_zip="$output_dir/go-vulndb/vulndb.zip"
mkdir -p "$upstream_dir/example.com/vulnerable/@v" "$vuln_db_dir/ID" "$vuln_db_dir/index"

python3 - "$upstream_dir" "$vuln_db_dir" "$source_vuln_db_zip" <<'PY'
import json
import pathlib
import sys
import zipfile

upstream = pathlib.Path(sys.argv[1])
vulndb = pathlib.Path(sys.argv[2])
vulndb_zip = pathlib.Path(sys.argv[3])
version_dir = upstream / "example.com" / "vulnerable" / "@v"

(version_dir / "list").write_text("v1.0.0\nv1.0.1\n", encoding="utf-8")
for version, go_version in (("v1.0.0", "1.26"), ("v1.0.1", "1.27")):
    (version_dir / f"{version}.info").write_text(
        json.dumps({"Version": version, "Time": "2026-01-01T00:00:00Z"}) + "\n",
        encoding="utf-8",
    )
    (version_dir / f"{version}.mod").write_text(f"module example.com/vulnerable\n\ngo {go_version}\n", encoding="utf-8")
    with zipfile.ZipFile(version_dir / f"{version}.zip", "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(f"example.com/vulnerable@{version}/go.mod", f"module example.com/vulnerable\n\ngo {go_version}\n")
        archive.writestr(f"example.com/vulnerable@{version}/vulnerable.go", "package vulnerable\n")

record = {
    "id": "GO-2026-0001",
    "summary": "Synthetic vulnerability",
    "aliases": ["CVE-2026-9999", "GHSA-test"],
    "affected": [
        {
            "package": {"ecosystem": "Go", "name": "example.com/vulnerable"},
            "ranges": [
                {
                    "type": "SEMVER",
                    "events": [
                        {"introduced": "0"},
                        {"fixed": "v1.0.1"},
                    ],
                }
            ],
        }
    ],
    "database_specific": {"url": "https://pkg.go.dev/vuln/GO-2026-0001"},
}
(vulndb / "ID" / "GO-2026-0001.json").write_text(json.dumps(record), encoding="utf-8")
(vulndb / "index" / "db.json").write_text(json.dumps({"modified": "2026-01-01T00:00:00Z"}), encoding="utf-8")

with zipfile.ZipFile(vulndb_zip, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(vulndb.rglob("*")):
        if path.is_file():
            archive.write(path, path.relative_to(vulndb).as_posix())
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

python3 "$tmp_dir/static_server.py" "$upstream_dir" "$tmp_dir/upstream.port" >"$tmp_dir/upstream.log" 2>&1 &
upstream_pid="$!"
for _ in {1..50}; do
  [[ -s "$tmp_dir/upstream.port" ]] && break
  sleep 0.1
done
[[ -s "$tmp_dir/upstream.port" ]] || {
  echo "upstream test server did not start" >&2
  exit 1
}
upstream_port="$(cat "$tmp_dir/upstream.port")"

printf 'example.com/vulnerable\n' > "$package_list"
python3 "$repo_root/Run-GoAirgapWorkflow.py" \
  --package-list-path "$package_list" \
  --go-version 1.26.5-1 \
  --proxy "http://127.0.0.1:$upstream_port" \
  --output-directory "$output_dir" \
  --vuln-db-url "http://127.0.0.1:$upstream_port/vulndb.zip" \
  --vuln-db-zip "$downloaded_vuln_db_zip" > "$tmp_dir/workflow-result.json"

test -f "$output_dir/go-proxy-cache.tar.gz"
test -f "$downloaded_vuln_db_zip"
test -f "$output_dir/go-vuln-report.csv"
tar -tzf "$output_dir/go-proxy-cache.tar.gz" | grep -q '^example.com/vulnerable/@v/v1.0.0.mod$'

python3 - "$output_dir/go-vuln-report.csv" <<'PY'
import csv
import pathlib
import sys

rows = list(csv.DictReader(pathlib.Path(sys.argv[1]).open(encoding="utf-8", newline="")))
if len(rows) != 1:
    raise SystemExit(f"expected one report row, got {len(rows)}")
row = rows[0]
checks = {
    "Package": "example.com/vulnerable",
    "Module": "example.com/vulnerable",
    "Version": "v1.0.0",
    "GoVersion": "1.26",
    "VulnerabilityCount": "1",
    "HighestCVE": "CVE-2026-9999",
    "HighestVulnerabilityID": "GO-2026-0001",
    "FixedVersion": "v1.0.1",
    "FixedGoVersion": "1.27",
}
for key, expected in checks.items():
    actual = row[key]
    if actual != expected:
        raise SystemExit(f"expected {key}={expected!r}, got {actual!r}")
PY

echo "Go vulnerability workflow smoke test passed"
