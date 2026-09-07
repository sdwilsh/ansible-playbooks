# Lists all targets
[private]
default:
    @just --list

# Run ansible-lint with the configured profile
[group('lint')]
ansible-lint:
    @ansible-lint --offline

# Syntax-check every playbook under `plays/`, `roles/`, and `site.yml`
[group('lint')]
ansible-syntax-check:
    #!/usr/bin/env bash
    set -eou pipefail

    # A play needs a `hosts:` key.  A role's task/handler/vars file, or an
    # `include_tasks` fragment, does not.  This script uses that key to
    # find real playbooks.  `ansible-lint` already checks the other files.
    #
    # `!vault` and `!unsafe` get a permissive constructor.  This script checks
    # file structure only.  It does not check real values.
    playbooks_output=$(
        find plays roles site.yml -type f \( -name "*.yml" -o -name "*.yaml" \) -print0 \
            | xargs -0 python3 -c '
    import sys, yaml

    class Loader(yaml.SafeLoader):
        pass

    Loader.add_constructor("!vault", lambda loader, node: loader.construct_scalar(node))
    Loader.add_constructor("!unsafe", lambda loader, node: loader.construct_scalar(node))

    failed = False
    for path in sys.argv[1:]:
        try:
            with open(path) as f:
                documents = list(yaml.load_all(f, Loader=Loader))
        except Exception as e:
            print(f"{path}: {e}", file=sys.stderr)
            failed = True
            continue
        for data in documents:
            if isinstance(data, list) and any(isinstance(p, dict) and "hosts" in p for p in data):
                print(path)
                break

    sys.exit(1 if failed else 0)
    '
    )
    playbooks=()
    if [ -n "${playbooks_output}" ]; then
        mapfile -t playbooks <<< "${playbooks_output}"
    fi
    # `-i` gives real groups to plays that target hosts other than `localhost`.
    # `ANSIBLE_DEPRECATION_WARNINGS` quiets a deprecation warning from a
    # vendored role under `.ansible/roles/`.  That role is not ours to fix here.
    ANSIBLE_CONFIG=ansible-ci.cfg ANSIBLE_DEPRECATION_WARNINGS=false \
        ansible-playbook --syntax-check -i prod-inventory "${playbooks[@]}"

# Check that `k8s_scale_down_order` and `k8s_scale_up_order` name the same namespaces,
# with no duplicates
[group('lint')]
ansible-scale-order-check:
    ANSIBLE_CONFIG=ansible-ci.cfg ansible-playbook -i prod-inventory plays/k8s/scale-order-check.yml

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

# Builds the images/mack container's mack-kairos target.
[group('images')]
build-mack-kairos platform="linux/amd64":
    #!/usr/bin/env bash
    set -eou pipefail

    GIT_SHA=unknown
    if [[ -z "$(git status -s)" ]]; then
        GIT_SHA=$(git rev-parse --short HEAD)
    fi

    podman build images/mack --target mack-kairos --platform={{ platform }} --build-arg GIT_SHA="${GIT_SHA}" --tag mack-kairos:latest

# Builds a bootable ISO that installs a new Kairos node.
[group('images')]
build-mack-kairos-iso image="ghcr.io/sdwilsh/mack-kairos:latest":
    #!/usr/bin/env bash
    set -eou pipefail

    mkdir -p output-mack-kairos

    sudo podman run \
        --rm \
        -it \
        --privileged \
        --pull=newer \
        --security-opt label=type:unconfined_t \
        -v ./output-mack-kairos:/output \
        quay.io/kairos/auroraboot:latest \
        build-iso --output /output/ {{ image }}

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

# Builds the images/nut-shutdown-agent container.
[group('images')]
build-nut-shutdown-agent:
    podman build images/nut-shutdown-agent --tag nut-shutdown-agent:latest

