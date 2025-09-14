#!/bin/bash

set -ouex pipefail

# renovate: datasource=github-releases depName=openpubkey/opkssh
OPKSSH_VERSION=0.10.0

rsync -rvK /ctx/opkssh/ /
systemd-sysusers /usr/lib/sysusers.d/opkssh.conf
systemctl enable opkssh-configure-selinux.service
chown -R root:opksshuser /etc/opk
chmod -R o= /etc/opk

# Grab the te file for selinux so it can be installed/updated at boot.
curl --fail \
    -o \
    /usr/share/opkssh/opkssh.te https://raw.githubusercontent.com/openpubkey/opkssh/refs/tags/v${OPKSSH_VERSION}/opkssh.te

# Determine what architecture we are building for because some packages do not
# label with the output from arch.
echo "Picking the correct target architecture from platform '${TARGETPLATFORM}'..."
TARGETARCHITECTURE=""
case "${TARGETPLATFORM}" in
    linux/amd64)
        TARGETARCHITECTURE="amd64"
        ;;
    linux/arm64)
        TARGETARCHITECTURE="arm64"
        ;;
    *)
        echo "Unable to determine target architecture!"
        exit 1
        ;;
esac

dnf install --setopt=install_weak_deps=False -y \
    checkpolicy \
    https://github.com/openpubkey/opkssh/releases/download/v${OPKSSH_VERSION}/opkssh_${OPKSSH_VERSION}_linux_${TARGETARCHITECTURE}.rpm
