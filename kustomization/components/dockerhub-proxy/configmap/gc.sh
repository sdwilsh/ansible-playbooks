#!/usr/bin/env sh
set -eux
while true; do
  sleep 1m
  if [ ! -d "/var/lib/registry/docker" ]; then
    echo "No registry data found, skipping garbage collection"
  else
    echo "Starting garbage collection..."
    registry garbage-collect /etc/distribution/config.yml || true
  fi
done