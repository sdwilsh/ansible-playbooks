'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {
  MKVMERGE_PROPERTIES, STDERR_LINE, trimMkvmerge, trimFfprobe, writeFixtures, writeStderrFixture, writeGrainFixture, main,
} = require('./fixtures/make-fixture.js');

const dir = path.join(__dirname, 'fixtures');
const files = fs.readdirSync(dir);
const scenarios = files.filter((f) => f.endsWith('.source.mkvmerge.json')).map((f) => f.replace('.source.mkvmerge.json', ''));
const stderrFiles = files.filter((f) => f.endsWith('.stderr.txt'));
const grainFiles = files.filter((f) => f.endsWith('.grain-frames.json'));
const read = (name) => fs.readFileSync(path.join(dir, name), 'utf8');
const readJson = (name) => JSON.parse(read(name));
const clone = (x) => JSON.parse(JSON.stringify(x));
const loadScenario = (name) => Object.fromEntries(['source', 'output'].map((role) => [role, {
  mkvmerge: readJson(`${name}.${role}.mkvmerge.json`),
  ffprobe: readJson(`${name}.${role}.ffprobe.json`),
}]));
const DTS_71 = 'bd-dts-hd-ma-7.1';

function tempDir(t) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'make-fixture-'));
  t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));
  return tmp;
}

test('make-fixture: trimming each committed fixture again writes the same bytes', (t) => {
  assert.ok(scenarios.length > 0 && stderrFiles.length > 0 && grainFiles.length > 0, 'fixtures were found');
  const tmp = tempDir(t);
  const written = [
    ...scenarios.flatMap((name) => writeFixtures(tmp, name, loadScenario(name))),
    ...stderrFiles.flatMap((f) => writeStderrFixture(tmp, f.replace('.idet-mpdecimate.stderr.txt', ''), read(f))),
    ...grainFiles.flatMap((f) => writeGrainFixture(tmp, f.replace('.grain-frames.json', ''), readJson(f))),
  ];
  assert.deepEqual(written.sort(), files.filter((f) => !/^(README\.md|make-fixture\.js|\.gitignore)$/.test(f)).sort());
  for (const name of written) assert.equal(fs.readFileSync(path.join(tmp, name), 'utf8'), read(name), name);
});

test('make-fixture: the trim drops file names, titles, uids, track names, codec names and writer tags', () => {
  const source = readJson(`${DTS_71}.source.mkvmerge.json`);
  const dirty = clone(source);
  Object.assign(dirty, { file_name: '/rips/Some Disc.mkv', container: { properties: { title: 'Some Disc', uid: 'abc' } }, attachments: [{ file_name: 'cover.jpg' }] });
  for (const track of dirty.tracks) {
    Object.assign(track, { codec: 'DTS-HD Master Audio' });
    Object.assign(track.properties, { uid: 123, track_name: 'Some Disc Commentary', encoding: 'utf8', tag_title: 'Some Disc' });
  }
  assert.deepEqual(trimMkvmerge(dirty), source);

  const probe = readJson(`${DTS_71}.output.ffprobe.json`);
  const dirtyProbe = clone(probe);
  Object.assign(dirtyProbe.format, { filename: '/rips/Some Disc.mkv', size: '1', start_time: '0' });
  Object.assign(dirtyProbe.format.tags, { ENCODER: 'libmatroska', creation_time: '2026-01-01T00:00:00Z', title: 'Some Disc' });
  for (const [i, stream] of dirtyProbe.streams.entries()) {
    Object.assign(stream, { index: i, codec_name: 'ac3', bit_rate: '1', disposition: { default: 1, attached_pic: 0 }, tags: { ...stream.tags, title: 'Some Disc', BPS: '1' } });
  }
  assert.deepEqual(trimFfprobe(dirtyProbe), probe);
});

test('make-fixture: the trim keeps a language duration tag and a cover art flag', () => {
  const trimmed = trimFfprobe({
    format: { duration: '10.0' },
    streams: [
      { index: 0, codec_type: 'video', codec_name: 'mjpeg', disposition: { attached_pic: 1 } },
      { index: 1, codec_type: 'audio', codec_name: 'ac3', tags: { 'DURATION-eng': '00:00:10.000000000', title: 'x' } },
    ],
  });
  assert.deepEqual(trimmed.streams[0], { codec_type: 'video', disposition: { attached_pic: 1 } });
  assert.deepEqual(trimmed.streams[1], { codec_type: 'audio', tags: { 'DURATION-eng': '00:00:10.000000000' } });
});

