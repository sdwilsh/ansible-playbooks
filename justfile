# Lists all targets
default:
    just --list

# Run hadolint on all `Dockerfile`s
hadolint:
    #!/usr/bin/env bash
    set -eou pipefail
    find . -type f -name "Dockerfile*" -not -path "./external_*" | while read -r file; do
        echo -n "Running \`hadolint\` on ${file}..."
        hadolint ${file}
        echo "{{BOLD + GREEN}}OK{{NORMAL}}"
    done

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

# Run shellcheck on all shell files
shellcheck:
    #!/usr/bin/env bash
    set -eou pipefail
    find . -type f -name "*.sh" -not -path "./external_*" -not -path "*/charts/*" | while read -r file; do
        echo -n "Running \`shellcheck -x\` on ${file}..."
        shellcheck -x ${file}
        echo "{{BOLD + GREEN}}OK{{NORMAL}}"
    done
