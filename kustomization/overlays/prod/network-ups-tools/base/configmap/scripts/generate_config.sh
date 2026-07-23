#!/bin/sh

set -e

# shellcheck source=kustomization/overlays/prod/network-ups-tools/base/configmap/scripts/generate_ups_conf.sh
. /scripts/generate_ups_conf.sh
# shellcheck source=kustomization/overlays/prod/network-ups-tools/base/configmap/scripts/generate_upsd_conf.sh
. /scripts/generate_upsd_conf.sh
# shellcheck source=kustomization/overlays/prod/network-ups-tools/base/configmap/scripts/generate_upsd_users.sh
. /scripts/generate_upsd_users.sh
# shellcheck source=kustomization/overlays/prod/network-ups-tools/base/configmap/scripts/generate_upsmon_conf.sh
. /scripts/generate_upsmon_conf.sh
