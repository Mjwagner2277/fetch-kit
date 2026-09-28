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
const json = (file, value) => fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);

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
  --output-dir DIR             New prepared bundle directory (no overwrite)
  --tar-file FILE              New uncompressed transfer TAR (no overwrite)
  --help                      Show this help

Bare roots and @latest select the highest stable version compatible with the
target Node/platform. Other named tags remain exact. Dependencies, optional
dependencies, and peers are walked without a depth limit. Optional target-
incompatible edges are reported as omissions; network/auth/integrity failures
are fatal. Unspecified platform dimensions are unfiltered, never host-derived.
Scripts/private/publishConfig/devDependencies are removed from package copies.
No npmrc is read. Source credentials are scoped to the configured registry.
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
    '--output-dir': 'outputDir', '--tar-file': 'tarFile'
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--help' || arg === '-h') { options.help = true; continue; }
    if (arg === '--no-ssl') { options.strictSsl = false; continue; }
    if (arg === '--include-dev-dependencies') { options.includeDevDependencies = true; continue; }
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
  if (!options.packageSpecs.length) throw new Error('Supply at least one --package, --packages-file, or positional package');
  const defaultName = `npm-http-bundle-node-v${options.nodeVersion}`;
  options.tarFile = path.resolve(options.tarFile || `${defaultName}.tar`);
  options.outputDir = path.resolve(options.outputDir || options.tarFile.replace(/\.tar$/i, '') + (options.tarFile.endsWith('.tar') ? '' : '-bundle'));
  if (isWithinDirectory(options.outputDir, options.tarFile)) throw new Error('--tar-file must be outside --output-dir');
  if (fs.existsSync(options.outputDir)) throw new Error(`Output directory already exists: ${options.outputDir}`);
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
  if (applied.length) fs.writeFileSync(file, zlib.gzipSync(Buffer.concat([...records.map(encodeTarRecord), Buffer.alloc(1024)]), { level: 9 }));
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
  const descriptor = fs.openSync(destination, 'wx');
  try {
    const visit = (directory, relative) => {
      for (const name of fs.readdirSync(directory).sort()) {
        const local = path.join(directory, name);
        const member = `${relative}/${name}`;
        if (fs.statSync(local).isDirectory()) visit(local, member);
        else {
          const record = tarHeader(member, fs.readFileSync(local));
          let written = 0;
          while (written < record.length) written += fs.writeSync(descriptor, record, written, record.length - written);
        }
      }
    };
    visit(bundleDir, 'npm-http-bundle');
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

async function buildBundle(options, stage, rawDir) {
  const packageDir = path.join(stage, 'tarballs');
  fs.mkdirSync(packageDir);
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

  async function archiveFor(name, version, metadata) {
    const key = `${name}@${version}`;
    if (archiveCache.has(key)) return archiveCache.get(key);
    if ((metadata.name && metadata.name !== name) || (metadata.version && metadata.version !== version)) throw new Error(`Registry version metadata identity mismatch for ${key}`);
    const dist = metadata.dist || {};
    if (!dist.tarball) throw new Error(`Registry metadata lacks dist.tarball for ${key}`);
    const tarballUrl = checkedUrl(dist.tarball, options.registryUrl);
    let registryIntegrity = dist.integrity;
    if (!registryIntegrity && typeof dist.shasum === 'string' && /^[a-fA-F0-9]{40}$/.test(dist.shasum)) registryIntegrity = `sha1-${Buffer.from(dist.shasum, 'hex').toString('base64')}`;
    if (!registryIntegrity) throw new Error(`Registry metadata lacks a supported integrity/shasum for ${key}; refusing an unverified download`);
    log(`Downloading ${key}`);
    const raw = path.join(rawDir, safeTarballName(name, version));
    fs.writeFileSync(raw, await requestBytes(tarballUrl, options));
    verifyOriginalIntegrity(raw, registryIntegrity, key);
    const manifests = readArchiveManifests(raw, { key, name, version });
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
      const metadata = await metadataFor(request.name);
      const rejected = new Map();
      let archive;
      while (true) {
        const version = selectVersion(metadata, request, options, rejected);
        archive = await archiveFor(request.name, version, metadata.versions[version]);
        const reason = incompatibility(archive.manifest, options);
        if (!reason) break;
        rejected.set(version, `archive manifest: ${reason}`);
      }
      edge.to = archive.key;
      edges.push(edge);
      recordTagNormalization(request, archive.version);
      if (request.kind === 'root') roots.push({ name: request.name, installName: request.installName, requested: request.requested, spec: `${request.installName}@${request.originalRequested}`, resolvedVersion: archive.version, resolvedSpec: archive.key });
      if (!published.has(archive.key)) {
        const tarballName = safeTarballName(archive.name, archive.version);
        const finalTarball = path.join(packageDir, tarballName);
        const sanitization = sanitizeTarballForAirgapPublish(archive.raw, finalTarball, options);
        validatePackageTarball(archive, finalTarball);
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
      }
      if (request.kind === 'root' && options.includeDevDependencies) walkManifest(archive, 'package/package.json', archive.key, true);
    } catch (error) {
      if (error instanceof CompatibilityError && request.optional && !request.bundledPath) {
        edge.omitted = true;
        edge.reason = error.message;
        omissions.push(edge);
        edges.push(edge);
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
  json(path.join(stage, 'packages.json'), items);
  fs.writeFileSync(path.join(stage, 'packages.jsonl'), items.map((item) => JSON.stringify(item)).join('\n') + '\n');
  json(path.join(stage, 'root-packages.json'), roots);
  json(path.join(stage, 'dependency-graph.json'), { schemaVersion: 1, resolutionModel: RESOLUTION_MODEL, closureComplete: true, roots, edges, bundledPackages, omissions });
  const summary = {
    schemaVersion: 1, inputMode: 'http-package-list', resolutionModel: RESOLUTION_MODEL,
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
  fs.mkdirSync(path.dirname(options.outputDir), { recursive: true });
  fs.mkdirSync(path.dirname(options.tarFile), { recursive: true });
  const work = fs.mkdtempSync(path.join(path.dirname(options.outputDir), '.npm-http-work-'));
  const stage = path.join(work, 'bundle');
  const rawDir = path.join(work, 'raw');
  const temporaryTar = path.join(path.dirname(options.tarFile), `.npm-http-${crypto.randomBytes(10).toString('hex')}.tar`);
  fs.mkdirSync(stage);
  fs.mkdirSync(rawDir);
  let installedOutput = false;
  try {
    const summary = await buildBundle(options, stage, rawDir);
    createTransferTar(stage, temporaryTar);
    const transferTarSha256 = hashFile(temporaryTar, 'sha256');
    const transferTarBytes = fs.statSync(temporaryTar).size;
    // Commit the completed archive without replacing another run's output,
    // including on transfer media without hard-link support.
    if (fs.existsSync(options.outputDir)) throw new Error(`Output directory already exists: ${options.outputDir}`);
    fs.renameSync(stage, options.outputDir);
    installedOutput = true;
    try { commitTransferTar(temporaryTar, options.tarFile); }
    catch (error) { fs.rmSync(options.outputDir, { recursive: true, force: true }); installedOutput = false; throw error; }
    const result = { ...summary, transferTarSha256, transferTarBytes };
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return result;
  } finally {
    fs.rmSync(temporaryTar, { force: true });
    fs.rmSync(work, { recursive: true, force: true });
    if (!installedOutput) log('No prepared bundle or transfer archive was committed.');
  }
}

module.exports = { parseArgs, parseRequest, selectVersion, collectDependencies, incompatibility, registryScoped, isWithinDirectory, main };
if (require.main === module) main().catch((error) => { console.error(`ERROR: ${error.message}`); process.exitCode = 1; });
