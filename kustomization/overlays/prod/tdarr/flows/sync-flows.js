'use strict';

const fs = require('fs');
const path = require('path');
const { isDeepStrictEqual } = require('util');

const WAIT = { deadlineMs: 5 * 60 * 1000, intervalMs: 5000 };

// Node names a failed fetch "fetch failed" and puts the reason in `cause`.
const describe = (e) => (e.cause ? `${e.message} (${e.cause.code || e.cause.message || e.cause})` : e.message);

// A ConfigMap mount holds symlinks and `..data` entries.  Take only the regular `.json` files.
function listFlowFiles(dir) {
  return fs.readdirSync(dir)
    .filter((name) => name.endsWith('.json') && !name.startsWith('.') && fs.statSync(path.join(dir, name)).isFile())
    .sort();
}

async function cruddb(baseUrl, doFetch, data) {
  const res = await doFetch(`${baseUrl}/api/v2/cruddb`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ data: { collection: 'FlowsJSONDB', ...data } }),
    signal: AbortSignal.timeout(30000),
  });
  if (!res.ok) throw new Error(`${data.mode} ${data.docID}: HTTP ${res.status}`);
  const body = await res.text();
  return body ? JSON.parse(body) : null;
}

// tdarr answers HTTP 200 with an empty body for a missing flow.
const exists = (doc) => Boolean(doc && doc._id);

// The Job runs when Argo CD finishes the sync.  The server pod can still be starting.
async function waitForServer(baseUrl, doFetch, { now = Date.now, sleep = (ms) => new Promise((r) => setTimeout(r, ms)), ...wait } = {}) {
  const { deadlineMs, intervalMs } = { ...WAIT, ...wait };
  const deadline = now() + deadlineMs;
  for (;;) {
    try {
      await cruddb(baseUrl, doFetch, { mode: 'getById', docID: 'tdarr-flows-sync-probe' });
      return;
    } catch (e) {
      if (now() >= deadline) throw new Error(`tdarr did not answer within ${deadlineMs / 1000} s: ${describe(e)}`);
      console.log(`waiting for tdarr: ${describe(e)}`);
      await sleep(intervalMs);
    }
  }
}

async function syncFlow(baseUrl, doFetch, flow) {
  const docID = flow._id;
  const mode = exists(await cruddb(baseUrl, doFetch, { mode: 'getById', docID })) ? 'update' : 'insert';
  await cruddb(baseUrl, doFetch, { mode, docID, obj: flow });
  const stored = await cruddb(baseUrl, doFetch, { mode: 'getById', docID });
  if (!exists(stored)) throw new Error(`${docID}: flow missing after ${mode}`);
  for (const key of ['flowPlugins', 'flowEdges']) {
    if (!isDeepStrictEqual(stored[key], flow[key])) throw new Error(`${docID}: stored ${key} differ from the file`);
  }
  return mode;
}

// Returns the number of flows that failed.  A server that never answers fails them all.
async function main(baseUrl, doFetch, dir, wait) {
  const files = listFlowFiles(dir);
  if (files.length === 0) {
    console.error(`no flow file in ${dir}`);
    return 1;
  }
  try {
    await waitForServer(baseUrl, doFetch, wait);
  } catch (e) {
    console.error(e.message);
    return files.length;
  }
  let failed = 0;
  for (const file of files) {
    let id = file;
    try {
      const flow = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
      id = flow._id;
      console.log(`${id}: ${await syncFlow(baseUrl, doFetch, flow)} ok`);
    } catch (e) {
      failed += 1;
      console.error(`${id}: FAILED ${describe(e)}`);
    }
  }
  return failed;
}

if (require.main === module) {
  if (!process.env.TDARR_URL) {
    console.error('TDARR_URL is not set');
    process.exit(1);
  }
  main(process.env.TDARR_URL, fetch, __dirname).then((failed) => process.exit(failed ? 1 : 0));
}

module.exports = { listFlowFiles, main, syncFlow, waitForServer };
