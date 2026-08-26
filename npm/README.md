# PowerShell npm Package Retrieval

`Get-NpmPackage.ps1` downloads npm package tarballs and registry dependency
metadata without calling `npm`, `node`, `npx`, or any JavaScript toolchain. It
uses the npm registry HTTP API, resolves dist-tags and common semver ranges, and
recursively downloads the selected dependency graph.

## Quick Start

Download the latest version of a package and its regular dependencies:

```powershell
.\npm\Get-NpmPackage.ps1 -Package "lodash"
```

Download an exact version:

```powershell
.\npm\Get-NpmPackage.ps1 `
  -Package "react" `
  -Version "18.2.0"
```

Download a scoped package:

```powershell
.\npm\Get-NpmPackage.ps1 `
  -Package "@babel/core" `
  -Version "^7.24.0"
```

Include optional and peer dependency edges:

```powershell
.\npm\Get-NpmPackage.ps1 `
  -Package "webpack" `
  -Version "latest" `
  -IncludeOptionalDependencies `
  -IncludePeerDependencies
```

Use a private registry:

```powershell
$env:NPM_TOKEN = "npm_..."

.\npm\Get-NpmPackage.ps1 `
  -Package "@company/internal-lib" `
  -Version "2.3.4" `
  -Registry "https://registry.example.com/" `
  -BearerToken $env:NPM_TOKEN
```

Prepare a USB-transferable Artifactory upload bundle from an internet-connected
machine:

```powershell
.\npm\Get-NpmPackage.ps1 `
  -Package "@company/app" `
  -Version "1.2.3" `
  -Registry "https://registry.npmjs.org/" `
  -OutputDirectory ".\npm-airgap-cache" `
  -IncludeOptionalDependencies `
  -IncludePeerDependencies
```

Copy only this directory to the air-gapped environment:

```text
.\npm-airgap-cache\artifactory-upload
```

Publish that transferred bundle to Artifactory inside the air-gapped
Linux environment:

```bash
export ARTIFACTORY_TOKEN="..."

./publish-npm-package-bundle.sh \
  --registry-url "https://art.example.com/artifactory/api/npm/npm-local/" \
  --token "$ARTIFACTORY_TOKEN" \
  --skip-existing
```

Run a random five-package sample from the repository's popular-package list:

```powershell
.\npm\Test-NpmPackageSample.ps1
```

Mirror every npm package version from a GitLab project or group package registry
to an Artifactory npm repository:

```bash
GITLAB_URL=https://gitlab.example.com \
GITLAB_TOKEN=glpat-... \
GITLAB_SCOPE_TYPE=project \
GITLAB_SCOPE_ID=12345 \
ARTIFACTORY_NPM_REGISTRY=https://art.example.com/artifactory/api/npm/npm-local/ \
ARTIFACTORY_TOKEN=... \
  ./npm/mirror-gitlab-npm-to-artifactory.sh
```

## Output

By default, downloads are written under:

```text
.\npm-package-cache
```

Each selected package version is stored under:

```text
npm-package-cache/
  packages/
    _babel_core/
      7.24.9/
        _babel_core-7.24.9.tgz
        metadata.json
        package.json
```

The command prints a JSON summary with:

- `Packages`: resolved package names, versions, requirements, parents, and
  dependency kinds.
- `Edges`: dependency graph edges.
- `Downloads`: tarball and metadata paths.
- `Failures`: resolution or download failures.
- `Output`: cache root.

Unless `-SkipArtifactoryBundle` is passed, the script also writes a
publish-ready bundle under:

```text
npm-package-cache/
  artifactory-upload/
    README.txt
    packages.json
    packages.tsv
    retrieval-summary.json
    publish-npm-package-bundle.sh
    tarballs/
      package-version.tgz
```

That `artifactory-upload` directory is the part intended for USB transfer. The
tarballs are flattened into one directory, and `packages.json` records package
name, version, tarball path, original source metadata paths, source tarball URL,
SHA-1, and SHA-512. The Bash offline publish script verifies the SHA-1 before
publishing each tarball.

## Dependency Resolution Behavior

The resolver downloads the root package, then follows its `dependencies`
recursively. Optional, peer, and root development dependencies are controlled by
switches:

- `-IncludeOptionalDependencies`
- `-IncludePeerDependencies`
- `-IncludeDevDependencies`

Version selection supports dist-tags such as `latest`, exact versions, wildcard
ranges, caret ranges, tilde ranges, comparator ranges like `>=1 <2`, hyphen
ranges like `1.2.0 - 1.4.0`, and `||` alternatives. For a matching range, it
chooses the highest matching non-prerelease version by default. Deprecated
versions remain eligible because npm can still resolve them in dependency
graphs.