test('make-fixture: the marker tag keeps its value and every other global tag gets one placeholder per value, in both files', (t) => {
  const tmp = tempDir(t);
  const input = loadScenario(DTS_71);
  input.source.ffprobe.format.tags = { DISC_TAGGER_DISC: 'secret-hash', Other_Key: 'secret-text', ENCODER: 'libebml', title: 'Some Disc' };
  input.output.ffprobe.format.tags = { ...input.source.ffprobe.format.tags, DISC_TAGGER_DISC: 'secret-hash', Other_Key: 'secret-changed', TDARR_TARGET: '1' };
  const warnings = [];
  writeFixtures(tmp, 'tags', input, { warn: (m) => warnings.push(m) });
  const tagsOf = (role) => JSON.parse(fs.readFileSync(path.join(tmp, `tags.${role}.ffprobe.json`), 'utf8')).format.tags;
  assert.deepEqual(tagsOf('source'), { DISC_TAGGER_DISC: 'tag-1', Other_Key: 'tag-2' });
  assert.deepEqual(tagsOf('output'), { DISC_TAGGER_DISC: 'tag-1', Other_Key: 'tag-3', TDARR_TARGET: '1' });
  assert.equal(warnings.length, 4);
  for (const f of fs.readdirSync(tmp)) assert.ok(!/secret|Some Disc/.test(fs.readFileSync(path.join(tmp, f), 'utf8')), f);
});

test('make-fixture: the self-check refuses a trim that drops a field the code reads', (t) => {
  const tmp = tempDir(t);
  const withoutDefault = MKVMERGE_PROPERTIES.filter((k) => k !== 'default_track');
  assert.throws(() => writeFixtures(tmp, 'refused', loadScenario(DTS_71), { mkvmergeProperties: withoutDefault }), /changes what target-convert\.js computes/);
  assert.deepEqual(fs.readdirSync(tmp), []);
});

test('make-fixture: every line of a committed idet and mpdecimate capture has the Parsed prefix', () => {
  for (const name of stderrFiles) {
    const lines = read(name).trimEnd().split('\n');
    assert.ok(lines.length > 0, name);
    for (const line of lines) assert.match(line, STDERR_LINE, `${name}: ${line}`);
  }
});

test('make-fixture: the stderr trim drops the input path, the title and every other line without the Parsed prefix', (t) => {
  const tmp = tempDir(t);
  const idet = '[Parsed_idet_0 @ 0x55a3be69d980] Multi frame detection: TFF:     3 BFF:     0 Progressive:     0 Undetermined:     0';
  const decimate = '[Parsed_mpdecimate_1 @ 0x7f2f40002880] keep pts:27 pts_time:0.027 drop_count:-1 keep_count:0';
  const raw = ['Input #0, matroska,webm, from \'/rips/Secret Film (1999).mkv\':', '    title           : Secret Film (1999)', idet,
    '[matroska,webm @ 0x1] Opening an input file: /rips/Secret Film (1999).mkv', decimate, ''].join('\n');
  assert.deepEqual(writeStderrFixture(tmp, 'sample', raw), ['sample.idet-mpdecimate.stderr.txt']);
  assert.equal(fs.readFileSync(path.join(tmp, 'sample.idet-mpdecimate.stderr.txt'), 'utf8'), `${idet}\n${decimate}\n`);
});

test('make-fixture: the grain fixture holds only the fields that grainStrengths reads', () => {
  const allowed = { '': ['frames'], frames: ['side_data_list'], side_data_list: ['side_data_type', 'components'], components: ['y_points_scaling'] };
  const walk = (value, kind, name) => {
    if (Array.isArray(value)) return value.forEach((v) => walk(v, kind, name));
    if (value === null || typeof value !== 'object') return undefined;
    assert.ok(Object.keys(value).every((k) => allowed[kind].includes(k)), `${name}: ${kind} holds ${Object.keys(value)}`);
    return Object.entries(value).forEach(([k, v]) => walk(v, k, name));
  };
  assert.ok(grainFiles.length > 0);
  for (const name of grainFiles) walk(readJson(name), '', name);
});

