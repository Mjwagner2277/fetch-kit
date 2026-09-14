# npm Artifactory Transfer Bundles

`download-npm-artifactory-bundle.js` uses the local `npm` CLI on an
internet-connected machine to resolve, pack, and stage npm packages for an
airgapped Artifactory upload process.

The downloader produces one transfer tar per run. The registry uploader is a
separate Bash script that can be maintained in the airgapped environment and
consume either the transfer tar or an extracted bundle directory.

## Quick Start

Download the latest compatible versions for a target Node.js version:

```bash
node npm/download-npm-artifactory-bundle.js \
  --node-version 20.11.1 \
  react \
  lodash \
  @storybook/test-runner
```

Download one exact package version for a target Node.js version:

```bash
node npm/download-npm-artifactory-bundle.js \
  --node-version 20.11.1 \
  react@18.2.0
```

Download a package list for a target Node.js version:

```bash
node npm/download-npm-artifactory-bundle.js \
  --node-version 20.11.1 \
  --packages-file packages-node-20.txt
```

Download for a specific airgapped npm platform:

```bash
node npm/download-npm-artifactory-bundle.js \
  --node-version 20.11.1 \
  --target-os linux \
  --target-arch x64 \
  --target-libc glibc \
  --packages-file packages-node-20.txt
```

Download everything already recorded for that same Node.js version:

```bash
node npm/download-npm-artifactory-bundle.js \
  --node-version 20.11.1 \
  --update-all
```

Use a private registry:

```bash
node npm/download-npm-artifactory-bundle.js \
  --node-version 20.11.1 \
  --registry "https://registry.example.com/" \
  --token "$NPM_TOKEN" \
  --no-ssl \
  @company/app
```

## Package Input Files

Use `--packages-file` or `--package-file` to load requested root packages from
a file. The flag may be repeated, and file entries can be combined with
positional package arguments or repeated `--package` arguments.
If the same package name appears more than once, the last request wins; CLI
package arguments are applied after package files.

Plain text files support blank lines and `#` comments:

```text
react
lodash@4.17.21
@storybook/test-runner
express 4.18.2
@protobuf-ts/runtime 2.9.4
```

JSON package lists are also supported:

```json
[
  "react",
  "lodash@4.17.21",
  { "name": "@protobuf-ts/runtime", "version": "2.9.4" }
]
```

You can also use a simple dependency map:

```json
{
  "react": "18.2.0",
  "@protobuf-ts/runtime": "2.9.4"
}
```

Unversioned entries are recorded as `latest` requests in the state file and are
resolved to the newest version compatible with the supplied `--node-version`.
Versioned entries stay pinned or ranged exactly as requested.

Upload the transfer tar from the airgapped environment:

```bash
bash upload-npm-artifactory-bundle.sh \
  --bundle-tar npm-artifactory-bundle-node-v20.11.1-20260904T201500Z.tar \
  --registry-url "https://art.example.com/artifactory/api/npm/npm-local/" \
  --token "$ARTIFACTORY_TOKEN"
```

## Output

By default, local state is written under:

```text
npm-state/
  node-v20.11.1.json
```

Transfer tar files are written under:

```text
npm-artifactory-cache/
  node-v20.11.1/
    npm-artifactory-bundle-node-v20.11.1-20260904T201500Z.tar
```

Inside the transfer tar:

```text
npm-artifactory-bundle-node-v20.11.1-.../
  README.txt
  package.json
  package-lock.json
  root-packages.json
  packages.json
  packages.jsonl
  packages.tsv
  artifactory-upload-manifest.tsv
  summary.json
  state/
    node-v20.11.1.json
  tarballs/
    package-version.tgz
```

`packages.jsonl` is usually the easiest uploader input: one JSON object per
resolved package version, including name, version, tarball path, hashes, size,
engine metadata, whether it was a root request, and whether the packed tarball's
`package/package.json` was validated.

`artifactory-upload-manifest.tsv` is the minimal uploader input:

```text
name    version    tarball
```

## npm Registry Upload

`upload-npm-artifactory-bundle.sh` is intentionally separate from the transfer
tar. Copy and maintain that Bash script in the airgapped environment, then
point it at each transfer tar.

The uploader is registry-generic despite the file name. It only uses npm CLI
operations: `npm view <package> versions --json` to inspect the target registry
and `npm publish <tarball> --tag <tag>` to upload. That means the latest-tag
logic applies to Artifactory and to other npm-compatible registries that support
those standard npm operations. If the target registry cannot answer the version
query for a package, the default behavior is to avoid `latest` for that package.

Required upload inputs:

- `--bundle-tar`: transfer tar from the download machine.
- `--registry-url`: target npm registry URL, for Artifactory normally
  `https://host/artifactory/api/npm/<repo>/`.
- authentication via `--token`, `--username`/`--password`, or `--userconfig`.
- use `--no-ssl` when npm must talk to an HTTPS registry with certificate
  validation disabled.

Required upload tools on the airgapped machine:

- `bash`
- `npm`
- `jq`
- `tar`
- GNU-compatible `sort -V`

The uploader checks that every manifest tarball path exists, then publishes
those already-packed tarballs. npm package validation happens on the
internet-connected downloader side: every tarball is checked after `npm pack`
to confirm `package/package.json` contains the expected package name and
version.

