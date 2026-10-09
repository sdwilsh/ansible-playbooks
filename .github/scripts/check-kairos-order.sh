#!/usr/bin/env bash
# Fail unless the control plane on the base ref already uses the workers' image.
set -euo pipefail

base_ref="${1:-origin/main}"
dir=kustomization/overlays/prod/kairos-operator/nodeopupgrade

image() {
  grep -m1 -oE 'image: +\S+' | sed -E 's/image: +//'
}

workers=$(image <"${dir}/workers.yml")
control_plane=$(git show "${base_ref}:${dir}/controlplane.yml" | image)

if [[ "${workers}" != "${control_plane}" ]]; then
  echo "Workers use ${workers}"
  echo "Control plane on ${base_ref} uses ${control_plane}"
  echo "Merge the control plane update first."
  exit 1
fi
echo "Control plane on ${base_ref} already uses ${workers}."
