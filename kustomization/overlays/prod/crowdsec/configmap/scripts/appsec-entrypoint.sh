#!/bin/sh

set -e

echo "Copying acquis.d configurations"
rsync -Lav /staging/etc/crowdsec/acquis.d/*.yaml /etc/crowdsec/acquis.d/

echo "Synchronizing default files"
rsync -av --ignore-existing /staging/etc/crowdsec/* /etc/crowdsec

echo "Registering ${CUSTOM_HOSTNAME} with ${LOCAL_API_URL}"
until cscli lapi register \
  --machine "${CUSTOM_HOSTNAME}" \
  --token "${REGISTRATION_TOKEN}" \
  --url "${LOCAL_API_URL}"; do
  echo "The local API is not available.  Trying again in 5 seconds."
  sleep 5
done

exec /docker_start.sh
