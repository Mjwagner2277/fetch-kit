#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

function usage() {
  console.log(`Download npm packages into an Artifactory-ready offline bundle.

Usage:
  node npm/download-npm-artifactory-bundle.js --node-version VERSION [options] <package...>

Examples:
  node npm/download-npm-artifactory-bundle.js --node-version 20.11.1 react lodash
  node npm/download-npm-artifactory-bundle.js --node-version 20.11.1 react@18.2.0
  node npm/download-npm-artifactory-bundle.js --node-version 18.20.4 --package @storybook/test-runner
  node npm/download-npm-artifactory-bundle.js --node-version 20.11.1 --packages-file packages.txt
  node npm/download-npm-artifactory-bundle.js --node-version 20.11.1 --update-all

Options:
  --node-version VERSION       Target Node.js version for engine checks. Required.
  --package SPEC              Package spec to add. May be repeated.
  --packages-file FILE        Package list file. May be repeated.
  --package-file FILE         Alias for --packages-file.
  --update-all                Re-download every package recorded in this node-version state file.
  --registry URL              Source npm registry. Defaults to npm's configured registry.
  --userconfig FILE           npmrc file for source registry auth.
  --token TOKEN               Bearer token for the source registry.
  --username USER             Basic auth username for the source registry.
  --password PASSWORD         Basic auth password/API key for the source registry.
  --no-ssl                    Disable npm SSL certificate validation.
  --target-arch ARCH          Target CPU architecture for npm resolution, e.g. x64, arm64.
  --target-os OS              Target OS for npm resolution, e.g. linux, win32, darwin.
  --target-libc LIBC          Target libc for Linux npm resolution, e.g. glibc, musl.
  --output-dir DIR            Transfer tar output root. Defaults to ./npm-artifactory-cache.
  --tar-file FILE             Exact transfer tar path. Defaults under --output-dir.
  --state-dir DIR             State root. Defaults to ./npm-state.
  --npm-bin PATH              npm executable. Defaults to npm.
  --max-version-probes N      Latest-compatible probes per package. Defaults to 50.
  --include-prerelease        Allow prerelease versions when searching latest-compatible.
  --omit-peer-dependencies    Do not include peer dependencies in the lockfile.
  --omit-optional-dependencies
                              Do not include optional dependencies in the lockfile.
  --allow-engine-mismatches   Record engines.node mismatches instead of failing.
  --no-normalize-library-package
                              Keep original npm tarball package.json metadata.
  --strip-peer-dependencies   Remove peerDependencies from packed tarball package.json.
  --strip-optional-dependencies
                              Remove optionalDependencies from packed tarball package.json.
  -h, --help                  Show this help.

State:
  One JSON state file is written per node version, for example:
    npm-state/node-v20.11.1.json
`);
}

function fail(message) {
  throw new Error(message);
}

function log(message) {
  process.stderr.write(`[${new Date().toISOString()}] ${message}\n`);
}

