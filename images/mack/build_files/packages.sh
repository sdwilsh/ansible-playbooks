#!/bin/bash

set -ouex pipefail

# Core packages needed for our scripts to work.
dnf install --setopt=install_weak_deps=False -y \
    'dnf5-command(copr)' \
    rsync

dnf -y copr enable atim/starship

# renovate: datasource=github-releases depName=twpayne/chezmoi
CHEZMOI_VERSION=2.63.0

dnf install --setopt=install_weak_deps=False -y \
    atuin \
    fish \
    starship \
    "https://github.com/twpayne/chezmoi/releases/download/v${CHEZMOI_VERSION}/chezmoi-${CHEZMOI_VERSION}-$(arch).rpm"

# For dev-sec hardening of SSH
dnf install --setopt=install_weak_deps=False -y \
    checkpolicy \
    openssh \
    python3-dnf \
    python3-policycoreutils

/ctx/packages/configure-alloy.sh
/ctx/packages/configure-node-exporter.sh
