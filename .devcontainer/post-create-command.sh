#!/usr/bin/env sh

set -eu

pip3 install --no-cache-dir -r requirements.txt

ansible-galaxy collection install --upgrade -r requirements.yml
ansible-galaxy role install --force-with-deps -p external_roles -r requirements.yml
