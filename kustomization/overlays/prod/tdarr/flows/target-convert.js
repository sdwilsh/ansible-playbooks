'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

// Output handles of the custom function node in target-convert.json.
const OUTPUT_CONVERTED = 1;
const OUTPUT_AT_TARGET = 2;

const config = {
  marker: 'TDARR_TARGET',
  markerVersion: '1',
  remuxMinTruehdChannels: 8,
  preset: 2,
  crfUpTo1080: 26,
  crfAbove1080: 22,
  pixFmt: 'yuv420p10le',
  displayAspectTolerance: 0.01,
  grain: {
    threshold: 20,
    sampleFractions: [0.2, 0.4, 0.6, 0.8],
    sampleSeconds: 10,
    samplePreset: 8,
    params: 'film-grain=8:film-grain-denoise=1',
  },
  compat: {
    codecs: ['ac3', 'eac3'],
    encodeCodec: 'eac3',
    rate: 48000,
    maxChannels: 6,
    bitrateMultichannel: '1024k',
    bitrateStereo: '256k',
  },
  durationTolerance: 0.01,
  scan: {
    sampleFractions: [0.25, 0.5, 0.75],
    sampleSeconds: 30,
    softTelecineMinRepeatShare: 0.3,
    mixedMinRepeatShare: 0.05,
    interlacedMinCombedShare: 0.6,
    telecineMinCombedShare: 0.1,
    pulldownMinDupShare: 0.15,
    outputMaxCombedShare: 0.05,
  },
  check: { sampleFractions: [0.3, 0.7], sampleSeconds: 20 },
};

const KEEP_TIMESTAMPS = ['-fps_mode', 'passthrough'];
// Decoded soft-telecine frames keep the 3:2 field timing.  Put them on an even 23.976 grid.
const RETIME_TO_FILM_RATE = ['-fps_mode', 'cfr', '-r', '24000/1001'];
const TREATMENTS = {
  progressive: { filter: null, timing: KEEP_TIMESTAMPS },
  soft_telecine: { filter: null, timing: RETIME_TO_FILM_RATE },
  telecine: { filter: 'fieldmatch=order=auto:combmatch=full,yadif=deint=interlaced,decimate', timing: KEEP_TIMESTAMPS },
  interlaced: { filter: 'bwdif=mode=send_field:parity=auto:deint=all', timing: KEEP_TIMESTAMPS },
};
// Decimate also drops frames from the soft-telecine parts and makes the video short.  Deinterlace drops no frames.
TREATMENTS.mixed = TREATMENTS.interlaced;

// A plan is { mode: 'remux', tracks, hdr10 } or { mode: 'av1', tracks, hdr10, crf }.
// The first audio track is the default.  A track is { origin: 'source', tid, srcAudioIndex }
// or { origin: 'compat', srcAudioIndex, channels, bitrate, lang, name }.

