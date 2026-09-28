#!/usr/bin/env node
'use strict';

// HTTP-only registry closure builder. No npm CLI, package scripts, shell, or
// external archive program is executed. Node 16+ runs this tool independently
// of the Node version selected for the destination.
const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');
const tls = require('tls');
const zlib = require('zlib');
const crypto = require('crypto');
const semver = require('./vendor/semver');
const {
  readPackagesFile, sanitizeTarballForAirgapPublish, validatePackageTarball,
  readTarRecords, verifyOriginalIntegrity, hashFile, safeTarballName,
  encodeTarRecord
} = require('./lib/package-archives.js');

const RESOLUTION_MODEL = 'Registry dependency closure for offline publishing; not an npm installation tree or peer-placement plan.';
const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
const log = (message) => process.stderr.write(`${message}\n`);
const json = (file, value) => {
  const temporary = `${file}.${crypto.randomBytes(8).toString('hex')}.tmp`;
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`);
    fs.renameSync(temporary, file);
  } finally {
    try { fs.rmSync(temporary, { force: true }); } catch (_) { /* Preserve the original write error. */ }
  }
};
const INCOMPLETE = 'npm-bundle.INCOMPLETE';
const DOWNLOAD_STATE = 'download-state.json';
const resolutionKey = (edge) => JSON.stringify([edge.from, edge.kind, edge.name, edge.installName, edge.requested]);

class CompatibilityError extends Error {}

function isWithinDirectory(directory, candidate, pathApi = path) {
  const relative = pathApi.relative(directory, candidate);
  return relative === '' || (relative !== '..' && !relative.startsWith('..' + pathApi.sep) && !pathApi.isAbsolute(relative));
}

function help() {
  return `Usage: node download-npm-http-bundle.js --node-version VERSION [options] [package@range ...]

Download, resolve, verify, and sanitize npm packages using HTTP and Node builtins.
The local Node runtime may be older than the target. No npm CLI is required.

  --node-version VERSION       Required target Node version, e.g. 24.0.0
  --packages-file FILE         Package list; repeatable (text or JSON)
  --package SPEC               Root package; repeatable, or use positional specs
  --registry URL               Source registry (default https://registry.npmjs.org/)
  --token TOKEN                Source token (default NPM_TOKEN)
  --username USER              Source basic-auth user (default NPM_USERNAME)
  --password PASSWORD          Source password (default NPM_PASSWORD)
  --target-os OS               Filter package os constraints (e.g. linux)
  --target-arch ARCH           Filter package cpu constraints (e.g. x64)
  --target-libc LIBC           Filter package libc constraints (glibc or musl)
  --include-dev-dependencies   Also include direct root devDependencies
  --ca-file FILE               Additional trusted PEM certificates
  --no-ssl                     Explicitly disable TLS certificate verification
  --output-dir DIR             Live package directory; retained on error
  --tar-file FILE              New uncompressed transfer TAR (no overwrite)
  --cache-dir DIR              Verified source cache (default OUTPUT-DIR.cache)
  --resume                     Resume an incomplete output directory
  --update                     Add package requests to an existing bundle
  --help                      Show this help

Bare roots and @latest select the highest stable version compatible with the
target Node/platform. Other named tags remain exact. Dependencies, optional
dependencies, and peers are walked without a depth limit. Optional target-
incompatible edges are reported as omissions; network/auth/integrity failures
are fatal. Unspecified platform dimensions are unfiltered, never host-derived.
Scripts/private/publishConfig/devDependencies are removed from package copies.
No npmrc is read. Source credentials are scoped to the configured registry.
Downloads and progress are saved as the run proceeds. After an error, rerun
the same command with --resume to reuse verified downloads. Use --update and
a new --tar-file to extend an existing bundle; previous roots are retained.
download-state.json remembers requests, cache location, and verified downloads.
Registry metadata is refreshed; matching cached tarballs are not downloaded.
Updates preserve previous selections; add an explicit version to include a new
version of an existing root. State belongs to the requested target Node/platform.
Only complete dependency closures produce a publishable bundle and transfer TAR.
`;
}

function parseArgs(argv, env = process.env) {
  const options = {
    packageSpecs: [], packagesFiles: [], registry: 'https://registry.npmjs.org/',
    token: env.NPM_TOKEN || '', username: env.NPM_USERNAME || '', password: env.NPM_PASSWORD || '',
    targetOs: '', targetArch: '', targetLibc: '', strictSsl: true,
    normalizeLibraryPackage: true, stripPeerDependencies: false, stripOptionalDependencies: false,
    includeDevDependencies: false
  };
  const flags = {
    '--node-version': 'nodeVersion', '--registry': 'registry', '--token': 'token',
    '--username': 'username', '--password': 'password', '--target-os': 'targetOs',
    '--target-arch': 'targetArch', '--target-libc': 'targetLibc', '--ca-file': 'caFile',
    '--output-dir': 'outputDir', '--tar-file': 'tarFile', '--cache-dir': 'cacheDir'
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--help' || arg === '-h') { options.help = true; continue; }
    if (arg === '--no-ssl') { options.strictSsl = false; continue; }
    if (arg === '--include-dev-dependencies') { options.includeDevDependencies = true; continue; }
    if (arg === '--resume') { options.resume = true; continue; }
    if (arg === '--update') { options.update = true; continue; }
    if (arg === '--') { options.packageSpecs.push(...argv.slice(index + 1)); break; }
    if (own(flags, arg) || arg === '--package' || arg === '--packages-file') {
      const value = argv[++index];
      if (!value || value.startsWith('--')) throw new Error(`Missing value for ${arg}`);
      if (arg === '--package') options.packageSpecs.push(value);
      else if (arg === '--packages-file') options.packagesFiles.push(value);
      else options[flags[arg]] = value;
      continue;
    }
    if (arg.startsWith('-')) throw new Error(`Unknown option: ${arg}`);
    options.packageSpecs.push(arg);
  }
  if (options.help) return options;
  if (options.resume && options.update) throw new Error('Choose --resume or --update, not both');
  options.nodeVersion = semver.valid(options.nodeVersion || '');
  if (!options.nodeVersion) throw new Error('--node-version requires a full target version, e.g. 24.0.0');
  options.registryUrl = checkedUrl(options.registry);
  options.registryUrl.search = '';
  options.registryUrl.hash = '';
  if (!options.registryUrl.pathname.endsWith('/')) options.registryUrl.pathname += '/';
  options.registry = options.registryUrl.href;
  if ((options.username && !options.password) || (!options.username && options.password)) throw new Error('Source basic authentication requires both --username and --password (or NPM_USERNAME/NPM_PASSWORD)');
  if (options.token && options.username) throw new Error('Choose token or basic source authentication, not both');
  if (options.caFile) options.ca = [...tls.rootCertificates, fs.readFileSync(path.resolve(options.caFile))];
  options.packageSpecs.push(...options.packagesFiles.flatMap(readPackagesFile));
  if (!options.packageSpecs.length && !options.resume && !options.update) throw new Error('Supply at least one --package, --packages-file, or positional package');
  options.packageSpecs.forEach((spec) => parseRequest(spec));
  options.packageSpecs = [...new Set(options.packageSpecs)];
  const defaultName = `npm-http-bundle-node-v${options.nodeVersion}`;
  options.tarFile = path.resolve(options.tarFile || `${defaultName}.tar`);
  options.outputDir = path.resolve(options.outputDir || options.tarFile.replace(/\.tar$/i, '') + (options.tarFile.endsWith('.tar') ? '' : '-bundle'));
  options.resumeProfile = {
    nodeVersion: options.nodeVersion, registry: options.registry,
    targetOs: options.targetOs, targetArch: options.targetArch, targetLibc: options.targetLibc,
    includeDevDependencies: options.includeDevDependencies, packageSpecs: options.packageSpecs
  };
  if (fs.existsSync(options.outputDir)) {
    if (!options.resume && !options.update) throw new Error(`Output directory already exists: ${options.outputDir}. Use --resume for an incomplete run or --update to add packages.`);
    if (fs.lstatSync(options.outputDir).isSymbolicLink() || !fs.statSync(options.outputDir).isDirectory()) throw new Error('--resume/--update requires a real bundle directory');
    if (options.resume && !fs.existsSync(path.join(options.outputDir, INCOMPLETE))) throw new Error('Output is already complete or is not a resumable HTTP bundle; use --update to extend it');
    let previous;
    const stateFile = path.join(options.outputDir, DOWNLOAD_STATE);
    // Older HTTP bundles have the same profile in summary.json. Their existing
    // source cache is reusable, and the first update adds the explicit state.
    const previousFile = fs.existsSync(stateFile) ? stateFile : path.join(options.outputDir, 'summary.json');
    try { previous = JSON.parse(fs.readFileSync(previousFile, 'utf8')); }
    catch (_) { throw new Error('Cannot read the existing HTTP bundle state/summary for --resume/--update'); }
    const profile = previous && previous.resumeProfile;
    if (!previous || previous.inputMode !== 'http-package-list' || !profile || !Array.isArray(profile.packageSpecs) || !profile.packageSpecs.length ||
        (previousFile === stateFile && (previous.schemaVersion !== 1 || !Array.isArray(previous.packages)))) {
      throw new Error('Existing directory does not contain supported HTTP bundle download state');
    }
    profile.packageSpecs.forEach((spec) => parseRequest(spec));
    for (const key of ['nodeVersion', 'registry', 'targetOs', 'targetArch', 'targetLibc', 'includeDevDependencies']) {
      if (profile[key] !== options.resumeProfile[key]) throw new Error('--resume/--update requires the same source registry, target Node/platform, and dependency options; use a new output directory with --cache-dir to reuse downloads for a different target');
    }
    if (options.resume && options.packageSpecs.some((spec) => !profile.packageSpecs.includes(spec))) throw new Error('--resume cannot add package requests; use --update to extend the bundle');
    options.packageSpecs = [...new Set([...profile.packageSpecs, ...options.packageSpecs])];
    options.resumeProfile.packageSpecs = options.packageSpecs;
    options.previousDownloadState = previous;
    options.cacheDir = options.cacheDir || previous.cacheDir;
  } else if (options.resume || options.update) {
    throw new Error('--resume/--update output directory does not exist; omit the flag for a new run');
  }
  options.cacheDir = path.resolve(options.cacheDir || `${options.outputDir}.cache`);
  if (isWithinDirectory(options.outputDir, options.tarFile)) throw new Error('--tar-file must be outside --output-dir');
  if (isWithinDirectory(options.outputDir, options.cacheDir) || isWithinDirectory(options.cacheDir, options.outputDir)) throw new Error('--cache-dir and --output-dir must be separate directories');
  if (isWithinDirectory(options.cacheDir, options.tarFile)) throw new Error('--tar-file must be outside --cache-dir');
  if (fs.existsSync(options.tarFile)) throw new Error(`Transfer TAR already exists: ${options.tarFile}`);
  return options;
}

function checkedUrl(value, base) {
  let url;
  try { url = new URL(value, base); } catch (_) { throw new Error('Invalid HTTP registry or download URL'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw new Error('Only HTTP(S) URLs without embedded credentials are supported');
  return url;
}

function printableUrl(url) {
  return `${url.origin}${url.pathname}`; // Signed URL query values may be secrets.
}

function registryScoped(url, options) {
  if (url.origin !== options.registryUrl.origin) return false;
  try {
    const actual = path.posix.normalize(decodeURIComponent(url.pathname));
    const scope = path.posix.normalize(decodeURIComponent(options.registryUrl.pathname));
    return actual.startsWith(scope.endsWith('/') ? scope : scope + '/');
  } catch (_) { return false; }
}

function requestBytes(url, options, redirects = 0) {
  const headers = { accept: 'application/json, application/octet-stream;q=0.9, */*;q=0.8', 'accept-encoding': 'identity', 'user-agent': 'fetch-kit-http-bundle/1' };
  if (registryScoped(url, options)) {
    if (options.token) headers.authorization = `Bearer ${options.token}`;
    else if (options.username) headers.authorization = `Basic ${Buffer.from(`${options.username}:${options.password}`).toString('base64')}`;
  }
  return new Promise((resolve, reject) => {
    const transport = url.protocol === 'https:' ? https : http;
    const request = transport.request(url, { headers, rejectUnauthorized: options.strictSsl, ca: options.ca }, (response) => {
      if ([301, 302, 303, 307, 308].includes(response.statusCode)) {
        response.resume();
        if (!response.headers.location || redirects >= 5) { reject(new Error(`Invalid or excessive redirect from ${printableUrl(url)}`)); return; }
        let next;
        try {
          next = checkedUrl(response.headers.location, url);
          if (url.protocol === 'https:' && next.protocol !== 'https:') throw new Error('HTTPS download redirect to HTTP is not allowed');
        } catch (error) { reject(error); return; }
        resolve(requestBytes(next, options, redirects + 1));
        return;
      }
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error(`HTTP ${response.statusCode} from ${printableUrl(url)}`));
        return;
      }
      const chunks = [];
      let total = 0;
      response.on('data', (chunk) => {
        total += chunk.length;
        if (total > 1024 * 1024 * 1024) { response.destroy(new Error('HTTP response exceeds 1 GiB safety limit')); return; }
        chunks.push(chunk);
      });
      response.on('error', reject);
      response.on('end', () => {
        try {
          const bytes = Buffer.concat(chunks);
          const encoding = String(response.headers['content-encoding'] || 'identity').toLowerCase();
          if (encoding === 'gzip') resolve(zlib.gunzipSync(bytes));
          else if (encoding === 'deflate') resolve(zlib.inflateSync(bytes));
          else if (encoding === 'identity') resolve(bytes);
          else reject(new Error(`Unsupported HTTP content encoding: ${encoding}`));
        } catch (error) { reject(error); }
      });
    });
    request.setTimeout(120000, () => request.destroy(new Error(`HTTP request timed out: ${printableUrl(url)}`)));
    request.on('error', (error) => reject(new Error(`HTTP request failed for ${printableUrl(url)}: ${error.code || 'connection error'}`)));
    request.end();
  });
}

function splitSpec(spec) {
  const text = String(spec || '').trim();
  const separator = text.indexOf('@', text.startsWith('@') ? text.indexOf('/') + 1 : 0);
  return separator > 0 ? { name: text.slice(0, separator), requested: text.slice(separator + 1) || 'latest' } : { name: text, requested: 'latest' };
}

function validName(name) {
  return typeof name === 'string' && /^(?:@[A-Za-z0-9._~-]+\/)?[A-Za-z0-9._~-]+$/.test(name) && name.split('/').every((part) => !['.', '..'].includes(part.replace(/^@+/, '')));
}

function canonicalVersion(version) {
  if (typeof version !== 'string') return false;
  const parsed = semver.parse(version);
  // semver.valid() removes build metadata; retain legitimate +build versions
  // while rejecting v-prefixed/whitespace forms the Python publisher rejects.
  return Boolean(parsed && `${parsed.version}${parsed.build.length ? '+' + parsed.build.join('.') : ''}` === version);
}

function parseRequest(nameOrSpec, requested) {
  const parsed = requested === undefined ? splitSpec(nameOrSpec) : { name: nameOrSpec, requested };
  if (!validName(parsed.name)) throw new Error(`Unsupported package name or dependency spec: ${parsed.name}`);
  if (typeof parsed.requested !== 'string') throw new Error(`Dependency spec for ${parsed.name} must be a string`);
  const installName = parsed.name;
  let name = parsed.name;
  let requirement = parsed.requested.trim() || '*';
  if (requirement.startsWith('npm:')) {
    const alias = splitSpec(requirement.slice(4));
    name = alias.name;
    requirement = alias.requested;
    if (!validName(name)) throw new Error(`Invalid npm alias for ${installName}`);
  }
  if (!semver.validRange(requirement) && !/^[A-Za-z][A-Za-z0-9._-]*$/.test(requirement)) {
    throw new Error(`Unsupported dependency spec ${installName}@${parsed.requested}; only registry versions, ranges, tags, and npm aliases are supported`);
  }
  return { name, installName, requested: requirement, originalRequested: parsed.requested, alias: name === installName ? null : installName };
}

function platformCompatible(constraint, target, field) {
  if (!target || constraint === undefined) return '';
  const allowed = typeof constraint === 'string' ? [constraint] : constraint;
  if (!Array.isArray(allowed) || allowed.some((item) => typeof item !== 'string')) return `invalid ${field} constraint`;
  if (allowed.includes('!' + target) || allowed.includes('!any')) return `${field} excludes ${target}`;
  const positives = allowed.filter((item) => !item.startsWith('!'));
  if (positives.length && !positives.includes(target) && !positives.includes('any')) return `${field} requires ${positives.join('|')}, target is ${target}`;
  return '';
}

function incompatibility(manifest, options) {
  const range = manifest.engines && manifest.engines.node;
  if (range !== undefined && (typeof range !== 'string' || !semver.validRange(range) || !semver.satisfies(options.nodeVersion, range, { includePrerelease: true }))) return `engines.node ${JSON.stringify(range)} does not support Node ${options.nodeVersion}`;
  return platformCompatible(manifest.os, options.targetOs, 'os') || platformCompatible(manifest.cpu, options.targetArch, 'cpu') || platformCompatible(manifest.libc, options.targetLibc, 'libc');
}

function selectVersion(metadata, request, options, rejected = new Map()) {
  const versions = metadata.versions;
  if (!versions || typeof versions !== 'object' || Array.isArray(versions)) throw new Error(`Registry metadata has no versions for ${request.name}`);
  const latest = request.requested === 'latest';
  const latestRoot = request.kind === 'root' && latest;
  const range = semver.validRange(request.requested);
  let candidates;
  if (latest) candidates = Object.keys(versions).filter((version) => semver.valid(version) && !semver.prerelease(version));
  else if (range) candidates = Object.keys(versions).filter((version) => semver.valid(version) && semver.satisfies(version, range));
  else {
    const tags = metadata['dist-tags'] || {};
    if (!own(tags, request.requested) || !own(versions, tags[request.requested])) throw new Error(`Unknown or unresolved tag ${request.name}@${request.requested}`);
    if (typeof tags[request.requested] !== 'string' || !semver.valid(tags[request.requested])) throw new Error(`Registry tag ${request.name}@${request.requested} does not identify a valid semantic version`);
    candidates = [tags[request.requested]];
  }
  candidates.sort(semver.rcompare);
  if (latest && !latestRoot) {
    const tagged = (metadata['dist-tags'] || {}).latest;
    if (typeof tagged === 'string' && semver.valid(tagged) && own(versions, tagged)) {
      candidates = [tagged, ...candidates.filter((version) => version !== tagged)];
    }
  }
  if (!candidates.length) throw new Error(`No version of ${request.name} satisfies ${request.requested}`);
  const reasons = [];
  for (const version of candidates) {
    const manifest = versions[version];
    if (!manifest || typeof manifest !== 'object') throw new Error(`Invalid version metadata for ${request.name}@${version}`);
    const reason = rejected.get(version) || incompatibility(manifest, options);
    if (reason) { reasons.push(`${version}: ${reason}`); continue; }
    return version;
  }
  throw new CompatibilityError(`No target-compatible version of ${request.name}@${request.requested}: ${reasons.slice(0, 6).join('; ')}${reasons.length > 6 ? '; ...' : ''}`);
}

function collectDependencies(manifest, options = {}) {
  const result = [];
  const dependencies = manifest.dependencies || {};
  const optional = manifest.optionalDependencies || {};
  const sections = ['dependencies', 'optionalDependencies', 'peerDependencies'];
  if (options.includeDevDependencies) sections.push('devDependencies');
  for (const section of sections) {
    const entries = manifest[section];
    if (entries === undefined) continue;
    if (!entries || typeof entries !== 'object' || Array.isArray(entries)) throw new Error(`Invalid ${section} in ${manifest.name}@${manifest.version}`);
    for (const [name, spec] of Object.entries(entries)) {
      if (section === 'dependencies' && own(optional, name)) continue;
      // Root development names that are also runtime dependencies are already
      // represented by the runtime request, as in a normal package manifest.
      if (section === 'devDependencies' && (own(dependencies, name) || own(optional, name))) continue;
      const peerOptional = section === 'peerDependencies' && manifest.peerDependenciesMeta && manifest.peerDependenciesMeta[name] && manifest.peerDependenciesMeta[name].optional === true;
      result.push({ ...parseRequest(name, spec), kind: section, optional: section === 'optionalDependencies' || Boolean(peerOptional) });
    }
  }
  return result;
}

function readArchiveManifests(file, pkg) {
  const manifests = new Map();
  for (const record of readTarRecords(file)) {
    if (['x', 'L', 'K'].includes(record.type)) continue;
    if (['1', '2'].includes(record.type)) throw new Error(`Archive links are unsupported by the offline publisher: ${pkg.key}: ${record.name}`);
    const canonical = path.posix.normalize(record.name);
    if (canonical !== record.name || record.name.split('/').includes('.')) throw new Error(`Noncanonical archive member path in ${pkg.key}: ${record.name}`);
    if (/^package\/(?:node_modules\/(?:@[^/]+\/)?[^/]+\/)*npm-shrinkwrap\.json$/.test(record.name)) throw new Error(`Published npm-shrinkwrap.json is unsupported by HTTP graph resolution: ${pkg.key}: ${record.name}; its locked dependencies require a lock-aware workflow`);
    if (!/^package\/(?:node_modules\/(?:@[^/]+\/)?[^/]+\/)*package\.json$/.test(record.name)) continue;
    if (record.type !== '0') throw new Error(`Package manifest is not a regular file: ${record.name}`);
    let manifest;
    try { manifest = JSON.parse(record.data.toString('utf8')); } catch (_) { throw new Error(`Invalid package JSON in ${pkg.key}: ${record.name}`); }
    if (!manifest || typeof manifest !== 'object' || !validName(manifest.name) || !canonicalVersion(manifest.version)) throw new Error(`Invalid package identity in ${pkg.key}: ${record.name}`);
    manifests.set(record.name, manifest);
  }
  validatePackageTarball(pkg, file);
  return manifests;
}

function encodePaxFields(fields) {
  return Buffer.concat(Object.entries(fields).map(([key, value]) => {
    const body = ` ${key}=${value}\n`;
    let length = Buffer.byteLength(body) + 1;
    while (String(length).length + Buffer.byteLength(body) !== length) length = String(length).length + Buffer.byteLength(body);
    return Buffer.from(`${length}${body}`);
  }));
}

function normalizeDependencyTags(file, changes) {
  if (!changes.length) return [];
  const records = readTarRecords(file);
  const applied = [];
  for (const record of records) {
    const matching = changes.filter((change) => change.manifestPath === record.name);
    if (!matching.length) continue;
    const manifest = JSON.parse(record.data.toString('utf8'));
    let changed = false;
    for (const change of matching) {
      // Development declarations were removed by library normalization. Keep
      // their resolved packages available without adding the declarations back.
      if (!manifest[change.section] || !own(manifest[change.section], change.installName)) continue;
      manifest[change.section][change.installName] = change.spec;
      applied.push(change);
      changed = true;
    }
    if (!changed) continue;
    record.data = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`);
    if (record.paxRecord && own(record.pax, 'size')) {
      delete record.pax.size;
      record.paxRecord.data = encodePaxFields(record.pax);
    }
  }
  if (applied.length) {
    const temporary = `${file}.${crypto.randomBytes(8).toString('hex')}.tmp`;
    try {
      fs.writeFileSync(temporary, zlib.gzipSync(Buffer.concat([...records.map(encodeTarRecord), Buffer.alloc(1024)]), { level: 9 }));
      fs.renameSync(temporary, file);
    } finally {
      try { fs.rmSync(temporary, { force: true }); } catch (_) { /* Retain the original error. */ }
    }
  }
  return applied;
}

