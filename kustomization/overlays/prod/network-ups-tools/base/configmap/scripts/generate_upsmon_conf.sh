#!/bin/sh

set -e

if [ -z "${NUT_ADMIN_PASSWORD_FILE}" ]; then
    echo "NUT_ADMIN_PASSWORD_FILE must be set!  This should point to a file containing the admin user password"
    exit 1
else
  admin_password=$(cat "${NUT_ADMIN_PASSWORD_FILE}")
fi

if [ -z "${NUT_UPS_NAME}" ]; then
    echo "NUT_UPS_NAME must be set!  This is used as the ups.conf section name."
    exit 1
fi

if [ -z "${POD_IP}" ]; then
    echo "POD_IP must be set!"
    exit 1
fi

config_dest=/etc/nut/local/upsmon.conf
echo "Creating ${config_dest}..."
printf '%s\n' "
MONITOR ${NUT_UPS_NAME}@${POD_IP} 1 admin \"${admin_password}\" primary
" > $config_dest

echo "Successfully setup configuration at ${config_dest}"