Prerelease versions are eligible when the requested range itself names a
prerelease, such as `^1.0.0-beta.2`. Use `-IncludePrerelease` when prerelease
versions must be eligible for ordinary ranges too. `-IncludeDeprecated` is still
accepted for compatibility with older commands, but deprecated versions are no
longer filtered by default.

Dependency entries that use npm alias syntax, such as
`react-is-18: npm:react-is@^18.3.1`, are resolved through the real package name
while the alias is preserved in the summary graph.

## Important Differences From npm

This is a retrieval tool, not an installer. It does not:

- create `node_modules`
- run lifecycle scripts
- read or write `package-lock.json`, `npm-shrinkwrap.json`, or workspaces
- implement npm's full peer dependency placement and conflict solver
- evaluate `os`, `cpu`, `engines`, or package manager constraints
- apply `overrides`, aliases, bundled dependencies, or registry config files
- verify Subresource Integrity strings beyond SHA-1 `dist.shasum`
- unpack `.tgz` files

Those omissions keep the implementation PowerShell-only and focused on
collecting npm registry source artifacts for offline review or mirroring.

## Parameters

- `-Package`: root npm package name, including scoped names such as
  `@scope/name`.
- `-Version`: exact version, dist-tag, or semver range. Defaults to `latest`.
- `-Registry`: npm-compatible registry URL. Defaults to
  `https://registry.npmjs.org/`.
- `-OutputDirectory`: cache destination. Defaults to `.\npm-package-cache`.
- `-MaxDepth`: maximum dependency depth. `0` means unlimited.
- `-IncludeDevDependencies`: include root package `devDependencies`.
- `-IncludeOptionalDependencies`: include `optionalDependencies`.
- `-IncludePeerDependencies`: include `peerDependencies`.
- `-IncludeDeprecated`: accepted for compatibility; deprecated versions are
  eligible by default.
- `-IncludePrerelease`: allow prerelease versions during selection.
- `-BearerToken`: bearer token for private registries, defaults to
  `$env:NPM_TOKEN`.
- `-Username` and `-Password`: basic authentication fallback.
- `-SkipArtifactoryBundle`: only write the resolver cache layout and skip the
  publish-ready `artifactory-upload` directory.

## Air-Gapped Artifactory Workflow

The intended disconnected workflow is:

1. On an internet-connected asset, run `Get-NpmPackage.ps1` for each root
   application/package that must be available offline. Use `-MaxDepth 0`, the
   default, to retrieve the full dependency tree selected by the resolver.
2. Review `Failures` in the JSON output. Do not transfer the bundle until
   `FailureCount` is `0`, unless you intentionally accept missing optional or
   peer packages.
3. Transfer the whole `artifactory-upload` directory to the air-gapped
   environment.
4. On the air-gapped Linux side, run `publish-npm-package-bundle.sh` from inside
   that transferred directory.

The Linux offline publisher requires Bash, `jq`, `sha1sum`, and `npm` because
Artifactory accepts standard npm package publication through
`npm publish --registry`. It does not need internet access.

Offline publisher examples:

```bash
# Token authentication
./publish-npm-package-bundle.sh \
  --registry-url "https://art.example.com/artifactory/api/npm/npm-local/" \
  --token "$ARTIFACTORY_TOKEN" \
  --skip-existing

# Username/password or API key authentication
./publish-npm-package-bundle.sh \
  --registry-url "https://art.example.com/artifactory/api/npm/npm-local/" \
  --username "$ARTIFACTORY_USERNAME" \
  --password "$ARTIFACTORY_PASSWORD" \
  --skip-existing

# Validate bundle and show what would publish
./publish-npm-package-bundle.sh \
  --registry-url "https://art.example.com/artifactory/api/npm/npm-local/" \
  --token "$ARTIFACTORY_TOKEN" \
  --dry-run
```

## Sample Test Harness

`Test-NpmPackageSample.ps1` keeps a checked-in list of 100+ commonly downloaded
npm packages, samples five by default, and runs `Get-NpmPackage.ps1` for each
selected package. It writes:

- `sample-results/sample.json`
- one log file per sampled package
- `sample-results/results.json`
- `sample-results/summary.json`

The harness defaults to `-MaxDepth 2` so random samples stay bounded while still
testing recursive dependency retrieval. Pass `-MaxDepth 0` to walk the full
registry dependency graph for each sampled package.

## GitLab to Artifactory Mirror

`mirror-gitlab-npm-to-artifactory.sh` copies already-published npm package
versions from GitLab Package Registry to an Artifactory npm repository. It uses:

- GitLab Packages API pagination to list package versions.
- GitLab npm registry access through `npm pack`.
- Artifactory npm publishing through `npm publish --registry`.

Required tools:

- `bash`
- `curl`
- `jq`
- `npm`

Required environment variables:

