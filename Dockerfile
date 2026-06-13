# syntax=docker/dockerfile:1
#
# omnidev — universal multi-language clone/build/test sandbox image.
#   Python (+uv) · Go · Node (+pnpm/yarn via corepack) · C/C++ (make/gcc/clang-free)
#   git + git-lfs + ssh + a lean CLI toolset (jq, ripgrep, fd, tree, ...).
#
# Multi-arch: linux/amd64, linux/arm64. Default user is non-root `dev` (uid/gid 1000).
# Base is glibc Debian (NOT Alpine/musl) so manylinux Python wheels and cgo "just work".
#
FROM debian:trixie-slim

# Toolchain versions — override at build time with --build-arg.
ARG GO_VERSION=1.26.4
ARG NODE_VERSION=24.16.0
# uv is copied from its official image below — keep UV_REF in sync with that tag.
ARG UV_REF=0.11.21
# Injected by buildx; falls back to the dpkg arch for a classic `docker build`.
ARG TARGETARCH

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 1) System layer: build toolchain, C dev headers, git/ssh, lean CLI tools.
#    Slowest-changing layer, so it goes first to maximize cache hits.
# ---------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential make cmake pkg-config autoconf automake libtool gcc g++ libc6-dev dpkg-dev \
      python3 python3-dev python3-venv python3-pip \
      git git-lfs openssh-client gnupg ca-certificates curl wget \
      libssl-dev zlib1g-dev libffi-dev libsqlite3-dev libreadline-dev libbz2-dev liblzma-dev \
      libxml2-dev libxslt1-dev \
      jq ripgrep fd-find tree unzip zip xz-utils file patch less vim-tiny nano bash locales tini; \
    ln -sf "$(command -v fdfind)" /usr/local/bin/fd; \
    sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen; locale-gen; \
    git lfs install --system; \
    apt-get clean; rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 2) Go toolchain — official tarball into /usr/local/go (apt's Go lags).
# ---------------------------------------------------------------------------
RUN set -eux; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" -o /tmp/go.tgz; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz; \
    /usr/local/go/bin/go version

# ---------------------------------------------------------------------------
# 3) Node.js — official tarball into /usr/local/node + corepack (pnpm/yarn).
#    Node tarballs use `x64` for amd64; map TARGETARCH. The corepack cache is
#    shared at /usr/local/corepack and later chowned to `dev` so the package
#    managers resolve for the non-root user (and read-only at runtime).
# ---------------------------------------------------------------------------
ENV COREPACK_HOME=/usr/local/corepack
RUN set -eux; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in \
      amd64) node_arch=x64 ;; \
      arm64) node_arch=arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" -o /tmp/node.txz; \
    mkdir -p /usr/local/node; \
    tar -xJf /tmp/node.txz -C /usr/local/node --strip-components=1; \
    rm /tmp/node.txz; \
    export PATH="/usr/local/node/bin:$PATH"; \
    corepack enable --install-directory /usr/local/node/bin pnpm yarn; \
    corepack prepare pnpm@latest yarn@stable --activate; \
    node --version

# ---------------------------------------------------------------------------
# 4) uv + uvx — static binaries copied from the official pinned image
#    (no Rust toolchain pulled in).
# ---------------------------------------------------------------------------
COPY --from=ghcr.io/astral-sh/uv:0.11.21 /uv /uvx /usr/local/bin/

# ---------------------------------------------------------------------------
# 5) Non-root user + writable dirs. Last because it changes most often.
# ---------------------------------------------------------------------------
RUN set -eux; \
    groupadd --gid 1000 dev; \
    useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash dev; \
    mkdir -p /work /home/dev/go /home/dev/.cache/uv /pnpm; \
    chown -R dev:dev /work /home/dev /pnpm /usr/local/corepack

# ---------------------------------------------------------------------------
# 6) Runtime env + PATH (also exported via /etc/profile.d for login shells),
#    OCI labels, tini as PID 1, and drop to the non-root user.
# ---------------------------------------------------------------------------
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore \
    GOPATH=/home/dev/go \
    GOTOOLCHAIN=local \
    PNPM_HOME=/pnpm \
    UV_CACHE_DIR=/home/dev/.cache/uv \
    PATH=/pnpm:/home/dev/go/bin:/usr/local/go/bin:/usr/local/node/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

RUN printf '%s\n' \
    'export PATH="/pnpm:$HOME/go/bin:/usr/local/go/bin:/usr/local/node/bin:/usr/local/bin:$PATH"' \
    > /etc/profile.d/10-omnidev.sh

ARG VCS_REF=dev
ARG BUILD_VERSION=dev
ARG BUILD_DATE=""
LABEL org.opencontainers.image.title="omnidev" \
      org.opencontainers.image.description="Universal multi-language (Python/uv, Go, Node/pnpm/yarn, C/C++) clone-build-test sandbox image" \
      org.opencontainers.image.source="https://github.com/CodeHawaii/omnidev" \
      org.opencontainers.image.url="https://github.com/CodeHawaii/omnidev" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="CodeHawaii" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}"

USER dev
WORKDIR /work

# Build-time smoke test against the real runtime user, PATH and env.
RUN set -eux; \
    go version; \
    node --version; npm --version; pnpm --version; yarn --version; \
    python3 --version; uv --version; \
    git --version; rg --version | head -1; fd --version; jq --version; \
    cc --version | head -1; make --version | head -1; tini --version

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["bash"]
