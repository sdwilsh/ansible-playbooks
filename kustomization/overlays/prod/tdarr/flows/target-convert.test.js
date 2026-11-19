'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const {
  makePlan, classifyScan, decideVideo, sampleStarts, av1EncodeArgs, parseIdet, parseMpdecimate, idetDecimateArgs, grainStrengths,
  buildInputs, trackOrder, buildMkvmergeArgs, evaluateOutput, audioTracks, TREATMENTS,
} = require('./target-convert.js');

const fx = (name) => fs.readFileSync(path.join(__dirname, 'fixtures', name), 'utf8');
const fxJson = (name) => JSON.parse(fx(name));
const clone = (x) => JSON.parse(JSON.stringify(x));
const fields = (obj, keys) => Object.fromEntries(keys.map((k) => [k, obj[k]]));

const scenario = (name) => ({
  srcInfo: fxJson(`${name}.source.mkvmerge.json`),
  srcProbe: fxJson(`${name}.source.ffprobe.json`),
  outInfo: fxJson(`${name}.output.mkvmerge.json`),
  outProbe: fxJson(`${name}.output.ffprobe.json`),
});
const planOf = (t) => makePlan(t.srcInfo, t.srcProbe);
const SCENARIOS = fs.readdirSync(path.join(__dirname, 'fixtures')).filter((f) => f.endsWith('.source.mkvmerge.json')).map((f) => f.replace('.source.mkvmerge.json', ''));

const DTS_71 = scenario('bd-dts-hd-ma-7.1');
const DTS_71_PLAN = planOf(DTS_71);
const COMPAT_FIELDS = ['origin', 'name', 'channels', 'bitrate', 'lang'];

test('plan: Atmos or 7.1 TrueHD source is a remux with TrueHD first and a compat track second', () => {
  const t = scenario('uhd-truehd-atmos');
  const plan = planOf(t);
  assert.equal(plan.mode, 'remux');
  assert.deepEqual(Object.keys(plan).sort(), ['hdr10', 'mode', 'tracks']);
  const [first, second] = plan.tracks;
  assert.equal(first.origin, 'source');
  assert.equal(audioTracks(t.srcInfo).find((a) => a.tid === first.tid).codec, 'truehd');
  assert.deepEqual(fields(second, COMPAT_FIELDS), { origin: 'compat', name: 'E-AC-3 5.1', channels: 6, bitrate: '1024k', lang: 'en' });
  assert.equal(plan.tracks.length, 12);
});

test('plan: DTS-HD MA 7.1 source gets a 5.1 E-AC-3 1024k default and keeps the source second', () => {
  assert.equal(DTS_71_PLAN.mode, 'av1');
  assert.deepEqual(Object.keys(DTS_71_PLAN).sort(), ['crf', 'hdr10', 'mode', 'tracks']);
  const [compat, kept] = DTS_71_PLAN.tracks;
  assert.deepEqual(fields(compat, COMPAT_FIELDS), { origin: 'compat', name: 'E-AC-3 5.1', channels: 6, bitrate: '1024k', lang: 'en' });
  const src = audioTracks(DTS_71.srcInfo);
  assert.deepEqual(fields(src[compat.srcAudioIndex], ['codec', 'channels']), { codec: 'dts', channels: 8 });
  assert.equal(kept.origin, 'source');
  assert.equal(kept.tid, src[compat.srcAudioIndex].tid);
});

test('plan: stereo Japanese default gets a 2.0 E-AC-3 256k default', () => {
  const plan = planOf(scenario('bd-truehd-2.0-japanese'));
  assert.equal(plan.mode, 'av1');
  assert.deepEqual(fields(plan.tracks[0], COMPAT_FIELDS), { origin: 'compat', name: 'E-AC-3 2.0', channels: 2, bitrate: '256k', lang: 'ja' });
});

test('plan: a TrueHD 5.1 default is AV1 with a 5.1 E-AC-3 default, not a remux', () => {
  const t = scenario('bd-truehd-2.0-japanese');
  for (const tr of t.srcInfo.tracks) {
    if (tr.type === 'audio') tr.properties.default_track = tr.properties.audio_channels === 6;
  }
  const plan = planOf(t);
  assert.equal(plan.mode, 'av1');
  assert.deepEqual(fields(plan.tracks[0], ['origin', 'name']), { origin: 'compat', name: 'E-AC-3 5.1' });
});

