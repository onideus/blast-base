# blast-base — shared substrate image for blast containers.
#
# Derived from the anthropics/claude-code reference devcontainer: default-deny
# egress firewall, non-root user, named-volume Claude config.
#
# This image is the boundary, not the toolchain. It ships Node (for the Claude
# Code CLI) and exactly the packages init-firewall.sh needs — nothing more.
# Consumers add their own language layers on top:
#
#     ARG BLAST_BASE=ghcr.io/onideus/blast-base:0.1.0
#     FROM ${BLAST_BASE}
#
# See BLAST-CONTRACT.md for what a consumer must supply.

FROM node:22-slim

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

# Stamped at build time so a session inside the container can report which
# boundary it is running under: `echo $BLAST_BASE_VERSION`.
ARG BLAST_BASE_VERSION=dev
ENV BLAST_BASE_VERSION="$BLAST_BASE_VERSION"

# .source links the published package to this repo, which is what makes it
# inherit the repo's access PERMISSIONS - and the link must exist before the
# first publish for that to apply at all. Visibility is a separate setting from
# permissions; see the README for what it actually did on first publish.
LABEL org.opencontainers.image.source="https://github.com/onideus/blast-base" \
      org.opencontainers.image.description="Shared substrate image for blast containers: default-deny egress firewall, non-root user, named-volume Claude config." \
      org.opencontainers.image.licenses="MIT"

# Core tooling. iptables/ipset/dnsutils/aggregate are required by init-firewall.sh.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    wget \
    unzip \
    procps \
    sudo \
    jq \
    dnsutils \
    aggregate \
    iptables \
    ipset \
    iproute2 \
    less \
    nano \
    gpg \
    apt-transport-https \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Persist command history across rebuilds (named volume mounts here)
RUN mkdir -p /commandhistory && \
    touch /commandhistory/.bash_history && \
    chown -R node:node /commandhistory && \
    echo 'export PROMPT_COMMAND="history -a"' >> /home/node/.bashrc && \
    echo 'export HISTFILE=/commandhistory/.bash_history' >> /home/node/.bashrc

# Claude config dir (named volume mounts here — credentials live in the volume,
# never the host keychain; survives rebuilds, dies with `docker volume rm`)
RUN mkdir -p /workspace /home/node/.claude && \
    chown -R node:node /workspace /home/node/.claude

ENV DEVCONTAINER=true

# Firewall script: node may run ONLY this, as root, nothing else via sudo.
#
# env_keep is load-bearing. sudo's default env_reset would strip every BLAST_*
# variable the consumer sets in containerEnv, and the script would silently fall
# back to its defaults everywhere. The list is enumerated rather than globbed
# because sudoers does not support wildcards here — and an explicit allowlist of
# what crosses the sudo boundary is the safer form anyway.
COPY init-firewall.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/init-firewall.sh && \
    { \
      echo 'Defaults env_keep += "BLAST_REQUIRED_DOMAINS BLAST_OPTIONAL_DOMAINS BLAST_ALLOW_GITHUB BLAST_ALLOW_HOST_NETWORK BLAST_GITHUB_META_URL BLAST_BASE_VERSION"'; \
      echo 'node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh'; \
    } > /etc/sudoers.d/node-firewall && \
    chmod 0440 /etc/sudoers.d/node-firewall && \
    visudo -cf /etc/sudoers.d/node-firewall

USER node
WORKDIR /workspace
