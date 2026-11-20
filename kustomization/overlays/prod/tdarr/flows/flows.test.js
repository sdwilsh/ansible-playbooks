'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { listFlowFiles } = require('./sync-flows.js');
const { OUTPUT_CONVERTED, OUTPUT_AT_TARGET } = require('./target-convert.js');

const flowFiles = listFlowFiles(__dirname);
const flows = flowFiles.map((f) => JSON.parse(fs.readFileSync(path.join(__dirname, f), 'utf8')));
const byId = new Map(flows.map((f) => [f._id, f]));
const nodes = flows.flatMap((f) => f.flowPlugins.map((p) => ({ flow: f._id, ...p })));
const overlay = path.join(__dirname, '..');
const mountPatch = fs.readFileSync(path.join(overlay, 'patches', 'add_target_code_volume.yml'), 'utf8');
const kustomization = fs.readFileSync(path.join(overlay, 'kustomization.yml'), 'utf8');
const stubCode = flows.flatMap((f) => f.flowPlugins).find((p) => p.pluginName === 'customFunction').inputsDB.code;
const node = (flowId, id) => byId.get(flowId).flowPlugins.find((p) => p.id === id);

test('flows: the three flows have distinct ids and every node id is unique in its flow', () => {
  assert.deepEqual([...byId.keys()].sort(), ['tgtConvert', 'tgtMovies', 'tgtShows']);
  for (const f of flows) {
    const ids = f.flowPlugins.map((p) => p.id);
    assert.equal(new Set(ids).size, ids.length, f._id);
  }
});

test('flows: the tdarr-flows ConfigMap holds every flow file', () => {
  for (const file of flowFiles) assert.match(kustomization, new RegExp(`^ {6}- flows/${file.replace('.', '\\.')}$`, 'm'), file);
});

test('flows: every edge points to a node that exists in its flow', () => {
  for (const f of flows) {
    const ids = new Set(f.flowPlugins.map((p) => p.id));
    for (const e of f.flowEdges) {
      assert.ok(ids.has(e.source), `${f._id} edge ${e.id} source ${e.source}`);
      assert.ok(ids.has(e.target), `${f._id} edge ${e.id} target ${e.target}`);
    }
  }
});

test('flows: every goToFlow targets a flow that exists', () => {
  const goTo = nodes.filter((n) => n.pluginName === 'goToFlow');
  assert.ok(goTo.length > 0);
  for (const n of goTo) assert.ok(byId.has(n.inputsDB.flowId), `${n.flow} ${n.id} -> ${n.inputsDB.flowId}`);
});

test('flows: no checkFileNameIncludes node has empty terms, which would match every path', () => {
  const checks = nodes.filter((n) => n.pluginName === 'checkFileNameIncludes');
  assert.ok(checks.length > 0);
  for (const n of checks) assert.ok(String(n.inputsDB.terms || '').trim() !== '', `${n.flow} ${n.id}`);
});

// The matching rule of the tdarr checkFileNameIncludes plugin.
function passes(check, filePath) {
  const { terms, pattern, includeFileDirectory } = check.inputsDB;
  const target = includeFileDirectory === 'true' ? filePath : path.basename(filePath);
  const regexes = String(terms).trim().split(',').map((term) => term.replace(/[\\^$*+?.()|[\]{}]/g, '\\$&'));
  if (pattern) regexes.push(pattern);
  return regexes.some((r) => new RegExp(r).test(target));
}

test('flows: a movie or episode file name passes the library name check', () => {
  const movies = node('tgtMovies', 'mvName');
  const shows = node('tgtShows', 'shName');
  assert.ok(passes(movies, '/media/movies/Example Film (2021)/Example Film (2021).mkv'));
  assert.ok(passes(shows, '/media/tv/Example Show (2023)/Season 01/S01E01.mkv'));
  assert.ok(passes(shows, '/media/tv/X (2020)/Season 02/X S02E05.mkv'));
  assert.ok(!passes(movies, '/media/movies/Example Film (2021)/extras/Making of.mkv'));
  assert.ok(!passes(shows, '/media/tv/Smother Lake (2005)/title_t00.mkv'));
});

