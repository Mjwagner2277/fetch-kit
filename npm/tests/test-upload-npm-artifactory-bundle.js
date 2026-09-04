#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const repoRoot = path.resolve(__dirname, '..', '..');
const uploader = path.join(repoRoot, 'npm', 'upload-npm-artifactory-bundle.js');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'npm-upload-test-'));

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || repoRoot,
    env: options.env || process.env,
    encoding: 'utf8',
    maxBuffer: 1024 * 1024 * 10
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== (options.status ?? 0)) {
    throw new Error(`${command} ${args.join(' ')} exited ${result.status}\nSTDOUT:\n${result.stdout}\nSTDERR:\n${result.stderr}`);
  }
  return result;
}

function makeBundle(name, packages) {
  const bundleDir = path.join(tmp, name);
  const tarballDir = path.join(bundleDir, 'tarballs');
  fs.mkdirSync(tarballDir, { recursive: true });

  const manifest = packages.map((pkg) => {
    const tarball = `tarballs/${pkg.name.replace(/^@/, '').replace(/[\\/]/g, '-')}-${pkg.version}.tgz`;
    fs.writeFileSync(path.join(bundleDir, tarball), `fake tarball for ${pkg.name}@${pkg.version}\n`);
    return {
      name: pkg.name,
      version: pkg.version,
      package: `${pkg.name}@${pkg.version}`,
      tarball
    };
  });

  fs.writeFileSync(path.join(bundleDir, 'packages.jsonl'), `${manifest.map((pkg) => JSON.stringify(pkg)).join('\n')}\n`);
  const tarFile = path.join(tmp, `${name}.tar`);
  run('tar', ['-cf', tarFile, '-C', tmp, name]);
  return { bundleDir, tarFile };
}

function fakeNpmScript(file, logFile) {
  fs.writeFileSync(file, `#!/usr/bin/env node
'use strict';
const fs = require('fs');
const logFile = ${JSON.stringify(logFile)};
const args = process.argv.slice(2);
fs.appendFileSync(logFile, JSON.stringify(args) + '\\n');

if (args[0] === 'view') {
  const name = args[1];
  if (name === 'ahead-pkg') {
    process.stdout.write(JSON.stringify(['3.0.0']));
    process.exit(0);
  }
  if (name === 'new-pkg') {
    process.stderr.write('npm ERR! code E404\\n');
    process.exit(1);
  }
  if (name === 'same-pkg') {
    process.stdout.write(JSON.stringify(['1.0.0']));
    process.exit(0);
  }
  process.stdout.write(JSON.stringify([]));
  process.exit(0);
}

if (args[0] === 'publish') {
  const tarball = args[1] || '';
  if (tarball.includes('same-pkg-1.0.0.tgz')) {
    process.stderr.write('npm ERR! code EPUBLISHCONFLICT\\nnpm ERR! already exists\\n');
    process.exit(1);
  }
  process.stdout.write('+ published\\n');
  process.exit(0);
}

process.stderr.write('unexpected fake npm args: ' + args.join(' ') + '\\n');
process.exit(1);
`);
  fs.chmodSync(file, 0o755);
}

function readLog(logFile) {
  return fs.readFileSync(logFile, 'utf8')
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

try {
  const fakeNpm = path.join(tmp, 'fake-npm.js');
  const logFile = path.join(tmp, 'npm.log');
  fakeNpmScript(fakeNpm, logFile);

  const mainBundle = makeBundle('bundle-main', [
    { name: 'ahead-pkg', version: '1.0.0' },
    { name: 'ahead-pkg', version: '2.0.0' },
    { name: 'new-pkg', version: '1.0.0' },
    { name: 'new-pkg', version: '2.0.0-beta.1' },
    { name: 'new-pkg', version: '2.0.0' }
  ]);

  const dryRun = run(process.execPath, [
    uploader,
    '--bundle-tar', mainBundle.tarFile,
    '--registry-url', 'https://art.example.com/artifactory/api/npm/npm-local/',
    '--token', 'test-token',
    '--npm-bin', fakeNpm,
    '--work-dir', path.join(tmp, 'work-dry-run'),
    '--dry-run'
  ]);
  const drySummary = JSON.parse(dryRun.stdout);
  const tagFor = (pkg, version) => drySummary.results
    .find((item) => item.package === pkg && item.version === version)
    .distTag;

  assert.strictEqual(tagFor('ahead-pkg', '1.0.0'), 'airgap-1.0.0');
  assert.strictEqual(tagFor('ahead-pkg', '2.0.0'), 'airgap-2.0.0');
  assert.strictEqual(tagFor('new-pkg', '1.0.0'), 'airgap-1.0.0');
  assert.strictEqual(tagFor('new-pkg', '2.0.0-beta.1'), 'airgap-2.0.0-beta.1');
  assert.strictEqual(tagFor('new-pkg', '2.0.0'), 'latest');
  assert.strictEqual(drySummary.results.find((item) => item.package === 'ahead-pkg' && item.version === '2.0.0').remoteHasNewerStable, true);

  const sameBundle = makeBundle('bundle-same', [
    { name: 'same-pkg', version: '1.0.0' }
  ]);
  const publish = run(process.execPath, [
    uploader,
    '--bundle-tar', sameBundle.tarFile,
    '--registry-url', 'https://art.example.com/artifactory/api/npm/npm-local/',
    '--token', 'test-token',
    '--npm-bin', fakeNpm,
    '--work-dir', path.join(tmp, 'work-publish'),
    '--skip-existing'
  ]);
  const publishSummary = JSON.parse(publish.stdout);
  assert.strictEqual(publishSummary.skippedExisting, 1);
  assert.strictEqual(publishSummary.results[0].status, 'skipped-existing');
  assert.strictEqual(publishSummary.results[0].distTag, 'latest');

  fs.writeFileSync(logFile, '');
  const never = run(process.execPath, [
    uploader,
    '--bundle-tar', mainBundle.tarFile,
    '--registry-url', 'https://art.example.com/artifactory/api/npm/npm-local/',
    '--token', 'test-token',
    '--npm-bin', fakeNpm,
    '--work-dir', path.join(tmp, 'work-never'),
    '--latest-policy', 'never',
    '--dry-run'
  ]);
  const neverSummary = JSON.parse(never.stdout);
  assert.ok(neverSummary.results.every((item) => item.distTag.startsWith('airgap-')));
  assert.ok(readLog(logFile).every((args) => args[0] !== 'view'));

  console.log('upload npm artifactory bundle: ok');
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
