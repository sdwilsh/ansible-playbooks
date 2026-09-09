#!/bin/bash

set -eoux pipefail

# This script waits for a CNPG `Backup` to complete.  ArgoCD runs it as a
# PreSync hook.

# A limit stops a sync that can never continue.  Give a Pod its own value
# for this variable if its database needs more time.  This is 30 minutes.
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1800}"

if [ -z "${BACKUP_RESOURCE:-}" ]; then
    echo "BACKUP_RESOURCE must be set!"
    exit 1
fi

get_field() {
    kubectl get "${1}" "${2}" -o "jsonpath=${3}" 2>/dev/null
}

if ! cluster=$(get_field backups.postgresql.cnpg.io "${BACKUP_RESOURCE}" '{.spec.cluster.name}'); then
    echo "Error: Cannot read the ${BACKUP_RESOURCE} backup!"
    exit 1
fi

if [ -z "${cluster}" ]; then
    echo "Error: ${BACKUP_RESOURCE} does not name a cluster!"
    exit 1
fi

if ! kubectl get clusters.postgresql.cnpg.io "${cluster}" -o name > /dev/null 2>&1; then
    echo "The ${cluster} cluster does not exist yet, so there is no data to back up."
    exit 0
fi

deadline=$(( SECONDS + TIMEOUT_SECONDS ))
while true
do
    if ! phase=$(get_field backups.postgresql.cnpg.io "${BACKUP_RESOURCE}" '{.status.phase}'); then
        echo "Error: Cannot read the status of ${BACKUP_RESOURCE}!"
        exit 1
    fi

    if [ "${phase}" == "completed" ]; then
        break
    fi

    if [ "${phase}" == "failed" ]; then
        echo "Error: Backup of ${BACKUP_RESOURCE} failed!"
        exit 1
    fi

    if [ "${SECONDS}" -ge "${deadline}" ]; then
        echo "Error: Backup of ${BACKUP_RESOURCE} did not complete in ${TIMEOUT_SECONDS} seconds.  Its phase is '${phase}'."
        exit 1
    fi

    echo "Sleeping for five seconds since the backup of ${BACKUP_RESOURCE} is not yet complete..."
    sleep 5s
done

echo "Backup of ${BACKUP_RESOURCE} is complete!"