function run(cmd, argv, { log, onStdout, okCodes = [0] } = {}) {
  return new Promise((resolve, reject) => {
    if (log) log(`${cmd} ${argv.map((a) => (/\s/.test(a) ? JSON.stringify(a) : a)).join(' ')}`);
    const child = spawn(cmd, argv, { stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    let err = '';
    child.stdout.on('data', (d) => { out += d; if (onStdout) onStdout(String(d)); });
    child.stderr.on('data', (d) => { err += d; });
    child.on('error', reject);
    child.on('close', (code) => {
      if (okCodes.includes(code)) resolve({ out, err });
      else reject(new Error(`${path.basename(cmd)} exited ${code}: ${err.slice(-2000)}`));
    });
  });
}

const tools = (args) => {
  const ffmpeg = args.ffmpegPath;
  const bin = path.dirname(args.mkvpropeditPath);
  return {
    ffmpeg,
    ffprobe: path.join(path.dirname(ffmpeg), path.basename(ffmpeg).replace(/ffmpeg$/, 'ffprobe')),
    mkvmerge: path.join(bin, 'mkvmerge'),
  };
};

async function ffprobe(t, file) {
  const { out } = await run(t.ffprobe, ['-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', file]);
  return JSON.parse(out);
}

// mkvmerge exits 1 for warnings only.
const MKVMERGE_OK = [0, 1];

async function identify(t, file) {
  const { out } = await run(t.mkvmerge, ['-J', file], { okCodes: MKVMERGE_OK });
  return JSON.parse(out);
}

const CODEC = { A_TRUEHD: 'truehd', A_AC3: 'ac3', A_EAC3: 'eac3', A_DTS: 'dts', A_FLAC: 'flac', A_OPUS: 'opus' };

function audioTracks(mkvInfo) {
  return mkvInfo.tracks.filter((t) => t.type === 'audio').map((t, audioIndex) => ({
    tid: t.id,
    audioIndex,
    codec: CODEC[t.properties.codec_id] || t.properties.codec_id,
    channels: t.properties.audio_channels,
    rate: t.properties.audio_sampling_frequency,
    lang: t.properties.language_ietf || t.properties.language || 'und',
    isDefault: Boolean(t.properties.default_track),
  }));
}

// Muxers rewrite these two global tags.
const WRITER_TAGS = ['ENCODER', 'CREATION_TIME'];

function globalTagFailures(srcProbe, outProbe) {
  const upper = (tags) => Object.fromEntries(Object.entries(tags || {}).map(([k, v]) => [k.toUpperCase(), String(v)]));
  const [src, out] = [upper(srcProbe.format.tags), upper(outProbe.format.tags)];
  return Object.entries(src).filter(([k, v]) => !WRITER_TAGS.includes(k) && out[k] !== v).map(([k]) => `global tag ${k} not kept`);
}

const markerValue = (probe) => {
  const entry = Object.entries(probe.format.tags || {}).find(([k]) => k.toUpperCase() === config.marker);
  return entry ? String(entry[1]) : null;
};

// The old flows made the AV1 files in the libraries.  A second encode loses quality.
function skipReason(mkvInfo, probe) {
  if (markerValue(probe) === config.markerVersion) return `already at target version ${config.markerVersion}`;
  if (mkvInfo.tracks.some((t) => t.type === 'video' && t.properties.codec_id === 'V_AV1')) return 'video is AV1 already';
  return null;
}

const isCompatReady = (a) => config.compat.codecs.includes(a.codec) && a.rate === config.compat.rate && a.channels <= config.compat.maxChannels;

const sourceDefault = (audio) => audio.find((a) => a.isDefault) || audio[0];

const sourceTrack = (a) => ({ origin: 'source', tid: a.tid, srcAudioIndex: a.audioIndex });

function compatFrom(a) {
  const channels = Math.min(a.channels, config.compat.maxChannels);
  const layout = channels === 6 ? '5.1' : channels === 2 ? '2.0' : `${channels}.0`;
  return {
    origin: 'compat',
    srcAudioIndex: a.audioIndex,
    channels,
    bitrate: channels > 2 ? config.compat.bitrateMultichannel : config.compat.bitrateStereo,
    lang: a.lang,
    name: `E-AC-3 ${layout}`,
  };
}

function makePlan(mkvInfo, probe) {
  const audio = audioTracks(mkvInfo);
  if (audio.length === 0) throw new Error('source has no audio track');
  const video = mkvInfo.tracks.filter((t) => t.type === 'video');
  if (video.length !== 1) throw new Error(`expected 1 video track, found ${video.length}`);
  const vstream = probe.streams.find((s) => s.codec_type === 'video' && !(s.disposition && s.disposition.attached_pic));
  const def = sourceDefault(audio);
  const others = audio.filter((a) => a !== def).map(sourceTrack);
  const hdr10 = vstream.color_transfer === 'smpte2084';
  if (def.codec === 'truehd' && def.channels >= config.remuxMinTruehdChannels) {
    return { mode: 'remux', tracks: [sourceTrack(def), compatFrom(def), ...others], hdr10 };
  }
  const tracks = isCompatReady(def) ? [sourceTrack(def), ...others] : [compatFrom(def), sourceTrack(def), ...others];
  return { mode: 'av1', tracks, hdr10, crf: (vstream.height || 0) > 1080 ? config.crfAbove1080 : config.crfUpTo1080 };
}

function grainStrengths(probeJson) {
  return probeJson.frames.map((f) => {
    const g = (f.side_data_list || []).find((x) => x.side_data_type === 'Film grain parameters');
    let s = 0;
    for (const c of (g && g.components) || []) {
      for (const p of String(c.y_points_scaling || '').split(/\s+/).filter(Boolean)) s = Math.max(s, Number(p));
    }
    return s;
  });
}

const median = (xs) => { const s = [...xs].sort((a, b) => a - b); return s[Math.floor(s.length / 2)]; };

// Film frames repeated whole to 29.97 fps.  Real 29.97p footage with many still frames also matches.
const isHiddenPulldown = (scan) =>
  Math.abs(scan.decodedFps - 30000 / 1001) < 0.5 && scan.dupShare >= config.scan.pulldownMinDupShare;

function classifyScan(scan) {
  const c = config.scan;
  if (scan.repeatShare >= c.softTelecineMinRepeatShare) return 'soft_telecine';
  if (scan.repeatShare >= c.mixedMinRepeatShare) return 'mixed';
  if (scan.combedShare >= c.interlacedMinCombedShare) return 'interlaced';
  if (scan.combedShare >= c.telecineMinCombedShare) return 'telecine';
  if (isHiddenPulldown(scan)) return 'telecine';
  return 'progressive';
}

function decideVideo(scan, grainStrength) {
  const scanType = classifyScan(scan);
  return Object.freeze({ scanType, treatment: TREATMENTS[scanType], grain: grainStrength >= config.grain.threshold });
}

const sampleStarts = (duration, fractions) => fractions.map((f) => Math.floor(duration * f));
// A sample that starts near the end is shorter than secs.
const sampledSeconds = (duration, starts, secs) => starts.reduce((sum, start) => sum + Math.min(secs, duration - start), 0);

const videoArgs = (treatment) => [...treatment.timing, ...(treatment.filter ? ['-vf', treatment.filter] : [])];

function av1EncodeArgs({ preset, crf, grain, treatment }) {
  return [...videoArgs(treatment), '-c:v', 'libsvtav1', '-preset', String(preset), '-crf', String(crf),
    ...(grain ? ['-svtav1-params', config.grain.params] : []), '-pix_fmt', config.pixFmt];
}

// ffmpeg logs the mpdecimate drop and keep decisions only at the debug log level.  parseMpdecimate needs them.
function idetDecimateArgs(input, start, secs) {
  return ['-hide_banner', '-nostats', '-loglevel', 'debug', '-ss', String(start), '-i', input,
    '-t', String(secs), '-map', '0:v:0', '-an', '-sn', '-dn', '-vf', 'idet,mpdecimate=max=1', '-f', 'null', '-'];
}

function parseIdet(stderr) {
  const m = /Multi frame detection:\s*TFF:\s*(\d+)\s*BFF:\s*(\d+)\s*Progressive:\s*(\d+)\s*Undetermined:\s*(\d+)/.exec(
    stderr.split('\n').filter((l) => l.includes('Multi frame detection')).pop() || '');
  const [tff, bff, prog, und] = m ? m.slice(1).map(Number) : [0, 0, 0, 0];
  return { tff, bff, prog, und };
}

function parseMpdecimate(stderr) {
  const decisions = stderr.split('\n').filter((l) => /Parsed_mpdecimate/.test(l) && / (drop|keep) /.test(l));
  return { frames: decisions.length, drops: decisions.filter((l) => / drop /.test(l)).length };
}

function grainFramesArgs(file) {
  return ['-v', 'error', '-export_side_data', 'film_grain', '-select_streams', 'v',
    '-show_frames', '-show_entries', 'frame=side_data_list', '-of', 'json', file];
}

async function measureGrain(job, crf, treatment) {
  const { t, input, dir, duration } = job;
  const all = [];
  for (const [i, start] of sampleStarts(duration, config.grain.sampleFractions).entries()) {
    const out = path.join(dir, `grain-sample-${i}.mkv`);
    await run(t.ffmpeg, ['-hide_banner', '-v', 'error', '-y', '-ss', String(start), '-i', input,
      '-t', String(config.grain.sampleSeconds), '-map', '0:v:0', '-an', '-sn', '-dn',
      ...av1EncodeArgs({ preset: config.grain.samplePreset, crf, grain: true, treatment }), out], { log: job.log });
    const { out: frames } = await run(t.ffprobe, grainFramesArgs(out));
    all.push(...grainStrengths(JSON.parse(frames)));
    fs.rmSync(out, { force: true });
  }
  if (all.length === 0) throw new Error('grain test decoded no frames');
  return median(all);
}

async function scanVideo(job) {
  const { t, input, duration } = job;
  let frames = 0; let repeats = 0; let combed = 0; let analysed = 0; let drops = 0; let decoded = 0;
  const secs = config.scan.sampleSeconds;
  const starts = sampleStarts(duration, config.scan.sampleFractions);
  for (const start of starts) {
    const { out: flags } = await run(t.ffprobe, ['-v', 'error', '-read_intervals', `${start}%+${secs}`, '-select_streams', 'v:0',
      '-show_entries', 'frame=repeat_pict', '-of', 'csv=p=0', input]);
    for (const line of flags.split('\n').filter(Boolean)) { frames += 1; if (Number(line.split(',')[0]) > 0) repeats += 1; }
    const { err } = await run(t.ffmpeg, idetDecimateArgs(input, start, secs));
    const idet = parseIdet(err);
    const decimate = parseMpdecimate(err);
    combed += idet.tff + idet.bff;
    analysed += idet.tff + idet.bff + idet.prog + idet.und;
    drops += decimate.drops;
    decoded += decimate.frames;
  }
  return {
    repeatShare: frames ? repeats / frames : 0,
    combedShare: analysed ? combed / analysed : 0,
    dupShare: decoded ? drops / decoded : 0,
    decodedFps: decoded / sampledSeconds(duration, starts, secs),
  };
}

const clockText = (secs) => {
  const s = Math.max(0, Math.round(secs));
  const two = (n) => String(n).padStart(2, '0');
  return `${Math.floor(s / 3600)}:${two(Math.floor((s % 3600) / 60))}:${two(s % 60)}`;
};

// Make a tdarr worker update from one ffmpeg -progress chunk.  tdarr shows ETA only when the plugin sends it.
function progressUpdate(chunk, duration, elapsedSecs) {
  const time = /out_time_us=(\d+)/.exec(chunk);
  if (!time || !(duration > 0)) return null;
  const percentage = Math.min(99, (Number(time[1]) / 1e6 / duration) * 100);
  const update = { percentage };
  if (percentage > 0) update.ETA = clockText((elapsedSecs * (100 - percentage)) / percentage);
  // tdarr shows the estimated size against the source size.  The estimate is the video only.
  const size = /total_size=(\d+)/.exec(chunk);
  if (size && percentage > 0) {
    update.outputFileSizeInGbytes = Number(size[1]) / 1024 ** 3;
    update.estSize = (update.outputFileSizeInGbytes * 100) / percentage;
  }
  const fps = /fps=([\d.]+)/.exec(chunk);
  if (fps && Number(fps[1]) > 0) update.fps = Number(fps[1]);
  return update;
}

async function encodeVideo(job, plan, decision, progress) {
  const { t, input, dir, duration } = job;
  const out = path.join(dir, 'video-av1.mkv');
  const start = Date.now();
  await run(t.ffmpeg, ['-hide_banner', '-v', 'error', '-y', '-i', input, '-map', '0:v:0', '-an', '-sn', '-dn', '-map_chapters', '-1',
    ...av1EncodeArgs({ preset: config.preset, crf: plan.crf, grain: decision.grain, treatment: decision.treatment }),
    '-progress', 'pipe:1', '-nostats', out], {
    log: job.log,
    onStdout: (chunk) => {
      const update = progressUpdate(chunk, duration, (Date.now() - start) / 1000);
      if (update) progress(update);
    },
  });
  return out;
}

async function encodeCompat(job, track) {
  const out = path.join(job.dir, `compat-${track.srcAudioIndex}.mka`);
  await run(job.t.ffmpeg, ['-hide_banner', '-v', 'error', '-y', '-i', job.input, '-map', `0:a:${track.srcAudioIndex}`,
    '-c:a', config.compat.encodeCodec, '-b:a', track.bitrate, '-ac', String(track.channels), '-ar', String(config.compat.rate), out], { log: job.log });
  return out;
}

// One entry per mkvmerge input file, in argv order: the encoded video (AV1 only), the source, then each compat file.
// A track is { tid, position, isDefault }.  `position` is the slot of the track in the output.
function buildInputs({ input, mkvInfo, plan, videoFile, compatFiles }) {
  const video = mkvInfo.tracks.find((x) => x.type === 'video');
  const subs = mkvInfo.tracks.filter((x) => x.type === 'subtitles');
  const slots = [
    videoFile ? { path: videoFile, tid: 0 } : { path: input, tid: video.id },
    ...plan.tracks.map((tr, i) => (tr.origin === 'source'
      ? { path: input, tid: tr.tid, isDefault: i === 0 }
      : { path: compatFiles.get(tr.srcAudioIndex), tid: 0, isDefault: i === 0 })),
    ...subs.map((s) => ({ path: input, tid: s.id })),
  ].map((slot, position) => ({ ...slot, position }));
  const tracksOf = (file) => slots.filter((s) => s.path === file).map(({ tid, position, isDefault }) => ({ tid, position, isDefault }));
  const defaultFlag = (tid, isDefault) => ['--default-track-flag', `${tid}:${isDefault ? 1 : 0}`];
  const language = (p) => `0:${p.language_ietf || p.language || 'und'}`;

  const encodedVideo = videoFile && {
    path: videoFile,
    options: ['--no-audio', '--no-subtitles', '--no-chapters', '--no-attachments', '--no-global-tags',
      '--language', language(video.properties), ...(video.properties.track_name ? ['--track-name', `0:${video.properties.track_name}`] : [])],
    tracks: tracksOf(videoFile),
  };
  const source = {
    path: input,
    options: [...(videoFile ? ['--no-video'] : []),
      ...tracksOf(input).filter((s) => s.isDefault !== undefined).flatMap((s) => defaultFlag(s.tid, s.isDefault))],
    tracks: tracksOf(input),
  };
  const compat = plan.tracks.filter((tr) => tr.origin === 'compat').map((tr) => {
    const file = compatFiles.get(tr.srcAudioIndex);
    const tracks = tracksOf(file);
    return { path: file, options: ['--language', `0:${tr.lang}`, '--track-name', `0:${tr.name}`, ...defaultFlag(0, tracks[0].isDefault)], tracks };
  });
  return [...(encodedVideo ? [encodedVideo] : []), source, ...compat];
}

// The output tracks in order, each with its input file id and its track id in that file.
const trackOrder = (inputs) => inputs
  .flatMap((file, id) => file.tracks.map((tr) => ({ id, path: file.path, ...tr })))
  .sort((a, b) => a.position - b.position);

function buildMkvmergeArgs(sources, out, tagsPath) {
  const inputs = buildInputs(sources);
  return ['-o', out, '--global-tags', tagsPath, ...inputs.flatMap((file) => [...file.options, file.path]),
    '--track-order', trackOrder(inputs).map((tr) => `${tr.id}:${tr.tid}`).join(',')];
}

async function assemble(job, sources, out) {
  const tags = path.join(job.dir, 'target-tags.xml');
  fs.writeFileSync(tags, `<?xml version="1.0"?>\n<Tags><Tag><Targets/><Simple><Name>${config.marker}</Name><String>${config.markerVersion}</String></Simple></Tag></Tags>\n`);
  await run(job.t.mkvmerge, buildMkvmergeArgs(sources, out, tags), { log: job.log, okCodes: MKVMERGE_OK });
}

// mkvmerge writes a DURATION tag, HH:MM:SS.nnnnnnnnn, on each track.  makemkvcon writes DURATION-<language>.
const DURATION_TAG = /^DURATION(-[A-Z]+)?$/i;

function streamDuration(stream) {
  const entry = Object.entries((stream && stream.tags) || {}).find(([k]) => DURATION_TAG.test(k));
  const m = /^(\d+):(\d{2}):(\d{2}(?:\.\d+)?)$/.exec(entry ? String(entry[1]) : '');
  return m ? Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3]) : NaN;
}

