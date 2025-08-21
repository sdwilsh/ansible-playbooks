# Lists all targets
[private]
default:
    @just --list

# Run ansible-lint with the configured profile
[group('lint')]
ansible-lint:
    @ansible-lint --offline

# Builds the images/loki container for the Raspberry Pi.
[group('images')]
build-loki-image:
    #!/usr/bin/env bash
    set -eou pipefail

    mkdir -p output-loki

    # This must be built rootful...
    sudo podman build \
        images/loki \
        --build-arg PARENT=ghcr.io/sdwilsh/mack:latest-arm64 \
        --platform=linux/arm64 \
        -t loki

    # ...so it can be done rootful here.
    sudo podman run \
        --rm \
        -it \
        --privileged \
        --pull=newer \
        --security-opt label=type:unconfined_t \
        -v ./config.toml:/config.toml:ro \
        -v ./output-loki:/output \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        quay.io/centos-bootc/bootc-image-builder:latest \
        --rootfs ext4 \
        --target-arch=aarch64 \
        --type raw \
        localhost/loki:latest
    
    sudo rm -rf output-loki/image/disk.raw.xz
    sudo xz -z -k -v output-loki/image/disk.raw

    echo "Complete! Now you can run this to install it:"
    echo "sudo arm-image-installer \
    --image=$(pwd)/output-loki/image/disk.raw.xz \
    --target=rpi4 \
    --resizefs \
    --media=/dev/sdXXX"

# Builds the images/mack container.
[group('images')]
build-mack:
    #!/usr/bin/env bash
    set -eou pipefail

    podman build \
        images/mack \
        -t mack

# Builds the images/mack container as a virtual machine.
[group('images')]
build-mack-vm:
    #!/usr/bin/env bash
    set -eou pipefail

    mkdir -p output-mack

    # This must be built rootful...
    sudo podman build \
        images/mack \
        -t mack

    # ...so it can be done rootful here.
    sudo podman run \
        --rm \
        -it \
        --privileged \
        --pull=newer \
        --security-opt label=type:unconfined_t \
        -v ./config.toml:/config.toml:ro \
        -v ./output-mack:/output \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        quay.io/centos-bootc/bootc-image-builder:latest \
        --rootfs ext4 \
        --type qcow2 \
        localhost/mack:latest

# List decisions from crowdsec.  Useful when debugging access problems.
[group('crowdsec')]
crowdsec-list-decisions:
  kubectl exec -n crowdsec -it deployments/crowdsec-deployment -c crowdsec -- /usr/bin/env cscli decisions list

# Generates/updates resources for Argo CD applications
[group('codegen')]
generate-argo-cd-applications:
    ansible-playbook plays/codegen/argo-cd-applications.yml --extra-vars overlay=prod

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
    find . -type f -name "Containerfile*" -not -path "./external_*" | while read -r file; do
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

# Runs the images/mack container in a virtual machine.
[group('images')]
run-mack: build-mack-vm
    #!/usr/bin/env bash
    set -eou pipefail

    qemu-system-x86_64 \
        -M accel=kvm \
        -cpu host \
        -smp 2 \
        -m 4096 \
        -bios /usr/share/OVMF/OVMF_CODE.fd \
        -serial stdio \
        -snapshot output-mack/qcow2/disk.qcow2

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