function bundledLookup(manifests, manifestPath, installName) {
  let directory = path.posix.dirname(manifestPath);
  while (true) {
    const candidate = `${directory}/node_modules/${installName}/package.json`;
    if (manifests.has(candidate)) return candidate;
    if (directory === 'package') return null;
    const parent = directory.lastIndexOf('/node_modules/');
    if (parent < 0) return null;
    directory = directory.slice(0, parent);
  }
}

function validateBundledDeclarations(manifest, manifestPath, manifests) {
  const declaration = manifest.bundleDependencies === undefined ? manifest.bundledDependencies : manifest.bundleDependencies;
  if (!declaration || declaration === false) return;
  const names = declaration === true ? Object.keys({ ...manifest.dependencies, ...manifest.optionalDependencies }) : declaration;
  if (!Array.isArray(names) || names.some((name) => typeof name !== 'string' || !validName(name))) throw new Error(`Invalid bundleDependencies in ${manifest.name}@${manifest.version}`);
  for (const name of names) {
    if (!bundledLookup(manifests, manifestPath, name) && !own(manifest.optionalDependencies || {}, name)) throw new Error(`Declared bundled dependency is missing: ${manifest.name}@${manifest.version} -> ${name}`);
  }
}

function tarHeader(name, data) {
  const header = Buffer.alloc(512);
  let filename = name;
  let prefix = '';
  if (Buffer.byteLength(name) > 100) {
    // USTAR's prefix and filename fields support ordinary long npm names.
    // Names beyond those limits receive a standard PAX path extension below.
    for (let slash = name.lastIndexOf('/'); slash >= 0; slash = name.lastIndexOf('/', slash - 1)) {
      if (Buffer.byteLength(name.slice(0, slash)) <= 155 && Buffer.byteLength(name.slice(slash + 1)) <= 100) {
        prefix = name.slice(0, slash);
        filename = name.slice(slash + 1);
        break;
      }
    }
  }
  let extendedHeader;
  if (Buffer.byteLength(filename) > 100) {
    const body = ` path=${name}\n`;
    let size = Buffer.byteLength(body) + 1;
    while (String(size).length + Buffer.byteLength(body) !== size) size = String(size).length + Buffer.byteLength(body);
    const paxData = Buffer.from(`${size}${body}`);
    const pax = tarHeader('npm-http-bundle/PaxHeader', paxData);
    const paxHeader = Buffer.from(pax.subarray(0, 512));
    paxHeader[156] = 'x'.charCodeAt(0);
    extendedHeader = encodeTarRecord({ header: paxHeader, data: paxData });
    filename = 'npm-http-bundle/package.tgz';
  }
  header.write(filename, 0, 100, 'utf8');
  if (prefix) header.write(prefix, 345, 155, 'utf8');
  header.write('0000644\0', 100, 8, 'ascii');
  header.write('0000000\0', 108, 8, 'ascii');
  header.write('0000000\0', 116, 8, 'ascii');
  header.write('00000000000\0', 136, 12, 'ascii');
  header[156] = 48;
  header.write('ustar\0', 257, 6, 'ascii');
  header.write('00', 263, 2, 'ascii');
  const record = encodeTarRecord({ header, data });
  return extendedHeader ? Buffer.concat([extendedHeader, record]) : record;
}

