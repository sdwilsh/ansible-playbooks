'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { listFlowFiles, main, syncFlow, waitForServer } = require('./sync-flows.js');

const flows = listFlowFiles(__dirname).map((f) => JSON.parse(fs.readFileSync(path.join(__dirname, f), 'utf8')));

const refused = () => new TypeError('fetch failed', { cause: Object.assign(new Error('connect ECONNREFUSED 10.0.0.1:8265'), { code: 'ECONNREFUSED' }) });

// A tdarr server stand-in.  The first `downFor` requests fail like a server that is still starting.
function fakeTdarr({ stored = {}, mutate = (flow) => flow, failMode = null, downFor = 0 } = {}) {
  const docs = new Map(Object.entries(stored));
  const requests = [];
  let down = downFor;
  const doFetch = async (url, init) => {
    assert.equal(url, 'http://tdarr/api/v2/cruddb');
    assert.equal(init.method, 'POST');
    if (down === Infinity || down-- > 0) throw refused();
    const { data } = JSON.parse(init.body);
    requests.push(data);
    assert.equal(data.collection, 'FlowsJSONDB');
    if (data.mode === failMode) return { ok: false, status: 500, text: async () => '' };
    if (data.mode === 'getById') return { ok: true, status: 200, text: async () => (docs.has(data.docID) ? JSON.stringify(docs.get(data.docID)) : '') };
    docs.set(data.docID, mutate(data.obj));
    return { ok: true, status: 200, text: async () => '' };
  };
  return { doFetch, requests, docs };
}

// A clock that moves only when the code sleeps.
function fakeClock() {
  const clock = { time: 0, sleeps: [] };
  clock.now = () => clock.time;
  clock.sleep = async (ms) => { clock.time += ms; clock.sleeps.push(ms); };
  return clock;
}

test('listFlowFiles: takes the regular .json files of a ConfigMap mount and nothing else', (t) => {
  const mount = fs.mkdtempSync(path.join(os.tmpdir(), 'tdarr-flows-mount-'));
  t.after(() => fs.rmSync(mount, { recursive: true, force: true }));
  fs.mkdirSync(path.join(mount, '..2026_11_19'));
  for (const name of ['a.json', 'b.json', 'sync-flows.js', '..hidden.json']) fs.writeFileSync(path.join(mount, '..2026_11_19', name), '{}');
  fs.symlinkSync('..2026_11_19', path.join(mount, '..data'));
  for (const name of ['a.json', 'b.json', 'sync-flows.js']) fs.symlinkSync(path.join('..data', name), path.join(mount, name));
  fs.mkdirSync(path.join(mount, 'dir.json'));
  assert.deepEqual(listFlowFiles(mount), ['a.json', 'b.json']);
});

test('sync: a flow that tdarr lacks is inserted, then read back', async () => {
  const server = fakeTdarr();
  assert.equal(await syncFlow('http://tdarr', server.doFetch, flows[0]), 'insert');
  assert.deepEqual(server.requests.map((r) => r.mode), ['getById', 'insert', 'getById']);
  assert.deepEqual(server.requests[1].obj, flows[0]);
  assert.deepEqual(server.docs.get(flows[0]._id), flows[0]);
});

test('sync: a flow that tdarr has is updated', async () => {
  const server = fakeTdarr({ stored: { [flows[0]._id]: { ...flows[0], flowEdges: [] } } });
  assert.equal(await syncFlow('http://tdarr', server.doFetch, flows[0]), 'update');
  assert.deepEqual(server.requests.map((r) => r.mode), ['getById', 'update', 'getById']);
  assert.deepEqual(server.docs.get(flows[0]._id).flowEdges, flows[0].flowEdges);
});

test('sync: a stored flow that differs from the file fails', async () => {
  const server = fakeTdarr({ mutate: (flow) => ({ ...flow, flowPlugins: flow.flowPlugins.slice(1) }) });
  await assert.rejects(syncFlow('http://tdarr', server.doFetch, flows[0]), /stored flowPlugins differ/);
});

test('sync: an HTTP error fails', async () => {
  const server = fakeTdarr({ failMode: 'insert' });
  await assert.rejects(syncFlow('http://tdarr', server.doFetch, flows[0]), /insert .*: HTTP 500/);
});

test('sync: main syncs every flow file and counts none failed', async (t) => {
  t.mock.method(console, 'log', () => {});
  const server = fakeTdarr();
  assert.equal(await main('http://tdarr', server.doFetch, __dirname, fakeClock()), 0);
  assert.deepEqual([...server.docs.keys()].sort(), flows.map((f) => f._id).sort());
});

test('sync: main still tries every flow after one fails, and reports the failures', async (t) => {
  t.mock.method(console, 'error', () => {});
  t.mock.method(console, 'log', () => {});
  const server = fakeTdarr({ failMode: 'insert' });
  assert.equal(await main('http://tdarr', server.doFetch, __dirname, fakeClock()), flows.length);
  assert.equal(server.requests.filter((r) => r.mode === 'insert').length, flows.length);
});

test('sync: a server that is down twice and then up is synced', async (t) => {
  const log = t.mock.method(console, 'log', () => {});
  const clock = fakeClock();
  const server = fakeTdarr({ downFor: 2 });
  assert.equal(await main('http://tdarr', server.doFetch, __dirname, clock), 0);
  assert.deepEqual(clock.sleeps, [5000, 5000]);
  assert.deepEqual([...server.docs.keys()].sort(), flows.map((f) => f._id).sort());
  assert.ok(log.mock.calls.some((c) => /ECONNREFUSED/.test(c.arguments[0])), 'the wait message names the cause');
});

test('sync: a server that stays down past the deadline fails every flow and writes nothing', async (t) => {
  t.mock.method(console, 'log', () => {});
  const error = t.mock.method(console, 'error', () => {});
  const clock = fakeClock();
  const server = fakeTdarr({ downFor: Infinity });
  assert.equal(await main('http://tdarr', server.doFetch, __dirname, clock), flows.length);
  assert.equal(server.requests.length, 0);
  assert.equal(clock.time, 5 * 60 * 1000);
  assert.match(error.mock.calls[0].arguments[0], /did not answer within 300 s.*ECONNREFUSED/);
});

test('sync: waitForServer returns at once when the server answers', async () => {
  const clock = fakeClock();
  await waitForServer('http://tdarr', fakeTdarr().doFetch, clock);
  assert.deepEqual(clock.sleeps, []);
});

test('sync: a directory without flow files fails', async (t) => {
  t.mock.method(console, 'error', () => {});
  const empty = fs.mkdtempSync(path.join(os.tmpdir(), 'tdarr-flows-empty-'));
  t.after(() => fs.rmSync(empty, { recursive: true, force: true }));
  assert.equal(await main('http://tdarr', fakeTdarr().doFetch, empty, fakeClock()), 1);
});
