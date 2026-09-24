#!/usr/bin/env bash
# Compare the pins in versions.env with the latest upstream releases.
#   agentbox versions           report only
#   agentbox versions --apply   rewrite outdated pins in versions.env
# NODE_VERSION and PYTHON_VERSION are deliberate choices and are never auto-bumped.
# Exits 1 if any lookup failed, so an offline run never reports "current".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="${AGENTBOX_VERSIONS_FILE:-$ROOT/versions.env}"
APPLY=0
case "${1:-}" in
  "") ;;
  --apply) APPLY=1 ;;
  *) echo "usage: agentbox update [--apply]" >&2; exit 2 ;;
esac

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "update: ERROR: '$tool' is required" >&2; exit 1; }
done

# source_for KEY -> where its latest version comes from; empty for manual pins.
source_for() {
  case "$1" in
    CLAUDE_CODE_VERSION) echo "npm @anthropic-ai/claude-code" ;;
    CODEX_VERSION) echo "npm @openai/codex" ;;
    OPENCODE_VERSION) echo "npm @opencode/cli" ;;
    PNPM_VERSION) echo "npm pnpm" ;;
    PLAYWRIGHT_MCP_VERSION) echo "npm @playwright/mcp" ;;
    PLAYWRIGHT_VERSION) echo "npm playwright" ;;
    UV_VERSION) echo "github astral-sh/uv" ;;
    BUN_VERSION) echo "github oven-sh/bun" ;;
    GIT_DELTA_VERSION) echo "github dandavison/delta" ;;
    PRE_COMMIT_VERSION) echo "pypi pre-commit" ;;
    NODE_VERSION|PYTHON_VERSION) echo "" ;;
    *) echo "update: ERROR: $FILE has an unknown key '$1'; add it to source_for in $0" >&2; return 1 ;;
  esac
}

# latest KIND NAME -> version string, or a non-zero exit on any failure. Every step
# returns explicitly: callers use this inside `if`, where `set -e` is off.
latest() {
  local v
  case "$1" in
    npm) v="$(curl -fsSL "https://registry.npmjs.org/$2/latest" | jq -er .version)" || return 1 ;;
    github) v="$(curl -fsSL "https://api.github.com/repos/$2/releases/latest" | jq -er .tag_name)" || return 1
      # oven-sh/bun tags releases "bun-v1.4.2": strip the longer "bun-v" prefix BEFORE
      # the bare "v" (order matters), or the pin would become the invalid "bun-v1.4.2".
      # A no-op for repos that tag plain "v1.2.3".
      v="${v#bun-v}"; v="${v#v}" ;;
    pypi) v="$(curl -fsSL "https://pypi.org/pypi/$2/json" | jq -er .info.version)" || return 1 ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$v" | grep -Eq '^[A-Za-z0-9._-]+$' || return 1
  printf '%s' "$v"
}

# Microsoft publishes the -noble image a little after the npm release.
playwright_image_exists() {
  curl -fsSL "https://mcr.microsoft.com/v2/playwright/tags/list" | jq -e --arg t "v$1-noble" '.tags | index($t)' >/dev/null
}

updates=""
failed=0
row() { printf '%-24s %-12s %-12s %s\n' "$@"; }
row KEY PINNED LATEST STATUS
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  key="${line%%=*}"
  pinned="${line#*=}"
  src="$(source_for "$key")" || exit 1
  if [ -z "$src" ]; then
    row "$key" "$pinned" "-" "manual (bump by hand)"
    continue
  fi
  # shellcheck disable=SC2086  # "KIND NAME" splits into two arguments
  if ! newest="$(latest $src 2>/dev/null)"; then
    row "$key" "$pinned" "?" "LOOKUP FAILED ($src)"
    failed=1
    continue
  fi
  status="current"
  if [ "$newest" != "$pinned" ]; then
    status="update available"
    if [ "$key" = PLAYWRIGHT_VERSION ] && ! playwright_image_exists "$newest"; then
      status="waiting (no v$newest-noble image yet)"
    else
      updates="$updates $key=$newest"
    fi
  fi
  row "$key" "$pinned" "$newest" "$status"
done < "$FILE"

echo
if [ "$failed" = 1 ]; then
  echo "Some lookups failed (offline, or rate-limited by GitHub?). Nothing was changed." >&2
  exit 1
fi
if [ -z "$updates" ]; then
  echo "Everything is current."
  exit 0
fi
if [ "$APPLY" != 1 ]; then
  echo "Run 'agentbox versions --apply' to update versions.env."
  exit 0
fi
for kv in $updates; do
  key="${kv%%=*}"
  tmp="$(mktemp)"
  sed "s|^$key=.*|$kv|" "$FILE" > "$tmp" && cat "$tmp" > "$FILE" && rm -f "$tmp"
  echo "  $kv"
done
echo "versions.env updated. Rebuild with: agentbox build"
echo "Read the release notes of anything with a new major version before relying on it."