function parseArgs(argv) {
  const options = {
    nodeVersion: '',
    packages: [],
    packagesFiles: [],
    updateAll: false,
    registry: '',
    userconfig: '',
    token: process.env.NPM_TOKEN || '',
    username: process.env.NPM_USERNAME || '',
    password: process.env.NPM_PASSWORD || '',
    strictSsl: true,
    targetArch: '',
    targetOs: '',
    targetLibc: '',
    outputDir: path.resolve(process.cwd(), 'npm-artifactory-cache'),
    tarFile: '',
    stateDir: path.resolve(process.cwd(), 'npm-state'),
    npmBin: process.env.NPM_BIN || 'npm',
    maxVersionProbes: 50,
    includePrerelease: false,
    omitPeerDependencies: false,
    omitOptionalDependencies: false,
    validateEngines: true,
    normalizeLibraryPackage: true,
    stripPeerDependencies: false,
    stripOptionalDependencies: false
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => {
      index += 1;
      if (index >= argv.length) {
        fail(`Missing value for ${arg}`);
      }
      return argv[index];
    };

    switch (arg) {
      case '-h':
      case '--help':
        options.help = true;
        break;
      case '--node-version':
        options.nodeVersion = next();
        break;
      case '--package':
        options.packages.push(next());
        break;
      case '--packages-file':
      case '--package-file':
        options.packagesFiles.push(next());
        break;
      case '--update-all':
        options.updateAll = true;
        break;
      case '--registry':
        options.registry = next();
        break;
      case '--userconfig':
        options.userconfig = path.resolve(next());
        break;
      case '--token':
        options.token = next();
        break;
      case '--username':
        options.username = next();
        break;
      case '--password':
        options.password = next();
        break;
      case '--no-ssl':
      case '--no-strict-ssl':
        options.strictSsl = false;
        break;
      case '--target-arch':
      case '--target-architecture':
      case '--cpu':
        options.targetArch = next();
        break;
      case '--target-os':
      case '--os':
        options.targetOs = next();
        break;
      case '--target-libc':
      case '--libc':
        options.targetLibc = next();
        break;
      case '--output-dir':
        options.outputDir = path.resolve(next());
        break;
      case '--tar-file':
        options.tarFile = path.resolve(next());
        break;
      case '--state-dir':
        options.stateDir = path.resolve(next());
        break;
      case '--npm-bin':
        options.npmBin = next();
        break;
      case '--max-version-probes':
        options.maxVersionProbes = Number.parseInt(next(), 10);
        break;
      case '--include-prerelease':
        options.includePrerelease = true;
        break;
      case '--omit-peer-dependencies':
        options.omitPeerDependencies = true;
        break;
      case '--omit-optional-dependencies':
        options.omitOptionalDependencies = true;
        break;
      case '--allow-engine-mismatches':
      case '--no-engine-strict':
        options.validateEngines = false;
        break;
      case '--no-normalize-library-package':
        options.normalizeLibraryPackage = false;
        break;
      case '--strip-peer-dependencies':
        options.stripPeerDependencies = true;
        break;
      case '--strip-optional-dependencies':
        options.stripOptionalDependencies = true;
        break;
      default:
        if (arg.startsWith('-')) {
          fail(`Unknown argument: ${arg}`);
        }
        options.packages.push(arg);
        break;
    }
  }

  if (!Number.isInteger(options.maxVersionProbes) || options.maxVersionProbes < 1) {
    fail('--max-version-probes must be a positive integer');
  }
  for (const [flag, value] of [
    ['--target-arch', options.targetArch],
    ['--target-os', options.targetOs],
    ['--target-libc', options.targetLibc]
  ]) {
    if (value && /[\s=]/.test(value)) {
      fail(`${flag} cannot contain whitespace or =`);
    }
  }

  return options;
}

function mkdirp(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function writeJson(file, value) {
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function sanitize(value) {
  return String(value).replace(/[^A-Za-z0-9._-]/g, '-');
}

function nodeStateSlug(nodeVersion) {
  return `node-v${sanitize(nodeVersion)}`;
}

function timestampSlug(date = new Date()) {
  return date.toISOString().replace(/[-:]/g, '').replace(/\..+$/, 'Z');
}

function targetPlatformSummary(options) {
  return {
    arch: options.targetArch || '',
    os: options.targetOs || '',
    libc: options.targetLibc || ''
  };
}

function formatTargetPlatform(options) {
  const parts = [];
  if (options.targetOs) parts.push(`os=${options.targetOs}`);
  if (options.targetArch) parts.push(`arch=${options.targetArch}`);
  if (options.targetLibc) parts.push(`libc=${options.targetLibc}`);
  return parts.length > 0 ? parts.join(', ') : 'npm host defaults';
}

function splitPackageSpec(spec) {
  const trimmed = String(spec || '').trim();
  if (!trimmed) {
    fail('Package spec cannot be empty');
  }

  if (trimmed.startsWith('@')) {
    const slash = trimmed.indexOf('/');
    if (slash === -1) {
      fail(`Invalid scoped package spec: ${trimmed}`);
    }
    const versionAt = trimmed.indexOf('@', slash + 1);
    if (versionAt === -1) {
      return { name: trimmed, requested: 'latest', spec: `${trimmed}@latest` };
    }
    const name = trimmed.slice(0, versionAt);
    const requested = trimmed.slice(versionAt + 1) || 'latest';
    return { name, requested, spec: `${name}@${requested}` };
  }

  const versionAt = trimmed.lastIndexOf('@');
  if (versionAt > 0) {
    const name = trimmed.slice(0, versionAt);
    const requested = trimmed.slice(versionAt + 1) || 'latest';
    return { name, requested, spec: `${name}@${requested}` };
  }

  return { name: trimmed, requested: 'latest', spec: `${trimmed}@latest` };
}

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
  const text = fs.readFileSync(fullPath, 'utf8');
  const trimmed = text.trim();
  if (fullPath.endsWith('.json') || trimmed.startsWith('[') || trimmed.startsWith('{')) {
    return packageSpecsFromJson(JSON.parse(text), fullPath);
  }

  return text
    .split(/\r?\n/)
    .map((line) => packageSpecFromTextLine(line, fullPath))
    .filter(Boolean);
}

function loadState(stateFile, nodeVersion) {
  if (!fs.existsSync(stateFile)) {
    return {
      schemaVersion: 1,
      nodeVersion,
      requests: {},
      runs: []
    };
  }

  const state = readJson(stateFile);
  if (state.nodeVersion !== nodeVersion) {
    fail(`State file ${stateFile} belongs to node version ${state.nodeVersion}, not ${nodeVersion}`);
  }
  state.requests = state.requests || {};
  state.runs = Array.isArray(state.runs) ? state.runs : [];
  return state;
}

function npmArgsWithConfig(options) {
  const args = [];
  if (options.registry) {
    args.push(`--registry=${options.registry}`);
  }
  if (options.userconfig) {
    args.push(`--userconfig=${options.userconfig}`);
  }
  if (!options.strictSsl) {
    args.push('--strict-ssl=false');
  }
  if (options.targetArch) {
    args.push(`--cpu=${options.targetArch}`);
  }
  if (options.targetOs) {
    args.push(`--os=${options.targetOs}`);
  }
  if (options.targetLibc) {
    args.push(`--libc=${options.targetLibc}`);
  }
  return args;
}

function npmEnv(options) {
  const env = {
    ...process.env,
    npm_config_engine_strict: 'false'
  };
  if (!options.strictSsl) {
    env.npm_config_strict_ssl = 'false';
  }
  if (options.targetArch) {
    env.npm_config_cpu = options.targetArch;
  }
  if (options.targetOs) {
    env.npm_config_os = options.targetOs;
  }
  if (options.targetLibc) {
    env.npm_config_libc = options.targetLibc;
  }
  if (options.cacheDir) {
    env.npm_config_cache = options.cacheDir;
  }
  return env;
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || process.cwd(),
    env: options.env || process.env,
    encoding: 'utf8',
    maxBuffer: 1024 * 1024 * 20
  });

  if (result.error) {
    fail(`${command} failed to start: ${result.error.message}`);
  }

  if (result.status !== 0) {
    const output = `${result.stdout || ''}${result.stderr || ''}`.trim();
    fail(`${command} ${args.join(' ')} failed${output ? `:\n${output}` : ''}`);
  }

  return result.stdout || '';
}