# Check that the fixed CoreDNS hosts entries agree with blocky
[group('lint')]
coredns-drift-check:
    #!/usr/bin/env python3
    # The tswn.us server block holds some fixed names.  These names resolve
    # when blocky does not answer.  blocky is the source of truth for them.
    # This check compares the two files.  It fails when the two files do not
    # agree.  It reads files only.  It does not send a query.
    #
    # Do not put two open braces together in this recipe.  just reads them as
    # the start of an expression.
    import ipaddress
    import sys

    import yaml

    SERVER = "kustomization/overlays/prod/kube-system/configmap/coredns/tswn.us.server"
    BLOCKY = "kustomization/overlays/prod/dns/configmap/blocky/config.yml"
    BLOCKY_SVC = "kustomization/overlays/prod/dns/patches/blocky/set_load_balancer_ips.yml"
    ZONE = "tswn.us"
    # These names must stay in the block.  The NodeHosts file no longer holds
    # them, so this file is the only place that keeps them fixed.
    REQUIRED = {
        "auth.tswn.us",
        "code.tswn.us",
        "dockerhub-proxy.hogs.tswn.us",
        "idm.tswn.us",
        "pool.ntp.hogs.tswn.us",
        "s3.tswn.us",
    }

    problems = []

    def address_or_none(text):
        try:
            return ipaddress.ip_address(text)
        except ValueError:
            return None

    # Read the inline hosts entries and the forward upstreams.
    hosts, upstreams, in_hosts = {}, [], False
    for raw in open(SERVER):
        line = raw.split("#")[0].strip()
        if not line:
            continue
        if line.startswith("hosts "):
            in_hosts = True
        elif in_hosts and line == "}":
            in_hosts = False
        elif line.startswith("forward "):
            upstreams = line.split()[2:]
        elif in_hosts:
            fields = line.split()
            if fields[0] in ("ttl", "reload", "fallthrough", "no_reverse"):
                continue
            if address_or_none(fields[0]) is None or len(fields) < 2:
                problems.append(f"cannot read this hosts line: {line}")
                continue
            for name in fields[1:]:
                hosts.setdefault(name.rstrip(".").lower(), []).append(fields[0])

    # Read the address of every name that blocky knows.
    custom = yaml.safe_load(open(BLOCKY))["customDNS"]
    mapping = {k.rstrip(".").lower(): v for k, v in (custom["mapping"] or {}).items()}
    cnames, origin = {}, ZONE

    def qualify(name):
        if name.endswith("."):
            return name.rstrip(".").lower()
        return f"{name}.{origin}".lower()

    for raw in (custom.get("zone") or "").splitlines():
        line = raw.split(";")[0].strip()
        if not line:
            continue
        if line.startswith("$ORIGIN"):
            fields = line.split()
            if len(fields) > 1:
                origin = fields[1].rstrip(".").lower()
            continue
        if line.startswith("$"):
            continue
        fields = line.split()
        found = [i for i, f in enumerate(fields) if i and f in ("A", "AAAA", "CNAME")]
        if not found or found[0] + 1 >= len(fields):
            continue
        index = found[0]
        if fields[index] == "CNAME":
            cnames[qualify(fields[0])] = qualify(fields[index + 1])
        else:
            mapping.setdefault(qualify(fields[0]), fields[index + 1])

    def resolve(name, seen=frozenset()):
        """Follow the CNAME chain to an address, as blocky does."""
        if name in seen:
            return None
        if name in mapping:
            return mapping[name]
        if name in cnames:
            return resolve(cnames[name], seen | {name})
        return None

    annotations = yaml.safe_load(open(BLOCKY_SVC))["metadata"]["annotations"]
    vip = annotations["kube-vip.io/loadbalancerIPs"]

    print("Checking CoreDNS hosts entries against blocky...", end="", flush=True)

    if not upstreams:
        problems.append("the block has no forward line")
    for upstream in upstreams:
        if upstream != vip:
            problems.append(f"forward sends to {upstream}, but blocky listens on {vip}")
    for name in sorted(REQUIRED - set(hosts)):
        problems.append(f"{name} is required, but the block does not hold it")
    for name, addresses in sorted(hosts.items()):
        if len(addresses) > 1:
            problems.append(f"{name} has {len(addresses)} entries: {', '.join(addresses)}")
        elif not (name == ZONE or name.endswith(f".{ZONE}")):
            problems.append(f"{name} is outside {ZONE}, so this block never serves it")
        elif (expected := resolve(name)) is None:
            problems.append(f"{name} is {addresses[0]} here, but blocky does not know it")
        elif address_or_none(expected) != address_or_none(addresses[0]):
            problems.append(f"{name} is {addresses[0]} here, but blocky says {expected}")

    if problems:
        print("{{ BOLD + RED }}FAILED{{ NORMAL }}", flush=True)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        sys.exit(1)
    print("{{ BOLD + GREEN }}OK{{ NORMAL }}")

