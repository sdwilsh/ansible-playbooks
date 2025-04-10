# Lists all targets
[private]
default:
    @just --list

# Run ansible-lint with the configured profile
[group('lint')]
ansible-lint:
    @ansible-lint --offline

# Generates/updates resources for Argo CD applications
[group('codegen')]
generate-argo-cd-applications:
    ansible-playbook plays/argo-cd-applications.yml --extra-vars overlay=prod

# Generates/updates resources for DNS entries
[group('codegen')]
generate-dns-hogs:
    ansible-playbook plays/dns-update.yml

# Generates/updates resources for postgres-operator managed resources
[group('codegen')]
generate-postgres-logical-backup-resources:
    ansible-playbook plays/codegen/postgres-logical-backup.yml

# Check `just` syntax
[group('just')]
justcheck:
    #!/usr/bin/env bash
    set -eou pipefail
    find . -type f -name "justfile" -not -path "./external_*" | while read -r file; do
        echo -n "Running \`just --fmt --check\` on ${file}..."
        just --unstable --fmt --check -f ${file}
        echo "{{ BOLD + GREEN }}OK{{ NORMAL }}"
    done

# Fixes `just` syntax
[group('just')]
justfix:
    #!/usr/bin/env bash
    set -eou pipefail
    find . -type f -name "justfile" -not -path "./external_*" | while read -r file; do
        echo "Running \`just --fmt\` on ${file}..."
        just --unstable --fmt -f ${file}
    done

# Run `hadolint` on all `Dockerfile`s
[group('lint')]
hadolint:
    #!/usr/bin/env bash
    set -eou pipefail
    find . -type f -name "Dockerfile*" -not -path "./external_*" | while read -r file; do
        echo -n "Running \`hadolint\` on ${file}..."
        hadolint ${file}
        echo "{{ BOLD + GREEN }}OK{{ NORMAL }}"
    done

# Build production overlay with `kustomize`
[group('lint')]
kustomize-build:
    #!/usr/bin/env bash
    set -eou pipefail
    find kustomization/overlays/prod -mindepth 1 -maxdepth 1 -type d  | while read -r file; do
        echo -n "Running \`kustomize build --enable-helm\` on ${file}..."
        kustomize build --enable-helm ${file} > /dev/null
        echo "{{ BOLD + GREEN }}OK{{ NORMAL }}"
    done

# Validate `renovate.json` file
[group('lint')]
renovate-validate:
    renovate-config-validator

# Run `shellcheck` on all shell files
[group('lint')]
shellcheck:
    #!/usr/bin/env bash
    set -eou pipefail
    find . -type f -name "*.sh" -not -path "./external_*" -not -path "*/charts/*" | while read -r file; do
        echo -n "Running \`shellcheck -x\` on ${file}..."
        shellcheck -x ${file}
        echo "{{ BOLD + GREEN }}OK{{ NORMAL }}"
    done
