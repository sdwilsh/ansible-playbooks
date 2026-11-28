'use strict';
// Find the library titles that the old flows damaged, and keep the list in one Forgejo issue.
// usage: node rerip-list.js <cache.jsonl> <root>...
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const { parseIdet, sampleStarts } = require('./target-convert.js');

const FFMPEG = '/usr/lib/jellyfin-ffmpeg/ffmpeg';
const FFPROBE = '/usr/lib/jellyfin-ffmpeg/ffprobe';
const IDET_FRACTIONS = [0.25, 0.5, 0.75];
const IDET_SECS = 30;
const COMBED = 0.6;
const LIGHTLY_COMBED = 0.05;
const MARKER = 'rerip-list v1';
const TITLE = 'Library titles to re-rip';
const LABEL = 'rerip-list';

const REASONS = {
  unreadable: 'unreadable',
  audio: 'damaged audio',
  combed: 'combed video',
  light: 'lightly combed video',
};
const SECTIONS = {
  rerip: 'Re-rip',
  check: 'Lightly combed: examine before a re-rip',
};

// The old flows encoded every file to AV1 and the audio to AAC or Opus.  A file in another
// codec is a source that tdarr did not convert yet.  A file with the target tag is new.
function judge(rec) {
  if (rec.error) return ['unreadable'];
  if (rec.target || !rec.video || rec.video.codec !== 'av1') return [];
  const reasons = [];
  if (rec.audio.some((a) => a.codec === 'aac' || a.codec === 'opus')) reasons.push('audio');
  if (rec.combedShare >= COMBED) reasons.push('combed');
  else if (rec.combedShare >= LIGHTLY_COMBED) reasons.push('light');
  return reasons;
}

const needsIdet = (rec) => !rec.error && !rec.target && rec.video && rec.video.codec === 'av1';

// A movie folder, or a season folder of a show.  Show files outside a season folder go to "<show> (other)".
function groupOf(file, root) {
  const parts = path.relative(root, file).split(path.sep);
  if (path.basename(root) !== 'tv') return parts[0];
  if (parts.length > 2 && /^(Season \d+|Specials)$/i.test(parts[1])) return `${parts[0]} ${parts[1]}`;
  return `${parts[0]} (other)`;
}

// Count the damaged files of each group: { group: { files, unreadable?, audio?, ... } }.
function summarize(entries) {
  const groups = {};
  for (const { group, rec } of entries) {
    const g = groups[group] || (groups[group] = { files: 0 });
    g.files += 1;
    for (const r of judge(rec)) g[r] = (g[r] || 0) + 1;
  }
  return groups;
}

function describe(g) {
  return Object.keys(REASONS).filter((r) => g[r]).map((r) => `${REASONS[r]} ${g[r]} of ${g.files}`).join(', ');
}

// A listed group stays listed.  It is fixed when no file in it is damaged.  A lightly combed
// group moves to the re-rip section if it gets worse, and not back.
function nextState(prev, groups) {
  const next = {};
  for (const [name, old] of Object.entries(prev)) next[name] = { ...old, fixed: true };
  for (const [name, g] of Object.entries(groups)) {
    const detail = describe(g);
    if (!detail) continue;
    const section = (g.unreadable || g.audio || g.combed || (prev[name] && prev[name].section === 'rerip')) ? 'rerip' : 'check';
    next[name] = { section, detail, fixed: false };
  }
  return next;
}

function renderBody(state) {
  const lines = [
    'The old flows made these titles.  The list job ticks a title when no file in it is damaged.',
    'Do not edit this issue.  The job writes the full body on each run.',
  ];
  for (const [key, heading] of Object.entries(SECTIONS)) {
    const names = Object.keys(state).filter((n) => state[n].section === key).sort();
    if (names.length === 0) continue;
    const fixed = names.filter((n) => state[n].fixed).length;
    lines.push('', `## ${heading} (${fixed} of ${names.length} fixed)`, '');
    for (const n of names) {
      const s = state[n];
      lines.push(s.fixed ? `- [x] ${n}` : `- [ ] ${n}: ${s.detail}`);
    }
  }
  lines.push('', `<!-- ${MARKER} ${JSON.stringify(state)} -->`);
  return `${lines.join('\n')}\n`;
}

function parseState(body) {
  const m = new RegExp(`<!-- ${MARKER} (.*) -->`).exec(body || '');
  return m ? JSON.parse(m[1]) : null;
}

function run(cmd, argv) {
  return new Promise((resolve) => {
    const child = spawn(cmd, argv, { stdio: ['ignore', 'pipe', 'pipe'] });
    let out = ''; let err = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { err += d; if (err.length > 1e6) err = err.slice(-5e5); });
    child.on('close', (code) => resolve({ code, out, err }));
  });
}

