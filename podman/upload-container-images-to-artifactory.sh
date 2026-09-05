#!/usr/bin/env bash
# Upload a Get-ContainerImage.py OCI transfer bundle to Artifactory.
# Runtime dependencies: Bash, curl, jq, tar, sha256sum or shasum, and standard Unix utilities.
set -Eeuo pipefail

prog="${0##*/}"
bundle_tar=""
bundle_dir_input=""
registry_url=""
repository=""
target_prefix=""
token="${ARTIFACTORY_TOKEN:-}"
api_key="${ARTIFACTORY_API_KEY:-}"
username="${ARTIFACTORY_USERNAME:-${ARTIFACTORY_USER:-}}"
password="${ARTIFACTORY_PASSWORD:-}"
skip_existing=0
dry_run=0
allow_incomplete=0
insecure=0
retries=3
retry_delay=1
summary_output=""
keep_work_dir=0
temporary_dir=""

usage() {
  cat <<USAGE
Upload an OCI image transfer bundle to an Artifactory Docker repository.

Usage:
  $prog (--bundle-tar FILE | --bundle-dir DIR) \\
    --registry-url URL --repository REPOSITORY [options]

Required:
  --bundle-tar FILE       Transfer archive from Get-ContainerImage.py.
  --bundle-dir DIR        Already extracted bundle; alternative to --bundle-tar.
  --registry-url URL      Registry-facing Artifactory URL, including scheme.
  --repository NAME       Artifactory local Docker repository key.

Authentication, choose one:
  --token TOKEN           Bearer token; defaults to ARTIFACTORY_TOKEN.
  --api-key KEY           X-JFrog-Art-Api value; defaults to ARTIFACTORY_API_KEY.
  --username USER         Basic auth user; defaults to ARTIFACTORY_USERNAME or ARTIFACTORY_USER.
  --password PASSWORD     Basic auth password/token; defaults to ARTIFACTORY_PASSWORD.

Options:
  --target-prefix PATH    Optional path below the Artifactory repository key.
  --skip-existing        Do not replace an existing destination tag.
  --dry-run              Verify the bundle and print the upload plan without network calls.
  --allow-incomplete     Testing only: accept a bundle created with --skip-layers.
  --insecure             Disable TLS certificate verification for Artifactory.
  --retries N            curl retry count. Default: $retries.
  --retry-delay N        Seconds between curl retries. Default: $retry_delay.
  --summary-output FILE  Also write the JSON result to this file.
  --keep-work-dir        Keep files extracted from --bundle-tar for inspection.
  -h, --help             Show this help.

The receiving host needs Bash, curl, jq, tar, sha256sum (or shasum), and
standard Unix utilities. Python, Docker, Podman, Skopeo, ORAS, and the JFrog
CLI are not used.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

status() {
  printf '[oci-upload] %s\n' "$*" >&2
}

require_value() {
  [[ $# -ge 2 ]] || die "$1 requires a value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-tar)
      require_value "$@"
      bundle_tar="$2"
      shift 2
      ;;
    --bundle-dir)
      require_value "$@"
      bundle_dir_input="$2"
      shift 2
      ;;
    --registry-url)
      require_value "$@"
      registry_url="$2"
      shift 2
      ;;
    --repository)
      require_value "$@"
      repository="$2"
      shift 2
      ;;
    --target-prefix)
      require_value "$@"
      target_prefix="$2"
      shift 2
      ;;
    --token)
      require_value "$@"
      token="$2"
      shift 2
      ;;
    --api-key)
      require_value "$@"
      api_key="$2"
      shift 2
      ;;
    --username|--user)
      require_value "$@"
      username="$2"
      shift 2
      ;;
    --password)
      require_value "$@"
      password="$2"
      shift 2
      ;;
    --skip-existing)
      skip_existing=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --allow-incomplete)
      allow_incomplete=1
      shift
      ;;
    --insecure)
      insecure=1
      shift
      ;;
    --retries)
      require_value "$@"
      retries="$2"
      shift 2
      ;;
    --retry-delay)
      require_value "$@"
      retry_delay="$2"
      shift 2
      ;;
    --summary-output)
      require_value "$@"
      summary_output="$2"
      shift 2
      ;;
    --keep-work-dir)
      keep_work_dir=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$bundle_tar" || -n "$bundle_dir_input" ]] || die "Set --bundle-tar or --bundle-dir"
