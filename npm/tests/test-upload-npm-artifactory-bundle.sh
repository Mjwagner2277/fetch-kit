#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
uploader="${repo_root}/npm/upload-npm-artifactory-bundle.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/npm-upload-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

assert_jq() {
  local json="$1"
  local expression="$2"
  printf '%s\n' "$json" | jq -e "$expression" >/dev/null || fail "jq assertion failed: $expression"
}

tag_for() {
  local json="$1"
  local package="$2"
  local version="$3"
  printf '%s\n' "$json" \
    | jq -r --arg package "$package" --arg version "$version" \
      '.results[] | select(.package == $package and .version == $version) | .distTag'
}

write_package_tarball() {
  local package="$1"
  local version="$2"
  local output="$3"
  local safe_name="${package#@}"
  safe_name="${safe_name//\//-}"
  local package_root="${tmp}/pkg-${safe_name}-${version}"
  local package_dir="${package_root}/package"
  rm -rf "$package_root"
  mkdir -p "$package_dir"
  jq -n \
    --arg name "$package" \
    --arg version "$version" \
    '{name: $name, version: $version, main: "index.js"}' > "${package_dir}/package.json"
  printf 'module.exports = { value: 1 };\n' > "${package_dir}/index.js"
  tar -czf "$output" -C "$package_root" package
  rm -rf "$package_root"
}

