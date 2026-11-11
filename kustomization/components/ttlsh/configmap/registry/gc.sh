#!/usr/bin/env sh
set -eux
while true; do
  # The registry still serves during a run, so a run can delete a layer
  # that a push has not yet linked.  Run less often to make that rare.
  sleep 1h
  if [ ! -d "/var/lib/registry/docker" ]; then
    echo "No registry data found, skipping garbage collection"
  else
    echo "Starting garbage collection..."
    registry garbage-collect /etc/docker/registry/config.yml || true
  fi
done