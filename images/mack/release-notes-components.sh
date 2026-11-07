#!/usr/bin/env sh
set -eu

# Print the Kairos components for the release notes.  This script runs in the
# image.  Each line contains a label, a tab, and a version.
# Source: images/kairos-fedora/release-notes-components.sh in marinatedconcrete/config.

kairos_release=/etc/kairos-release

read_var() {
    key="$1"
    value="$(sed -n "s/^${key}=//p" "$kairos_release" | head -n 1)"
    value="${value%\"}"
    value="${value#\"}"
    printf '%s' "$value"
}

row() {
    [ -n "$2" ] || return 0
    printf '%s\t%s\n' "$1" "$2"
}

[ -f "$kairos_release" ] || exit 0

row "Kairos Agent" "$(kairos-agent --version 2>/dev/null |
    sed -n 's/^kairos-agent version //p' | head -n 1)"
row "kairos-init" "$(read_var KAIROS_INIT_VERSION)"
row "Kubernetes ($(read_var KAIROS_SOFTWARE_VERSION_PREFIX))" \
    "$(read_var KAIROS_SOFTWARE_VERSION)"
row "Variant" "$(read_var KAIROS_VARIANT)"
row "Model" "$(read_var KAIROS_MODEL)"
