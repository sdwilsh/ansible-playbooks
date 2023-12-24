#!/bin/sh

if [ -n "${INCLUDE_GENERIC_HYGROSTAT}" ]; then
    generic_hygrostat_dest=/config/generic_hygrostat.yaml
    
    if [ -f ${generic_hygrostat_dest} ]; then
        echo "${generic_hygrostat_dest} already exists and is not managed.  Leaving it as-is."
    else
        echo "Creating empty ${generic_hygrostat_dest}..."
        echo "---
[]
" > $generic_hygrostat_dest
        echo "Successfully setup empty configuration at ${generic_hygrostat_dest}"
    fi

    echo "generic_hygrostat: !include generic_hygrostat.yaml" >> "${config_dest:?}"
    echo "Successfully added generic_hygrostat configuration to ${config_dest:?}"
fi

