#!/usr/bin/env bash
# agentbox entrypoint: per-launch setup, then an interactive zsh. No `set -e`: a
# failed setup step prints a warning but still gives you the shell to fix it from.
set -uo pipefail
# shellcheck source=/dev/null
. /etc/agentbox/zshrc

warn() { printf 'agentbox: WARN: %s\n' "$*" >&2; }
mcp_cli="$(npm root -g)/@playwright/mcp/cli.js"

# --- Codex login from a token (first launch of this box only) ------------------------
if [ -n "${CODEX_ACCESS_TOKEN:-}" ]; then
  if [ -f "$HOME/.codex/auth.json" ]; then
    echo "agentbox: CODEX_ACCESS_TOKEN is set but ~/.codex/auth.json already exists and wins; remove it to re-seed from the token." >&2
  else
    printf '%s' "$CODEX_ACCESS_TOKEN" \
      | command codex login -c 'cli_auth_credentials_store="file"' --with-access-token >/dev/null 2>&1 \
      || warn "codex login with CODEX_ACCESS_TOKEN failed; run 'codex login' in the box"
  fi
fi

# --- Git -------------------------------------------------------------------------------
# ~/.gitconfig comes fresh from the image each launch (it only includes your identity).
# The box has no SSH keys, so rewrite GitHub SSH remotes to HTTPS and let gh serve
# GH_TOKEN as the credential.
if [ -n "${GH_TOKEN:-}" ]; then
  for prefix in "git@github.com:" "ssh://git@github.com/" "ssh://git@github.com:22/"; do
    git config --global --add url."https://github.com/".insteadOf "$prefix"
  done
  gh auth setup-git >/dev/null 2>&1 || warn "gh auth setup-git failed; git push over HTTPS may prompt"
fi
# No signing keys in the box, and the mounted repo belongs to a host UID.
git config --global commit.gpgsign false
git config --global --add safe.directory /workspace
# Every sibling worktree's directory is missing inside the box, so `git gc` (including
# the automatic one after commits and fetches) would prune their metadata.
git config --global gc.worktreePruneExpire never

# pre-commit is available but never installed automatically: `pre-commit install`
# would write a hook into the HOST repo that points at this container's Python.
if [ -f /workspace/.pre-commit-config.yaml ]; then
  echo "agentbox: this repo uses pre-commit. Run 'pre-commit run' before committing from the box."
fi

# --- Playwright MCP --------------------------------------------------------------------
# Chromium needs --no-sandbox as a non-root container user. Register it here, not in a
# repo file, so host sessions keep Chromium's sandbox. Claude: local scope overrides a
# same-named server in the repo's .mcp.json. Codex: user config in the box's volume.
# opencode: set in /etc/opencode (managed). Remove first so re-runs stay idempotent.
command claude mcp remove playwright --scope local >/dev/null 2>&1 || true
command claude mcp add playwright --scope local -- node "$mcp_cli" --browser chromium --no-sandbox >/dev/null 2>&1 \
  || warn "could not register the Playwright MCP with Claude Code"
command codex mcp remove playwright >/dev/null 2>&1 || true
command codex mcp add playwright -- node "$mcp_cli" --browser chromium --no-sandbox >/dev/null 2>&1 \
  || warn "could not register the Playwright MCP with Codex"

# Headed Chromium needs a display; DISPLAY=:99 is set in the image.
if ! pgrep -x Xvfb >/dev/null 2>&1; then
  Xvfb :99 -screen 0 1280x1024x24 </dev/null >/dev/null 2>&1 &
fi

# --- Project dependencies ----------------------------------------------------------------
agentbox-deps || warn "dependency setup failed (details above). Fix it, then run: agentbox-deps"

cat <<'BANNER'

agentbox ready. Agents run without permission prompts; the container is the boundary.
  claude          Claude Code
  codex           Codex
  opencode        opencode
  agentbox-deps   reinstall project dependencies (--force: even if nothing changed)
  exit            leave (this stops the box, including other shells joined to it)
Only /workspace and the per-box volumes survive exit.

BANNER
# -i: interactive even when stdin isn't a terminal (the integration test pipes commands).
exec zsh -i
