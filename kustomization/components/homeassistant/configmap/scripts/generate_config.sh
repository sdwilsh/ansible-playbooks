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

source /scripts/generate_http_config.sh
source /scripts/generate_recorder_config.sh

echo "Successfully setup configuration at ${config_dest}"
