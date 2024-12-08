VERSION 0.7
FROM alpine

#
# Depedency Targets
#

helm:
    # renovate: datasource=github-releases depName=helm/helm
    ARG HELM_VERSION=v3.16.3
    ARG TARGETARCH
    ARG TARGETOS
    RUN wget https://get.helm.sh/helm-$HELM_VERSION-$TARGETOS-$TARGETARCH.tar.gz
    RUN tar -xvzf helm-$HELM_VERSION-$TARGETOS-$TARGETARCH.tar.gz
    RUN mv $TARGETOS-$TARGETARCH/helm /usr/local/bin/
    SAVE ARTIFACT /usr/local/bin/helm /binary

tracked-files:
    # renovate: datasource=docker depName=alpine/git
    ARG GIT_VERSION=v2.47.1
    FROM alpine/git:$GIT_VERSION
    RUN mkdir local_files
    RUN mkdir tracked_files
    COPY --dir . local_files
    WORKDIR local_files
    RUN git ls-files | xargs -n1 dirname | uniq | xargs -I {} -n1 mkdir -p ../tracked_files/{}
    RUN git ls-files | xargs -I {} -n1 cp {} ../tracked_files/{}
    SAVE ARTIFACT ../tracked_files /all

#
# Workflows
#

kustomize-build:
    # renovate: datasource=docker depName=registry.k8s.io/kustomize/kustomize
    ARG KUSTOMIZE_VERSION=v5.4.3
    FROM registry.k8s.io/kustomize/kustomize:$KUSTOMIZE_VERSION
    COPY +helm/binary /usr/local/bin/helm
    COPY kustomization kustomization
    RUN find kustomization/overlays/prod/ -mindepth 1 -maxdepth 1 -type d -print | xargs -r -n1 kustomize build --enable-helm > /dev/null

renovate-validate:
    # renovate: datasource=docker depName=renovate/renovate versioning=docker
    ARG RENOVATE_VERSION=39
    FROM renovate/renovate:$RENOVATE_VERSION
    WORKDIR /usr/src/app
    COPY renovate.json .
    RUN renovate-config-validator

shellcheck-lint:
    # renovate: datasource=docker depName=koalaman/shellcheck-alpine versioning=docker
    ARG SHELLCHECK_VERSION=v0.10.0
    FROM koalaman/shellcheck-alpine:$SHELLCHECK_VERSION
    WORKDIR /mnt
    COPY +tracked-files/all .
    RUN find . -name "*.sh" -print | xargs -r -n1 shellcheck -x

lint:
    BUILD +kustomize-build
    BUILD +renovate-validate
    BUILD +shellcheck-lint
