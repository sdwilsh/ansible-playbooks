#!/usr/bin/env node
'use strict';

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { MARKER, MKVMERGE_OK, WRITER_TAGS, DURATION_TAG, makePlan, buildMkvmergeArgs, evaluateOutput, grainStrengths, parseIdet, parseMpdecimate } = require('../target-convert.js');

const MKVMERGE_TRACK = ['id', 'type', 'properties'];
const MKVMERGE_PROPERTIES = [
  'audio_channels', 'audio_sampling_frequency', 'codec_id', 'default_track', 'forced_track', 'language', 'language_ietf',
];
const FFPROBE_STREAM = ['codec_type', 'color_transfer', 'display_aspect_ratio', 'width', 'height'];
const GRAIN_COMPONENT = ['y_points_scaling'];
const DROPPED_TAGS = ['TITLE'];
const STDERR_LINE = /^\[Parsed_(idet|mpdecimate)_\d+ @ 0x[0-9a-f]+\] /;
const MAX_SECONDS = 600;
const NAME = /^[a-z0-9][a-z0-9.-]*$/;
const ROLES = ['source', 'output'];
const TOOLS = ['mkvmerge', 'ffprobe'];

const USAGE = `usage: make-fixture.js <name> <source.mkv> <output.mkv>
       make-fixture.js --from-json <name> <source.mkvmerge.json> <source.ffprobe.json> <output.mkvmerge.json> <output.ffprobe.json>
       make-fixture.js --idet-mpdecimate <name> <stderr.txt>
       make-fixture.js --grain-frames <name> <frames.json>`;

const pick = (obj, keys) => Object.fromEntries(Object.entries(obj || {}).filter(([k]) => keys.includes(k)));
const json = (value) => `${JSON.stringify(value, null, 1)}\n`;

function placeholders() {
  const seen = new Map();
  return (value) => {
    if (!seen.has(value)) seen.set(value, `tag-${seen.size + 1}`);
    return seen.get(value);
  };
}

function trimMkvmerge(info, properties = MKVMERGE_PROPERTIES) {
  return {
    tracks: info.tracks.map((track) => ({ ...pick(track, MKVMERGE_TRACK), properties: pick(track.properties, properties) })),
  };
}

function trimFfprobe(probe, placeholder = placeholders(), warn = () => {}) {
  const tags = Object.fromEntries(Object.entries((probe.format || {}).tags || {})
    .filter(([k]) => !WRITER_TAGS.includes(k.toUpperCase()) && !DROPPED_TAGS.includes(k.toUpperCase()))
    .map(([k, v]) => {
      if (k.toUpperCase() === MARKER) return [k, v];
      warn(`global tag ${k} kept with a placeholder value`);
      return [k, placeholder(String(v))];
    }));
  const format = pick(probe.format, ['duration']);
  if (Object.keys(tags).length > 0) format.tags = tags;
  const streams = probe.streams.map((stream) => {
    const kept = pick(stream, FFPROBE_STREAM);
    if (stream.disposition && stream.disposition.attached_pic) kept.disposition = { attached_pic: stream.disposition.attached_pic };
    const durations = Object.entries(stream.tags || {}).filter(([k]) => DURATION_TAG.test(k));
    if (durations.length > 0) kept.tags = Object.fromEntries(durations);
    return kept;
  });
  return { format, streams };
}

function trimGrainFrames(probe) {
  return {
    frames: probe.frames.map((frame) => (frame.side_data_list ? {
      side_data_list: frame.side_data_list.map((data) => ({
        side_data_type: data.side_data_type,
        ...(data.components ? { components: data.components.map((c) => pick(c, GRAIN_COMPONENT)) } : {}),
      })),
    } : {})),
  };
}

const trimStderr = (text) => `${text.split('\n').filter((line) => STDERR_LINE.test(line)).join('\n')}\n`;

function targetConvertResults({ source, output }) {
  const plan = makePlan(source.mkvmerge, source.ffprobe);
  const compatFiles = new Map(plan.tracks.filter((tr) => tr.origin === 'compat').map((tr) => [tr.srcAudioIndex, `/work/compat-${tr.srcAudioIndex}.mka`]));
  const sources = { input: '/in/source.mkv', mkvInfo: source.mkvmerge, plan, videoFile: plan.mode === 'av1' ? '/work/video-av1.mkv' : null, compatFiles };
  return {
    plan,
    mkvmergeArgs: buildMkvmergeArgs(sources, '/work/out.mkv', '/work/tags.xml'),
    failures: evaluateOutput({
      srcInfo: source.mkvmerge,
      srcProbe: source.ffprobe,
      outInfo: output.mkvmerge,
      outProbe: output.ffprobe,
      plan,
      av1Evidence: { combing: { combed: 0, analysed: 100 }, firstFrameSideData: ['Mastering display metadata'] },
    }),
  };
}

function assertSame(raw, trimmed, what) {
  const differences = Object.keys(raw).filter((k) => JSON.stringify(raw[k]) !== JSON.stringify(trimmed[k]));
  if (differences.length === 0) return;
  const detail = differences.map((k) => `${k}: raw ${JSON.stringify(raw[k])}, trimmed ${JSON.stringify(trimmed[k])}`).join('\n');
  throw new Error(`the trim changes what target-convert.js computes from the ${what}.  The code reads a field that the trim drops.\n${detail}`);
}

