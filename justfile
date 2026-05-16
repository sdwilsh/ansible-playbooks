# Lists all targets
[private]
default:
    @just --list

# Run ansible-lint with the configured profile
[group('lint')]
ansible-lint:
    @ansible-lint --offline

# Syncs the argocd application.
[group('argocd')]
argocd-argocd:
    #!/usr/bin/env bash
    set -eou pipefail

    current_context=$(kubectl config view -o jsonpath='{.contexts[?(@.name == "default")].context.namespace}')
    kubectl config set-context --current --namespace argocd
    argocd --core app sync argocd --prune
    kubectl config set-context --current --namespace ${current_context}

# Login to argocd cli.
[group('argocd')]
argocd-login:
    #!/usr/bin/env bash
    set -eou pipefail

    argocd login argo-cd.hogs.tswn.us --sso --grpc-web --sso-launch-browser=false

# Syncs the traefik application.
[group('argocd')]
argocd-traefik:
    #!/usr/bin/env bash
    set -eou pipefail

    current_context=$(kubectl config view -o jsonpath='{.contexts[?(@.name == "default")].context.namespace}')
    kubectl config set-context --current --namespace argocd
    argocd --core app sync traefik --prune
    kubectl config set-context --current --namespace ${current_context}

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
build-mack platform="linux/amd64" tag="mack":
    #!/usr/bin/env bash
    set -eoux pipefail

    BUILD_ARGS=()
    LABELS=()
    if [[ -z "$(git status -s)" ]]; then
        GIT_SHA=$(git rev-parse --short HEAD)
        BUILD_ARGS+=("--build-arg" "SHA_HEAD_SHORT=${GIT_SHA}")
        LABELS+=("--label" "io.artifacthub.package.readme-url=https://raw.githubusercontent.com/sdwilsh/mack/${GIT_SHA}/README.md")
        LABELS+=("--label" "org.opencontainers.image.documentation=https://raw.githubusercontent.com/sdwilsh/mack/${GIT_SHA}/README.md")
        LABELS+=("--label" "org.opencontainers.image.source=https://github.com/sdwilsh/mack/${GIT_SHA}/Containerfile")
        LABELS+=("--label" "org.opencontainers.image.url=https://github.com/sdwilsh/mack/tree/${GIT_SHA}")
    fi

    LABELS+=("--label" "io.artifacthub.package.deprecated=false")
    LABELS+=("--label" "io.artifacthub.package.keywords=bootc")
    LABELS+=("--label" "io.artifacthub.package.license=Apache-2.0")
    LABELS+=("--label" "io.artifacthub.package.logo-url=https://avatars.githubusercontent.com/u/656602?s=200&v=4")
    LABELS+=("--label" "io.artifacthub.package.prerelease=false")
    LABELS+=("--label" "org.opencontainers.image.created=$(date -u +%Y\-%m\-%d\T%H\:%M\:%S\Z)")
    LABELS+=("--label" "org.opencontainers.image.description='Mack OS—A bootc-powered core operating system.'")
    LABELS+=("--label" "org.opencontainers.image.title=mack")
    LABELS+=("--label" "org.opencontainers.image.vendor=sdwilsh")
    LABELS+=("--label" "org.opencontainers.image.version={{ tag }}.$(date +%Y%M%d)")

    # This actually builds the image!
    PODMAN_BUILD_ARGS=("${BUILD_ARGS[@]}" "${LABELS[@]}" --platform={{ platform }} --pull=newer --tag "mack:{{ tag }}")

    podman build "${PODMAN_BUILD_ARGS[@]}" images/mack

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

# Split the image for smaller updates.
[group('images')]
rechunk target_image tag:
    #!/usr/bin/env bash
    set -xeuo pipefail
    export CHUNKAH_CONFIG_STR=$(podman inspect "{{ target_image }}:{{ tag }}")
    podman run \
        -e CHUNKAH_CONFIG_STR \
        --mount=type=image,src="{{ target_image }}:{{ tag }}",target=/chunkah \
        --rm \
        quay.io/coreos/chunkah:latest \
    build \
        --compressed \
        --max-layers 128 \
        --prune /sysroot/ \
        --prune /ostree \
        --label ostree.commit- --label ostree.final-diffid- \
        --tag "{{ target_image }}:{{ tag }}" | podman load

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

# Tag Images
[group('images')]
tag-images target_image tag tags registry="":
    #!/usr/bin/env bash
    set -eoux pipefail

    # Get Image, and untag
    IMAGE=$(podman inspect {{ target_image }}:{{ tag }} | jq -r .[].Id)
    podman untag ${IMAGE}

    if [ -z "{{ registry }}"]; then
        REGISTRY=""
    else
        REGISTRY="{{ registry }}/"
    fi

    # Tag Image
    for tag in {{ tags }}; do
        podman tag ${IMAGE} "${REGISTRY}{{ target_image }}:{{ tag }}"
    done

    # Show Images
    podman images

[group('longhorn')]
longhorn-allow-trim:
    #!/usr/bin/env bash
    set -eou pipefail

    ansible localhost --module-name include_role --args name=marinatedconcrete.config.longhorn_allow_encrypted_trim
