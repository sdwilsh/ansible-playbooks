#!/bin/sh

if [ -n "${INCLUDE_PROMETHEUS}" ]; then
    prometheus_dest=/config/prometheus.yaml
    
    echo "Creating ${prometheus_dest}..."
    rm -f $prometheus_dest
    echo "Setting namespace: ${PROMETHEUS_NAMESPACE:-homeassistant}"
    echo "---
# This file is generated in an initContainer, and any modifications will be
# dropped at the next restart!
namespace: ${PROMETHEUS_NAMESPACE:-homeassistant}
" > $prometheus_dest

    echo "prometheus: !include prometheus.yaml" >> "${config_dest:?}"
    echo "Successfully added prometheus configuration to ${config_dest:?}"
fi
