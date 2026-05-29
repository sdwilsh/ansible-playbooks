#!/bin/bash

set -e
set -x

if [ -z "${BACKUP_RESOURCE}" ]; then
    echo "BACKUP_RESOURCE must be set!"
    exit 1
fi

while $(kubectl get backups.postgresql.cnpg.io "${BACKUP_RESOURCE}" -o jsonpath='{.status.phase}') != "complete"
do
    sleep 5s
done
