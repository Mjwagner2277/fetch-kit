#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

function usage() {
  console.log(`Upload an npm transfer bundle to an Artifactory npm repository.

Usage:
  node npm/upload-npm-artifactory-bundle.js --bundle-tar FILE --registry-url URL [options]

Options:
  --bundle-tar FILE          Transfer tar produced by download-npm-artifactory-bundle.js.
  --bundle-dir DIR           Already-extracted bundle directory. Alternative to --bundle-tar.
  --registry-url URL         Artifactory npm registry URL.
  --userconfig FILE          npmrc file for Artifactory auth.
  --token TOKEN              Artifactory token. Defaults to ARTIFACTORY_TOKEN.
  --username USER            Artifactory username. Defaults to ARTIFACTORY_USERNAME.
  --password PASSWORD        Artifactory password/API key. Defaults to ARTIFACTORY_PASSWORD.
  --no-ssl                   Disable npm SSL certificate validation.
  --work-dir DIR             Working directory for extraction, npmrc, logs, and summaries.
  --keep-work-dir            Keep a temporary work directory after completion.
  --skip-existing            Treat already-published versions as success. Default.
  --no-skip-existing         Treat already-published versions as failures.
  --dry-run                  Query Artifactory and print planned publish actions.
  --latest-policy POLICY     computed, never, or force-computed. Defaults to computed.
  --fail-on-remote-query-error
                             Fail if Artifactory versions cannot be queried.
                             Default is to avoid latest for that package and continue.
  --tag-prefix PREFIX        Prefix for non-latest dist-tags. Defaults to airgap-.
  --publish-retries N        Retries after a failed publish attempt. Defaults to 2.
  --retry-delay-ms N         Delay between publish retries. Defaults to 1000.
  --npm-bin PATH             npm executable. Defaults to npm.
  --npm-flags FLAGS          Extra flags appended to npm publish.
  -h, --help                 Show this help.

latest-policy:
  computed        Query Artifactory versions for every package. An incoming stable
                  version only gets latest if it is the highest stable version
                  across both Artifactory and the incoming bundle.
                  If lookup fails for one package, avoid latest for that package
                  and continue unless --fail-on-remote-query-error is set.
  never           Never publish with latest. Every version gets PREFIX<version>.
  force-computed  Compute latest from the incoming bundle only. This can move
                  latest backwards if Artifactory already has a newer version.
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
    bundleTar: '',
    bundleDir: '',
    registryUrl: '',
    userconfig: '',
    token: process.env.ARTIFACTORY_TOKEN || '',
    username: process.env.ARTIFACTORY_USERNAME || '',
    password: process.env.ARTIFACTORY_PASSWORD || '',
    strictSsl: true,
    workDir: '',
    keepWorkDir: false,
    skipExisting: true,
    dryRun: false,
    latestPolicy: 'computed',
    failOnRemoteQueryError: false,
    tagPrefix: 'airgap-',
    publishRetries: 2,
    retryDelayMs: 1000,
    npmBin: process.env.NPM_BIN || 'npm',
    npmFlags: process.env.NPM_FLAGS || ''
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
      case '--bundle-tar':
        options.bundleTar = path.resolve(next());
        break;
      case '--bundle-dir':
        options.bundleDir = path.resolve(next());
        break;
      case '--registry-url':
        options.registryUrl = next();
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
      case '--work-dir':
        options.workDir = path.resolve(next());
        break;
      case '--keep-work-dir':
        options.keepWorkDir = true;
        break;
      case '--skip-existing':
        options.skipExisting = true;
        break;
      case '--no-skip-existing':
        options.skipExisting = false;
        break;
      case '--dry-run':
        options.dryRun = true;
        break;
      case '--latest-policy':
        options.latestPolicy = next();
        break;
      case '--fail-on-remote-query-error':
        options.failOnRemoteQueryError = true;
        break;
      case '--tag-prefix':
        options.tagPrefix = next();
        break;
      case '--publish-retries':
        options.publishRetries = Number.parseInt(next(), 10);
        break;
      case '--retry-delay-ms':
        options.retryDelayMs = Number.parseInt(next(), 10);
        break;
      case '--npm-bin':
        options.npmBin = next();
        break;
      case '--npm-flags':
        options.npmFlags = next();
        break;
      default:
        fail(`Unknown argument: ${arg}`);
    }
  }

  if (!['computed', 'never', 'force-computed'].includes(options.latestPolicy)) {
    fail('--latest-policy must be computed, never, or force-computed');
  }
  if (!options.tagPrefix || !/^[A-Za-z][A-Za-z0-9._-]*$/.test(options.tagPrefix)) {
    fail('--tag-prefix must start with a letter and contain only letters, numbers, dots, underscores, or hyphens');
  }
  if (!Number.isInteger(options.publishRetries) || options.publishRetries < 0) {
    fail('--publish-retries must be a non-negative integer');
  }
  if (!Number.isInteger(options.retryDelayMs) || options.retryDelayMs < 0) {
    fail('--retry-delay-ms must be a non-negative integer');
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

function highestStable(versions) {
  return versions
    .filter((version) => parseSemver(version) && !isPrerelease(version))
    .sort(compareSemver)
    .pop() || '';
}

function mirrorTagForVersion(version, prefix) {
  const safeVersion = String(version).replace(/[^A-Za-z0-9._-]/g, '-');
  return `${prefix}${safeVersion}`;
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

  return result;
}

function requireSuccess(result, command, args) {
  if (result.status !== 0) {
    const output = `${result.stdout || ''}${result.stderr || ''}`.trim();
    fail(`${command} ${args.join(' ')} failed${output ? `:\n${output}` : ''}`);
  }
  return result.stdout || '';
}

function registryAuthFragment(registryUrl) {
  const registry = registryUrl.replace(/^https?:\/\//, '').replace(/\/+$/, '/');
  return `//${registry}`;
}

function writeGeneratedNpmrc(options, workDir) {
  if (options.userconfig) {
    return options.userconfig;
  }
  if (!options.token && (!options.username || !options.password)) {
    fail('Set --userconfig, --token, or --username plus --password');
  }

  const registry = options.registryUrl.replace(/\/+$/, '/');
  const fragment = registryAuthFragment(registry);
  const npmrc = path.join(workDir, 'artifactory.npmrc');
  const lines = [
    `registry=${registry}`,
    `${fragment}:always-auth=true`
  ];
  if (!options.strictSsl) {
    lines.push('strict-ssl=false');
  }

  if (options.token) {
    lines.push(`${fragment}:_authToken=${options.token}`);
  } else {
    lines.push(`${fragment}:username=${options.username}`);
    lines.push(`${fragment}:_password=${Buffer.from(options.password).toString('base64')}`);
    lines.push(`${fragment}:email=npm-artifactory-uploader@example.invalid`);
  }

  fs.writeFileSync(npmrc, `${lines.join('\n')}\n`);
  return npmrc;
}

function npmConfigArgs(options) {
  const args = [
    `--registry=${options.registryUrl}`,
    `--userconfig=${options.userconfig}`
  ];
  if (!options.strictSsl) {
    args.push('--strict-ssl=false');
  }
  return args;
}

function splitNpmFlags(flags) {
  if (!flags || !String(flags).trim()) {
    return [];
  }
  return String(flags).match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g)
    .map((part) => part.replace(/^['"]|['"]$/g, ''));
}

function sleep(ms) {
  if (ms <= 0) {
    return;
  }
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function extractBundle(options, workDir) {
  if (options.bundleDir) {
    if (!fs.existsSync(options.bundleDir) || !fs.statSync(options.bundleDir).isDirectory()) {
      fail(`Bundle directory not found: ${options.bundleDir}`);
    }
    return options.bundleDir;
  }

  if (!options.bundleTar) {
    fail('Set --bundle-tar or --bundle-dir');
  }
  if (!fs.existsSync(options.bundleTar)) {
    fail(`Bundle tar not found: ${options.bundleTar}`);
  }

  const extractDir = path.join(workDir, 'extract');
  mkdirp(extractDir);
  requireSuccess(run('tar', ['-xf', options.bundleTar, '-C', extractDir]), 'tar', ['-xf', options.bundleTar, '-C', extractDir]);

  const entries = fs.readdirSync(extractDir)
    .filter((entry) => !entry.startsWith('.'))
    .map((entry) => path.join(extractDir, entry));
  const directories = entries.filter((entry) => fs.statSync(entry).isDirectory());
  if (directories.length === 1) {
    return directories[0];
  }
  return extractDir;
}

function readPackagesJsonl(file) {
  return fs.readFileSync(file, 'utf8')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function readPackagesTsv(file) {
  return fs.readFileSync(file, 'utf8')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .filter((line) => !/^name\tversion\ttarball$/i.test(line))
    .map((line) => {
      const [name, version, tarball] = line.split('\t');
      return { name, version, tarball, package: `${name}@${version}` };
    });
}

function readManifest(bundleDir) {
  const jsonl = path.join(bundleDir, 'packages.jsonl');
  const json = path.join(bundleDir, 'packages.json');
  const tsv = path.join(bundleDir, 'artifactory-upload-manifest.tsv');

  let packages;
  let manifestFile;
  if (fs.existsSync(jsonl)) {
    packages = readPackagesJsonl(jsonl);
    manifestFile = jsonl;
  } else if (fs.existsSync(json)) {
    packages = readJson(json);
    manifestFile = json;
  } else if (fs.existsSync(tsv)) {
    packages = readPackagesTsv(tsv);
    manifestFile = tsv;
  } else {
    fail(`No manifest found in ${bundleDir}`);
  }

  const normalized = packages.map((pkg) => {
    const name = pkg.name || pkg.Name;
    const version = String(pkg.version || pkg.Version || '');
    const tarball = pkg.tarball || pkg.Tarball;
    if (!name || !version || !tarball) {
      fail(`Manifest entry is missing name, version, or tarball: ${JSON.stringify(pkg)}`);
    }
    return {
      ...pkg,
      name,
      version,
      package: pkg.package || pkg.Package || `${name}@${version}`,
      tarball,
      tarballPath: path.resolve(bundleDir, tarball)
    };
  });

  for (const pkg of normalized) {
    if (!fs.existsSync(pkg.tarballPath)) {
      fail(`Tarball not found for ${pkg.package}: ${pkg.tarballPath}`);
    }
  }

  return { manifestFile, packages: normalized };
}

function sortPackagesForPublish(packages) {
  return [...packages].sort((left, right) => {
    if (left.name !== right.name) {
      return left.name < right.name ? -1 : 1;
    }
    return compareSemver(left.version, right.version);
  });
}

function groupByPackageName(packages) {
  const groups = new Map();
  for (const pkg of packages) {
    const group = groups.get(pkg.name) || [];
    group.push(pkg);
    groups.set(pkg.name, group);
  }
  return groups;
}

function npmViewVersions(packageName, options) {
  const args = [
    'view',
    packageName,
    'versions',
    '--json',
    ...npmConfigArgs(options)
  ];
  const result = run(options.npmBin, args);
  if (result.status === 0) {
    const text = String(result.stdout || '').trim();
    if (!text) {
      return { ok: true, versions: [] };
    }
    const parsed = JSON.parse(text);
    const versions = Array.isArray(parsed) ? parsed : [parsed].filter(Boolean);
    return { ok: true, versions: versions.map(String) };
  }

  const output = `${result.stdout || ''}${result.stderr || ''}`;
  if (/E404|404 Not Found|not found/i.test(output)) {
    return { ok: true, versions: [], notFound: true };
  }

  return { ok: false, versions: [], error: output.trim() || `npm view exited ${result.status}` };
}

function buildTagPlan(packages, options) {
  const groups = groupByPackageName(packages);
  const plan = new Map();
  const remoteByPackage = {};

  for (const [packageName, group] of groups.entries()) {
    const incomingVersions = group.map((pkg) => pkg.version);
    let remoteVersions = [];

    if (options.latestPolicy === 'computed') {
      log(`Querying Artifactory versions for ${packageName}`);
      const remote = npmViewVersions(packageName, options);
      if (!remote.ok) {
        if (options.failOnRemoteQueryError) {
          fail(`Could not query Artifactory versions for ${packageName}. Use --latest-policy never to avoid latest tags, or fix the registry query.\n${remote.error}`);
        }
        remoteByPackage[packageName] = {
          versions: [],
          notFound: false,
          queryOk: false,
          error: remote.error,
          latestProtected: true
        };
        for (const pkg of group) {
          plan.set(`${pkg.name}@${pkg.version}`, {
            distTag: mirrorTagForVersion(pkg.version, options.tagPrefix),
            latestReason: 'remote-query-failed-avoid-latest',
            highestStableVersion: '',
            remoteVersionCount: 0,
            remoteHasNewerStable: false,
            remoteQueryOk: false,
            remoteQueryError: remote.error
          });
        }
        continue;
      }
      remoteVersions = remote.versions;
      remoteByPackage[packageName] = {
        versions: remoteVersions,
        notFound: Boolean(remote.notFound),
        queryOk: true,
        error: '',
        latestProtected: false
      };
    } else {
      remoteByPackage[packageName] = {
        versions: [],
        notFound: false,
        queryOk: true,
        error: '',
        skipped: options.latestPolicy !== 'computed',
        latestProtected: false
      };
    }

    const highest = options.latestPolicy === 'force-computed'
      ? highestStable(incomingVersions)
      : highestStable([...remoteVersions, ...incomingVersions]);

    for (const pkg of group) {
      let distTag = mirrorTagForVersion(pkg.version, options.tagPrefix);
      let latestReason = 'non-latest-version';

      if (isPrerelease(pkg.version)) {
        latestReason = 'prerelease';
      } else if (options.latestPolicy === 'never') {
        latestReason = 'latest-policy-never';
      } else if (highest && pkg.version === highest) {
        distTag = 'latest';
        latestReason = options.latestPolicy === 'computed' ? 'highest-stable-across-artifactory-and-bundle' : 'highest-stable-in-bundle';
      } else if (highest) {
        latestReason = `highest-stable-is-${highest}`;
      }

      plan.set(`${pkg.name}@${pkg.version}`, {
        distTag,
        latestReason,
        highestStableVersion: highest,
        remoteVersionCount: remoteVersions.length,
        remoteHasNewerStable: Boolean(highest && compareSemver(highest, pkg.version) > 0),
        remoteQueryOk: true,
        remoteQueryError: ''
      });
    }
  }

  return { plan, remoteByPackage };
}

function publishPackage(pkg, tag, options, publishLog) {
  const args = [
    'publish',
    pkg.tarballPath,
    ...npmConfigArgs(options),
    '--tag',
    tag,
    '--ignore-scripts',
    ...splitNpmFlags(options.npmFlags)
  ];

  let lastOutput = '';
  for (let attempt = 0; attempt <= options.publishRetries; attempt += 1) {
    const result = run(options.npmBin, args);
    lastOutput = `${result.stdout || ''}${result.stderr || ''}`;
    fs.appendFileSync(publishLog, `[attempt ${attempt + 1}] ${pkg.name}@${pkg.version} tag=${tag}\n${lastOutput}\n`);

    if (result.status === 0) {
      return { status: 'published', output: result.stdout || '', attempts: attempt + 1 };
    }

    if (options.skipExisting &&
        /EPUBLISHCONFLICT|already exists|already present|cannot publish over|409|conflict/i.test(lastOutput)) {
      return { status: 'skipped-existing', output: lastOutput, attempts: attempt + 1 };
    }

    if (attempt < options.publishRetries) {
      sleep(options.retryDelayMs);
    }
  }

  return { status: 'failed', output: lastOutput, attempts: options.publishRetries + 1 };
}

function writeResult(resultsJsonl, result) {
  fs.appendFileSync(resultsJsonl, `${JSON.stringify(result)}\n`);
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    usage();
    return;
  }
  if (!options.registryUrl) {
    fail('--registry-url is required');
  }
  if (options.bundleTar && options.bundleDir) {
    fail('Use only one of --bundle-tar or --bundle-dir');
  }

  const createdTempWorkDir = !options.workDir;
  const workDir = options.workDir || fs.mkdtempSync(path.join(os.tmpdir(), 'npm-artifactory-upload-'));
  mkdirp(workDir);

  try {
    options.userconfig = writeGeneratedNpmrc(options, workDir);

    const bundleDir = extractBundle(options, workDir);
    const { manifestFile, packages } = readManifest(bundleDir);
    const sortedPackages = sortPackagesForPublish(packages);
    const { plan, remoteByPackage } = buildTagPlan(sortedPackages, options);

    const resultsJsonl = path.join(workDir, 'upload-results.jsonl');
    const resultsJson = path.join(workDir, 'upload-results.json');
    const summaryJson = path.join(workDir, 'upload-summary.json');
    const publishLog = path.join(workDir, 'npm-publish.log');
    fs.writeFileSync(resultsJsonl, '');
    fs.writeFileSync(publishLog, '');

    let published = 0;
    let skippedExisting = 0;
    let dryRun = 0;
    let failed = 0;
    const results = [];

    for (const pkg of sortedPackages) {
      const tag = plan.get(`${pkg.name}@${pkg.version}`);
      const baseResult = {
        package: pkg.name,
        version: pkg.version,
        packageRef: `${pkg.name}@${pkg.version}`,
        tarball: path.relative(bundleDir, pkg.tarballPath).replace(/\\/g, '/'),
        distTag: tag.distTag,
        latestReason: tag.latestReason,
        highestStableVersion: tag.highestStableVersion,
        remoteHasNewerStable: tag.remoteHasNewerStable,
        remoteQueryOk: tag.remoteQueryOk,
        remoteQueryError: tag.remoteQueryError,
        publishAttempts: 0
      };

      if (options.dryRun) {
        log(`DRY_RUN would publish ${baseResult.packageRef} with dist-tag ${tag.distTag}`);
        dryRun += 1;
        const result = { ...baseResult, status: 'dry-run', error: '' };
        results.push(result);
        writeResult(resultsJsonl, result);
        continue;
      }

      log(`Publishing ${baseResult.packageRef} with dist-tag ${tag.distTag}`);
      const publishResult = publishPackage(pkg, tag.distTag, options, publishLog);
      if (publishResult.status === 'published') {
        published += 1;
      } else if (publishResult.status === 'skipped-existing') {
        skippedExisting += 1;
      } else {
        failed += 1;
      }

      const result = {
        ...baseResult,
        status: publishResult.status,
        publishAttempts: publishResult.attempts,
        error: publishResult.status === 'failed' ? publishResult.output : ''
      };
      results.push(result);
      writeResult(resultsJsonl, result);
    }

    writeJson(resultsJson, results);
    const summary = {
      registryUrl: options.registryUrl,
      strictSsl: options.strictSsl,
      latestPolicy: options.latestPolicy,
      skipExisting: options.skipExisting,
      failOnRemoteQueryError: options.failOnRemoteQueryError,
      publishRetries: options.publishRetries,
      bundleDir,
      manifestFile,
      workDir,
      resultsFile: resultsJson,
      publishLog,
      packageCount: sortedPackages.length,
      published,
      skippedExisting,
      dryRun,
      failed,
      remoteByPackage,
      results
    };
    writeJson(summaryJson, summary);
    console.log(JSON.stringify(summary, null, 2));

    if (failed > 0) {
      process.exitCode = 1;
    }
  } finally {
    if (createdTempWorkDir && !options.keepWorkDir) {
      fs.rmSync(workDir, { recursive: true, force: true });
    }
  }
}

try {
  main();
} catch (error) {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
}