The uploader always passes an explicit npm dist-tag. It does not rely on
`npm publish` defaults. It also treats already-published versions as success by
default so reruns of large bundles can continue making progress. Use
`--no-skip-existing` for strict conflict handling.

Default `latest` handling uses `--latest-policy computed`:

1. Read incoming versions from the bundle.
2. Query the target registry with `npm view <package> versions --json`.
3. Compute the highest stable version across the target registry and the incoming
   bundle.
4. Publish an incoming stable version with `latest` only if it is that highest
   stable version.
5. Publish older versions and prerelease versions with `airgap-<version>`.

That means if the target registry already has `some-lib@3.0.0`, and the transfer tar
contains `some-lib@2.0.0`, the uploader publishes `2.0.0` with
`airgap-2.0.0`, not `latest`.

If target registry version lookup fails for one package, the default policy avoids
`latest` for that package and continues with the rest of the bundle. That keeps
the upload fail-closed for tag safety while maximizing progress on large sets.
Use `--fail-on-remote-query-error` for strict lookup handling, or
`--latest-policy never` when you want to avoid `latest` tags entirely.

Dry-run example:

```bash
bash upload-npm-artifactory-bundle.sh \
  --bundle-tar npm-artifactory-bundle-node-v20.11.1-20260904T201500Z.tar \
  --registry-url "https://art.example.com/artifactory/api/npm/npm-local/" \
  --token "$ARTIFACTORY_TOKEN" \
  --no-ssl \
  --dry-run
```

For large uploads, provide a durable work directory so `upload-results.json`,
`upload-results.jsonl`, and `npm-publish.log` remain available:

```bash
bash upload-npm-artifactory-bundle.sh \
  --bundle-tar npm-artifactory-bundle-node-v20.11.1-20260904T201500Z.tar \
  --registry-url "https://art.example.com/artifactory/api/npm/npm-local/" \
  --token "$ARTIFACTORY_TOKEN" \
  --work-dir ./upload-work
```

## State Behavior

There is one state file per target Node.js version. Every run updates that
state file before resolution, so newly requested root packages are retained even
if a later network or registry step fails.

When a request uses `latest`, the script records the root package name as a
tracked request. Later `--update-all` runs resolve that package again and pick
the newest version whose `engines.node` range is compatible with the requested
`--node-version`.

Exact requests stay exact. For example, `react@18.2.0` remains pinned as
`18.2.0` in state.

## Node Version Selection

npm does not reliably resolve as a different Node.js runtime just because a
target version is supplied. This script therefore checks `engines.node` itself
when resolving `latest` root packages and after the lockfile is produced.

Supported engine range forms include:

- `>=18`
- `>=18 <21`
- `^18.17.0 || >=20.5.0`
- `~20.0.0`
- `18.x`
- `18.17.0 - 20.11.1`

If a transitive package has an incompatible `engines.node` range, the run fails
by default. Use `--allow-engine-mismatches` to record those mismatches in the
bundle manifests instead of failing.

## Target Platform

Use `--target-arch` when the airgapped runtime architecture differs from the
download machine:

```bash
node npm/download-npm-artifactory-bundle.js \
  --node-version 20.11.1 \
  --target-arch arm64 \
  @company/app
```

For Linux targets, prefer setting the full npm platform:

```bash
node npm/download-npm-artifactory-bundle.js \
  --node-version 20.11.1 \
  --target-os linux \
  --target-arch arm64 \
  --target-libc glibc \
  @company/app
```

These flags map to npm's `cpu`, `os`, and `libc` config values. They affect
dependency resolution for platform-specific native and optional packages.
Every bundle records the requested target platform in `summary.json` and
`README.txt`.

## Package Normalization

Packed tarballs are normalized by default before they are added to the transfer
tar. The normalizer removes `scripts` and `devDependencies` from
`package/package.json`, then repacks with `tar`.

This keeps packages importable as libraries while avoiding offline build, test,
prepare, install, and postinstall behavior. Runtime fields and dependencies are
kept, including `main`, `module`, `types`, `exports`, `dependencies`,
`peerDependencies`, and `optionalDependencies`.

Use these only when your runtime does not need those dependency relationships:

```bash
node npm/download-npm-artifactory-bundle.js \
  --node-version 20.11.1 \
  --strip-peer-dependencies \
  --strip-optional-dependencies \
  @company/app
```

## CVE Spreadsheet Difficulty

Populating an Excel CVE spreadsheet is moderate difficulty, not hard, if the
bundle already has `package-lock.json`.

The practical approach is:

1. Run `npm audit --json --package-lock-only` on the internet-connected side
   against the generated lockfile.
2. Convert audit vulnerabilities into rows with package, installed version,
   vulnerable range, severity, CVE/GHSA identifiers, advisory URL, fix
   availability, and dependency path.
3. Write `.xlsx` using a small Node dependency such as `exceljs`, or write CSV
   if Excel formatting is not important.

The hard parts are policy choices, not extraction:

- npm audit frequently reports GHSA/advisory IDs without a CVE.
- Private registry mirrors may not expose the same advisory data as npmjs.
- Transitive dependency paths can be numerous for the same vulnerable package.
- Airgapped systems should consume a precomputed report or an internally
  mirrored vulnerability database; they cannot query live advisory APIs.

## Deprecated Workflow

The previous PowerShell-only retriever, GitLab mirror, Bash upload helper, and
their tests live under:

```text
npm/soon-to-be-deprecated/
```
