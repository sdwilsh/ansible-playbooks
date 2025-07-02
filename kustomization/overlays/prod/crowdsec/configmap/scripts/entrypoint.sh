#!/bin/sh

set -e

echo "Copying acquis.d configurations"
rsync -Lav /staging/etc/crowdsec/acquis.d/*.yaml /etc/crowdsec/acquis.d/

echo "Synchronizing default files"
rsync -av --ignore-existing /staging/etc/crowdsec/* /etc/crowdsec

exec /docker_start.sh
