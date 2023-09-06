VERSION 0.6
FROM alpine

kustomize-build:
    # renovate: datasource=docker depName=registry.k8s.io/kustomize/kustomize versioning=docker
    ARG KUSTOMIZE_VERSION=v5.0.1
    FROM registry.k8s.io/kustomize/kustomize:$KUSTOMIZE_VERSION
    COPY kustomization kustomization
    RUN ls
    RUN find kustomization/overlays/prod/ -mindepth 1 -maxdepth 1 -type d -print | xargs -r -n1 kustomize build > /dev/null

renovate-validate:
    # renovate: datasource=docker depName=renovate/renovate versioning=docker
    ARG RENOVATE_VERSION=34
    FROM renovate/renovate:$RENOVATE_VERSION
    WORKDIR /usr/src/app
    COPY renovate.json .
    RUN renovate-config-validator

lint:
    BUILD +kustomize-build
    BUILD +renovate-validate