function runNpmJson(options, args) {
  const stdout = run(options.npmBin, [...args, '--json', ...npmArgsWithConfig(options)], {
    env: npmEnv(options)
  }).trim();
  if (!stdout) {
    return null;
  }
  return JSON.parse(stdout);
}

function writeGeneratedNpmrc(options, dir) {
  if (options.userconfig || (!options.token && !options.username && !options.password)) {
    return options.userconfig;
  }
  if (!options.registry) {
    fail('--registry is required when --token or --username/--password is used');
  }

  const registry = options.registry.replace(/\/+$/, '/');
  const fragment = `//${registry.replace(/^https?:\/\//, '')}`;
  const npmrc = path.join(dir, 'source-registry.npmrc');
  const lines = [`registry=${registry}`, `${fragment}:always-auth=true`];
  if (!options.strictSsl) {
    lines.push('strict-ssl=false');
  }
  if (options.token) {
    lines.push(`${fragment}:_authToken=${options.token}`);
  } else {
    if (!options.username || !options.password) {
      fail('Set --token, or set --username and --password');
    }
    lines.push(`${fragment}:username=${options.username}`);
    lines.push(`${fragment}:_password=${Buffer.from(options.password).toString('base64')}`);
    lines.push(`${fragment}:email=npm-artifactory-bundler@example.invalid`);
  }
  fs.writeFileSync(npmrc, `${lines.join('\n')}\n`);
  return npmrc;
}

function parseSemver(version) {
  const match = String(version).match(/^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+.*)?$/);
  if (!match) {
    return null;
  }
  return {
    major: Number.parseInt(match[1], 10),
    minor: Number.parseInt(match[2], 10),
    patch: Number.parseInt(match[3], 10),
    prerelease: match[4] || ''
  };
}

function comparePrerelease(left, right) {
  if (!left && !right) return 0;
  if (!left) return 1;
  if (!right) return -1;

  const leftParts = left.split('.');
  const rightParts = right.split('.');
  const length = Math.max(leftParts.length, rightParts.length);
  for (let index = 0; index < length; index += 1) {
    const a = leftParts[index];
    const b = rightParts[index];
    if (a === undefined) return -1;
    if (b === undefined) return 1;
    const aNumber = /^\d+$/.test(a) ? Number.parseInt(a, 10) : null;
    const bNumber = /^\d+$/.test(b) ? Number.parseInt(b, 10) : null;
    if (aNumber !== null && bNumber !== null && aNumber !== bNumber) {
      return aNumber - bNumber;
    }
    if (aNumber !== null && bNumber === null) return -1;
    if (aNumber === null && bNumber !== null) return 1;
    if (a !== b) return a < b ? -1 : 1;
  }
  return 0;
}

function compareSemver(left, right) {
  const a = parseSemver(left);
  const b = parseSemver(right);
  if (!a && !b) return String(left).localeCompare(String(right));
  if (!a) return -1;
  if (!b) return 1;
  if (a.major !== b.major) return a.major - b.major;
  if (a.minor !== b.minor) return a.minor - b.minor;
  if (a.patch !== b.patch) return a.patch - b.patch;
  return comparePrerelease(a.prerelease, b.prerelease);
}

