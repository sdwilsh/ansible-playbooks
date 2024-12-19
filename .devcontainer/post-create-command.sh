#!/usr/bin/env sh

set -eu

if [ -z "${CI}" ]; then
    ansible-playbook plays/kairos/get_kubeconfig.yml
fi