test('plan: 4K HDR10 source encodes at CRF 22; 1080p at CRF 26', () => {
  const uhd = planOf(scenario('uhd-hdr10-dts'));
  assert.equal(uhd.mode, 'av1');
  assert.equal(uhd.hdr10, true);
  assert.equal(uhd.crf, 22);
  assert.equal(DTS_71_PLAN.crf, 26);
  assert.equal(DTS_71_PLAN.hdr10, false);
});

test('plan: AC-3 48 kHz default is reused and no compat track is added', () => {
  for (const name of ['dvd-soft-telecine', 'dvd-hidden-pulldown', 'dvd-interlaced']) {
    const t = scenario(name);
    const plan = planOf(t);
    const audio = audioTracks(t.srcInfo);
    assert.equal(plan.mode, 'av1', name);
    assert.equal(plan.tracks.length, audio.length, name);
    assert.ok(plan.tracks.every((tr) => tr.origin === 'source'), name);
    const first = audio.find((a) => a.tid === plan.tracks[0].tid);
    assert.deepEqual(fields(first, ['codec', 'rate']), { codec: 'ac3', rate: 48000 }, name);
  }
});

test('plan: an AC-3 default with more than 6 channels is not reused', () => {
  const t = scenario('dvd-soft-telecine');
  const wide = clone(t.srcInfo);
  wide.tracks.find((x) => x.type === 'audio').properties.audio_channels = 8;
  const plan = makePlan(wide, t.srcProbe);
  assert.equal(plan.tracks.filter((tr) => tr.origin === 'compat').length, 1);
  assert.deepEqual(fields(plan.tracks[0], ['origin', 'channels']), { origin: 'compat', channels: 6 });
});

test('plan: a source without audio or with two video tracks is refused', () => {
  const t = scenario('dvd-hidden-pulldown');
  const noAudio = clone(t.srcInfo);
  noAudio.tracks = noAudio.tracks.filter((x) => x.type !== 'audio');
  assert.throws(() => makePlan(noAudio, t.srcProbe), /no audio/);
  const twoVideo = clone(t.srcInfo);
  twoVideo.tracks.push(clone(twoVideo.tracks.find((x) => x.type === 'video')));
  assert.throws(() => makePlan(twoVideo, t.srcProbe), /expected 1 video track/);
});

const MEASURED = [
  ['dvd-soft-telecine', { repeatShare: 0.5, combedShare: 0, dupShare: 0.013, decodedFps: 24.03 }, 'soft_telecine'],
  ['dvd-interlaced', { repeatShare: 0, combedShare: 0.995, dupShare: 0.02, decodedFps: 30.03 }, 'interlaced'],
  ['dvd-hidden-pulldown', { repeatShare: 0, combedShare: 0, dupShare: 0.361, decodedFps: 30.04 }, 'telecine'],
  ['hard telecine', { repeatShare: 0, combedShare: 0.4, dupShare: 0, decodedFps: 29.97 }, 'telecine'],
  ['bd-dts-hd-ma-7.1', { repeatShare: 0, combedShare: 0, dupShare: 0.0014, decodedFps: 24.03 }, 'progressive'],
  ['29.97p with few duplicates', { repeatShare: 0, combedShare: 0, dupShare: 0.05, decodedFps: 29.97 }, 'progressive'],
];

test('classifyScan: measured scans give the measured kind', () => {
  for (const [name, scan, kind] of MEASURED) assert.equal(classifyScan(scan), kind, name);
});

test('classifyScan: 29.97p with 15% or more duplicates is treated as film, a known risk for real 29.97p stills', () => {
  assert.equal(classifyScan({ repeatShare: 0, combedShare: 0, dupShare: 0.15, decodedFps: 29.97 }), 'telecine');
  assert.equal(classifyScan({ repeatShare: 0, combedShare: 0, dupShare: 0.15, decodedFps: 25 }), 'progressive');
});

