#!/bin/sh

if [ -z "${MINIO_ROOT_USER}" ]; then
    echo "MINIO_ROOT_USER must be set!"
    exit 1
fi

if [ -z "${MINIO_ROOT_PASSWORD}" ]; then
    echo "MINIO_ROOT_PASSWORD must be set!"
    exit 1
fi

if [ -z "${POD_IP}" ]; then
    echo "POD_IP must be set!"
    exit 1
fi

minio server /data --console-address "${POD_IP}":9090
