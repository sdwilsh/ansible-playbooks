#!/usr/bin/env bash
#
# Exercises the built `nut-shutdown-agent` image against a real
# `upsd`/`dummy-ups` pair (rather than a hand-rolled fake protocol
# speaker), scripting each threshold path independently via the fixtures
# in `test/fixtures/`, then asserting on the stubbed `kubectl`/`nsenter`
# invocations the image made.

set -eou pipefail

IMAGE="${1:?Usage: e2e.sh <image-tag>}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

current_network=""
current_fakeupsd=""

cleanup_scenario_resources() {
    if [ -n "${current_fakeupsd}" ]; then
        "${CONTAINER_RUNTIME}" rm -f "${current_fakeupsd}" >/dev/null 2>&1 || true
    fi
    if [ -n "${current_network}" ]; then
        "${CONTAINER_RUNTIME}" network rm "${current_network}" >/dev/null 2>&1 || true
    fi
    current_network=""
    current_fakeupsd=""
}

cleanup_on_interrupt() {
    echo
    echo "Interrupted, cleaning up..."
    cleanup_scenario_resources
    exit 130
}
trap cleanup_on_interrupt INT TERM

stub_dir="${WORK_DIR}/stub"
mkdir -p "${stub_dir}"
cat > "${stub_dir}/kubectl" <<'STUB'
#!/bin/sh
echo "kubectl $*" >> /tmp/shutdown.log
STUB
cat > "${stub_dir}/nsenter" <<'STUB'
#!/bin/sh
echo "nsenter $*" >> /tmp/shutdown.log
STUB
chmod +x "${stub_dir}/kubectl" "${stub_dir}/nsenter"

failures=0

# run_scenario <name> <fixture> <expect_shutdown: yes|no> [-e VAR=VAL ...]
run_scenario() {
    local name="$1"
    local fixture="$2"
    local expect_shutdown="$3"
    shift 3

    echo "=== ${name} ==="

    local run_id="${name}-$$"
    local network="nut-e2e-${run_id}"
    local fakeupsd="nut-e2e-fakeupsd-${run_id}"
    current_network="${network}"
    current_fakeupsd="${fakeupsd}"

    local setup_status
    set +e
    "${CONTAINER_RUNTIME}" network create "${network}" >/dev/null \
        && "${CONTAINER_RUNTIME}" run -d \
            --name "${fakeupsd}" \
            --network "${network}" \
            -v "${FIXTURES_DIR}/${fixture}:/etc/nut/${fixture}:ro,Z" \
            -v "${SCRIPT_DIR}/fakeupsd-entrypoint.sh:/fakeupsd-entrypoint.sh:ro,Z" \
            -e "DUMMY_UPS_FILE=${fixture}" \
            --entrypoint /bin/sh \
            "${IMAGE}" /fakeupsd-entrypoint.sh >/dev/null
    setup_status=$?
    set -e

    if [ "${setup_status}" -ne 0 ]; then
        echo "FAIL: ${name} - could not start fake upsd (network/container setup failed)"
        cleanup_scenario_resources
        failures=$((failures + 1))
        return
    fi

    local ready=no
    for _ in $(seq 1 30); do
        if "${CONTAINER_RUNTIME}" run --rm --network "${network}" \
            --entrypoint upsc \
            "${IMAGE}" "testups@${fakeupsd}" ups.status >/dev/null 2>&1; then
            ready=yes
            break
        fi
        sleep 1
    done

    if [ "${ready}" != "yes" ]; then
        echo "FAIL: ${name} - fake upsd never became ready"
        "${CONTAINER_RUNTIME}" logs "${fakeupsd}" || true
        cleanup_scenario_resources
        failures=$((failures + 1))
        return
    fi

    local output
    set +e
    output="$("${CONTAINER_RUNTIME}" run --rm \
        --network "${network}" \
        -v "${stub_dir}:/usr/local/stub:ro,Z" \
        -e "PATH=/usr/local/stub:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        -e UPS_NAME=testups \
        -e "UPS_HOST=${fakeupsd}" \
        -e NODE_NAME=test-node \
        -e POLL_INTERVAL_SECONDS=1 \
        "$@" \
        --entrypoint /bin/sh \
        "${IMAGE}" \
        -c 'timeout 12 /monitor.sh; cat /tmp/shutdown.log 2>/dev/null || true' 2>&1)"
    set -e

    cleanup_scenario_resources

    local shutdown_fired=no
    if grep -q "nsenter -t 1 -m -u -n -i poweroff" <<< "${output}"; then
        shutdown_fired=yes
    fi

    if [ "${shutdown_fired}" = "${expect_shutdown}" ]; then
        echo "PASS: ${name}"
    else
        echo "FAIL: ${name} (expected shutdown=${expect_shutdown}, got shutdown=${shutdown_fired})"
        echo "${output}"
        failures=$((failures + 1))
    fi
}

run_scenario "on-battery-duration" "on-battery.dev" "yes" \
    -e SHUTDOWN_AFTER_SECONDS_ON_BATTERY=3

run_scenario "battery-charge-percent" "charge-percent.dev" "yes" \
    -e SHUTDOWN_BELOW_BATTERY_CHARGE_PERCENT=50

run_scenario "battery-runtime-seconds" "runtime-seconds.dev" "yes" \
    -e SHUTDOWN_BELOW_RUNTIME_SECONDS=600

run_scenario "fsd-backstop" "fsd.dev" "yes"

run_scenario "healthy-no-trigger" "healthy.dev" "no" \
    -e SHUTDOWN_AFTER_SECONDS_ON_BATTERY=3 \
    -e SHUTDOWN_BELOW_BATTERY_CHARGE_PERCENT=50 \
    -e SHUTDOWN_BELOW_RUNTIME_SECONDS=600

if [ "${failures}" -ne 0 ]; then
    echo "${failures} scenario(s) failed"
    exit 1
fi

echo "All scenarios passed"