async function probe(file, st) {
  const rec = { path: file, size: st.size, mtime: st.mtimeMs };
  const p = await run(FFPROBE, ['-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', file]);
  if (p.code !== 0) return { ...rec, error: p.err.slice(-500) };
  const data = JSON.parse(p.out);
  const v = data.streams.find((s) => s.codec_type === 'video' && !(s.disposition || {}).attached_pic);
  rec.duration = Number(data.format.duration);
  rec.target = Boolean((data.format.tags || {}).TDARR_TARGET);
  rec.audio = data.streams.filter((s) => s.codec_type === 'audio').map((s) => ({ codec: s.codec_name }));
  rec.video = v ? { codec: v.codec_name } : null;
  if (!needsIdet(rec)) return rec;
  let combed = 0; let analysed = 0;
  for (const start of sampleStarts(rec.duration, IDET_FRACTIONS)) {
    const r = await run(FFMPEG, ['-hide_banner', '-nostdin', '-nostats', '-ss', String(start), '-i', file,
      '-t', String(IDET_SECS), '-map', '0:v:0', '-an', '-sn', '-dn', '-vf', 'idet', '-f', 'null', '-']);
    const i = parseIdet(r.err);
    combed += i.tff + i.bff; analysed += i.tff + i.bff + i.prog + i.und;
  }
  rec.combedShare = analysed ? combed / analysed : null;
  return rec;
}

function walk(dir, files) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name.startsWith('.') || e.name.endsWith('.part.d')) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, files);
    else if (e.isFile() && e.name.endsWith('.mkv')) files.push(p);
  }
}

// The cache holds one probe record per line, keyed by path, size and mtime.  The last line wins.
function loadCache(file) {
  const cache = new Map();
  if (!fs.existsSync(file)) return cache;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    if (!line) continue;
    try { const r = JSON.parse(line); cache.set(r.path, r); } catch { /* a cut last line */ }
  }
  return cache;
}

async function probeAll(cacheFile, roots, jobs) {
  const cache = loadCache(cacheFile);
  const entries = [];
  const todo = [];
  for (const root of roots) {
    const files = [];
    walk(root, files);
    for (const f of files) {
      const st = fs.statSync(f);
      const hit = cache.get(f);
      const entry = { group: groupOf(f, root), rec: hit };
      entries.push(entry);
      if (!hit || hit.size !== st.size || hit.mtime !== st.mtimeMs) todo.push({ entry, file: f, st });
    }
  }
  console.log(`files ${entries.length}, to probe ${todo.length}`);
  let next = 0;
  const worker = async () => {
    while (next < todo.length) {
      const { entry, file, st } = todo[next++];
      entry.rec = await probe(file, st).catch((e) => ({ path: file, size: st.size, mtime: st.mtimeMs, error: String(e).slice(0, 500) }));
      fs.appendFileSync(cacheFile, `${JSON.stringify(entry.rec)}\n`);
    }
  };
  await Promise.all(Array.from({ length: jobs }, worker));
  const tmp = `${cacheFile}.tmp`;
  fs.writeFileSync(tmp, entries.map((e) => `${JSON.stringify(e.rec)}\n`).join(''));
  fs.renameSync(tmp, cacheFile);
  return entries;
}

async function forgejo(method, route, body) {
  const token = fs.readFileSync(process.env.FORGEJO_TOKEN_FILE, 'utf8').trim();
  const res = await fetch(`${process.env.FORGEJO_URL}/api/v1/repos/${process.env.FORGEJO_REPO}${route}`, {
    method,
    headers: { Authorization: `token ${token}`, 'Content-Type': 'application/json' },
    body: body && JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`${method} ${route}: ${res.status} ${await res.text()}`);
  return res.json();
}

async function publish(groups) {
  const open = await forgejo('GET', `/issues?state=open&type=issues&labels=${LABEL}&limit=50`);
  const issue = open.filter((i) => parseState(i.body)).sort((a, b) => a.number - b.number)[0];
  const body = renderBody(nextState(issue ? parseState(issue.body) : {}, groups));
  if (issue && issue.body === body) return console.log(`issue #${issue.number} has no change`);
  if (issue) {
    await forgejo('PATCH', `/issues/${issue.number}`, { body });
    return console.log(`issue #${issue.number} updated`);
  }
  const labels = await forgejo('GET', '/labels?limit=100');
  const label = labels.find((l) => l.name === LABEL) || await forgejo('POST', '/labels', { name: LABEL, color: '#c5def5' });
  const made = await forgejo('POST', '/issues', { title: TITLE, body, labels: [label.id] });
  console.log(`issue #${made.number} created`);
}

async function main() {
  const [cacheFile, ...roots] = process.argv.slice(2);
  const entries = await probeAll(cacheFile, roots, Number(process.env.JOBS || 2));
  await publish(summarize(entries));
}

module.exports = { judge, groupOf, summarize, nextState, renderBody, parseState };
if (require.main === module) main().catch((e) => { console.error(e); process.exit(1); });