function isPrerelease(version) {
  const parsed = parseSemver(version);
  return Boolean(parsed && parsed.prerelease);
}

function parseRangeVersion(value) {
  const cleaned = String(value || '').trim().replace(/^v/i, '');
  if (!cleaned || cleaned === '*' || /^[xX*]$/.test(cleaned)) {
    return { wildcardIndex: 0, parts: [0, 0, 0] };
  }

  const parts = cleaned.split('.');
  const parsed = [0, 0, 0];
  let wildcardIndex = -1;

  for (let index = 0; index < 3; index += 1) {
    const part = parts[index];
    if (part === undefined || /^[xX*]$/.test(part)) {
      wildcardIndex = index;
      break;
    }
    const match = String(part).match(/^(\d+)/);
    if (!match) {
      return null;
    }
    parsed[index] = Number.parseInt(match[1], 10);
  }

  return { wildcardIndex, parts: parsed };
}

function compareVersionParts(left, right) {
  for (let index = 0; index < 3; index += 1) {
    if (left[index] !== right[index]) {
      return left[index] - right[index];
    }
  }
  return 0;
}

function upperBoundForWildcard(parsed) {
  const upper = [...parsed.parts];
  if (parsed.wildcardIndex <= 1) {
    upper[0] += 1;
    upper[1] = 0;
    upper[2] = 0;
  } else {
    upper[1] += 1;
    upper[2] = 0;
  }
  return upper;
}

function upperBoundForCaret(parsed) {
  const upper = [...parsed.parts];
  if (parsed.parts[0] > 0) {
    upper[0] += 1;
    upper[1] = 0;
    upper[2] = 0;
  } else if (parsed.parts[1] > 0) {
    upper[1] += 1;
    upper[2] = 0;
  } else {
    upper[2] += 1;
  }
  return upper;
}

function upperBoundForTilde(parsed) {
  const upper = [...parsed.parts];
  if (parsed.wildcardIndex === 1) {
    upper[0] += 1;
    upper[1] = 0;
    upper[2] = 0;
  } else {
    upper[1] += 1;
    upper[2] = 0;
  }
  return upper;
}

function comparatorSatisfied(nodeParts, operator, targetParts) {
  const comparison = compareVersionParts(nodeParts, targetParts);
  switch (operator) {
    case '>':
      return comparison > 0;
    case '>=':
      return comparison >= 0;
    case '<':
      return comparison < 0;
    case '<=':
      return comparison <= 0;
    case '=':
      return comparison === 0;
    default:
      return false;
  }
}

function expandTokenToComparators(token) {
  if (!token || token === '*' || /^[xX*]$/.test(token)) {
    return [];
  }

  const caret = token.startsWith('^');
  const tilde = token.startsWith('~');
  if (caret || tilde) {
    const parsed = parseRangeVersion(token.slice(1));
    if (!parsed) {
      return null;
    }
    return [
      ['>=', parsed.parts],
      ['<', caret ? upperBoundForCaret(parsed) : upperBoundForTilde(parsed)]
    ];
  }

  const match = token.match(/^(>=|<=|>|<|=)?(.+)$/);
  if (!match) {
    return null;
  }

  const operator = match[1] || '';
  const parsed = parseRangeVersion(match[2]);
  if (!parsed) {
    return null;
  }

  if (!operator && parsed.wildcardIndex !== -1) {
    return [
      ['>=', parsed.parts],
      ['<', upperBoundForWildcard(parsed)]
    ];
  }

  return [[operator || '=', parsed.parts]];
}

function normalizeEngineRange(range) {
  return String(range || '')
    .replace(/[()]/g, ' ')
    .replace(/\s+-\s+/g, ' - ')
    .replace(/(>=|<=|>|<|=|\^|~)\s+/g, '$1')
    .replace(/\s+/g, ' ')
    .trim();
}

