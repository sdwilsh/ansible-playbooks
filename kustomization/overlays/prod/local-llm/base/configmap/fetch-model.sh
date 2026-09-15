#!/bin/sh
# Get each model shard through olah.  Check each one after the download.
#
# llama-server has its own downloader.  It cannot use olah.  It calls the
# Hugging Face "refs" endpoint to find the commit for "main".  olah does
# not serve that endpoint.  This script asks for a fixed commit instead,
# through olah's "resolve" endpoint.  olah does serve that endpoint.
#
# olah sends an etag with each file.  The etag is the sha256 of the file.
# This script checks the etag against the real hash of the download.  A
# resume can hide a torn write in the middle of a file.  A check after
# every download catches this.
set -eu

base="http://olah-svc.olah.svc.cluster.local:8090/unsloth/Qwen3-Coder-Next-GGUF/resolve/ce09c67b53bc8739eef83fe67b2f5d293c270632/Q8_0"

for f in \
  Qwen3-Coder-Next-Q8_0-00001-of-00003.gguf \
  Qwen3-Coder-Next-Q8_0-00002-of-00003.gguf \
  Qwen3-Coder-Next-Q8_0-00003-of-00003.gguf; do
  echo "fetching $f"

  # A new `Pod`'s egress fails for a few seconds after the pod starts.  The
  # network policy has not taken effect yet.  "--retry-all-errors" covers
  # this.
  curl -fsS --retry 20 --retry-all-errors --retry-delay 10 \
    --max-time 43200 --speed-limit 1024 --speed-time 300 \
    -C - -o "/models/$f" "$base/$f"

  want=$(curl -fsSI "$base/$f" | tr -d '\r' | tr '[:upper:]' '[:lower:]' | \
    sed -n 's/^etag: *"\{0,1\}\([0-9a-f]*\)"\{0,1\}$/\1/p')

  sidecar="/models/$f.sha256-verified"
  if [ -f "$sidecar" ] && [ "$(cat "$sidecar")" = "$want" ]; then
    echo "$f already checked against this etag, skip the hash"
    continue
  fi

  got=$(sha256sum "/models/$f" | cut -d' ' -f1)

  if [ "$want" != "$got" ]; then
    echo "checksum mismatch for $f: want $want got $got" >&2
    rm -f "$sidecar"
    rm -f "/models/$f"
    exit 1
  fi

  echo "$want" > "$sidecar"
done