function checkName(name) {
  if (!NAME.test(String(name))) throw new Error(`scenario name "${name}" must hold only lower case letters, digits, dots and hyphens`);
}

function checkLength(input) {
  for (const role of ROLES) {
    const { duration } = input[role].ffprobe.format || {};
    if (!(Number(duration) <= MAX_SECONDS)) {
      throw new Error(`${role} duration is ${duration} s, not within the ${MAX_SECONDS} s limit.  `
        + 'A full-length runtime with the track layout can identify a release.  Cut a 5-minute part with mkvmerge --split parts: first.');
    }
  }
}

function scenarioFiles(name, input, { warn = () => {}, mkvmergeProperties = MKVMERGE_PROPERTIES } = {}) {
  checkName(name);
  checkLength(input);
  const placeholder = placeholders();
  const trimmed = Object.fromEntries(ROLES.map((role) => [role, {
    mkvmerge: trimMkvmerge(input[role].mkvmerge, mkvmergeProperties),
    ffprobe: trimFfprobe(input[role].ffprobe, placeholder, (m) => warn(`${role}: ${m}`)),
  }]));
  assertSame(targetConvertResults(input), targetConvertResults(trimmed), 'scenario');
  return Object.fromEntries(ROLES.flatMap((role) => TOOLS.map((tool) => [`${name}.${role}.${tool}.json`, json(trimmed[role][tool])])));
}

function stderrFiles(name, text) {
  checkName(name);
  const trimmed = trimStderr(text);
  const reading = (s) => ({ idet: parseIdet(s), mpdecimate: parseMpdecimate(s) });
  assertSame(reading(text), reading(trimmed), 'stderr');
  return { [`${name}.idet-mpdecimate.stderr.txt`]: trimmed };
}

function grainFiles(name, probe) {
  checkName(name);
  const trimmed = trimGrainFrames(probe);
  assertSame({ strengths: grainStrengths(probe) }, { strengths: grainStrengths(trimmed) }, 'grain frames');
  return { [`${name}.grain-frames.json`]: json(trimmed) };
}

function writeAll(dir, files) {
  for (const [file, text] of Object.entries(files)) fs.writeFileSync(path.join(dir, file), text);
  return Object.keys(files);
}

const writeFixtures = (dir, name, input, options) => writeAll(dir, scenarioFiles(name, input, options));
const writeStderrFixture = (dir, name, text) => writeAll(dir, stderrFiles(name, text));
const writeGrainFixture = (dir, name, probe) => writeAll(dir, grainFiles(name, probe));

function runTool(cmd, args, okStatuses) {
  const result = spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 1 << 28 });
  if (result.error) throw new Error(`${cmd}: ${result.error.message}`);
  if (!okStatuses.includes(result.status)) throw new Error(`${cmd} exited ${result.status}: ${String(result.stderr).slice(-500)}`);
  return JSON.parse(result.stdout);
}

function capture(mkv) {
  const mkvmerge = process.env.MKVMERGE || 'mkvmerge';
  const ffprobe = process.env.FFPROBE || 'ffprobe';
  return {
    mkvmerge: runTool(mkvmerge, ['-J', mkv], MKVMERGE_OK),
    ffprobe: runTool(ffprobe, ['-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', mkv], [0]),
  };
}

const readJson = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));

function parse(argv) {
  const [first, ...rest] = argv;
  if (first === '--from-json' && rest.length === 5) {
    const [name, srcMkvmerge, srcFfprobe, outMkvmerge, outFfprobe] = rest;
    return { name, write: (dir, warn) => writeFixtures(dir, name, {
      source: { mkvmerge: readJson(srcMkvmerge), ffprobe: readJson(srcFfprobe) },
      output: { mkvmerge: readJson(outMkvmerge), ffprobe: readJson(outFfprobe) },
    }, { warn }) };
  }
  if (first === '--idet-mpdecimate' && rest.length === 2) return { name: rest[0], write: (dir) => writeStderrFixture(dir, rest[0], fs.readFileSync(rest[1], 'utf8')) };
  if (first === '--grain-frames' && rest.length === 2) return { name: rest[0], write: (dir) => writeGrainFixture(dir, rest[0], readJson(rest[1])) };
  if (argv.length === 3 && !first.startsWith('--')) {
    return { name: first, write: (dir, warn) => writeFixtures(dir, first, { source: capture(rest[0]), output: capture(rest[1]) }, { warn }) };
  }
  throw new Error(USAGE);
}

function main(argv, dir = __dirname) {
  const { name, write } = parse(argv);
  checkName(name);
  for (const file of write(dir, (m) => console.error(`warning: ${m}`))) console.log(`wrote ${file}`);
}

if (require.main === module) {
  try {
    main(process.argv.slice(2));
  } catch (e) {
    console.error(`make-fixture: ${e.message}`);
    process.exit(1);
  }
}

module.exports = {
  MKVMERGE_PROPERTIES, STDERR_LINE, MAX_SECONDS, trimMkvmerge, trimFfprobe, trimGrainFrames, trimStderr, writeFixtures, writeStderrFixture, writeGrainFixture, main,
};