test('decideVideo: every kind classifyScan returns has a treatment, and soft telecine encodes at a 24000/1001 CFR', () => {
  for (const [name, scan] of MEASURED) assert.ok(TREATMENTS[classifyScan(scan)], name);
  const [, softTelecine] = MEASURED[0];
  const decision = decideVideo(softTelecine, 0);
  assert.equal(decision.scanType, 'soft_telecine');
  const argv = av1EncodeArgs({ preset: 2, crf: 26, grain: decision.grain, treatment: decision.treatment });
  const i = argv.indexOf('-fps_mode');
  assert.deepEqual(argv.slice(i, i + 4), ['-fps_mode', 'cfr', '-r', '24000/1001']);
});

test('decideVideo: film grain is on from the strength threshold and the decision is frozen', () => {
  const [, progressive] = MEASURED[4];
  assert.equal(decideVideo(progressive, 20).grain, true);
  assert.equal(decideVideo(progressive, 19).grain, false);
  assert.ok(Object.isFrozen(decideVideo(progressive, 0)));
});

test('av1EncodeArgs: grain parameters appear only when grain is on', () => {
  const treatment = TREATMENTS.progressive;
  const on = av1EncodeArgs({ preset: 2, crf: 26, grain: true, treatment });
  const off = av1EncodeArgs({ preset: 2, crf: 26, grain: false, treatment });
  assert.ok(on.includes('-svtav1-params'));
  assert.ok(!off.includes('-svtav1-params'));
  assert.equal(on[on.indexOf('-crf') + 1], '26');
  assert.equal(on[on.indexOf('-preset') + 1], '2');
});

test('sampleStarts: each sample starts at a whole second of its fraction of the duration', () => {
  assert.deepEqual(sampleStarts(299.7, [0.25, 0.5, 0.75]), [74, 149, 224]);
});

test('idetDecimateArgs: the scan sample asks ffmpeg for the debug log level that mpdecimate needs', () => {
  const argv = idetDecimateArgs('in.mkv', 120, 30);
  assert.equal(argv[argv.indexOf('-loglevel') + 1], 'debug');
});

test('parseIdet and parseMpdecimate: count frames and drops in real ffmpeg captures', () => {
  const interlaced = fx('dvd-interlaced.idet-mpdecimate.stderr.txt');
  const hiddenPulldown = fx('dvd-hidden-pulldown.idet-mpdecimate.stderr.txt');
  assert.deepEqual(parseIdet(interlaced), { tff: 61, bff: 0, prog: 0, und: 0 });
  assert.deepEqual(parseMpdecimate(interlaced), { frames: 61, drops: 0 });
  assert.deepEqual(parseIdet(hiddenPulldown), { tff: 0, bff: 0, prog: 59, und: 2 });
  assert.deepEqual(parseMpdecimate(hiddenPulldown), { frames: 61, drops: 24 });
});

test('parseIdet and parseMpdecimate: empty output gives zero counts', () => {
  assert.deepEqual(parseIdet(''), { tff: 0, bff: 0, prog: 0, und: 0 });
  assert.deepEqual(parseMpdecimate(''), { frames: 0, drops: 0 });
});

test('grainStrengths: real AV1 film grain frames give non-zero strengths; frames without grain give 0', () => {
  const strengths = grainStrengths(fxJson('av1-film-grain.grain-frames.json'));
  assert.equal(strengths.length, 48);
  assert.ok(strengths.every((s) => s > 0));
  assert.equal(strengths[0], 37);
  assert.deepEqual(grainStrengths({ frames: [{}, { side_data_list: [{ side_data_type: 'Other' }] }] }), [0, 0]);
});

const SRC = '/in/source.mkv';
const VIDEO = '/w/video-av1.mkv';
const COMPAT = '/w/compat-0.mka';
const label = (o) => `${o.path === SRC ? 'source' : path.basename(o.path)}/${o.tid}`;
const orderOf = (inputs) => trackOrder(inputs).map(label);
const defaultsOf = (inputs) => trackOrder(inputs).filter((o) => o.isDefault !== undefined).map((o) => `${label(o)}=${o.isDefault ? 1 : 0}`);
const inputsFor = (t, plan, videoFile) => buildInputs({
  input: SRC,
  mkvInfo: t.srcInfo,
  plan,
  videoFile,
  compatFiles: new Map(plan.tracks.filter((tr) => tr.origin === 'compat').map((tr) => [tr.srcAudioIndex, COMPAT])),
});
const range = (from, to) => Array.from({ length: to - from + 1 }, (_, i) => from + i);

