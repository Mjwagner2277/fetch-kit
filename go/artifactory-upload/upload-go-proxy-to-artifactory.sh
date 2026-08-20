#!/usr/bin/env bash
#
# Upload a static Go module proxy tree to an Artifactory repository.
#
# The source directory is expected to be the document root for a static Go proxy,
# for example a directory served by nginx or exported by fetch-kit's
# Get-GoLibrary.ps1 -GoProxyDirectory option:
#
#   example.com/module/@v/list
#   example.com/module/@v/v1.2.3.info
#   example.com/module/@v/v1.2.3.mod
#   example.com/module/@v/v1.2.3.zip
#
# The script preserves those relative paths and uploads each file with
# Artifactory's artifact deployment REST API:
#
#   PUT <artifactory-url>/<repo>/<optional-prefix>/<relative-go-proxy-path>
#
# By default only standard Go proxy artifacts are uploaded. Cache helper files
# such as .ziphash are intentionally skipped unless --all-files is provided.
# Version list files are uploaded after version artifacts so proxy clients do
# not discover a listed version before its .info, .mod, and .zip files exist.
set -Eeuo pipefail

prog="${0##*/}"

source_dir=""
artifactory_url=""
repo=""
target_prefix=""
token="${ARTIFACTORY_TOKEN:-${JFROG_ACCESS_TOKEN:-}}"
api_key="${ARTIFACTORY_API_KEY:-}"
username="${ARTIFACTORY_USER:-}"
password="${ARTIFACTORY_PASSWORD:-}"
dry_run=0
all_files=0
insecure=0
retries=3
retry_delay=2

