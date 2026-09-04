#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NPM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/npm-normalize-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

MANIFEST="${TMP_DIR}/manifest.tsv"
WORK_DIR="${TMP_DIR}/work"
FAKE_NPM="${TMP_DIR}/npm"
FAKE_NPM_LOG="${TMP_DIR}/npm.log"
SOURCE_DIR="${TMP_DIR}/source"
PACKAGE_DIR="${SOURCE_DIR}/package"
SOURCE_TARBALL="${TMP_DIR}/scope-library-1.0.0.tgz"

mkdir -p "$PACKAGE_DIR"
cat >"${PACKAGE_DIR}/package.json" <<'EOF'
{
  "name": "@scope/library",
  "version": "1.0.0",
  "main": "index.js",
  "types": "index.d.ts",
  "exports": {
    ".": "./index.js"
  },
  "scripts": {
    "prepare": "npm run build",
    "build": "tsc",
    "test": "node test.js",
    "postinstall": "node scripts/postinstall.js"
  },
  "dependencies": {
    "runtime-dep": "^1.0.0"
  },
  "peerDependencies": {
    "react": "^18.0.0"
  },
  "devDependencies": {
    "typescript": "^5.0.0"
  }
}
EOF
printf 'module.exports = { value: 1 };\n' >"${PACKAGE_DIR}/index.js"
printf 'export declare const value: number;\n' >"${PACKAGE_DIR}/index.d.ts"
tar -czf "$SOURCE_TARBALL" -C "$SOURCE_DIR" package

cat >"$MANIFEST" <<EOF
@scope/library	1.0.0	${SOURCE_TARBALL}
EOF

cat >"$FAKE_NPM" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_NPM_LOG:?}"
exit 0
EOF
chmod +x "$FAKE_NPM"

FAKE_NPM_LOG="$FAKE_NPM_LOG" "${NPM_DIR}/upload-npm-tarballs-to-artifactory.sh" \
  --manifest "$MANIFEST" \
  --registry-url "https://art.example.com/artifactory/api/npm/npm-local/" \
  --work-dir "$WORK_DIR" \
  --token "test-token" \
  --npm-bin "$FAKE_NPM" >/dev/null

published_tarball="$(awk '$1 == "publish" { print $2; exit }' "$FAKE_NPM_LOG")"
[[ -n "$published_tarball" ]] || fail "Fake npm did not receive a tarball"
[[ "$published_tarball" != "$SOURCE_TARBALL" ]] || fail "Uploader published the unnormalized tarball"
[[ -f "$published_tarball" ]] || fail "Normalized tarball not found: $published_tarball"

INSPECT_DIR="${TMP_DIR}/inspect"
mkdir -p "$INSPECT_DIR"
tar -xzf "$published_tarball" -C "$INSPECT_DIR"

jq -e '
  .name == "@scope/library" and
  .version == "1.0.0" and
  .main == "index.js" and
  .types == "index.d.ts" and
  .exports["."] == "./index.js" and
  .dependencies["runtime-dep"] == "^1.0.0" and
  .peerDependencies.react == "^18.0.0" and
  ((has("scripts") | not) and (has("devDependencies") | not))
' "${INSPECT_DIR}/package/package.json" >/dev/null ||
  fail "Normalized package.json did not keep library fields and remove build metadata"

jq -e '
  .normalize_library_package == true and
  .results[0].normalized == true and
  .results[0].source_tarball != .results[0].tarball
' "${WORK_DIR}/upload-summary.json" >/dev/null ||
  fail "Upload summary did not record normalization"

printf 'upload npm tarball library normalization: ok\n'
