# agentbox: a disposable sandbox image for coding agents (Claude Code, Codex, opencode).
#
# Build it with `agentbox build`, which passes every pin in ../versions.env as a
# --build-arg. The ARGs below have "0.0.0" defaults so Docker accepts the FROM lines;
# a bare `docker build` fails when the FROM can't resolve image:0.0.0.
#
# Layer order is cheapest-to-change LAST: agentbox's own scripts and policy files sit
# at the bottom, so editing them rebuilds in seconds instead of re-running toolchains.

ARG PLAYWRIGHT_VERSION=0.0.0
ARG UV_VERSION=0.0.0
ARG NODE_VERSION=0.0.0
ARG BUN_VERSION=0.0.0

# --- Ingredient stages ------------------------------------------------------------
# Playwright's CDN downloader intermittently hangs at 100% (all bytes sent, stream
# never closed). Copying browsers out of Microsoft's image avoids the download.
FROM mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble AS browsers
# COPY --from cannot expand build args, so uv gets its own named stage.
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv
# bun too: its image is only mined for the binary below.
FROM oven/bun:${BUN_VERSION} AS bun

FROM node:${NODE_VERSION}-bookworm

ARG CLAUDE_CODE_VERSION
ARG CODEX_VERSION
ARG OPENCODE_VERSION
ARG PYTHON_VERSION
ARG PNPM_VERSION
ARG PLAYWRIGHT_MCP_VERSION
ARG GIT_DELTA_VERSION
ARG PRE_COMMIT_VERSION

# Linux hosts: bind mounts keep numeric ownership, so the box user must share your
# UID/GID or files it writes into the repo come back owned by someone else. agentbox
# passes these on Linux; Docker Desktop (macOS) remaps ownership itself, so it doesn't.
ARG HOST_UID=1000
ARG HOST_GID=1000
RUN if [ "$HOST_UID" != 1000 ] || [ "$HOST_GID" != 1000 ]; then \
      groupmod -o -g "$HOST_GID" node && usermod -o -u "$HOST_UID" -g "$HOST_GID" node; \
    fi

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DEVCONTAINER=true \
    SHELL=/bin/zsh \
    EDITOR=nano \
    VISUAL=nano

# --- System packages ---------------------------------------------------------------
# No sudo: nothing in the box runs as root. System packages belong in the image
# (or a project's .agentbox/Dockerfile), not in an agent session.
# python3 (system) is only for host-style hooks that call bare `python`; projects get
# a uv-managed interpreter. xvfb gives headed Chromium a display. gh comes from
# GitHub's apt repo because Debian's package is years behind.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg2 \
  && install -d -m 0755 /etc/apt/keyrings \
  && wget -qO /etc/apt/keyrings/githubcli-archive-keyring.gpg \
       https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y --no-install-recommends \
      build-essential dnsutils fzf gh git iproute2 jq less lsof man-db nano procps \
      python3 ripgrep unzip vim xvfb zsh \
  && ln -sf /usr/bin/python3 /usr/local/bin/python \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# delta: readable git diffs in the terminal.
RUN deb="/tmp/delta.deb" \
  && curl -fsSLo "$deb" "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_$(dpkg --print-architecture).deb" \
  && dpkg -i "$deb" && rm "$deb"

COPY --from=uv /uv /uvx /usr/local/bin/
# Copy the bun binary and create the bunx link explicitly instead of relying on COPY
# resolving the image's bunx symlink. BUN_INSTALL_BIN stays unset on purpose: the box
# runs as non-root `node` (/usr/local/bin isn't writable), so bun's default per-user
# ~/.bun is the correct destination for `bun i -g`.
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
RUN ln -s bun /usr/local/bin/bunx

# Directories the runtime user owns. Each one that a named volume mounts over must
# exist node-owned in the image: Docker initialises a fresh volume from the image
# directory's ownership, otherwise it mounts root-owned and unwritable.
#   ~/.claude, ~/.codex, ~/.local/share/opencode  agent state (per-box volumes)
#   ~/.venvs                                       project virtualenv + uv-downloaded Pythons (per-box volume)
#   ~/.config/opencode                             ephemeral; host config is bound in read-only
RUN mkdir -p /usr/local/share/npm-global /workspace /opt/ms-playwright /opt/uv \
      /home/node/.claude /home/node/.codex /home/node/.local/share/opencode \
      /home/node/.config/opencode /home/node/.venvs \
  && chown -R node:node /usr/local/share/npm-global /workspace /opt/ms-playwright /opt/uv /home/node