function engineRangeCompatible(range, nodeVersion) {
  if (!range || range === '*') {
    return { compatible: true, supported: true };
  }

  const nodeParsed = parseRangeVersion(nodeVersion);
  if (!nodeParsed || nodeParsed.wildcardIndex !== -1) {
    return { compatible: false, supported: false, reason: `Invalid node version: ${nodeVersion}` };
  }

  const normalized = normalizeEngineRange(range);
  const orParts = normalized.split(/\s*\|\|\s*/).filter(Boolean);
  if (orParts.length === 0) {
    return { compatible: true, supported: true };
  }

  let unsupported = false;
  for (const part of orParts) {
    let expression = part;
    const hyphen = expression.match(/^(\S+)\s+-\s+(\S+)$/);
    if (hyphen) {
      expression = `>=${hyphen[1]} <=${hyphen[2]}`;
    }

    const tokens = expression.split(/\s+/).filter(Boolean);
    const comparators = [];
    for (const token of tokens) {
      const expanded = expandTokenToComparators(token);
      if (!expanded) {
        unsupported = true;
        break;
      }
      comparators.push(...expanded);
    }

    if (tokens.length === 0) {
      return { compatible: true, supported: true };
    }

    if (comparators.every(([operator, target]) => comparatorSatisfied(nodeParsed.parts, operator, target))) {
      return { compatible: true, supported: true };
    }
  }

  return unsupported
    ? { compatible: true, supported: false, reason: `Unsupported engine range syntax: ${range}` }
    : { compatible: false, supported: true };
}

function makePackageJson(dependencies) {
  return {
    private: true,
    name: 'npm-artifactory-bundle-resolution',
    version: '0.0.0',
    dependencies
  };
}

function npmInstallLock(projectDir, options) {
  const args = [
    'install',
    '--package-lock-only',
    '--ignore-scripts',
    '--no-audit',
    '--fund=false',
    '--engine-strict=false',
    '--omit=dev'
  ];
  if (options.omitPeerDependencies) {
    args.push('--omit=peer');
  }
  if (options.omitOptionalDependencies) {
    args.push('--omit=optional');
  }
  run(options.npmBin, [...args, ...npmArgsWithConfig(options)], {
    cwd: projectDir,
    env: npmEnv(options)
  });
}

function candidateVersionsForLatest(packageName, options) {
  const versionsJson = runNpmJson(options, ['view', packageName, 'versions']);
  const versions = Array.isArray(versionsJson) ? versionsJson : [versionsJson].filter(Boolean);
  if (versions.length === 0) {
    fail(`No versions returned for ${packageName}`);
  }

  let latest = '';
  try {
    const distTags = runNpmJson(options, ['view', packageName, 'dist-tags']);
    latest = distTags && distTags.latest ? String(distTags.latest) : '';
  } catch {
    latest = '';
  }

  const stableDescending = versions
    .filter((version) => options.includePrerelease || !isPrerelease(version))
    .sort(compareSemver)
    .reverse();

  const candidates = [];
  if (latest && (options.includePrerelease || !isPrerelease(latest))) {
    candidates.push(latest);
  }
  for (const version of stableDescending) {
    if (!candidates.includes(version)) {
      candidates.push(version);
    }
  }
  return candidates;
}

function getPackageEngines(packageName, version, options) {
  const engines = runNpmJson(options, ['view', `${packageName}@${version}`, 'engines']);
  return engines && typeof engines === 'object' ? engines : {};
}

function resolveLatestCompatible(packageName, options) {
  const candidates = candidateVersionsForLatest(packageName, options);
  let checked = 0;

  for (const version of candidates) {
    checked += 1;
    if (checked > options.maxVersionProbes) {
      break;
    }

    try {
      log(`Checking ${packageName}@${version} against Node ${options.nodeVersion}`);
      const engines = getPackageEngines(packageName, version, options);
      const check = engineRangeCompatible(engines.node, options.nodeVersion);
      if (check.compatible) {
        return { version, checked, engines };
      }
      log(`Skipping ${packageName}@${version}; engines.node=${engines.node}`);
    } catch (error) {
      log(`Skipping ${packageName}@${version}; ${error.message}`);
    }
  }

  fail(`Could not find a ${packageName} version compatible with Node ${options.nodeVersion} after ${checked} probes.`);
}

function packageNameFromLockPath(lockPath) {
  const marker = 'node_modules/';
  const index = lockPath.lastIndexOf(marker);
  if (index === -1) {
    return '';
  }
  const rest = lockPath.slice(index + marker.length);
  const parts = rest.split('/');
  if (parts[0] && parts[0].startsWith('@')) {
    return parts.length >= 2 ? `${parts[0]}/${parts[1]}` : '';
  }
  return parts[0] || '';
}

function collectLockPackages(lock) {
  const packages = lock.packages || {};
  const byKey = new Map();

  for (const [lockPath, meta] of Object.entries(packages)) {
    if (!lockPath || !meta || !meta.version) {
      continue;
    }
    const name = meta.name || packageNameFromLockPath(lockPath);
    if (!name) {
      continue;
    }
    const key = `${name}@${meta.version}`;
    if (!byKey.has(key)) {
      byKey.set(key, {
        name,
        version: meta.version,
        key,
        lockPath,
        resolved: meta.resolved || '',
        integrity: meta.integrity || '',
        engines: meta.engines || {},
        optional: Boolean(meta.optional),
        dev: Boolean(meta.dev)
      });
    }
  }

  return [...byKey.values()].sort((left, right) => {
    if (left.name !== right.name) {
      return left.name < right.name ? -1 : 1;
    }
    return compareSemver(left.version, right.version);
  });
}