test('flows: the extras check passes a file in an extras folder and not a title that holds a folder word', () => {
  for (const [flowId, id] of [['tgtMovies', 'mvExtras'], ['tgtShows', 'shExtras']]) {
    const extras = node(flowId, id);
    assert.ok(passes(extras, '/media/movies/Example Film (2021)/extras/Making of.mkv'), flowId);
    assert.ok(passes(extras, '/media/tv/Example Show (2023)/featurettes/Cast.mkv'), flowId);
    assert.ok(!passes(extras, '/media/tv/Smother Lake (2005)/title_t00.mkv'), flowId);
    assert.ok(!passes(extras, '/media/movies/Teenscenes (2010)/title_t00.mkv'), flowId);
    assert.ok(!passes(extras, '/media/movies/Eclipse Road (2001)/title_t00.mkv'), flowId);
  }
});

test('flows: a hidden file or a file in a hidden folder ends the flow before any other check', () => {
  for (const [flowId, pre] of [['tgtMovies', 'mv'], ['tgtShows', 'sh']]) {
    const f = byId.get(flowId);
    const next = (id, handle) => f.flowEdges.find((e) => e.source === id && e.sourceHandle === String(handle)).target;
    assert.equal(next(`${pre}Input`, 1), `${pre}Skip`, flowId);
    assert.equal(f.flowEdges.some((e) => e.source === next(`${pre}Skip`, 1)), false, `${flowId}: the skip branch ends`);
    assert.equal(next(`${pre}Skip`, 2), `${pre}Name`, flowId);
    const skip = node(flowId, `${pre}Skip`);
    assert.ok(passes(skip, '/media/tv/X (2020)/Season 01/.X S01E01.mkv.part'), `${flowId}: .part file`);
    assert.ok(passes(skip, '/media/movies/Example Film (2021)/.Example Film (2021).part.d/title_t00.mkv'), `${flowId}: hidden folder`);
    assert.ok(passes(skip, '/media/tv/X (2020)/.trash/X S01E01.mkv'), `${flowId}: any hidden folder`);
    assert.ok(!passes(skip, '/media/movies/Example Film (2021)/Example Film (2021).mkv'), `${flowId}: library file`);
    assert.ok(!passes(skip, '/media/tv/Example Show (2023)/Season 01/Example Show S01E01.mkv'), `${flowId}: library episode`);
  }
});

test('flows: the extras and trailer checks are the same in both library flows', () => {
  assert.deepEqual(node('tgtMovies', 'mvExtras').inputsDB, node('tgtShows', 'shExtras').inputsDB);
  assert.deepEqual(node('tgtMovies', 'mvTrailer').inputsDB, node('tgtShows', 'shTrailer').inputsDB);
});

test('flows: the custom function requires the path that the node deployment mounts', () => {
  const mount = /mountPath: (\S+)/.exec(mountPatch)[1];
  const required = /realpathSync\('([^']+)'\)/.exec(stubCode)[1];
  assert.equal(required, `${mount}/target-convert.js`);
});

test('flows: the custom function outputs lead to the health check and to the at-target end', () => {
  const convert = byId.get('tgtConvert');
  const fn = convert.flowPlugins.find((p) => p.pluginName === 'customFunction');
  const targetOf = (handle) => {
    const edge = convert.flowEdges.find((e) => e.source === fn.id && e.sourceHandle === String(handle));
    return convert.flowPlugins.find((p) => p.id === edge.target).pluginName;
  };
  assert.equal(targetOf(OUTPUT_CONVERTED), 'runHealthCheck');
  assert.equal(targetOf(OUTPUT_AT_TARGET), 'comment');
});

test('flows: the custom function clears the require cache at the real path of the mounted file', async () => {
  const link = '/app/target/target-convert.js';
  const real = '/app/target/..2026_11_19/target-convert.js';
  const calls = [];
  const cache = { [link]: 'stale', [real]: 'stale' };
  const fakeFs = { realpathSync: (file) => (file === link ? real : file) };
  const fakeRequire = Object.assign((name) => {
    if (name === 'fs') return fakeFs;
    calls.push({ file: name, cached: name in cache });
    return async (args) => `converted ${args.id}`;
  }, { cache });
  const mod = { exports: null };
  new Function('module', 'require', stubCode)(mod, fakeRequire);
  assert.equal(await mod.exports({ id: 'a' }), 'converted a');
  assert.deepEqual(calls, [{ file: real, cached: false }]);
});
