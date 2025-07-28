#!/bin/bash

set -ouex pipefail

# Core packages needed for our scripts to work.
dnf install --setopt=install_weak_deps=False -y \
    'dnf5-command(copr)' \
    rsync

dnf -y copr enable atim/starship

# Determine what architecture we are building for because some packages do not
# label with the output from arch.
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

# renovate: datasource=github-releases depName=twpayne/chezmoi
CHEZMOI_VERSION=2.63.1
# renovate: datasource=github-releases depName=openpubkey/opkssh
OPKSSH_VERSION=0.8.0

dnf install --setopt=install_weak_deps=False -y \
    atuin \
    fish \
    starship \
    vim \
    "https://github.com/twpayne/chezmoi/releases/download/v${CHEZMOI_VERSION}/chezmoi-${CHEZMOI_VERSION}-$(arch).rpm" \
    https://github.com/openpubkey/opkssh/releases/download/v${OPKSSH_VERSION}/opkssh_${OPKSSH_VERSION}_linux_${TARGETARCHITECTURE}.rpm

# For dev-sec hardening of SSH
dnf install --setopt=install_weak_deps=False -y \
    audit \
    audit-rules \
    checkpolicy \
    initscripts-service \
    openssh \
    python3-dnf \
    python3-policycoreutils

/ctx/packages/configure-alloy.sh
/ctx/packages/configure-node-exporter.sh
/ctx/packages/configure-opkssh.sh
