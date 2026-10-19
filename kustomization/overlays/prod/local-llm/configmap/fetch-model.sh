#!/bin/sh
# Get each model file through olah, and check each one after the download.
# `MODELS` holds the records that `generate-model-services.sh` reads.  This
# script uses the base URL, the shard names and the kind of each record.
#
# An `llm` token is a path under the base URL, or the full URL of a file of
# another repository.  A full URL goes to the directory of the first token.
# An `asr` record names its model directory first, then the files in it.
#
# olah does not serve the Hugging Face "refs" endpoint.  So each base URL
# names a fixed commit, and the script asks for it through "resolve".
#
# The etag from olah is the sha256 of a big file or the git hash of a small
# file.  The script checks it after every download, because a resume can
# hide a torn write.
set -eu

[ -n "${MODELS:-}" ] || { echo "fetch-model.sh: MODELS has no value" >&2; exit 1; }

# Get the file at $1 to /models/$2.  The path may hold a directory.
fetch() {
  url=$1
  f=$2
  echo "fetching $f"

  # A new `Pod`'s egress fails for a few seconds after the pod starts.
  # The network policy has not taken effect yet.  "--retry-all-errors"
  # covers this.  "--create-dirs" makes the subdirectory; curl does not
  # make it on its own.
  before=none
  [ ! -f "/models/$f" ] || before=$(wc -c < "/models/$f")
  curl -fsS --retry 20 --retry-all-errors --retry-delay 10 \
    --max-time 43200 --speed-limit 1024 --speed-time 300 \
    --create-dirs -C - -o "/models/$f" "$url"
  after=$(wc -c < "/models/$f")

  headers=$(curl -fsSI "$url" | tr -d '\r' | tr '[:upper:]' '[:lower:]')
  want=$(echo "$headers" |
    sed -n 's/^etag: *"\{0,1\}\([0-9a-f]*\)"\{0,1\}$/\1/p')
  length=$(echo "$headers" | sed -n 's/^content-length: *\([0-9]*\)$/\1/p')

  # Skip the hash only if the run downloaded nothing, the file has the size
  # that the server reports, and the sidecar holds this etag and this change
  # time.  A file that someone replaces has a new change time.
  sidecar="/models/$f.sha256-verified"
  stamp="$want $(stat -c %Y "/models/$f")"
  if [ "$before" = "$after" ] && [ "$after" = "$length" ] && [ -f "$sidecar" ] &&
    [ "$(cat "$sidecar")" = "$stamp" ]; then
    echo "$f already checked against this etag, skip the hash"
    return 0
  fi

  # A git hash has 40 digits and covers a header and the file.
  if [ "${#want}" -eq 40 ]; then
    got=$({ printf 'blob %s\0' "$(wc -c < "/models/$f")"; cat "/models/$f"; } |
      sha1sum | cut -d' ' -f1)
  else
    got=$(sha256sum "/models/$f" | cut -d' ' -f1)
  fi

  if [ "$want" != "$got" ]; then
    echo "checksum mismatch for $f: want $want got $got" >&2
    rm -f "$sidecar"
    rm -f "/models/$f"
    exit 1
  fi

  echo "$stamp" > "$sidecar"
}

# The record has the same fields as `generate-model-services.sh` reads.
# shellcheck disable=SC2034
while IFS='|' read -r alias base shards port ctx extra kind; do
  [ -n "$alias" ] || continue

  # The shard names lack glob characters.
  set -f
  # shellcheck disable=SC2086
  set -- $shards
  set +f

  if [ "$kind" = asr ]; then
    dir=$1
    shift
    for f in "$@"; do
      fetch "$base/$f" "$dir/$f"
    done
    continue
  fi

  # The model directory is the directory of the first token, if it has one.
  prefix=""
  case $1 in
    */*) prefix=${1%/*}/ ;;
  esac
  for f in "$@"; do
    case $f in
      http*) fetch "$f" "$prefix${f##*/}" ;;
      # The URL has no directory.  The path may hold one, for a model
      # kept under its own subdirectory of /models.
      *) fetch "$base/${f##*/}" "$f" ;;
    esac
  done
done <<EOF
$MODELS
EOF
