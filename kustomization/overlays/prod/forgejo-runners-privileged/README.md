# forgejo-runners-privileged Overlay

Runs CI jobs that need to build/run containers: `docker` (docker-in-docker) and `buildah` (rootless-ish image builds). Both workers execute **attacker-controlled code** — anything a PR's `.forgejo/workflows/*.yml` defines — so isolation between this namespace and the rest of the cluster is the main design concern below.

## Two Workers, Two Isolation Strategies

`docker` runs fully `privileged: true` (dind needs it), contained entirely by `runtimeClassName: kata-qemu-runtime-rs` — a kernel escape here still means guest-VM compromise, not host compromise.

`buildah` can't use Kata (see the comment in `worker-buildah.yml`), so instead it runs rootful with `hostUsers: false` (unprivileged-userns UID remap) and a narrow, explicit capability set including `SYS_ADMIN`/`SYS_CHROOT` — the minimum buildah needs to build images without a full container escape hatch. This is a real risk-acceptance, not an oversight: `SYS_ADMIN` in a userns is a historically CVE-prone combination, and it's the sharpest edge in this namespace.

## Storage Driver: `vfs`

`buildah` uses the shared component's `vfs` default — same as `forgejo-runners-restricted`. `vfs` copies the full image on every layer instead of copy-on-write, which is why graphroot is sized generously (100Gi, see below). We briefly tried patching `buildah` to `driver = "overlay"` (it holds `SYS_ADMIN`, and graphroot is a dedicated Longhorn volume so the old "can't nest overlayfs on overlayfs" constraint doesn't apply), and it worked for single, sequential builds — but under concurrent overlay mounts (e.g. a release workflow kicking off several image builds at once) it intermittently failed with `fuse: device /dev/fuse not found`, since native overlay-in-userns isn't reliably usable here and we never provisioned `/dev/fuse` for the fuse-overlayfs fallback. Reverted to `vfs` until that's understood better.

## Ephemeral Scratch on `longhorn-ephemeral-ssd`

Both workers' build scratch (`docker`'s loop-mounted `/var/lib/docker` image, `buildah`'s graphroot) used to be `emptyDir`, which meant CI churn landed on the node's system NVMe. They're now generic ephemeral volumes on `longhorn-ephemeral-ssd` (`numberOfReplicas: 1`, `reclaimPolicy: Delete`) — disposable scratch has no business being replicated or retained, and routing it to the cheaper SSD-tagged disks keeps CI I/O off the NVMe tier.

## CPU Requests and `maxCapacity`

`buildah`'s `workflow` container requests a full `cpu: "4"` so concurrent builds don't stack on and starve each other on one node. `maxCapacity: 2` caps how many can attempt to schedule at once — with `4` it regularly demanded more CPU (up to 16 cores) than the cluster had free, causing scheduling storms; `2` matches realistic sustained headroom.

## DNS and NetworkPolicy: Split by Trust Level

Job pods (`workflow-job`) get a dedicated resolver (`dnsPolicy: None` + `dnsConfig` pointing at `forgejo-runner-dns`) so `code.tswn.us` and `ephemeral-container-registry.hogs.tswn.us` resolve to a Traefik `ClusterIP` (`172.17.255.250`, pinned in the `172.17.255.0/24` static-IP block) bound only to the `websecure-ci` entrypoint. That entrypoint only has Forgejo and ttl.sh registered as routers — so even if a compromised job pod sends an arbitrary Host header, it can't pivot to any other internal service Traefik fronts. `connection-manager`/`job-executor` are **not** attacker-controlled, so they deliberately keep the original broad Traefik access (general `websecure` entrypoint, default cluster DNS) — narrowing their policy to match `workflow-job` was tried and broke task reporting, since their DNS never routes through the CI-only resolver.
