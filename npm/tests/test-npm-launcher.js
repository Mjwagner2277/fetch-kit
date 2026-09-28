#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');

const downloader = path.resolve(__dirname, '..', 'soon-to-be-deprecated', 'download-npm-artifactory-bundle.js');
const source = fs.readFileSync(downloader, 'utf8');

// Exercise Windows discovery without requiring a Windows host or executing a shell.
function windowsHarness({ files = [], env = {}, cwd = 'C:\\work', execPath = 'C:\\Node\\node.exe' } = {}) {
  const normalize = (file) => path.win32.resolve(cwd, file).toLowerCase();
  const present = new Set(files.map(normalize));
  const calls = [];
  const missing = (file) => Object.assign(new Error(`ENOENT: ${file}`), { code: 'ENOENT' });
  const fakeFs = {
    ...fs,
    existsSync: (file) => present.has(normalize(file)),
    statSync(file) {
      if (!present.has(normalize(file))) throw missing(file);
      return { isFile: () => true, isDirectory: () => false };
    },
    realpathSync(file) {
      if (!present.has(normalize(file))) throw missing(file);
      return path.win32.resolve(cwd, file);
    },
    accessSync(file) {
      if (!present.has(normalize(file))) throw missing(file);
    }
  };
  const fakePath = {
    ...path.win32,
    resolve: (...parts) => path.win32.resolve(cwd, ...parts)
  };
  const fakeProcess = {
    platform: 'win32', execPath, env, cwd: () => cwd,
    argv: [execPath, downloader],
    stderr: { write() {} },
    exit() { throw new Error('Import unexpectedly executed main()'); }
  };
  const module = { exports: {} };
  const fakeRequire = (name) => {
    if (name === 'fs' || name === 'node:fs') return fakeFs;
    if (name === 'path' || name === 'node:path') return fakePath;
    if (name === 'child_process' || name === 'node:child_process') {
      return {
        spawnSync(command, args, options) {
          calls.push({ command, args: Array.from(args), options });
          return { status: 0, stdout: 'mock npm output', stderr: '' };
        }
      };
    }
    return require(name);
  };
  fakeRequire.main = null;
  vm.runInNewContext(source, {
    require: fakeRequire, module, exports: module.exports, process: fakeProcess,
    console, Buffer, URL, __filename: downloader, __dirname: path.dirname(downloader)
  }, { filename: downloader });
  assert.strictEqual(calls.length, 0, 'Requiring the downloader must not start a command');
  return { ...module.exports, calls };
}

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

const nodeDir = 'C:\\Program Files\\nodejs';
const npmCmd = path.win32.join(nodeDir, 'npm.cmd');
const npmCli = path.win32.join(nodeDir, 'node_modules', 'npm', 'bin', 'npm-cli.js');
const nodeExe = path.win32.join(nodeDir, 'node.exe');

for (const npmBin of ['npm', 'npm.cmd']) {
  const harness = windowsHarness({
    files: [npmCmd, npmCli], env: { Path: nodeDir, CUSTOM_NPM_TEST: 'inherited' }, execPath: nodeExe
  });
  assert.deepStrictEqual(plain(harness.resolveNpmInvocation(npmBin)), {
    command: nodeExe, args: [npmCli]
  });
  const options = { npmBin, strictSsl: true, targetArch: 'arm64' };
  const args = ['view', 'example@>=1 <3', '--registry=https://example.invalid/?a=1&b=2'];
  const runOptions = { cwd: 'C:\\temporary work' };
  assert.strictEqual(harness.runNpm(options, args, runOptions), 'mock npm output');
  const [call] = harness.calls;
  assert.strictEqual(call.command, nodeExe);
  assert.deepStrictEqual(call.args, [npmCli, ...args]);
  assert.strictEqual(call.options.cwd, runOptions.cwd);
  assert.strictEqual(call.options.env.CUSTOM_NPM_TEST, 'inherited');
  assert.strictEqual(call.options.env.npm_config_cpu, 'arm64');
  assert.strictEqual(call.options.env.npm_config_engine_strict, 'false');
  assert.ok(!call.options.shell, 'npm arguments must not be interpreted by a shell');
  assert.deepStrictEqual(args, ['view', 'example@>=1 <3', '--registry=https://example.invalid/?a=1&b=2']);
}