function createTransferTar(bundleDir, destination) {
  const entries = JSON.parse(fs.readFileSync(path.join(bundleDir, 'packages.json'), 'utf8'));
  const included = new Set(['README.txt', 'packages.json', 'packages.jsonl', 'summary.json',
    'dependency-graph.json', 'root-packages.json', 'upload-npm-artifactory-bundle.py',
    ...entries.map((entry) => entry.tarball)]);
  const descriptor = fs.openSync(destination, 'wx');
  try {
    for (const relative of [...included].sort()) {
      const record = tarHeader(`npm-http-bundle/${relative}`, fs.readFileSync(path.join(bundleDir, relative)));
      let written = 0;
      while (written < record.length) written += fs.writeSync(descriptor, record, written, record.length - written);
    }
    fs.writeSync(descriptor, Buffer.alloc(1024));
  } finally { fs.closeSync(descriptor); }
}

function commitTransferTar(source, destination) {
  try {
    fs.linkSync(source, destination);
  } catch (error) {
    // FAT/exFAT transfer media and some network shares do not support hard
    // links. Both paths refuse to overwrite another run's destination file.
    if (!['ENOTSUP', 'EOPNOTSUPP', 'ENOSYS', 'EPERM', 'EXDEV'].includes(error.code)) throw error;
    fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL);
  }
}

