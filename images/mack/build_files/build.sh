#!/bin/bash

set -ouex pipefail

/ctx/packages.sh

# Cleanup
dnf clean all
rm -rf /var/lib/dnf
