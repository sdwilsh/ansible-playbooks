#!/bin/sh

set -e

if [ -z "${NUT_SNMP_AUTHENTICATION_PASSWORD_FILE}" ]; then
    echo "NUT_SNMP_AUTHENTICATION_PASSWORD_FILE must be set!  This is a file whos contents correspond to NUT's snmp-ups 'authPassword' setting."
    exit 1
else
  snmp_auth_password=$(cat "${NUT_SNMP_AUTHENTICATION_PASSWORD_FILE}")
fi

if [ -z "${NUT_SNMP_AUTHENTICATION_PROTOCOL}" ]; then
    echo "NUT_SNMP_AUTHENTICATION_PROTOCOL must be set!  This corresponds to NUT's snmp-ups 'authProtocol' setting."
    exit 1
fi

if [ -z "${NUT_SNMP_PORT}" ]; then
    echo "NUT_SNMP_PORT must be set!  This corresponds to NUT's snmp-ups 'port' setting."
    exit 1
fi

if [ -z "${NUT_SNMP_PRIVACY_KEY_FILE}" ]; then
    echo "NUT_SNMP_PRIVACY_KEY_FILE must be set!  This is a file whos contents correspond to NUT's snmp-ups 'privPassword' setting."
    exit 1
else
  snmp_priv_password=$(cat "${NUT_SNMP_PRIVACY_KEY_FILE}")
fi

if [ -z "${NUT_SNMP_PRIVACY_PROTOCOL}" ]; then
    echo "NUT_SNMP_PRIVACY_PROTOCOL must be set!  This corresponds to NUT's snmp-ups 'privProtocol' setting."
    exit 1
fi

if [ -z "${NUT_UPS_NAME}" ]; then
    echo "NUT_UPS_NAME must be set!  This is used as the ups.conf section name, which nut_exporter surfaces as the 'ups' label."
    exit 1
fi

config_dest=/etc/nut/local/ups.conf
echo "Creating ${config_dest}..."
printf '%s\n' "
[${NUT_UPS_NAME}]
  driver = snmp-ups
  port = ${NUT_SNMP_PORT}
  snmp_version = v3
  secLevel = authPriv
  secName = readwrite
  authPassword = \"${snmp_auth_password}\"
  authProtocol = ${NUT_SNMP_AUTHENTICATION_PROTOCOL}
  privPassword = \"${snmp_priv_password}\"
  privProtocol = ${NUT_SNMP_PRIVACY_PROTOCOL}
" > $config_dest

echo "Successfully setup configuration at ${config_dest}"
