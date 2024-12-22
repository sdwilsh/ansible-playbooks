# Lists all targets
default:
    just --list

# Build production overlay with kustomize
kustomize-build:
    #!/usr/bin/env bash
    set -eou pipefail
    find kustomization/overlays/prod -mindepth 1 -maxdepth 1 -type d  | while read -r file; do
        echo -n "Running \`kustomize build --enable-helm\` on ${file}..."
        kustomize build --enable-helm ${file} > /dev/null
        echo "{{BOLD + GREEN}}OK{{NORMAL}}"
    done

# Validate renovate.json file
renovate-validate:
    renovate-config-validator