make_bundle() {
  local name="$1"
  shift
  local bundle_dir="${tmp}/${name}"
  local tarball_dir="${bundle_dir}/tarballs"
  local manifest="${bundle_dir}/packages.jsonl"
  mkdir -p "$tarball_dir"
  : > "$manifest"

  while [[ $# -gt 0 ]]; do
    local package="$1"
    local version="$2"
    shift 2
    local safe_name="${package#@}"
    safe_name="${safe_name//\//-}"
    local tarball="tarballs/${safe_name}-${version}.tgz"
    write_package_tarball "$package" "$version" "${bundle_dir}/${tarball}"
    jq -c -n \
      --arg name "$package" \
      --arg version "$version" \
      --arg tarball "$tarball" \
      '{name: $name, version: $version, package: ($name + "@" + $version), tarball: $tarball}' >> "$manifest"
  done

  tar -cf "${tmp}/${name}.tar" -C "$tmp" "$name"
  printf '%s\n' "${tmp}/${name}.tar"
}

fake_npm="${tmp}/fake-npm.js"
cat > "$fake_npm" <<'JS'
#!/usr/bin/env node
'use strict';
const fs = require('fs');
const logFile = process.env.FAKE_NPM_LOG;
const args = process.argv.slice(2);
fs.appendFileSync(logFile, `${JSON.stringify(args)}\n`);

if (args[0] === 'view') {
  const name = args[1];
  if (name === 'ahead-pkg') {
    process.stdout.write(JSON.stringify(['3.0.0']));
    process.exit(0);
  }
  if (name === 'new-pkg') {
    process.stderr.write('npm ERR! code E404\n');
    process.exit(1);
  }
  if (name === 'same-pkg') {
    process.stdout.write(JSON.stringify(['1.0.0']));
    process.exit(0);
  }
  if (name === 'query-fail-pkg') {
    process.stderr.write('npm ERR! code E500\n');
    process.exit(1);
  }
  process.stdout.write(JSON.stringify([]));
  process.exit(0);
}

if (args[0] === 'publish') {
  const tarball = args[1] || '';
  if (tarball.includes('same-pkg-1.0.0.tgz')) {
    process.stderr.write('npm ERR! code EPUBLISHCONFLICT\nnpm ERR! already exists\n');
    process.exit(1);
  }
  process.stdout.write('+ published\n');
  process.exit(0);
}

process.stderr.write(`unexpected fake npm args: ${args.join(' ')}\n`);
process.exit(1);
JS
chmod +x "$fake_npm"

log_file="${tmp}/npm.log"
: > "$log_file"

main_bundle="$(make_bundle bundle-main \
  ahead-pkg 1.0.0 \
  ahead-pkg 2.0.0 \
  new-pkg 1.0.0 \
  new-pkg 2.0.0-beta.1 \
  new-pkg 2.0.0 \
  query-fail-pkg 1.0.0)"

dry_summary="$(
  FAKE_NPM_LOG="$log_file" bash "$uploader" \
    --bundle-tar "$main_bundle" \
    --registry-url "https://registry.example.invalid/npm/" \
    --token "test-token" \
    --no-ssl \
    --npm-bin "$fake_npm" \
    --work-dir "${tmp}/work-dry-run" \
    --dry-run
)"

[[ "$(tag_for "$dry_summary" ahead-pkg 1.0.0)" == "airgap-1.0.0" ]] || fail "ahead-pkg@1.0.0 tag mismatch"
[[ "$(tag_for "$dry_summary" ahead-pkg 2.0.0)" == "airgap-2.0.0" ]] || fail "ahead-pkg@2.0.0 tag mismatch"
[[ "$(tag_for "$dry_summary" new-pkg 1.0.0)" == "airgap-1.0.0" ]] || fail "new-pkg@1.0.0 tag mismatch"
[[ "$(tag_for "$dry_summary" new-pkg 2.0.0-beta.1)" == "airgap-2.0.0-beta.1" ]] || fail "new-pkg prerelease tag mismatch"
[[ "$(tag_for "$dry_summary" new-pkg 2.0.0)" == "latest" ]] || fail "new-pkg@2.0.0 tag mismatch"
[[ "$(tag_for "$dry_summary" query-fail-pkg 1.0.0)" == "airgap-1.0.0" ]] || fail "query-fail-pkg tag mismatch"
assert_jq "$dry_summary" '.strictSsl == false'
assert_jq "$dry_summary" '.results[] | select(.package == "ahead-pkg" and .version == "2.0.0") | .remoteHasNewerStable == true'
assert_jq "$dry_summary" '.results[] | select(.package == "query-fail-pkg") | .remoteQueryOk == false'
assert_jq "$dry_summary" '.remoteByPackage["query-fail-pkg"].latestProtected == true'
jq -e 'select(.[0] == "view" and any(.[]; . == "--strict-ssl=false"))' "$log_file" >/dev/null \
  || fail "dry run did not pass --strict-ssl=false to npm view"

: > "$log_file"
same_bundle="$(make_bundle bundle-same same-pkg 1.0.0)"
publish_summary="$(
  FAKE_NPM_LOG="$log_file" bash "$uploader" \
    --bundle-tar "$same_bundle" \
    --registry-url "https://registry.example.invalid/npm/" \
    --token "test-token" \
    --no-ssl \
    --npm-bin "$fake_npm" \
    --work-dir "${tmp}/work-publish" \
    --skip-existing
)"

assert_jq "$publish_summary" '.strictSsl == false'
assert_jq "$publish_summary" '.skippedExisting == 1'
assert_jq "$publish_summary" '.results[0].status == "skipped-existing"'
assert_jq "$publish_summary" '.results[0].distTag == "latest"'
jq -e 'select(.[0] == "publish" and any(.[]; . == "--strict-ssl=false"))' "$log_file" >/dev/null \
  || fail "publish did not pass --strict-ssl=false to npm publish"

: > "$log_file"
never_summary="$(
  FAKE_NPM_LOG="$log_file" bash "$uploader" \
    --bundle-tar "$main_bundle" \
    --registry-url "https://registry.example.invalid/npm/" \
    --token "test-token" \
    --npm-bin "$fake_npm" \
    --work-dir "${tmp}/work-never" \
    --latest-policy "never" \
    --dry-run
)"

assert_jq "$never_summary" 'all(.results[]; .distTag | startswith("airgap-"))'
if [[ -s "$log_file" ]]; then
  ! jq -e 'select(.[0] == "view")' "$log_file" >/dev/null || fail "--latest-policy never queried remote versions"
fi

printf 'upload npm bundle: ok\n'