WORKDIR /workspace
USER node

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global \
    PATH=/home/node/.local/bin:/usr/local/share/npm-global/bin:$PATH \
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    UV_TOOL_DIR=/opt/uv/tools \
    UV_PROJECT_ENVIRONMENT=/home/node/.venvs/project \
    UV_LINK_MODE=copy \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    DISPLAY=:99

# --- Agent CLIs (one layer each: bumping one version doesn't reinstall the others) ---
RUN npm install -g --no-audit --no-fund @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} && npm cache clean --force
RUN npm install -g --no-audit --no-fund @openai/codex@${CODEX_VERSION} && npm cache clean --force
RUN npm install -g --no-audit --no-fund opencode-ai@${OPENCODE_VERSION} && npm cache clean --force

# --- Toolchains ---------------------------------------------------------------------
# yarn is served by corepack (bundled with Node 24) and honours a project's
# `packageManager` pin. pnpm is installed directly so its version is explicit.
RUN npm install -g --no-audit --no-fund pnpm@${PNPM_VERSION} && npm cache clean --force
RUN uv python install ${PYTHON_VERSION} \
  && uv tool install "pre-commit==${PRE_COMMIT_VERSION}"
# From here on, Pythons that uv downloads for a project (a different .python-version)
# land on the per-box venv volume. In the image layer they would vanish on exit and
# leave the venv pointing at nothing. The baked default stays reachable through the
# ~/.local/bin/python3.x link that `uv python install` created.
ENV UV_PYTHON_INSTALL_DIR=/home/node/.venvs/python

# --- Playwright MCP + browsers ------------------------------------------------------
RUN npm install -g --no-audit --no-fund @playwright/mcp@${PLAYWRIGHT_MCP_VERSION} && npm cache clean --force
USER root
# System libraries Chromium needs (an apt install, not a browser download).
RUN node "$(npm root -g)/@playwright/mcp/node_modules/playwright-core/cli.js" install-deps chromium \
  && rm -rf /var/lib/apt/lists/*
USER node
COPY --from=browsers --chown=node:node /ms-playwright /opt/ms-playwright
# The MCP's bundled playwright-core usually wants a newer Chromium revision than the
# stable image ships; install just that revision next to the stable ones.
RUN node "$(npm root -g)/@playwright/mcp/node_modules/playwright-core/cli.js" install chromium

# ~/.claude.json lives beside the ~/.claude volume, so it would reset every run
# (folder trust, MCP registrations). Symlink it into the volume so it persists.
RUN ln -sf /home/node/.claude/.claude.json /home/node/.claude.json \
  && printf '[include]\n\tpath = /home/node/.gitconfig-host\n' > /home/node/.gitconfig \
  && echo 'source /etc/agentbox/zshrc' > /home/node/.zshrc

# --- agentbox scripts and policy (LAST: edits here rebuild in seconds) ---------------
USER root
COPY --chmod=0755 entrypoint.sh agentbox-deps /usr/local/bin/
COPY --chmod=0755 deps.d/ /opt/agentbox/deps.d/
COPY --chmod=0644 zshrc /etc/agentbox/zshrc
COPY --chmod=0644 codex-profile.toml /etc/agentbox/codex-profile.toml
COPY --chmod=0644 opencode-base.json /etc/agentbox/opencode-base.json
COPY --chmod=0755 guard-git-worktree.sh /etc/agentbox/hooks/guard-git-worktree.sh
# Managed (system) policy for each agent: highest precedence, not overridable by
# project config. Holds only the guardrails; permissive defaults live one tier lower
# so a project's .agentbox/ files can tighten them.
COPY --chmod=0644 claude-managed-settings.json /etc/claude-code/managed-settings.json
COPY --chmod=0644 codex-requirements.toml /etc/codex/requirements.toml
# The opencode managed file names the Playwright MCP by absolute path, resolved now.
COPY --chmod=0644 opencode-managed.json /tmp/opencode-managed.json
RUN mkdir -p /etc/opencode \
  && sed "s#@MCP_CLI@#$(npm root -g)/@playwright/mcp/cli.js#" /tmp/opencode-managed.json > /etc/opencode/opencode.json \
  && chmod 0644 /etc/opencode/opencode.json && rm /tmp/opencode-managed.json \
  && chmod 0755 /etc/agentbox /etc/agentbox/hooks /etc/claude-code /etc/codex /opt/agentbox
USER node

CMD ["/usr/local/bin/entrypoint.sh"]
