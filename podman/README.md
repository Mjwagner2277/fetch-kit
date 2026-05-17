# Podman Pull Replacement

`Get-ContainerImage.ps1` pulls container images without invoking Podman, Docker,
Skopeo, or ORAS. It talks directly to OCI Distribution / Docker Registry v2 APIs
with PowerShell HTTP calls and writes an OCI image layout to disk.

## What It Can Retrieve

- Public images from Docker Hub, including shorthand names such as `alpine:3.20`.
- Public images from GitLab Container Registry, including the GitLab analyzer
  image used in the offline container scanning documentation:
  `registry.gitlab.com/security-products/container-scanning:8`.
- Private registry images when credentials are supplied.
- Multi-architecture images, selecting a manifest with `-Platform`.

## Examples

The examples below assume your current directory is `fetch-kit/podman`. From the
repository root, prefix script paths with `.\podman\`, for example:

```powershell
.\podman\Get-ContainerImage.ps1 -Image "alpine:3.20"
```

Pull the GitLab offline container scanning analyzer image:

```powershell
.\Get-ContainerImage.ps1 `
  -Image "registry.gitlab.com/security-products/container-scanning:8" `
  -Platform "linux/amd64"
```

Pull a Docker Hub image using Docker-style shorthand:

```powershell
.\Get-ContainerImage.ps1 -Image "alpine:3.20"
```

Pull by digest instead of tag:

```powershell
.\Get-ContainerImage.ps1 `
  -Image "alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc" `
  -SkipLayers
```

Pull from an authenticated registry:

```powershell
$env:REGISTRY_USERNAME = "oauth2"
$env:REGISTRY_PASSWORD = "glpat-..."

.\Get-ContainerImage.ps1 `
  -Image "registry.gitlab.example.com/group/project/image:tag"
```

Fetch only the selected manifest and config blob, which is useful for quick
connectivity and auth tests:

```powershell
.\Get-ContainerImage.ps1 `
  -Image "registry.gitlab.com/security-products/container-scanning:8" `
  -SkipLayers
```

## Output

By default, images are written under:

```text
.\container-image-cache
```

Each image creates an OCI image layout directory with:

- `oci-layout`
- `index.json`
- `blobs/sha256/<digest>` entries for the selected manifest, config, and layers

The script verifies cached and newly downloaded manifest, config, and layer blobs
against their content digests. If an existing cached blob has the wrong digest,
it is replaced. The script prints a JSON summary with the selected manifest
digest, config path, downloaded layer paths, and layout path.

## Tests

The test harness uses:

- `registry.gitlab.com/security-products/container-scanning:8`, the image named
  by GitLab's offline container scanning `SOURCE_IMAGE` example.
- `alpine:3.20`, to verify Docker Hub shorthand normalization.

By default the tests use `-SkipLayers` to avoid downloading large layers while
still validating registry auth, manifest-list platform selection, config blob
retrieval, and OCI layout creation.

```powershell
.\Test-ContainerImagePull.ps1
```

To download all layers:

```powershell
.\Test-ContainerImagePull.ps1 -FullPull
```

Run a random sample of five common public FOSS images:

```powershell
.\Test-CommonFossImages.ps1
```

From the repository root, run the test scripts as:

```powershell
.\podman\Test-ContainerImagePull.ps1
.\podman\Test-CommonFossImages.ps1
```

## Limitations

- The output is an OCI image layout, not a populated Podman local image store.
- Pushing to a registry is not implemented.
- Docker `save` tar archive output is not implemented.
- Windows container layers are not special-cased; select them with `-Platform`
  if the registry image provides them.
