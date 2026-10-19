# sif Image

This image runs the model servers of one node.  `amd.com/gpu: 1` belongs to a node and does not
divide, so every server shares one container, and s6-overlay supervises them.

`scripts/generate-model-services.sh` writes one s6 service for each record in `MODELS`.  Each
service starts a `gufo serve`, and a logger gives the output of that server a prefix.  s6 starts
one dead server again, and the other servers stay up.  `scripts/check-servers.sh` and
`scripts/check-supervisor.sh` are the exec probes.

The image holds the scripts and the `S6_` settings.  A container needs `MODELS`, `POD_IP`, a
writable `/run` and the models on `/models`.

`MODELS` takes seven fields for each record, and the last two are optional:
`alias|base URL|shard names|port|context size|extra arguments|kind`.  The kind is `llm` or `asr`,
and empty means `llm`.  The extra arguments must not hold `--host`, `--port`, `-i` or `-p`.  An
`asr` record names a model directory, and its context is optional.

## Build And Test

A stage of the `Containerfile` builds `gufo` with the nix flake of the fork `sdwilsh/gufo`.  The
build uses the commit `GUFO_COMMIT`, which is the tag `GUFO_VERSION`.  Renovate changes both
lines together.  The flake lock pins nixpkgs, so it also pins ROCm and the compiler.  The final
image holds the nix closure of the `gufo` package of the fork's flake, and `ps` from the same
nixpkgs.

A tag needs the `localhost/` prefix.  `sif:` is the Singularity transport of
`containers-transports(5)`, so `podman build --tag sif:ci` fails.

```sh
just build-sif
CONTAINER_RUNTIME=podman images/sif/test/e2e.py localhost/sif:latest
```

### As CI Runs It

CI uses docker, and the uid of the runner is not 1000.  podman on a workstation maps the uid of
the user to 0 in the container, which hides a fault in the owner of a directory.  This command
gives the conditions of CI.

```sh
mkdir -p /tmp/e2ework && chmod 0777 /tmp/e2ework
docker build -f images/sif/Containerfile images/sif -t localhost/sif:ci
docker run --rm --user 1001:1001 --group-add "$(getent group docker | cut -d: -f3)" \
  -v /usr/bin/docker:/usr/bin/docker:ro -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD:$PWD" -w "$PWD" -v /tmp/e2ework:/tmp/e2ework -e TMPDIR=/tmp/e2ework \
  -e CONTAINER_RUNTIME=docker --entrypoint python3 docker.io/library/python:3.13-slim \
  images/sif/test/e2e.py localhost/sif:ci
```
