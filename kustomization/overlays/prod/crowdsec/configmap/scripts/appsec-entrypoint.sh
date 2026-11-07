#!/bin/sh

set -e

echo "Copying acquis.d configurations"
rsync -Lav /staging/etc/crowdsec/acquis.d/*.yaml /etc/crowdsec/acquis.d/

echo "Synchronizing default files"
rsync -av --ignore-existing /staging/etc/crowdsec/* /etc/crowdsec

# The credentials do not stay after the container stops, so the next start
# cannot use this machine again.  Each start registers a new machine.
machine="${CUSTOM_HOSTNAME}-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
echo "Registering ${machine} with ${LOCAL_API_URL}"
until cscli lapi register \
  --machine "${machine}" \
  --token "${REGISTRATION_TOKEN}" \
  --url "${LOCAL_API_URL}"; do
  echo "The local API is not available.  Trying again in 5 seconds."
  sleep 5
done

exec /docker_start.sh
