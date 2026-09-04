#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Upload npm tarballs to an Artifactory npm repository.

Usage:
  ./upload-npm-tarballs-to-artifactory.sh --manifest FILE --registry-url URL [options]

Manifest format:
  Tab-separated rows with at least these columns:
    package_name    package_version    tarball_path

Options:
  --manifest FILE          TSV manifest of package versions and tarball paths.
  --registry-url URL       Artifactory npm registry URL.
  --work-dir DIR           Directory for logs and summaries.
  --token TOKEN            Artifactory token. Defaults to ARTIFACTORY_TOKEN.
  --username USER          Artifactory username. Defaults to ARTIFACTORY_USERNAME.
  --password PASSWORD      Artifactory password/API key. Defaults to ARTIFACTORY_PASSWORD.
  --skip-existing          Treat already-published versions as success.
  --dry-run                Print planned publish actions without calling npm.
  --normalize-library-package
                          Rewrite tarball package.json before upload. Default.
  --no-normalize-library-package
                          Publish the original tarball without metadata rewrites.
  --strip-peer-dependencies
                          Remove peerDependencies while normalizing.
  --strip-optional-dependencies
                          Remove optionalDependencies while normalizing.
  --npm-bin PATH           npm executable. Defaults to npm.
  --npm-flags FLAGS        Extra flags appended to npm publish.
  -h, --help               Show this help.

Tag behavior:
  The highest non-prerelease version for each package is published with the
  latest dist-tag. Older versions and prerelease versions use a unique
  gitlab-mirror-<version> dist-tag so they do not try to replace latest.

Library normalization:
  By default, uploaded tarballs are repacked with tar after removing package
  metadata that is not needed to import the package as a library. The rewrite
  keeps runtime entrypoint fields and dependencies, and removes scripts and
  devDependencies so npm install/publish does not attempt missing build, test,
  prepare, or lifecycle dependencies in an airgapped environment.
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

npm_mirror_tag_for_version() {
  local package_version="$1"
  local safe_version
  safe_version="$(printf '%s' "$package_version" | sed 's/[^A-Za-z0-9-]/-/g')"
  printf 'gitlab-mirror-%s' "$safe_version"
}

safe_package_slug() {
  local package_name="$1"
  local package_version="$2"
  printf '%s-%s' "$package_name" "$package_version" |
    sed 's/^@//; s#[/@]#-#g; s/[^A-Za-z0-9._-]/-/g'
}

write_sorted_manifest() {
  local input_file="$1"
  local output_file="$2"

  awk -F '\t' 'NF >= 3 && !($1 == "Name" && $2 == "Version") { print }' "$input_file" |
    sort -u |
    sort -t $'\t' -k1,1 -k2,2V >"$output_file"
}

write_latest_version_inventory() {
  local package_list="$1"
  local output_file="$2"

  awk -F '\t' 'index($2, "-") == 0 { latest[$1] = $2 } END { for (name in latest) print name "\t" latest[name] }' "$package_list" |
    sort >"$output_file"
}

get_latest_version_for_package() {
  local package_name="$1"
  awk -F '\t' -v package_name="$package_name" '$1 == package_name { print $2; exit }' "$LATEST_VERSIONS_FILE"
}

write_result() {
  local status="$1"
  local package_name="$2"
  local package_version="$3"
  local source_tarball="$4"
  local publish_tarball="$5"
  local dist_tag="$6"
  local normalized="$7"
  local error="${8:-}"

  jq -cn \
    --arg status "$status" \
    --arg package "$package_name" \
    --arg version "$package_version" \
    --arg source_tarball "$source_tarball" \
    --arg tarball "$publish_tarball" \
    --arg dist_tag "$dist_tag" \
    --argjson normalized "$normalized" \
    --arg error "$error" \
    '{status:$status, package:$package, version:$version,
      source_tarball:$source_tarball, tarball:$tarball,
      dist_tag:$dist_tag, normalized:$normalized, error:$error}' \
    >>"$RESULTS_JSONL"
}

normalize_npm_tarball_for_library() {
  local source_tarball="$1"
  local package_name="$2"
  local package_version="$3"
  local slug extract_dir package_json tmp_json output_tarball jq_filter

  slug="$(safe_package_slug "$package_name" "$package_version")"
  extract_dir="${NORMALIZED_TARBALL_DIR}/${slug}.extract"
  output_tarball="${NORMALIZED_TARBALL_DIR}/${slug}.tgz"
  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"

  tar -xzf "$source_tarball" -C "$extract_dir"
  package_json="${extract_dir}/package/package.json"
  [[ -f "$package_json" ]] || fail "Tarball does not contain package/package.json: $source_tarball"

  jq_filter='del(.scripts, .devDependencies)'
  if [[ "$STRIP_PEER_DEPENDENCIES" == "true" ]]; then
    jq_filter="${jq_filter} | del(.peerDependencies, .peerDependenciesMeta)"
  fi
  if [[ "$STRIP_OPTIONAL_DEPENDENCIES" == "true" ]]; then
    jq_filter="${jq_filter} | del(.optionalDependencies)"
  fi

  tmp_json="${package_json}.tmp"
  jq "$jq_filter" "$package_json" >"$tmp_json"
  mv "$tmp_json" "$package_json"

  tar -czf "$output_tarball" -C "$extract_dir" package
  printf '%s\n' "$output_tarball"
}

