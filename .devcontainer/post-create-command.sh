#!/usr/bin/env sh

set -e

ansible-galaxy collection install --upgrade -p external_collections -r requirements.yml
ansible-galaxy role install --force-with-deps -p external_roles -r requirements.yml

if [ -z "${CI}" ]; then
    ansible-playbook plays/kairos/get_kubeconfig.yml
fi
