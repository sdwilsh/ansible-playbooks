#!/bin/sh

if [ -n "${INCLUDE_PLANT}" ]; then
    plant_dest=/config/plant.yaml
    
    if [ -f ${plant_dest} ]; then
        echo "${plant_dest} already exists and is not managed.  Leaving it as-is."
    else
        echo "Creating empty ${plant_dest}..."
        echo "---
{}
" > $plant_dest
        echo "Successfully setup empty configuration at ${plant_dest}"
    fi

    echo "plant: !include plant.yaml" >> "${config_dest:?}"
    echo "Successfully added plant configuration to ${config_dest:?}"
fi

