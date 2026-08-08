# forgejo-runners-restricted Overlay

Runs CI jobs that don't need to build or run nested containers — lint, test, and similar steps — as a single `container` worker under the `restricted` [pod security standard](https://kubernetes.io/docs/concepts/security/pod-security-standards/). No elevated capabilities, `runAsNonRoot: true`, UID/GID ranges start at `1`. This is the default worker for anything that doesn't specifically need `forgejo-runners-privileged`.

## Storage Driver Stays `vfs`

`registries.conf`/`storage.conf` are shared with `forgejo-runners-privileged` via the `forgejo-runner-registry-config` component, but this namespace does **not** override `storage.conf` to `driver = "overlay"`. Overlay mounts need `CAP_SYS_ADMIN`, which this namespace never grants — switching drivers here would just fail. `vfs`'s space inefficiency is an acceptable tradeoff since these jobs aren't expected to build images.

## Same DNS/NetworkPolicy Containment as Privileged

Shares the same CI-only DNS resolver and Traefik entrypoint design as `forgejo-runners-privileged` — see that overlay's README for the full rationale. `connection-manager`/`job-executor` keep broad Traefik access; `workflow-job` is confined to the `websecure-ci` entrypoint.
