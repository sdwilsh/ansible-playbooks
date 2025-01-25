#!/bin/sh

set -e

echo "Copying acquis.d configurations"
rsync -Lav /staging/etc/crowdsec/acquis.d/*.yaml /etc/crowdsec/acquis.d/

echo "Creating /etc/crowdsec/local_api_credentials.yaml"
echo "url: http://${POD_IP}:8081
login: localhost
password: ${LOCAL_API_PASSWORD}" > /etc/crowdsec/local_api_credentials.yaml

echo "Synchronizing default files"
rsync -av --ignore-existing /staging/etc/crowdsec/* /etc/crowdsec

exec /docker_start.sh
