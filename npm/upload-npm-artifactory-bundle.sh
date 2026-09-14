#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Upload an npm transfer bundle to an npm-compatible registry.

Usage:
  bash npm/upload-npm-artifactory-bundle.sh --bundle-tar FILE --registry-url URL [options]

Options:
  --bundle-tar FILE          Transfer tar produced by download-npm-artifactory-bundle.js.
  --bundle-dir DIR           Already-extracted bundle directory. Alternative to --bundle-tar.
  --registry-url URL         Target npm registry URL.
  --userconfig FILE          npmrc file for target registry auth.
  --token TOKEN              Registry token. Defaults to NPM_TOKEN or ARTIFACTORY_TOKEN.
  --username USER            Registry username. Defaults to NPM_USERNAME or ARTIFACTORY_USERNAME.
  --password PASSWORD        Registry password/API key. Defaults to NPM_PASSWORD or ARTIFACTORY_PASSWORD.
  --no-ssl                   Disable npm SSL certificate validation.
  --work-dir DIR             Working directory for extraction, npmrc, logs, and summaries.
  --keep-work-dir            Keep a temporary work directory after completion.
  --skip-existing            Treat already-published versions as success. Default.
  --no-skip-existing         Treat already-published versions as failures.
  --dry-run                  Query the target registry and print planned publish actions.
  --latest-policy POLICY     computed, never, or force-computed. Defaults to computed.
  --fail-on-remote-query-error
                             Fail if target registry versions cannot be queried.
                             Default is to avoid latest for that package and continue.
  --tag-prefix PREFIX        Prefix for non-latest dist-tags. Defaults to airgap-.
  --publish-retries N        Retries after a failed publish attempt. Defaults to 2.
  --retry-delay-ms N         Delay between publish retries. Defaults to 1000.
  --npm-bin PATH             npm executable. Defaults to npm.
  --npm-flags FLAGS          Extra shell-split flags appended to npm publish.
  -h, --help                 Show this help.

latest-policy:
  computed        Query target registry versions for every package. An incoming
                  stable version only gets latest if it is the highest stable
                  version across both the target registry and the incoming bundle.
                  If lookup fails for one package, avoid latest for that package
                  and continue unless --fail-on-remote-query-error is set.
  never           Never publish with latest. Every version gets PREFIX<version>.
  force-computed  Compute latest from the incoming bundle only. This can move
                  latest backwards if the target registry already has a newer version.
USAGE
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

absolute_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$(pwd -P)" "$1" ;;
  esac
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

json_bool() {
  if [[ "$1" == "true" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

one_line() {
  tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ //; s/ $//'
}

safe_tag_version() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/-/g'
}

mirror_tag_for_version() {
  printf '%s%s' "$TAG_PREFIX" "$(safe_tag_version "$1")"
}

is_prerelease() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+- ]]
}

is_stable_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9A-Za-z.-]+)?$ ]]
}

semver_greater() {
  local left="$1"
  local right="$2"
  local last
  [[ -n "$left" && -n "$right" && "$left" != "$right" ]] || return 1
  last="$(printf '%s\n%s\n' "$left" "$right" | LC_ALL=C sort -V | tail -n 1)"
  [[ "$last" == "$left" ]]
}

highest_stable_from_files() {
  awk 'NF > 0 && $0 ~ /^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9A-Za-z.-]+)?$/ { print }' "$@" \
    | LC_ALL=C sort -V \
    | tail -n 1
}

sleep_ms() {
  local ms="$1"
  local seconds
  [[ "$ms" -gt 0 ]] || return 0
  seconds="$(awk -v ms="$ms" 'BEGIN { printf "%.3f", ms / 1000 }')"
  sleep "$seconds"
}

