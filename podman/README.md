# OCI Image Air-Gap Transfer

The tools in this directory download a list of container images, select one
target platform, deduplicate their content in a shared OCI image layout, create
a transfer archive, and publish the images into an Artifactory local Docker
repository.

The connected-side downloader uses Python's standard library. The receiving-side
uploader uses Bash, `curl`, `jq`, and standard Unix utilities. Both talk to the
OCI Distribution API directly and do not invoke Podman, Docker, Skopeo, ORAS,
the JFrog CLI, or PowerShell.

## Files

- `Get-ContainerImage.py` downloads one or more images and optionally creates a
  `.tar` or `.tar.gz` transfer archive.
- `upload-container-images-to-artifactory.sh` verifies and uploads a bundle to
  an Artifactory Docker/OCI registry using Bash, `curl`, and `jq`.
- `oci_registry.py` contains the shared registry, authentication, digest, and
  image-reference support.
- `recommended-rhel9-ci-images.txt` is a starter list of RHEL 9 UBI, slim UBI,
  Iron Bank-hardened UBI, and common CI images.
- `registry-credentials.example.json` shows registry-scoped source credentials.
- `tests/test_oci_bundle_workflow.py` is a local end-to-end test.

## Connected-Side Download

Download the sample list for Linux AMD64 and create one transfer archive:

```bash
python3 Get-ContainerImage.py \
  --images-file recommended-rhel9-ci-images.txt \
  --platform linux/amd64 \
  --output-directory oci-image-bundle \
  --archive-output oci-image-bundle.tar.gz \
  --credentials-file registry-credentials.json
```

The sample includes Registry1/Iron Bank images, which require an account. Copy
`registry-credentials.example.json` to the gitignored
`registry-credentials.json`, then add your Registry1 credentials. Credentials
are selected by registry host; an Iron Bank secret is not sent to Docker Hub,
Red Hat, GHCR, Quay, or GitLab.

For a public-only run, remove or comment out the `registry1.dso.mil` entries and
omit `--credentials-file`.

Images can also be supplied directly. Repeat `--image`, use positional
references, or combine both forms with one or more list files:

```bash
python3 Get-ContainerImage.py \
  --image registry.access.redhat.com/ubi9/ubi:9.7 \
  --image registry.access.redhat.com/ubi9/ubi-minimal:9.7 \
  --archive-output rhel9-bases.tar.gz
```

Text list files allow blank lines and `#` comments. JSON lists can set explicit
destination names and tags:

```json
{
  "images": [
    {
      "image": "registry.access.redhat.com/ubi9/ubi-minimal:9.7",
      "targetRepository": "base-images/ubi9-minimal",
      "targetTag": "9.7"
    }
  ]
}
```

Without overrides, the uploader preserves the source registry and repository in
the destination path. The JSON form is useful when your Artifactory naming
policy requires shorter paths.

### Source Authentication

`--credentials-file` accepts either the example format or Docker's
`config.json` `auths` object. Each registry entry can contain `username` and
`password`, base64 `auth`, or `bearerToken`/`identitytoken`.

For a single private source registry, environment variables also work:

```bash
export REGISTRY_HOST=registry1.dso.mil
export REGISTRY_USERNAME='<registry1 username>'
export REGISTRY_PASSWORD='<registry1 CLI secret>'

python3 Get-ContainerImage.py \
  --images-file ironbank-images.txt \
  --archive-output ironbank-images.tar.gz
```

When a run spans multiple registries, `REGISTRY_HOST` or
`--credential-registry` is required for inline/environment credentials. This
prevents one registry's secret from being sent to another registry.

## Bundle Contents

The bundle directory is a valid OCI image layout with additional transfer
metadata:

```text
oci-image-bundle/
  oci-layout
  index.json
  bundle-manifest.json
  SHA256SUMS
  README.txt
  blobs/
    sha256/
      ...
```

`index.json` references the selected platform manifest for each image.
`bundle-manifest.json` records the original source, source tag or digest,
selected platform, resolved manifest digest, config and layers, and optional
destination overrides. Shared blobs are stored once. Cached blobs are reused
only after their content digest is verified.