test('buildInputs: a remux keeps the source video and puts TrueHD first, the compat track second, then the rest', () => {
  const t = scenario('uhd-truehd-atmos');
  const inputs = inputsFor(t, planOf(t), null);
  assert.deepEqual(inputs.map((i) => i.path), [SRC, COMPAT]);
  assert.ok(!inputs[0].options.includes('--no-video'));
  assert.deepEqual(orderOf(inputs), ['source/0', 'source/1', 'compat-0.mka/0', ...range(2, 11).map((n) => `source/${n}`), ...range(12, 35).map((n) => `source/${n}`)]);
  assert.deepEqual(defaultsOf(inputs), ['source/1=1', 'compat-0.mka/0=0', ...range(2, 11).map((n) => `source/${n}=0`)]);
  assert.deepEqual(inputs[1].options, ['--language', '0:en', '--track-name', '0:E-AC-3 5.1', '--default-track-flag', '0:0']);
});

test('buildInputs: AV1 puts the encoded video first, the compat track first among the audio, and defaults the compat track', () => {
  const inputs = inputsFor(DTS_71, DTS_71_PLAN, VIDEO);
  assert.deepEqual(inputs.map((i) => i.path), [VIDEO, SRC, COMPAT]);
  assert.ok(inputs[0].options.includes('--no-audio'));
  assert.ok(inputs[1].options.includes('--no-video'));
  assert.deepEqual(orderOf(inputs), ['video-av1.mkv/0', 'compat-0.mka/0', ...range(1, 5).map((n) => `source/${n}`), ...range(6, 10).map((n) => `source/${n}`)]);
  assert.deepEqual(defaultsOf(inputs), ['compat-0.mka/0=1', ...range(1, 5).map((n) => `source/${n}=0`)]);
  assert.deepEqual(inputs[2].options, ['--language', '0:en', '--track-name', '0:E-AC-3 5.1', '--default-track-flag', '0:1']);
});

test('buildInputs: a reused AC-3 default stays default and no compat input is added', () => {
  const t = scenario('dvd-soft-telecine');
  const inputs = inputsFor(t, planOf(t), VIDEO);
  assert.deepEqual(inputs.map((i) => i.path), [VIDEO, SRC]);
  assert.deepEqual(orderOf(inputs), ['video-av1.mkv/0', ...range(1, 8).map((n) => `source/${n}`)]);
  assert.deepEqual(defaultsOf(inputs), ['source/1=1', ...range(2, 5).map((n) => `source/${n}=0`)]);
});

test('buildMkvmergeArgs: each input file follows its own options, and the track order uses the input positions', () => {
  const sources = { input: SRC, mkvInfo: DTS_71.srcInfo, plan: DTS_71_PLAN, videoFile: VIDEO, compatFiles: new Map([[0, COMPAT]]) };
  const inputs = buildInputs(sources);
  const argv = buildMkvmergeArgs(sources, '/w/out.mkv', '/w/tags.xml');
  assert.deepEqual(argv.slice(0, 4), ['-o', '/w/out.mkv', '--global-tags', '/w/tags.xml']);
  for (const file of inputs) {
    const at = argv.indexOf(file.path);
    assert.deepEqual(argv.slice(at - file.options.length, at), file.options, file.path);
  }
  assert.ok(argv.indexOf(VIDEO) < argv.indexOf(SRC) && argv.indexOf(SRC) < argv.indexOf(COMPAT));
  assert.equal(argv[argv.indexOf('--track-order') + 1], '0:0,2:0,1:1,1:2,1:3,1:4,1:5,1:6,1:7,1:8,1:9,1:10');
});

