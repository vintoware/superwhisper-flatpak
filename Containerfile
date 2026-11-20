# Build environment for flatpak-builder (see build.sh). Pinned Debian 13 "trixie".
# Runs on the host's architecture; flatpak-builder sandboxes the build with bubblewrap,
# which can't create namespaces under QEMU user-mode emulation.
ARG BASE_IMAGE=debian:13.7
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        flatpak \
        flatpak-builder \
        ostree \
        appstream-compose \
        librsvg2-common \
        elfutils \
        python3 \
        minisign \
        tar \
        zstd \
        git \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
