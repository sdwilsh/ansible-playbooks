#!/usr/bin/env bash
#
# Runs the built `wireguard-egress` image against a real WireGuard peer.
# A "pod" container holds the network namespace.  The image runs in that
# namespace like an init container, and the checks run inside it.

set -eou pipefail

IMAGE="${1:?Usage: e2e.sh <image-tag>}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"
PREFIX="${E2E_NAME_PREFIX:-wg-egress-test}-$$"

NETWORK="${PREFIX}-net"
PEER="${PREFIX}-peer"
POD="${PREFIX}-pod"
FWMARK=51820
FWMARK_HEX="$(printf '0x%x' "${FWMARK}")"
PEER_TUNNEL_IP=10.99.0.1
CLIENT_TUNNEL_IP=10.99.0.2
EXCLUDED_CIDRS="198.51.100.0/24 203.0.113.0/24"

WORK_DIR="$(mktemp -d)"
containers=("${PEER}" "${POD}")
failures=0

cleanup() {
    local name
    for name in "${containers[@]}"; do
        "${CONTAINER_RUNTIME}" rm -f "${name}" >/dev/null 2>&1 || true
    done
    "${CONTAINER_RUNTIME}" network rm "${NETWORK}" >/dev/null 2>&1 || true
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT
trap 'echo "Interrupted, cleaning up..."; exit 130' INT TERM

pass() { echo "PASS: $1"; }
fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi
}

assert_contains() {
    if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1: expected '$3' in: $2"; fi
}

assert_not_contains() {
    if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1: did not expect '$3' in: $2"; fi
}

runtime() { "${CONTAINER_RUNTIME}" "$@"; }
in_pod() { runtime exec "${POD}" "$@"; }

# tool <command...>
# Runs a command from the image, outside the pod, to make keys.
tool() { runtime run --rm --entrypoint sh "${IMAGE}" -c "$@"; }

# start_detached <name> <config-file> <create options...>
# Starts a long-lived container from the image.  `STARTUP` is its script.
start_detached() {
    local name="$1" config="$2"
    shift 2
    runtime create --name "${name}" --entrypoint sh "$@" "${IMAGE}" -c "${STARTUP}" >/dev/null
    runtime cp "${config}" "${name}:/etc/wireguard/wg0.conf"
    runtime start "${name}" >/dev/null
}

# run_setup <id> [docker create options...]
# Runs the image in the namespace of the pod, as the init container would.
# Sets `setup_output` and `setup_status`.
run_setup() {
    local name="${PREFIX}-$1"
    shift
    containers+=("${name}")
    runtime create --name "${name}" --network "container:${POD}" \
        --cap-drop ALL --cap-add NET_ADMIN "$@" "${IMAGE}" >/dev/null
    runtime cp "${WORK_DIR}/client.conf" "${name}:/etc/wireguard/wg0.conf"
    setup_status=0
    setup_output="$(runtime start -a "${name}" 2>&1)" || setup_status=$?
}

wait_for_handshake() {
    local deadline=$((SECONDS + 20)) timestamp
    while ((SECONDS < deadline)); do
        timestamp="$(in_pod wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}')" || true
        if [ -n "${timestamp}" ] && [ "${timestamp}" != 0 ] \
            && (($(date +%s) - timestamp < 60)); then
            return 0
        fi
        sleep 1
    done
    return 1
}

rule_count() { in_pod ip rule show | grep -c -- "$1" || true; }

check_tunnel() {
    local label="$1" peers handshake_ok=no ping_output
    peers="$(in_pod wg show wg0 peers)"
    assert_eq "${label}: wg show lists the peer" "${peer_public}" "${peers}"
    if wait_for_handshake; then handshake_ok=yes; fi
    assert_eq "${label}: the peer completed a recent handshake" yes "${handshake_ok}"
    assert_contains "${label}: the route to the peer tunnel address uses wg0" \
        "$(in_pod ip route get "${PEER_TUNNEL_IP}")" "dev wg0"
    if ping_output="$(in_pod ping -c 3 -W 2 "${PEER_TUNNEL_IP}" 2>&1)"; then
        pass "${label}: ping to the peer tunnel address succeeds"
    else
        fail "${label}: ping to the peer tunnel address failed: ${ping_output}"
    fi
}

runtime network create "${NETWORK}" >/dev/null
gateway="$(runtime network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "${NETWORK}")"

client_private="$(tool 'wg genkey')"
client_public="$(tool "echo ${client_private} | wg pubkey")"
peer_private="$(tool 'wg genkey')"
peer_public="$(tool "echo ${peer_private} | wg pubkey")"

cat > "${WORK_DIR}/peer.conf" <<CONF
[Interface]
PrivateKey = ${peer_private}
ListenPort = 51820

[Peer]
PublicKey = ${client_public}
AllowedIPs = ${CLIENT_TUNNEL_IP}/32
CONF

