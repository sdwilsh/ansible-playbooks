#!/bin/bash

set -eoux pipefail

BARMAN_CLOUD_LAST_READY=$( \
    kubectl get \
        deployments.apps \
        barman-cloud \
        -o jsonpath='{.status.conditions[?(@.reason=="NewReplicaSetAvailable")].lastUpdateTime}' \
)
CNPG_CONTROLLER_LAST_READY=$( \
    kubectl get \
        deployments.apps \
        cnpg-controller-manager \
        -o jsonpath='{.status.conditions[?(@.reason=="NewReplicaSetAvailable")].lastUpdateTime}' \
)
if (( \
    "$(date --date="${BARMAN_CLOUD_LAST_READY}" '+%s')" \
    > \
    "$(date --date="${CNPG_CONTROLLER_LAST_READY}" '+%s')" \
)); then
    echo "Resarting CNPG Controller since Barman Cloud plugin appears to be newer..."
    kubectl rollout restart \
        deployments.apps \
        cnpg-controller-manager
    kubectl rollout status \
        deployments.apps \
        cnpg-controller-manager
fi
