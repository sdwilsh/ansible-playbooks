#!/bin/sh

set -e

# Setup a real mount for docker when running in kata:
# https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-run-docker-with-kata.md
if [ "$(df -PT /var/lib/docker | awk 'NR==2 {print $2}')" = virtiofs ];
then
  truncate -s 40G /mnt/scratch/dind-disk.img
  mkfs.ext4 -F /mnt/scratch/dind-disk.img
  mkdir -p /var/lib/docker
  mount -o loop /mnt/scratch/dind-disk.img /var/lib/docker
fi

# The original entry point.
/usr/local/bin/dockerd-entrypoint.sh &

while [ ! -f /state/complete ]
do
  sleep 5
  echo "Waiting for action completion..."
done

kill "$(cat /var/run/docker.pid)"
