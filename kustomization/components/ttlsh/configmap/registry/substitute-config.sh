#!/usr/bin/env sh
set -eux

cat /config.yml > /etc/docker/registry/config.yml
sed -i "s/__HOOK_TOKEN__/${HOOK_TOKEN}/g" /etc/docker/registry/config.yml
sed -i "s/__POD_IP__/${POD_IP}/g" /etc/docker/registry/config.yml
