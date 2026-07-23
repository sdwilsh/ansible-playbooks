#!/bin/sh

set -e

snmp_auth_password=$(require_env_file NUT_SNMP_AUTHENTICATION_PASSWORD_FILE "${NUT_SNMP_AUTHENTICATION_PASSWORD_FILE:-}" "This is a file whos contents correspond to NUT's snmp-ups 'authPassword' setting.")
snmp_auth_protocol=$(require_env NUT_SNMP_AUTHENTICATION_PROTOCOL "${NUT_SNMP_AUTHENTICATION_PROTOCOL:-}" "This corresponds to NUT's snmp-ups 'authProtocol' setting.")
snmp_port=$(require_env NUT_SNMP_PORT "${NUT_SNMP_PORT:-}" "This corresponds to NUT's snmp-ups 'port' setting.")
snmp_priv_password=$(require_env_file NUT_SNMP_PRIVACY_KEY_FILE "${NUT_SNMP_PRIVACY_KEY_FILE:-}" "This is a file whos contents correspond to NUT's snmp-ups 'privPassword' setting.")
snmp_priv_protocol=$(require_env NUT_SNMP_PRIVACY_PROTOCOL "${NUT_SNMP_PRIVACY_PROTOCOL:-}" "This corresponds to NUT's snmp-ups 'privProtocol' setting.")
ups_name=$(require_env NUT_UPS_NAME "${NUT_UPS_NAME:-}" "This is used as the ups.conf section name, which nut_exporter surfaces as the 'ups' label.")

write_config /etc/nut/local/ups.conf "
[${ups_name}]
  driver = snmp-ups
  port = ${snmp_port}
  snmp_version = v3
  secLevel = authPriv
  secName = readwrite
  authPassword = \"$(nut_escape "${snmp_auth_password}")\"
  authProtocol = ${snmp_auth_protocol}
  privPassword = \"$(nut_escape "${snmp_priv_password}")\"
  privProtocol = ${snmp_priv_protocol}
"
