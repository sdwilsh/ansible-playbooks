# tdarr target flows

These files convert each MKV in the Movies and Shows libraries to one target.  The target is AV1 video with an E-AC-3 compatibility audio track as the default.  A source with TrueHD 7.1 or Atmos as its default audio keeps its video and gets only the compatibility track.

## What the flows do

- `Target: Movies` and `Target: Shows` first end at once, with no change, for a hidden file or a file in a hidden folder.  disc-tagger writes a partial file that way and then renames it into place.
- They then check the file name.  A movie name must hold a year.  A show name must hold an SxxEyy code.  A file in an extras folder, or a file whose name ends in `trailer.mkv`, also passes.  Any other file fails the flow.
- Both flows then call `Target: Convert`.  It runs `target-convert.js`, the tdarr health check, and the replace of the original file.
- `target-convert.js` stops at once when the file has the `TDARR_TARGET=1` tag.  Else it classifies the audio, scans the video for telecine and interlace, runs a film grain test, encodes, assembles the output with mkvmerge, and checks the output.  The output replaces the source only when every check passes.  The checks include each track's duration and every global tag of the source, such as `DISC_TAGGER_DISC`.

The thresholds and encoder settings are in the `config` object in `target-convert.js`.  `fixtures/` holds real tool output from seven discs, and the tests use it.  `fixtures/README.md` says how to add a scenario.

## Where the code runs

- `target-convert.js` runs inside the tdarr node pods.  A ConfigMap named `tdarr-target-code` mounts it at `/app/target`.  The name has no hash suffix, so a code change does not restart the pods.  A long encode must not stop.
- The custom function in `Target: Convert` clears the require cache and loads the file again for each job.  A code change applies to the next job.
- `sync-flows.js` runs in the `tdarr-flows-sync-job` Job.  It reads every `.json` file from the `tdarr-flows` ConfigMap.

## How a change deploys

Argo CD syncs the overlay.  After the sync, the Job waits up to five minutes for the tdarr server to answer.  It then inserts or updates each flow file through the tdarr API.  It reads each flow back and compares `flowPlugins` and `flowEdges` with the file.  The Job fails when a call fails or a flow differs.

A change made in the tdarr UI to these three flows is overwritten on the next sync.  Change the JSON files instead.

## Tests

Run `just tdarr-flows-test`.  The tests need no media file and no tool.  They use real `mkvmerge -J`, `ffprobe` and `ffmpeg` output in `fixtures/`.  CI runs the same recipe.
