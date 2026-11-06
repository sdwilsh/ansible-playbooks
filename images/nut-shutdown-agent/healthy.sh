#!/bin/sh

set -eu

# `live` checks the loop heartbeat, and `ready` checks the last successful
# poll.  A restart resets the on-battery countdown, so liveness must not
# depend on `upsd`.
case "${1:-}" in
    live) heartbeat=/tmp/nut-loop-heartbeat ;;
    ready) heartbeat=/tmp/nut-heartbeat ;;
    *)
        echo "Usage: healthy.sh <live|ready>"
        exit 1
        ;;
esac

# Once shutdown starts, the poll loop stops, and a drain can take minutes.
# A failing probe would then restart the container and stop the shutdown.
if [ -e /tmp/shutdown-started ]; then
    exit 0
fi

heartbeat_mtime=$(stat -c %Y "${heartbeat}" 2>/dev/null) || exit 1
max_age_seconds=$(( ${POLL_INTERVAL_SECONDS:-10} * 6 ))
age_seconds=$(( $(date +%s) - heartbeat_mtime ))

[ "${age_seconds}" -le "${max_age_seconds}" ]
