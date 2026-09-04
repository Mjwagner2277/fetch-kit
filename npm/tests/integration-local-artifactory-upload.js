#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');
const http = require('http');
const https = require('https');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const repoRoot = path.resolve(__dirname, '..', '..');
const uploader = path.join(repoRoot, 'npm', 'upload-npm-artifactory-bundle.js');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'npm-artifactory-integration-'));

function skip(message) {
  console.log(`SKIP: ${message}`);
  process.exit(77);
}

function errorText(error) {
  const parts = [];
  if (error && error.message) {
    parts.push(error.message);
  }
  if (error && error.code) {
    parts.push(error.code);
  }
  if (error && Array.isArray(error.errors)) {
    for (const inner of error.errors) {
      parts.push(errorText(inner));
    }
  }
  return parts.filter(Boolean).join(' ');
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || repoRoot,
    env: options.env || process.env,
    encoding: 'utf8',
    maxBuffer: 1024 * 1024 * 20
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== (options.status ?? 0)) {
    throw new Error(`${command} ${args.join(' ')} exited ${result.status}\nSTDOUT:\n${result.stdout}\nSTDERR:\n${result.stderr}`);
  }
  return result.stdout;
}

function authHeaders() {
  const token = process.env.ARTIFACTORY_TOKEN || '';
  const username = process.env.ARTIFACTORY_USERNAME || 'admin';
  const password = process.env.ARTIFACTORY_PASSWORD || 'password';
  if (token) {
    return { Authorization: `Bearer ${token}` };
  }
  return {
    Authorization: `Basic ${Buffer.from(`${username}:${password}`).toString('base64')}`
  };
}

function request(method, url, body) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const transport = parsed.protocol === 'https:' ? https : http;
    const payload = body ? JSON.stringify(body) : '';
    const req = transport.request(parsed, {
      method,
      headers: {
        ...authHeaders(),
        Accept: 'application/json',
        ...(payload ? {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(payload)
        } : {})
      }
    }, (res) => {
      let responseBody = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => {
        responseBody += chunk;
      });
      res.on('end', () => {
        resolve({ status: res.statusCode || 0, body: responseBody });
      });
    });
    req.on('error', reject);
    if (payload) {
      req.write(payload);
    }
    req.end();
  });
}

function registryFromBase(baseUrl, repoKey) {
  return `${baseUrl.replace(/\/+$/, '')}/api/npm/${repoKey}/`;
}

async function ensureRegistry() {
  const explicitRegistry = process.env.ARTIFACTORY_NPM_REGISTRY || '';
  if (explicitRegistry) {
    return {
      registryUrl: explicitRegistry.replace(/\/?$/, '/'),
      cleanup: async () => {}
    };
  }

  const baseUrl = process.env.ARTIFACTORY_URL || 'http://localhost:8082/artifactory';
  const explicitRepo = process.env.ARTIFACTORY_NPM_REPO || '';
  const autoRepoKey = `fetch-kit-npm-test-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`;
  const repoKey = explicitRepo || autoRepoKey;
  const repoUrl = `${baseUrl.replace(/\/+$/, '')}/api/repositories/${repoKey}`;

  let repoExisted = false;
  try {
    const existing = await request('GET', repoUrl);
    if (existing.status === 200) {
      repoExisted = true;
    } else if (existing.status !== 404) {
      const message = `${existing.status} ${existing.body}`.trim();
      if (/available only in Artifactory Pro|unsupported package type|license/i.test(message)) {
        skip(`local Artifactory cannot provide npm repositories: ${message}`);
      }
      throw new Error(`Could not inspect Artifactory repository ${repoKey}: ${message}`);
    }
  } catch (error) {
    const message = errorText(error);
    if (/ECONNREFUSED|ENOTFOUND|EHOSTUNREACH|ETIMEDOUT|EPERM|socket hang up/i.test(message)) {
      skip(`local Artifactory is not reachable at ${baseUrl}`);
    }
    throw error;
  }

  if (!repoExisted) {
    const create = await request('PUT', repoUrl, {
      rclass: 'local',
      packageType: 'npm',
      repoLayoutRef: 'npm-default',
      description: 'fetch-kit local npm uploader integration test'
    });
    if (![200, 201].includes(create.status)) {
      const message = `${create.status} ${create.body}`.trim();
      if (/available only in Artifactory Pro|unsupported package type|license/i.test(message)) {
        skip(`local Artifactory cannot create npm repositories: ${message}`);
      }
      throw new Error(`Could not create Artifactory npm repository ${repoKey}: ${message}`);
    }
  }

  return {
    registryUrl: registryFromBase(baseUrl, repoKey),
    cleanup: async () => {
      if (!explicitRepo && process.env.KEEP_ARTIFACTORY_TEST_REPO !== 'true') {
        await request('DELETE', repoUrl);
      }
    }
  };
}

