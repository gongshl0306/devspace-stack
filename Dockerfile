# syntax=docker/dockerfile:1

# =============================================================================
# DevSpace MCP Server
# Self-hosted MCP server: https://github.com/Waishnav/devspace
#
# Multi-stage build:
#   build   - install the DevSpace CLI + compile its native deps
#   runtime - lean image with git/bash/curl, non-root user, healthcheck
# =============================================================================

# ---- Build stage: install the DevSpace CLI + native dependencies -----------
FROM node:22-bookworm-slim AS build

# Toolchain needed to compile native modules (better-sqlite3, node-pty).
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*

# Install the DevSpace CLI globally. Pin the version for reproducibility.
ARG DEVSPACE_VERSION=1.0.7
RUN npm install -g "@waishnav/devspace@${DEVSPACE_VERSION}" \
    && npm cache clean --force

# ---- Runtime stage ----------------------------------------------------------
FROM node:22-bookworm-slim AS runtime

# Runtime deps: git (worktrees), bash (shell tool), curl (healthcheck/debug).
RUN apt-get update \
    && apt-get install -y --no-install-recommends git bash curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# The node base image ships a 'node' user (UID 1000, GID 1000) — the same UID
# as a typical Linux host user, so files written into the mounted workspace keep
# the host user's ownership. We run as that existing user (no new user needed).
# If your host user is not UID 1000, adjust the build to create a matching user.
ENV HOME=/home/node \
    DEVSPACE_CONFIG_DIR=/home/node/.devspace \
    DEVSPACE_STATE_DIR=/home/node/state \
    DEVSPACE_WORKTREE_ROOT=/home/node/worktrees
RUN mkdir -p /home/node/.devspace /home/node/state /home/node/worktrees /workspace \
    && chown -R node:node /home/node /workspace

# Copy the globally installed CLI and its node_modules from the build stage.
COPY --from=build /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=build /usr/local/bin /usr/local/bin

WORKDIR /workspace
USER node

EXPOSE 7676

# /healthz returns {"ok":true,"name":"devspace"} without authentication.
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1:7676/healthz || exit 1

CMD ["devspace", "serve"]
