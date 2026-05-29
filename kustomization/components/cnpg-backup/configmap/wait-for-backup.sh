#!/bin/bash

set -eoux pipefail

if [ -z "${BACKUP_RESOURCE}" ]; then
    echo "BACKUP_RESOURCE must be set!"
    exit 1
fi

output=$( \
    kubectl \
        get \
        backups.postgresql.cnpg.io \
        "${BACKUP_RESOURCE}" \
        -o jsonpath='{.status.phase}' \
    ) || exit $?
while [ "${output}" != "completed" ]
do
    echo "Sleeping for five seconds since the backup of ${BACKUP_RESOURCE} is not yet complete..."
    sleep 5s
    output=$( \
        kubectl \
            get \
            backups.postgresql.cnpg.io \
            "${BACKUP_RESOURCE}" \
            -o jsonpath='{.status.phase}' \
        ) || exit $?
done

echo "Backup of ${BACKUP_RESOURCE} is complete!"
