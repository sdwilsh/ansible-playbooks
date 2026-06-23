#!/usr/bin/env sh
set -eux

# Run garbage collection job in background
/garbage-collect.sh &

registry serve /etc/distribution/config.yml