const passing = (t) => ({ ...t, plan: planOf(t), av1Evidence: { combing: { combed: 0, analysed: 100 }, firstFrameSideData: ['Mastering display metadata'] } });
const evaluate = (t, changes = {}) => evaluateOutput({ ...passing(t), ...changes });

test('evaluateOutput: every real source and output pair passes', () => {
  assert.ok(SCENARIOS.length > 0, 'scenarios were found');
  for (const name of SCENARIOS) assert.deepEqual(evaluate(scenario(name)), [], name);
});

test('evaluateOutput: the source given as its own output fails', () => {
  const failures = evaluate(DTS_71, { outInfo: DTS_71.srcInfo, outProbe: DTS_71.srcProbe });
  assert.ok(failures.includes('audio track 1 is not AC-3 or E-AC-3 at 48 kHz with 6 channels or fewer'), failures.join('|'));
  assert.ok(failures.includes('audio count 5, expected 6'));
  assert.ok(failures.includes('video is not AV1'));
  assert.ok(failures.includes('marker tag missing'));
});

test('evaluateOutput: an unconverted remux source fails for the count and the marker', () => {
  const t = scenario('uhd-truehd-atmos');
  assert.deepEqual(evaluate(t, { outInfo: t.srcInfo, outProbe: t.srcProbe }), ['audio count 11, expected 12', 'marker tag missing']);
});

test('evaluateOutput: two default audio tracks fail', () => {
  const outInfo = clone(DTS_71.outInfo);
  outInfo.tracks.filter((x) => x.type === 'audio')[1].properties.default_track = true;
  assert.deepEqual(evaluate(DTS_71, { outInfo }), ['audio track 1 is not the only default audio track']);
});

test('evaluateOutput: a default flag on a later track instead of track 1 fails', () => {
  const outInfo = clone(DTS_71.outInfo);
  const audio = outInfo.tracks.filter((x) => x.type === 'audio');
  audio[0].properties.default_track = false;
  audio[1].properties.default_track = true;
  assert.ok(evaluate(DTS_71, { outInfo }).includes('audio track 1 is not the only default audio track'));
});

test('evaluateOutput: a changed display aspect fails', () => {
  const outProbe = clone(DTS_71.outProbe);
  outProbe.streams.find((x) => x.codec_type === 'video').display_aspect_ratio = '4:3';
  assert.deepEqual(evaluate(DTS_71, { outProbe }), ['display aspect 1.333 differs from source 1.778']);
});

test('evaluateOutput: a combed share of 0.2 fails; 0.05 and unknown behave as documented', () => {
  const withCombing = (combing) => evaluate(DTS_71, { av1Evidence: { ...passing(DTS_71).av1Evidence, combing } });
  assert.deepEqual(withCombing({ combed: 20, analysed: 100 }), ['output combed share 0.200']);
  assert.deepEqual(withCombing({ combed: 5, analysed: 100 }), []);
  assert.deepEqual(withCombing({ combed: 0, analysed: 0 }), ['output combed share unknown: no frame analysed']);
});

test('evaluateOutput: a remux needs no AV1 evidence', () => {
  assert.deepEqual(evaluate(scenario('uhd-truehd-atmos'), { av1Evidence: undefined }), []);
});

test('evaluateOutput: a missing or old marker fails', () => {
  const missing = clone(DTS_71.outProbe);
  delete missing.format.tags;
  assert.deepEqual(evaluate(DTS_71, { outProbe: missing }), ['marker tag missing']);
  const old = clone(DTS_71.outProbe);
  old.format.tags.TDARR_TARGET = '0';
  assert.deepEqual(evaluate(DTS_71, { outProbe: old }), ['marker tag missing']);
});

test('evaluateOutput: a truncated output fails on the format duration', () => {
  const outProbe = clone(DTS_71.outProbe);
  outProbe.format.duration = String(Number(outProbe.format.duration) * 0.9);
  assert.deepEqual(evaluate(DTS_71, { outProbe }), ['duration ratio 0.9000']);
});

test('evaluateOutput: HDR10 output without mastering metadata fails', () => {
  const t = scenario('uhd-hdr10-dts');
  assert.deepEqual(evaluate(t, { av1Evidence: { combing: { combed: 0, analysed: 100 }, firstFrameSideData: [] } }), ['HDR10 mastering metadata missing']);
});

