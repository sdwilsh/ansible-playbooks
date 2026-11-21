#!/usr/bin/env bash
# Run a bash snippet in the devcontainer image that CI loaded.
# The image runs as root.  A job owns the workspace under another uid.
# The git variables mark the workspace as safe for root.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <bash snippet>" >&2
    exit 2
fi

exec docker run --rm \
    --env ANSIBLE_CONFIG=ansible-ci.cfg \
    --env CI=1 \
    --env GIT_CONFIG_COUNT=1 \
    --env GIT_CONFIG_KEY_0=safe.directory \
    --env GIT_CONFIG_VALUE_0=/w \
    --env HOME=/home/vscode \
    --user root \
    --volume "${GITHUB_WORKSPACE:-${PWD}}:/w" \
    --workdir /w \
    "${DEVCONTAINER_IMAGE:-devcontainer:ci}" \
    bash -euxo pipefail -c "$1"
