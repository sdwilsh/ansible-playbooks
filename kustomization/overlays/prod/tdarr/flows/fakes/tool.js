'use strict';

const fs = require('fs');
const path = require('path');

// The tests set these environment variables.  FAKE_SCENARIO picks the mkvmerge -J and ffprobe -show_streams fixtures.
// FAKE_INPUT is the source path.  FAKE_OUTPUT_IS_SOURCE gives the output the source data.  FAKE_LOG lists each file that a tool writes.
// FAKE_FAIL names a tool that exits 2, but mkvmerge -J does not fail.  FAKE_WARN names a tool that exits 1.
const env = process.env;
const fixture = (name) => fs.readFileSync(path.join(__dirname, '..', 'fixtures', name), 'utf8');
const role = (file) => (file === env.FAKE_INPUT || env.FAKE_OUTPUT_IS_SOURCE ? 'source' : 'output');
const writeFile = (file) => {
  fs.writeFileSync(file, '');
  fs.appendFileSync(env.FAKE_LOG, `${path.basename(file)}\n`);
};

module.exports = (tool, argv) => {
  const isIdentify = argv.includes('-J');
  if (env.FAKE_FAIL === tool && !isIdentify) {
    process.stderr.write(`${tool} failed on purpose\n`);
    process.exit(2);
  }
  const last = argv[argv.length - 1];
  if (tool === 'ffprobe' && argv.includes('-show_streams')) process.stdout.write(fixture(`${env.FAKE_SCENARIO}.${role(last)}.ffprobe.json`));
  else if (tool === 'ffprobe' && argv.includes('-export_side_data')) process.stdout.write(fixture('av1-film-grain.grain-frames.json'));
  else if (tool === 'mkvmerge' && argv[0] === '-J') process.stdout.write(fixture(`${env.FAKE_SCENARIO}.${role(last)}.mkvmerge.json`));
  else if (tool === 'mkvmerge') writeFile(argv[1]);
  else if (tool === 'ffmpeg' && argv.includes('idet')) process.stderr.write(fixture('dvd-hidden-pulldown.idet-mpdecimate.stderr.txt'));
  else if (tool === 'ffmpeg' && last !== '-') writeFile(last);
  if (env.FAKE_WARN === tool) process.exitCode = 1;
};
