#!/bin/sh
# Get each model shard through olah.  Check each one after the download.
# `MODELS` gives one record per model, the same format
# `generate-model-services.sh` reads: alias|base URL|shard names|port|ctx.
# This script uses the base URL and the shard names only.
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

[ -n "${MODELS:-}" ] || { echo "fetch-model.sh: MODELS has no value" >&2; exit 1; }

# The record has the same fields as `generate-model-services.sh` reads.
# shellcheck disable=SC2034
while IFS='|' read -r alias base shards port ctx; do
  [ -n "$alias" ] || continue

  for f in $shards; do
    # The URL has no directory.  The path may hold one, for a model
    # kept under its own subdirectory of /models.
    name=${f##*/}
    echo "fetching $f"

    # A new `Pod`'s egress fails for a few seconds after the pod starts.
    # The network policy has not taken effect yet.  "--retry-all-errors"
    # covers this.  "--create-dirs" makes the subdirectory; curl does not
    # make it on its own.
    curl -fsS --retry 20 --retry-all-errors --retry-delay 10 \
      --max-time 43200 --speed-limit 1024 --speed-time 300 \
      --create-dirs -C - -o "/models/$f" "$base/$name"

    want=$(curl -fsSI "$base/$name" | tr -d '\r' | tr '[:upper:]' '[:lower:]' | \
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
done <<EOF
$MODELS
EOF
