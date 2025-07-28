#!/bin/bash

set -ouex pipefail

# See ssh_selinux_packages from
# https://github.com/dev-sec/ansible-collection-hardening/blob/master/roles/ssh_hardening/vars/Fedora.yml
SSH_HARENDING_PACKAGES=(
    checkpolicy
    python3-policycoreutils
)
TEMPORARY_PACKAGES=(
    ansible
)
dnf install --setopt=install_weak_deps=False -y \
    python3-dnf \
    "${SSH_HARENDING_PACKAGES[@]}" \
    "${TEMPORARY_PACKAGES[@]}"

mkdir -p /var/cache/ansible/external_collections
pushd /ctx/ansible
ansible-galaxy collection install --upgrade -r requirements.yml
ansible-playbook tasks.yml -l localhost
popd

# Cleanup
rm -rf ~/.ansible
dnf remove -y "${TEMPORARY_PACKAGES[@]}"
