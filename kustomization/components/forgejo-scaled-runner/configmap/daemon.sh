#!/bin/sh

set -e

# kubelet requires /dev/kmsg to start (it watches it for OOM events) and
# fails immediately with "open /dev/kmsg: no such file or directory" if it's
# missing.  Privileged containers normally inherit /dev/kmsg from the real
# host, but under kata there is no real host to inherit from - only the
# guest VM's own /dev, which often doesn't expose one.  This only matters
# for workloads that run their own nested kubelet (e.g. kind-based e2e
# tests); create it unconditionally since it's a no-op when already present.
if [ ! -e /dev/kmsg ]; then
  mknod /dev/kmsg c 1 11 || true
fi

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