BUNDLE_TAR=""
BUNDLE_DIR=""
REGISTRY_URL=""
USERCONFIG=""
TOKEN="${NPM_TOKEN:-${ARTIFACTORY_TOKEN:-}}"
USERNAME="${NPM_USERNAME:-${ARTIFACTORY_USERNAME:-}}"
PASSWORD="${NPM_PASSWORD:-${ARTIFACTORY_PASSWORD:-}}"
STRICT_SSL="true"
WORK_DIR=""
KEEP_WORK_DIR="false"
SKIP_EXISTING="true"
DRY_RUN="false"
LATEST_POLICY="computed"
FAIL_ON_REMOTE_QUERY_ERROR="false"
TAG_PREFIX="airgap-"
PUBLISH_RETRIES=2
RETRY_DELAY_MS=1000
NPM_BIN="${NPM_BIN:-npm}"
NPM_FLAGS="${NPM_FLAGS:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --bundle-tar)
      shift || fail "Missing value for --bundle-tar"
      BUNDLE_TAR="$(absolute_path "$1")"
      ;;
    --bundle-dir)
      shift || fail "Missing value for --bundle-dir"
      BUNDLE_DIR="$(absolute_path "$1")"
      ;;
    --registry-url)
      shift || fail "Missing value for --registry-url"
      REGISTRY_URL="$1"
      ;;
    --userconfig)
      shift || fail "Missing value for --userconfig"
      USERCONFIG="$(absolute_path "$1")"
      ;;
    --token)
      shift || fail "Missing value for --token"
      TOKEN="$1"
      ;;
    --username)
      shift || fail "Missing value for --username"
      USERNAME="$1"
      ;;
    --password)
      shift || fail "Missing value for --password"
      PASSWORD="$1"
      ;;
    --no-ssl|--no-strict-ssl)
      STRICT_SSL="false"
      ;;
    --work-dir)
      shift || fail "Missing value for --work-dir"
      WORK_DIR="$(absolute_path "$1")"
      ;;
    --keep-work-dir)
      KEEP_WORK_DIR="true"
      ;;
    --skip-existing)
      SKIP_EXISTING="true"
      ;;
    --no-skip-existing)
      SKIP_EXISTING="false"
      ;;
    --dry-run)
      DRY_RUN="true"
      ;;
    --latest-policy)
      shift || fail "Missing value for --latest-policy"
      LATEST_POLICY="$1"
      ;;
    --fail-on-remote-query-error)
      FAIL_ON_REMOTE_QUERY_ERROR="true"
      ;;
    --tag-prefix)
      shift || fail "Missing value for --tag-prefix"
      TAG_PREFIX="$1"
      ;;
    --publish-retries)
      shift || fail "Missing value for --publish-retries"
      PUBLISH_RETRIES="$1"
      ;;
    --retry-delay-ms)
      shift || fail "Missing value for --retry-delay-ms"
      RETRY_DELAY_MS="$1"
      ;;
    --npm-bin)
      shift || fail "Missing value for --npm-bin"
      NPM_BIN="$1"
      ;;
    --npm-flags)
      shift || fail "Missing value for --npm-flags"
      NPM_FLAGS="$1"
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
  shift || true
done

[[ -n "$REGISTRY_URL" ]] || fail "--registry-url is required"
[[ -z "$BUNDLE_TAR" || -z "$BUNDLE_DIR" ]] || fail "Use only one of --bundle-tar or --bundle-dir"
[[ "$LATEST_POLICY" == "computed" || "$LATEST_POLICY" == "never" || "$LATEST_POLICY" == "force-computed" ]] \
  || fail "--latest-policy must be computed, never, or force-computed"
[[ "$TAG_PREFIX" =~ ^[A-Za-z][A-Za-z0-9._-]*$ ]] \
  || fail "--tag-prefix must start with a letter and contain only letters, numbers, dots, underscores, or hyphens"
[[ "$PUBLISH_RETRIES" =~ ^[0-9]+$ ]] || fail "--publish-retries must be a non-negative integer"
[[ "$RETRY_DELAY_MS" =~ ^[0-9]+$ ]] || fail "--retry-delay-ms must be a non-negative integer"

require_command jq
require_command tar
require_command sort
require_command awk
require_command sed
require_command "$NPM_BIN"

CREATED_TEMP_WORK_DIR="false"
if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/npm-registry-upload.XXXXXX")"
  CREATED_TEMP_WORK_DIR="true"
else
  mkdir -p "$WORK_DIR"
fi