The transfer archive contains the whole directory under one top-level folder.
The Bash uploader reads the canonical `bundle-manifest.json` with `jq`, so there
is no duplicate upload manifest to keep synchronized. Move the archive and this
uploader to the environment that can reach Artifactory:

- `upload-container-images-to-artifactory.sh`

## Artifactory Upload

Create or select an Artifactory **local Docker repository** (for example,
`docker-local`). On the receiving side, upload directly from the archive:

```bash
export ARTIFACTORY_TOKEN='<access token>'

./upload-container-images-to-artifactory.sh \
  --bundle-tar oci-image-bundle.tar.gz \
  --registry-url https://company.jfrog.io \
  --repository docker-local \
  --target-prefix airgap
```

For the plain-text sample list, a source such as:

```text
registry.access.redhat.com/ubi9/ubi-minimal:9.7
```

is published as:

```text
company.jfrog.io/docker-local/airgap/registry.access.redhat.com/ubi9/ubi-minimal:9.7
```

The exact hostname and repository routing depend on the Artifactory Docker
access method configured by your administrator. Pass the registry-facing base
URL to `--registry-url`; do not append `/v2`.

The uploader performs these operations in order for each image:

1. Verify `SHA256SUMS` and every OCI manifest/config/layer digest.
2. Check whether each referenced blob is already present in the destination
   repository.
3. Upload missing blobs with the OCI Distribution upload endpoints.
4. Publish the exact selected image manifest under the destination tag.

Use a preview to verify destination names without contacting Artifactory:

```bash
./upload-container-images-to-artifactory.sh \
  --bundle-tar oci-image-bundle.tar.gz \
  --registry-url https://company.jfrog.io \
  --repository docker-local \
  --target-prefix airgap \
  --dry-run
```

The uploader accepts these target authentication forms:

- `ARTIFACTORY_TOKEN` or `--token` for bearer authentication.
- `ARTIFACTORY_USERNAME` plus `ARTIFACTORY_PASSWORD` (also
  `ARTIFACTORY_USER`) for Basic authentication.
- `ARTIFACTORY_API_KEY` or `--api-key` for legacy JFrog API-key headers.

The receiving host only needs Bash, `curl`, `jq`, `tar`, and `sha256sum` or
`shasum`. It does not need Python or a container CLI.

Use `--skip-existing` when an existing destination tag must never be replaced.
By default, missing blobs are reused and the tag is published or updated. A
digest-only source is assigned a tag such as `sha256-<full digest>` unless a
JSON list supplies `targetTag`.

## Choosing and Pinning Images

The Red Hat UBI family does not use a `slim` tag. `ubi-minimal` is the practical
slim base with `microdnf`; `ubi-micro` is smaller and has no package manager.
The sample includes both, plus full UBI and init-capable UBI.

The sample uses RHEL 9 minor tags where practical and moving tags for several CI
utilities. Every downloaded bundle records the exact selected manifest digest,
so the transferred content does not change after download. For long-lived or
audited baselines, replace moving source tags with approved `@sha256:...`
references and use JSON `targetTag` values that match your promotion policy.

Iron Bank Registry1 does not allow anonymous pulls. Tags and approved versions
also change independently from Red Hat's public UBI cadence; confirm the desired
tag in the Iron Bank catalog before creating a production baseline.

## Test

The end-to-end test starts a loopback-only registry stand-in and verifies bearer
authentication, multi-platform index selection, image/config/layer download,
OCI layout creation, transfer archive extraction, checksum validation, blob
upload, manifest publication, and offline dry-run behavior:

```bash
python3 -B tests/test_oci_bundle_workflow.py
```

No internet connection, external container CLI, or Artifactory instance is
needed for this test.

## Limitations

- One platform is selected per run. Run separate bundles for `linux/amd64` and
  `linux/arm64` when both are needed; the uploader does not reconstruct a
  multi-architecture index.
- OCI referrers such as Cosign signatures, attestations, and SBOM artifacts are
  not discovered automatically. List standalone OCI artifacts explicitly when
  their references are known.
- `--skip-layers` is only for registry/auth connectivity checks. It creates an
  incomplete bundle that the uploader rejects by default.
- Registry-specific content trust, malware review, vulnerability acceptance,
  and Artifactory promotion policies remain operational responsibilities.
