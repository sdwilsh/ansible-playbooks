#!/bin/sh


config_dest=/config/configuration.yaml
echo "Creating ${config_dest}..."
rm -f $config_dest
echo "---
# This file is generated in an initContainer, and any modifications will be
# dropped at the next restart!

# Loads default set of integrations. Do not remove.
default_config:

automation: !include automations.yaml
frontend:
  themes: !include_dir_merge_named themes
scene: !include scenes.yaml
script: !include scripts.yaml
" > $config_dest

# shellcheck source=kustomization/components/homeassistant/configmap/scripts/generate_generic_hygrostat_config.sh
. /scripts/generate_generic_hygrostat_config.sh
# shellcheck source=kustomization/components/homeassistant/configmap/scripts/generate_http_config.sh
. /scripts/generate_http_config.sh
# shellcheck source=kustomization/components/homeassistant/configmap/scripts/generate_plant_config.sh
. /scripts/generate_plant_config.sh
# shellcheck source=kustomization/components/homeassistant/configmap/scripts/generate_prometheus_config.sh
. /scripts/generate_prometheus_config.sh
# shellcheck source=kustomization/components/homeassistant/configmap/scripts/generate_recorder_config.sh
. /scripts/generate_recorder_config.sh

echo "Successfully setup configuration at ${config_dest}"
