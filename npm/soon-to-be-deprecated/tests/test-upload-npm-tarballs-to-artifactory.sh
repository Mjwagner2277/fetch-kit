#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NPM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/npm-upload-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

MANIFEST="${TMP_DIR}/manifest.tsv"
WORK_DIR="${TMP_DIR}/work"
FAKE_NPM="${TMP_DIR}/npm"
FAKE_NPM_LOG="${TMP_DIR}/npm.log"

touch \
  "${TMP_DIR}/pkg-1.0.0.tgz" \
  "${TMP_DIR}/pkg-2.0.0.tgz" \
  "${TMP_DIR}/pkg-2.1.0-beta.1.tgz" \
  "${TMP_DIR}/beta-only-1.0.0-beta.1.tgz"

cat >"$MANIFEST" <<EOF
@scope/pkg	2.1.0-beta.1	${TMP_DIR}/pkg-2.1.0-beta.1.tgz
@scope/pkg	1.0.0	${TMP_DIR}/pkg-1.0.0.tgz
@scope/pkg	2.0.0	${TMP_DIR}/pkg-2.0.0.tgz
beta-only	1.0.0-beta.1	${TMP_DIR}/beta-only-1.0.0-beta.1.tgz
EOF

cat >"$FAKE_NPM" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_NPM_LOG:?}"
exit 0
EOF
chmod +x "$FAKE_NPM"

"${NPM_DIR}/upload-npm-tarballs-to-artifactory.sh" \
  --manifest "$MANIFEST" \
  --registry-url "https://art.example.com/artifactory/api/npm/npm-local/" \
  --work-dir "$WORK_DIR" \
  --no-normalize-library-package \
  --dry-run >/dev/null

jq -e '
  def tag_for($package; $version):
    .results[] | select(.package == $package and .version == $version) | .dist_tag;
  (tag_for("@scope/pkg"; "1.0.0") == "gitlab-mirror-1-0-0") and
  (tag_for("@scope/pkg"; "2.0.0") == "latest") and
  (tag_for("@scope/pkg"; "2.1.0-beta.1") == "gitlab-mirror-2-1-0-beta-1") and
  (tag_for("beta-only"; "1.0.0-beta.1") == "gitlab-mirror-1-0-0-beta-1")
' "${WORK_DIR}/upload-summary.json" >/dev/null || fail "Unexpected dry-run dist-tag plan"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
: >"$FAKE_NPM_LOG"

FAKE_NPM_LOG="$FAKE_NPM_LOG" "${NPM_DIR}/upload-npm-tarballs-to-artifactory.sh" \
  --manifest "$MANIFEST" \
  --registry-url "https://art.example.com/artifactory/api/npm/npm-local/" \
  --work-dir "$WORK_DIR" \
  --token "test-token" \
  --no-normalize-library-package \
  --npm-bin "$FAKE_NPM" >/dev/null

latest_count="$(grep -c -- '--tag latest' "$FAKE_NPM_LOG")"
[[ "$latest_count" == "1" ]] || fail "Expected exactly one latest publish, got ${latest_count}"

grep -q -- 'pkg-2.0.0.tgz --registry .* --tag latest' "$FAKE_NPM_LOG" ||
  fail "Expected stable 2.0.0 to publish with latest"
grep -q -- 'pkg-2.1.0-beta.1.tgz --registry .* --tag gitlab-mirror-2-1-0-beta-1' "$FAKE_NPM_LOG" ||
  fail "Expected beta version to avoid latest"
grep -q -- 'beta-only-1.0.0-beta.1.tgz --registry .* --tag gitlab-mirror-1-0-0-beta-1' "$FAKE_NPM_LOG" ||
  fail "Expected beta-only package to avoid latest"

printf 'upload npm tarball tag behavior: ok\n'