cleanup() {
  if [[ "$CREATED_TEMP_WORK_DIR" == "true" && "$KEEP_WORK_DIR" != "true" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

registry_auth_fragment() {
  local registry="$1"
  registry="${registry#http://}"
  registry="${registry#https://}"
  registry="${registry%/}/"
  printf '//%s' "$registry"
}

write_generated_npmrc() {
  [[ -z "$USERCONFIG" ]] || return 0
  [[ -n "$TOKEN" || ( -n "$USERNAME" && -n "$PASSWORD" ) ]] \
    || fail "Set --userconfig, --token, or --username plus --password"

  local registry="${REGISTRY_URL%/}/"
  local fragment
  local encoded_password
  fragment="$(registry_auth_fragment "$registry")"
  USERCONFIG="${WORK_DIR}/target-registry.npmrc"

  {
    printf 'registry=%s\n' "$registry"
    printf '%s:always-auth=true\n' "$fragment"
    if [[ "$STRICT_SSL" != "true" ]]; then
      printf 'strict-ssl=false\n'
    fi
    if [[ -n "$TOKEN" ]]; then
      printf '%s:_authToken=%s\n' "$fragment" "$TOKEN"
    else
      encoded_password="$(printf '%s' "$PASSWORD" | base64 | tr -d '\n')"
      printf '%s:username=%s\n' "$fragment" "$USERNAME"
      printf '%s:_password=%s\n' "$fragment" "$encoded_password"
      printf '%s:email=npm-registry-uploader@example.invalid\n' "$fragment"
    fi
  } > "$USERCONFIG"
}

write_generated_npmrc

NPM_CONFIG_ARGS=("--registry=$REGISTRY_URL" "--userconfig=$USERCONFIG")
if [[ "$STRICT_SSL" != "true" ]]; then
  NPM_CONFIG_ARGS+=("--strict-ssl=false")
fi

extract_bundle() {
  if [[ -n "$BUNDLE_DIR" ]]; then
    [[ -d "$BUNDLE_DIR" ]] || fail "Bundle directory not found: $BUNDLE_DIR"
    printf '%s\n' "$BUNDLE_DIR"
    return 0
  fi

  [[ -n "$BUNDLE_TAR" ]] || fail "Set --bundle-tar or --bundle-dir"
  [[ -f "$BUNDLE_TAR" ]] || fail "Bundle tar not found: $BUNDLE_TAR"

  local extract_dir="${WORK_DIR}/extract"
  mkdir -p "$extract_dir"
  tar -xf "$BUNDLE_TAR" -C "$extract_dir"

  shopt -s nullglob
  local entries=("$extract_dir"/*)
  shopt -u nullglob
  if [[ "${#entries[@]}" -eq 1 && -d "${entries[0]}" ]]; then
    printf '%s\n' "${entries[0]}"
  else
    printf '%s\n' "$extract_dir"
  fi
}

BUNDLE_DIR_RESOLVED="$(extract_bundle)"
PACKAGES_TSV="${WORK_DIR}/packages-normalized.tsv"
SORTED_PACKAGES_TSV="${WORK_DIR}/packages-sorted.tsv"
PLAN_TSV="${WORK_DIR}/tag-plan.tsv"
REMOTE_JSONL="${WORK_DIR}/remote-by-package.jsonl"
REMOTE_JSON="${WORK_DIR}/remote-by-package.json"
RESULTS_JSONL="${WORK_DIR}/upload-results.jsonl"
RESULTS_JSON="${WORK_DIR}/upload-results.json"
SUMMARY_JSON="${WORK_DIR}/upload-summary.json"
PUBLISH_LOG="${WORK_DIR}/npm-publish.log"

extract_tarball_package_json() {
  local tarball_path="$1"
  tar -xOzf "$tarball_path" package/package.json 2>/dev/null && return 0
  tar -xOzf "$tarball_path" ./package/package.json 2>/dev/null && return 0
  return 1
}

validate_package_tarball() {
  local name="$1"
  local version="$2"
  local tarball_path="$3"
  local package_ref="$4"
  local package_json
  local actual
  local actual_name
  local actual_version

  if ! package_json="$(extract_tarball_package_json "$tarball_path")"; then
    fail "Package tarball for ${package_ref} does not contain package/package.json: ${tarball_path}. Use the downloader transfer tar or a manifest that points at npm package .tgz files."
  fi

  if ! actual="$(printf '%s\n' "$package_json" | jq -r '[.name // "", ((.version // "") | tostring)] | @tsv')"; then
    fail "Package tarball for ${package_ref} contains package/package.json that is not valid JSON: ${tarball_path}"
  fi

  IFS=$'\t' read -r actual_name actual_version <<< "$actual"
  if [[ "$actual_name" != "$name" || "$actual_version" != "$version" ]]; then
    fail "Package tarball mismatch for ${package_ref}: manifest points to ${tarball_path}, but package/package.json contains ${actual_name}@${actual_version}"
  fi
}

read_manifest() {
  local jsonl="${BUNDLE_DIR_RESOLVED}/packages.jsonl"
  local json="${BUNDLE_DIR_RESOLVED}/packages.json"
  local tsv="${BUNDLE_DIR_RESOLVED}/artifactory-upload-manifest.tsv"

  if [[ -f "$jsonl" ]]; then
    MANIFEST_FILE="$jsonl"
    jq -r '
      select(type == "object")
      | (.name // .Name) as $name
      | ((.version // .Version) | tostring) as $version
      | (.tarball // .Tarball) as $tarball
      | [ $name, $version, $tarball, (.package // .Package // ($name + "@" + $version)) ]
      | @tsv
    ' "$jsonl" > "$PACKAGES_TSV"
  elif [[ -f "$json" ]]; then
    MANIFEST_FILE="$json"
    jq -r '
      .[]
      | (.name // .Name) as $name
      | ((.version // .Version) | tostring) as $version
      | (.tarball // .Tarball) as $tarball
      | [ $name, $version, $tarball, (.package // .Package // ($name + "@" + $version)) ]
      | @tsv
    ' "$json" > "$PACKAGES_TSV"
  elif [[ -f "$tsv" ]]; then
    MANIFEST_FILE="$tsv"
    awk -F '\t' '
      BEGIN { OFS = "\t" }
      NF >= 3 && tolower($1 "\t" $2 "\t" $3) != "name\tversion\ttarball" {
        print $1, $2, $3, $1 "@" $2
      }
    ' "$tsv" > "$PACKAGES_TSV"
  else
    fail "No manifest found in $BUNDLE_DIR_RESOLVED"
  fi

  [[ -s "$PACKAGES_TSV" ]] || fail "Manifest has no packages: $MANIFEST_FILE"

  while IFS=$'\t' read -r name version tarball package_ref; do
    [[ -n "$name" && -n "$version" && -n "$tarball" ]] \
      || fail "Manifest entry is missing name, version, or tarball in $MANIFEST_FILE"
    [[ -f "${BUNDLE_DIR_RESOLVED}/${tarball}" ]] \
      || fail "Tarball not found for ${package_ref}: ${BUNDLE_DIR_RESOLVED}/${tarball}"
    validate_package_tarball "$name" "$version" "${BUNDLE_DIR_RESOLVED}/${tarball}" "$package_ref"
  done < "$PACKAGES_TSV"
}

read_manifest
LC_ALL=C sort -t $'\t' -k1,1 -k2,2V "$PACKAGES_TSV" > "$SORTED_PACKAGES_TSV"
: > "$PLAN_TSV"
: > "$REMOTE_JSONL"
: > "$RESULTS_JSONL"
: > "$PUBLISH_LOG"

npm_view_versions() {
  local package_name="$1"
  local versions_file="$2"
  local error_file="$3"
  local raw_file="${versions_file}.raw"
  local combined_file="${versions_file}.combined"

  if "$NPM_BIN" view "$package_name" versions --json "${NPM_CONFIG_ARGS[@]}" > "$raw_file" 2> "$error_file"; then
    if [[ -s "$raw_file" ]]; then
      jq -r 'if type == "array" then .[] else . end | tostring' "$raw_file" > "$versions_file"
    else
      : > "$versions_file"
    fi
    return 0
  fi

  cat "$raw_file" "$error_file" > "$combined_file"
  if grep -Eiq 'E404|404 Not Found|not found' "$combined_file"; then
    : > "$versions_file"
    return 10
  fi

  return 1
}

append_remote_info() {
  local package_name="$1"
  local versions_file="$2"
  local not_found="$3"
  local query_ok="$4"
  local error="$5"
  local skipped="$6"
  local latest_protected="$7"
  local versions_json="${versions_file}.json"

  jq -R -s 'split("\n") | map(select(length > 0))' "$versions_file" > "$versions_json"
  jq -c -n \
    --arg package "$package_name" \
    --slurpfile versions "$versions_json" \
    --argjson notFound "$(json_bool "$not_found")" \
    --argjson queryOk "$(json_bool "$query_ok")" \
    --arg error "$error" \
    --argjson skipped "$(json_bool "$skipped")" \
    --argjson latestProtected "$(json_bool "$latest_protected")" \
    '{
      package: $package,
      versions: $versions[0],
      notFound: $notFound,
      queryOk: $queryOk,
      error: $error,
      skipped: $skipped,
      latestProtected: $latestProtected
    }' >> "$REMOTE_JSONL"
}

build_tag_plan() {
  local package_name
  local index=0

  cut -f1 "$SORTED_PACKAGES_TSV" | uniq | while IFS= read -r package_name; do
    index=$((index + 1))
    local incoming_versions="${WORK_DIR}/incoming-${index}.txt"
    local remote_versions="${WORK_DIR}/remote-${index}.txt"
    local remote_error="${WORK_DIR}/remote-${index}.err"
    local remote_query_ok="true"
    local remote_error_text=""
    local remote_not_found="false"
    local remote_skipped="false"
    local latest_protected="false"

    awk -F '\t' -v package="$package_name" '$1 == package { print $2 }' "$SORTED_PACKAGES_TSV" > "$incoming_versions"
    : > "$remote_versions"
    : > "$remote_error"

    if [[ "$LATEST_POLICY" == "computed" ]]; then
      log "Querying target registry versions for ${package_name}"
      if npm_view_versions "$package_name" "$remote_versions" "$remote_error"; then
        :
      else
        local rc=$?
        if [[ "$rc" -eq 10 ]]; then
          remote_not_found="true"
          remote_query_ok="true"
          : > "$remote_error"
        else
          remote_query_ok="false"
          remote_error_text="$(cat "$remote_error" | one_line)"
          if [[ "$FAIL_ON_REMOTE_QUERY_ERROR" == "true" ]]; then
            fail "Could not query target registry versions for ${package_name}. Use --latest-policy never to avoid latest tags, or fix the registry query. ${remote_error_text}"
          fi
          latest_protected="true"
          append_remote_info "$package_name" "$remote_versions" "false" "false" "$remote_error_text" "false" "true"
          while IFS= read -r version; do
            [[ -n "$version" ]] || continue
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
              "$package_name" "$version" "$(mirror_tag_for_version "$version")" \
              "remote-query-failed-avoid-latest" "" "0" "false" "false" "$remote_error_text" >> "$PLAN_TSV"
          done < "$incoming_versions"
          continue
        fi
      fi
    else
      remote_skipped="true"
    fi

    append_remote_info "$package_name" "$remote_versions" "$remote_not_found" "$remote_query_ok" "" "$remote_skipped" "$latest_protected"

    local highest=""
    if [[ "$LATEST_POLICY" == "force-computed" ]]; then
      highest="$(highest_stable_from_files "$incoming_versions")"
    elif [[ "$LATEST_POLICY" == "never" ]]; then
      highest="$(highest_stable_from_files "$incoming_versions" "$remote_versions")"
    else
      highest="$(highest_stable_from_files "$incoming_versions" "$remote_versions")"
    fi

    local remote_count
    remote_count="$(wc -l < "$remote_versions" | tr -d ' ')"

    while IFS= read -r version; do
      [[ -n "$version" ]] || continue
      local dist_tag
      local latest_reason
      local remote_has_newer_stable="false"

      dist_tag="$(mirror_tag_for_version "$version")"
      latest_reason="non-latest-version"

      if is_prerelease "$version"; then
        latest_reason="prerelease"
      elif [[ "$LATEST_POLICY" == "never" ]]; then
        latest_reason="latest-policy-never"
      elif [[ -n "$highest" && "$version" == "$highest" ]]; then
        dist_tag="latest"
        if [[ "$LATEST_POLICY" == "computed" ]]; then
          latest_reason="highest-stable-across-registry-and-bundle"
        else
          latest_reason="highest-stable-in-bundle"
        fi
      elif [[ -n "$highest" ]]; then
        latest_reason="highest-stable-is-${highest}"
      fi

      if [[ -n "$highest" ]] && semver_greater "$highest" "$version"; then
        remote_has_newer_stable="true"
      fi

      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$package_name" "$version" "$dist_tag" "$latest_reason" "$highest" \
        "$remote_count" "$remote_has_newer_stable" "true" "" >> "$PLAN_TSV"
    done < "$incoming_versions"
  done
}

build_tag_plan

publish_package() {
  local name="$1"
  local version="$2"
  local tarball_path="$3"
  local tag="$4"
  local attempts=0
  local max_attempts=$((PUBLISH_RETRIES + 1))
  local output_file
  local output_text
  local rc

  while [[ "$attempts" -lt "$max_attempts" ]]; do
    attempts=$((attempts + 1))
    output_file="${WORK_DIR}/publish-${attempts}.out"
    local publish_args=(publish "$tarball_path" "${NPM_CONFIG_ARGS[@]}" --tag "$tag" --ignore-scripts)
    if [[ -n "$NPM_FLAGS" ]]; then
      # shellcheck disable=SC2206
      local extra_flags=( $NPM_FLAGS )
      publish_args+=("${extra_flags[@]}")
    fi

    if "$NPM_BIN" "${publish_args[@]}" > "$output_file" 2>&1; then
      cat >> "$PUBLISH_LOG" <<EOF
[attempt ${attempts}] ${name}@${version} tag=${tag}
$(cat "$output_file")

EOF
      PUBLISH_STATUS="published"
      PUBLISH_ATTEMPTS="$attempts"
      PUBLISH_OUTPUT="$(cat "$output_file" | one_line)"
      return 0
    fi

    rc=$?
    output_text="$(cat "$output_file")"
    cat >> "$PUBLISH_LOG" <<EOF
[attempt ${attempts}] ${name}@${version} tag=${tag}
${output_text}

EOF

    if [[ "$SKIP_EXISTING" == "true" ]] && printf '%s\n' "$output_text" | grep -Eiq 'EPUBLISHCONFLICT|already exists|already present|cannot publish over|409|conflict'; then
      PUBLISH_STATUS="skipped-existing"
      PUBLISH_ATTEMPTS="$attempts"
      PUBLISH_OUTPUT="$(printf '%s\n' "$output_text" | one_line)"
      return 0
    fi

    if [[ "$attempts" -lt "$max_attempts" ]]; then
      sleep_ms "$RETRY_DELAY_MS"
    fi
  done

  PUBLISH_STATUS="failed"
  PUBLISH_ATTEMPTS="$attempts"
  PUBLISH_OUTPUT="$(printf '%s\n' "$output_text" | one_line)"
  return "$rc"
}

append_result() {
  local package_name="$1"
  local version="$2"
  local package_ref="$3"
  local tarball="$4"
  local dist_tag="$5"
  local latest_reason="$6"
  local highest_stable="$7"
  local remote_has_newer_stable="$8"
  local remote_query_ok="$9"
  local remote_query_error="${10}"
  local status="${11}"
  local publish_attempts="${12}"
  local error="${13}"

  jq -c -n \
    --arg package "$package_name" \
    --arg version "$version" \
    --arg packageRef "$package_ref" \
    --arg tarball "$tarball" \
    --arg distTag "$dist_tag" \
    --arg latestReason "$latest_reason" \
    --arg highestStableVersion "$highest_stable" \
    --argjson remoteHasNewerStable "$(json_bool "$remote_has_newer_stable")" \
    --argjson remoteQueryOk "$(json_bool "$remote_query_ok")" \
    --arg remoteQueryError "$remote_query_error" \
    --arg status "$status" \
    --argjson publishAttempts "$publish_attempts" \
    --arg error "$error" \
    '{
      package: $package,
      version: $version,
      packageRef: $packageRef,
      tarball: $tarball,
      distTag: $distTag,
      latestReason: $latestReason,
      highestStableVersion: $highestStableVersion,
      remoteHasNewerStable: $remoteHasNewerStable,
      remoteQueryOk: $remoteQueryOk,
      remoteQueryError: $remoteQueryError,
      status: $status,
      publishAttempts: $publishAttempts,
      error: $error
    }' >> "$RESULTS_JSONL"
}

PUBLISHED=0
SKIPPED_EXISTING=0
DRY_RUN_COUNT=0
FAILED=0

while IFS=$'\t' read -r name version tarball package_ref; do
  plan_line="$(awk -F '\t' -v package="$name" -v version="$version" '$1 == package && $2 == version { print; exit }' "$PLAN_TSV")"
  [[ -n "$plan_line" ]] || fail "No tag plan found for ${name}@${version}"

  IFS=$'\t' read -r _plan_name _plan_version dist_tag latest_reason highest_stable _remote_count remote_has_newer_stable remote_query_ok remote_query_error <<< "$plan_line"
  tarball_path="${BUNDLE_DIR_RESOLVED}/${tarball}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY_RUN would publish ${name}@${version} with dist-tag ${dist_tag}"
    DRY_RUN_COUNT=$((DRY_RUN_COUNT + 1))
    append_result "$name" "$version" "$package_ref" "$tarball" "$dist_tag" "$latest_reason" "$highest_stable" \
      "$remote_has_newer_stable" "$remote_query_ok" "$remote_query_error" "dry-run" "0" ""
    continue
  fi

  log "Publishing ${name}@${version} with dist-tag ${dist_tag}"
  if publish_package "$name" "$version" "$tarball_path" "$dist_tag"; then
    if [[ "$PUBLISH_STATUS" == "published" ]]; then
      PUBLISHED=$((PUBLISHED + 1))
    elif [[ "$PUBLISH_STATUS" == "skipped-existing" ]]; then
      SKIPPED_EXISTING=$((SKIPPED_EXISTING + 1))
    fi
  else
    FAILED=$((FAILED + 1))
  fi

  local_error=""
  if [[ "$PUBLISH_STATUS" == "failed" ]]; then
    local_error="$PUBLISH_OUTPUT"
  fi
  append_result "$name" "$version" "$package_ref" "$tarball" "$dist_tag" "$latest_reason" "$highest_stable" \
    "$remote_has_newer_stable" "$remote_query_ok" "$remote_query_error" "$PUBLISH_STATUS" "$PUBLISH_ATTEMPTS" "$local_error"
done < "$SORTED_PACKAGES_TSV"

jq -s '.' "$RESULTS_JSONL" > "$RESULTS_JSON"
if [[ -s "$REMOTE_JSONL" ]]; then
  jq -s 'map({(.package): del(.package)}) | add // {}' "$REMOTE_JSONL" > "$REMOTE_JSON"
else
  printf '{}\n' > "$REMOTE_JSON"
fi

jq -n \
  --arg registryUrl "$REGISTRY_URL" \
  --argjson strictSsl "$(json_bool "$STRICT_SSL")" \
  --arg latestPolicy "$LATEST_POLICY" \
  --argjson skipExisting "$(json_bool "$SKIP_EXISTING")" \
  --argjson failOnRemoteQueryError "$(json_bool "$FAIL_ON_REMOTE_QUERY_ERROR")" \
  --argjson publishRetries "$PUBLISH_RETRIES" \
  --arg bundleDir "$BUNDLE_DIR_RESOLVED" \
  --arg manifestFile "$MANIFEST_FILE" \
  --arg workDir "$WORK_DIR" \
  --arg resultsFile "$RESULTS_JSON" \
  --arg publishLog "$PUBLISH_LOG" \
  --argjson packageCount "$(wc -l < "$SORTED_PACKAGES_TSV" | tr -d ' ')" \
  --argjson published "$PUBLISHED" \
  --argjson skippedExisting "$SKIPPED_EXISTING" \
  --argjson dryRun "$DRY_RUN_COUNT" \
  --argjson failed "$FAILED" \
  --slurpfile remoteByPackage "$REMOTE_JSON" \
  --slurpfile results "$RESULTS_JSON" \
  '{
    registryUrl: $registryUrl,
    strictSsl: $strictSsl,
    latestPolicy: $latestPolicy,
    skipExisting: $skipExisting,
    failOnRemoteQueryError: $failOnRemoteQueryError,
    publishRetries: $publishRetries,
    bundleDir: $bundleDir,
    manifestFile: $manifestFile,
    workDir: $workDir,
    resultsFile: $resultsFile,
    publishLog: $publishLog,
    packageCount: $packageCount,
    published: $published,
    skippedExisting: $skippedExisting,
    dryRun: $dryRun,
    failed: $failed,
    remoteByPackage: $remoteByPackage[0],
    results: $results[0]
  }' | tee "$SUMMARY_JSON"

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
