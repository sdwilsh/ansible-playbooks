# renovate: datasource=docker depName=python
ARG PYTHON_VERSION=3.13

FROM ghcr.io/hadolint/hadolint:v2.12.0@sha256:30a8fd2e785ab6176eed53f74769e04f125afb2f74a6c52aef7d463583b6d45e AS hadolint

FROM mcr.microsoft.com/devcontainers/python:1-${PYTHON_VERSION}

COPY --chmod=777 --from=hadolint /bin/hadolint /usr/local/bin/hadolint

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    dnsutils \
    iproute2 \
    iputils-ping \
    libssh-dev \
    vim \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp
COPY requirements.txt requirements.txt
RUN pip3 install --no-cache-dir -r requirements.txt
