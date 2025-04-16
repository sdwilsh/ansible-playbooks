#!/usr/bin/env sh

set -e

ansible-galaxy collection install --upgrade -p external_collections -r requirements.yml
ansible-galaxy role install --force-with-deps -p external_roles -r requirements.yml

# bertvv.bind appears to be dead.  In order to buy myself time to move off of
# it, this terrible hack exists.
find external_roles/bertvv.bind/ -type f -exec sed -i 's/ ipaddr(/ ansible.utils.ipaddr(/g' {} \;

if [ -z "${CI}" ]; then
    ansible-playbook plays/kairos/get_kubeconfig.yml
fi
