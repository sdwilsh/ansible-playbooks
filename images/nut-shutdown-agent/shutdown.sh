#!/bin/sh

set -eu

if [ -z "${NODE_NAME:-}" ]; then
    echo "NODE_NAME must be set!"
    exit 1
fi

echo "Cordoning ${NODE_NAME}..."
kubectl cordon "${NODE_NAME}" || echo "Cordon failed; continuing to poweroff anyway."

echo "Draining ${NODE_NAME}..."
kubectl drain "${NODE_NAME}" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s \
    || echo "Drain failed or timed out; continuing to poweroff anyway."

echo "Powering off ${NODE_NAME}..."
nsenter -t 1 -m -u -n -i poweroff
