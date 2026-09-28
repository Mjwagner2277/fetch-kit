# Vendored runtime libraries

`semver/` contains the unmodified runtime files of npm's `semver` library,
version 7.8.5. Its ISC license is included at `semver/LICENSE`.
Upstream: https://github.com/npm/node-semver.

The HTTP-only downloader uses this local copy to resolve npm version ranges and
check the requested Node version without installing dependencies or calling npm.
Keep this directory beside the downloader when copying the connected-side tool.
No vendor lifecycle scripts are executed.

`semver-provenance.json` records the source version and SHA-256 of each copied
file. The command-line wrapper `bin/semver.js` was not copied because only the
library API is used.