function safeError(error, options) {
  let message = String(error.message || error);
  for (const secret of [options.token, options.password]) {
    if (secret) message = message.split(secret).join('[redacted]');
  }
  return message.replace(/https?:\/\/[^\s"'<>]+/g, (value) => {
    try { return printableUrl(new URL(value)); } catch (_) { return '[URL redacted]'; }
  });
}

function progressSummary(options, state, status, error) {
  return {
    schemaVersion: 1, inputMode: 'http-package-list', resolutionModel: RESOLUTION_MODEL,
    status, closureComplete: false, resumeProfile: options.resumeProfile,
    nodeVersion: options.nodeVersion, targetNodeVersion: options.nodeVersion,
    hostNodeVersion: process.version, registry: options.registry,
    targetPlatform: { os: options.targetOs, arch: options.targetArch, libc: options.targetLibc },
    outputDir: options.outputDir, cacheDir: options.cacheDir, transferTarFile: options.tarFile,
    downloadStateFile: path.join(options.outputDir, DOWNLOAD_STATE),
    packageCount: state.packageCount || 0, sourceDownloadCount: state.downloads,
    reusedDownloadCount: state.cacheHits, updatedAt: new Date().toISOString(),
    ...(error ? { error: safeError(error, options) } : {})
  };
}