const probeVideo = (probe) => probe.streams.find((x) => x.codec_type === 'video' && !(x.disposition && x.disposition.attached_pic));
const probeAudio = (probe) => probe.streams.filter((x) => x.codec_type === 'audio');

// mkvmerge takes the segment duration from the longest track.  Compare each track with the source track it comes from.
function trackDurationFailures({ srcProbe, outProbe, plan }) {
  const srcAudio = probeAudio(srcProbe);
  const outAudio = probeAudio(outProbe);
  const pairs = [['video', probeVideo(srcProbe), probeVideo(outProbe)]];
  if (outAudio.length === plan.tracks.length) {
    plan.tracks.forEach((tr, i) => pairs.push([`audio track ${i + 1}`, srcAudio[tr.srcAudioIndex], outAudio[i]]));
  }
  return pairs.flatMap(([name, src, out]) => {
    const [s, o] = [streamDuration(src), streamDuration(out)];
    if (Number.isNaN(s) || Number.isNaN(o)) return [`${name} duration tag missing`];
    const ratio = o / s;
    return Math.abs(1 - ratio) <= config.durationTolerance ? [] : [`${name} duration ratio ${ratio.toFixed(4)}`];
  });
}

const MODE_EXPECTS = {
  remux: {
    firstAudio: (a) => a.codec === 'truehd',
    firstAudioFailure: 'remux audio track 1 is not TrueHD',
    video: (out, src) => out.properties.codec_id === src.properties.codec_id,
    videoFailure: 'remux video codec changed',
  },
  av1: {
    firstAudio: isCompatReady,
    firstAudioFailure: 'audio track 1 is not AC-3 or E-AC-3 at 48 kHz with 6 channels or fewer',
    video: (out) => out.properties.codec_id === 'V_AV1',
    videoFailure: 'video is not AV1',
  },
};

