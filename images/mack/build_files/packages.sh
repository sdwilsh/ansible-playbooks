#!/bin/bash

set -ouex pipefail

# Core packages needed for our scripts to work.
dnf install --setopt=install_weak_deps=False -y \
    'dnf5-command(copr)' \
    rsync

dnf -y copr enable atim/starship

# renovate: datasource=github-releases depName=twpayne/chezmoi
CHEZMOI_VERSION=2.64.0

dnf install --setopt=install_weak_deps=False -y \
    atuin \
    fish \
    starship \
    vim \
    "https://github.com/twpayne/chezmoi/releases/download/v${CHEZMOI_VERSION}/chezmoi-${CHEZMOI_VERSION}-$(arch).rpm"

/ctx/packages/configure-alloy.sh
/ctx/packages/configure-node-exporter.sh
/ctx/packages/configure-opkssh.sh