{
  const firstDir = 'C:\\first npm';
  const secondDir = 'C:\\second npm';
  const firstCli = path.win32.join(firstDir, 'node_modules', 'npm', 'bin', 'npm-cli.js');
  const secondCli = path.win32.join(secondDir, 'node_modules', 'npm', 'bin', 'npm-cli.js');
  const harness = windowsHarness({
    files: [path.win32.join(firstDir, 'npm.cmd'), firstCli, path.win32.join(secondDir, 'npm.cmd'), secondCli],
    env: { PATH: `${firstDir};${secondDir}` }
  });
  assert.deepStrictEqual(plain(harness.resolveNpmInvocation('npm')), {
    command: 'C:\\Node\\node.exe', args: [firstCli]
  }, 'The first npm installation on PATH must win');
}

{
  const executable = path.win32.join(nodeDir, 'npm.exe');
  const harness = windowsHarness({ files: [executable, npmCmd, npmCli], env: { Path: nodeDir } });
  assert.deepStrictEqual(plain(harness.resolveNpmInvocation('npm')), {
    command: executable, args: []
  }, 'Native npm executables must retain precedence over batch launchers');
  assert.deepStrictEqual(plain(harness.resolveNpmInvocation(executable)), {
    command: executable, args: []
  });
}

{
  const harness = windowsHarness({ files: [npmCli], execPath: nodeExe });
  assert.deepStrictEqual(plain(harness.resolveNpmInvocation('npm')), {
    command: nodeExe, args: [npmCli]
  }, 'Default npm may use the CLI bundled beside the running Node executable');
  assert.throws(() => harness.resolveNpmInvocation('C:\\missing npm\\npm.cmd'),
    /not found|cannot|could not|missing|does not exist/i,
    'An explicit missing npm path must not silently use bundled npm');
}

{
  const explicitCmd = 'C:\\work\\tools with spaces\\npm.cmd';
  const explicitCli = 'C:\\work\\tools with spaces\\node_modules\\npm\\bin\\npm-cli.js';
  const harness = windowsHarness({ files: [explicitCmd, explicitCli] });
  assert.deepStrictEqual(plain(harness.resolveNpmInvocation('.\\tools with spaces\\npm.cmd')), {
    command: 'C:\\Node\\node.exe', args: [explicitCli]
  });
}

{
  const unsupportedCmd = 'C:\\tools\\custom-npm.cmd';
  const harness = windowsHarness({ files: [unsupportedCmd, npmCli], execPath: nodeExe });
  assert.throws(() => harness.resolveNpmInvocation(unsupportedCmd), /--npm-bin/,
    'Unsupported batch wrappers must explain how to select the npm CLI directly');
}

{
  const harness = windowsHarness();
  assert.throws(() => harness.resolveNpmInvocation('npm'), /ENOENT.*--npm-bin/);
  assert.throws(() => harness.resolveNpmInvocation('C:\\missing\\npm-cli.js'), /CLI not found.*--npm-bin/);
}

for (const extension of ['js', 'cjs', 'mjs']) {
  const cli = `C:\\work\\tools with spaces\\custom-npm.${extension}`;
  const harness = windowsHarness({ files: [cli] });
  assert.deepStrictEqual(plain(harness.resolveNpmInvocation(`.\\tools with spaces\\custom-npm.${extension}`)), {
    command: 'C:\\Node\\node.exe', args: [cli]
  });
}

// Run a real non-executable JavaScript CLI with a different child cwd. This catches
// accidental direct execution, quoting, and relative-path resolution regressions.
const { resolveNpmInvocation, runNpm } = require(downloader);
if (process.platform !== 'win32') {
  assert.deepStrictEqual(resolveNpmInvocation('npm'), { command: 'npm', args: [] });
  assert.deepStrictEqual(resolveNpmInvocation('/custom/npm-wrapper'), { command: '/custom/npm-wrapper', args: [] });
}
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'npm launcher test '));
try {
  const cli = path.join(tmp, 'fake npm cli.js');
  const childCwd = path.join(tmp, 'child cwd');
  fs.mkdirSync(childCwd);
  fs.writeFileSync(cli, `process.stdout.write(JSON.stringify({
    args: process.argv.slice(2), cwd: process.cwd(), cpu: process.env.npm_config_cpu
  }));\n`, { mode: 0o600 });
  const npmBin = path.relative(process.cwd(), cli);
  const args = ['view', 'example@>=1 <3', 'https://example.invalid/?a=1&b=2', 'a path with spaces'];
  const output = runNpm({ npmBin, strictSsl: true, targetArch: 'arm64' }, args, { cwd: childCwd });
  const actual = JSON.parse(output);
  assert.deepStrictEqual(actual.args, args);
  assert.strictEqual(fs.realpathSync(actual.cwd), fs.realpathSync(childCwd));
  assert.strictEqual(actual.cpu, 'arm64');
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}

console.log('npm launcher tests passed');