function commonChecks({ srcInfo, srcProbe, outInfo, outProbe, plan }) {
  const failures = [];
  const expects = MODE_EXPECTS[plan.mode];
  const outAudio = audioTracks(outInfo);
  const first = outAudio[0];
  if (outAudio.filter((a) => a.isDefault).length !== 1 || !first || !first.isDefault) failures.push('audio track 1 is not the only default audio track');
  if (!(first && expects.firstAudio(first))) failures.push(expects.firstAudioFailure);
  if (outAudio.length !== plan.tracks.length) failures.push(`audio count ${outAudio.length}, expected ${plan.tracks.length}`);
  const vOut = outInfo.tracks.filter((x) => x.type === 'video');
  const vSrc = srcInfo.tracks.filter((x) => x.type === 'video');
  if (vOut.length !== 1) failures.push(`video count ${vOut.length}`);
  else if (!expects.video(vOut[0], vSrc[0])) failures.push(expects.videoFailure);
  const subFlags = (mkvInfo) => mkvInfo.tracks.filter((x) => x.type === 'subtitles')
    .map((x) => `${x.properties.language}:${x.properties.default_track ? 1 : 0}${x.properties.forced_track ? 1 : 0}`).join(',');
  if (subFlags(outInfo) !== subFlags(srcInfo)) failures.push('subtitle tracks or flags changed');
  const ratio = Number(outProbe.format.duration) / Number(srcProbe.format.duration);
  if (!(Math.abs(1 - ratio) <= config.durationTolerance)) failures.push(`duration ratio ${ratio.toFixed(4)}`);
  failures.push(...trackDurationFailures({ srcProbe, outProbe, plan }));
  if (markerValue(outProbe) !== config.markerVersion) failures.push('marker tag missing');
  failures.push(...globalTagFailures(srcProbe, outProbe));
  const dar = (probe) => {
    const v = probeVideo(probe);
    const [w, h] = String(v.display_aspect_ratio || '').split(':').map(Number);
    return w && h ? w / h : v.width / v.height;
  };
  if (Math.abs(dar(outProbe) / dar(srcProbe) - 1) > config.displayAspectTolerance) failures.push(`display aspect ${dar(outProbe).toFixed(3)} differs from source ${dar(srcProbe).toFixed(3)}`);
  return failures;
}

