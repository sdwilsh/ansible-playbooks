# Test fixtures

Every fixture file here is real tool output that `make-fixture.js` trimmed.  Never edit a fixture file by hand.  Run the tool again instead.

## Files

- `<scenario>.source.mkvmerge.json` and `<scenario>.output.mkvmerge.json`.  `mkvmerge -J` output for a source and for the output that the flow made from it.
- `<scenario>.source.ffprobe.json` and `<scenario>.output.ffprobe.json`.  `ffprobe -show_format -show_streams` output for the same two files.
- `<scenario>.idet-mpdecimate.stderr.txt`.  The stderr of the `idetDecimateArgs` command.
- `<name>.grain-frames.json`.  The film grain side data of AV1 frames.
- `make-fixture.js`.  The tool.
- `.gitignore`.  It keeps MKV files and `.part` files out of the repo.

The tests read the scenarios from the file names in this directory.

## Add a scenario

1. Cut a 5-minute part of the source.  Keep the part outside the repo.

   ```
   mkvmerge -o part.mkv --split parts:00:20:00-00:25:00 source.mkv
   ```

2. Convert the part with the flow code in `target-convert.js`.  This gives the output MKV.
3. Run the tool from a repo checkout, with `mkvmerge` and `ffprobe` on `PATH`.  Set `MKVMERGE` and `FFPROBE` when the tools have other names.  Pass MKV paths from outside the repo.

   ```
   node fixtures/make-fixture.js <scenario> /path/to/part.mkv /path/to/output.mkv
   ```

   Or run it in the tdarr node image, with the repo mounted at `/repo` and the MKV files in `/media`.  Use the tag that `kustomization/components/tdarr/kustomization.yml` pins.

   ```
   docker run --rm -u "$(id -u):$(id -g)" --entrypoint node -v "$PWD":/repo -v /path/to/mkv/files:/media:ro \
     -w /repo/kustomization/overlays/prod/tdarr/flows/fixtures \
     ghcr.io/haveagitgat/tdarr_node:<tag> make-fixture.js <scenario> /media/part.mkv /media/output.mkv
   ```

   To trim JSON that you captured before, run `node fixtures/make-fixture.js --from-json <scenario> <source.mkvmerge.json> <source.ffprobe.json> <output.mkvmerge.json> <output.ffprobe.json>`.
4. Read the warnings and the diff.  Run `just tdarr-flows-test`.

## Other captures

- The idet and mpdecimate stderr.  Run ffmpeg with the arguments from `idetDecimateArgs(input, start, secs)` in `target-convert.js`, and save its stderr to a file.  Then run `node fixtures/make-fixture.js --idet-mpdecimate <scenario> <stderr.txt>`.  The tool keeps only the `[Parsed_idet_…]` and `[Parsed_mpdecimate_…]` lines.  The other lines hold the input path and the title.
- The AV1 film grain frames.  Run ffprobe with the arguments from `grainFramesArgs(file)` on an AV1 sample, and save its stdout to a file.  Then run `node fixtures/make-fixture.js --grain-frames <name> <frames.json>`.

## What the tool keeps and refuses

The tool keeps only the fields that `target-convert.js` reads.  It drops file names, titles, UIDs, track names, dates and the writer tags.  It keeps the value of the `TDARR_TARGET` marker tag.  It replaces the value of every other global tag with `tag-1`, `tag-2` and so on.  A value that is the same in the source and the output gets the same placeholder.  A tag such as `DISC_TAGGER_DISC` holds a public key to the title.

The tool writes nothing and exits with an error in these cases:

- The name holds anything but lower case letters, digits, dots and hyphens, or starts with a dot or a hyphen.  The name becomes a file name.
- A source or an output is longer than 600 seconds.  A full-length runtime with the track layout can identify a release.
- The trim changes what the code computes.  The tool runs `makePlan`, `buildMkvmergeArgs` and `evaluateOutput` on the raw input and on the trimmed input.  For the other captures, it compares `parseIdet`, `parseMpdecimate` or `grainStrengths` in the same way.  A difference means that the code reads a field that the tool drops.  A video track that has a name causes this: `buildMkvmergeArgs` copies that name.  Clear it first with `mkvpropedit part.mkv --edit track:v1 --delete name`.
