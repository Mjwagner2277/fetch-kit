#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Mirror npm packages from a GitLab npm registry to an Artifactory npm repository.

Required environment variables:
  GITLAB_URL                    Base GitLab URL, for example https://gitlab.example.com
  GITLAB_TOKEN                  GitLab token with API and package read access
  GITLAB_SCOPE_TYPE             project or group
  GITLAB_SCOPE_ID               Project/group numeric ID or URL path

  ARTIFACTORY_NPM_REGISTRY      Artifactory npm URL, for example
                                https://art.example.com/artifactory/api/npm/npm-local/

Artifactory authentication, choose one:
  ARTIFACTORY_TOKEN             Access token/API token for npm publish
  ARTIFACTORY_USERNAME          Username for basic auth
  ARTIFACTORY_PASSWORD          Password/API key/token for basic auth

Optional environment variables:
  GITLAB_NPM_REGISTRY           Override source npm registry URL
  GITLAB_PACKAGE_STATUS         GitLab package status filter. Defaults to default.
                                Use all to omit the status filter.
  WORK_DIR                      Directory for downloaded tarballs and logs
  KEEP_WORK_DIR                 true to keep the temporary work directory
  SKIP_EXISTING                 true to treat already-published versions as success
  DRY_RUN                       true to list planned actions without downloading/publishing
  DRY_RUN_SIZE                  true to query GitLab package file sizes during DRY_RUN.
                                Defaults to true.
  INCLUDE_PACKAGE_REGEX         Only mirror package names matching this regex
  EXCLUDE_PACKAGE_REGEX         Skip package names matching this regex
  NPM_FLAGS                     Extra flags appended to npm pack and npm publish

Examples:
  GITLAB_URL=https://gitlab.example.com \
  GITLAB_TOKEN=glpat-... \
  GITLAB_SCOPE_TYPE=project \
  GITLAB_SCOPE_ID=12345 \
  ARTIFACTORY_NPM_REGISTRY=https://art.example.com/artifactory/api/npm/npm-local/ \
  ARTIFACTORY_TOKEN=... \
    ./npm/mirror-gitlab-npm-to-artifactory.sh

  GITLAB_SCOPE_TYPE=group GITLAB_SCOPE_ID=my-group/subgroup \
    ./npm/mirror-gitlab-npm-to-artifactory.sh
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

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    fail "Missing required environment variable: $name"
  fi
}

urlencode() {
  jq -rn --arg value "$1" '$value|@uri'
}

registry_auth_fragment() {
  local registry="$1"
  registry="${registry#http://}"
  registry="${registry#https://}"
  registry="${registry%/}/"
  printf '//%s' "$registry"
}

base64_one_line() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

json_string() {
  jq -Rn --arg value "$1" '$value'
}

format_bytes() {
  local bytes="$1"
  awk -v bytes="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB", units, " ");
    value = bytes + 0;
    unit = 1;
    while (value >= 1024 && unit < 5) {
      value = value / 1024;
      unit++;
    }
    if (unit == 1) {
      printf "%d %s", value, units[unit];
    } else {
      printf "%.2f %s", value, units[unit];
    }
  }'
}

is_true() {
  case "${1:-}" in
    true|TRUE|1|yes|YES|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

append_npm_auth() {
  local npmrc="$1"
  local registry="$2"
  local token="${3:-}"
  local username="${4:-}"
  local password="${5:-}"
  local fragment
  fragment="$(registry_auth_fragment "$registry")"

  {
    printf '%s:always-auth=true\n' "$fragment"
    if [[ -n "$token" ]]; then
      printf '%s:_authToken=%s\n' "$fragment" "$token"
    elif [[ -n "$username" && -n "$password" ]]; then
      printf '%s:username=%s\n' "$fragment" "$username"
      printf '%s:_password=%s\n' "$fragment" "$(base64_one_line "$password")"
      printf '%s:email=npm-mirror@example.invalid\n' "$fragment"
    else
      fail "No npm authentication provided for $registry"
    fi
  } >>"$npmrc"
}

gitlab_api_get() {
  local url="$1"
  curl --fail --silent --show-error \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --header 'Accept: application/json' \
    "$url"
}

build_gitlab_urls() {
  local encoded_scope
  encoded_scope="$(urlencode "$GITLAB_SCOPE_ID")"

  case "$GITLAB_SCOPE_TYPE" in
    project)
      GITLAB_PACKAGES_API="${GITLAB_URL%/}/api/v4/projects/${encoded_scope}/packages"
      DEFAULT_GITLAB_NPM_REGISTRY="${GITLAB_URL%/}/api/v4/projects/${encoded_scope}/packages/npm/"
      ;;
    group)
      GITLAB_PACKAGES_API="${GITLAB_URL%/}/api/v4/groups/${encoded_scope}/packages"
      DEFAULT_GITLAB_NPM_REGISTRY="${GITLAB_URL%/}/api/v4/groups/${encoded_scope}/-/packages/npm/"
      ;;
    *)
      fail "GITLAB_SCOPE_TYPE must be project or group"
      ;;
  esac

  GITLAB_NPM_REGISTRY="${GITLAB_NPM_REGISTRY:-$DEFAULT_GITLAB_NPM_REGISTRY}"
}