function writeNpmrc(registryUrl) {
  const token = process.env.ARTIFACTORY_TOKEN || '';
  const username = process.env.ARTIFACTORY_USERNAME || 'admin';
  const password = process.env.ARTIFACTORY_PASSWORD || 'password';
  const registry = registryUrl.replace(/\/+$/, '/');
  const fragment = `//${registry.replace(/^https?:\/\//, '')}`;
  const npmrc = path.join(tmp, 'artifactory.npmrc');
  const lines = [
    `registry=${registry}`,
    `${fragment}:always-auth=true`
  ];
  if (token) {
    lines.push(`${fragment}:_authToken=${token}`);
  } else {
    lines.push(`${fragment}:username=${username}`);
    lines.push(`${fragment}:_password=${Buffer.from(password).toString('base64')}`);
    lines.push(`${fragment}:email=fetch-kit-test@example.invalid`);
  }
  fs.writeFileSync(npmrc, `${lines.join('\n')}\n`);
  return npmrc;
}

function makePackageTar(packageName, version) {
  const sourceDir = path.join(tmp, 'source', `${packageName}-${version}`);
  fs.mkdirSync(sourceDir, { recursive: true });
  fs.writeFileSync(path.join(sourceDir, 'package.json'), JSON.stringify({
    name: packageName,
    version,
    description: 'fetch-kit local Artifactory integration fixture',
    main: 'index.js',
    license: 'UNLICENSED'
  }, null, 2));
  fs.writeFileSync(path.join(sourceDir, 'index.js'), `module.exports = ${JSON.stringify({ packageName, version })};\n`);

  const packDir = path.join(tmp, 'packed');
  fs.mkdirSync(packDir, { recursive: true });
  const stdout = run('npm', [
    'pack',
    '--ignore-scripts',
    '--json',
    `--pack-destination=${packDir}`,
    `--cache=${path.join(tmp, 'npm-cache')}`
  ], { cwd: sourceDir });
  const parsed = JSON.parse(stdout);
  return path.join(packDir, parsed[0].filename);
}

function copyPackageIntoBundle(bundleDir, tarball, packageName, version) {
  const tarballDir = path.join(bundleDir, 'tarballs');
  fs.mkdirSync(tarballDir, { recursive: true });
  const targetName = `${packageName}-${version}.tgz`;
  const target = path.join(tarballDir, targetName);
  fs.copyFileSync(tarball, target);
  return {
    name: packageName,
    version,
    package: `${packageName}@${version}`,
    tarball: `tarballs/${targetName}`
  };
}

