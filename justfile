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
        --build-arg PARENT=ghcr.io/sdwilsh/mack:latest \
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
build-mack platform="linux/amd64":
    #!/usr/bin/env bash
    set -eou pipefail

    MACK_VERSION=unknown
    if [[ -z "$(git status -s)" ]]; then
        MACK_VERSION=$(git rev-parse --short HEAD)
    fi

    podman build images/mack --target mack --platform={{ platform }} --pull=newer --build-arg MACK_VERSION="${MACK_VERSION}" --tag mack:latest

# Builds an ISO that installs the published mack image with no prompts.
[group('images')]
build-mack-iso image="ghcr.io/sdwilsh/mack:latest":
    #!/usr/bin/env bash
    set -eou pipefail

    mkdir -p output-mack

    # bootc-image-builder reads the image from root storage.  It makes the
    # installed host follow the tag, so the image must stay under the tag.
    sudo images/mack/verify-signature.sh docker://{{ image }} containers-storage:{{ image }}

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
        --type anaconda-iso \
        {{ image }}

# Builds the images/mack container's mack-kairos target.
[group('images')]
build-mack-kairos platform="linux/amd64":
    #!/usr/bin/env bash
    set -eou pipefail

    MACK_VERSION=unknown
    if [[ -z "$(git status -s)" ]]; then
        MACK_VERSION=$(git rev-parse --short HEAD)
    fi

    podman build images/mack --target mack-kairos --platform={{ platform }} --build-arg MACK_VERSION="${MACK_VERSION}" --tag mack-kairos:latest

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
        --target mack \
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

# Builds the images/sif container.
[group('images')]
build-sif:
    podman build images/sif --tag localhost/sif:latest

# Check that the fixed CoreDNS hosts entries agree with blocky
[group('lint')]
coredns-drift-check:
    #!/usr/bin/env python3
    # A CoreDNS server file holds some fixed names.  These names resolve when
    # blocky does not answer.  blocky is the source of truth for them.  This
    # check compares the files.  It fails when they do not agree.  It reads
    # files only.  It does not send a query.
    #
    # Do not put two open braces together in this recipe.  just reads them as
    # the start of an expression.
    import glob
    import ipaddress
    import re
    import sys

    import yaml

    OVERLAY = "kustomization/overlays/prod/kube-system"
    SERVERS = f"{OVERLAY}/configmap/coredns/*.server"
    OVERRIDES = f"{OVERLAY}/configmap/coredns/*.override"
    KUSTOMIZATION = f"{OVERLAY}/kustomization.yml"
    BLOCKY = "kustomization/overlays/prod/dns/configmap/blocky/config.yml"
    BLOCKY_SVC = "kustomization/overlays/prod/dns/patches/blocky/set_load_balancer_ips.yml"
    # These names must stay in a server file.  The NodeHosts file no longer
    # holds them, so the server files are the only place that keeps them fixed.
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

    def read_server_file(path, is_override=False):
        """Return the zone, the inline hosts entries and the forward upstreams."""
        zone, hosts, upstreams, in_hosts, policy = None, {}, [], False, None
        for raw in open(path):
            line = raw.split("#")[0].strip()
            if not line:
                continue
            header = re.match(r"^(\S+):53 *\{$", line)
            if header and not in_hosts:
                zone = header.group(1).rstrip(".").lower()
            elif line.startswith("hosts "):
                in_hosts = True
            elif in_hosts and line == "}":
                in_hosts = False
            elif line.startswith("policy "):
                policy = line.split()[1]
            elif line.startswith("forward "):
                upstreams += [f for f in line.split()[2:] if f != "{"]
            elif in_hosts:
                fields = line.split()
                if fields[0] in ("ttl", "reload", "fallthrough", "no_reverse"):
                    continue
                if len(fields) < 2 or address_or_none(fields[0]) is None:
                    problems.append(f"{path}: cannot read this hosts line: {line}")
                    continue
                for name in fields[1:]:
                    hosts.setdefault(name.rstrip(".").lower(), []).append(fields[0])
        if zone is None and not is_override:
            problems.append(f"{path}: no server block header found")
        return zone, hosts, upstreams, policy

    # Read the address of every name that blocky knows.
    custom = yaml.safe_load(open(BLOCKY))["customDNS"]
    mapping = {k.rstrip(".").lower(): v for k, v in (custom["mapping"] or {}).items()}
    cnames, origin = {}, ""

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

    paths = sorted(glob.glob(SERVERS))
    overrides = sorted(glob.glob(OVERRIDES))
    if not paths:
        problems.append(f"no server file matches {SERVERS}")
    # A file that the kustomization does not list never reaches CoreDNS.  Such
    # a file must not satisfy the list of required names.
    listed = yaml.safe_load(open(KUSTOMIZATION))
    generated = set()
    for generator in listed.get("configMapGenerator") or []:
        if generator.get("name") == "coredns-custom":
            generated = {f"{OVERLAY}/{f}" for f in generator.get("files") or []}
    for path in paths + overrides:
        if path not in generated:
            problems.append(f"{path} is not in the configMapGenerator of the kustomization")
    for path in sorted(generated - set(paths) - set(overrides)):
        problems.append(f"{path} is in the kustomization, but the file is missing")

    # An override file replaces the forward plugin of the default server block.
    # It must send every query to blocky first.  A different policy, or a
    # different first server, returns the random behaviour that it corrects.
    for path in overrides:
        _, _, upstreams, policy = read_server_file(path, is_override=True)
        if not upstreams:
            problems.append(f"{path}: the file has no forward line")
        elif upstreams[0] != vip:
            problems.append(f"{path}: the first upstream is {upstreams[0]}, not blocky at {vip}")
        if policy != "sequential":
            problems.append(f"{path}: the policy is {policy}, but it must be sequential")
    seen_names = set()
    for path in paths:
        zone, hosts, upstreams, _ = read_server_file(path)
        seen_names |= set(hosts)
        if not upstreams:
            problems.append(f"{path}: the block has no forward line")
        for upstream in upstreams:
            if upstream != vip:
                problems.append(f"{path}: forward sends to {upstream}, not to blocky at {vip}")
        for name, addresses in sorted(hosts.items()):
            if len(addresses) > 1:
                problems.append(f"{name} has {len(addresses)} entries: {', '.join(addresses)}")
            elif zone and not (name == zone or name.endswith(f".{zone}")):
                problems.append(f"{name} is outside {zone}, so {path} never serves it")
            elif zone and zone.endswith(".arpa"):
                continue
            elif (expected := resolve(name)) is None:
                problems.append(f"{name} is {addresses[0]} here, but blocky does not know it")
            elif address_or_none(expected) != address_or_none(addresses[0]):
                problems.append(f"{name} is {addresses[0]} here, but blocky says {expected}")
    for name in sorted(REQUIRED - seen_names):
        problems.append(f"{name} is required, but no server file holds it")

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

