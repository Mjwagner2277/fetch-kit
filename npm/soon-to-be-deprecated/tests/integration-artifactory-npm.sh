#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Run an npm publish/install integration test against an Artifactory npm repo.

Required environment variables:
  ARTIFACTORY_URL               Base Artifactory URL, for example http://localhost:8082/artifactory

Authentication, choose one:
  ARTIFACTORY_TOKEN             Artifactory token
  ARTIFACTORY_USERNAME          Artifactory username
  ARTIFACTORY_PASSWORD          Artifactory password/API key/token

Optional environment variables:
  ARTIFACTORY_NPM_REPO          Repo key to create/use. Defaults to npm-local-test.
  WORK_DIR                      Test work directory.
  KEEP_WORK_DIR                 true to keep WORK_DIR after the test.

The test:
  1. Creates a local npm repository if possible.
  2. Builds three local npm tarballs out of order: old, stable, beta.
  3. Uploads them with upload-npm-tarballs-to-artifactory.sh.
  4. Verifies only the highest stable version gets latest.
  5. Generates package-lock.json from Artifactory and runs npm ci from it.

Exit code 77 means the target Artifactory does not support npm repositories,
which is expected for OSS-only instances.
USAGE
}

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

skip() {
  log "SKIP: $*"
  exit 77
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

write_npmrc() {
  local npmrc="$1"
  local registry="$2"
  local fragment
  fragment="$(registry_auth_fragment "$registry")"

  {
    printf 'registry=%s\n' "$registry"
    printf '%s:always-auth=true\n' "$fragment"
    if [[ -n "${ARTIFACTORY_TOKEN:-}" ]]; then
      printf '%s:_authToken=%s\n' "$fragment" "$ARTIFACTORY_TOKEN"
    else
      printf '%s:username=%s\n' "$fragment" "$ARTIFACTORY_USERNAME"
      printf '%s:_password=%s\n' "$fragment" "$(base64_one_line "$ARTIFACTORY_PASSWORD")"
      printf '%s:email=fetch-kit-artifactory-test@example.invalid\n' "$fragment"
    fi
  } >"$npmrc"
}

create_npm_repo() {
  local repo_key="$1"
  local config_file="$2"
  local response_file="$3"
  local status_file="$4"

  cat >"$config_file" <<JSON
{
  "rclass": "local",
  "packageType": "npm",
  "description": "fetch-kit npm integration test"
}
JSON

  if [[ -n "${ARTIFACTORY_TOKEN:-}" ]]; then
    curl -sS -o "$response_file" -w '%{http_code}' \
      -H "Authorization: Bearer ${ARTIFACTORY_TOKEN}" \
      -H 'Content-Type: application/json' \
      -X PUT \
      --data-binary "@$config_file" \
      "${ARTIFACTORY_URL%/}/api/repositories/${repo_key}" >"$status_file"
  else
    curl -sS -o "$response_file" -w '%{http_code}' \
      -u "${ARTIFACTORY_USERNAME}:${ARTIFACTORY_PASSWORD}" \
      -H 'Content-Type: application/json' \
      -X PUT \
      --data-binary "@$config_file" \
      "${ARTIFACTORY_URL%/}/api/repositories/${repo_key}" >"$status_file"
  fi

  status="$(cat "$status_file")"
  case "$status" in
    200|201) return 0 ;;
    400)
      if grep -qi 'available only in Artifactory Pro' "$response_file"; then
        skip "npm repositories are not available on this Artifactory edition"
      fi
      ;;
    409)
      return 0
      ;;
  esac

  if grep -qi 'already exists' "$response_file"; then
    return 0
  fi

  sed 's/^/[artifactory] /' "$response_file" >&2
  fail "Failed to create npm repo ${repo_key}; HTTP ${status}"
}

