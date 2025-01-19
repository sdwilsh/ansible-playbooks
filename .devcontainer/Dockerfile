# renovate: datasource=docker depName=python
ARG PYTHON_VERSION=3.13
FROM mcr.microsoft.com/devcontainers/python:1-${PYTHON_VERSION}

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