function saveDownloadState(options, state, status, error) {
  json(path.join(options.outputDir, DOWNLOAD_STATE), {
    schemaVersion: 1, inputMode: 'http-package-list', status,
    closureComplete: status === 'complete' || status === 'archive-failed',
    resumeProfile: options.resumeProfile, cacheDir: options.cacheDir,
    targetNodeVersion: options.nodeVersion,
    targetPlatform: { os: options.targetOs, arch: options.targetArch, libc: options.targetLibc },
    transferTarFile: options.tarFile, updatedAt: new Date().toISOString(),
    sourceDownloadCount: state.downloads, reusedDownloadCount: state.cacheHits,
    packages: [...state.cachedPackages.values()],
    preserveSelections: state.preserveSelections, resolutions: [...state.resolutions.values()],
    ...(error ? { error: safeError(error, options) } : {})
  });
}

function previousResolutions(options) {
  const previous = options.previousDownloadState;
  if (!previous) return [];
  if (Array.isArray(previous.resolutions)) return previous.resolutions;
  // Migrate selections from bundles created before download-state.json.
  const packages = new Map();
  const resolutions = new Map();
  for (const name of ['packages.json', 'partial-packages.json']) {
    const file = path.join(options.outputDir, name);
    if (!fs.existsSync(file)) continue;
    const entries = JSON.parse(fs.readFileSync(file, 'utf8'));
    for (const entry of entries) packages.set(entry.package, entry);
  }
  for (const name of ['dependency-graph.json', 'partial-dependency-graph.json']) {
    const file = path.join(options.outputDir, name);
    if (!fs.existsSync(file)) continue;
    const graph = JSON.parse(fs.readFileSync(file, 'utf8'));
    for (const edge of graph.edges) {
      const entry = packages.get(edge.to);
      if (edge.omitted) resolutions.set(resolutionKey(edge), {
        from: edge.from, kind: edge.kind, name: edge.name, installName: edge.installName,
        requested: edge.requested, omitted: true, reason: edge.reason
      });
      else if (!edge.bundled && entry) resolutions.set(resolutionKey(edge), {
        from: edge.from, kind: edge.kind, name: edge.name, installName: edge.installName,
        requested: edge.requested, version: entry.version, integrity: entry.registryIntegrity
      });
    }
  }
  return [...resolutions.values()];
}

