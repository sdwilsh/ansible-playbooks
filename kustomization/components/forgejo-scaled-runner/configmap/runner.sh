#!/bin/sh

set -e

while ! nc -z 127.0.0.1 2376 </dev/null; do
    echo 'waiting for docker daemon...';
    sleep 5;
done

forgejo-runner one-job \
    --config /config/config.yml \
    || echo "forgejo-runner failed!  Continuing to cleanup..."

echo "Notifing daemon as completed..."
touch /state/complete
