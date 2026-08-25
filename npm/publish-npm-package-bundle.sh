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

base64_one_line() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

registry_auth_fragment() {
  local registry="$1"
  registry="${registry#http://}"
  registry="${registry#https://}"
  registry="${registry%/}/"
  printf '//%s' "$registry"
}

json_string() {
  jq -Rn --arg value "$1" '$value'
}

write_result() {
  local status="$1"
  local package_ref="$2"
  local tarball="$3"
  local error="${4:-}"

  jq -cn \
    --arg status "$status" \
    --arg package "$package_ref" \
    --arg tarball "$tarball" \
    --arg error "$error" \
    '{status:$status, package:$package, tarball:$tarball, error:$error}' \
    >>"$RESULTS_JSONL"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR"
REGISTRY_URL=""
TOKEN="${ARTIFACTORY_TOKEN:-}"
USERNAME="${ARTIFACTORY_USERNAME:-}"
PASSWORD="${ARTIFACTORY_PASSWORD:-}"
SKIP_EXISTING=false
DRY_RUN=false

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

need_command jq
need_command sha1sum
if [[ "$DRY_RUN" != "true" ]]; then
  need_command npm
fi

if [[ -z "$TOKEN" && ( -z "$USERNAME" || -z "$PASSWORD" ) ]]; then
  fail "Set --token, or set --username and --password."
fi

NPMRC="$BUNDLE_DIR/.npmrc.publish"
RESULTS_JSONL="$BUNDLE_DIR/publish-results.jsonl"
RESULTS_JSON="$BUNDLE_DIR/publish-results.json"
SUMMARY_JSON="$BUNDLE_DIR/publish-summary.json"
PUBLISH_LOG="$BUNDLE_DIR/npm-publish.log"
: >"$RESULTS_JSONL"
: >"$PUBLISH_LOG"

fragment="$(registry_auth_fragment "$REGISTRY_URL")"
{
  printf 'registry=%s\n' "$REGISTRY_URL"
  printf '%s:always-auth=true\n' "$fragment"
  if [[ -n "$TOKEN" ]]; then
    printf '%s:_authToken=%s\n' "$fragment" "$TOKEN"
  else
    printf '%s:username=%s\n' "$fragment" "$USERNAME"
    printf '%s:_password=%s\n' "$fragment" "$(base64_one_line "$PASSWORD")"
    printf '%s:email=npm-bundle-publisher@example.invalid\n' "$fragment"
  fi
} >"$NPMRC"

total=0
published=0
skipped_existing=0
dry_run_count=0
failed=0

while IFS=$'\t' read -r package_ref tarball_rel expected_sha1; do
  [[ -n "$package_ref" ]] || continue
  total=$((total + 1))

  tarball="$BUNDLE_DIR/$tarball_rel"
  [[ -f "$tarball" ]] || fail "Missing tarball for $package_ref: $tarball"

  actual_sha1="$(sha1sum "$tarball" | awk '{print tolower($1)}')"
  expected_sha1="$(printf '%s' "$expected_sha1" | tr '[:upper:]' '[:lower:]')"
  if [[ "$actual_sha1" != "$expected_sha1" ]]; then
    fail "SHA1 mismatch for $package_ref. Expected $expected_sha1 but found $actual_sha1."
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY_RUN would publish $package_ref from $tarball_rel"
    dry_run_count=$((dry_run_count + 1))
    write_result dry-run "$package_ref" "$tarball_rel" ""
    continue
  fi

  log "Publishing $package_ref"
  set +e
  publish_output="$(npm publish "$tarball" --registry "$REGISTRY_URL" --userconfig "$NPMRC" --ignore-scripts 2>&1)"
  exit_code=$?
  set -e
  printf '%s\n' "$publish_output" >>"$PUBLISH_LOG"

  if [[ "$exit_code" -eq 0 ]]; then
    published=$((published + 1))
    write_result published "$package_ref" "$tarball_rel" ""
    continue
  fi

  if [[ "$SKIP_EXISTING" == "true" ]] &&
     grep -Eiq 'EPUBLISHCONFLICT|already exists|already present|cannot publish over|409|conflict' <<<"$publish_output"; then
    log "Skipping existing $package_ref"
    skipped_existing=$((skipped_existing + 1))
    write_result skipped-existing "$package_ref" "$tarball_rel" ""
    continue
  fi

  failed=$((failed + 1))
  write_result failed "$package_ref" "$tarball_rel" "$publish_output"
done < <(jq -r '.[] | [.Package, .Tarball, .Sha1] | @tsv' "$BUNDLE_DIR/packages.json")

jq -s '.' "$RESULTS_JSONL" >"$RESULTS_JSON"
jq -n \
  --arg registry_url "$REGISTRY_URL" \
  --arg bundle_dir "$BUNDLE_DIR" \
  --arg results_file "$RESULTS_JSON" \
  --arg publish_log "$PUBLISH_LOG" \
  --argjson package_count "$total" \
  --argjson published "$published" \
  --argjson skipped_existing "$skipped_existing" \
  --argjson dry_run "$dry_run_count" \
  --argjson failed "$failed" \
  '{registry_url:$registry_url, bundle_dir:$bundle_dir, package_count:$package_count,
    published:$published, skipped_existing:$skipped_existing, dry_run:$dry_run,
    failed:$failed, results_file:$results_file, publish_log:$publish_log}' \
  >"$SUMMARY_JSON"

cat "$SUMMARY_JSON"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