function av1Checks(plan, { combing, firstFrameSideData }) {
  const failures = [];
  if (combing.analysed === 0) failures.push('output combed share unknown: no frame analysed');
  else if (combing.combed / combing.analysed > config.scan.outputMaxCombedShare) failures.push(`output combed share ${(combing.combed / combing.analysed).toFixed(3)}`);
  if (plan.hdr10 && !firstFrameSideData.includes('Mastering display metadata')) failures.push('HDR10 mastering metadata missing');
  return failures;
}

// `av1Evidence` is { combing, firstFrameSideData }.  A remux needs none.
function evaluateOutput({ srcInfo, srcProbe, outInfo, outProbe, plan, av1Evidence }) {
  const failures = commonChecks({ srcInfo, srcProbe, outInfo, outProbe, plan });
  if (plan.mode === 'av1') failures.push(...av1Checks(plan, av1Evidence));
  return failures;
}

async function gatherAv1Evidence(t, out, outProbe, plan) {
  const combing = { combed: 0, analysed: 0 };
  const { sampleFractions, sampleSeconds } = config.check;
  for (const start of sampleStarts(Number(outProbe.format.duration), sampleFractions)) {
    const { err } = await run(t.ffmpeg, ['-hide_banner', '-nostats', '-ss', String(start), '-i', out,
      '-t', String(sampleSeconds), '-map', '0:v:0', '-vf', 'idet', '-f', 'null', '-']);
    const r = parseIdet(err);
    combing.combed += r.tff + r.bff;
    combing.analysed += r.tff + r.bff + r.prog + r.und;
  }
  let firstFrameSideData = [];
  if (plan.hdr10) {
    const { out: frames } = await run(t.ffprobe, ['-v', 'error', '-select_streams', 'v:0', '-read_intervals', '%+#1',
      '-show_frames', '-show_entries', 'frame=side_data_list', '-of', 'json', out]);
    firstFrameSideData = ((JSON.parse(frames).frames[0] || {}).side_data_list || []).map((x) => x.side_data_type);
  }
  return { combing, firstFrameSideData };
}

