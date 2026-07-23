#!/bin/sh

set -eu

if [ -z "${UPS_NAME:-}" ]; then
    echo "UPS_NAME must be set!"
    exit 1
fi

if [ -z "${UPS_HOST:-}" ]; then
    echo "UPS_HOST must be set!"
    exit 1
fi

if [ -z "${NODE_NAME:-}" ]; then
    echo "NODE_NAME must be set!"
    exit 1
fi

ups_port="${UPS_PORT:-3493}"
poll_interval_seconds="${POLL_INTERVAL_SECONDS:-10}"
ups_target="${UPS_NAME}@${UPS_HOST}:${ups_port}"
on_battery_since=""

# Only `SHUTDOWN_AFTER_SECONDS_ON_BATTERY`, `SHUTDOWN_BELOW_BATTERY_CHARGE_PERCENT`,
# and `SHUTDOWN_BELOW_RUNTIME_SECONDS` are configurable, and this script has
# no way to enforce which subset a given deployment sets.  That subset is what
# staggers sibling nodes on the same UPS so they don't all go down at once;
# whatever deploys this (DaemonSet/patch per node group) MUST give each group
# a distinct threshold, or they'll cross it within one poll interval of each
# other.

extract() {
    printf '%s\n' "${1}" | awk -v key="${2}: " 'index($0, key) == 1 { print substr($0, length(key) + 1) }'
}

is_number() {
    case "$1" in
        '' | *[!0-9.]*) return 1 ;;
        *) return 0 ;;
    esac
}

# check_threshold <label> <value> <threshold> <unit>
# No-op if <threshold> is unset.  Shuts down (via exec, so this never
# returns on that path) if <value> is numeric and <= <threshold>; logs and
# skips this poll's check on a non-numeric <value> instead of disabling it
# permanently.
check_threshold() {
    label="$1"
    value="$2"
    threshold="$3"
    unit="$4"

    if [ -z "${threshold}" ]; then
        return
    fi

    if ! is_number "${value}"; then
        echo "${label} reading '${value}' is not numeric; skipping this poll's check."
        return
    fi

    if awk -v a="${value}" -v b="${threshold}" 'BEGIN { exit !(a <= b) }'; then
        echo "${label} at ${value}${unit} (<= ${threshold}${unit}) -- shutting down ${NODE_NAME} now."
        exec /shutdown.sh
    fi
}

echo "Monitoring ${ups_target} for node ${NODE_NAME}..."

while true; do
    if data=$(upsc "${ups_target}" 2>/dev/null); then
        status=$(extract "${data}" ups.status)
        charge=$(extract "${data}" battery.charge)
        runtime=$(extract "${data}" battery.runtime)

        if [ -z "${status}" ]; then
            echo "ups.status missing from this poll's reading; skipping this poll's status check."
        else
            case " ${status} " in
                *" FSD "*)
                    echo "UPS reports FSD (forced shutdown) -- shutting down ${NODE_NAME} now."
                    exec /shutdown.sh
                    ;;
                *" OB "*)
                    now=$(date +%s)
                    if [ -z "${on_battery_since}" ]; then
                        on_battery_since="${now}"
                        echo "UPS is now on battery."
                    fi
                    if [ -n "${SHUTDOWN_AFTER_SECONDS_ON_BATTERY:-}" ]; then
                        elapsed=$(( now - on_battery_since ))
                        if [ "${elapsed}" -ge "${SHUTDOWN_AFTER_SECONDS_ON_BATTERY}" ]; then
                            echo "On battery for ${elapsed}s (>= ${SHUTDOWN_AFTER_SECONDS_ON_BATTERY}s) -- shutting down ${NODE_NAME} now."
                            exec /shutdown.sh
                        fi
                    fi
                    ;;
                *)
                    if [ -n "${on_battery_since}" ]; then
                        echo "UPS is back on line power."
                    fi
                    on_battery_since=""
                    ;;
            esac
        fi

        check_threshold "Battery charge" "${charge}" "${SHUTDOWN_BELOW_BATTERY_CHARGE_PERCENT:-}" "%"
        check_threshold "Battery runtime" "${runtime}" "${SHUTDOWN_BELOW_RUNTIME_SECONDS:-}" "s"
    else
        echo "Failed to query ${ups_target}; will retry."
    fi

    sleep "${poll_interval_seconds}"
done