- `GITLAB_URL`: base GitLab URL, such as `https://gitlab.example.com`.
- `GITLAB_TOKEN`: GitLab token with API and package read access.
- `GITLAB_SCOPE_TYPE`: `project` or `group`.
- `GITLAB_SCOPE_ID`: project/group numeric ID or URL path.
- `ARTIFACTORY_NPM_REGISTRY`: target Artifactory npm registry URL, normally
  `https://host/artifactory/api/npm/<repo>/`.
- `ARTIFACTORY_TOKEN`: Artifactory token for npm publishing. Alternatively set
  `ARTIFACTORY_USERNAME` and `ARTIFACTORY_PASSWORD`.

Useful optional settings:

- `GITLAB_NPM_REGISTRY`: override the source npm registry URL.
- `GITLAB_PACKAGE_STATUS`: package status filter. Defaults to `default`; set
  `all` to omit the status filter. Use `all` if you are reconciling missing
  versions and want GitLab to return every package status the API will expose.
- `WORK_DIR`: where tarballs, logs, and summary files are written.
- `KEEP_WORK_DIR=true`: keep the temporary work directory after completion.
- `SKIP_EXISTING=true`: treat already-published Artifactory versions as success.
  This is the default.
- `DRY_RUN=true`: list packages without downloading or publishing.
- `DRY_RUN_SIZE=true`: query GitLab package-file metadata and include total
  package file size in the dry-run summary. This is the default. Set
  `DRY_RUN_SIZE=false` to avoid the extra GitLab API calls.
- `INCLUDE_PACKAGE_REGEX` and `EXCLUDE_PACKAGE_REGEX`: limit package names.

For a group registry, use:

```bash
GITLAB_SCOPE_TYPE=group \
GITLAB_SCOPE_ID=my-group/subgroup \
  ./npm/mirror-gitlab-npm-to-artifactory.sh
```

The script writes a JSON summary to stdout and stores `results.jsonl` plus
`summary.json` in `WORK_DIR`. It exits non-zero if any selected package version
fails to mirror.

To verify what the script will try to mirror before publishing, keep the work
directory and run a dry run:

```bash
KEEP_WORK_DIR=true \
WORK_DIR=/tmp/gitlab-npm-mirror-audit \
DRY_RUN=true \
GITLAB_PACKAGE_STATUS=all \
GITLAB_URL=https://gitlab.example.com \
GITLAB_TOKEN=glpat-... \
GITLAB_SCOPE_TYPE=project \
GITLAB_SCOPE_ID=12345 \
ARTIFACTORY_NPM_REGISTRY=https://art.example.com/artifactory/api/npm/npm-local/ \
ARTIFACTORY_TOKEN=... \
  ./npm/mirror-gitlab-npm-to-artifactory.sh
```

Then inspect:

```bash
cut -f1,2 "$WORK_DIR/gitlab-npm-packages.tsv"
jq -r '.results[] | [.status, .package, .version] | @tsv' "$WORK_DIR/summary.json"
```

Each line in `gitlab-npm-packages.tsv` is one GitLab package version selected
from the API. The final summary separates `mirrored`, `skipped_existing`,
filtered `skipped`, and `failed`, so already-present Artifactory versions are no
longer blended into the publish count.

To confirm packages with multiple versions are handled separately:

```bash
column -t -s $'\t' "$WORK_DIR/gitlab-npm-version-counts.tsv"
```

Example:

```text
Package                VersionCount  Versions
@protobuf-ts/runtime   3             2.9.3,2.9.4,2.9.5
@protobuf-ts/plugin    2             2.9.4,2.9.5
```

The script mirrors each `name + version` row independently, so those examples
would publish `@protobuf-ts/runtime@2.9.3`, `@protobuf-ts/runtime@2.9.4`, and
`@protobuf-ts/runtime@2.9.5` as separate package versions.

Dry-run sizing example:

```bash
DRY_RUN=true \
GITLAB_URL=https://gitlab.example.com \
GITLAB_TOKEN=glpat-... \
GITLAB_SCOPE_TYPE=project \
GITLAB_SCOPE_ID=12345 \
ARTIFACTORY_NPM_REGISTRY=https://art.example.com/artifactory/api/npm/npm-local/ \
ARTIFACTORY_TOKEN=... \
  ./npm/mirror-gitlab-npm-to-artifactory.sh
```

The summary includes `dry_run_size_bytes`, `dry_run_size_human`, and
`dry_run_unknown_size_count`, and the script logs the total known size at the
end of the dry run. GitLab's package list API does not include package file size
directly, so the script totals the `size` fields from the package files endpoint
for each package version. Project scope supports this directly. Group scope
depends on GitLab returning enough project/link metadata to locate the
package-files endpoint; otherwise the package is counted as unknown size.