# Generates/updates the `linux-mcp` NetworkPolicy, policy, and `known_hosts` files
[group('codegen')]
generate-linux-mcp:
    ansible-playbook plays/codegen/linux-mcp.yml

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
    git ls-files 'justfile' '*/justfile' | while read -r file; do
        echo -n "Running \`just --fmt --check\` on ${file}..."
        just --unstable --fmt --check -f ${file}
        echo "{{ BOLD + GREEN }}OK{{ NORMAL }}"
    done

# Fixes `just` syntax
[group('just')]
justfix:
    #!/usr/bin/env bash
    set -eou pipefail
    git ls-files 'justfile' '*/justfile' | while read -r file; do
        echo "Running \`just --fmt\` on ${file}..."
        just --unstable --fmt -f ${file}
    done

# Run `go test` on all Go modules
[group('go')]
go-test:
    #!/usr/bin/env bash
    set -eou pipefail
    git ls-files 'go.mod' '*/go.mod' | while read -r file; do
        dir=$(dirname ${file})
        echo "Running \`go test\` in ${dir}..."
        (cd ${dir} && go test ./...)
        echo "{{ BOLD + GREEN }}OK{{ NORMAL }}"
    done

# Run the tests that need the `traefik` binary on all Go modules
[group('go')]
go-traefik-test:
    #!/usr/bin/env bash
    set -eou pipefail
    traefik_bin=$(command -v traefik) || { echo "traefik is not on PATH" >&2; exit 1; }
    git ls-files 'go.mod' '*/go.mod' | while read -r file; do
        dir=$(dirname ${file})
        echo "Running \`go test -tags traefik\` in ${dir}..."
        (cd ${dir} && TRAEFIK_BIN="${traefik_bin}" go test -tags traefik -count=1 -run Traefik ./...)
        echo "{{ BOLD + GREEN }}OK{{ NORMAL }}"
    done

