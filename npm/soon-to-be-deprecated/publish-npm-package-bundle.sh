#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Publish an air-gapped npm package bundle to an Artifactory npm repository.

Usage:
  ./publish-npm-package-bundle.sh --registry-url URL [options]

Options:
  --bundle-dir DIR       Bundle directory. Defaults to this script's directory.
  --registry-url URL     Artifactory npm registry URL.
  --token TOKEN          Artifactory token. Defaults to ARTIFACTORY_TOKEN.
  --username USER        Artifactory username. Defaults to ARTIFACTORY_USERNAME.
  --password PASSWORD    Artifactory password/API key. Defaults to ARTIFACTORY_PASSWORD.
  --skip-existing        Treat already-published versions as success.
  --dry-run              Verify tarballs and print what would publish.
  --normalize-library-package
                         Rewrite tarball package.json before upload. Default.
  --no-normalize-library-package
                         Publish original tarballs without metadata rewrites.
  --strip-peer-dependencies
                         Remove peerDependencies while normalizing.
  --strip-optional-dependencies
                         Remove optionalDependencies while normalizing.
  -h, --help             Show this help.

Examples:
  ARTIFACTORY_TOKEN=... \
    ./publish-npm-package-bundle.sh \
      --registry-url https://art.example.com/artifactory/api/npm/npm-local/ \
      --skip-existing

  ./publish-npm-package-bundle.sh \
    --registry-url https://art.example.com/artifactory/api/npm/npm-local/ \
    --username "$ARTIFACTORY_USERNAME" \
    --password "$ARTIFACTORY_PASSWORD"
USAGE
}

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

is_true() {
  case "${1:-}" in
    true|TRUE|1|yes|YES|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR"
REGISTRY_URL=""
TOKEN="${ARTIFACTORY_TOKEN:-}"
USERNAME="${ARTIFACTORY_USERNAME:-}"
PASSWORD="${ARTIFACTORY_PASSWORD:-}"
SKIP_EXISTING=false
DRY_RUN=false
NORMALIZE_LIBRARY_PACKAGE="${NORMALIZE_LIBRARY_PACKAGE:-true}"
STRIP_PEER_DEPENDENCIES="${STRIP_PEER_DEPENDENCIES:-false}"
STRIP_OPTIONAL_DEPENDENCIES="${STRIP_OPTIONAL_DEPENDENCIES:-false}"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --bundle-dir)
      BUNDLE_DIR="$2"
      shift 2
      ;;
    --registry-url)
      REGISTRY_URL="$2"
      shift 2
      ;;
    --token)
      TOKEN="$2"
      shift 2
      ;;
    --username)
      USERNAME="$2"
      shift 2
      ;;
    --password)
      PASSWORD="$2"
      shift 2
      ;;
    --skip-existing)
      SKIP_EXISTING=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --normalize-library-package)
      NORMALIZE_LIBRARY_PACKAGE=true
      shift
      ;;
    --no-normalize-library-package)
      NORMALIZE_LIBRARY_PACKAGE=false
      shift
      ;;
    --strip-peer-dependencies)
      STRIP_PEER_DEPENDENCIES=true
      shift
      ;;
    --strip-optional-dependencies)
      STRIP_OPTIONAL_DEPENDENCIES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$REGISTRY_URL" ]] || fail "--registry-url is required"
[[ -d "$BUNDLE_DIR" ]] || fail "Bundle directory not found: $BUNDLE_DIR"
[[ -f "$BUNDLE_DIR/packages.json" ]] || fail "Bundle manifest not found: $BUNDLE_DIR/packages.json"

if is_true "$NORMALIZE_LIBRARY_PACKAGE"; then
  NORMALIZE_LIBRARY_PACKAGE=true
else
  NORMALIZE_LIBRARY_PACKAGE=false
fi
if is_true "$STRIP_PEER_DEPENDENCIES"; then
  STRIP_PEER_DEPENDENCIES=true