[[ -z "$bundle_tar" || -z "$bundle_dir_input" ]] || die "Use only one of --bundle-tar or --bundle-dir"
[[ -n "$registry_url" ]] || die "--registry-url is required"
[[ "$registry_url" == http://* || "$registry_url" == https://* ]] || die "--registry-url must include http:// or https://"
registry_url="${registry_url%/}"
[[ -n "$repository" ]] || die "--repository is required"
[[ "$retries" =~ ^[0-9]+$ ]] || die "--retries must be a non-negative integer"
[[ "$retry_delay" =~ ^[0-9]+$ ]] || die "--retry-delay must be a non-negative integer"
[[ -z "$username" && -z "$password" ]] || [[ -n "$username" && -n "$password" ]] || \
  die "Both --username and --password are required for Basic authentication"
command -v jq >/dev/null 2>&1 || die "jq is required on the receiving host"

cleanup() {
  if [[ -n "$temporary_dir" && -d "$temporary_dir" && "$keep_work_dir" -eq 0 ]]; then
    rm -rf -- "$temporary_dir"
  elif [[ -n "$temporary_dir" && -d "$temporary_dir" ]]; then
    status "kept work directory: $temporary_dir"
  fi
}
trap cleanup EXIT

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-artifactory-upload.XXXXXX")"

validate_repository_path() {
  local value="$1"
  local label="$2"
  local component
  local parts=()
  [[ -n "$value" && "$value" != /* && "$value" != */ ]] || die "$label is not a valid OCI repository path: $value"
  IFS='/' read -r -a parts <<< "$value"
  for component in "${parts[@]}"; do
    [[ "$component" =~ ^[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*$ ]] || \
      die "$label is not a valid lowercase OCI repository path: $value"
  done
}

validate_repository_path "$repository" "--repository"
[[ "$repository" != */* ]] || die "--repository must be one Artifactory repository key, without slashes"
if [[ -n "$target_prefix" ]]; then
  target_prefix="${target_prefix#/}"
  target_prefix="${target_prefix%/}"
  validate_repository_path "$target_prefix" "--target-prefix"
fi

validate_relative_path() {
  local value="$1"
  case "$value" in
    ""|/*|../*|*/../*|*/..)
      die "Unsafe bundle-relative path: $value"
      ;;
  esac
}

validate_archive() {
  local archive="$1"
  local member
  local listing
  tar -tf "$archive" >/dev/null || die "Could not read bundle archive: $archive"
  while IFS= read -r member; do
    validate_relative_path "$member"
  done < <(tar -tf "$archive")
  while IFS= read -r listing; do
    case "${listing:0:1}" in
      l|h|b|c|p)
        die "Bundle archive contains a link or special file"
        ;;
    esac
  done < <(tar -tvf "$archive")
}

locate_bundle() {
  local root="$1"
  local candidate
  local candidates=()
  if [[ -f "$root/bundle-manifest.json" ]]; then
    printf '%s' "$root"
    return
  fi
  while IFS= read -r candidate; do
    candidates+=("${candidate%/bundle-manifest.json}")
  done < <(find "$root" -mindepth 2 -maxdepth 2 -type f -name bundle-manifest.json -print)
  [[ ${#candidates[@]} -eq 1 ]] || die "Could not identify one OCI bundle under $root"
  printf '%s' "${candidates[0]}"
}

if [[ -n "$bundle_tar" ]]; then
  [[ -f "$bundle_tar" ]] || die "Bundle archive not found: $bundle_tar"
  validate_archive "$bundle_tar"
  mkdir -p "$temporary_dir/extract"
  tar -xf "$bundle_tar" -C "$temporary_dir/extract"
  bundle_dir="$(locate_bundle "$temporary_dir/extract")"
else
  [[ -d "$bundle_dir_input" ]] || die "Bundle directory not found: $bundle_dir_input"
  bundle_dir="$(locate_bundle "$bundle_dir_input")"
fi

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    die "sha256sum or shasum is required"
  fi
}

verify_bundle_checksums() {
  local checksum_file="$bundle_dir/SHA256SUMS"
  local line expected relative actual
  local count=0
  [[ -f "$checksum_file" ]] || die "Bundle is missing SHA256SUMS"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    [[ "$line" =~ ^([A-Fa-f0-9]{64})\ \ (.+)$ ]] || die "Invalid SHA256SUMS entry: $line"
    expected="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
    relative="${BASH_REMATCH[2]}"
    validate_relative_path "$relative"
    [[ -f "$bundle_dir/$relative" ]] || die "Bundle file listed in SHA256SUMS is missing: $relative"
    actual="$(sha256_file "$bundle_dir/$relative")"
    [[ "$actual" == "$expected" ]] || die "Bundle checksum mismatch: $relative"
    ((count += 1))
  done < "$checksum_file"
  [[ $count -gt 0 ]] || die "SHA256SUMS does not contain any files"
}

verify_sha256_digest() {
  local path="$1"
  local digest="$2"
  local expected actual
  [[ "$digest" =~ ^sha256:([A-Fa-f0-9]{64})$ ]] || die "Unsupported OCI digest: $digest"
  expected="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
  [[ -f "$path" ]] || return 1
  actual="$(sha256_file "$path")"
  [[ "$actual" == "$expected" ]] || die "OCI digest mismatch for $path"
}

blob_path() {
  local digest="$1"
  [[ "$digest" =~ ^sha256:([A-Fa-f0-9]{64})$ ]] || die "Unsupported OCI digest: $digest"
  printf '%s/blobs/sha256/%s' "$bundle_dir" \
    "$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
}

status "verifying bundle checksums and OCI digests"
verify_bundle_checksums
bundle_manifest="$bundle_dir/bundle-manifest.json"
[[ -f "$bundle_manifest" ]] || die "Bundle is missing bundle-manifest.json"
if ! jq -e '
  .schemaVersion == 1 and
  (.images | type == "array" and length > 0) and
  ([.images[] |
    ((.source | type) == "string" and (.source | length) > 0) and
    ((.registry | type) == "string" and (.registry | length) > 0) and
    ((.repository | type) == "string" and (.repository | length) > 0) and
    ((.sourceTag | type) == "string") and
    ((.targetRepository | type) == "string") and
    ((.targetTag | type) == "string") and
    ((.manifest | type) == "object") and
    ((.manifest.digest | type) == "string" and (.manifest.digest | length) > 0) and
    ((.manifest.mediaType | type) == "string" and (.manifest.mediaType | length) > 0) and
    ((.config | type) == "object") and
    ((.config.digest | type) == "string" and (.config.digest | length) > 0) and
    ((.layers | type) == "array") and
    ([.layers[] | ((.digest | type) == "string" and (.digest | length) > 0)] | all) and
    ((.complete | type) == "boolean")
  ] | all)
' "$bundle_manifest" >/dev/null; then
  die "bundle-manifest.json is invalid or unsupported"
fi

curl_common=(--silent --show-error --retry "$retries" --retry-delay "$retry_delay" --connect-timeout 30)
if [[ "$insecure" -eq 1 ]]; then
  curl_common+=(--insecure)
fi
curl_auth=()
if [[ -n "$token" ]]; then
  curl_auth=(-H "Authorization: Bearer $token")
elif [[ -n "$api_key" ]]; then
  curl_auth=(-H "X-JFrog-Art-Api: $api_key")
elif [[ -n "$username" ]]; then
  curl_auth=(-u "$username:$password")
fi

registry_component() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="${value//\[/}"
  value="${value//\]/}"
  value="${value//:/-}"
  [[ "$value" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "Invalid source registry in upload manifest: $1"
  printf '%s' "$value"
}

head_exists() {
  local kind="$1"
  local distribution_repository="$2"
  local reference="$3"
  local url="$registry_url/v2/$distribution_repository/$kind/$reference"
  local code
  if ! code="$(curl "${curl_common[@]}" "${curl_auth[@]}" --head --output /dev/null --write-out '%{http_code}' "$url")"; then
    die "Could not query Artifactory: $url"
  fi
  case "$code" in
    200|307)
      return 0
      ;;
    404)
      return 1
      ;;
    401|403)
      die "Artifactory authentication or authorization failed for $url (HTTP $code)"
      ;;
    *)
      die "Unexpected HTTP $code from $url"
      ;;
  esac
}

resolve_location() {
  local request_url="$1"
  local location="$2"
  local rest authority origin
  case "$location" in
    http://*|https://*)
      printf '%s' "$location"
      ;;
    //*)
      printf '%s:%s' "${registry_url%%:*}" "$location"
      ;;
    /*)
      rest="${registry_url#*://}"
      authority="${rest%%/*}"
      origin="${registry_url%%://*}://$authority"
      printf '%s%s' "$origin" "$location"
      ;;
    *)
      printf '%s/%s' "${request_url%/*}" "$location"
      ;;
  esac
}

upload_blob() {
  local distribution_repository="$1"
  local digest="$2"
  local path="$3"
  local start_url="$registry_url/v2/$distribution_repository/blobs/uploads/"
  local headers_file="$temporary_dir/response-headers"
  local code location upload_url separator
  : > "$headers_file"
  if ! code="$(curl "${curl_common[@]}" "${curl_auth[@]}" \
    --request POST --data-binary '' --dump-header "$headers_file" \
    --output /dev/null --write-out '%{http_code}' "$start_url")"; then
    die "Could not start blob upload for $distribution_repository"
  fi
  [[ "$code" == 202 || "$code" == 201 ]] || die "Artifactory returned HTTP $code when starting blob upload"
  location="$(awk 'tolower($1) == "location:" {$1=""; sub(/^ /, ""); gsub(/\r/, ""); value=$0} END {print value}' "$headers_file")"
  [[ -n "$location" ]] || die "Artifactory blob upload response did not include Location"
  upload_url="$(resolve_location "$start_url" "$location")"
  separator='?'
  [[ "$upload_url" == *\?* ]] && separator='&'
  upload_url="${upload_url}${separator}digest=${digest}"

  status "uploading blob $digest ($(wc -c < "$path" | tr -d ' ') bytes)"
  if ! code="$(curl "${curl_common[@]}" "${curl_auth[@]}" \
    --request PUT --header 'Content-Type: application/octet-stream' \
    --upload-file "$path" --output /dev/null --write-out '%{http_code}' "$upload_url")"; then
    die "Could not upload blob $digest"
  fi
  [[ "$code" == 201 || "$code" == 202 ]] || die "Artifactory returned HTTP $code while uploading $digest"
}

publish_manifest() {
  local distribution_repository="$1"
  local tag="$2"
  local media_type="$3"
  local path="$4"
  local url="$registry_url/v2/$distribution_repository/manifests/$tag"
  local code
  status "publishing manifest $distribution_repository:$tag"
  if ! code="$(curl "${curl_common[@]}" "${curl_auth[@]}" \
    --request PUT --header "Content-Type: $media_type" \
    --upload-file "$path" --output /dev/null --write-out '%{http_code}' "$url")"; then
    die "Could not publish manifest $distribution_repository:$tag"
  fi
  [[ "$code" == 201 || "$code" == 202 ]] || \
    die "Artifactory returned HTTP $code while publishing $distribution_repository:$tag"
}

validate_tag() {
  [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "Invalid destination image tag: $1"
}

image_count=0
published=0
planned=0
skipped=0
uploaded_blobs=0
existing_blobs=0
while IFS= read -r image_json; do
  ((image_count += 1))

  source="$(jq -r '.source' <<< "$image_json")"
  source_registry="$(jq -r '.registry' <<< "$image_json")"
  source_repository="$(jq -r '.repository' <<< "$image_json")"
  source_tag="$(jq -r '.sourceTag' <<< "$image_json")"
  target_repository="$(jq -r '.targetRepository' <<< "$image_json")"
  target_tag="$(jq -r '.targetTag' <<< "$image_json")"
  manifest_digest="$(jq -r '.manifest.digest' <<< "$image_json")"
  manifest_media_type="$(jq -r '.manifest.mediaType' <<< "$image_json")"
  complete="$(jq -r '.complete' <<< "$image_json")"

  [[ "$source" != *$'\n'* && "$source" != *$'\r'* ]] || die "Image source contains a line break"
  [[ "$manifest_media_type" =~ ^[A-Za-z0-9][A-Za-z0-9.+_-]*/[A-Za-z0-9][A-Za-z0-9.+_-]*$ ]] || \
    die "Invalid manifest media type for $source"
  validate_repository_path "$source_repository" "source repository"
  source_registry="$(registry_component "$source_registry")"
  if [[ -n "$target_repository" ]]; then
    validate_repository_path "$target_repository" "targetRepository"
    image_repository="$target_repository"
  else
    image_repository="$source_registry/$source_repository"
  fi

  distribution_repository="$repository"
  visible_repository=""
  if [[ -n "$target_prefix" ]]; then
    distribution_repository="$distribution_repository/$target_prefix"
    visible_repository="$target_prefix/"
  fi
  distribution_repository="$distribution_repository/$image_repository"
  visible_repository="$visible_repository$image_repository"

  if [[ -z "$target_tag" ]]; then
    if [[ -n "$source_tag" ]]; then
      target_tag="$source_tag"
    else
      [[ "$manifest_digest" == sha256:* ]] || die "Cannot derive a tag from $manifest_digest"
      target_tag="sha256-${manifest_digest#sha256:}"
    fi
  fi
  validate_tag "$target_tag"
  manifest_path="$(blob_path "$manifest_digest")"
  verify_sha256_digest "$manifest_path" "$manifest_digest" || die "Bundle is missing manifest $manifest_digest"

  if [[ "$complete" != true && "$allow_incomplete" -eq 0 ]]; then
    die "Image $source is incomplete; recreate the bundle without --skip-layers"
  fi

  image_blob_digests=()
  while IFS= read -r blob_digest; do
    image_blob_digests+=("$blob_digest")
  done < <(jq -r '[.config.digest, .layers[].digest] | .[]' <<< "$image_json")
  for blob_digest in "${image_blob_digests[@]}"; do
    local_blob_path="$(blob_path "$blob_digest")"
    if [[ -f "$local_blob_path" ]]; then
      verify_sha256_digest "$local_blob_path" "$blob_digest"
    elif [[ "$allow_incomplete" -eq 0 ]]; then
      die "Bundle is missing referenced blob $blob_digest"
    fi
  done

  destination="$registry_url/$repository/$visible_repository:$target_tag"
  if [[ "$dry_run" -eq 1 ]]; then
    status "would publish $destination"
    ((planned += 1))
    continue
  fi

  if [[ "$skip_existing" -eq 1 ]] && head_exists manifests "$distribution_repository" "$target_tag"; then
    status "skipping existing image $destination"
    ((skipped += 1))
    continue
  fi

  for blob_digest in "${image_blob_digests[@]}"; do
    local_blob_path="$(blob_path "$blob_digest")"
    if head_exists blobs "$distribution_repository" "$blob_digest"; then
      status "blob already present: $blob_digest"
      ((existing_blobs += 1))
    elif [[ -f "$local_blob_path" ]]; then
      upload_blob "$distribution_repository" "$blob_digest" "$local_blob_path"
      ((uploaded_blobs += 1))
    else
      die "Incomplete bundle blob is not already present in Artifactory: $blob_digest"
    fi
  done
  publish_manifest "$distribution_repository" "$target_tag" "$manifest_media_type" "$manifest_path"
  ((published += 1))
done < <(jq -c '.images[]' "$bundle_manifest")

[[ $image_count -gt 0 ]] || die "Bundle manifest does not contain any images"

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

dry_run_json=false
[[ "$dry_run" -eq 1 ]] && dry_run_json=true
printf -v summary '{\n  "mode": "OciImageBundleUpload",\n  "dryRun": %s,\n  "registryUrl": "%s",\n  "artifactoryRepository": "%s",\n  "targetPrefix": "%s",\n  "imageCount": %d,\n  "published": %d,\n  "planned": %d,\n  "skippedExisting": %d,\n  "uploadedBlobs": %d,\n  "existingBlobs": %d\n}\n' \
  "$dry_run_json" "$(json_escape "$registry_url")" "$(json_escape "$repository")" \
  "$(json_escape "$target_prefix")" "$image_count" "$published" "$planned" "$skipped" \
  "$uploaded_blobs" "$existing_blobs"

printf '%s' "$summary"
if [[ -n "$summary_output" ]]; then
  mkdir -p "$(dirname "$summary_output")"
  printf '%s' "$summary" > "$summary_output"
fi
