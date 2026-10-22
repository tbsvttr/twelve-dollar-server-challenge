# amd64 Ubuntu 24.04 with the aarch64 cross toolchain and arm64 copies of the
# libraries install.sh pulls in. arm64 binaries (the SQLite PGO trainer, the
# unit tests) run through the host's qemu binfmt handler.
FROM --platform=linux/amd64 ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN sed -i '/^Components:/a Architectures: amd64' /etc/apt/sources.list.d/ubuntu.sources && \
    printf '%s\n' \
      'Types: deb' \
      'URIs: http://ports.ubuntu.com/ubuntu-ports' \
      'Suites: noble noble-updates noble-security' \
      'Components: main universe' \
      'Architectures: arm64' \
      'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' \
      > /etc/apt/sources.list.d/ubuntu-ports.sources && \
    dpkg --add-architecture arm64 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      gcc-aarch64-linux-gnu g++-aarch64-linux-gnu cmake ninja-build git ca-certificates file \
      libc6:arm64 libstdc++6:arm64 libssl-dev:arm64 libgtest-dev:arm64 liburing-dev:arm64 && \
    rm -rf /var/lib/apt/lists/*
