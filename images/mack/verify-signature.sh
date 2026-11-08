#!/usr/bin/env bash
set -euo pipefail

# Copy image $1 to $2 with the signature check that mack hosts run.  Both
# arguments use skopeo transport syntax, for example docker://IMAGE.

files="$(cd "$(dirname "$0")/build_files" && pwd)"
policy="$(mktemp)"
trap 'rm -f "${policy}"' EXIT

jq --arg key "${files}/signing/etc/pki/containers/sdwilsh-mack.pub" \
    '{default: [{type: "reject"}], transports: {docker: {"ghcr.io/sdwilsh/mack": map(.keyPath = $key)}}}' \
    "${files}/signature-policy.json" > "${policy}"

skopeo copy \
    --policy "${policy}" \
    --registries.d "${files}/signing/etc/containers/registries.d" \
    "$1" "$2"