async function buildBundle(options, stage, state) {
  const packageDir = path.join(stage, 'tarballs');
  fs.mkdirSync(packageDir, { recursive: true });
  const metadataCache = new Map();
  const archiveCache = new Map();
  const published = new Map();
  const roots = [];
  const edges = [];
  const omissions = [];
  const bundledPackages = [];
  const visitedManifests = new Set();
  const tagNormalizations = new Map();
  const queue = options.packageSpecs.map((spec) => ({ ...parseRequest(spec), kind: 'root', optional: false, from: null, path: [spec] }));

  state.checkpoint = (status = 'resolving', error) => {
    state.packageCount = published.size;
    saveDownloadState(options, state, status, error);
    json(path.join(stage, 'partial-packages.json'), [...published.values()]);
    json(path.join(stage, 'partial-dependency-graph.json'), {
      schemaVersion: 1, resolutionModel: RESOLUTION_MODEL, closureComplete: false,
      roots, edges, bundledPackages, omissions
    });
    json(path.join(stage, 'summary.json'), progressSummary(options, state, status, error));
  };
  state.checkpoint();

  async function metadataFor(name) {
    if (!metadataCache.has(name)) {
      log(`Reading registry metadata: ${name}`);
      const url = new URL(encodeURIComponent(name), options.registryUrl);
      const bytes = await requestBytes(url, options);
      let metadata;
      try { metadata = JSON.parse(bytes.toString('utf8')); } catch (_) { throw new Error(`Registry returned invalid JSON for ${name}`); }
      if (!metadata || typeof metadata !== 'object' || (metadata.name && metadata.name !== name)) throw new Error(`Registry metadata identity mismatch for ${name}`);
      metadataCache.set(name, metadata);
    }
    return metadataCache.get(name);
  }

  async function archiveFor(name, version, metadata, expectedIntegrity) {
    const key = `${name}@${version}`;
    if ((metadata.name && metadata.name !== name) || (metadata.version && metadata.version !== version)) throw new Error(`Registry version metadata identity mismatch for ${key}`);
    const dist = metadata.dist || {};
    if (!dist.tarball) throw new Error(`Registry metadata lacks dist.tarball for ${key}`);
    const tarballUrl = checkedUrl(dist.tarball, options.registryUrl);
    let registryIntegrity = dist.integrity;
    if (!registryIntegrity && typeof dist.shasum === 'string' && /^[a-fA-F0-9]{40}$/.test(dist.shasum)) registryIntegrity = `sha1-${Buffer.from(dist.shasum, 'hex').toString('base64')}`;
    if (!registryIntegrity) throw new Error(`Registry metadata lacks a supported integrity/shasum for ${key}; refusing an unverified download`);
    if (expectedIntegrity && registryIntegrity !== expectedIntegrity) throw new Error(`Source integrity changed for previously selected ${key}; refusing to replace an existing version during an update`);
    if (archiveCache.has(key)) return archiveCache.get(key);
    const cacheKey = crypto.createHash('sha256').update(JSON.stringify([options.registry, name, version, registryIntegrity])).digest('hex');
    const raw = path.join(options.cacheDir, `${cacheKey}.tgz`);
    let manifests;
    if (fs.existsSync(raw)) {
      try {
        if (fs.lstatSync(raw).isSymbolicLink() || !fs.statSync(raw).isFile()) throw new Error('Invalid cache file type');
        verifyOriginalIntegrity(raw, registryIntegrity, key);
        manifests = readArchiveManifests(raw, { key, name, version });
        state.cacheHits += 1;
        log(`Using verified cached download: ${key}`);
      } catch (_) {
        // Preserve rejected bytes for diagnosis without presenting them as a
        // usable tarball. Fresh metadata and the source digest remain required.
        fs.renameSync(raw, `${raw}.invalid-${crypto.randomBytes(6).toString('hex')}`);
        state.cachedPackages.delete(cacheKey);
        log(`Cached download failed validation; downloading again: ${key}`);
      }
    }
    if (!manifests) {
      log(`Downloading ${key}`);
      const incoming = `${raw}.${crypto.randomBytes(8).toString('hex')}.part`;
      fs.writeFileSync(incoming, await requestBytes(tarballUrl, options));
      verifyOriginalIntegrity(incoming, registryIntegrity, key);
      manifests = readArchiveManifests(incoming, { key, name, version });
      fs.renameSync(incoming, raw);
      state.downloads += 1;
      json(path.join(options.cacheDir, `${cacheKey}.json`), { name, version, registry: options.registry, integrity: registryIntegrity, tarball: `${cacheKey}.tgz` });
    }
    // Commit an explicit reusable inventory as each archive becomes durable.
    // It is an index, not a reason to trust bytes: reuse above always rechecks
    // the registry digest and archive identity, even when this record exists.
    state.cachedPackages.set(cacheKey, {
      name, version, registry: options.registry, integrity: registryIntegrity,
      cacheKey, tarball: `${cacheKey}.tgz`, bytes: fs.statSync(raw).size,
      verifiedAt: new Date().toISOString()
    });
    saveDownloadState(options, state, 'resolving');
    const result = { key, name, version, raw, manifests, manifest: manifests.get('package/package.json'), registryIntegrity, resolved: printableUrl(tarballUrl) };
    archiveCache.set(key, result);
    return result;
  }

  function walkManifest(archive, manifestPath, nodeKey, includeDev) {
    const visitKey = `${archive.key}::${manifestPath}`;
    // A package first encountered transitively can later be an explicit root;
    // walk root devDependencies separately in that case.
    const visitMode = visitKey + (includeDev ? ':with-dev' : ':runtime');
    if (visitedManifests.has(visitMode)) return;
    const runtimeVisited = visitedManifests.has(visitKey + ':runtime');
    visitedManifests.add(visitMode);
    const manifest = archive.manifests.get(manifestPath);
    validateBundledDeclarations(manifest, manifestPath, archive.manifests);
    for (const dependency of collectDependencies(manifest, { includeDevDependencies: includeDev })) {
      if (includeDev && runtimeVisited && dependency.kind !== 'devDependencies') continue;
      const bundledPath = bundledLookup(archive.manifests, manifestPath, dependency.installName);
      queue.push({ ...dependency, from: nodeKey, ownerArchive: archive, manifestPath, archive: bundledPath ? archive : undefined, bundledPath,
        path: [nodeKey, `${dependency.installName}@${dependency.originalRequested}`] });
    }
  }

  function recordTagNormalization(request, version) {
    if (!request.ownerArchive || semver.validRange(request.requested)) return;
    const spec = request.originalRequested.startsWith('npm:') ? `npm:${request.name}@${version}` : version;
    const change = { manifestPath: request.manifestPath, section: request.kind, installName: request.installName, requested: request.originalRequested, version, spec };
    const key = JSON.stringify([request.ownerArchive.key, request.manifestPath, request.kind, request.installName]);
    tagNormalizations.set(key, { owner: request.ownerArchive.key, ...change });
  }

  function registerBundled(archive) {
    for (const [manifestPath, manifest] of archive.manifests) {
      if (manifestPath === 'package/package.json') continue;
      const reason = incompatibility(manifest, options);
      if (reason) throw new Error(`Bundled fixed version ${manifest.name}@${manifest.version} in ${archive.key} is incompatible: ${reason}; use a compatible containing package version`);
      const key = `${archive.key}::${manifestPath}`;
      bundledPackages.push({ key, name: manifest.name, version: manifest.version, containedIn: archive.key, manifestPath });
      walkManifest(archive, manifestPath, key, false);
    }
  }

  for (let cursor = 0; cursor < queue.length; cursor += 1) {
    const request = queue[cursor];
    const edge = { from: request.from, to: null, name: request.name, installName: request.installName, requested: request.requested, kind: request.kind, optional: request.optional };
    try {
      if (request.bundledPath) {
        const manifest = request.archive.manifests.get(request.bundledPath);
        if (manifest.name !== request.name) throw new Error(`Bundled dependency identity mismatch for ${request.installName}: expected ${request.name}, got ${manifest.name}`);
        const range = semver.validRange(request.requested);
        if (range && !semver.satisfies(manifest.version, range)) throw new Error(`Bundled ${manifest.name}@${manifest.version} does not satisfy ${request.requested}`);
        const reason = incompatibility(manifest, options);
        if (reason) throw new CompatibilityError(`Bundled ${manifest.name}@${manifest.version}: ${reason}`);
        edge.to = `${request.archive.key}::${request.bundledPath}`;
        edge.bundled = true;
        edges.push(edge);
        recordTagNormalization(request, manifest.version);
        continue;
      }
      const pinned = state.pinnedResolutions.get(resolutionKey(edge));
      if (pinned && pinned.omitted) {
        if (!request.optional) throw new Error(`Saved omission is not optional: ${request.name}@${request.requested}`);
        edge.omitted = true;
        edge.reason = pinned.reason;
        omissions.push(edge);
        edges.push(edge);
        log(`Preserving optional target omission: ${request.from} -> ${request.name}@${request.requested}`);
        continue;
      }
      const metadata = await metadataFor(request.name);
      const rejected = new Map();
      let archive;
      while (true) {
        let version;
        if (pinned) {
          // Exact saved identities must not pass through SemVer range matching:
          // build metadata is ignored in precedence (1.0.0+a equals 1.0.0+b).
          version = pinned.version;
          const range = semver.validRange(request.requested);
          if (range && !semver.satisfies(version, range)) throw new Error(`Saved ${request.name}@${version} does not satisfy ${request.requested}`);
          if (!metadata.versions || !own(metadata.versions, version)) throw new Error(`Previously selected ${request.name}@${version} is no longer available in registry metadata`);
          if (!metadata.versions[version] || typeof metadata.versions[version] !== 'object' || Array.isArray(metadata.versions[version])) throw new Error(`Invalid version metadata for ${request.name}@${version}`);
          const reason = incompatibility(metadata.versions[version], options);
          if (reason) throw new Error(`Previously selected ${request.name}@${version} is incompatible with the saved target: ${reason}`);
        } else {
          version = selectVersion(metadata, request, options, rejected);
        }
        archive = await archiveFor(request.name, version, metadata.versions[version], pinned && pinned.integrity);
        const reason = incompatibility(archive.manifest, options);
        if (!reason) break;
        if (pinned) throw new Error(`Previously selected ${archive.key} archive is incompatible with the saved target: ${reason}`);
        rejected.set(version, `archive manifest: ${reason}`);
      }
      edge.to = archive.key;
      edges.push(edge);
      const selection = { from: edge.from, kind: edge.kind, name: edge.name,
        installName: edge.installName, requested: edge.requested,
        version: archive.version, integrity: archive.registryIntegrity };
      state.resolutions.set(resolutionKey(edge), selection);
      if (state.preserveSelections) state.pinnedResolutions.set(resolutionKey(edge), selection);
      recordTagNormalization(request, archive.version);
      if (request.kind === 'root') roots.push({ name: request.name, installName: request.installName, requested: request.requested, spec: `${request.installName}@${request.originalRequested}`, resolvedVersion: archive.version, resolvedSpec: archive.key });
      if (!published.has(archive.key)) {
        const tarballName = safeTarballName(archive.name, archive.version);
        const finalTarball = path.join(packageDir, tarballName);
        const preparingTarball = `${finalTarball}.${crypto.randomBytes(8).toString('hex')}.tmp`;
        let sanitization;
        try {
          sanitization = sanitizeTarballForAirgapPublish(archive.raw, preparingTarball, options);
          validatePackageTarball(archive, preparingTarball);
          fs.renameSync(preparingTarball, finalTarball);
        } finally {
          try { fs.rmSync(preparingTarball, { force: true }); } catch (_) { /* Retain the original error. */ }
        }
        const integrity = `sha512-${crypto.createHash('sha512').update(fs.readFileSync(finalTarball)).digest('base64')}`;
        const manifest = archive.manifest;
        published.set(archive.key, {
          name: archive.name, version: archive.version, package: archive.key,
          tarball: `tarballs/${tarballName}`, sha1: hashFile(finalTarball, 'sha1'),
          sha512: hashFile(finalTarball, 'sha512'), integrity, bytes: fs.statSync(finalTarball).size,
          resolved: archive.resolved, registryIntegrity: archive.registryIntegrity, originalIntegrityVerified: true,
          engines: manifest.engines || {}, enginesNode: (manifest.engines && manifest.engines.node) || '',
          engineCompatible: true, engineRangeSupported: true, normalized: true, publishSanitized: true,
          publishSanitizedFields: sanitization.removedFields, sanitizedPackages: sanitization.sanitizedPackages,
          offlineWarnings: sanitization.offlineWarnings, packageJsonValidated: true, root: false
        });
        for (const warning of sanitization.offlineWarnings) log(`WARNING: ${archive.key}: ${warning}`);
        registerBundled(archive);
        walkManifest(archive, 'package/package.json', archive.key, false);
        state.checkpoint();
        log(`Saved ${archive.key} (${published.size} prepared packages)`);
      }
      if (request.kind === 'root' && options.includeDevDependencies) walkManifest(archive, 'package/package.json', archive.key, true);
    } catch (error) {
      if (error instanceof CompatibilityError && request.optional && !request.bundledPath) {
        edge.omitted = true;
        edge.reason = error.message;
        omissions.push(edge);
        edges.push(edge);
        const omission = { from: edge.from, kind: edge.kind, name: edge.name,
          installName: edge.installName, requested: edge.requested, omitted: true, reason: edge.reason };
        state.resolutions.set(resolutionKey(edge), omission);
        if (state.preserveSelections) state.pinnedResolutions.set(resolutionKey(edge), omission);
        log(`OPTIONAL TARGET OMISSION: ${request.from} -> ${request.name}@${request.requested}: ${error.message}`);
        continue;
      }
      throw new Error(`${request.path.join(' -> ')}: ${error.message}`);
    }
  }

  const items = [...published.values()].sort((left, right) => left.name.localeCompare(right.name) || semver.compare(left.version, right.version));
  const rootKeys = new Set(roots.map((root) => root.resolvedSpec));
  for (const item of items) {
    item.root = rootKeys.has(item.package);
    const changes = [...tagNormalizations.values()].filter((change) => change.owner === item.package).map(({ owner, ...change }) => change);
    const finalTarball = path.join(stage, item.tarball);
    item.normalizedDependencyTags = normalizeDependencyTags(finalTarball, changes);
    if (item.normalizedDependencyTags.length) {
      item.sha1 = hashFile(finalTarball, 'sha1');
      item.sha512 = hashFile(finalTarball, 'sha512');
      item.integrity = `sha512-${crypto.createHash('sha512').update(fs.readFileSync(finalTarball)).digest('base64')}`;
      item.bytes = fs.statSync(finalTarball).size;
      validatePackageTarball({ ...item, key: item.package }, finalTarball);
    }
  }
  state.checkpoint();
  const selectedTarballs = new Set(items.map((item) => item.tarball));
  for (const previous of state.priorTarballs) {
    if (!selectedTarballs.has(previous)) fs.rmSync(path.join(stage, previous), { force: true });
  }
  json(path.join(stage, 'packages.json'), items);
  fs.writeFileSync(path.join(stage, 'packages.jsonl'), items.map((item) => JSON.stringify(item)).join('\n') + '\n');
  json(path.join(stage, 'root-packages.json'), roots);
  json(path.join(stage, 'dependency-graph.json'), { schemaVersion: 1, resolutionModel: RESOLUTION_MODEL, closureComplete: true, roots, edges, bundledPackages, omissions });
  const summary = {
    schemaVersion: 1, inputMode: 'http-package-list', resolutionModel: RESOLUTION_MODEL,
    status: 'complete', resumeProfile: options.resumeProfile, cacheDir: options.cacheDir,
    downloadStateFile: path.join(options.outputDir, DOWNLOAD_STATE),
    sourceDownloadCount: state.downloads, reusedDownloadCount: state.cacheHits,
    closureComplete: true, nodeVersion: options.nodeVersion, targetNodeVersion: options.nodeVersion,
    hostNodeVersion: process.version, registry: options.registry, strictSsl: options.strictSsl,
    targetPlatform: { os: options.targetOs, arch: options.targetArch, libc: options.targetLibc },
    unspecifiedPlatformDimensions: 'Unfiltered; not inferred from the connected host',
    rootPackageCount: roots.length, packageCount: items.length, bundledPackageCount: bundledPackages.length,
    includeOptionalDependencies: true, includePeerDependencies: true, includeDevDependencies: options.includeDevDependencies,
    normalized: true, publishSanitized: true, originalIntegrityVerified: true,
    optionalOmissionCount: omissions.length, omissions,
    normalizedDependencyTagCount: items.reduce((total, item) => total + item.normalizedDependencyTags.length, 0),
    offlineWarnings: items.flatMap((item) => item.offlineWarnings.map((warning) => `${item.package}: ${warning}`)),
    rootPackages: roots, outputDir: options.outputDir, transferTarFile: options.tarFile
  };
  json(path.join(stage, 'summary.json'), summary);
  fs.copyFileSync(path.join(__dirname, 'upload-npm-artifactory-bundle.py'), path.join(stage, 'upload-npm-artifactory-bundle.py'));
  fs.writeFileSync(path.join(stage, 'README.txt'), `HTTP-only npm offline publishing bundle\n\n${RESOLUTION_MODEL}\n\nAll included registry packages passed source digest and archive identity verification.\nPackage scripts, private, publishConfig, and devDependencies were removed from copies.\nRuntime, peer, and optional ranges remain. Dependency tags are pinned to selected\nexact versions (aliases preserved); packages.json records normalizedDependencyTags.\nReview summary.json omissions and offlineWarnings, especially native modules and\nassets formerly downloaded by hooks.\n\nPublish with Python 3 standard library (no npm required):\n  python3 upload-npm-artifactory-bundle.py --bundle-dir . --registry-url https://art.example.com/artifactory/api/npm/npm-local/ --work-dir ../npm-upload\nSet ARTIFACTORY_TOKEN in the airgapped environment. The uploader publishes serially\nand reconciles latest tags. Read --help for authentication and latest-tag policies.\n\nThis is a publishing closure, not a generated installation lockfile. Install your\nprojects against the destination registry with their own compatible package inputs.\nSelected roots may contain multiple versions of the same name. No package-lock.json\nor combined package.json is fabricated. See dependency-graph.json for each edge.\n`);
  return summary;
}

