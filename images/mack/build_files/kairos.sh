#!/bin/bash

set -ouex pipefail

/ctx/kairos/configure-serial-console.sh

# kairos-operator compares KAIROS_VERSION to decide whether a node
# needs an upgrade.  A plain kairos-fedora bump changes this value.
# MACK_VERSION differs at every release, so a weekly rebuild of the
# same commit still changes this value.  Without this suffix,
# kairos-operator skips the upgrade.
# shellcheck disable=SC1091
# This file exists on the node at build time, not at lint time.
. /etc/kairos-release
sed -i "s/^KAIROS_VERSION=.*/KAIROS_VERSION=\"${KAIROS_VERSION}-mack.${MACK_VERSION}\"/" /etc/kairos-release
