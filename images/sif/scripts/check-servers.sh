#!/bin/sh
# Ask `/health` of each model server.  The `startupProbe` and the
# `readinessProbe` run this script.  `generate-model-services.sh` gives
# the format of a record.
set -eu

[ -n "${MODELS:-}" ] || { echo "MODELS has no value" >&2; exit 1; }
[ -n "${POD_IP:-}" ] || { echo "POD_IP has no value" >&2; exit 1; }

# The record has the same fields for each script.
# shellcheck disable=SC2034
while IFS='|' read -r alias base shards port ctx extra kind; do
  [ -n "$alias" ] || continue

  # `gufo` answers 503 while it loads a model or after it loses the device.
  # `curl -f` fails on 503.
  curl -fsS --max-time 4 -o /dev/null "http://$POD_IP:$port/health"
done <<EOF
$MODELS
EOF