test('evaluateOutput: changed subtitle flags fail', () => {
  const t = scenario('uhd-truehd-atmos');
  const outInfo = clone(t.outInfo);
  const sub = outInfo.tracks.find((x) => x.type === 'subtitles');
  sub.properties.forced_track = !sub.properties.forced_track;
  assert.deepEqual(evaluate(t, { outInfo }), ['subtitle tracks or flags changed']);
});

const hms = (seconds) => {
  const whole = Math.floor(seconds);
  const pad = (n) => String(n).padStart(2, '0');
  return `${pad(Math.floor(whole / 3600))}:${pad(Math.floor((whole % 3600) / 60))}:${pad(whole % 60)}.${String(Math.round((seconds - whole) * 1e9)).padStart(9, '0')}`;
};
const parseHms = (s) => s.split(':').reduce((acc, part) => acc * 60 + Number(part), 0);
const withStreamDuration = (probe, type, n, factor) => {
  const copy = clone(probe);
  const s = copy.streams.filter((x) => x.codec_type === type)[n];
  s.tags.DURATION = hms(parseHms(s.tags.DURATION) * factor);
  return copy;
};

test('evaluateOutput: a short AV1 track fails even when the format duration is right', () => {
  const outProbe = withStreamDuration(DTS_71.outProbe, 'video', 0, 0.8);
  assert.equal(outProbe.format.duration, DTS_71.outProbe.format.duration);
  assert.deepEqual(evaluate(DTS_71, { outProbe }), ['video duration ratio 0.8000']);
});

test('evaluateOutput: a short compat track fails', () => {
  const outProbe = withStreamDuration(DTS_71.outProbe, 'audio', 0, 0.8);
  assert.deepEqual(evaluate(DTS_71, { outProbe }), ['audio track 1 duration ratio 0.8000']);
});

test('evaluateOutput: a missing DURATION tag fails on either side', () => {
  const noOut = clone(DTS_71.outProbe);
  delete noOut.streams.find((x) => x.codec_type === 'video').tags;
  assert.deepEqual(evaluate(DTS_71, { outProbe: noOut }), ['video duration tag missing']);
  const noSrc = clone(DTS_71.srcProbe);
  delete noSrc.streams.filter((x) => x.codec_type === 'audio')[1].tags.DURATION;
  assert.deepEqual(evaluate(DTS_71, { srcProbe: noSrc }), ['audio track 3 duration tag missing']);
});

test('evaluateOutput: a source global tag such as DISC_TAGGER_DISC must be in the output', () => {
  const tag = { DISC_TAGGER_DISC: 'b3f1c0de' };
  const srcProbe = clone(DTS_71.srcProbe);
  srcProbe.format.tags = { ...srcProbe.format.tags, ...tag, encoder: 'libebml v1.4.7', creation_time: '2026-11-19T00:07:47Z' };
  const kept = clone(DTS_71.outProbe);
  kept.format.tags = { ...kept.format.tags, ...tag };
  assert.deepEqual(evaluate(DTS_71, { srcProbe, outProbe: kept }), []);
  assert.deepEqual(evaluate(DTS_71, { srcProbe }), ['global tag DISC_TAGGER_DISC not kept']);
});

test('evaluateOutput: a source made by makemkvcon, with DURATION-eng tags, passes', () => {
  const srcProbe = clone(DTS_71.srcProbe);
  for (const s of srcProbe.streams.filter((x) => x.tags && x.tags.DURATION)) {
    s.tags['DURATION-eng'] = s.tags.DURATION;
    delete s.tags.DURATION;
  }
  assert.deepEqual(evaluate(DTS_71, { srcProbe }), []);
});

test('evaluateOutput: each output audio track is compared with the source track the plan names', () => {
  const srcProbe = withStreamDuration(DTS_71.srcProbe, 'audio', 0, 0.5);
  const outProbe = withStreamDuration(withStreamDuration(DTS_71.outProbe, 'audio', 0, 0.5), 'audio', 1, 0.5);
  assert.deepEqual(evaluate(DTS_71, { srcProbe, outProbe }), []);
});
