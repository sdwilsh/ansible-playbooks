#!/bin/sh

set -e

if [ -z "${POD_IP}" ]; then
    echo "POD_IP must be set!"
    exit 1
fi

config_dest=/etc/nut/local/upsd.conf
echo "Creating ${config_dest}..."
printf '%s\n' "
LISTEN ${POD_IP} 3493
" > $config_dest

echo "Successfully setup configuration at ${config_dest}"
