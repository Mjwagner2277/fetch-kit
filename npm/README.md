# npm Artifactory Transfer Bundles

`download-npm-artifactory-bundle.js` uses the local `npm` CLI on an
internet-connected machine to resolve, pack, and stage npm packages for an
airgapped Artifactory upload process.

The script produces one transfer tar per run. The Artifactory uploader is not
maintained here; it can consume the manifests inside the tar.

## Quick Start

Download the latest compatible versions for a target Node.js version:

```bash
node npm/download-npm-artifactory-bundle.js \
  --node-version 20.11.1 \
  react \
  lodash \
  @storybook/test-runner
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
  @company/app
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
engine metadata, and whether it was a root request.

`artifactory-upload-manifest.tsv` is the minimal uploader input:

```text
name    version    tarball
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
