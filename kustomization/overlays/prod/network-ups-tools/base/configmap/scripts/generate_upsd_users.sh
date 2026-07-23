#!/bin/sh

set -e

if [ -z "${NUT_ADMIN_PASSWORD_FILE}" ]; then
    echo "NUT_ADMIN_PASSWORD_FILE must be set!  This should point to a file containing the admin user password"
    exit 1
else
  admin_password=$(cat "${NUT_ADMIN_PASSWORD_FILE}")
fi

if [ -z "${NUT_OBSERVER_PASSWORD_FILE}" ]; then
    echo "NUT_OBSERVER_PASSWORD_FILE must be set!  This should point to a file containing the observer user password"
    exit 1
else
  observer_password=$(cat "${NUT_OBSERVER_PASSWORD_FILE}")
fi

config_dest=/etc/nut/local/upsd.users
echo "Creating ${config_dest}..."
printf '%s\n' "
[admin]
  actions = set
  actions = fsd
  instcmds = all
  password = \"${admin_password}\"
  upsmon primary

[observer]
  password = \"${observer_password}\"
  upsmon secondary
" > $config_dest

echo "Successfully setup configuration at ${config_dest}"
