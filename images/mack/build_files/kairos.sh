#!/bin/bash

set -ouex pipefail

/ctx/kairos/configure-serial-console.sh

# kairos-operator compares KAIROS_VERSION to decide whether a node
# needs an upgrade.  A plain kairos-fedora bump changes this value.
# Our own hardening changes do not change this value.  This step adds
# a suffix to KAIROS_VERSION.  The suffix makes the value different at
# every build.  Without this step, kairos-operator skips a real update
# to this image.
# shellcheck disable=SC1091
# This file exists on the node at build time, not at lint time.
. /etc/kairos-release
sed -i "s/^KAIROS_VERSION=.*/KAIROS_VERSION=\"${KAIROS_VERSION}-mack.${GIT_SHA}\"/" /etc/kairos-release