write_npmrc() {
  local npmrc="$1"
  local registry_url="$2"
  local token="$3"
  local username="$4"
  local password="$5"
  local fragment
  fragment="$(registry_auth_fragment "$registry_url")"

  {
    printf 'registry=%s\n' "$registry_url"
    printf '%s:always-auth=true\n' "$fragment"
    if [[ -n "$token" ]]; then
      printf '%s:_authToken=%s\n' "$fragment" "$token"
    else
      printf '%s:username=%s\n' "$fragment" "$username"
      printf '%s:_password=%s\n' "$fragment" "$(base64_one_line "$password")"
      printf '%s:email=npm-artifactory-uploader@example.invalid\n' "$fragment"
    fi
  } >"$npmrc"
}

publish_to_artifactory() {
  local tarball="$1"
  local package_ref="$2"
  local dist_tag="$3"
  local publish_log="$4"

  log "Publishing ${package_ref} to Artifactory with dist-tag ${dist_tag}"
  set +e
  publish_output="$("$NPM_BIN" publish "$tarball" \
    --registry "$REGISTRY_URL" \
    --userconfig "$NPMRC" \
    --tag "$dist_tag" \
    --ignore-scripts \
    ${NPM_FLAGS:-} 2>&1)"
  exit_code=$?
  set -e
  printf '%s\n' "$publish_output" >>"$publish_log"

  if [[ "$exit_code" -eq 0 ]]; then
    PUBLISH_RESULT="published"
    return 0
  fi

  if [[ "$SKIP_EXISTING" == "true" ]] &&
     grep -Eiq 'EPUBLISHCONFLICT|already exists|already present|cannot publish over|409|conflict' <<<"$publish_output"; then
    log "Skipping existing package ${package_ref}"
    PUBLISH_RESULT="skipped-existing"
    return 0
  fi

  PUBLISH_RESULT="failed"
  sed 's/^/[npm publish] /' <<<"$publish_output" >&2
  return "$exit_code"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST=""
REGISTRY_URL=""
WORK_DIR=""
TOKEN="${ARTIFACTORY_TOKEN:-}"
USERNAME="${ARTIFACTORY_USERNAME:-}"
PASSWORD="${ARTIFACTORY_PASSWORD:-}"
SKIP_EXISTING=false
DRY_RUN=false
NPM_BIN="${NPM_BIN:-npm}"
NPM_FLAGS="${NPM_FLAGS:-}"
NORMALIZE_LIBRARY_PACKAGE="${NORMALIZE_LIBRARY_PACKAGE:-true}"
STRIP_PEER_DEPENDENCIES="${STRIP_PEER_DEPENDENCIES:-false}"
STRIP_OPTIONAL_DEPENDENCIES="${STRIP_OPTIONAL_DEPENDENCIES:-false}"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --manifest)
      MANIFEST="$2"
      shift 2
      ;;
    --registry-url)
      REGISTRY_URL="$2"
      shift 2
      ;;
    --work-dir)
      WORK_DIR="$2"
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
    --npm-bin)
      NPM_BIN="$2"
      shift 2
      ;;
    --npm-flags)
      NPM_FLAGS="$2"
      shift 2
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

[[ -n "$MANIFEST" ]] || fail "--manifest is required"
[[ -f "$MANIFEST" ]] || fail "Manifest not found: $MANIFEST"
[[ -n "$REGISTRY_URL" ]] || fail "--registry-url is required"

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

need_command awk
need_command jq
need_command sort
need_command sed
if [[ "$NORMALIZE_LIBRARY_PACKAGE" == "true" && "$DRY_RUN" != "true" ]]; then
  need_command tar
fi
if [[ "$DRY_RUN" != "true" ]]; then
  need_command "$NPM_BIN"
  need_command base64
  if [[ -z "$TOKEN" && ( -z "$USERNAME" || -z "$PASSWORD" ) ]]; then
    fail "Set --token, or set --username and --password."
  fi
fi

if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/npm-artifactory-upload.XXXXXX")"
else
  mkdir -p "$WORK_DIR"
fi

NPMRC="${WORK_DIR}/npmrc"
SORTED_MANIFEST="${WORK_DIR}/upload-manifest.sorted.tsv"
LATEST_VERSIONS_FILE="${WORK_DIR}/upload-latest-versions.tsv"
RESULTS_JSONL="${WORK_DIR}/upload-results.jsonl"
RESULTS_JSON="${WORK_DIR}/upload-results.json"
SUMMARY_JSON="${WORK_DIR}/upload-summary.json"
PUBLISH_LOG="${WORK_DIR}/npm-publish.log"
NORMALIZED_TARBALL_DIR="${WORK_DIR}/normalized-tarballs"
: >"$RESULTS_JSONL"
: >"$PUBLISH_LOG"
mkdir -p "$NORMALIZED_TARBALL_DIR"