function safeTarballName(name, version) {
  const safeName = name.replace(/^@/, '').replace(/[\/\\]/g, '-').replace(/[^A-Za-z0-9._-]/g, '-');
  return `${safeName}-${version}.tgz`;
}

function hashFile(file, algorithm) {
  const hash = crypto.createHash(algorithm);
  hash.update(fs.readFileSync(file));
  return hash.digest('hex');
}

function packPackage(pkg, options, rawTarballDir) {
  const packageRef = `${pkg.name}@${pkg.version}`;
  log(`Packing ${packageRef}`);
  const output = run(options.npmBin, [
    'pack',
    packageRef,
    '--ignore-scripts',
    '--json',
    `--pack-destination=${rawTarballDir}`,
    ...npmArgsWithConfig(options)
  ], {
    env: npmEnv(options)
  });

  const parsed = JSON.parse(output);
  const first = Array.isArray(parsed) ? parsed[0] : parsed;
  if (!first || !first.filename) {
    fail(`npm pack did not return a filename for ${packageRef}`);
  }
  return {
    rawTarball: path.join(rawTarballDir, first.filename),
    npmPack: first
  };
}

function normalizeTarball(sourceTarball, outputTarball, options, workRoot) {
  const extractDir = fs.mkdtempSync(path.join(workRoot, 'normalize-'));
  run('tar', ['-xzf', sourceTarball, '-C', extractDir]);

  const packageJsonFile = path.join(extractDir, 'package', 'package.json');
  if (!fs.existsSync(packageJsonFile)) {
    fail(`Tarball does not contain package/package.json: ${sourceTarball}`);
  }

  const packageJson = readJson(packageJsonFile);
  delete packageJson.scripts;
  delete packageJson.devDependencies;
  if (options.stripPeerDependencies) {
    delete packageJson.peerDependencies;
    delete packageJson.peerDependenciesMeta;
  }
  if (options.stripOptionalDependencies) {
    delete packageJson.optionalDependencies;
  }
  writeJson(packageJsonFile, packageJson);

  run('tar', ['-czf', outputTarball, '-C', extractDir, 'package']);
}

function validateResolvedEngines(packages, options) {
  const mismatches = [];
  const unsupported = [];

  for (const pkg of packages) {
    const nodeRange = pkg.engines && pkg.engines.node ? String(pkg.engines.node) : '';
    if (!nodeRange) {
      pkg.engineCompatible = true;
      pkg.engineRangeSupported = true;
      continue;
    }

    const check = engineRangeCompatible(nodeRange, options.nodeVersion);
    pkg.enginesNode = nodeRange;
    pkg.engineCompatible = check.compatible;
    pkg.engineRangeSupported = check.supported;
    if (!check.supported) {
      unsupported.push(`${pkg.key}: ${nodeRange}`);
    }
    if (!check.compatible) {
      mismatches.push(`${pkg.key} requires node "${nodeRange}"`);
    }
  }

  if (mismatches.length > 0 && options.validateEngines) {
    fail(`Resolved packages include engines.node mismatches for Node ${options.nodeVersion}:\n${mismatches.join('\n')}`);
  }

  return { mismatches, unsupported };
}

function createTransferTar(bundleDir, tarFile) {
  mkdirp(path.dirname(tarFile));
  run('tar', ['-cf', tarFile, '-C', path.dirname(bundleDir), path.basename(bundleDir)]);
}

