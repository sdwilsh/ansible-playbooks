#!/usr/bin/env bash

set -x

export OPKSSH_INSTALL_DIR=/usr/bin
# Fake-out script so it does not run main by default.
export SHUNIT_RUNNING=1
# shellcheck source=/dev/null
source /usr/share/opkssh/install-linux.sh

set -oeu pipefail

check_selinux