# Run `go vet` on all Go modules
[group('go')]
go-vet:
    #!/usr/bin/env bash
    set -eou pipefail
    git ls-files 'go.mod' '*/go.mod' | while read -r file; do
        dir=$(dirname ${file})
        echo -n "Running \`go vet\` in ${dir}..."
        (cd ${dir} && go vet -tags traefik ./...)
        echo "{{ BOLD + GREEN }}OK{{ NORMAL }}"
    done

# Check `gofmt` formatting on all Go files
[group('go')]
gofmtcheck:
    #!/usr/bin/env bash
    set -eou pipefail
    git ls-files '*.go' | while read -r file; do
        echo -n "Running \`gofmt -l\` on ${file}..."
        test -z "$(gofmt -l ${file})"
        echo "{{ BOLD + GREEN }}OK{{ NORMAL }}"
    done

# Fix `gofmt` formatting on all Go files
[group('go')]
gofmtfix:
    #!/usr/bin/env bash
    set -eou pipefail
    git ls-files '*.go' | while read -r file; do
        echo -n "Running \`gofmt -w\` on ${file}..."
        gofmt -w ${file}
        echo "{{ BOLD + GREEN }}OK{{ NORMAL }}"
    done

# Run `hadolint` on all `Dockerfile`s
[group('lint')]
hadolint:
    #!/usr/bin/env bash
    set -eou pipefail
    git ls-files '*Containerfile*' | while read -r file; do
        echo -n "Running \`hadolint\` on ${file}..."
        hadolint ${file}
        echo "{{ BOLD + GREEN }}OK{{ NORMAL }}"
    done

# Fail on `images:` entries that match no image in a rendered overlay
[group('lint')]
image-pin-check:
    .github/scripts/check-image-pins.py

