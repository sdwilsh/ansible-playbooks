#!/bin/bash

set -ouex pipefail

rsync -rvK /ctx/signing/ /

policy=/etc/containers/policy.json
jq --slurpfile mack /ctx/signature-policy.json \
    '.transports.docker["ghcr.io/sdwilsh/mack"] = $mack[0]' \
    "$policy" > /tmp/policy.json
cat /tmp/policy.json > "$policy"
rm /tmp/policy.json
