#!/bin/bash

set -ouex pipefail

/ctx/packages.sh

/ctx/hardening.sh

# Cleanup
dnf clean all
rm -rf /var/lib/dnf
