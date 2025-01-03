#!/bin/sh

set -e

if [ -z "${ATUIN_DB_NAME}" ]; then
    echo "Setting ATUIN_DB_NAME to default 'atuin'"
    ATUIN_DB_NAME="atuin"
fi

if [ -z "${ATUIN_DB_USERNAME}" ]; then
    echo "ATUIN_DB_USERNAME must be set!"
    exit 1
fi

if [ -z "${ATUIN_DB_HOST}" ]; then
    echo "ATUIN_DB_HOST must be set!"
    exit 1
fi

if [ -z "${ATUIN_DB_PASSWORD_SECRET_FILE}" ]; then
    echo "ATUIN_DB_PASSWORD_SECRET_FILE must be set!"
    exit 1
fi
echo "Loading password from ${ATUIN_DB_PASSWORD_SECRET_FILE}..."
db_password=$(cat "${ATUIN_DB_PASSWORD_SECRET_FILE}")

if [ -z "${ATUIN_HOST}" ]; then
    echo "ATUIN_HOST must be set, but was somehow unset!"
    exit 1
fi

if [ -z "${ATUIN_OPEN_REGISTRATION}" ]; then
    echo "ATUIN_OPEN_REGISTRATION not set.  Defaulting to 'true'"
    ATUIN_OPEN_REGISTRATION="true"
fi
if [ "${ATUIN_OPEN_REGISTRATION}" != "true" ] && [ "${ATUIN_OPEN_REGISTRATION}" != "false" ]; then
    echo "Invalid value for ATUIN_OPEN_REGISTRATION!  Must be 'true' or 'false'."
    exit 1
fi

if [ -z "${ATUIN_PORT}" ]; then
    echo "ATUIN_PORT must be set, but was somehow unset!"
    exit 1
fi

config_dest=/config/server.toml
echo "Creating ${config_dest}..."
rm -f $config_dest
echo "
host = \"${ATUIN_HOST}\"
port = ${ATUIN_PORT}
open_registration = ${ATUIN_OPEN_REGISTRATION}
db_uri = \"postgres://${ATUIN_DB_USERNAME}:${db_password}@${ATUIN_DB_HOST}/${ATUIN_DB_NAME}\"
" > $config_dest

echo "Successfully setup configuration at ${config_dest}"
