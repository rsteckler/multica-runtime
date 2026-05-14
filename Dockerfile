# syntax=docker/dockerfile:1.7
#
# multica-runtime — container image that runs the Multica agent daemon in k8s.
#
# Bakes in the stable, well-known agent toolchain (claude code, gh, railway,
# modal, posthog-cli, plus standard build/dev tools). Niche CLIs that aren't
# baked can still be installed at runtime into $HOME/.local/bin — that path
# is on a PVC in the helm chart, so installs persist across pod restarts.
#
# Pinned to a specific Multica release so the daemon's wire protocol matches
# the server it's talking to. Bump MULTICA_VERSION (and tag this image
# accordingly) when you upgrade the server.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    PATH="/home/multica/.local/bin:/usr/local/go/bin:/home/multica/go/bin:${PATH}"

# ---------------------------------------------------------------------------
# Base system + standard dev tools.
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg lsb-release software-properties-common \
        git make build-essential pkg-config \
        unzip zip xz-utils \
        jq ripgrep fd-find fzf tree htop \
        tmux vim nano less \
        openssh-client sudo locales tzdata \
        python3 python3-pip python3-venv python-is-python3 \
        postgresql-client redis-tools \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Node.js 22 LTS (NodeSource). claude code, railway, posthog-cli are npm pkgs.
# ---------------------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable

# ---------------------------------------------------------------------------
# GitHub CLI — official apt repo.
# ---------------------------------------------------------------------------
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Go — same major as the multica server (1.26). Useful for `go install` of
# agent-side tooling and for building from source inside a task workspace.
# ---------------------------------------------------------------------------
ARG GO_VERSION=1.26.1
RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in amd64) GOARCH=amd64 ;; arm64) GOARCH=arm64 ;; *) echo "unsupported arch $ARCH" >&2; exit 1 ;; esac \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz

# ---------------------------------------------------------------------------
# uv — fast Python package manager. Installed system-wide so it works for
# every user. Agents tend to reach for `uv pip install` and `uv tool install`.
# ---------------------------------------------------------------------------
RUN curl -fsSL https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR=/usr/local/bin sh

# ---------------------------------------------------------------------------
# npm-based CLIs:
#   - @anthropic-ai/claude-code  → `claude`           (Claude Code)
#   - @railway/cli                → `railway`          (Railway)
#   - posthog-cli                 → `posthog-cli`      (PostHog)
# ---------------------------------------------------------------------------
RUN npm install -g --no-fund --no-audit \
        @anthropic-ai/claude-code \
        @railway/cli \
        posthog-cli \
    && npm cache clean --force

# ---------------------------------------------------------------------------
# Modal CLI — pip package. Installed into a system venv to avoid PEP-668
# "externally-managed environment" errors on Ubuntu 24.04.
# ---------------------------------------------------------------------------
RUN python3 -m venv /opt/modal-venv \
    && /opt/modal-venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/modal-venv/bin/pip install --no-cache-dir modal \
    && ln -s /opt/modal-venv/bin/modal /usr/local/bin/modal

# ---------------------------------------------------------------------------
# Multica CLI — pinned release tarball from GitHub. The daemon's wire format
# tracks the server, so this version should match the server image's tag.
# ---------------------------------------------------------------------------
ARG MULTICA_VERSION=0.2.29
RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in amd64) MARCH=amd64 ;; arm64) MARCH=arm64 ;; *) echo "unsupported arch $ARCH" >&2; exit 1 ;; esac \
    && curl -fsSL "https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}/multica-cli-${MULTICA_VERSION}-linux-${MARCH}.tar.gz" \
        -o /tmp/multica.tar.gz \
    && tar -C /usr/local/bin -xzf /tmp/multica.tar.gz multica \
    && chmod +x /usr/local/bin/multica \
    && rm /tmp/multica.tar.gz \
    && multica version

# ---------------------------------------------------------------------------
# Non-root user. UID/GID 1000 matches the helm chart's fsGroup so PVCs are
# writable. ubuntu:24.04 ships a default `ubuntu` user at uid/gid 1000 —
# delete it first so the GID is free. NOPASSWD sudo is intentional —
# agents occasionally need apt-get to install something niche; the user
# explicitly opted into a "let it install things" runtime.
# ---------------------------------------------------------------------------
RUN userdel --remove ubuntu 2>/dev/null || true \
    && groupadd --gid 1000 multica \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash multica \
    && echo "multica ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/multica \
    && chmod 0440 /etc/sudoers.d/multica \
    && install -d -o multica -g multica /home/multica/.local/bin \
                                        /home/multica/.multica \
                                        /home/multica/multica_workspaces

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

USER multica
WORKDIR /home/multica

# Daemon health server (see MULTICA_HEALTH_PORT in CLI_AND_DAEMON.md).
EXPOSE 19514

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
