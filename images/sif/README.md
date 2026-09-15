# sif Image

This image runs the model servers of one node.  `amd.com/gpu: 1` belongs to a node and does not
divide, so every server shares one container, and s6-overlay supervises them.

`scripts/generate-model-services.sh` writes one s6 service for each record in `MODELS`.  Each
service starts a `llama-server`, and a logger gives the output of that server a prefix.  s6 starts
one dead server again, and the other servers stay up.  `scripts/check-servers.sh` and
`scripts/check-supervisor.sh` are the exec probes.

The image holds the scripts and the `S6_` settings.  A container needs `MODELS`, `POD_IP`, a
writable `/run` and the models on `/models`.

## Build And Test

A tag needs the `localhost/` prefix.  `sif:` is the Singularity transport of
`containers-transports(5)`, so `podman build --tag sif:ci` fails.

```sh
just build-sif
CONTAINER_RUNTIME=podman images/sif/test/e2e.py localhost/sif:latest
```
