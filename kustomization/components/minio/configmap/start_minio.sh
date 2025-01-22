#!/bin/sh

if [ -z "${MINIO_CONSOLE_ADDRESS}" ]; then
    echo "MINIO_CONSOLE_ADDRESS must be set!"
    exit 1
fi

if [ -z "${MINIO_ROOT_USER}" ]; then
    echo "MINIO_ROOT_USER must be set!"
    exit 1
fi

if [ -z "${MINIO_ROOT_PASSWORD}" ]; then
    echo "MINIO_ROOT_PASSWORD must be set!"
    exit 1
fi

minio server /data --console-address "${MINIO_CONSOLE_ADDRESS}":9090