test('make-fixture: the grain trim drops every other field', (t) => {
  const tmp = tempDir(t);
  const probe = { frames: [{ pts: 1, side_data_list: [{ side_data_type: 'Film grain parameters', seed: 7, components: [{ y_points_value: '0 255', y_points_scaling: '37 36' }] },
    { side_data_type: 'Other', size: 3 }] }, { pts: 2 }] };
  writeGrainFixture(tmp, 'sample', probe);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(tmp, 'sample.grain-frames.json'), 'utf8')), {
    frames: [{ side_data_list: [{ side_data_type: 'Film grain parameters', components: [{ y_points_scaling: '37 36' }] }, { side_data_type: 'Other' }] }, {}],
  });
});

test('make-fixture: a source or an output longer than 600 s is refused, and 600 s is accepted', (t) => {
  const tmp = tempDir(t);
  for (const role of ['source', 'output']) {
    const input = loadScenario(DTS_71);
    input[role].ffprobe.format.duration = '700.000000';
    assert.throws(() => writeFixtures(tmp, 'long', input), new RegExp(`${role} duration is 700.000000 s`));
  }
  assert.deepEqual(fs.readdirSync(tmp), []);
  const limit = loadScenario(DTS_71);
  for (const role of ['source', 'output']) limit[role].ffprobe.format.duration = '600';
  assert.equal(writeFixtures(tmp, 'limit', limit).length, 4);
});

test('make-fixture: a name with upper case letters or a path is refused and nothing is written', (t) => {
  const tmp = tempDir(t);
  for (const name of ['Upper', '../escape', '']) assert.throws(() => writeFixtures(tmp, name, loadScenario(DTS_71)), /scenario name/);
  assert.deepEqual(fs.readdirSync(tmp), []);
});

function withFakeTools(t, env) {
  const tmp = tempDir(t);
  for (const tool of ['mkvmerge', 'ffprobe']) {
    const file = path.join(tmp, tool);
    fs.writeFileSync(file, `#!/usr/bin/env node\nrequire(${JSON.stringify(path.join(__dirname, 'fakes/tool.js'))})(${JSON.stringify(tool)}, process.argv.slice(2));\n`, { mode: 0o755 });
  }
  const saved = { ...process.env };
  Object.assign(process.env, { MKVMERGE: path.join(tmp, 'mkvmerge'), FFPROBE: path.join(tmp, 'ffprobe'), FAKE_SCENARIO: DTS_71, FAKE_INPUT: '/rips/source.mkv', ...env });
  t.after(() => { for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k]; Object.assign(process.env, saved); });
  const out = path.join(tmp, 'out');
  fs.mkdirSync(out);
  return out;
}

test('make-fixture: capture mode takes mkvmerge exit 1 as a warning and writes the committed bytes', (t) => {
  const out = withFakeTools(t, { FAKE_WARN: 'mkvmerge' });
  main(['captured', '/rips/source.mkv', '/rips/output.mkv'], out);
  for (const file of fs.readdirSync(out)) assert.equal(fs.readFileSync(path.join(out, file), 'utf8'), read(file.replace('captured', DTS_71)), file);
  assert.equal(fs.readdirSync(out).length, 4);
});

test('make-fixture: capture mode refuses an ffprobe failure', (t) => {
  const out = withFakeTools(t, { FAKE_WARN: 'ffprobe' });
  assert.throws(() => main(['captured', '/rips/source.mkv', '/rips/output.mkv'], out), /ffprobe exited 1/);
  assert.deepEqual(fs.readdirSync(out), []);
});

test('make-fixture: main checks the scenario name before it runs any tool', (t) => {
  const out = withFakeTools(t, { MKVMERGE: '/nonexistent/mkvmerge' });
  assert.throws(() => main(['Bad Name', '/rips/source.mkv', '/rips/output.mkv'], out), /scenario name/);
});

test('make-fixture: main reads the JSON mode and the stderr mode from files', (t) => {
  const out = withFakeTools(t, {});
  const names = ['source.mkvmerge', 'source.ffprobe', 'output.mkvmerge', 'output.ffprobe'];
  main(['--from-json', 'copy', ...names.map((n) => path.join(dir, `${DTS_71}.${n}.json`))], out);
  main(['--idet-mpdecimate', 'copy', path.join(dir, stderrFiles[0])], out);
  assert.deepEqual(fs.readdirSync(out).sort(), [...names.map((n) => `copy.${n}.json`), 'copy.idet-mpdecimate.stderr.txt'].sort());
  assert.throws(() => main(['--unknown'], out), /usage:/);
});
