# vergil

Runs the FastFlowLM server (`flm`) on an AMD NPU.  The server answers
`/v1/audio/transcriptions`.  `check-transcription.sh` is the `startupProbe`
and the `livenessProbe`, and the end-to-end test uses it too.

## Build and test

```
just build-vergil
CONTAINER_RUNTIME=podman images/vergil/test/e2e.py vergil:latest
```

The test needs `python3` and a container runtime.  It uses `docker` when
`CONTAINER_RUNTIME` has no value.  The test needs no NPU.

## Before a version change

Renovate changes `FLM_VERSION` and `FLM_SHA256` together.  Keep the two lines
next to each other and in that order, or the update stops.

A new archive can hold a different set of libraries.  The build compares the
multiarch mirror against the XRT libraries, because the `flm` wrapper writes a
symbolic link for each name that the mirror does not hold, and the pod gives
the container a read-only root.
