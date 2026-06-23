#!/usr/bin/env sh
set -eux

cat /config.yml > /etc/distribution/config.yml
sed -i "s/__POD_IP__/${POD_IP}/g" /etc/distribution/config.yml
