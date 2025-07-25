#!/bin/bash

set -ouex pipefail

# renovate: datasource=github-releases depName=openpubkey/opkssh
OPKSSH_VERSION=0.8.0

rsync -rvK /ctx/opkssh/ /
systemd-sysusers /usr/lib/sysusers.d/opkssh.conf
systemctl enable opkssh-check-selinux.service
chown -R root:opksshuser /etc/opk
chmod -R o= /etc/opk

# Grab the installer file for the version we are running.  This is used by the
# opkssh-check-selinux service that is enabled above.
curl -o /usr/share/opkssh/install-linux.sh https://raw.githubusercontent.com/openpubkey/opkssh/refs/tags/v${OPKSSH_VERSION}/scripts/install-linux.sh 
