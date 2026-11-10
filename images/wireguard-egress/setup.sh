#!/bin/sh
#
# Routes all traffic of the pod through a WireGuard tunnel, except the
# traffic to `WG_EXCLUDE_CIDRS`.  Run it as an init container with
# NET_ADMIN.  Run it again at any time: it leaves one copy of each rule.

set -eu
set -f

WG_CONFIG="${WG_CONFIG:-/etc/wireguard/wg0.conf}"
WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_MTU="${WG_MTU:-1420}"
WG_FWMARK="${WG_FWMARK:-51820}"

fail() {
  echo "wireguard-egress: $*" >&2
  exit 1
}

# Print the command, then run it.  No command here holds a secret.
run() {
  echo "+ $*"
  "$@"
}

# `ip rule del` removes one rule per call.
delete_rule() {
  while ip rule del "$@" 2>/dev/null; do :; done
}

[ -n "${WG_ADDRESS:-}" ] || fail "WG_ADDRESS is required, for example 10.2.0.2/32"
# An empty value is valid and means "no exclusions".
[ -n "${WG_EXCLUDE_CIDRS+set}" ] || fail "WG_EXCLUDE_CIDRS is required, for example the pod and service ranges of the cluster"
[ -f "${WG_CONFIG}" ] || fail "WG_CONFIG (${WG_CONFIG}) does not exist"

if ip link show dev "${WG_INTERFACE}" >/dev/null 2>&1; then
  run ip link delete dev "${WG_INTERFACE}"
fi

run ip link add dev "${WG_INTERFACE}" type wireguard
run wg setconf "${WG_INTERFACE}" "${WG_CONFIG}"
run ip address add "${WG_ADDRESS}" dev "${WG_INTERFACE}"
run ip link set mtu "${WG_MTU}" up dev "${WG_INTERFACE}"

# The tunnel socket carries the fwmark, so it skips the tunnel route.
run wg set "${WG_INTERFACE}" fwmark "${WG_FWMARK}"
run ip route replace default dev "${WG_INTERFACE}" table "${WG_FWMARK}"
# If the interface goes away, drop the traffic.  Do not send it out eth0.
run ip route replace blackhole default metric 4096 table "${WG_FWMARK}"
delete_rule not fwmark "${WG_FWMARK}" table "${WG_FWMARK}"
delete_rule table main suppress_prefixlength 0
run ip rule add not fwmark "${WG_FWMARK}" table "${WG_FWMARK}"
run ip rule add table main suppress_prefixlength 0

if [ -n "${WG_EXCLUDE_CIDRS}" ]; then
  gateway="$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "via") {print $(i + 1); exit}}')"
  [ -n "${gateway}" ] || fail "the pod has no default route with a gateway"
  run ip route replace "${gateway}" dev eth0
  for cidr in ${WG_EXCLUDE_CIDRS}; do
    run ip route replace "${cidr}" via "${gateway}" dev eth0
  done
fi

echo "wireguard-egress: ${WG_INTERFACE} is up, all other traffic uses table ${WG_FWMARK}"
