'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const convert = require('./target-convert.js');

const INPUT = '/media/source.mkv';

function setup(t, env) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'target-convert-io-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const tool of ['ffmpeg', 'ffprobe', 'mkvmerge', 'mkvpropedit']) {
    const file = path.join(root, 'bin', tool);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, `#!/usr/bin/env node\nrequire(${JSON.stringify(path.join(__dirname, 'fakes/tool.js'))})(${JSON.stringify(tool)}, process.argv.slice(2));\n`, { mode: 0o755 });
  }
  const log = path.join(root, 'written.log');
  fs.writeFileSync(log, '');
  const saved = { ...process.env };
  Object.assign(process.env, { FAKE_INPUT: INPUT, FAKE_LOG: log }, env);
  t.after(() => { for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k]; Object.assign(process.env, saved); });
  const workDir = path.join(root, 'work');
  fs.mkdirSync(workDir);
  const args = {
    ffmpegPath: path.join(root, 'bin', 'ffmpeg'),
    mkvpropeditPath: path.join(root, 'bin', 'mkvpropedit'),
    workDir,
    inputFileObj: { _id: INPUT },
    jobLog: () => {},
    updateWorker: () => {},
    variables: {},
  };
  const written = () => fs.readFileSync(log, 'utf8').split('\n').filter(Boolean);
  return { args, workDir, written };
}

const leftovers = (workDir) => fs.readdirSync(workDir).flatMap((d) => fs.readdirSync(path.join(workDir, d)));

test('convert: an AV1 conversion leaves only the output file in the work directory', async (t) => {
  const { args, workDir, written } = setup(t, { FAKE_SCENARIO: 'bd-dts-hd-ma-7.1' });
  const result = await convert(args);
  assert.equal(result.outputNumber, convert.OUTPUT_CONVERTED);
  assert.equal(path.basename(result.outputFileObj._id), 'source.mkv');
  assert.ok(fs.existsSync(result.outputFileObj._id));
  assert.deepEqual(leftovers(workDir), ['source.mkv']);
  const names = written();
  for (const intermediate of ['video-av1.mkv', 'compat-0.mka', 'grain-sample-0.mkv']) assert.ok(names.includes(intermediate), `${intermediate} was written`);
});

test('convert: a remux conversion leaves only the output file in the work directory', async (t) => {
  const { args, workDir, written } = setup(t, { FAKE_SCENARIO: 'uhd-truehd-atmos' });
  const result = await convert(args);
  assert.equal(result.outputNumber, convert.OUTPUT_CONVERTED);
  assert.deepEqual(leftovers(workDir), ['source.mkv']);
  assert.ok(written().includes('compat-0.mka'));
});

test('convert: a failed output check removes every intermediate and the output', async (t) => {
  const { args, workDir, written } = setup(t, { FAKE_SCENARIO: 'bd-dts-hd-ma-7.1', FAKE_OUTPUT_IS_SOURCE: '1' });
  await assert.rejects(convert(args), /target checks failed/);
  assert.deepEqual(fs.readdirSync(workDir), []);
  assert.ok(written().includes('video-av1.mkv'), 'the AV1 video existed before the check');
});

test('convert: a failed mkvmerge run removes the intermediates', async (t) => {
  const { args, workDir, written } = setup(t, { FAKE_SCENARIO: 'bd-dts-hd-ma-7.1', FAKE_FAIL: 'mkvmerge' });
  await assert.rejects(convert(args), /mkvmerge exited 2/);
  assert.deepEqual(fs.readdirSync(workDir), []);
  assert.ok(written().includes('compat-0.mka'), 'the compat file existed before the failure');
});

test('convert: mkvmerge may exit 1 for a warning, and ffmpeg may not', async (t) => {
  const warned = setup(t, { FAKE_SCENARIO: 'uhd-truehd-atmos', FAKE_WARN: 'mkvmerge' });
  assert.equal((await convert(warned.args)).outputNumber, convert.OUTPUT_CONVERTED);
  const broken = setup(t, { FAKE_SCENARIO: 'uhd-truehd-atmos', FAKE_WARN: 'ffmpeg' });
  await assert.rejects(convert(broken.args), /ffmpeg exited 1/);
});