package_allowed() {
  local package_name="$1"

  if [[ -n "${INCLUDE_PACKAGE_REGEX:-}" ]] && ! [[ "$package_name" =~ $INCLUDE_PACKAGE_REGEX ]]; then
    return 1
  fi

  if [[ -n "${EXCLUDE_PACKAGE_REGEX:-}" ]] && [[ "$package_name" =~ $EXCLUDE_PACKAGE_REGEX ]]; then
    return 1
  fi

  return 0
}

list_gitlab_npm_packages() {
  local output_file="$1"
  local page=1
  local page_file
  page_file="${WORK_DIR}/gitlab-packages-page.json"
  : >"$output_file"

  while true; do
    local url="${GITLAB_PACKAGES_API}?package_type=npm&per_page=100&page=${page}&order_by=name&sort=asc"
    if [[ "${GITLAB_PACKAGE_STATUS}" != "all" ]]; then
      url="${url}&status=${GITLAB_PACKAGE_STATUS}"
    fi

    log "Listing GitLab npm packages page ${page}"
    gitlab_api_get "$url" >"$page_file"

    local count
    count="$(jq 'length' "$page_file")"
    if [[ "$count" == "0" ]]; then
      break
    fi

    jq -r '.[] | select(.name and .version) |
      [.name, .version, (.id // ""), (.project_id // ""), (._links.delete_api_path // "")] | @tsv' "$page_file" >>"$output_file"
    page=$((page + 1))
  done

  sort -u "$output_file" -o "$output_file"
}

get_package_files_url() {
  local package_id="$1"
  local project_id="${2:-}"
  local delete_api_path="${3:-}"

  if [[ "$GITLAB_SCOPE_TYPE" == "project" ]]; then
    printf '%s/%s/package_files\n' "$GITLAB_PACKAGES_API" "$package_id"
    return 0
  fi

  if [[ -n "$project_id" && "$project_id" != "null" ]]; then
    printf '%s/api/v4/projects/%s/packages/%s/package_files\n' "${GITLAB_URL%/}" "$(urlencode "$project_id")" "$package_id"
    return 0
  fi

  if [[ "$delete_api_path" == /api/v4/projects/*/packages/* ]]; then
    printf '%s%s/package_files\n' "${GITLAB_URL%/}" "$delete_api_path"
    return 0
  fi

  return 1
}

get_package_file_size_summary() {
  local package_id="$1"
  local project_id="${2:-}"
  local delete_api_path="${3:-}"
  local files_url

  if ! files_url="$(get_package_files_url "$package_id" "$project_id" "$delete_api_path")"; then
    printf 'unknown\t0\t'
    return 0
  fi

  local page=1
  local total_size=0
  local total_files=0
  local page_file="${WORK_DIR}/gitlab-package-files-${package_id}.json"

  while true; do
    local url="${files_url}?per_page=100&page=${page}&order_by=file_name&sort=asc"
    gitlab_api_get "$url" >"$page_file"

    local count
    count="$(jq 'length' "$page_file")"
    if [[ "$count" == "0" ]]; then
      break
    fi

    local page_size
    page_size="$(jq '[.[].size // 0] | add // 0' "$page_file")"
    total_size=$((total_size + page_size))
    total_files=$((total_files + count))
    page=$((page + 1))
  done

  printf '%s\t%s\t%s' "$total_size" "$total_files" "$files_url"
}

pack_from_gitlab() {
  local package_name="$1"
  local package_version="$2"
  local package_ref="${package_name}@${package_version}"
  local pack_json="${WORK_DIR}/pack.json"

  log "Packing ${package_ref} from GitLab"
  npm pack "$package_ref" \
    --registry "$GITLAB_NPM_REGISTRY" \
    --userconfig "$NPMRC" \
    --pack-destination "$TARBALL_DIR" \
    --ignore-scripts \
    --json \
    ${NPM_FLAGS:-} >"$pack_json"

  local filename
  filename="$(jq -r '.[0].filename // empty' "$pack_json")"
  if [[ -z "$filename" ]]; then
    fail "npm pack did not return a tarball filename for ${package_ref}"
  fi

  printf '%s/%s\n' "$TARBALL_DIR" "$filename"
}

publish_to_artifactory() {
  local tarball="$1"
  local package_ref="$2"
  local publish_log="${WORK_DIR}/publish.log"

  log "Publishing ${package_ref} to Artifactory"
  set +e
  npm publish "$tarball" \
    --registry "$ARTIFACTORY_NPM_REGISTRY" \
    --userconfig "$NPMRC" \
    --ignore-scripts \
    ${NPM_FLAGS:-} >"$publish_log" 2>&1
  local exit_code=$?
  set -e

  if [[ "$exit_code" -eq 0 ]]; then
    return 0
  fi

  if is_true "${SKIP_EXISTING:-true}" && grep -Eiq 'EPUBLISHCONFLICT|already exists|already present|cannot publish over|409|conflict' "$publish_log"; then
    log "Skipping existing package ${package_ref}"
    return 0
  fi

  sed 's/^/[npm publish] /' "$publish_log" >&2
  return "$exit_code"
}

write_result() {
  local status="$1"
  local package_name="$2"
  local package_version="$3"
  local package_id="$4"
  local tarball="$5"
  local error_message="${6:-}"
  local size_bytes="${7:-}"
  local size_known="${8:-false}"
  local file_count="${9:-0}"
  local package_files_url="${10:-}"

  jq -cn \
    --arg status "$status" \
    --arg package "$package_name" \
    --arg version "$package_version" \
    --arg id "$package_id" \
    --arg tarball "$tarball" \
    --arg error "$error_message" \
    --arg package_files_url "$package_files_url" \
    --argjson size_bytes "${size_bytes:-0}" \
    --argjson size_known "$size_known" \
    --argjson file_count "${file_count:-0}" \
    '{status:$status, package:$package, version:$version, gitlab_package_id:$id, tarball:$tarball,
      size_bytes:$size_bytes, size_known:$size_known, file_count:$file_count,
      package_files_url:$package_files_url, error:$error}' \
    >>"$RESULTS_JSONL"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  need_command curl
  need_command jq
  need_command npm
  need_command sort
  need_command base64

  require_env GITLAB_URL
  require_env GITLAB_TOKEN
  require_env GITLAB_SCOPE_TYPE
  require_env GITLAB_SCOPE_ID
  require_env ARTIFACTORY_NPM_REGISTRY

  if [[ -z "${ARTIFACTORY_TOKEN:-}" && ( -z "${ARTIFACTORY_USERNAME:-}" || -z "${ARTIFACTORY_PASSWORD:-}" ) ]]; then
    fail "Set ARTIFACTORY_TOKEN or ARTIFACTORY_USERNAME plus ARTIFACTORY_PASSWORD"
  fi

  GITLAB_PACKAGE_STATUS="${GITLAB_PACKAGE_STATUS:-default}"
  DRY_RUN_SIZE="${DRY_RUN_SIZE:-true}"
  build_gitlab_urls

  if [[ -z "${WORK_DIR:-}" ]]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gitlab-npm-artifactory.XXXXXX")"
  else
    mkdir -p "$WORK_DIR"
  fi

  TARBALL_DIR="${WORK_DIR}/tarballs"
  mkdir -p "$TARBALL_DIR"
  NPMRC="${WORK_DIR}/npmrc"
  PACKAGE_LIST="${WORK_DIR}/gitlab-npm-packages.tsv"
  RESULTS_JSONL="${WORK_DIR}/results.jsonl"
  SUMMARY_JSON="${WORK_DIR}/summary.json"
  : >"$NPMRC"
  : >"$RESULTS_JSONL"

  if ! is_true "${KEEP_WORK_DIR:-false}"; then
    trap 'rm -rf "$WORK_DIR"' EXIT
  fi

  append_npm_auth "$NPMRC" "$GITLAB_NPM_REGISTRY" "$GITLAB_TOKEN" "" ""
  append_npm_auth "$NPMRC" "$ARTIFACTORY_NPM_REGISTRY" "${ARTIFACTORY_TOKEN:-}" "${ARTIFACTORY_USERNAME:-}" "${ARTIFACTORY_PASSWORD:-}"

  log "GitLab packages API: ${GITLAB_PACKAGES_API}"
  log "GitLab npm registry: ${GITLAB_NPM_REGISTRY}"
  log "Artifactory npm registry: ${ARTIFACTORY_NPM_REGISTRY}"
  log "Work directory: ${WORK_DIR}"

  list_gitlab_npm_packages "$PACKAGE_LIST"

  local discovered
  discovered="$(wc -l <"$PACKAGE_LIST" | tr -d ' ')"
  log "Discovered ${discovered} npm package versions"

  local total=0
  local mirrored=0
  local skipped=0
  local failed=0
  local size_known_total=0
  local size_unknown_count=0

  while IFS=$'\t' read -r package_name package_version package_id project_id delete_api_path; do
    [[ -n "$package_name" ]] || continue

    if ! package_allowed "$package_name"; then
      skipped=$((skipped + 1))
      write_result skipped "$package_name" "$package_version" "$package_id" "" "Filtered by package regex"
      continue
    fi

    total=$((total + 1))
    local package_ref="${package_name}@${package_version}"

    if is_true "${DRY_RUN:-false}"; then
      local size_bytes=0
      local size_known=false
      local file_count=0
      local package_files_url=""

      if is_true "$DRY_RUN_SIZE"; then
        local size_summary
        size_summary="$(get_package_file_size_summary "$package_id" "${project_id:-}" "${delete_api_path:-}")"
        IFS=$'\t' read -r size_bytes file_count package_files_url <<<"$size_summary"
        if [[ "$size_bytes" == "unknown" ]]; then
          size_bytes=0
          size_unknown_count=$((size_unknown_count + 1))
        else
          size_known=true
          size_known_total=$((size_known_total + size_bytes))
        fi
      fi

      if [[ "$size_known" == "true" ]]; then
        log "DRY_RUN would mirror ${package_ref} ($(format_bytes "$size_bytes"), ${file_count} files)"
      else
        log "DRY_RUN would mirror ${package_ref} (size unknown)"
      fi
      write_result dry-run "$package_name" "$package_version" "$package_id" "" "" "$size_bytes" "$size_known" "$file_count" "$package_files_url"
      continue
    fi

    local tarball=""
    local error_message=""
    if tarball="$(pack_from_gitlab "$package_name" "$package_version")" &&
       publish_to_artifactory "$tarball" "$package_ref"; then
      mirrored=$((mirrored + 1))
      write_result mirrored "$package_name" "$package_version" "$package_id" "$tarball" ""
    else
      failed=$((failed + 1))
      error_message="Failed to mirror ${package_ref}"
      log "$error_message"
      write_result failed "$package_name" "$package_version" "$package_id" "$tarball" "$error_message"
      if ! is_true "${CONTINUE_ON_ERROR:-true}"; then
        fail "$error_message"
      fi
    fi
  done <"$PACKAGE_LIST"

  if is_true "${DRY_RUN:-false}" && is_true "$DRY_RUN_SIZE"; then
    log "DRY_RUN total known package file size: $(format_bytes "$size_known_total") (${size_known_total} bytes)"
    if [[ "$size_unknown_count" -gt 0 ]]; then
      log "DRY_RUN package versions with unknown size: ${size_unknown_count}"
    fi
  fi

  jq -s \
    --arg gitlab_url "$GITLAB_URL" \
    --arg gitlab_scope_type "$GITLAB_SCOPE_TYPE" \
    --arg gitlab_scope_id "$GITLAB_SCOPE_ID" \
    --arg gitlab_registry "$GITLAB_NPM_REGISTRY" \
    --arg artifactory_registry "$ARTIFACTORY_NPM_REGISTRY" \
    --arg work_dir "$WORK_DIR" \
    --argjson discovered "$discovered" \
    --argjson total "$total" \
    --argjson mirrored "$mirrored" \
    --argjson skipped "$skipped" \
    --argjson failed "$failed" \
    --argjson dry_run_size_bytes "$size_known_total" \
    --arg dry_run_size_human "$(format_bytes "$size_known_total")" \
    --argjson dry_run_unknown_size_count "$size_unknown_count" \
    '{gitlab_url:$gitlab_url, gitlab_scope_type:$gitlab_scope_type, gitlab_scope_id:$gitlab_scope_id,
      gitlab_registry:$gitlab_registry, artifactory_registry:$artifactory_registry, work_dir:$work_dir,
      discovered:$discovered, selected:$total, mirrored:$mirrored, skipped:$skipped, failed:$failed,
      dry_run_size_bytes:$dry_run_size_bytes, dry_run_size_human:$dry_run_size_human,
      dry_run_unknown_size_count:$dry_run_unknown_size_count,
      results:.}' \
    "$RESULTS_JSONL" >"$SUMMARY_JSON"

  cat "$SUMMARY_JSON"

  if [[ "$failed" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
