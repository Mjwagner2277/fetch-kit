#!/usr/bin/env node
'use strict';

const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const { spawnSync } = require('child_process');

const downloader = path.resolve(__dirname, '..', 'soon-to-be-deprecated', 'download-npm-artifactory-bundle.js');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'npm-locked-fetch-test-'));
const digest = (buffer) => `sha512-${crypto.createHash('sha512').update(buffer).digest('base64')}`;

function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8', env: { ...process.env, COPYFILE_DISABLE: '1' } });
  assert.strictEqual(result.status, 0, `${result.stdout}\n${result.stderr}`);
  return result.stdout;
}

function archive(files) {
  return zlib.gzipSync(Buffer.concat([...Object.entries(files).map(([name, data]) => {
    const content = Buffer.from(data);
    const header = Buffer.alloc(512);
    header.write(name);
    header.write('0000644\0', 100);
    header.write('0000000\0', 108);
    header.write('0000000\0', 116);
    header.write(`${content.length.toString(8).padStart(11, '0')}\0`, 124);
    header.write('00000000000\0', 136);
    header.fill(32, 148, 156);
    header[156] = 48;
    header.write('ustar\0', 257);
    header.write('00', 263);
    header.write(`${header.reduce((sum, byte) => sum + byte, 0).toString(8).padStart(6, '0')}\0 `, 148);
    return Buffer.concat([header, content, Buffer.alloc((512 - content.length % 512) % 512)]);
  }), Buffer.alloc(1024)]));
}

