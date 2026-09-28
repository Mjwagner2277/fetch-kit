# npm Artifactory Transfer Bundles

`download-npm-http-bundle.js` resolves a package list for a selected Node version,
downloads packages through registry HTTP APIs, sanitizes their archives, and
builds a bundle for airgapped Artifactory publication. It does not invoke npm,
npx, package lifecycle scripts, or external tar utilities.

The downloader produces one transfer tar per run. The recommended airgapped
uploader is `upload-npm-artifactory-bundle.py`: Python 3.9+ standard library only,
without npm, Node.js, jq, Bash, external tar, or pip packages. It accepts a
directory of npm package tarballs, a transfer tar, or an extracted bundle
directory. The HTTP downloader includes a copy of the uploader in each bundle.

## Package list and target Node version, without npm

This is the current replacement for the HTTP-only retrieval workflow in
`soon-to-be-deprecated/Get-NpmPackage.ps1`. It keeps the recursive registry
retrieval model and adds target-Node checks on every selected dependency,
connected-side sanitization, and the standard Python-publisher bundle format.

Create a package list, for example `packages.txt`:

```text
# Names, exact versions, and version ranges are supported.
react@18.2.0
react@19.0.0
lodash@4.17.21
```

On the connected machine:

```bash
node npm/download-npm-http-bundle.js \
  --node-version 24.0.0 \
  --target-os linux \
  --target-arch x64 \
  --target-libc glibc \
  --packages-file packages.txt \
  --output-dir ./npm-node24-bundle \
  --tar-file ./npm-node24-bundle.tar
```

The requested `--node-version` is the version used for dependency compatibility
checks. It may be newer than the local Node runtime (Node 16+); the downloaded
packages are never installed or executed on the connected machine. Copy the
`npm/` directory together: the downloader uses
`lib/package-archives.js` for archive functions, `vendor/` for
SemVer, and the Python uploader for the transfer bundle. The vendored library
includes its license; there is no `npm install` setup step. The HTTP downloader
does not import the deprecated CLI downloader or load `child_process`.