else
  STRIP_PEER_DEPENDENCIES=false
fi
if is_true "$STRIP_OPTIONAL_DEPENDENCIES"; then
  STRIP_OPTIONAL_DEPENDENCIES=true
else
  STRIP_OPTIONAL_DEPENDENCIES=false
fi

need_command jq
need_command sha1sum

if [[ -z "$TOKEN" && ( -z "$USERNAME" || -z "$PASSWORD" ) ]]; then
  fail "Set --token, or set --username and --password."
fi

UPLOAD_SCRIPT="${BUNDLE_DIR}/upload-npm-tarballs-to-artifactory.sh"
if [[ ! -x "$UPLOAD_SCRIPT" ]]; then
  UPLOAD_SCRIPT="${SCRIPT_DIR}/upload-npm-tarballs-to-artifactory.sh"
fi
[[ -x "$UPLOAD_SCRIPT" ]] || fail "Upload script not found. Keep upload-npm-tarballs-to-artifactory.sh beside this script or in the bundle directory."

UPLOAD_MANIFEST="$BUNDLE_DIR/artifactory-upload-manifest.tsv"
UPLOAD_WORK_DIR="$BUNDLE_DIR/artifactory-upload-work"
RESULTS_JSON="$BUNDLE_DIR/publish-results.json"
SUMMARY_JSON="$BUNDLE_DIR/publish-summary.json"
: >"$UPLOAD_MANIFEST"

total=0

while IFS=$'\t' read -r package_name package_version package_ref tarball_rel expected_sha1; do
  [[ -n "$package_name" ]] || continue
  total=$((total + 1))

  tarball="$BUNDLE_DIR/$tarball_rel"
  [[ -f "$tarball" ]] || fail "Missing tarball for $package_ref: $tarball"

  actual_sha1="$(sha1sum "$tarball" | awk '{print tolower($1)}')"
  expected_sha1="$(printf '%s' "$expected_sha1" | tr '[:upper:]' '[:lower:]')"
  if [[ "$actual_sha1" != "$expected_sha1" ]]; then
    fail "SHA1 mismatch for $package_ref. Expected $expected_sha1 but found $actual_sha1."
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY_RUN verified $package_ref from $tarball_rel"
  fi

  printf '%s\t%s\t%s\n' "$package_name" "$package_version" "$tarball" >>"$UPLOAD_MANIFEST"
done < <(jq -r '.[] | [.Name, .Version, .Package, .Tarball, .Sha1] | @tsv' "$BUNDLE_DIR/packages.json")

upload_args=(
  "$UPLOAD_SCRIPT"
  --manifest "$UPLOAD_MANIFEST"
  --registry-url "$REGISTRY_URL"
  --work-dir "$UPLOAD_WORK_DIR"
)
if [[ -n "$TOKEN" ]]; then
  upload_args+=(--token "$TOKEN")
else
  upload_args+=(--username "$USERNAME" --password "$PASSWORD")
fi
if [[ "$SKIP_EXISTING" == "true" ]]; then
  upload_args+=(--skip-existing)
fi
if [[ "$DRY_RUN" == "true" ]]; then
  upload_args+=(--dry-run)
fi
if [[ "$NORMALIZE_LIBRARY_PACKAGE" == "true" ]]; then
  upload_args+=(--normalize-library-package)
else
  upload_args+=(--no-normalize-library-package)
fi
if [[ "$STRIP_PEER_DEPENDENCIES" == "true" ]]; then
  upload_args+=(--strip-peer-dependencies)
fi
if [[ "$STRIP_OPTIONAL_DEPENDENCIES" == "true" ]]; then
  upload_args+=(--strip-optional-dependencies)
fi

"${upload_args[@]}" >"$SUMMARY_JSON"
if [[ -f "${UPLOAD_WORK_DIR}/upload-results.json" ]]; then
  cp "${UPLOAD_WORK_DIR}/upload-results.json" "$RESULTS_JSON"
fi
cat "$SUMMARY_JSON"
