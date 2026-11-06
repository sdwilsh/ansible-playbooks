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
NAME_PREFIX="${E2E_NAME_PREFIX:-nut-e2e}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

current_network=""
current_fakeupsd=""
current_agent=""

cleanup_scenario_resources() {
    if [ -n "${current_agent}" ]; then
        "${CONTAINER_RUNTIME}" rm -f "${current_agent}" >/dev/null 2>&1 || true
    fi
    if [ -n "${current_fakeupsd}" ]; then
        "${CONTAINER_RUNTIME}" rm -f "${current_fakeupsd}" >/dev/null 2>&1 || true
    fi
    if [ -n "${current_network}" ]; then
        "${CONTAINER_RUNTIME}" network rm "${current_network}" >/dev/null 2>&1 || true
    fi
    current_network=""
    current_fakeupsd=""
    current_agent=""
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
if [ "$1" = drain ]; then
    sleep "${STUB_DRAIN_SECONDS:-0}"
fi
STUB
cat > "${stub_dir}/nsenter" <<'STUB'
#!/bin/sh
echo "nsenter $*" >> /tmp/shutdown.log
STUB
chmod +x "${stub_dir}/kubectl" "${stub_dir}/nsenter"

failures=0
scenario_count=0

# start_fake_upsd <name> <fixture>
# Starts a network and a fake `upsd` serving <fixture>, and waits until it
# answers.  Sets `current_network`, `current_fakeupsd` and `run_id`.
# A container name is also a DNS label, so `run_id` must stay short.
start_fake_upsd() {
    local name="$1"
    local fixture="$2"

    scenario_count=$((scenario_count + 1))
    run_id="${scenario_count}-$$"
    current_network="${NAME_PREFIX}-${run_id}"
    current_fakeupsd="${NAME_PREFIX}-fakeupsd-${run_id}"

    local setup_status
    set +e
    "${CONTAINER_RUNTIME}" network create "${current_network}" >/dev/null \
        && "${CONTAINER_RUNTIME}" run -d \
            --name "${current_fakeupsd}" \
            --network "${current_network}" \
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
        return 1
    fi

    local ready=no
    for attempt in $(seq 1 30); do
        if "${CONTAINER_RUNTIME}" run --rm --name "${NAME_PREFIX}-ready-${run_id}-${attempt}" \
            --network "${current_network}" \
            --entrypoint upsc \
            "${IMAGE}" "testups@${current_fakeupsd}" ups.status >/dev/null 2>&1; then
            ready=yes
            break
        fi
        sleep 1
    done

    if [ "${ready}" != "yes" ]; then
        echo "FAIL: ${name} - fake upsd never became ready"
        "${CONTAINER_RUNTIME}" logs "${current_fakeupsd}" || true
        cleanup_scenario_resources
        failures=$((failures + 1))
        return 1
    fi
}

# set_agent_options
# Sets `agent_options` for an agent container against the current fake `upsd`.
# The probe scenarios assume this one second poll interval, which gives
# `healthy.sh` a six second limit.
set_agent_options() {
    agent_options=(
        --network "${current_network}"
        -v "${stub_dir}:/usr/local/stub:ro,Z"
        -e "PATH=/usr/local/stub:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        -e UPS_NAME=testups
        -e "UPS_HOST=${current_fakeupsd}"
        -e NODE_NAME=test-node
        -e POLL_INTERVAL_SECONDS=1
    )
}

# run_scenario <name> <fixture> <expect_shutdown: yes|no> [-e VAR=VAL ...]
run_scenario() {
    local name="$1"
    local fixture="$2"
    local expect_shutdown="$3"
    shift 3

    echo "=== ${name} ==="

    local run_id
    if ! start_fake_upsd "${name}" "${fixture}"; then
        return
    fi

    local output
    set_agent_options
    set +e
    output="$("${CONTAINER_RUNTIME}" run --rm \
        --name "${NAME_PREFIX}-agent-${run_id}" \
        "${agent_options[@]}" \
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

# start_agent [-e VAR=VAL ...]
# Runs the image's `monitor.sh` in the background against the current fake
# `upsd`.  Sets `current_agent`.
start_agent() {
    current_agent="${NAME_PREFIX}-agent-${run_id}"
    set_agent_options
    "${CONTAINER_RUNTIME}" run -d \
        --name "${current_agent}" \
        "${agent_options[@]}" \
        "$@" \
        "${IMAGE}" >/dev/null
}

# probe_passes <live|ready>
# Succeeds when `healthy.sh` in the agent container exits zero in that mode.
probe_passes() {
    "${CONTAINER_RUNTIME}" exec "${current_agent}" /healthy.sh "$1" >/dev/null 2>&1
}

# wait_for_probe <live|ready> <pass|fail> <timeout_seconds>
# Succeeds once the probe in that mode gives the wanted result.
wait_for_probe() {
    local mode="$1"
    local want="$2"
    local timeout_seconds="$3"
    local got

    for _ in $(seq 1 "${timeout_seconds}"); do
        if probe_passes "${mode}"; then
            got=pass
        else
            got=fail
        fi
        if [ "${got}" = "${want}" ]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# probe_fail <name> <message>
probe_fail() {
    echo "FAIL: $1 ($2)"
    "${CONTAINER_RUNTIME}" logs "${current_agent}" 2>&1 || true
    failures=$((failures + 1))
}

probe_scenario_after_healthy_poll() {
    local name="probe-passes-after-healthy-poll"
    echo "=== ${name} ==="

    local run_id
    start_fake_upsd "${name}" "healthy.dev" || return 0
    start_agent

    if ! wait_for_probe ready pass 15; then
        probe_fail "${name}" "ready probe never passed"
    elif ! probe_passes live; then
        probe_fail "${name}" "live probe failed after the ready probe passed"
    else
        echo "PASS: ${name}"
    fi
    cleanup_scenario_resources
}

probe_scenario_upsd_unreachable() {
    local name="probe-fails-when-upsd-unreachable"
    echo "=== ${name} ==="

    local run_id
    start_fake_upsd "${name}" "healthy.dev" || return 0
    start_agent

    if ! wait_for_probe ready pass 15; then
        probe_fail "${name}" "ready probe never passed before upsd was stopped"
    else
        "${CONTAINER_RUNTIME}" rm -f "${current_fakeupsd}" >/dev/null
        if ! wait_for_probe ready fail 30; then
            probe_fail "${name}" "ready probe still passed 30s after upsd was stopped"
        elif ! probe_passes live; then
            probe_fail "${name}" "live probe failed because upsd was unreachable"
        else
            echo "PASS: ${name}"
        fi
    fi
    cleanup_scenario_resources
}

probe_scenario_bad_mode() {
    local name="probe-rejects-missing-or-unknown-mode"
    echo "=== ${name} ==="

    local run_id
    start_fake_upsd "${name}" "healthy.dev" || return 0
    start_agent

    if ! wait_for_probe ready pass 15; then
        probe_fail "${name}" "ready probe never passed"
    elif "${CONTAINER_RUNTIME}" exec "${current_agent}" /healthy.sh >/dev/null 2>&1; then
        probe_fail "${name}" "probe passed with no mode on a healthy agent"
    elif "${CONTAINER_RUNTIME}" exec "${current_agent}" /healthy.sh bogus >/dev/null 2>&1; then
        probe_fail "${name}" "probe passed with an unknown mode on a healthy agent"
    else
        echo "PASS: ${name}"
    fi
    cleanup_scenario_resources
}

probe_scenario_during_shutdown() {
    local name="probe-passes-after-shutdown-starts"
    echo "=== ${name} ==="

    local run_id
    start_fake_upsd "${name}" "fsd.dev" || return 0
    start_agent -e STUB_DRAIN_SECONDS=60

    local drain_started=no
    for _ in $(seq 1 15); do
        if "${CONTAINER_RUNTIME}" exec "${current_agent}" grep -q "kubectl drain" /tmp/shutdown.log 2>/dev/null; then
            drain_started=yes
            break
        fi
        sleep 1
    done

    if [ "${drain_started}" != "yes" ]; then
        probe_fail "${name}" "shutdown never reached the drain"
        cleanup_scenario_resources
        return
    fi

    sleep 10

    if "${CONTAINER_RUNTIME}" exec "${current_agent}" grep -q poweroff /tmp/shutdown.log; then
        probe_fail "${name}" "node powered off before the probe ran"
    elif ! probe_passes ready; then
        probe_fail "${name}" "ready probe failed 10s into a drain, with a stale heartbeat"
    elif ! probe_passes live; then
        probe_fail "${name}" "live probe failed 10s into a drain, with a stale heartbeat"
    else
        echo "PASS: ${name}"
    fi
    cleanup_scenario_resources
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

probe_scenario_after_healthy_poll
probe_scenario_upsd_unreachable
probe_scenario_bad_mode
probe_scenario_during_shutdown

if [ "${failures}" -ne 0 ]; then
    echo "${failures} scenario(s) failed"
    exit 1
fi

echo "All scenarios passed"