# Validate every Corefile by running coredns against it and checking it stays up
[group('lint')]
coredns-validate:
    #!/usr/bin/env bash
    set -eou pipefail
    # A custom server file reads the NodeHosts file that k3s writes into the
    # `coredns` ConfigMap.  That file is not in this repository.  So give
    # CoreDNS an empty NodeHosts file.  This recipe checks the syntax only.
    stub="$(mktemp)"
    trap 'rm -f "${stub}"' EXIT

    find . -type f \( -name "Corefile" -o -name "*.server" \) -not -path "./.ansible/*" | while read -r file; do
        echo -n "Validating ${file}..."
        name="coredns-validate-$$"
        podman run -d --name "${name}" \
            -v "$(realpath "${file}"):/Corefile:ro,z" \
            -v "${stub}:/etc/coredns/NodeHosts:ro,z" \
            docker.io/coredns/coredns:latest \
            -conf /Corefile > /dev/null
        sleep 3
        running=$(podman inspect "${name}" --format '{{ "{{.State.Running}}" }}')
        logs=$(podman logs "${name}" 2>&1)
        podman rm -f "${name}" > /dev/null
        if [ "${running}" != "true" ]; then
            echo "{{ BOLD + RED }}FAILED{{ NORMAL }}"
            echo "${logs}"
            exit 1
        fi
        echo "{{ BOLD + GREEN }}OK{{ NORMAL }}"
    done

# List decisions from crowdsec.  Useful when debugging access problems.
[group('crowdsec')]
crowdsec-list-decisions:
    kubectl exec -n crowdsec -it deployments/crowdsec-deployment -c crowdsec -- /usr/bin/env cscli decisions list

# Generates/updates resources for Argo CD applications
[group('codegen')]
generate-argo-cd-applications:
    ansible-playbook plays/codegen/argo-cd-applications.yml --extra-vars overlay=prod

# Scale a single namespace up or down
[group('k8s')]
k8s-scale direction namespace:
    ansible-playbook plays/k8s/scale-namespace.yml \
        --extra-vars "direction={{ direction }} namespace={{ namespace }}"

# Check `just` syntax
[group('just')]
justcheck:
    #!/usr/bin/env bash
    set -eou pipefail
    find . -type f -name "justfile" -not -path "./.ansible/*" | while read -r file; do
        echo -n "Running \`just --fmt --check\` on ${file}..."
        just --unstable --fmt --check -f ${file}
        echo "{{ BOLD + GREEN }}OK{{ NORMAL }}"
    done

# Fixes `just` syntax
[group('just')]
justfix:
    #!/usr/bin/env bash
    set -eou pipefail
    find . -type f -name "justfile" -not -path "./.ansible/*" | while read -r file; do
        echo "Running \`just --fmt\` on ${file}..."
        just --unstable --fmt -f ${file}
    done

# Run `hadolint` on all `Dockerfile`s
[group('lint')]
hadolint:
    #!/usr/bin/env bash
    set -eou pipefail
    find . -type f -name "Containerfile*" -not -path "./.ansible/*" | while read -r file; do
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
        --label ostree.commit- \
        --label ostree.final-diffid- \
        --tag "{{ target_image }}:{{ tag }}" | podman load

# Validate `renovate.json` file
[group('lint')]
renovate-validate:
    ~/.local/share/pnpm/global/5/node_modules/.bin/renovate-config-validator

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
    find . -type f -name "*.sh" -not -path "./.ansible/*" -not -path "*/charts/*" | while read -r file; do
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
        podman tag ${IMAGE} "${REGISTRY}{{ target_image }}:${tag}"
    done

    # Show Images
    podman images

[group('longhorn')]
longhorn-allow-trim:
    #!/usr/bin/env bash
    set -eou pipefail

    ansible localhost --module-name include_role --args name=marinatedconcrete.config.longhorn_allow_encrypted_trim
