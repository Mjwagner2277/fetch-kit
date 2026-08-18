#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install-static-goproxy-cache.sh [--no-sudo] SOURCE_DIR [DEST_DIR]

Copies a static Go proxy cache exported by Get-GoLibrary.ps1 -GoProxyDirectory
into an existing static Go proxy root and validates the Go proxy protocol files.
Files are merged additively; existing modules are not deleted.

Arguments:
  SOURCE_DIR  Transferred directory containing escaped-module/@v files.
  DEST_DIR    Destination served by your internal HTTP server.
              Defaults to /srv/goproxy.

Example:
  sudo ./scripts/install-static-goproxy-cache.sh ./go-proxy-cache /srv/goproxy
  ./scripts/install-static-goproxy-cache.sh --no-sudo ./go-proxy-cache ./local-goproxy

Then serve DEST_DIR as static files and point clients at it:
  go env -w GOPROXY=https://goproxy.internal.example.com,direct
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

use_sudo=1
if [[ "${1:-}" == "--no-sudo" ]]; then
  use_sudo=0
  shift
fi

source_dir="${1:-}"
dest_dir="${2:-/srv/goproxy}"

if [[ -z "$source_dir" ]]; then
  usage >&2
  exit 2
fi

if [[ ! -d "$source_dir" ]]; then
  echo "source directory does not exist: $source_dir" >&2
  exit 1
fi

run_as_root() {
  if [[ "$use_sudo" -eq 1 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

run_as_root mkdir -p "$dest_dir"

if command -v rsync >/dev/null 2>&1; then
  if [[ "$use_sudo" -eq 1 ]]; then
    sudo rsync -a "$source_dir"/ "$dest_dir"/
  else
    rsync -a "$source_dir"/ "$dest_dir"/
  fi
else
  tmp_dir="$(mktemp -d)"
  cp -a "$source_dir"/. "$tmp_dir"/
  run_as_root mkdir -p "$dest_dir"
  run_as_root cp -a "$tmp_dir"/. "$dest_dir"/
  rm -rf "$tmp_dir"
fi

missing=0
while IFS= read -r -d '' info_file; do
  version_file_name="$(basename "$info_file")"
  version="${version_file_name%.info}"
  version_dir="$(dirname "$info_file")"

  for suffix in mod zip; do
    if [[ ! -f "$version_dir/$version.$suffix" ]]; then
      echo "missing $version.$suffix next to $info_file" >&2
      missing=1
    fi
  done

  if [[ ! -f "$version_dir/list" ]]; then
    echo "missing list next to $info_file" >&2
    missing=1
  elif ! grep -Fxq "$version" "$version_dir/list"; then
    echo "list does not contain $version next to $info_file" >&2
    missing=1
  fi
done < <(find "$dest_dir" -path '*/@v/*.info' -type f -print0)

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

run_as_root find "$dest_dir" -type d -exec chmod 0755 {} +
run_as_root find "$dest_dir" -type f -exec chmod 0644 {} +

cat <<EOF
Installed static Go proxy cache at:
  $dest_dir

Client setting:
  go env -w GOPROXY=https://goproxy.internal.example.com
EOF
