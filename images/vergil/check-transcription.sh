#!/bin/sh
# Ask the server to transcribe the probe clip.  The `startupProbe` runs this
# script.  A transcription holds the NPU, so no other probe runs it.
#
# The server answers 200 with a body of `null` when it loads no ASR model.
# A status check does not find this state.
set -eu
[ -n "${POD_IP:-}" ] || { echo "POD_IP has no value" >&2; exit 1; }
curl -fsS --max-time 20 \
  -F file=@/opt/vergil/probe.wav -F model=whisper-v3:turbo \
  "http://$POD_IP:8080/v1/audio/transcriptions" \
  | jq -e '.text | type == "string" and length > 0' > /dev/null