function writeBundleReadme(bundleDir, options) {
  const lines = [
    'npm Artifactory transfer bundle',
    '',
    `Target Node.js version: ${options.nodeVersion}`,
    `Target npm platform: ${formatTargetPlatform(options)}`,
    '',
    'This directory is intended to be transported as the single .tar file created by the downloader.',
    '',
    'The npm registry uploader script is maintained separately in the airgapped environment.',
    'Use upload-npm-artifactory-bundle.sh with this transfer tar, or use packages.json,',
    'packages.jsonl, or artifactory-upload-manifest.tsv as custom uploader input.',
    '',
    'Files:',
    '  package.json                    Root requested package set used for resolution.',
    '  package-lock.json               npm lockfile for the resolved offline dependency tree.',
    '  packages.json                   Machine-readable package/tarball manifest.',
    '  packages.tsv                    Human-readable package/tarball list.',
    '  artifactory-upload-manifest.tsv Tab-separated name/version/tarball manifest.',
    '  tarballs/                       Packed npm tarballs ready to publish.',
    '  state/                          Snapshot of the local per-node-version state file.',
    '',
    'Tarball package.json files are normalized by default: scripts and devDependencies are removed.',
    'Runtime fields and dependencies are preserved unless strip flags were used.'
  ];
  fs.writeFileSync(path.join(bundleDir, 'README.txt'), `${lines.join('\n')}\n`);
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    usage();
    return;
  }
  if (!options.nodeVersion) {
    fail('--node-version is required');
  }

  const packageSpecs = [
    ...options.packagesFiles.flatMap((file) => readPackagesFile(file)),
    ...options.packages
  ];
  mkdirp(options.stateDir);
  mkdirp(options.outputDir);

  const nodeSlug = nodeStateSlug(options.nodeVersion);
  const stateFile = path.join(options.stateDir, `${nodeSlug}.json`);
  const state = loadState(stateFile, options.nodeVersion);
  const now = new Date().toISOString();

  for (const spec of packageSpecs) {
    const request = splitPackageSpec(spec);
    const previous = state.requests[request.name] || {};
    state.requests[request.name] = {
      name: request.name,
      requested: request.requested,
      spec: request.spec,
      firstRequestedAt: previous.firstRequestedAt || now,
      lastRequestedAt: now
    };
  }
  writeJson(stateFile, state);

  const requestsByName = new Map();
  if (options.updateAll) {
    for (const request of Object.values(state.requests)) {
      requestsByName.set(request.name, request);
    }
  }
  for (const spec of packageSpecs) {
    const request = splitPackageSpec(spec);
    requestsByName.set(request.name, request);
  }

  const requests = [...requestsByName.values()].sort((left, right) => left.name.localeCompare(right.name));
  if (requests.length === 0) {
    fail('Provide at least one package, or use --update-all after the state file has requests');
  }

  const runId = timestampSlug();
  const bundleName = `npm-artifactory-bundle-${nodeSlug}-${runId}`;
  const runOutputDir = path.join(options.outputDir, nodeSlug);
  const transferTarFile = options.tarFile || path.join(runOutputDir, `${bundleName}.tar`);
  const workRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'npm-artifactory-download-'));
  try {
    const bundleDir = path.join(workRoot, bundleName);
    const tarballDir = path.join(bundleDir, 'tarballs');
    const stateSnapshotDir = path.join(bundleDir, 'state');
    const projectDir = path.join(workRoot, 'resolver');
    const rawTarballDir = path.join(workRoot, 'raw-tarballs');
    options.cacheDir = path.join(workRoot, 'npm-cache');

    mkdirp(runOutputDir);
    mkdirp(bundleDir);
    mkdirp(tarballDir);
    mkdirp(stateSnapshotDir);
    mkdirp(projectDir);
    mkdirp(rawTarballDir);
    mkdirp(options.cacheDir);

    options.userconfig = writeGeneratedNpmrc(options, workRoot);

    const dependencies = {};
    const rootPackages = [];

    for (const request of requests) {
      if (request.requested === 'latest') {
        const resolved = resolveLatestCompatible(request.name, options);
        dependencies[request.name] = resolved.version;
        rootPackages.push({
          name: request.name,
          requested: request.requested,
          spec: request.spec,
          resolvedVersion: resolved.version,
          resolvedSpec: `${request.name}@${resolved.version}`,
          latestCompatibleChecks: resolved.checked,
          engines: resolved.engines
        });
      } else {
        dependencies[request.name] = request.requested;
        rootPackages.push({
          name: request.name,
          requested: request.requested,
          spec: request.spec,
          resolvedVersion: '',
          resolvedSpec: `${request.name}@${request.requested}`,
          latestCompatibleChecks: 0,
          engines: {}
        });
      }
    }

    writeJson(path.join(projectDir, 'package.json'), makePackageJson(dependencies));
    log(`Resolving dependency tree for Node ${options.nodeVersion}`);
    npmInstallLock(projectDir, options);

    const lockFile = path.join(projectDir, 'package-lock.json');
    const lock = readJson(lockFile);
    const resolvedPackages = collectLockPackages(lock);
    if (resolvedPackages.length === 0) {
      fail('npm produced a lockfile with no resolved packages');
    }

    const rootVersionByName = new Map();
    for (const pkg of resolvedPackages) {
      if (dependencies[pkg.name]) {
        rootVersionByName.set(pkg.name, pkg.version);
      }
    }
    for (const root of rootPackages) {
      root.resolvedVersion = rootVersionByName.get(root.name) || root.resolvedVersion;
      root.resolvedSpec = `${root.name}@${root.resolvedVersion || root.requested}`;
    }

    const engineReport = validateResolvedEngines(resolvedPackages, options);

    fs.copyFileSync(path.join(projectDir, 'package.json'), path.join(bundleDir, 'package.json'));
    fs.copyFileSync(lockFile, path.join(bundleDir, 'package-lock.json'));

    const manifestItems = [];
    for (const pkg of resolvedPackages) {
      const packed = packPackage(pkg, options, rawTarballDir);
      const tarballName = safeTarballName(pkg.name, pkg.version);
      const finalTarball = path.join(tarballDir, tarballName);

      if (options.normalizeLibraryPackage) {
        normalizeTarball(packed.rawTarball, finalTarball, options, workRoot);
      } else {
        fs.copyFileSync(packed.rawTarball, finalTarball);
      }

      const stat = fs.statSync(finalTarball);
      manifestItems.push({
        name: pkg.name,
        version: pkg.version,
        package: `${pkg.name}@${pkg.version}`,
        tarball: path.relative(bundleDir, finalTarball).replace(/\\/g, '/'),
        sha1: hashFile(finalTarball, 'sha1'),
        sha512: hashFile(finalTarball, 'sha512'),
        bytes: stat.size,
        lockPath: pkg.lockPath,
        resolved: pkg.resolved,
        registryIntegrity: pkg.integrity,
        engines: pkg.engines,
        enginesNode: pkg.enginesNode || '',
        engineCompatible: pkg.engineCompatible,
        engineRangeSupported: pkg.engineRangeSupported,
        normalized: options.normalizeLibraryPackage,
        root: rootPackages.some((root) => root.name === pkg.name && root.resolvedVersion === pkg.version),
        optional: pkg.optional,
        dev: pkg.dev,
        npmPack: packed.npmPack
      });
    }

    writeJson(path.join(bundleDir, 'root-packages.json'), rootPackages);
    writeJson(path.join(bundleDir, 'packages.json'), manifestItems);
    fs.writeFileSync(
      path.join(bundleDir, 'packages.jsonl'),
      `${manifestItems.map((item) => JSON.stringify(item)).join('\n')}\n`
    );
    fs.writeFileSync(
      path.join(bundleDir, 'packages.tsv'),
      `Name\tVersion\tPackage\tTarball\tBytes\tSha1\n${manifestItems.map((item) => [
        item.name,
        item.version,
        item.package,
        item.tarball,
        item.bytes,
        item.sha1
      ].join('\t')).join('\n')}\n`
    );
    fs.writeFileSync(
      path.join(bundleDir, 'artifactory-upload-manifest.tsv'),
      `${manifestItems.map((item) => [item.name, item.version, item.tarball].join('\t')).join('\n')}\n`
    );

    const runRecord = {
      at: now,
      nodeVersion: options.nodeVersion,
      registry: options.registry || 'npm-config-default',
      strictSsl: options.strictSsl,
      targetPlatform: targetPlatformSummary(options),
      transferTarFile,
      bundleName,
      rootPackages,
      packageCount: manifestItems.length,
      normalized: options.normalizeLibraryPackage,
      engineMismatchCount: engineReport.mismatches.length,
      unsupportedEngineRangeCount: engineReport.unsupported.length
    };

    state.lastRun = runRecord;
    state.resolvedPackages = Object.fromEntries(manifestItems.map((item) => [item.package, {
      name: item.name,
      version: item.version,
      lastSeenAt: now,
      root: item.root,
      optional: item.optional,
      enginesNode: item.enginesNode,
      engineCompatible: item.engineCompatible
    }]));
    state.runs.push(runRecord);
    state.runs = state.runs.slice(-25);
    writeJson(stateFile, state);
    fs.copyFileSync(stateFile, path.join(stateSnapshotDir, path.basename(stateFile)));

    const summary = {
      nodeVersion: options.nodeVersion,
      registry: options.registry || 'npm-config-default',
      strictSsl: options.strictSsl,
      targetPlatform: targetPlatformSummary(options),
      transferTarFile,
      bundleName,
      stateFile,
      stateSnapshot: `state/${path.basename(stateFile)}`,
      rootPackageCount: rootPackages.length,
      packageCount: manifestItems.length,
      normalized: options.normalizeLibraryPackage,
      stripPeerDependencies: options.stripPeerDependencies,
      stripOptionalDependencies: options.stripOptionalDependencies,
      engineMismatchCount: engineReport.mismatches.length,
      unsupportedEngineRangeCount: engineReport.unsupported.length,
      engineMismatches: engineReport.mismatches,
      unsupportedEngineRanges: engineReport.unsupported,
      rootPackages
    };
    writeJson(path.join(bundleDir, 'summary.json'), summary);
    writeBundleReadme(bundleDir, options);
    createTransferTar(bundleDir, transferTarFile);

    const finalSummary = {
      ...summary,
      transferTarBytes: fs.statSync(transferTarFile).size,
      transferTarSha256: hashFile(transferTarFile, 'sha256')
    };

    console.log(JSON.stringify(finalSummary, null, 2));
  } finally {
    fs.rmSync(workRoot, { recursive: true, force: true });
  }
}

try {
  main();
} catch (error) {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
}
