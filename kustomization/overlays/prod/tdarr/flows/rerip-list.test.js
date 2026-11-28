'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { groupOf, summarize, nextState, renderBody, parseState } = require('./rerip-list.js');

const old = (extra) => ({ video: { codec: 'av1' }, audio: [{ codec: 'eac3' }], combedShare: 0, ...extra });
const entries = (list) => list.map(([group, rec]) => ({ group, rec }));
const run = (prev, list) => nextState(prev, summarize(entries(list)));
const lines = (state) => renderBody(state).split('\n').filter((l) => l.startsWith('- ['));

test('groupOf: a movie folder, a season folder, or the other files of a show', () => {
  assert.equal(groupOf('/media/movies/A Film (2001)/extras/b.mkv', '/media/movies'), 'A Film (2001)');
  assert.equal(groupOf('/media/tv/A Show (2010)/Season 02/featurettes/c.mkv', '/media/tv'), 'A Show (2010) Season 02');
  assert.equal(groupOf('/media/tv/A Show (2010)/extras/d.mkv', '/media/tv'), 'A Show (2010) (other)');
});

test('an old file with AAC or Opus audio, combing or a probe error is listed; other files are not', () => {
  const state = run({}, [
    ['Aac', old({ audio: [{ codec: 'aac' }] })],
    ['Opus', old({ audio: [{ codec: 'opus' }, { codec: 'eac3' }] })],
    ['Combed', old({ combedShare: 0.6 })],
    ['Light', old({ combedShare: 0.05 })],
    ['Broken', { error: 'moov atom not found' }],
    ['Clean', old({ combedShare: 0.049 })],
    ['Target', old({ target: true, audio: [{ codec: 'aac' }], combedShare: 1 })],
    ['Source', { video: { codec: 'mpeg2video' }, audio: [{ codec: 'aac' }], combedShare: 1 }],
  ]);
  assert.deepEqual(Object.fromEntries(Object.entries(state).map(([n, s]) => [n, s.section])),
    { Aac: 'rerip', Opus: 'rerip', Combed: 'rerip', Light: 'check', Broken: 'rerip' });
});

test('a group shows the count of each damage; it is ticked when no file is damaged and stays listed', () => {
  const first = run({}, [
    ['A Show S1', old({ audio: [{ codec: 'aac' }], combedShare: 0.9 })],
    ['A Show S1', old({ audio: [{ codec: 'aac' }] })],
    ['A Show S1', old()],
    ['A Film', old({ audio: [{ codec: 'aac' }] })],
  ]);
  assert.deepEqual(lines(first), [
    '- [ ] A Film: damaged audio 1 of 1',
    '- [ ] A Show S1: damaged audio 2 of 3, combed video 1 of 3',
  ]);
  const second = run(parseState(renderBody(first)), [['A Show S1', old()], ['A Film', old({ audio: [{ codec: 'aac' }] })]]);
  assert.deepEqual(lines(second), ['- [ ] A Film: damaged audio 1 of 1', '- [x] A Show S1']);
  assert.match(renderBody(second), /## Re-rip \(1 of 2 fixed\)/);
  const gone = run(parseState(renderBody(second)), []);
  assert.deepEqual(lines(gone), ['- [x] A Film', '- [x] A Show S1']);
});

test('a lightly combed group that gets worse moves to the re-rip section and does not move back', () => {
  const light = run({}, [['A Film', old({ combedShare: 0.1 })]]);
  assert.equal(light['A Film'].section, 'check');
  const worse = run(light, [['A Film', old({ audio: [{ codec: 'aac' }], combedShare: 0.1 })]]);
  assert.equal(worse['A Film'].section, 'rerip');
  assert.equal(run(worse, [['A Film', old({ combedShare: 0.1 })]])['A Film'].section, 'rerip');
});

test('the body holds the state; the same input gives the same body', () => {
  const state = run({}, [['A Film', old({ combedShare: 0.2 })], ['B Film', old({ audio: [{ codec: 'aac' }] })]]);
  assert.deepEqual(parseState(renderBody(state)), state);
  assert.equal(renderBody(run(parseState(renderBody(state)), [['A Film', old({ combedShare: 0.2 })], ['B Film', old({ audio: [{ codec: 'aac' }] })]])), renderBody(state));
  assert.equal(parseState('a body by hand'), null);
});
