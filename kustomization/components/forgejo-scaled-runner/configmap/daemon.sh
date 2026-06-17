#!/bin/sh

set -e

# The original entry point.
/usr/local/bin/dockerd-entrypoint.sh &

while [ ! -f /state/complete ]
do
  sleep 5
  echo "Waiting for action completion..."
done

kill "$(cat /var/run/docker.pid)"
