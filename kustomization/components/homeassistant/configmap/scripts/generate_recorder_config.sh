#!/bin/sh

if [ -z "${RECORDER_SCHEME}" ]; then
    echo "RECORDER_SCHEME must be set!  See https://www.home-assistant.io/integrations/recorder/#custom-database-engines"
    exit 1
fi

echo "Using ${RECORDER_SCHEME} scheme for db_url..."

db_url=""

#
# PostgreSQL
#
if [ "${RECORDER_SCHEME}" = "postgresql" ]; then
    if [ -z "${RECORDER_DATABASE_NAME}" ]||
       [ -z "${RECORDER_HOSTNAME}" ]||
       [ -z "${RECORDER_USERNAME}" ]||
       [ -z "${RECORDER_PASSWORD}" ]; then
        echo "RECORDER_DATABASE_NAME, RECORDER_HOSTNAME, RECORDER_USERNAME, and RECORDER_PASSWORD must be set!"
        exit 1
    fi
    db_url="postgresql://${RECORDER_USERNAME}:${RECORDER_PASSWORD}@${RECORDER_HOSTNAME}/${RECORDER_DATABASE_NAME}?client_encoding=utf8"
fi

# Verify that we configured a db_url before writing out a configuration!
if [ -z "${db_url}" ]; then
    echo "Unsupported RECORDER_SCHEME=${RECORDER_SCHEME}"
    exit 1
fi 

recorder_dest=/config/recorder.yaml
echo "Creating ${recorder_dest}..."
rm -f $recorder_dest
echo "---
# This file is generated in an initContainer, and any modifications will be
# dropped at the next restart!
" > $recorder_dest

if [ -n "${RECORDER_AUTO_PURGE}" ]; then
    echo "Setting auto_purge: ${RECORDER_AUTO_PURGE}"
    echo "auto_purge: ${RECORDER_AUTO_PURGE}" >> $recorder_dest
fi

if [ -n "${RECORDER_AUTO_REPACK}" ]; then
    echo "Setting auto_repack: ${RECORDER_AUTO_REPACK}"
    echo "auto_repack: ${RECORDER_AUTO_REPACK}" >> $recorder_dest
fi

if [ -n "${RECORDER_COMMIT_INTERVAL}" ]; then
    echo "Setting commit_interval: ${RECORDER_COMMIT_INTERVAL}"
    echo "commit_interval: ${RECORDER_COMMIT_INTERVAL}" >> $recorder_dest
fi

if [ -n "${RECORDER_DB_MAX_RETRIES}" ]; then
    echo "Setting db_max_retries: ${RECORDER_DB_MAX_RETRIES}"
    echo "db_max_retries: ${RECORDER_DB_MAX_RETRIES}" >> $recorder_dest
fi

if [ -n "${RECORDER_DB_RETRY_WAIT}" ]; then
    echo "Setting db_retry_wait: ${RECORDER_DB_RETRY_WAIT}"
    echo "db_retry_wait: ${RECORDER_DB_RETRY_WAIT}" >> $recorder_dest
fi

echo "Setting db_url: ********"
echo "db_url: ${db_url}" >> $recorder_dest

if [ -n "${RECORDER_PURGE_KEEP_DAYS}" ]; then
    echo "Setting purge_keep_days: ${RECORDER_PURGE_KEEP_DAYS}"
    echo "purge_keep_days: ${RECORDER_PURGE_KEEP_DAYS}" >> $recorder_dest
fi

chmod u=r,g=,o= $recorder_dest

echo "Successfully setup recorder configuration at ${recorder_dest}"

echo "recorder: !include recorder.yaml" >> "${config_dest:?}"
echo "Successfully added recorder configuration to ${config_dest:?}"
