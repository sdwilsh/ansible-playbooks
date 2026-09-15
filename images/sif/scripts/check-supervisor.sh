#!/bin/sh
# Check that s6 supervises each model server.  The `livenessProbe` runs
# this script.  A server that is down must not restart the container, so
# this script reads the status of `s6-svstat` and not the value of `up`.
# `generate-model-services.sh` gives the format of a record.
set -eu

[ -n "${MODELS:-}" ] || { echo "MODELS has no value" >&2; exit 1; }

# The record has the same fields for each script.
# shellcheck disable=SC2034
while IFS='|' read -r alias base shards port ctx; do
  [ -n "$alias" ] || continue

  /command/s6-svstat -o up "/run/service/$alias" > /dev/null
done <<EOF
$MODELS
EOF