function makeBundle(bundleName, packageDefs) {
  const bundleDir = path.join(tmp, bundleName);
  fs.mkdirSync(bundleDir, { recursive: true });
  const manifest = packageDefs.map((pkg) => {
    const tarball = makePackageTar(pkg.name, pkg.version);
    return copyPackageIntoBundle(bundleDir, tarball, pkg.name, pkg.version);
  });
  fs.writeFileSync(path.join(bundleDir, 'packages.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  fs.writeFileSync(path.join(bundleDir, 'packages.jsonl'), `${manifest.map((item) => JSON.stringify(item)).join('\n')}\n`);

  const tarFile = path.join(tmp, `${bundleName}.tar`);
  run('tar', ['-cf', tarFile, '-C', tmp, bundleName]);
  return { bundleDir, tarFile, manifest };
}

function npmJson(args, registryUrl, npmrc) {
  const stdout = run('npm', [
    ...args,
    '--json',
    `--registry=${registryUrl}`,
    `--userconfig=${npmrc}`,
    `--cache=${path.join(tmp, 'npm-cache')}`
  ]);
  return stdout.trim() ? JSON.parse(stdout) : null;
}

function npmPublish(tarball, tag, registryUrl, npmrc) {
  run('npm', [
    'publish',
    tarball,
    `--registry=${registryUrl}`,
    `--userconfig=${npmrc}`,
    `--cache=${path.join(tmp, 'npm-cache')}`,
    '--ignore-scripts',
    '--tag',
    tag
  ]);
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function npmJsonEventually(args, registryUrl, npmrc) {
  let lastError;
  for (let attempt = 0; attempt < 10; attempt += 1) {
    try {
      return npmJson(args, registryUrl, npmrc);
    } catch (error) {
      lastError = error;
      await delay(1000);
    }
  }
  throw lastError;
}

async function main() {
  const registry = await ensureRegistry();
  const npmrc = writeNpmrc(registry.registryUrl);
  const suffix = `${Date.now()}-${Math.random().toString(16).slice(2, 8)}`;
  const aheadName = `fetch-kit-ahead-${suffix}`;
  const newName = `fetch-kit-new-${suffix}`;

  try {
    const aheadNewest = makePackageTar(aheadName, '3.0.0');
    npmPublish(aheadNewest, 'latest', registry.registryUrl, npmrc);
    await npmJsonEventually(['view', aheadName, 'versions'], registry.registryUrl, npmrc);

    const bundle = makeBundle('bundle-under-test', [
      { name: aheadName, version: '1.0.0' },
      { name: aheadName, version: '2.0.0' },
      { name: aheadName, version: '2.1.0-beta.1' },
      { name: newName, version: '1.0.0' },
      { name: newName, version: '2.0.0-beta.1' },
      { name: newName, version: '2.0.0' }
    ]);

    const uploadWorkDir = path.join(tmp, 'upload-work');
    const uploadOutput = run(process.execPath, [
      uploader,
      '--bundle-tar', bundle.tarFile,
      '--registry-url', registry.registryUrl,
      '--userconfig', npmrc,
      '--work-dir', uploadWorkDir,
      '--skip-existing'
    ]);
    const summary = JSON.parse(uploadOutput);
    const tagFor = (packageName, version) => summary.results
      .find((item) => item.package === packageName && item.version === version)
      .distTag;

    assert.strictEqual(tagFor(aheadName, '1.0.0'), 'airgap-1.0.0');
    assert.strictEqual(tagFor(aheadName, '2.0.0'), 'airgap-2.0.0');
    assert.strictEqual(tagFor(aheadName, '2.1.0-beta.1'), 'airgap-2.1.0-beta.1');
    assert.strictEqual(tagFor(newName, '1.0.0'), 'airgap-1.0.0');
    assert.strictEqual(tagFor(newName, '2.0.0-beta.1'), 'airgap-2.0.0-beta.1');
    assert.strictEqual(tagFor(newName, '2.0.0'), 'latest');

    const aheadTags = await npmJsonEventually(['view', aheadName, 'dist-tags'], registry.registryUrl, npmrc);
    const newTags = await npmJsonEventually(['view', newName, 'dist-tags'], registry.registryUrl, npmrc);
    const aheadVersions = await npmJsonEventually(['view', aheadName, 'versions'], registry.registryUrl, npmrc);
    const newVersions = await npmJsonEventually(['view', newName, 'versions'], registry.registryUrl, npmrc);

    assert.strictEqual(aheadTags.latest, '3.0.0');
    assert.strictEqual(aheadTags['airgap-2.0.0'], '2.0.0');
    assert.strictEqual(newTags.latest, '2.0.0');
    assert.ok(aheadVersions.includes('1.0.0'));
    assert.ok(aheadVersions.includes('2.0.0'));
    assert.ok(aheadVersions.includes('2.1.0-beta.1'));
    assert.ok(aheadVersions.includes('3.0.0'));
    assert.ok(newVersions.includes('1.0.0'));
    assert.ok(newVersions.includes('2.0.0-beta.1'));
    assert.ok(newVersions.includes('2.0.0'));

    console.log('local Artifactory npm upload integration: ok');
  } finally {
    await registry.cleanup();
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

main().catch((error) => {
  fs.rmSync(tmp, { recursive: true, force: true });
  console.error(`ERROR: ${errorText(error) || error.message}`);
  process.exit(1);
});
