#!/bin/bash

set -ouex pipefail

# In GitHub CI for arm64, this fails with a cryptic:
# error: Linting: Function not implemented (os error 38)
if [ "${TARGETPLATFORM}" = "linux/amd64" ]; then
    bootc container lint
fi