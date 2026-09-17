#!/usr/bin/env bash
# Tests for the in-box git worktree guard hook.
set -euo pipefail
. "$(dirname "$0")/assert.sh"
GUARD="$AGENTBOX_ROOT/image/guard-git-worktree.sh"
command -v jq >/dev/null || { echo "jq is required for this test"; exit 1; }

verdict() {  # RAW_STDIN -> deny | allow (with exit-code check)
  local out rc=0
  out="$(printf '%s' "$1" | bash "$GUARD" 2>/dev/null)" || rc=$?
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
    [ "$rc" -eq 2 ] && echo deny || echo "deny(exit $rc)"
  else
    [ "$rc" -eq 0 ] && echo allow || echo "allow(exit $rc)"
  fi
}
payload() { jq -nc --arg c "$1" '{tool_input:{command:$c}}'; }
check() { assert_eq "$1: $3" "$2" "$(verdict "$(payload "$3")")"; }

check deny deny "git worktree prune"
check deny deny "git worktree remove ../feature"
check deny deny "git worktree move a b"
check deny deny "git -C /repo worktree prune"
check deny deny "GIT_DIR=/x git worktree prune"
check deny deny "cd /tmp && git   worktree prune -v"
check deny deny 'bash -c "git worktree remove --force x"'
check deny deny "git worktree \"prune\""
check deny deny "git worktree 'remove' ../x"
check deny deny "git worktree \\prune"
check allow allow "git worktree list"
check allow allow "git worktree add ../feature feature"
check allow allow "git branch -D remove-me"
check allow allow "npm run worktree-prune-docs"
check allow allow "ls"

# Other payload shapes: an argv array, or the command under an unexpected field.
assert_eq "argv-array command is denied" deny "$(verdict '{"tool_input":{"command":["bash","-lc","git worktree prune"]}}')"
assert_eq "unexpected field name is still scanned" deny "$(verdict '{"tool_input":{"cmd":"git worktree remove x"}}')"
assert_eq "harmless payload with odd shape is allowed" allow "$(verdict '{"tool_input":{"cmd":"ls"}}')"

# Without jq the raw payload is still scanned (fail closed).
NOJQ="$(mktemp -d)"
for t in bash cat grep printf; do ln -s "$(command -v "$t")" "$NOJQ/$t"; done
nojq() { printf '%s' "$1" | PATH="$NOJQ" "$NOJQ/bash" "$GUARD" >/dev/null 2>&1 && echo allow || echo deny; }
assert_eq "no jq: destructive command denied" deny "$(nojq "$(payload "git worktree prune")")"
assert_eq "no jq: harmless command allowed" allow "$(nojq "$(payload "git status")")"
rm -rf "$NOJQ"

# Fail closed: unparseable input is scanned raw.
assert_eq "malformed JSON with a destructive command is denied" deny "$(verdict '{not json git worktree prune')"
assert_eq "malformed JSON without one is allowed" allow "$(verdict '{not json ls')"
assert_eq "empty input is allowed" allow "$(verdict '')"

finish