build_fixture_package() {
  local package_name="$1"
  local package_version="$2"
  local package_dir="$3"
  local pack_dir="$4"

  mkdir -p "$package_dir"
  cat >"${package_dir}/package.json" <<JSON
{
  "name": "${package_name}",
  "version": "${package_version}",
  "description": "fetch-kit Artifactory npm integration fixture",
  "main": "index.js",
  "license": "UNLICENSED"
}
JSON
  printf 'module.exports = "%s@%s";\n' "$package_name" "$package_version" >"${package_dir}/index.js"

  (cd "$package_dir" && npm pack --pack-destination "$pack_dir" --ignore-scripts >/dev/null)
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

need_command base64
need_command curl
need_command jq
need_command npm

[[ -n "${ARTIFACTORY_URL:-}" ]] || fail "Set ARTIFACTORY_URL"
if [[ -z "${ARTIFACTORY_TOKEN:-}" && ( -z "${ARTIFACTORY_USERNAME:-}" || -z "${ARTIFACTORY_PASSWORD:-}" ) ]]; then
  fail "Set ARTIFACTORY_TOKEN or ARTIFACTORY_USERNAME plus ARTIFACTORY_PASSWORD"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NPM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
UPLOAD_SCRIPT="${NPM_DIR}/upload-npm-tarballs-to-artifactory.sh"
[[ -x "$UPLOAD_SCRIPT" ]] || fail "Upload script not executable: $UPLOAD_SCRIPT"

REPO_KEY="${ARTIFACTORY_NPM_REPO:-npm-local-test}"
REGISTRY_URL="${ARTIFACTORY_URL%/}/api/npm/${REPO_KEY}/"

if [[ -z "${WORK_DIR:-}" ]]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fetch-kit-artifactory-npm.XXXXXX")"
else
  mkdir -p "$WORK_DIR"
fi

if [[ "${KEEP_WORK_DIR:-false}" != "true" ]]; then
  trap 'rm -rf "$WORK_DIR"' EXIT
else
  log "Keeping work directory: $WORK_DIR"
fi

create_npm_repo "$REPO_KEY" "${WORK_DIR}/repo.json" "${WORK_DIR}/repo-create-response.json" "${WORK_DIR}/repo-create-status.txt"

run_id="$(date -u '+%Y%m%d%H%M%S')"
package_name="fetch-kit-artifactory-fixture-${run_id}"
pack_dir="${WORK_DIR}/tarballs"
mkdir -p "$pack_dir"

build_fixture_package "$package_name" "2.1.0-beta.1" "${WORK_DIR}/src-beta" "$pack_dir"
build_fixture_package "$package_name" "1.0.0" "${WORK_DIR}/src-old" "$pack_dir"
build_fixture_package "$package_name" "2.0.0" "${WORK_DIR}/src-stable" "$pack_dir"

manifest="${WORK_DIR}/manifest.tsv"
cat >"$manifest" <<EOF
${package_name}	2.1.0-beta.1	$(find "$pack_dir" -name "${package_name}-2.1.0-beta.1.tgz" -print -quit)
${package_name}	1.0.0	$(find "$pack_dir" -name "${package_name}-1.0.0.tgz" -print -quit)
${package_name}	2.0.0	$(find "$pack_dir" -name "${package_name}-2.0.0.tgz" -print -quit)
EOF

upload_args=(
  "$UPLOAD_SCRIPT"
  --manifest "$manifest"
  --registry-url "$REGISTRY_URL"
  --work-dir "${WORK_DIR}/upload"
  --skip-existing
)
if [[ -n "${ARTIFACTORY_TOKEN:-}" ]]; then
  upload_args+=(--token "$ARTIFACTORY_TOKEN")
else
  upload_args+=(--username "$ARTIFACTORY_USERNAME" --password "$ARTIFACTORY_PASSWORD")
fi

"${upload_args[@]}" >"${WORK_DIR}/upload-summary.json"

jq -e --arg package "$package_name" '
  [.results[] | select(.package == $package) | {version, dist_tag}] as $rows |
  ($rows | map(select(.version == "1.0.0" and .dist_tag == "gitlab-mirror-1-0-0")) | length == 1) and
  ($rows | map(select(.version == "2.0.0" and .dist_tag == "latest")) | length == 1) and
  ($rows | map(select(.version == "2.1.0-beta.1" and .dist_tag == "gitlab-mirror-2-1-0-beta-1")) | length == 1)
' "${WORK_DIR}/upload-summary.json" >/dev/null || fail "Uploader selected unexpected dist-tags"

npmrc="${WORK_DIR}/npmrc"
write_npmrc "$npmrc" "$REGISTRY_URL"

dist_tags="$(npm view "$package_name" dist-tags --json --registry "$REGISTRY_URL" --userconfig "$npmrc")"
printf '%s\n' "$dist_tags" >"${WORK_DIR}/dist-tags.json"
jq -e '.latest == "2.0.0" and ."gitlab-mirror-1-0-0" == "1.0.0" and ."gitlab-mirror-2-1-0-beta-1" == "2.1.0-beta.1"' \
  "${WORK_DIR}/dist-tags.json" >/dev/null || fail "Artifactory dist-tags did not match expected upload tags"

consumer_dir="${WORK_DIR}/consumer"
mkdir -p "$consumer_dir"
cat >"${consumer_dir}/package.json" <<JSON
{
  "name": "fetch-kit-artifactory-consumer-${run_id}",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "${package_name}": "1.0.0"
  }
}
JSON

(cd "$consumer_dir" && npm install --package-lock-only --ignore-scripts --registry "$REGISTRY_URL" --userconfig "$npmrc" >/dev/null)
rm -rf "${consumer_dir}/node_modules"
(cd "$consumer_dir" && npm ci --ignore-scripts --registry "$REGISTRY_URL" --userconfig "$npmrc" >/dev/null)

installed_version="$(jq -r '.version' "${consumer_dir}/node_modules/${package_name}/package.json")"
[[ "$installed_version" == "1.0.0" ]] || fail "Expected npm ci to install 1.0.0 from lockfile, got ${installed_version}"

jq -n \
  --arg registry_url "$REGISTRY_URL" \
  --arg package "$package_name" \
  --arg installed_version "$installed_version" \
  --arg work_dir "$WORK_DIR" \
  '{status:"ok", registry_url:$registry_url, package:$package,
    installed_version:$installed_version, work_dir:$work_dir}'