async function main(argv = process.argv.slice(2), env = process.env) {
  const options = parseArgs(argv, env);
  if (options.help) { process.stdout.write(help()); return; }
  if (!options.strictSsl) log('WARNING: TLS certificate verification is explicitly disabled.');
  const state = { downloads: 0, cacheHits: 0, priorTarballs: new Set(), cachedPackages: new Map(),
    resolutions: new Map(), pinnedResolutions: new Map(), preserveSelections: false };
  const previousState = options.previousDownloadState;
  state.preserveSelections = !!(options.update || (previousState && previousState.preserveSelections));
  if (state.preserveSelections) {
    for (const entry of previousResolutions(options)) {
      if (!entry || (entry.from !== null && typeof entry.from !== 'string') ||
          !['root', 'dependencies', 'optionalDependencies', 'peerDependencies', 'devDependencies'].includes(entry.kind) ||
          typeof entry.name !== 'string' || typeof entry.installName !== 'string' || typeof entry.requested !== 'string' ||
          (entry.omitted ? (entry.omitted !== true || entry.kind === 'root' || typeof entry.reason !== 'string') :
            (!canonicalVersion(entry.version) || typeof entry.integrity !== 'string'))) throw new Error('Invalid saved dependency selection in HTTP bundle state');
      state.pinnedResolutions.set(resolutionKey(entry), entry);
      state.resolutions.set(resolutionKey(entry), entry);
    }
  }
  if (previousState && previousState.cacheDir === options.cacheDir && Array.isArray(previousState.packages)) {
    for (const entry of previousState.packages) {
      if (entry && /^[a-f0-9]{64}$/.test(entry.cacheKey) && entry.tarball === `${entry.cacheKey}.tgz` &&
          entry.registry === options.registry && typeof entry.name === 'string' && typeof entry.version === 'string' && typeof entry.integrity === 'string') {
        state.cachedPackages.set(entry.cacheKey, {
          name: entry.name, version: entry.version, registry: entry.registry, integrity: entry.integrity,
          cacheKey: entry.cacheKey, tarball: entry.tarball, bytes: entry.bytes, verifiedAt: entry.verifiedAt
        });
      }
    }
  }
  if (options.resume || options.update) {
    for (const name of ['partial-packages.json', 'packages.json']) {
      try {
        const entries = JSON.parse(fs.readFileSync(path.join(options.outputDir, name), 'utf8'));
        if (Array.isArray(entries)) for (const entry of entries) {
          if (typeof entry.tarball === 'string' && /^tarballs\/[^/\\]+\.tgz$/.test(entry.tarball)) state.priorTarballs.add(entry.tarball);
        }
      } catch (_) { /* Cache validation, not old inventory, determines reuse. */ }
    }
    // A previous retry may have failed before restoring its inventory. Inspect
    // the durable files too, so obsolete selections never enter a complete run.
    const previousDirectory = path.join(options.outputDir, 'tarballs');
    if (fs.existsSync(previousDirectory) && !fs.lstatSync(previousDirectory).isSymbolicLink() && fs.statSync(previousDirectory).isDirectory()) {
      for (const name of fs.readdirSync(previousDirectory)) {
        if (/^[A-Za-z0-9._+-]+-[a-f0-9]{10}\.tgz$/.test(name)) state.priorTarballs.add(`tarballs/${name}`);
      }
    }
  }
  fs.mkdirSync(path.dirname(options.outputDir), { recursive: true });
  if (!options.resume && !options.update) fs.mkdirSync(options.outputDir);
  const incompleteFile = path.join(options.outputDir, INCOMPLETE);
  fs.writeFileSync(incompleteFile, 'Dependency resolution is incomplete. Do not publish this directory. Rerun the same downloader command with --resume.\n');
  let complete = false;
  let summary;
  let temporaryTar;
  log(`Live package directory: ${options.outputDir}`);
  log(`Verified source cache: ${options.cacheDir}`);
  log(`Persistent download state: ${path.join(options.outputDir, DOWNLOAD_STATE)}`);
  if (options.update) log(`Updating cumulative bundle: ${options.packageSpecs.length} root requests. Refreshing metadata; verified cached tarballs will be reused.`);
  try {
    saveDownloadState(options, state, 'resolving');
    json(path.join(options.outputDir, 'summary.json'), progressSummary(options, state, 'resolving'));
    // A prior interrupted finalization may have written some complete-manifest
    // files. The marker remains in place throughout this fresh graph walk.
    for (const name of ['packages.json', 'packages.jsonl', 'dependency-graph.json', 'root-packages.json']) {
      fs.rmSync(path.join(options.outputDir, name), { force: true });
    }
    const tarballs = path.join(options.outputDir, 'tarballs');
    if (fs.existsSync(tarballs) && (fs.lstatSync(tarballs).isSymbolicLink() || !fs.statSync(tarballs).isDirectory())) throw new Error('The bundle tarballs path must be a real directory');
    fs.mkdirSync(options.cacheDir, { recursive: true });
    if (fs.lstatSync(options.cacheDir).isSymbolicLink()) throw new Error('--cache-dir must be a real directory');
    summary = await buildBundle(options, options.outputDir, state);
    saveDownloadState(options, state, 'complete');
    for (const name of ['partial-packages.json', 'partial-dependency-graph.json']) fs.rmSync(path.join(options.outputDir, name), { force: true });
    // Remove this last: until now the publisher must reject even a directory
    // whose manifests happened to be written before interruption.
    fs.unlinkSync(incompleteFile);
    complete = true;
    fs.mkdirSync(path.dirname(options.tarFile), { recursive: true });
    temporaryTar = path.join(path.dirname(options.tarFile), `.npm-http-${crypto.randomBytes(10).toString('hex')}.tar`);
    createTransferTar(options.outputDir, temporaryTar);
    const transferTarSha256 = hashFile(temporaryTar, 'sha256');
    const transferTarBytes = fs.statSync(temporaryTar).size;
    commitTransferTar(temporaryTar, options.tarFile);
    const result = { ...summary, transferTarSha256, transferTarBytes };
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return result;
  } catch (error) {
    try {
      if (complete) {
        saveDownloadState(options, state, 'archive-failed', error);
        json(path.join(options.outputDir, 'summary.json'), { ...summary, status: 'archive-failed', error: safeError(error, options) });
      } else if (state.checkpoint) {
        state.checkpoint('failed', error);
      } else {
        saveDownloadState(options, state, 'failed', error);
        json(path.join(options.outputDir, 'summary.json'), progressSummary(options, state, 'failed', error));
      }
    } catch (reportError) {
      log(`Could not update progress report: ${safeError(reportError, options)}. Existing package files and checkpoints were retained.`);
    }
    if (complete) {
      log(`Transfer archive failed; the complete prepared directory is retained and can be published with --bundle-dir: ${options.outputDir}`);
    } else {
      log(`Downloaded packages and partial inventory retained: ${options.outputDir}`);
      log('The dependency graph is INCOMPLETE. Fix the error, then retry with --resume (or --update to add packages); verified downloads will be reused.');
    }
    throw new Error(safeError(error, options));
  } finally {
    if (temporaryTar) {
      try { fs.rmSync(temporaryTar, { force: true }); }
      catch (error) { log(`Temporary archive cleanup failed: ${safeError(error, options)}`); }
    }
  }
}

module.exports = { parseArgs, parseRequest, selectVersion, collectDependencies, incompatibility, registryScoped, isWithinDirectory, main };
if (require.main === module) main().catch((error) => { console.error(`ERROR: ${error.message}`); process.exitCode = 1; });