# Check that each tool the `linux-mcp` policy denies is a tool the server has
[group('lint')]
linux-mcp-validate:
    #!/usr/bin/env bash
    set -eou pipefail
    # The server accepts a tool name that does not exist.  It gives no message,
    # and the rule then has no effect, which permits the tool.  The policy is a
    # generated file, so a name with an error is difficult to see.
    policy="kustomization/components/codegen-linux-mcp-prod/configmap/policy.yml"
    overlay="kustomization/overlays/prod/linux-mcp/kustomization.yml"

    image=$(python3 -c "
    import sys, yaml
    k = yaml.safe_load(open(sys.argv[1]))
    for i in k.get('images', []):
        if i['name'].endswith('linux-mcp-server'):
            print(i['name'] + ':' + i['newTag'])
            break
    " "${overlay}")
    echo -n "Reading the tools of ${image%%@*}..."

    tools=$(podman run --rm --entrypoint sh "${image}" -c '
    python3 -c "
    import ast, pathlib
    base = pathlib.Path(__import__(\"linux_mcp_server\").__file__).parent / \"tools\"
    names = set()
    for f in sorted(base.glob(\"*.py\")):
        for node in ast.walk(ast.parse(f.read_text())):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                for d in node.decorator_list:
                    fn = d.func if isinstance(d, ast.Call) else d
                    if getattr(fn, \"attr\", None) == \"tool\":
                        names.add(node.name)
    print(chr(10).join(sorted(names)))
    "')
    echo "{{ BOLD + GREEN }}OK{{ NORMAL }}"

    rc=0
    for denied in $(grep -oE -- "- -[a-z_]+" "${policy}" | sed "s/^- -//" | sort -u); do
        echo -n "Checking \`${denied}\`..."
        if grep -qx -- "${denied}" <<< "${tools}"; then
            echo "{{ BOLD + GREEN }}OK{{ NORMAL }}"
        else
            echo "{{ BOLD + RED }}FAILED{{ NORMAL }}"
            echo "  The policy denies \`${denied}\`, but the server has no tool with that name."
            echo "  Correct the name in \`plays/codegen/templates/resources/linux-mcp-policy.yml.j2\`."
            rc=1
        fi
    done
    exit "${rc}"

# Build every overlay with `kustomize`
[group('lint')]
kustomize-build:
    #!/usr/bin/env bash
    set -eou pipefail
    find kustomization/overlays -mindepth 2 -maxdepth 2 -type d  | while read -r file; do
        echo -n "Running \`kustomize build --enable-helm\` on ${file}..."
        kustomize build --enable-helm ${file} > /dev/null
        echo "{{ BOLD + GREEN }}OK{{ NORMAL }}"
    done

# Fail when a NetworkPolicy port name maps to more than one number
[group('lint')]
named-port-check:
    .github/scripts/check-named-ports.py

# Test the script that picks the next release version of an image
[group('lint')]
next-calver-version-test:
    .github/scripts/test-next-calver-version.sh

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
    git ls-files '*.sh' ':!*/charts/*' | while read -r file; do
        echo -n "Running \`shellcheck -x\` on ${file}..."
        shellcheck -x ${file}
        echo "{{ BOLD + GREEN }}OK{{ NORMAL }}"
    done

# Check that the devcontainer and the deployment pin the same `traefik` image
[group('lint')]
traefik-pin-check:
    #!/usr/bin/env bash
    set -eou pipefail
    built=$(sed -n 's|^FROM 11notes/traefik:\([^ ]*\) AS traefik$|\1|p' .devcontainer/Containerfile)
    deployed=$(python3 -c 'import sys, yaml; print(*[i["newTag"] for i in yaml.safe_load(open(sys.argv[1]))["images"] if i["name"] == "traefik"])' kustomization/overlays/prod/traefik/kustomization.yml)
    if [ -z "${built}" ] || [ -z "${deployed}" ]; then
        echo "{{ BOLD + RED }}FAIL{{ NORMAL }} could not read a traefik pin: devcontainer='${built}' deployment='${deployed}'" >&2
        exit 1
    fi
    if [ "${built}" != "${deployed}" ]; then
        echo "{{ BOLD + RED }}FAIL{{ NORMAL }} traefik pins differ: devcontainer='${built}' deployment='${deployed}'" >&2
        exit 1
    fi
    echo "{{ BOLD + GREEN }}OK{{ NORMAL }} ${built}"

[group('longhorn')]
longhorn-allow-trim:
    #!/usr/bin/env bash
    set -eou pipefail

    ansible localhost --module-name include_role --args name=marinatedconcrete.config.longhorn_allow_encrypted_trim

# Log in to Proton Mail Bridge again, for example after an "Invalid refresh token" error.
[group('proton')]
proton-bridge-login:
    #!/usr/bin/env bash
    set -eou pipefail

    namespace=proton-mail
    statefulset=proton-bridge-statefulset
    pod=proton-bridge-login
    image=$(kubectl -n "${namespace}" get statefulset "${statefulset}" -o jsonpath='{.spec.template.spec.containers[0].image}')
    overrides=$(jq -n --arg image "${image}" --arg claim "data-${statefulset}-0" --arg pod "${pod}" '{
        spec: {
            containers: [{
                name: $pod,
                image: $image,
                command: ["sleep", "infinity"],
                volumeMounts: [{name: "data", mountPath: "/root"}]
            }],
            volumes: [{name: "data", persistentVolumeClaim: {claimName: $claim}}]
        }
    }')

    # The login needs the bridge volume.  Stop the bridge and pause its Argo CD auto-sync.
    # On exit, start the bridge and enable auto-sync again.
    current_context=$(kubectl config view -o jsonpath='{.contexts[?(@.name == "default")].context.namespace}')
    kubectl config set-context --current --namespace argocd
    restore() {
        kubectl -n "${namespace}" delete pod "${pod}" --ignore-not-found
        kubectl -n "${namespace}" scale statefulset "${statefulset}" --replicas=1
        argocd --core app set proton-mail --sync-policy automated
        kubectl config set-context --current --namespace "${current_context}"
    }
    argocd --core app set proton-mail --sync-policy none
    trap restore EXIT

    kubectl -n "${namespace}" scale statefulset "${statefulset}" --replicas=0
    kubectl -n "${namespace}" wait --for=delete "pod/${statefulset}-0" --timeout=180s
    kubectl -n "${namespace}" run "${pod}" --restart=Never --image="${image}" --overrides="${overrides}"
    kubectl -n "${namespace}" wait --for=condition=Ready "pod/${pod}" --timeout=180s
    # Run the CLI through `kubectl exec`.  The container log does not record an exec session.
    echo "In the bridge CLI, run 'login', then 'info' to see the bridge password, then 'exit'."
    kubectl -n "${namespace}" exec -it "${pod}" -- bash /protonmail/entrypoint.sh init
