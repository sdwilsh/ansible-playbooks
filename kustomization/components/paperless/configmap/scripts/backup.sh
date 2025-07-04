#!/bin/sh

set -e
set -x

if [ -z "${BACKUP_DESTINATION}" ]; then
    echo "BACKUP_DESTINATION must be set!"
    exit 1
fi

if [ -z "${BACKUP_FILENAME}" ]; then
    BACKUP_FILENAME=paperless-backup
    echo "No BACKUP_FILENAME provided, so defaulting to '${BACKUP_FILENAME}'."
fi

# Generate the backup.
kubectl \
    exec \
    pod/paperless-0 \
    -c paperless \
    -- \
    document_exporter \
        /tmp \
        --compare-checksums \
        --split-manifest \
        --zip \
        --zip-name "${BACKUP_FILENAME}"

# Pull the backup out of the container.
kubectl \
    exec \
    pod/paperless-0 \
    -c paperless \
    -- \
    tar -cf - -C /tmp/ "${BACKUP_FILENAME}".zip \
    | tar xf - -C "${BACKUP_DESTINATION}" "${BACKUP_FILENAME}".zip

# Some some stats in the logs.
ls -la "${BACKUP_DESTINATION}"

# Remove the backup from the original source.
kubectl \
    exec \
    pod/paperless-0 \
    -c paperless \
    -- \
    rm /tmp/"${BACKUP_FILENAME}".zip
