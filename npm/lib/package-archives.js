'use strict';

// HTTP bundle utilities, independent of the archived npm CLI downloader.
// Importing this module must never load child_process or execute a command.
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const crypto = require('crypto');

function fail(message) { throw new Error(message); }
function log(message) { process.stderr.write(`${message}\n`); }

function packageSpecFromNameVersion(name, version, source) {
  const cleanName = String(name || '').trim();
  const cleanVersion = version === undefined || version === null ? '' : String(version).trim();
  if (!cleanName) {
    fail(`Package entry in ${source} is missing a package name`);
  }
  return cleanVersion ? `${cleanName}@${cleanVersion}` : cleanName;
}

function packageSpecFromTextLine(line, source) {
  const trimmed = String(line || '').replace(/#.*/, '').trim();
  if (!trimmed) {
    return '';
  }

  const comma = trimmed.match(/^([^,\s]+)\s*,\s*(.+)$/);
  if (comma) {
    return packageSpecFromNameVersion(comma[1], comma[2], source);
  }

  // Preserve complete inline ranges such as "react@>=18 <20" and npm aliases.
  // A leading @ in a scoped name is not a version separator.
  const firstToken = trimmed.split(/\s+/, 1)[0];
  const versionAt = firstToken.indexOf('@', firstToken.startsWith('@') ? firstToken.indexOf('/') + 1 : 0);
  if (versionAt > 0) {
    return trimmed;
  }

  const parts = trimmed.split(/\s+/);
  if (parts.length > 1) {
    return packageSpecFromNameVersion(parts[0], parts.slice(1).join(' '), source);
  }

  return trimmed;
}

function packageSpecsFromDependencyMap(map, source) {
  if (!map || typeof map !== 'object' || Array.isArray(map)) {
    fail(`Package dependency map in ${source} must be an object`);
  }
  return Object.entries(map).map(([name, version]) => packageSpecFromNameVersion(name, version, source));
}

function packageSpecFromJsonEntry(item, source) {
  if (typeof item === 'string') {
    return packageSpecFromTextLine(item, source);
  }
  if (item && typeof item === 'object' && !Array.isArray(item)) {
    if (item.spec) {
      return packageSpecFromTextLine(String(item.spec), source);
    }
    if (item.name) {
      const version = item.version ?? item.requested ?? item.range ?? item.tag ?? '';
      return packageSpecFromNameVersion(item.name, version, source);
    }
  }
  fail(`Unsupported package entry in ${source}`);
}

function packageSpecsFromJson(value, source) {
  if (Array.isArray(value)) {
    return value.map((item) => packageSpecFromJsonEntry(item, source)).filter(Boolean);
  }

  if (value && typeof value === 'object') {
    if (Array.isArray(value.packages)) {
      return value.packages.map((item) => packageSpecFromJsonEntry(item, source)).filter(Boolean);
    }
    if (value.packages && typeof value.packages === 'object') {
      return packageSpecsFromDependencyMap(value.packages, source);
    }
    if (value.dependencies && typeof value.dependencies === 'object') {
      return packageSpecsFromDependencyMap(value.dependencies, source);
    }

    const entries = Object.entries(value);
    if (entries.length > 0 && entries.every(([, version]) => ['string', 'number'].includes(typeof version))) {
      return packageSpecsFromDependencyMap(value, source);
    }
  }

  fail(`--packages-file JSON must be an array, {"packages":[...]}, {"packages":{...}}, or a dependency map`);
}

function readPackagesFile(file) {
  if (!file) {
    return [];
  }

  const fullPath = path.resolve(file);
  const bytes = fs.readFileSync(fullPath);
  let text;
  // Windows PowerShell 5 commonly emits UTF-16LE; editors and newer PowerShell
  // also write UTF-8 BOM files. Decode both text and JSON package lists here.
  if (bytes.length >= 2 && ((bytes[0] === 0xff && bytes[1] === 0xfe) || (bytes[0] === 0xfe && bytes[1] === 0xff))) {
    if (bytes.length % 2) fail(`Malformed UTF-16 package list: ${fullPath}`);
    const body = Buffer.from(bytes.subarray(2));
    if (bytes[0] === 0xfe) body.swap16();
    text = body.toString('utf16le');
  } else {
    text = bytes.toString('utf8').replace(/^\uFEFF/, '');
  }
  const trimmed = text.trim();
  if (fullPath.toLowerCase().endsWith('.json') || trimmed.startsWith('[') || trimmed.startsWith('{')) {
    return packageSpecsFromJson(JSON.parse(text), fullPath);
  }

  return text
    .split(/\r?\n/)
    .map((line) => packageSpecFromTextLine(line, fullPath))
    .filter(Boolean);
}

function verifyOriginalIntegrity(file, integrity, label) {
  if (!integrity) {
    log(`WARNING: ${label} has no source integrity; only package identity can be verified`);
    return false;
  }
  const strengths = ['sha512', 'sha384', 'sha256', 'sha1'];
  const tokens = String(integrity).trim().split(/\s+/).map((token) => token.match(/^(sha512|sha384|sha256|sha1)-([A-Za-z0-9+/]+={0,2})(?:\?.*)?$/)).filter(Boolean);
  const algorithm = strengths.find((candidate) => tokens.some((token) => token[1] === candidate));
  if (!algorithm) fail(`Unsupported or malformed source integrity for ${label}`);
  const actual = crypto.createHash(algorithm).update(fs.readFileSync(file)).digest('base64');
  if (!tokens.some((token) => token[1] === algorithm && token[2] === actual)) {
    fail(`Original tarball integrity mismatch for ${label}; download rejected before sanitization`);
  }
  return true;
}

function safeTarballName(name, version) {
  const safeName = name.replace(/^@/, '').replace(/[\/\\]/g, '-').replace(/[^A-Za-z0-9._-]/g, '-');
  const suffix = crypto.createHash('sha256').update(name).digest('hex').slice(0, 10);
  return `${safeName}-${version}-${suffix}.tgz`;
}

function deletePackageJsonField(packageJson, field, removedFields) {
  if (Object.prototype.hasOwnProperty.call(packageJson, field)) {
    delete packageJson[field];
    removedFields.push(field);
  }
}

function hashFile(file, algorithm) {
  const hash = crypto.createHash(algorithm);
  hash.update(fs.readFileSync(file));
  return hash.digest('hex');
}

function sanitizePackageJson(packageJson, options) {
  const removedFields = [];
  deletePackageJsonField(packageJson, 'scripts', removedFields);
  deletePackageJsonField(packageJson, 'private', removedFields);
  deletePackageJsonField(packageJson, 'publishConfig', removedFields);

  if (options.normalizeLibraryPackage) {
    deletePackageJsonField(packageJson, 'devDependencies', removedFields);
  }
  if (options.stripPeerDependencies) {
    deletePackageJsonField(packageJson, 'peerDependencies', removedFields);
    deletePackageJsonField(packageJson, 'peerDependenciesMeta', removedFields);
  }
  if (options.stripOptionalDependencies) {
    deletePackageJsonField(packageJson, 'optionalDependencies', removedFields);
  }
  return removedFields;
}

// Inspect/rewrite tar records in memory. Package archives are never extracted and
// no package lifecycle scripts run. Keeping the original records also preserves
// file modes while producing repeatable gzip output for identical input bytes.
function readTarRecords(file) {
  const data = zlib.gunzipSync(fs.readFileSync(file));
  const records = [];
  let pax = {};
  let paxRecord;
  let longName = '';
  let longLink = '';
  const field = (header, start, length) => header.subarray(start, start + length).toString('utf8').replace(/\0.*$/s, '');
  for (let offset = 0; offset + 512 <= data.length;) {
    const header = Buffer.from(data.subarray(offset, offset + 512));
    if (header.every((byte) => byte === 0)) break;
    const storedChecksum = parseInt(field(header, 148, 8).trim(), 8);
    let checksum = 0;
    for (let i = 0; i < 512; i += 1) checksum += i >= 148 && i < 156 ? 32 : header[i];
    if (storedChecksum !== checksum) fail(`Invalid tar header checksum in ${file}`);
    const type = String.fromCharCode(header[156] || 48);
    const rawSize = field(header, 124, 12).trim();
    if (!/^[0-7]+$/.test(rawSize)) fail(`Unsupported tar size encoding in ${file}`);
    let size = parseInt(rawSize, 8);
    if (!['x', 'g', 'L', 'K'].includes(type) && pax.size !== undefined) size = Number(pax.size);
    if (!Number.isSafeInteger(size) || size < 0 || offset + 512 + size > data.length) fail(`Truncated tarball: ${file}`);
    const content = data.subarray(offset + 512, offset + 512 + size);
    const prefix = field(header, 345, 155);
    const name = field(header, 0, 100);
    const record = { header, data: content, type, name: prefix ? `${prefix}/${name}` : name };
    records.push(record);
    offset += 512 + Math.ceil(size / 512) * 512;
    if (type === 'g') fail('Global PAX tar headers are not supported');
    if (type === 'x') {
      pax = {};
      for (let index = 0; index < content.length;) {
        const space = content.indexOf(32, index);
        const length = Number(content.subarray(index, space).toString());
        if (space < 0 || !Number.isInteger(length) || length <= space - index + 1 || index + length > content.length) fail('Invalid PAX tar header');
        const line = content.subarray(space + 1, index + length - 1).toString('utf8');
        const equals = line.indexOf('=');
        if (equals < 1) fail('Invalid PAX tar field');
        pax[line.slice(0, equals)] = line.slice(equals + 1);
        index += length;
      }
      paxRecord = record;
      continue;
    }
    if (type === 'L') { longName = content.toString('utf8').replace(/\0.*$/s, '').replace(/\n$/, ''); continue; }
    if (type === 'K') { longLink = content.toString('utf8').replace(/\0.*$/s, '').replace(/\n$/, ''); continue; }
    record.name = String(pax.path || longName || record.name).replace(/^\.\//, '');
    if (!record.name.startsWith('package/') || record.name.includes('\\') || record.name.split('/').includes('..')) {
      fail(`Unsafe or unsupported tar member: ${record.name}`);
    }
    if (!['0', '5', '1', '2'].includes(type)) fail(`Unsupported tar member type ${type}: ${record.name}`);
    if (type === '1' || type === '2') {
      const target = pax.linkpath || longLink || field(header, 157, 100);
      const resolved = type === '2' ? path.posix.join(path.posix.dirname(record.name), target) : target;
      if (target.startsWith('/') || target.includes('\\') || !resolved.startsWith('package/') || resolved.split('/').includes('..')) {
        fail(`Unsafe tar link: ${record.name}`);
      }
    }
    record.pax = pax;
    record.paxRecord = paxRecord;
    pax = {};
    paxRecord = undefined;
    longName = '';
    longLink = '';
  }
  const names = new Set();
  for (const record of records.filter((entry) => !['x', 'L', 'K'].includes(entry.type))) {
    if (names.has(record.name)) fail(`Duplicate tar member: ${record.name}`);
    names.add(record.name);
  }
  return records;
}

function encodePax(pax) {
  return Buffer.concat(Object.entries(pax).map(([key, value]) => {
    const body = ` ${key}=${value}\n`;
    let length = Buffer.byteLength(body) + 1;
    while (String(length).length + Buffer.byteLength(body) !== length) length = String(length).length + Buffer.byteLength(body);
    return Buffer.from(`${length}${body}`);
  }));
}

function encodeTarRecord(record) {
  const header = Buffer.from(record.header);
  header.write(`${record.data.length.toString(8).padStart(11, '0')}\0`, 124, 12, 'ascii');
  header.fill(32, 148, 156);
  const checksum = header.reduce((total, byte) => total + byte, 0);
  header.write(`${checksum.toString(8).padStart(6, '0')}\0 `, 148, 8, 'ascii');
  return Buffer.concat([header, record.data, Buffer.alloc((512 - record.data.length % 512) % 512)]);
}

function sanitizeTarballForAirgapPublish(sourceTarball, outputTarball, options) {
  const records = readTarRecords(sourceTarball);
  const sanitizedPackages = [];
  const offlineWarnings = [];
  let rootFields;
  let changed = false;
  for (const record of records) {
    if (record.name.endsWith('/binding.gyp')) offlineWarnings.push(`${record.name}: npm can implicitly run node-gyp; prebuilt binaries or an offline native build toolchain may be required`);
    if (!/^package\/(?:node_modules\/(?:@[^/]+\/)?[^/]+\/)*package\.json$/.test(record.name)) continue;
    if (record.type !== '0') fail(`Package manifest must be a regular file: ${record.name}`);
    const packageJson = JSON.parse(record.data.toString('utf8'));
    const installHooks = Object.keys(packageJson.scripts || {}).filter((name) => /^(preinstall|install|postinstall|prepare)$/.test(name));
    if (installHooks.length) offlineWarnings.push(`${record.name}: removed ${installHooks.join(', ')}; any generated files or downloaded binaries must already be present`);
    const removedFields = sanitizePackageJson(packageJson, options);
    if (record.name === 'package/package.json') rootFields = removedFields;
    sanitizedPackages.push({ path: record.name, removedFields });
    if (!removedFields.length) continue;
    changed = true;
    record.data = Buffer.from(`${JSON.stringify(packageJson, null, 2)}\n`);
    if (record.paxRecord && Object.prototype.hasOwnProperty.call(record.pax, 'size')) {
      delete record.pax.size;
      record.paxRecord.data = encodePax(record.pax);
    }
  }
  if (!rootFields) fail(`Tarball does not contain package/package.json: ${sourceTarball}`);
  if (changed) {
    fs.writeFileSync(outputTarball, zlib.gzipSync(Buffer.concat([...records.map(encodeTarRecord), Buffer.alloc(1024)]), { level: 9 }));
  } else {
    fs.copyFileSync(sourceTarball, outputTarball);
  }
  return { removedFields: rootFields, sanitizedPackages, offlineWarnings };
}

function validatePackageTarball(pkg, tarball) {
  const records = readTarRecords(tarball);
  const root = records.find((record) => record.name === 'package/package.json' && record.type === '0');
  if (!root) {
    fail(`Packed tarball does not contain package/package.json for ${pkg.key}: ${tarball}`);
  }
  const packageJson = JSON.parse(root.data.toString('utf8'));
  const actualName = String(packageJson.name || '');
  const actualVersion = String(packageJson.version || '');
  if (actualName !== pkg.name || actualVersion !== pkg.version) {
    fail(`Packed tarball mismatch for ${pkg.key}: package/package.json contains ${actualName}@${actualVersion}`);
  }
  for (const bundled of pkg.bundledPackages || []) {
    const record = records.find((entry) => entry.name === bundled.tarPath && entry.type === '0');
    if (!record) fail(`Missing bundled dependency ${bundled.key} in ${pkg.key}: ${bundled.tarPath}`);
    const manifest = JSON.parse(record.data.toString('utf8'));
    if (manifest.name !== bundled.name || manifest.version !== bundled.version) fail(`Bundled dependency identity mismatch: ${bundled.key} in ${pkg.key}`);
  }
}

module.exports = {
  readPackagesFile, sanitizeTarballForAirgapPublish, validatePackageTarball,
  readTarRecords, verifyOriginalIntegrity, hashFile, safeTarballName,
  encodeTarRecord
};
