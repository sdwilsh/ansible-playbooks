#!/bin/sh
# Ask the server to read the probe image.  The `startupProbe` runs this script.
#
# `probe.png` holds the word PROBE.  A server that reads the image gives that
# word.  A server with no vision model answers 200 and holds no content, and a
# server that drives the device wrongly gives other text.  A status check finds
# neither state.
set -eu
[ -n "${POD_IP:-}" ] || { echo "POD_IP has no value" >&2; exit 1; }
jq -n --arg url "data:image/png;base64,$(base64 -w0 /opt/vergil/probe.png)" '
  {model: "qwen3vl-it:4b", max_tokens: 32, temperature: 0,
   messages: [{role: "user", content: [
     {type: "image_url", image_url: {url: $url}},
     {type: "text", text: "Read the word in this image."}]}]}' \
  | curl -fsS --max-time 20 -H 'Content-Type: application/json' --data @- \
      "http://$POD_IP:8080/v1/chat/completions" \
  | jq -e '.choices[0].message.content
           | type == "string" and (ascii_upcase | contains("PROBE"))' \
      > /dev/null