async function check(t, srcInfo, srcProbe, out, plan) {
  const outInfo = await identify(t, out);
  const outProbe = await ffprobe(t, out);
  const av1Evidence = plan.mode === 'av1' ? await gatherAv1Evidence(t, out, outProbe, plan) : undefined;
  return evaluateOutput({ srcInfo, srcProbe, outInfo, outProbe, plan, av1Evidence });
}

// Keep only `keep` in `dir`.  A null `keep` removes the directory.
function cleanWorkDir(dir, keep) {
  if (!keep) { fs.rmSync(dir, { recursive: true, force: true }); return; }
  for (const name of fs.readdirSync(dir)) {
    if (path.join(dir, name) !== keep) fs.rmSync(path.join(dir, name), { recursive: true, force: true });
  }
}

async function convert(args) {
  const log = (m) => args.jobLog(`[target] ${m}`);
  const t = tools(args);
  const input = args.inputFileObj._id;
  if (path.extname(input).toLowerCase() !== '.mkv') throw new Error(`not an MKV file: ${input}`);
  const srcProbe = await ffprobe(t, input);
  const srcInfo = await identify(t, input);
  const skip = skipReason(srcInfo, srcProbe);
  if (skip) {
    log(`not converted: ${skip}`);
    return { outputFileObj: args.inputFileObj, outputNumber: OUTPUT_AT_TARGET, variables: args.variables };
  }
  const plan = makePlan(srcInfo, srcProbe);
  const dir = path.join(args.workDir, `target-${Date.now()}`);
  const job = { t, input, dir, log, duration: Number(srcProbe.format.duration) };
  const out = path.join(dir, path.basename(input));
  fs.mkdirSync(dir, { recursive: true });
  let kept = null;
  try {
    log(`plan ${JSON.stringify(plan)}`);
    let videoFile = null;
    if (plan.mode === 'av1') {
      const scan = await scanVideo(job);
      log(`scan ${JSON.stringify(scan)}`);
      const strength = await measureGrain(job, plan.crf, TREATMENTS[classifyScan(scan)]);
      const decision = decideVideo(scan, strength);
      log(`video decision ${JSON.stringify(decision)}, grain strength median ${strength}, threshold ${config.grain.threshold}`);
      videoFile = await encodeVideo(job, plan, decision, (update) => args.updateWorker(update));
    }
    const compatFiles = new Map();
    for (const tr of plan.tracks.filter((x) => x.origin === 'compat')) compatFiles.set(tr.srcAudioIndex, await encodeCompat(job, tr));
    await assemble(job, { input, mkvInfo: srcInfo, plan, videoFile, compatFiles }, out);
    const failures = await check(t, srcInfo, srcProbe, out, plan);
    if (failures.length > 0) throw new Error(`target checks failed: ${failures.join('; ')}`);
    log('checks passed');
    kept = out;
  } finally {
    cleanWorkDir(dir, kept);
  }
  return { outputFileObj: { _id: out }, outputNumber: OUTPUT_CONVERTED, variables: args.variables };
}

module.exports = convert;
Object.assign(module.exports, {
  OUTPUT_CONVERTED, OUTPUT_AT_TARGET, MKVMERGE_OK, MARKER: config.marker, WRITER_TAGS, DURATION_TAG, TREATMENTS, makePlan, skipReason, audioTracks, grainStrengths, classifyScan, decideVideo, sampleStarts, sampledSeconds, progressUpdate,
  av1EncodeArgs, idetDecimateArgs, grainFramesArgs, parseIdet, parseMpdecimate, buildInputs, trackOrder, buildMkvmergeArgs, evaluateOutput,
});