STARTUP='set -eu
ip link add dev wg0 type wireguard
wg setconf wg0 /etc/wireguard/wg0.conf
ip address add '"${PEER_TUNNEL_IP}"'/32 dev wg0
ip link set up dev wg0
ip route add '"${CLIENT_TUNNEL_IP}"'/32 dev wg0
exec sleep 3600'
start_detached "${PEER}" "${WORK_DIR}/peer.conf" --network "${NETWORK}" --cap-add NET_ADMIN

for _ in $(seq 20); do
    in_peer_ready="$(runtime exec "${PEER}" wg show wg0 2>/dev/null)" && break
    sleep 0.5
done
peer_ip="$(runtime inspect -f "{{(index .NetworkSettings.Networks \"${NETWORK}\").IPAddress}}" "${PEER}")"
[ -n "${in_peer_ready:-}" ] || { echo "The peer did not start." >&2; runtime logs "${PEER}" >&2; exit 1; }

cat > "${WORK_DIR}/client.conf" <<CONF
[Interface]
PrivateKey = ${client_private}

[Peer]
PublicKey = ${peer_public}
Endpoint = ${peer_ip}:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 5
CONF

runtime create --name "${POD}" --network "${NETWORK}" --cap-add NET_ADMIN --entrypoint sleep "${IMAGE}" 3600 >/dev/null
runtime start "${POD}" >/dev/null

run_setup missing-address -e "WG_CONFIG=/etc/wireguard/wg0.conf"
assert_eq "without WG_ADDRESS the setup fails" 1 "${setup_status}"
assert_contains "without WG_ADDRESS the message names the variable" "${setup_output}" "WG_ADDRESS is required"

run_setup missing-exclude -e "WG_ADDRESS=${CLIENT_TUNNEL_IP}/32"
assert_eq "without WG_EXCLUDE_CIDRS the setup fails" 1 "${setup_status}"
assert_contains "without WG_EXCLUDE_CIDRS the message names the variable" "${setup_output}" "WG_EXCLUDE_CIDRS is required"

run_setup missing-config -e "WG_ADDRESS=${CLIENT_TUNNEL_IP}/32" -e "WG_EXCLUDE_CIDRS=" -e "WG_CONFIG=/nonexistent.conf"
assert_eq "without the config file the setup fails" 1 "${setup_status}"
assert_contains "without the config file the message names the path" "${setup_output}" "/nonexistent.conf"

setup_env=(-e "WG_ADDRESS=${CLIENT_TUNNEL_IP}/32" -e "WG_EXCLUDE_CIDRS=${EXCLUDED_CIDRS}")
run_setup first "${setup_env[@]}"
assert_eq "the first setup succeeds" 0 "${setup_status}"
assert_not_contains "the setup output holds no private key" "${setup_output}" "${client_private}"
check_tunnel "first run"

excluded_route="$(in_pod ip route get 198.51.100.7)"
assert_contains "an excluded address routes via the default gateway" "${excluded_route}" "via ${gateway} dev eth0"
assert_contains "the second excluded range routes via eth0" "$(in_pod ip route get 203.0.113.9)" "dev eth0"
public_route="$(in_pod ip route get 1.1.1.1)"
assert_contains "a public address uses the tunnel" "${public_route}" "dev wg0"
assert_contains "a public address uses the WireGuard table" "${public_route}" "table ${FWMARK}"

rules_before="$(in_pod ip rule show)"
run_setup second "${setup_env[@]}"
assert_eq "the second setup succeeds" 0 "${setup_status}"
assert_eq "after two runs there is one not-fwmark rule" 1 "$(rule_count "not from all fwmark ${FWMARK_HEX} lookup ${FWMARK}")"
assert_eq "after two runs there is one suppress rule" 1 "$(rule_count 'suppress_prefixlength 0')"
assert_eq "two runs leave the rule list unchanged" "${rules_before}" "$(in_pod ip rule show)"
for cidr in ${EXCLUDED_CIDRS}; do
    assert_eq "after two runs there is one route for ${cidr}" 1 "$(in_pod ip route show "${cidr}" | wc -l | tr -d ' ')"
done
assert_eq "after two runs wg0 has one address" 1 "$(in_pod ip -4 -o address show dev wg0 | wc -l | tr -d ' ')"
check_tunnel "second run"
assert_eq "after two runs there is one blackhole route" 1 "$(in_pod ip route show table "${FWMARK}" | grep -c '^blackhole default')"

runtime run --rm --network "container:${POD}" --cap-drop ALL --cap-add NET_ADMIN --entrypoint ip "${IMAGE}" link delete dev wg0
lost_route="$(in_pod ip route get 1.1.1.1 2>&1 || true)"
assert_not_contains "without wg0 a public address does not use eth0" "${lost_route}" "dev eth0"
if in_pod ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
    fail "without wg0 a ping to a public address fails"
else
    pass "without wg0 a ping to a public address fails"
fi

if ((failures > 0)); then
    echo "${failures} check(s) failed." >&2
    exit 1
fi
echo "All checks passed."
