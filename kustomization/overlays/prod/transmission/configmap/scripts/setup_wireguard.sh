#!/bin/sh

set -x
set -e

# Install Dependencies
apk add iproute2
apk add wireguard-tools-wg

# Delete `wg0` if it already exists.
if ip link show dev wg0 >/dev/null 2>&1; then
  ip link delete dev wg0
fi

# Create and Configure `wg0`
ip link add dev wg0 type wireguard
wg setconf wg0 /etc/wireguard/wg0.conf
ip address add 10.2.0.2 dev wg0 # Proton VPN client address is always 10.2.0.2.
ip link set mtu 1420 up dev wg0

# By default, route all traffic through `wg0`.
wg set wg0 fwmark 51820
ip route add default dev wg0 table 51820
ip rule add not fwmark 51820 table 51820
ip rule add table main suppress_prefixlength 0

#
# Route Exceptions
#

# Route all k8s traffic though `eth0`.
ip route add 172.16.0.1 dev eth0 || true
ip route add 172.16.0.0/16 via 172.16.0.1 dev eth0 || true
ip route add 172.17.0.0/16 via 172.16.0.1 dev eth0 || true
