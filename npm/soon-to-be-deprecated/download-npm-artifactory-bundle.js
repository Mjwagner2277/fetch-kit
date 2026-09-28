#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const { spawnSync } = require('child_process');

function usage() {
  console.log(`Download npm packages into an Artifactory-ready offline bundle.

Usage:
  node npm/soon-to-be-deprecated/download-npm-artifactory-bundle.js --node-version VERSION [options] <package...>
  node npm/soon-to-be-deprecated/download-npm-artifactory-bundle.js --node-version VERSION --package-lock FILE [options]

Examples:
  node npm/soon-to-be-deprecated/download-npm-artifactory-bundle.js --node-version 20.11.1 react lodash
  node npm/soon-to-be-deprecated/download-npm-artifactory-bundle.js --node-version 20.11.1 react@18.2.0
  node npm/soon-to-be-deprecated/download-npm-artifactory-bundle.js --node-version 18.20.4 --package @storybook/test-runner
  node npm/soon-to-be-deprecated/download-npm-artifactory-bundle.js --node-version 20.11.1 --packages-file packages.txt
  node npm/soon-to-be-deprecated/download-npm-artifactory-bundle.js --node-version 20.11.1 --update-all

Options:
  --node-version VERSION       Target Node.js version for engine checks. Required.
  --package SPEC              Package spec to add. May be repeated.
  --packages-file FILE        Package list file. May be repeated.
  --package-file FILE         Alias for --packages-file.
  --package-lock FILE         Fetch the exact dependency tree in a v1/v2/v3 lockfile.
  --destination-registry URL  Internal registry URL for the rewritten lockfile.
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
  --npm-bin PATH              npm executable or npm-cli.js. Defaults to npm.
  --max-version-probes N      Latest-compatible probes per package. Defaults to 50.
  --include-prerelease        Allow prerelease versions when searching latest-compatible.
  --omit-peer-dependencies    Do not include peer dependencies in the lockfile.
  --omit-optional-dependencies
                              Do not include optional dependencies in the lockfile.
  --allow-engine-mismatches   Record engines.node mismatches instead of failing.
  --no-normalize-library-package
                              Keep devDependencies; publish blockers are still removed.
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
    packageLock: '',
    destinationRegistry: '',
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
      case '--package-lock':
        options.packageLock = path.resolve(next());
        break;
      case '--destination-registry':
        options.destinationRegistry = next().replace(/\/+$/, '') + '/';
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
  if (options.packageLock && (options.packages.length || options.packagesFiles.length || options.updateAll
      || options.omitPeerDependencies || options.omitOptionalDependencies)) {
    fail('--package-lock cannot be combined with package inputs, --update-all, or --omit-* flags; every locked package is included');
  }
  if (options.destinationRegistry) {
    const destination = new URL(options.destinationRegistry);
    if (!['http:', 'https:'].includes(destination.protocol) || destination.username || destination.password
        || destination.search || destination.hash) {
      fail('--destination-registry must be an HTTP(S) registry URL without credentials, query, or fragment');
    }
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
    npm_config_engine_strict: 'false',
    npm_config_ignore_scripts: 'true'
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

function resolveNpmInvocation(npmBin) {
  const isFile = (file) => {
    try {
      return fs.statSync(file).isFile();
    } catch {
      return false;
    }
  };
  const nodeCli = (file) => ({ command: process.execPath, args: [file] });
  const isJavaScript = (file) => /\.[cm]?js$/i.test(file);
  if (isJavaScript(npmBin)) {
    const cli = path.resolve(npmBin);
    if (!isFile(cli)) fail(`npm CLI not found: ${cli}. Check --npm-bin or NPM_BIN.`);
    return nodeCli(cli);
  }
  if (process.platform !== 'win32') return { command: npmBin, args: [] };

  // Windows npm.cmd cannot be spawned directly. Find the selected installation
  // and invoke its CLI through Node so package arguments never pass through cmd.exe.
  const explicitPath = /[\\/]/.test(npmBin) || path.isAbsolute(npmBin);
  const pathKey = Object.keys(process.env).sort().find((key) => key.toLowerCase() === 'path');
  const directories = explicitPath ? [''] : (process.env[pathKey] || '').split(path.delimiter)
    .map((directory) => directory.replace(/^"(.*)"$/, '$1'));
  const names = path.extname(npmBin) ? [npmBin]
    : ['.exe', '.com', '.cmd', '.bat', ''].map((extension) => npmBin + extension);
  let launcher;
  for (const directory of directories) {
    launcher = names.map((name) => path.resolve(directory, name)).find(isFile);
    if (launcher) break;
  }
  if (!launcher) {
    // The standard Windows Node distribution bundles npm beside node.exe.
    if (!explicitPath && /^npm(?:\.cmd)?$/i.test(npmBin)) {
      const bundledCli = path.join(path.dirname(process.execPath), 'node_modules', 'npm', 'bin', 'npm-cli.js');
      if (isFile(bundledCli)) return nodeCli(bundledCli);
    }
    fail(`Cannot find npm launcher "${npmBin}" (ENOENT). Install Node.js with npm, add its directory to PATH, or set --npm-bin to the full path to npm-cli.js.`);
  }
  if (/\.(exe|com)$/i.test(launcher)) return { command: launcher, args: [] };
  const realLauncher = fs.realpathSync(launcher);
  if (isJavaScript(realLauncher)) return nodeCli(realLauncher);
  if (/^npm(?:\.(cmd|bat))?$/i.test(path.basename(launcher))) {
    const cli = path.join(path.dirname(realLauncher), 'node_modules', 'npm', 'bin', 'npm-cli.js');
    if (isFile(cli)) return nodeCli(cli);
  }
  fail(`Cannot locate npm-cli.js for "${launcher}". Set --npm-bin to the full path to npm-cli.js in the npm installation you want to use.`);
}

function runNpm(options, args, runOptions = {}) {
  const invocation = options.npmInvocation || (options.npmInvocation = resolveNpmInvocation(options.npmBin));
  return run(invocation.command, [...invocation.args, ...args], { ...runOptions, env: npmEnv(options) });
}

function run(command, args, options = {}) {
  const cwd = options.cwd || process.cwd();
  const result = spawnSync(command, args, {
    cwd,
    env: options.env || process.env,
    encoding: 'utf8',
    maxBuffer: 1024 * 1024 * 20
  });

  if (result.error) {
    if (result.error.code === 'ENOENT') {
      if (!fs.existsSync(cwd)) fail(`Working directory not found: ${cwd}`);
      const hint = command === 'tar' ? 'Install tar and add it to PATH.'
        : 'Check that it is installed and on PATH; for npm, set --npm-bin to its executable or npm-cli.js.';
      fail(`Cannot launch "${command}" (ENOENT). ${hint}`);
    }
    fail(`${command} failed to start: ${result.error.message}`);
  }

  if (result.status !== 0) {
    const output = `${result.stdout || ''}${result.stderr || ''}`.trim();
    fail(`${command} ${args.join(' ')} failed${output ? `:\n${output}` : ''}`);
  }

  return result.stdout || '';
}

function runNpmJson(options, args) {
  const stdout = runNpm(options, [...args, '--json', ...npmArgsWithConfig(options)]).trim();
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
  runNpm(options, [...args, ...npmArgsWithConfig(options)], {
    cwd: projectDir
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

function collectLockPackages(lock, strict = false) {
  if (strict && ![1, 2, 3].includes(lock.lockfileVersion)) {
    fail('Unsupported lockfileVersion; --package-lock requires npm lockfile v1, v2, or v3');
  }
  const records = new Map();
  function add(lockPath, meta, fallbackName) {
    if (!meta || typeof meta !== 'object') fail(`Invalid lockfile entry: ${lockPath}`);
    let name = meta.name || fallbackName || packageNameFromLockPath(lockPath);
    let version = String(meta.version || '');
    const alias = version.match(/^npm:(.+)@([^@]+)$/);
    if (alias) [, name, version] = alias;
    if (strict && (meta.link || !/^(?:node_modules\/(?:@[^/]+\/)?[^/]+\/)*node_modules\/(?:@[^/]+\/)?[^/]+$/.test(lockPath)
        || lockPath.split('/').some((part) => part === '.' || part === '..') || !name || !parseSemver(version))) {
      fail(`Unsupported local, workspace, git, or non-exact lockfile entry: ${lockPath} (${version})`);
    }
    if (!name || !version) return;
    if (strict && meta.resolved && !/^https?:\/\//i.test(meta.resolved)) {
      fail(`Unsupported resolved source for ${lockPath}: only HTTP(S) tarballs are supported`);
    }
    if (records.has(lockPath)) {
      const existing = records.get(lockPath);
      if (existing.name !== name || existing.version !== version) fail(`Inconsistent v2 lockfile entry: ${lockPath}`);
      if (strict && ((existing.integrity && meta.integrity && existing.integrity !== meta.integrity)
          || (existing.resolved && meta.resolved && existing.resolved !== meta.resolved))) {
        fail(`Conflicting sources or integrity in v2 lockfile entry: ${lockPath}`);
      }
      existing.lockEntries.push(meta);
      return;
    }
    records.set(lockPath, {
      name, version, key: `${name}@${version}`, lockPath,
      resolved: meta.resolved || '', integrity: meta.integrity || '',
      engines: meta.engines || {}, optional: Boolean(meta.optional), dev: Boolean(meta.dev),
      inBundle: Boolean(meta.inBundle || meta.bundled), lockEntries: [meta]
    });
  }
  if (lock.packages && typeof lock.packages === 'object') {
    for (const [lockPath, meta] of Object.entries(lock.packages)) {
      if (lockPath) add(lockPath, meta);
    }
  }
  function walkLegacy(dependencies, parentPath = '') {
    for (const [name, meta] of Object.entries(dependencies || {})) {
      const lockPath = `${parentPath ? `${parentPath}/` : ''}node_modules/${name}`;
      add(lockPath, meta, name);
      walkLegacy(meta.dependencies, lockPath);
    }
  }
  if (lock.lockfileVersion === 1 || lock.lockfileVersion === 2) walkLegacy(lock.dependencies);
  const byKey = new Map();
  for (const record of records.values()) {
    if (record.inBundle) continue;
    const existing = byKey.get(record.key);
    if (existing) {
      if (strict && (existing.resolved !== record.resolved || existing.integrity !== record.integrity)) {
        fail(`Conflicting sources or integrity for ${record.key}; one registry version cannot represent both lock entries`);
      }
      existing.lockPaths.push(record.lockPath);
      existing.lockEntries.push(...record.lockEntries);
    } else {
      byKey.set(record.key, { ...record, lockPaths: [record.lockPath], bundledPackages: [] });
    }
  }
  for (const record of records.values()) {
    if (!record.inBundle) continue;
    let ownerPath = record.lockPath;
    let owner;
    while (ownerPath.includes('/node_modules/')) {
      ownerPath = ownerPath.slice(0, ownerPath.lastIndexOf('/node_modules/'));
      const candidate = records.get(ownerPath);
      if (candidate && !candidate.inBundle) { owner = candidate; break; }
    }
    if (!owner) fail(`Bundled lock entry has no containing package: ${record.lockPath}`);
    byKey.get(owner.key).bundledPackages.push({ ...record, tarPath: `package/${record.lockPath.slice(ownerPath.length + 1)}/package.json` });
  }

  return [...byKey.values()].sort((left, right) => {
    if (left.name !== right.name) {
      return left.name < right.name ? -1 : 1;
    }
    return compareSemver(left.version, right.version);
  });
}

function verifyOriginalIntegrity(file, integrity, label) {
  if (!integrity) {
    log(`WARNING: ${label} has no lockfile integrity; only package identity can be verified`);
    return false;
  }
  const strengths = ['sha512', 'sha384', 'sha256', 'sha1'];
  const tokens = String(integrity).trim().split(/\s+/).map((token) => token.match(/^(sha512|sha384|sha256|sha1)-([A-Za-z0-9+/]+={0,2})(?:\?.*)?$/)).filter(Boolean);
  const algorithm = strengths.find((candidate) => tokens.some((token) => token[1] === candidate));
  if (!algorithm) fail(`Unsupported or malformed lockfile integrity for ${label}`);
  const actual = crypto.createHash(algorithm).update(fs.readFileSync(file)).digest('base64');
  if (!tokens.some((token) => token[1] === algorithm && token[2] === actual)) {
    fail(`Original tarball integrity mismatch for ${label}; download rejected before sanitization`);
  }
  return true;
}

function rewriteLockPackage(pkg, integrity, options) {
  for (const entry of pkg.lockEntries) {
    entry.integrity = integrity;
    delete entry.hasInstallScript;
    if (options.destinationRegistry) {
      const basename = pkg.name.split('/').pop();
      entry.resolved = `${options.destinationRegistry}${pkg.name}/-/${basename}-${pkg.version}.tgz`;
    } else {
      delete entry.resolved;
    }
  }
  for (const bundled of pkg.bundledPackages) {
    for (const entry of bundled.lockEntries) {
      delete entry.hasInstallScript;
      delete entry.integrity;
      delete entry.resolved;
    }
  }
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

function packPackage(pkg, options, rawTarballDir) {
  const packageRef = options.packageLock && pkg.resolved ? pkg.resolved : `${pkg.name}@${pkg.version}`;
  log(`Packing ${packageRef}`);
  const output = runNpm(options, [
    'pack',
    packageRef,
    '--ignore-scripts',
    '--json',
    `--pack-destination=${rawTarballDir}`,
    ...npmArgsWithConfig(options)
  ]);

  const parsed = JSON.parse(output);
  const first = Array.isArray(parsed) ? parsed[0] : parsed;
  if (!first || !first.filename) {
    fail(`npm pack did not return a filename for ${packageRef}`);
  }
  const rawTarball = path.resolve(rawTarballDir, first.filename);
  if (!rawTarball.startsWith(`${rawTarballDir}${path.sep}`)) fail('npm pack returned an unsafe filename');
  return {
    rawTarball,
    npmPack: first
  };
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
    'Use upload-npm-artifactory-bundle.py with this transfer tar, or use packages.json,',
    'packages.jsonl, or artifactory-upload-manifest.tsv as custom uploader input.',
    '',
    'Files:',
    '  package.json                    Root requested package set used for resolution.',
    '  package-lock.json               npm lockfile for the resolved offline dependency tree.',
    '  package-lock.original.json      Original lockfile before sanitized integrity rewriting.',
    '  packages.json                   Machine-readable package/tarball manifest.',
    '  packages.tsv                    Human-readable package/tarball list.',
    '  artifactory-upload-manifest.tsv Tab-separated name/version/tarball manifest.',
    '  tarballs/                       Packed npm tarballs ready to publish.',
    '  state/                          Snapshot of the local per-node-version state file.',
    '',
    'Every tarball was sanitized before bundling to remove npm publish blockers',
    'from package/package.json, then validated to confirm the expected package',
    'name and version.',
    'The rewritten lockfile uses sanitized tarball integrity. When no destination registry',
    'was supplied, resolved URLs are omitted so npm uses its configured registry.',
    '',
    'Tarball package.json files are library-normalized by default: devDependencies are removed.',
    'Runtime fields and dependencies are preserved unless strip flags were used.',
    'Removed install scripts may have supplied native binaries or generated files.',
    'See summary.json offlineWarnings; prepare and test such assets before airgap transfer.',
    'Use npm ci --ignore-scripts with the rewritten lockfile and your internal registry.'
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
  if (requests.length === 0 && !options.packageLock) {
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

    const lockFile = path.join(projectDir, 'package-lock.json');
    if (options.packageLock) {
      fs.copyFileSync(options.packageLock, lockFile);
      const suppliedLock = readJson(lockFile);
      const siblingManifest = path.join(path.dirname(options.packageLock), 'package.json');
      let rootManifest;
      if (fs.existsSync(siblingManifest)) {
        rootManifest = readJson(siblingManifest);
      } else if (suppliedLock.packages && suppliedLock.packages['']) {
        rootManifest = { ...suppliedLock.packages[''], name: suppliedLock.name || 'offline-lockfile-bundle', version: suppliedLock.version || '0.0.0', private: true };
      } else {
        rootManifest = makePackageJson(Object.fromEntries(Object.entries(suppliedLock.dependencies || {}).map(([name, meta]) => [name, meta.version])));
        log('No adjacent package.json found: generated a manifest from the v1 top-level lock entries; use your original project package.json for installation');
      }
      writeJson(path.join(projectDir, 'package.json'), rootManifest);
      log(`Reading exact packages from ${options.packageLock}; retaining all locked platforms and optional dependencies`);
    } else {
      writeJson(path.join(projectDir, 'package.json'), makePackageJson(dependencies));
      log(`Resolving dependency tree for Node ${options.nodeVersion}`);
      npmInstallLock(projectDir, options);
    }
    const lock = readJson(lockFile);
    const resolvedPackages = collectLockPackages(lock, Boolean(options.packageLock));
    if (resolvedPackages.length === 0) {
      fail('Lockfile has no independently resolved packages');
    }
    if (options.packageLock) {
      for (const pkg of resolvedPackages) {
        for (const lockPath of pkg.lockPaths.filter((value) => value === `node_modules/${packageNameFromLockPath(value)}`)) {
          rootPackages.push({ name: pkg.name, installName: packageNameFromLockPath(lockPath), requested: pkg.version, spec: pkg.key, resolvedVersion: pkg.version, resolvedSpec: pkg.key });
        }
      }
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
    fs.copyFileSync(lockFile, path.join(bundleDir, 'package-lock.original.json'));

    const manifestItems = [];
    for (const pkg of resolvedPackages) {
      const packed = packPackage(pkg, options, rawTarballDir);
      const originalIntegrityVerified = options.packageLock
        ? verifyOriginalIntegrity(packed.rawTarball, pkg.integrity, pkg.key)
        : false;
      const tarballName = safeTarballName(pkg.name, pkg.version);
      const finalTarball = path.join(tarballDir, tarballName);

      const sanitization = sanitizeTarballForAirgapPublish(packed.rawTarball, finalTarball, options);
      validatePackageTarball(pkg, finalTarball, workRoot);

      const stat = fs.statSync(finalTarball);
      const integrity = `sha512-${crypto.createHash('sha512').update(fs.readFileSync(finalTarball)).digest('base64')}`;
      rewriteLockPackage(pkg, integrity, options);
      for (const warning of sanitization.offlineWarnings) log(`WARNING: ${pkg.key}: ${warning}`);
      manifestItems.push({
        name: pkg.name,
        version: pkg.version,
        package: `${pkg.name}@${pkg.version}`,
        tarball: path.relative(bundleDir, finalTarball).replace(/\\/g, '/'),
        sha1: hashFile(finalTarball, 'sha1'),
        sha512: hashFile(finalTarball, 'sha512'),
        integrity,
        bytes: stat.size,
        lockPath: pkg.lockPath,
        lockPaths: pkg.lockPaths,
        resolved: pkg.resolved,
        registryIntegrity: pkg.integrity,
        originalIntegrityVerified,
        engines: pkg.engines,
        enginesNode: pkg.enginesNode || '',
        engineCompatible: pkg.engineCompatible,
        engineRangeSupported: pkg.engineRangeSupported,
        normalized: options.normalizeLibraryPackage,
        publishSanitized: true,
        publishSanitizedFields: sanitization.removedFields,
        sanitizedPackages: sanitization.sanitizedPackages,
        offlineWarnings: sanitization.offlineWarnings,
        packageJsonValidated: true,
        root: rootPackages.some((root) => root.name === pkg.name && root.resolvedVersion === pkg.version),
        optional: pkg.optional,
        dev: pkg.dev,
        npmPack: packed.npmPack
      });
    }

    writeJson(path.join(bundleDir, 'package-lock.json'), lock);
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
      publishSanitized: true,
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
      inputMode: options.packageLock ? 'package-lock' : 'package-list',
      sourceLockfile: options.packageLock || '',
      destinationRegistry: options.destinationRegistry || 'npm-config-default',
      lockfileIntegrityRewritten: true,
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
      publishSanitized: true,
      stripPeerDependencies: options.stripPeerDependencies,
      stripOptionalDependencies: options.stripOptionalDependencies,
      engineMismatchCount: engineReport.mismatches.length,
      unsupportedEngineRangeCount: engineReport.unsupported.length,
      engineMismatches: engineReport.mismatches,
      unsupportedEngineRanges: engineReport.unsupported,
      offlineWarnings: manifestItems.flatMap((item) => item.offlineWarnings.map((warning) => `${item.package}: ${warning}`)),
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

// Shared archive operations are also used by the HTTP-only downloader. Importing
// this module must never launch npm or execute its command-line entry point.
module.exports = {
  readPackagesFile, splitPackageSpec, sanitizeTarballForAirgapPublish,
  validatePackageTarball, readTarRecords, verifyOriginalIntegrity,
  hashFile, safeTarballName, encodeTarRecord,
  resolveNpmInvocation, runNpm
};

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(`ERROR: ${error.message}`);
    process.exit(1);
  }
}
