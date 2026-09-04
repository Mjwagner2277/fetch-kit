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
function parsePackageRef(ref) {
  const trimmed = String(ref || '');
  if (trimmed.startsWith('@')) {
    const slash = trimmed.indexOf('/');
    const versionAt = trimmed.indexOf('@', slash + 1);
    if (versionAt === -1) return { name: trimmed, version: '2.0.0' };
    return { name: trimmed.slice(0, versionAt), version: trimmed.slice(versionAt + 1) };
  }
  const versionAt = trimmed.lastIndexOf('@');
  if (versionAt > 0) return { name: trimmed.slice(0, versionAt), version: trimmed.slice(versionAt + 1) };
  return { name: trimmed, version: '2.0.0' };
}
function lockPathForPackage(name) {
  return 'node_modules/' + name;
}
function resolveRequestedVersion(requested) {
  const value = String(requested || '').trim();
  if (!value || value === 'latest' || value === '*' || /[<>=^~xX]/.test(value) || /\\s/.test(value)) {
    return '2.0.0';
  }
  return value;
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
  if (field === 'versions') {
    process.stdout.write(JSON.stringify(['1.0.0', '2.0.0']));
    process.exit(0);
  }
  if (field === 'dist-tags') {
    process.stdout.write(JSON.stringify({ latest: '2.0.0' }));
    process.exit(0);
  }
  if (field === 'engines') {
    process.stdout.write(JSON.stringify({ node: '>=18 <21' }));
    process.exit(0);
  }
}
if (args[0] === 'install') {
  const manifest = JSON.parse(fs.readFileSync(path.join(process.cwd(), 'package.json'), 'utf8'));
  const deps = manifest.dependencies || {};
  const lockPackages = {
    '': {
      name: 'npm-artifactory-bundle-resolution',
      version: '0.0.0',
      dependencies: deps
    }
  };
  for (const [name, requested] of Object.entries(deps)) {
    const version = resolveRequestedVersion(requested);
    lockPackages[lockPathForPackage(name)] = {
      name,
      version,
      resolved: 'https://registry.example.invalid/' + name + '/-/' + name.replace(/^@/, '').replace(/[\\\\/]/g, '-') + '-' + version + '.tgz',
      integrity: 'sha512-test',
      engines: { node: '>=18 <21' }
    };
  }
  fs.writeFileSync(path.join(process.cwd(), 'package-lock.json'), JSON.stringify({
    name: 'npm-artifactory-bundle-resolution',
    version: '0.0.0',
    lockfileVersion: 3,
    requires: true,
    packages: lockPackages
  }, null, 2));
  process.exit(0);
}
if (args[0] === 'pack') {
  const dest = argValue('--pack-destination=');
  if (!dest) process.exit(1);
  const pkg = parsePackageRef(args[1]);
  writePackageTar(dest, pkg.name, pkg.version);
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

  const textPackagesFile = path.join(tmp, 'packages-node-18.txt');
  fs.writeFileSync(textPackagesFile, [
    '# latest-compatible request',
    'fake-lib',
    'pinned-lib 1.0.0',
    '@scope/scoped-lib@1.0.0',
    ''
  ].join('\n'));
  const listStateDir = path.join(tmp, 'state-list');
  const listStdout = run(process.execPath, [
    downloader,
    '--node-version', '18.20.4',
    '--npm-bin', fakeNpm,
    '--output-dir', path.join(tmp, 'out-list'),
    '--state-dir', listStateDir,
    '--packages-file', textPackagesFile
  ]);
  const listSummary = JSON.parse(listStdout);
  const listRoots = new Map(listSummary.rootPackages.map((item) => [item.name, item]));
  assert.strictEqual(listSummary.nodeVersion, '18.20.4');
  assert.strictEqual(listSummary.rootPackageCount, 3);
  assert.strictEqual(listSummary.packageCount, 3);
  assert.strictEqual(listRoots.get('fake-lib').requested, 'latest');
  assert.strictEqual(listRoots.get('fake-lib').resolvedVersion, '2.0.0');
  assert.strictEqual(listRoots.get('pinned-lib').requested, '1.0.0');
  assert.strictEqual(listRoots.get('@scope/scoped-lib').requested, '1.0.0');
  const listState = JSON.parse(fs.readFileSync(path.join(listStateDir, 'node-v18.20.4.json'), 'utf8'));
  assert.strictEqual(listState.requests['fake-lib'].spec, 'fake-lib@latest');
  assert.strictEqual(listState.requests['pinned-lib'].spec, 'pinned-lib@1.0.0');
  assert.strictEqual(listState.requests['@scope/scoped-lib'].spec, '@scope/scoped-lib@1.0.0');

  const jsonPackagesFile = path.join(tmp, 'packages-node-20.json');
  fs.writeFileSync(jsonPackagesFile, JSON.stringify({
    packages: [
      'json-latest',
      { name: 'json-pinned', version: '1.0.0' },
      'cli-pinned'
    ]
  }, null, 2));
  const jsonStdout = run(process.execPath, [
    downloader,
    '--node-version', '20.12.0',
    '--npm-bin', fakeNpm,
    '--output-dir', path.join(tmp, 'out-json'),
    '--state-dir', path.join(tmp, 'state-json'),
    '--package-file', jsonPackagesFile,
    '--package', 'cli-pinned@1.0.0'
  ]);
  const jsonSummary = JSON.parse(jsonStdout);
  const jsonRoots = new Map(jsonSummary.rootPackages.map((item) => [item.name, item]));
  assert.strictEqual(jsonSummary.rootPackageCount, 3);
  assert.strictEqual(jsonRoots.get('json-latest').requested, 'latest');
  assert.strictEqual(jsonRoots.get('json-latest').resolvedVersion, '2.0.0');
  assert.strictEqual(jsonRoots.get('json-pinned').requested, '1.0.0');
  assert.strictEqual(jsonRoots.get('cli-pinned').requested, '1.0.0');

  console.log('download npm artifactory bundle: ok');
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
