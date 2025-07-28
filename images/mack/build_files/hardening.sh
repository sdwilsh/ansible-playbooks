#!/bin/bash

set -ouex pipefail

TEMPORARY_PACKAGES=(
    ansible
    python3-policycoreutils
)
dnf install --setopt=install_weak_deps=False -y \
    python3-dnf \
    ${TEMPORARY_PACKAGES}

mkdir -p /var/cache/ansible/external_collections
pushd /ctx/ansible
ansible-galaxy collection install --upgrade -r requirements.yml
ansible-playbook tasks.yml -l localhost
popd

# Cleanup
rm -rf ~/.ansible
dnf remove -y ${TEMPORARY_PACKAGES}
