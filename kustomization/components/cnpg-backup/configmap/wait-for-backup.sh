#!/bin/bash

set -eoux pipefail

if [ -z "${BACKUP_RESOURCE}" ]; then
    echo "BACKUP_RESOURCE must be set!"
    exit 1
fi

get_backup_phase() {
    kubectl \
        get \
        backups.postgresql.cnpg.io \
        "${BACKUP_RESOURCE}" \
        -o jsonpath='{.status.phase}' \
        2>&1 || echo "unknown"
}

output=$(get_backup_phase)
while [ "${output}" != "completed" ]
do
    if [ "${output}" == "failed" ]; then
        echo "Error: Backup of ${BACKUP_RESOURCE} failed!"
        exit 1
    fi

    if [ "${output}" == "unkown" ]; then
        echo "Warning: Unknown error while trying to get status..."
        exit 1
    fi

    echo "Sleeping for five seconds since the backup of ${BACKUP_RESOURCE} is not yet complete..."
    sleep 5s

    output=$(get_backup_phase)
done

echo "Backup of ${BACKUP_RESOURCE} is complete!"