npm may be installed on the connected machine; it is optional for this workflow.
Forward target selection comes from checking the requested `--node-version`
against each package's metadata, independently of the installed runtime. npm's
normal `engines` checks are advisory unless strict mode is enabled, so merely
installing npm does not establish target compatibility. See
[npm's engines documentation](https://docs.npmjs.com/cli/v11/configuring-npm/package-json/#engines).

On Windows PowerShell, run the same workflow as one command:

```powershell
node .\npm\download-npm-http-bundle.js --node-version 24.0.0 --target-os linux --target-arch x64 --target-libc glibc --packages-file .\packages.txt --output-dir .\npm-node24-bundle --tar-file .\npm-node24-bundle.tar
```

The target platform flags describe the airgapped destination, independently of
the connected Windows host. Package lists accept UTF-8 and BOM-marked UTF-16,
including PowerShell-generated files and CRLF line endings. Quote paths with
spaces. Transfer archive creation also supports drives without hard links,
such as FAT/exFAT media, and refuses to replace an existing archive.

The reported Windows `spawnSync npm ENOENT` came from the earlier npm CLI
downloader, now under `soon-to-be-deprecated/`. Its launcher fix runs npm's
`npm-cli.js` through Node; the HTTP command above does not launch npm at all.
Copy `download-npm-http-bundle.js`, `lib/`, `vendor/`, and
`upload-npm-artifactory-bundle.py` together when distributing just the current
tool. No files from `soon-to-be-deprecated/` are needed.

Start with a new output directory and transfer tar path. The downloader creates
`--output-dir` immediately and saves each verified, sanitized package there
as it is resolved. Progress is durable throughout the run:

```text
npm-node24-bundle/
  tarballs/                       # verified, sanitized packages saved so far
  partial-packages.json            # running package inventory
  partial-dependency-graph.json    # selected roots and resolved edges so far
  summary.json                    # counts, target, status and last error
  download-state.json             # target, cumulative requests, selections, cache inventory
  npm-bundle.INCOMPLETE            # present until resolution and preparation finish
npm-node24-bundle.cache/           # verified original source archives for reuse
```

An error or interruption keeps these downloads and progress files. To retry,
rerun the same command with **`--resume`**. The source registry metadata is
fetched again, and cached tarballs are rechecked against its checksum and package
identity before reuse. A corrupt cache entry is downloaded again. Resume requires
the same registry, target Node/platform, and dependency options; credentials can
be corrected. Package arguments may be omitted to use the stored requests, or
may repeat existing requests; use `--update` to add new requests. Resume rebuilds
the graph and sanitized copies. Old selections are removed from the prepared set only after successful resolution,
while their original downloads remain cached. Run one downloader per output
directory at a time.

```powershell
node .\npm\download-npm-http-bundle.js --node-version 24.0.0 --target-os linux --target-arch x64 --target-libc glibc --packages-file .\packages.txt --output-dir .\npm-node24-bundle --tar-file .\npm-node24-bundle.tar --resume
```

Use `--cache-dir PATH` to choose another persistent cache location outside the
output directory. This cache contains original archives and is not the prepared
publishing bundle. The default cache is `<output-dir>.cache` and is kept after
success too. Resume and update remember a previously supplied custom cache path
unless you explicitly select another `--cache-dir`. Old versions of this script
deleted temporary downloads on failure; they cannot supply this new resume state,
so their failed runs need a fresh run.

### Add packages to an existing bundle

Use **`--update`** with the same output directory and a **new transfer TAR path**.
It works for completed bundles and interrupted runs. You can supply just the
additions or an expanded package list; saved root requests are retained and
duplicates are ignored. For example, after creating `npm-node24-bundle` above:

```powershell
node .\npm\download-npm-http-bundle.js --node-version 24.0.0 --target-os linux --target-arch x64 --target-libc glibc --package axios --output-dir .\npm-node24-bundle --tar-file .\npm-node24-bundle-v2.tar --update
```

`download-state.json` is saved as each source archive is verified. It records the
requested Node version, platform, registry, cumulative package requests, selected
versions, cache location, and original-archive checksums. It belongs to that exact
**requested Node version**, independently of the Node runtime running the script.
Using the directory with a different Node version, OS, architecture, libc, source
registry, or dependency option is rejected before changing existing files.

For another Node target, use a separate output directory and transfer TAR. You
may point both targets at the same `--cache-dir`: original source bytes can be
reused, but each target gets its own state, dependency selections, compatibility
checks, and prepared package copies. An archive is never accepted solely because
the state file says it was downloaded; its checksum and package identity are
verified again. Keep the cache directory alongside the state for download reuse.

Updates preserve previous root and dependency selections and optional omissions,
including tags rewritten inside sanitized archives, and resolve new requests
against fresh registry metadata.
This avoids changing the bytes of an existing package version merely because a
source tag moved. To add a newer version, request it explicitly, such as
`--package react@19.0.0`; previously requested versions remain included. To refresh
all ranges and tags, start a new output directory using the shared cache.
Metadata HTTP requests still occur during update, but unchanged verified package
tarballs are reused. Each run reports `sourceDownloadCount` and
`reusedDownloadCount` so these cases are visible.

If an update fails, its accumulated requests and selections remain in the state.
Rerun it with `--update`, or use `--resume` with the same target options and no
package arguments. Earlier complete transfer TARs remain unchanged. The live
directory is marked incomplete until the expanded graph finishes; use a fresh
TAR filename for every successful generation. Existing archives are never
overwritten. Bundles from the preceding HTTP downloader version are migrated
from their saved summary and dependency graph automatically. The state and
original cache stay on the connected machine; the transfer TAR contains only
the prepared publishing bundle.

### Publish the completed bundle

The Python uploader refuses inputs containing `npm-bundle.INCOMPLETE`, including
direct selection of its `tarballs/` subdirectory. Do not remove the marker to
bypass an unresolved dependency graph. On success, final manifests replace the
partial inventories and the marker is removed. If only transfer-TAR creation
fails, the completed directory is preserved with `status: "archive-failed"` and
can still be published using `--bundle-dir`.

The completed bundle
contains sanitized tarballs, `packages.json`/`packages.jsonl`, exact root
selections, `dependency-graph.json`, `summary.json`, and a copy of the standalone
Python publisher. It does not require an input lockfile and does not fabricate
an npm installation lockfile.

Transfer the prepared directory to the airgap and publish:

```bash
export ARTIFACTORY_TOKEN='your-access-token'
python3 npm-node24-bundle/upload-npm-artifactory-bundle.py \
  --bundle-dir ./npm-node24-bundle \
  --registry-url "https://art.example.com/artifactory/api/npm/npm-local/" \
  --work-dir ./npm-upload
```

The Python publisher retains the sequential publishing and `latest` handling
documented below. Sanitization has already happened on the connected side.

For a TAR-only transfer, first extract it with Python's standard library:
`python3 -m tarfile -e ./npm-node24-bundle.tar ./transfer`. The extracted bundle
is `./transfer/npm-http-bundle`; use its uploader and that path with
`--bundle-dir`. If you already have the standalone uploader, you can instead
give it `--bundle-tar ./npm-node24-bundle.tar` directly.

### Dependency resolution contract

- Regular, optional, and peer dependency edges are followed recursively with no
  depth limit. Duplicate downloads and cycles are handled by package name and
  version. Multiple explicitly requested versions are preserved.
- Every version selection checks `engines.node` against your target Node
  version. Bare roots and root `latest` select the highest compatible stable
  version. Transitive `latest` prefers the compatible source tag, with fallback
  to the highest compatible stable version. Other named tags and exact versions
  do not fall back. Ranges use the included npm SemVer library.
- Dependency declarations using tags are rewritten to their selected exact
  versions, including npm aliases and bundled package manifests. This avoids
  relying on source-registry tags inside the airgap. The original requests and
  changes are recorded in `normalizedDependencyTags`; version ranges remain.
- Optional dependencies override same-name regular dependencies. Explicit
  target OS/CPU/libc constraints can exclude incompatible optional packages;
  omissions are recorded. Unspecified platform dimensions are not inferred
  from the connected host, so provide all three flags for a specific Linux
  destination.
- Bundled dependencies are inspected inside their parent archive, including
  their external dependency requirements. Source checksums and package identity
  are verified before archives are sanitized.
- A missing required package, incompatible required dependency, invalid
  checksum, authentication/download failure, or unsupported dependency source
  prevents a completed transfer bundle. Git, local-file, workspace, and direct
  URL dependency specifications need separate preparation. Published root or
  bundled `npm-shrinkwrap.json` files are rejected explicitly because their
  locked graph is not supported by this workflow. Archive links and ambiguous
  member paths are rejected before emitting a bundle.
  Previously downloaded packages and incomplete progress remain available.
- Root development dependencies can be included with
  `--include-dev-dependencies`; development dependencies of published libraries
  are not needed merely to mirror those libraries.

"Complete" means a complete selected registry dependency closure for the
requested target. This is a mirror builder, not npm's peer-placement and
installation-layout solver. The graph records separate peer requirements and
may include multiple versions; it does not certify that an arbitrary combined
application can install or build. Native binaries, browser downloads, and
other assets normally generated by install hooks still need target-specific
preparation, as described under limitations below.

For a private source registry, supply `--registry` with `NPM_TOKEN` (or
`NPM_USERNAME`/`NPM_PASSWORD`), or the corresponding command-line credentials.
`--ca-file` trusts an internal CA. Source credentials are separate from
`ARTIFACTORY_TOKEN`, which is used only by the offline publisher. This HTTP
workflow does not load npm's configuration or call npm for authentication.

## Upload a directory of npm packages

On the airgapped machine, point the Python script directly at your directory of
already-downloaded npm `.tgz` or `.tar.gz` files. No `packages.json`, project,
lockfile, or fetch-kit-specific input layout is required:

```bash
export ARTIFACTORY_TOKEN='your-access-token'
python3 upload-npm-artifactory-bundle.py \
  --packages-dir /media/transfer/npm-packages \
  --registry-url "https://art.example.com/artifactory/api/npm/npm-local/" \
  --sanitize-scripts \
  --work-dir ./npm-upload
```

The script searches subdirectories, reads the actual name and version from each
archive's `package/package.json`, and validates all packages before contacting
Artifactory. Filenames do not determine identity. The directory may contain
multiple versions of the same package and scoped packages. Each version is
published sequentially, followed by the `latest` reconciliation described below.

`--sanitize-scripts` removes `scripts`, `private`, and `publishConfig` from the
root and bundled dependency manifests and repacks copies in the work directory.
This removes publish/prepublish/prepare and install hooks without running them.
Original files are unchanged. Without this flag the original package bytes are
uploaded; direct API publication still never executes lifecycle scripts. The
airgapped uploader contacts only the configured internal registry and performs
no dependency downloads. Include all package versions you need in the directory.

Add `--dry-run` to inventory, validate, and sanitize without network requests.
Use `--latest-policy preserve` to keep the pre-upload `latest` value instead of
choosing the highest stable version available in the destination. Authentication
and internal CA options are the same as for transfer bundles below.

Byte-identical duplicates of a name/version are uploaded once. Different bytes
for the same name/version are rejected before any uploads. Other file types
are ignored; malformed package archives and symlink paths are rejected. Input
must be npm package archives, not an unpacked `node_modules` tree or an outer
transfer tar (use `--bundle-tar` for a fetch-kit transfer archive).

The work directory includes `discovered-packages.json` with source filenames,
computed checksums and duplicate paths, plus the normal `prepared-bundle` and
upload reports. These locally calculated checksums detect changes during
preparation; they do not verify the packages against an upstream lockfile or
trusted transfer manifest. Use `--bundle-dir` or `--bundle-tar` for bundles with
existing checksums you want verified. Directory mode ignores adjacent lockfiles
and manifests.

Keep output outside the input directory for repeat imports. The current work
directory is excluded from discovery, but older prepared bundles left beneath
the input directory are scanned like any other package archives.

## Existing npm CLI lockfile workflow (optional)

This older JavaScript entry point requires the npm CLI on the connected machine.
Use the HTTP package-list workflow above when npm is unavailable.

Use the project's **`package-lock.json`** (or npm shrinkwrap in the same format).
There is no need to copy an installed `node_modules` directory. The lockfile
records the resolved dependency tree, including transitive dependencies.

On the internet-connected machine:

```bash
node npm/soon-to-be-deprecated/download-npm-artifactory-bundle.js \
  --node-version 22.0.0 \
  --package-lock /path/to/project/package-lock.json \
  --destination-registry "https://art.example.com/artifactory/api/npm/npm-local/" \
  --tar-file ./npm-transfer.tar
```

Set `--node-version` to your target runtime. The connected machine needs Node.js,
npm, and tar. Source registry authentication uses normal npm configuration or
the existing `--registry`, `--userconfig`, and credential options.

On Windows, the downloader locates `npm`/`npm.cmd` on PATH and runs that
installation's `node_modules/npm/bin/npm-cli.js` through the current Node.js
executable. This avoids `spawnSync npm ENOENT` and `.cmd` launch errors. If npm
is absent from PATH, it also checks for npm bundled beside `node.exe`.

For a custom installation, use `--npm-bin` (or `NPM_BIN`) with the full path to
`npm-cli.js`, for example
`--npm-bin "C:\Program Files\nodejs\node_modules\npm\bin\npm-cli.js"`.
JavaScript entry points also work on macOS/Linux. The Windows automatic lookup
selects the CLI adjacent to the launcher; use an explicit CLI path if your
wrapper normally redirects to a different npm installation. A missing npm
installation still needs to be installed; a `tar` ENOENT error means `tar` must
be available on PATH as well.

Lock mode reads versions 1, 2, and 3 directly instead of resolving new versions.
It downloads the locked HTTP(S) tarballs, verifies original integrity values
when present (and warns when absent),
then removes `scripts`, `private`, and `publishConfig` before repacking. This
includes `prepublish`, `prepublishOnly`, `prepare`, pack/publish hooks, and
install hooks. Bundled package manifests are sanitized too. By default it also
removes `devDependencies` metadata inside dependencies; it still downloads dev
packages recorded in the project's lockfile. Multiple versions and npm aliases
are retained. Entries for other platforms are retained rather than filtered for
the connected host.

The bundle includes the source `package-lock.original.json` for audit and a
rewritten `package-lock.json` containing the sanitized tarballs' integrity
values. `--destination-registry` sets internal tarball URLs; without it, the
rewritten lock omits source `resolved` URLs so npm can use the configured
registry. The Python publisher also writes a lock with the upload registry URLs.
The input project and original lockfile are not modified.

Transfer `npm-transfer.tar` and `upload-npm-artifactory-bundle.py`, then run on
the airgapped machine:

```bash
export ARTIFACTORY_TOKEN='your-access-token'
python3 upload-npm-artifactory-bundle.py \
  --bundle-tar ./npm-transfer.tar \
  --registry-url "https://art.example.com/artifactory/api/npm/npm-local/" \
  --work-dir ./npm-upload
```

To sanitize a bundle made with older tooling, add `--sanitize-scripts`:

```bash
python3 upload-npm-artifactory-bundle.py \
  --bundle-tar ./older-npm-transfer.tar \
  --registry-url "https://art.example.com/artifactory/api/npm/npm-local/" \
  --work-dir ./npm-upload-fixed \
  --sanitize-scripts
```

This flag removes all scripts plus `private` and `publishConfig` from package
manifests, repacks only packages needing changes, and recalculates manifest and
lockfile hashes. It preserves runtime files and dependency relationships. The
original bundle remains unchanged. Without the flag, package bytes are preserved.
Neither mode executes package code or lifecycle hooks: publication is an HTTP
npm-registry request, not an `npm publish` subprocess.

Use `--bundle-dir` instead of `--bundle-tar` for an extracted bundle.
`--dry-run` validates and prepares output without making registry requests.
`--ca-file internal-ca.pem` trusts your organization's CA. Username/password
authentication uses `ARTIFACTORY_USERNAME` and `ARTIFACTORY_PASSWORD` or the
corresponding CLI flags. The destination should normally be a local npm
repository; a virtual repository needs a configured deployment target and
appropriate permissions.

The publisher verifies manifest hashes and package identity before contacting
the registry. Existing versions are skipped only when registry content hashes
match; a different artifact at the same name/version is an error. Each uploaded
version gets an `airgap-<version>` tag; `latest` is reconciled separately as
described below. Persistent results and the prepared bundle are written beneath
`--work-dir`, which must be
new or empty. Use a new work directory when retrying a previous upload; matching
versions will be skipped. Output includes:

```text
npm-upload/
  upload-summary.json
  upload-results.json
  prepared-bundle/
    package-lock.json
    package-lock.original.json
    packages.json
    tarballs/
```

The lock files are emitted when present in the input bundle. Read the summary
and use the prepared lock only after all required packages have uploaded
successfully. `--dry-run` prepares the same local files but does not establish
that anything exists in Artifactory.

For application installation, keep the project's own `package.json`, use the
publisher's prepared `package-lock.json`, and configure the internal registry:

```bash
npm ci --ignore-scripts --no-audit --no-fund \
  --registry "https://art.example.com/artifactory/api/npm/npm-local/"
```

Do not add `--offline` unless the npm cache is already populated: this install
needs to reach internal Artifactory. Authentication for installing is configured
separately in your project's/user's npm configuration.

### Sequential uploads and the `latest` tag

The Python publisher sends one package upload at a time, ordered by package
name and ascending semantic version (`2.9.0` before `2.10.0`, and prereleases
before the matching stable version). It always supplies an explicit
`airgap-<version>` tag. After all upload requests finish, it reconciles `latest`
for each package using fresh destination metadata and the npm dist-tag API.

The default, `--latest-policy computed`, selects the highest stable version
actually present in the destination, including versions already there before
this bundle. It does not lower a newer existing stable `latest`, and an existing
prerelease `latest` is preserved as an intentional release-channel choice.
New prereleases are never selected for `latest`. Build metadata does not affect
SemVer precedence; an existing tag at equal precedence is retained.

Use `--latest-policy preserve` to retain the exact pre-upload `latest` value,
including its absence. This can require restoring the tag: Artifactory can be
configured to choose the most recently uploaded package, even when upload order
does not match the desired release channel. An automatically created `latest`
is removed when the policy calls for it to remain absent, including a new
package containing only prereleases.

If any version of a package fails, that package's original tag is restored
instead of promoting a partially uploaded set. Successful packages can still
complete. Tag writes are verified with a fresh registry read; an error or a
different effective tag makes the run fail and is recorded in
`upload-summary.json` under `latestResults` and `latestFailed`. Dry runs make no
registry requests, so they defer the tag decision rather than inventing a
destination version.

Use the local deployment repository for this operation. Virtual repositories
may calculate their own effective `latest`. Run only one uploader/writer for
the same package at a time: npm's tag API does not provide an atomic
compare-and-swap, so sequential uploads within this script cannot coordinate
another process. A registry that refuses a requested tag update/removal or
overrides it during verification is reported as a failure.
Tag reconciliation is a final step, not an atomic registry transaction. A
registry may expose temporary automatic tag changes during the import; an
interrupted run may leave them in place until reconciliation is completed.

Here, highest stable means the highest stable version **available in your
mirror**, not npmjs.org's upstream `latest`. A lockfile does not capture upstream
distribution tags. See [npm tag behavior](https://docs.npmjs.com/adding-dist-tags-to-packages/),
[the npm dist-tag API implementation](https://github.com/npm/cli/blob/latest/lib/commands/dist-tag.js),
and [Artifactory's latest-version settings](https://docs.jfrog.com/artifactory/docs/npm-repositories).

### What a lockfile and sanitizer cannot supply

- The lockfile only covers packages actually recorded in it. Generate a complete
  lock for the target platforms; missing optional/native platform packages cannot
  be inferred from an incomplete lock. Git, local-file, and workspace inputs
  that cannot be mirrored faithfully are rejected rather than silently skipped.
- Browser downloads, native build outputs, system libraries, and assets fetched
  by lifecycle scripts are not automatically supplied. Removing a hook may make
  its package unusable until those assets are prepared for the target OS, CPU,
  libc, and Node ABI. Validate your application on a representative target.
- npm can infer a `node-gyp rebuild` install step from `binding.gyp` even after
  `scripts` is removed. Use `--ignore-scripts` when installing. This also suppresses
  hooks in your application's unchanged root `package.json`.
- Sanitized archives differ from upstream: their original integrity values and
  registry signatures no longer describe them. Use the rewritten lock and a
  dedicated internal repository; preserve the original lock for provenance.
- Embedded shrinkwrap files or URL/git dependency specifications may still
  point outside the internal registry. The transfer does not rewrite arbitrary
  package source code or runtime network behavior. Review such packages before
  relying on a completely offline application.
- The Python uploader rejects archive links and special files. Its publish
  request holds a tarball and its base64 attachment in memory, so very large
  individual packages need adequate memory. The downloader rejects unsupported
  tar formats, including global PAX headers, with an explicit error.

References: [npm lockfile format](https://docs.npmjs.com/cli/v11/configuring-npm/package-lock-json/),
[npm lifecycle and implicit install scripts](https://docs.npmjs.com/cli/v11/using-npm/scripts/),
[npm's registry publish implementation](https://github.com/npm/cli/blob/latest/workspaces/libnpmpublish/lib/publish.js),
and [JFrog npm repository configuration](https://docs.jfrog.com/artifactory/docs/npm-repositories).

### Validation

The HTTP downloader and Python uploader can be tested without npm:

```bash
python3 -B npm/tests/test_npm_http_bundle.py
python3 -B npm/tests/test_upload_npm_artifactory_bundle.py
```

The HTTP fixtures launch Node with an empty executable search path, select a
target Node newer than the host, and publish the resulting bundle using the
copied Python script after stopping the source registry. They cover deep
dependency graphs, aliases, bundled dependencies, sanitization, and latest tags.

The earlier npm CLI workflow retains its separate regression tests:

```bash
node npm/tests/test-npm-launcher.js
node npm/tests/test-download-npm-artifactory-bundle.js
node npm/tests/test-download-npm-lock.js
python3 npm/tests/test_upload_npm_artifactory_bundle.py
python3 npm/tests/test_npm_lock_workflow.py
bash npm/tests/test-upload-npm-artifactory-bundle.sh
```

The Python publisher tests need only the standard library and a localhost port.
The end-to-end test also needs Node.js/npm. It creates a local source registry,
generates a real lockfile, downloads and publishes it, then installs with a
fresh npm cache after disconnecting the source registry. It covers a scoped npm
alias, nested multiple versions, and optional packages for another platform.
No test publishes to a real Artifactory instance; validate that final integration
with your repository and credentials.

## Existing npm CLI package-list workflow (optional)

This earlier downloader requires the npm CLI. Use the HTTP-only workflow at the
top of this document when npm is unavailable.

Download the latest compatible versions for a target Node.js version:

```bash
node npm/soon-to-be-deprecated/download-npm-artifactory-bundle.js \
  --node-version 20.11.1 \
  react \
  lodash \
  @storybook/test-runner
```

Download one exact package version for a target Node.js version:

```bash
node npm/soon-to-be-deprecated/download-npm-artifactory-bundle.js \
  --node-version 20.11.1 \
  react@18.2.0
```

Download a package list for a target Node.js version:

```bash
node npm/soon-to-be-deprecated/download-npm-artifactory-bundle.js \
  --node-version 20.11.1 \
  --packages-file packages-node-20.txt
```

Download for a specific airgapped npm platform:

```bash
node npm/soon-to-be-deprecated/download-npm-artifactory-bundle.js \
  --node-version 20.11.1 \
  --target-os linux \
  --target-arch x64 \
  --target-libc glibc \
  --packages-file packages-node-20.txt
```

Download everything already recorded for that same Node.js version:

```bash
node npm/soon-to-be-deprecated/download-npm-artifactory-bundle.js \
  --node-version 20.11.1 \
  --update-all
```

Use a private registry:

```bash
node npm/soon-to-be-deprecated/download-npm-artifactory-bundle.js \
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
  package-lock.original.json
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
`package/package.json` was sanitized and validated.

`artifactory-upload-manifest.tsv` is the minimal uploader input:

```text
name    version    tarball
```

## Legacy Bash npm registry uploader

`upload-npm-artifactory-bundle.sh` is intentionally separate from the transfer
tar. Copy and maintain that Bash script in the airgapped environment, then
point it at each transfer tar.

The uploader is registry-generic despite the file name. It only uses npm CLI
operations: `npm view <package> versions --json` to inspect the target registry
and `npm publish <tarball> --tag <tag> --ignore-scripts=true` to upload. That
means the latest-tag logic applies to Artifactory and to other npm-compatible
registries that support those standard npm operations. If the target registry
cannot answer the version query for a package, the default behavior is to avoid
`latest` for that package.

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
those already-packed tarballs. npm package sanitization and validation happen on
the internet-connected downloader side: every tarball is repacked before it is
added to the transfer bundle, then checked to confirm `package/package.json`
contains the expected package name and version.

The downloader always removes publish-time metadata that can redirect, block, or
execute work during airgapped upload:

- `scripts`, including publish lifecycle hooks such as `prepublishOnly`,
  `prepare`, `prepack`, `publish`, and `postpublish`.
- `private`, which would make `npm publish` refuse the package.
- `publishConfig`, which can override publish-time registry, tag, access, and
  other npm config values.

Airgapped uploads do not run package lifecycle scripts. The uploader forces
`--ignore-scripts=true` after any custom `--npm-flags` and sets
`npm_config_ignore_scripts=true` for the `npm publish` process. That blocks
`prepublish`, `prepublishOnly`, `prepare`, `publish`, `postpublish`, and other
package scripts from attempting build steps or network calls during upload.

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
node npm/soon-to-be-deprecated/download-npm-artifactory-bundle.js \
  --node-version 20.11.1 \
  --target-arch arm64 \
  @company/app
```

For Linux targets, prefer setting the full npm platform:

```bash
node npm/soon-to-be-deprecated/download-npm-artifactory-bundle.js \
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

Packed tarballs are sanitized before they are added to the transfer tar. The
sanitizer always removes publish-blocking metadata from `package/package.json`
and repacks with `tar`. By default, the library normalizer also removes
`devDependencies`.

This removes explicit build, test, prepare, install, and postinstall scripts.
Packages whose required runtime files are already present remain usable; packages
that need install-time compilation or downloads require separate preparation.
Runtime fields and dependencies are kept, including `main`, `module`, `types`,
`exports`, `dependencies`, `peerDependencies`, and `optionalDependencies`.

`--no-normalize-library-package` keeps non-publish runtime metadata closer to the
source tarball, including `devDependencies`, but it still removes `scripts`,
`private`, and `publishConfig` so the airgapped upload remains publish-safe.

Use these only when your runtime does not need those dependency relationships:

```bash
node npm/soon-to-be-deprecated/download-npm-artifactory-bundle.js \
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
