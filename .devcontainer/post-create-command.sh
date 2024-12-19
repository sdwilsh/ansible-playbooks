#!/usr/bin/env sh

set -eu

ansible-playbook plays/kairos/get_kubeconfig.yml