write_sorted_manifest "$MANIFEST" "$SORTED_MANIFEST"
write_latest_version_inventory "$SORTED_MANIFEST" "$LATEST_VERSIONS_FILE"
if [[ "$DRY_RUN" != "true" ]]; then
  write_npmrc "$NPMRC" "$REGISTRY_URL" "$TOKEN" "$USERNAME" "$PASSWORD"
fi

total=0
published=0
skipped_existing=0
dry_run_count=0
failed=0
PUBLISH_RESULT=""

while IFS=$'\t' read -r package_name package_version tarball _extra; do
  [[ -n "$package_name" ]] || continue
  total=$((total + 1))

  if [[ "$tarball" != /* ]]; then
    tarball="$(cd "$(dirname "$MANIFEST")" && pwd)/$tarball"
  fi
  [[ -f "$tarball" ]] || fail "Missing tarball for ${package_name}@${package_version}: $tarball"

  latest_version="$(get_latest_version_for_package "$package_name")"
  dist_tag="latest"
  if [[ -z "$latest_version" || "$package_version" != "$latest_version" ]]; then
    dist_tag="$(npm_mirror_tag_for_version "$package_version")"
  fi

  package_ref="${package_name}@${package_version}"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY_RUN would publish ${package_ref} with dist-tag ${dist_tag}"
    if [[ "$NORMALIZE_LIBRARY_PACKAGE" == "true" ]]; then
      log "DRY_RUN would normalize ${package_ref} for library upload"
    fi
    dry_run_count=$((dry_run_count + 1))
    write_result dry-run "$package_name" "$package_version" "$tarball" "$tarball" "$dist_tag" "$NORMALIZE_LIBRARY_PACKAGE" ""
    continue
  fi

  publish_tarball="$tarball"
  normalized=false
  if [[ "$NORMALIZE_LIBRARY_PACKAGE" == "true" ]]; then
    publish_tarball="$(normalize_npm_tarball_for_library "$tarball" "$package_name" "$package_version")"
    normalized=true
  fi

  if publish_to_artifactory "$publish_tarball" "$package_ref" "$dist_tag" "$PUBLISH_LOG"; then
    if [[ "$PUBLISH_RESULT" == "skipped-existing" ]]; then
      skipped_existing=$((skipped_existing + 1))
      write_result skipped-existing "$package_name" "$package_version" "$tarball" "$publish_tarball" "$dist_tag" "$normalized" ""
    else
      published=$((published + 1))
      write_result published "$package_name" "$package_version" "$tarball" "$publish_tarball" "$dist_tag" "$normalized" ""
    fi
  else
    failed=$((failed + 1))
    write_result failed "$package_name" "$package_version" "$tarball" "$publish_tarball" "$dist_tag" "$normalized" "Failed to publish ${package_ref}"
  fi
done <"$SORTED_MANIFEST"

jq -s '.' "$RESULTS_JSONL" >"$RESULTS_JSON"
jq -n \
  --arg registry_url "$REGISTRY_URL" \
  --arg manifest "$MANIFEST" \
  --arg sorted_manifest "$SORTED_MANIFEST" \
  --arg latest_versions_file "$LATEST_VERSIONS_FILE" \
  --arg work_dir "$WORK_DIR" \
  --arg results_file "$RESULTS_JSON" \
  --arg publish_log "$PUBLISH_LOG" \
  --arg normalized_tarball_dir "$NORMALIZED_TARBALL_DIR" \
  --argjson normalize_library_package "$NORMALIZE_LIBRARY_PACKAGE" \
  --argjson strip_peer_dependencies "$STRIP_PEER_DEPENDENCIES" \
  --argjson strip_optional_dependencies "$STRIP_OPTIONAL_DEPENDENCIES" \
  --argjson package_count "$total" \
  --argjson published "$published" \
  --argjson skipped_existing "$skipped_existing" \
  --argjson dry_run "$dry_run_count" \
  --argjson failed "$failed" \
  --slurpfile results "$RESULTS_JSON" \
  '{registry_url:$registry_url, manifest:$manifest, sorted_manifest:$sorted_manifest,
    latest_versions_file:$latest_versions_file, work_dir:$work_dir,
    normalized_tarball_dir:$normalized_tarball_dir,
    normalize_library_package:$normalize_library_package,
    strip_peer_dependencies:$strip_peer_dependencies,
    strip_optional_dependencies:$strip_optional_dependencies,
    package_count:$package_count, published:$published, skipped_existing:$skipped_existing,
    dry_run:$dry_run, failed:$failed, results_file:$results_file, publish_log:$publish_log,
    results:$results[0]}' \
  >"$SUMMARY_JSON"

cat "$SUMMARY_JSON"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
