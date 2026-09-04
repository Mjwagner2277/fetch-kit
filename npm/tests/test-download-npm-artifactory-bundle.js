#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const repoRoot = path.resolve(__dirname, '..', '..');
const downloader = path.join(repoRoot, 'npm', 'download-npm-artifactory-bundle.js');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'npm-download-test-'));

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || repoRoot,
    encoding: 'utf8',
    maxBuffer: 1024 * 1024 * 10
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed\n${result.stdout}\n${result.stderr}`);
  }
  return result.stdout;
}

try {
  const fakeNpm = path.join(tmp, 'fake-npm.js');
  fs.writeFileSync(fakeNpm, `#!/usr/bin/env node
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const args = process.argv.slice(2);
function argValue(prefix) {
  const value = args.find((arg) => arg.startsWith(prefix));
  return value ? value.slice(prefix.length) : '';
}
function writePackageTar(dest, name, version) {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fake-npm-pack-'));
  const packageDir = path.join(work, 'package');
  fs.mkdirSync(packageDir, { recursive: true });
  fs.writeFileSync(path.join(packageDir, 'package.json'), JSON.stringify({
    name,
    version,
    main: 'index.js',
    types: 'index.d.ts',
    scripts: { prepare: 'npm run build', postinstall: 'node postinstall.js' },
    dependencies: { 'runtime-dep': '^1.0.0' },
    devDependencies: { typescript: '^5.0.0' }
  }, null, 2));
  fs.writeFileSync(path.join(packageDir, 'index.js'), 'module.exports = { value: 1 };\\n');
  fs.writeFileSync(path.join(packageDir, 'index.d.ts'), 'export declare const value: number;\\n');
  const filename = name.replace(/^@/, '').replace(/[\\\\/]/g, '-') + '-' + version + '.tgz';
  const result = spawnSync('tar', ['-czf', path.join(dest, filename), '-C', work, 'package']);
  if (result.status !== 0) process.exit(result.status || 1);
  process.stdout.write(JSON.stringify([{ filename, name, version }]));
}
if (args[0] === 'view') {
  const spec = args[1];
  const field = args[2];
  if (spec === 'fake-lib' && field === 'versions') {
    process.stdout.write(JSON.stringify(['1.0.0', '2.0.0']));
    process.exit(0);
  }
  if (spec === 'fake-lib' && field === 'dist-tags') {
    process.stdout.write(JSON.stringify({ latest: '2.0.0' }));
    process.exit(0);
  }
  if (spec === 'fake-lib@2.0.0' && field === 'engines') {
    process.stdout.write(JSON.stringify({ node: '>=18 <21' }));
    process.exit(0);
  }
}
if (args[0] === 'install') {
  fs.writeFileSync(path.join(process.cwd(), 'package-lock.json'), JSON.stringify({
    name: 'npm-artifactory-bundle-resolution',
    version: '0.0.0',
    lockfileVersion: 3,
    requires: true,
    packages: {
      '': {
        name: 'npm-artifactory-bundle-resolution',
        version: '0.0.0',
        dependencies: { 'fake-lib': '2.0.0' }
      },
      'node_modules/fake-lib': {
        name: 'fake-lib',
        version: '2.0.0',
        resolved: 'https://registry.example.invalid/fake-lib/-/fake-lib-2.0.0.tgz',
        integrity: 'sha512-test',
        engines: { node: '>=18 <21' }
      }
    }
  }, null, 2));
  process.exit(0);
}
if (args[0] === 'pack') {
  const dest = argValue('--pack-destination=');
  if (!dest) process.exit(1);
  writePackageTar(dest, 'fake-lib', '2.0.0');
  process.exit(0);
}
process.stderr.write('unexpected fake npm args: ' + args.join(' ') + '\\n');
process.exit(1);
`);
  fs.chmodSync(fakeNpm, 0o755);

  const outputDir = path.join(tmp, 'out');
  const stateDir = path.join(tmp, 'state');
  const stdout = run(process.execPath, [
    downloader,
    '--node-version', '20.11.1',
    '--npm-bin', fakeNpm,
    '--output-dir', outputDir,
    '--state-dir', stateDir,
    'fake-lib'
  ]);
  const summary = JSON.parse(stdout);

  assert.strictEqual(summary.nodeVersion, '20.11.1');
  assert.strictEqual(summary.packageCount, 1);
  assert.ok(fs.existsSync(summary.transferTarFile));
  assert.ok(fs.existsSync(path.join(stateDir, 'node-v20.11.1.json')));

  const extractDir = path.join(tmp, 'extract');
  fs.mkdirSync(extractDir);
  run('tar', ['-xf', summary.transferTarFile, '-C', extractDir]);
  const [bundleName] = fs.readdirSync(extractDir);
  const bundleDir = path.join(extractDir, bundleName);

  assert.ok(fs.existsSync(path.join(bundleDir, 'packages.jsonl')));
  assert.ok(fs.existsSync(path.join(bundleDir, 'state', 'node-v20.11.1.json')));
  const packages = JSON.parse(fs.readFileSync(path.join(bundleDir, 'packages.json'), 'utf8'));
  assert.strictEqual(packages[0].package, 'fake-lib@2.0.0');
  assert.strictEqual(packages[0].normalized, true);

  const packageExtractDir = path.join(tmp, 'package-extract');
  fs.mkdirSync(packageExtractDir);
  run('tar', ['-xzf', path.join(bundleDir, packages[0].tarball), '-C', packageExtractDir]);
  const packageJson = JSON.parse(fs.readFileSync(path.join(packageExtractDir, 'package', 'package.json'), 'utf8'));
  assert.strictEqual(packageJson.name, 'fake-lib');
  assert.strictEqual(packageJson.main, 'index.js');
  assert.strictEqual(packageJson.types, 'index.d.ts');
  assert.ok(packageJson.dependencies['runtime-dep']);
  assert.strictEqual(packageJson.scripts, undefined);
  assert.strictEqual(packageJson.devDependencies, undefined);

  console.log('download npm artifactory bundle: ok');
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