usage() {
  cat <<USAGE
Usage:
  $prog --source-dir DIR --artifactory-url URL --repo REPO [options]

Uploads a static Go module proxy directory, such as an nginx document root
containing paths like:

  github.com/example/project/@v/list
  github.com/example/project/@v/v1.2.3.info
  github.com/example/project/@v/v1.2.3.mod
  github.com/example/project/@v/v1.2.3.zip

The upload endpoint is Artifactory's artifact REST API:

  PUT <artifactory-url>/<repo>/<relative-go-proxy-path>

Required:
  --source-dir DIR        Local Go proxy root served by nginx.
  --artifactory-url URL   Artifactory base URL, usually https://host/artifactory.
  --repo REPO             Target Artifactory repository key, for example go-local.

Authentication, choose one:
  --token TOKEN           Bearer token. Can also use ARTIFACTORY_TOKEN or JFROG_ACCESS_TOKEN.
  --api-key KEY           Legacy X-JFrog-Art-Api key. Can also use ARTIFACTORY_API_KEY.
  --user USER             Username. Can also use ARTIFACTORY_USER.
  --password PASSWORD     Password or token for --user. Can also use ARTIFACTORY_PASSWORD.

Options:
  --target-prefix PATH    Optional prefix inside the Artifactory repository.
  --all-files             Upload every file. By default only Go proxy files are uploaded.
  --dry-run               Print uploads without calling Artifactory.
  --insecure              Pass --insecure to curl.
  --retries N             curl retry count. Default: $retries.
  --retry-delay N         Seconds between retries. Default: $retry_delay.
  -h, --help              Show this help.

Examples:
  ARTIFACTORY_TOKEN=... \\
    ./$prog \\
      --source-dir /var/www/go-proxy \\
      --artifactory-url https://example.jfrog.io/artifactory \\
      --repo go-local \\
      --dry-run

  ./$prog \\
    --source-dir "\$GOMODCACHE/cache/download" \\
    --artifactory-url https://artifactory.example.com/artifactory \\
    --repo go-local \\
    --user deployer \\
    --password "\$ARTIFACTORY_PASSWORD"
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

strip_leading_slashes() {
  local value="$1"
  while [[ "$value" == /* ]]; do
    value="${value#/}"
  done
  printf '%s' "$value"
}

strip_trailing_slashes() {
  local value="$1"
  while [[ "$value" == */ && "$value" != "/" ]]; do
    value="${value%/}"
  done
  printf '%s' "$value"
}

join_path() {
  local left="$1"
  local right="$2"

  left="$(strip_leading_slashes "$left")"
  left="$(strip_trailing_slashes "$left")"
  right="$(strip_leading_slashes "$right")"

  if [[ -z "$left" ]]; then
    printf '%s' "$right"
  else
    printf '%s/%s' "$left" "$right"
  fi
}

is_go_proxy_artifact() {
  local rel="$1"

  # The Go proxy protocol stores version metadata under a module's @v
  # directory. Matching only these files keeps build-cache side files, logs, and
  # accidental local files out of Artifactory by default.
  case "$rel" in
    @v/list|@v/*.info|@v/*.mod|@v/*.zip|*/@v/list|*/@v/*.info|*/@v/*.mod|*/@v/*.zip)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_version_list() {
  local rel="$1"

  # Upload @v/list last. Go clients consult this file to discover versions, so
  # publishing it after version files avoids a transient incomplete repository.
  case "$rel" in
    @v/list|*/@v/list)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

parse_positive_int() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be a non-negative integer"
  printf '%s' "$value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dir)
      [[ $# -ge 2 ]] || die "--source-dir requires a value"
      source_dir="$2"
      shift 2
      ;;
    --artifactory-url)
      [[ $# -ge 2 ]] || die "--artifactory-url requires a value"
      artifactory_url="$2"
      shift 2
      ;;
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a value"
      repo="$2"
      shift 2
      ;;
    --target-prefix)
      [[ $# -ge 2 ]] || die "--target-prefix requires a value"
      target_prefix="$2"
      shift 2
      ;;
    --token)
      [[ $# -ge 2 ]] || die "--token requires a value"
      token="$2"
      shift 2
      ;;
    --api-key)
      [[ $# -ge 2 ]] || die "--api-key requires a value"
      api_key="$2"
      shift 2
      ;;
    --user)
      [[ $# -ge 2 ]] || die "--user requires a value"
      username="$2"
      shift 2
      ;;
    --password)
      [[ $# -ge 2 ]] || die "--password requires a value"
      password="$2"
      shift 2
      ;;
    --all-files)
      all_files=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --insecure)
      insecure=1
      shift
      ;;
    --retries)
      [[ $# -ge 2 ]] || die "--retries requires a value"
      retries="$(parse_positive_int "--retries" "$2")"
      shift 2
      ;;
    --retry-delay)
      [[ $# -ge 2 ]] || die "--retry-delay requires a value"
      retry_delay="$(parse_positive_int "--retry-delay" "$2")"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$source_dir" ]] || die "--source-dir is required"
[[ -d "$source_dir" ]] || die "--source-dir is not a directory: $source_dir"
[[ -n "$artifactory_url" ]] || die "--artifactory-url is required"
[[ -n "$repo" ]] || die "--repo is required"

source_dir="$(cd "$source_dir" && pwd -P)"
artifactory_url="$(strip_trailing_slashes "$artifactory_url")"
repo="$(strip_leading_slashes "$repo")"
repo="$(strip_trailing_slashes "$repo")"
target_prefix="$(strip_leading_slashes "$target_prefix")"
target_prefix="$(strip_trailing_slashes "$target_prefix")"

[[ "$repo" != */* ]] || die "--repo must be only the repository key, not a path: $repo"

for required_cmd in curl find sort mktemp sed; do
  command -v "$required_cmd" >/dev/null 2>&1 || die "$required_cmd is required"
done

auth_args=()
if [[ -n "$token" ]]; then
  # Preferred for modern JFrog access tokens.
  auth_args=(-H "Authorization: Bearer ${token}")
elif [[ -n "$api_key" ]]; then
  # Supported for older Artifactory deployments where API keys are still used.
  auth_args=(-H "X-JFrog-Art-Api: ${api_key}")
elif [[ -n "$username" || -n "$password" ]]; then
  [[ -n "$username" ]] || die "--user or ARTIFACTORY_USER is required when using password auth"
  [[ -n "$password" ]] || die "--password or ARTIFACTORY_PASSWORD is required when using user auth"
  auth_args=(-u "${username}:${password}")
elif [[ "$dry_run" -eq 0 ]]; then
  die "no credentials provided; set ARTIFACTORY_TOKEN, JFROG_ACCESS_TOKEN, ARTIFACTORY_API_KEY, or ARTIFACTORY_USER/ARTIFACTORY_PASSWORD"
fi

curl_fail_arg="--fail"
if curl --help all 2>/dev/null | grep -q -- '--fail-with-body'; then
  # Keep useful Artifactory error responses visible on newer curl versions.
  curl_fail_arg="--fail-with-body"
fi

# --path-as-is keeps Go module escape sequences and @v path components exactly
# as they appear in the local proxy tree.
curl_common=(-sS "$curl_fail_arg" --retry "$retries" --retry-delay "$retry_delay" --path-as-is)
if [[ "$insecure" -eq 1 ]]; then
  curl_common+=(--insecure)
fi

tmp_files="$(mktemp "${TMPDIR:-/tmp}/go-proxy-files.XXXXXX")"
tmp_response="$(mktemp "${TMPDIR:-/tmp}/go-proxy-upload-response.XXXXXX")"
cleanup() {
  rm -f "$tmp_files" "$tmp_response"
}
trap cleanup EXIT

find "$source_dir" -type f -print | LC_ALL=C sort > "$tmp_files"

total=0
uploaded=0
skipped=0
failed=0

upload_one() {
  local file="$1"
  local rel="$2"
  local target_path target_url http_code curl_exit

  target_path="$(join_path "$target_prefix" "$rel")"
  target_url="${artifactory_url}/${repo}/${target_path}"

  if [[ "$dry_run" -eq 1 ]]; then
    printf 'DRY-RUN: %s -> %s\n' "$file" "$target_url"
    uploaded=$((uploaded + 1))
    return 0
  fi

  : > "$tmp_response"
  set +e
  http_code="$(
    curl "${curl_common[@]}" "${auth_args[@]}" \
      -X PUT \
      -T "$file" \
      -o "$tmp_response" \
      -w '%{http_code}' \
      "$target_url"
  )"
  curl_exit=$?
  set -e

  if [[ "$curl_exit" -eq 0 ]]; then
    printf 'uploaded: %s (%s)\n' "$target_path" "$http_code"
    uploaded=$((uploaded + 1))
    return 0
  fi

  printf 'ERROR: upload failed: %s -> %s\n' "$file" "$target_url" >&2
  if [[ -n "$http_code" ]]; then
    printf 'ERROR: HTTP status: %s\n' "$http_code" >&2
  fi
  if [[ -s "$tmp_response" ]]; then
    sed 's/^/ERROR: response: /' "$tmp_response" >&2
  fi
  failed=$((failed + 1))
  return 0
}

process_files() {
  local list_mode="$1"
  local file rel

  # The file list is processed twice: first all version artifacts, then @v/list
  # files. This is deliberate publish ordering, not parallel upload.
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    rel="${file#"$source_dir"/}"

    if [[ "$all_files" -eq 0 ]] && ! is_go_proxy_artifact "$rel"; then
      if [[ "$list_mode" == "artifacts" ]]; then
        skipped=$((skipped + 1))
      fi
      continue
    fi

    if [[ "$list_mode" == "lists" ]]; then
      is_version_list "$rel" || continue
    else
      ! is_version_list "$rel" || continue
    fi

    total=$((total + 1))
    upload_one "$file" "$rel"
  done < "$tmp_files"
}

printf 'Source: %s\n' "$source_dir"
printf 'Target: %s/%s\n' "$artifactory_url" "$repo"
if [[ -n "$target_prefix" ]]; then
  printf 'Target prefix: %s\n' "$target_prefix"
fi
if [[ "$all_files" -eq 0 ]]; then
  printf 'Filter: Go proxy artifacts only\n'
else
  printf 'Filter: all files\n'
fi
if [[ "$dry_run" -eq 1 ]]; then
  printf 'Mode: dry run\n'
fi

process_files "artifacts"
process_files "lists"

printf '\nSummary: uploaded=%d skipped=%d failed=%d considered=%d\n' "$uploaded" "$skipped" "$failed" "$total"

if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