try {
  const sources = {};
  const fixtures = new Map();
  function fixture(name, version, extraFiles = {}, extraManifest = {}) {
    const packageJson = {
      name, version, main: 'index.js', scripts: { publish: 'exit 1', prepublishOnly: 'curl example.invalid', install: 'node install.js' },
      private: true, publishConfig: { registry: 'https://outside.invalid/' },
      dependencies: {}, devDependencies: { builder: '1.0.0' }, ...extraManifest
    };
    const bytes = archive({ 'package/package.json': JSON.stringify(packageJson), 'package/index.js': `module.exports = ${JSON.stringify(name)};\n`, ...extraFiles });
    const index = fixtures.size;
    const filename = path.join(tmp, `source-${index}.tgz`);
    const resolved = `https://registry.example.invalid/tarballs/exact-${index}.tgz`;
    fs.writeFileSync(filename, bytes);
    sources[resolved] = filename;
    sources[`${name}@${version}`] = filename;
    const metadata = { name, version, resolved, integrity: digest(bytes) };
    fixtures.set(`${name}@${version}`, metadata);
    return metadata;
  }
  const bundled = { name: 'bundled', version: '3.0.0', scripts: { postinstall: 'curl example.invalid' }, private: true };
  const parent = fixture('parent', '1.0.0', {
    'package/node_modules/bundled/package.json': JSON.stringify(bundled),
    'package/node_modules/bundled/index.js': 'module.exports = 3;',
    'package/binding.gyp': '{}'
  }, { bundleDependencies: ['bundled'], dependencies: { bundled: '3.0.0' } });
  const scoped = fixture('@a/b', '1.0.0');
  const collision = fixture('a-b', '1.0.0');
  const nested = fixture('@a/b', '2.0.0');
  const optional = fixture('windows-only', '1.0.0', {}, { os: ['win32'], cpu: ['x64'] });
  const sourceFile = path.join(tmp, 'sources.json');
  fs.writeFileSync(sourceFile, JSON.stringify(sources));
  const callsFile = path.join(tmp, 'calls.jsonl');
  const fakeNpm = path.join(tmp, 'fake-npm.js');
  fs.writeFileSync(fakeNpm, `#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const args = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(callsFile)}, JSON.stringify(args) + '\\n');
if (args[0] !== 'pack' || !args.includes('--ignore-scripts')) throw Error('Expected only exact npm pack');
const source = JSON.parse(fs.readFileSync(${JSON.stringify(sourceFile)}, 'utf8'))[args[1]];
if (!source) throw Error('Unknown exact source: ' + args[1]);
const destination = args.find(arg => arg.startsWith('--pack-destination=')).split('=').slice(1).join('=');
const filename = path.basename(source);
fs.copyFileSync(source, path.join(destination, filename));
process.stdout.write(JSON.stringify([{filename}]));
`);
  fs.chmodSync(fakeNpm, 0o755);
  const lockFile = path.join(tmp, 'package-lock.json');
  let serial = 0;
  function invoke(lock, flags = [], expectedError = '') {
    const raw = `${JSON.stringify(lock, null, 3)}\n`;
    fs.writeFileSync(lockFile, raw);
    const id = serial++;
    const args = [downloader, '--node-version', '20.11.1', '--package-lock', lockFile, '--npm-bin', fakeNpm,
      '--state-dir', path.join(tmp, `state-${id}`), '--output-dir', path.join(tmp, `out-${id}`), ...flags];
    const result = spawnSync(process.execPath, args, { encoding: 'utf8' });
    if (expectedError) {
      assert.notStrictEqual(result.status, 0);
      assert.match(result.stderr, new RegExp(expectedError));
      return;
    }
    assert.strictEqual(result.status, 0, result.stderr);
    const summary = JSON.parse(result.stdout);
    const extractDir = path.join(tmp, `extract-${id}`);
    fs.mkdirSync(extractDir);
    run('tar', ['-xf', summary.transferTarFile, '-C', extractDir]);
    const dir = path.join(extractDir, fs.readdirSync(extractDir)[0]);
    assert.strictEqual(fs.readFileSync(path.join(dir, 'package-lock.original.json'), 'utf8'), raw);
    return { summary, dir, lock: JSON.parse(fs.readFileSync(path.join(dir, 'package-lock.json'))), packages: JSON.parse(fs.readFileSync(path.join(dir, 'packages.json'))) };
  }
  const lock = {
    name: 'fixture', version: '1.0.0', lockfileVersion: 3,
    packages: {
      '': { name: 'fixture', version: '1.0.0', dependencies: { alias: 'npm:@a/b@1.0.0', parent: '1.0.0', 'a-b': '1.0.0' } },
      'node_modules/alias': { ...scoped, hasInstallScript: true },
      'node_modules/a-b': collision,
      'node_modules/parent': parent,
      'node_modules/parent/node_modules/bundled': { version: '3.0.0', inBundle: true, hasInstallScript: true },
      'node_modules/parent/node_modules/@a/b': nested,
      'node_modules/windows-only': { ...optional, optional: true, os: ['win32'], cpu: ['x64'] }
    }
  };
  const internal = 'https://artifactory.internal/artifactory/api/npm/npm-local/';
  const output = invoke(lock, ['--destination-registry', internal]);
  assert.strictEqual(output.summary.packageCount, 5);
  assert.strictEqual(output.packages.find((pkg) => pkg.name === 'windows-only').optional, true);
  assert.ok(output.summary.offlineWarnings.some((warning) => warning.includes('node-gyp')));
  assert.strictEqual(new Set(output.packages.map((pkg) => pkg.tarball)).size, 5, 'Scoped and unscoped filenames must not collide');
  for (const pkg of output.packages) {
    const bytes = fs.readFileSync(path.join(output.dir, pkg.tarball));
    assert.strictEqual(pkg.originalIntegrityVerified, true);
    assert.strictEqual(pkg.integrity, digest(bytes));
    assert.notStrictEqual(pkg.integrity, pkg.registryIntegrity);
    const meta = output.lock.packages[pkg.lockPath];
    assert.strictEqual(meta.integrity, digest(bytes));
    assert.strictEqual(meta.resolved, `${internal}${pkg.name}/-/${pkg.name.split('/').pop()}-${pkg.version}.tgz`);
    const packageJson = JSON.parse(run('tar', ['-xOzf', path.join(output.dir, pkg.tarball), 'package/package.json']));
    assert.strictEqual(packageJson.scripts, undefined);
    assert.strictEqual(packageJson.private, undefined);
    assert.strictEqual(packageJson.publishConfig, undefined);
    assert.strictEqual(packageJson.devDependencies, undefined);
    assert.strictEqual(packageJson.main, 'index.js');
  }
  const packedParent = output.packages.find((pkg) => pkg.name === 'parent');
  const bundledJson = JSON.parse(run('tar', ['-xOzf', path.join(output.dir, packedParent.tarball), 'package/node_modules/bundled/package.json']));
  assert.strictEqual(bundledJson.scripts, undefined);
  assert.strictEqual(output.lock.packages['node_modules/parent/node_modules/bundled'].hasInstallScript, undefined);
  const calls = fs.readFileSync(callsFile, 'utf8').trim().split('\n').map(JSON.parse);
  assert.strictEqual(calls.length, 5);
  assert.ok(calls.every((args) => args[0] === 'pack' && args[1].startsWith('https://registry.example.invalid/tarballs/exact-')));
  const repeat = invoke(lock);
  for (const pkg of repeat.packages) {
    assert.strictEqual(pkg.sha512, output.packages.find((item) => item.package === pkg.package).sha512, 'Identical sources produce deterministic sanitized bytes');
    assert.strictEqual(repeat.lock.packages[pkg.lockPath].resolved, undefined);
  }
  const v1 = { lockfileVersion: 1, dependencies: { alias: { version: 'npm:@a/b@1.0.0', resolved: scoped.resolved, integrity: scoped.integrity, dependencies: { '@a/b': nested } } } };
  const v1Output = invoke(v1);
  assert.strictEqual(v1Output.packages.length, 2);
  assert.strictEqual(v1Output.lock.dependencies.alias.version, 'npm:@a/b@1.0.0');
  assert.strictEqual(v1Output.lock.dependencies.alias.integrity, v1Output.packages.find((pkg) => pkg.version === '1.0.0').integrity);
  const v2 = { lockfileVersion: 2, packages: { '': {}, 'node_modules/alias': scoped }, dependencies: { alias: { version: 'npm:@a/b@1.0.0', resolved: scoped.resolved, integrity: scoped.integrity } } };
  const v2Output = invoke(v2);
  assert.strictEqual(v2Output.packages.length, 1);
  assert.strictEqual(v2Output.lock.dependencies.alias.integrity, v2Output.lock.packages['node_modules/alias'].integrity);
  const badIntegrity = structuredClone(lock);
  badIntegrity.packages['node_modules/a-b'].integrity = digest(Buffer.from('wrong bytes'));
  invoke(badIntegrity, [], 'Original tarball integrity mismatch');
  for (const unsupported of [
    { link: true, resolved: '../workspace' },
    { version: '1.0.0', resolved: 'git+https://example.invalid/repo.git' },
    { version: '1.0.0', resolved: 'file:../package.tgz' }
  ]) invoke({ lockfileVersion: 3, packages: { '': {}, 'node_modules/unsupported': unsupported } }, [], 'Unsupported');
  const conflicting = structuredClone(lock);
  conflicting.packages['node_modules/another-alias'] = { ...scoped, integrity: digest(Buffer.from('different')) };
  invoke(conflicting, [], 'Conflicting sources or integrity');
  const noBundle = structuredClone(lock);
  noBundle.packages['node_modules/parent/node_modules/bundled'].version = '99.0.0';
  invoke(noBundle, [], 'Bundled dependency identity mismatch');
  invoke(lock, ['--omit-optional-dependencies'], 'cannot be combined');
  const fallback = invoke({ lockfileVersion: 3, packages: { '': {}, 'node_modules/a-b': { version: collision.version, integrity: collision.integrity } } });
  assert.strictEqual(fallback.packages.length, 1);
  assert.strictEqual(fallback.packages[0].originalIntegrityVerified, true);
  console.log('download npm package-lock bundle: ok');
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
