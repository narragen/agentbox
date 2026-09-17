#!/bin/bash
# agentbox guard: deny destructive `git worktree` commands inside the sandbox.
# Wired in as a managed PreToolUse hook for Claude Code and Codex; opencode gets the
# same rule as managed permission.bash globs. Never installed on the host.
#
# WHY: in a linked worktree the box mounts the SHARED .git dir but only this one
# working tree. Every sibling worktree's path is missing inside the container, so git
# reports them all as prunable, and one `git worktree prune` destroys their metadata.
# (`git gc` prunes the same way; the entrypoint sets gc.worktreePruneExpire=never.)
# Manage worktrees on the host; repair damaged metadata there with `git worktree repair`.
#
# A guardrail, not a boundary: string matching can't see through every indirection.
# The structural backstop is that sibling working trees aren't mounted at all.
#
# Input: PreToolUse JSON on stdin. On a match, print the deny decision and exit 2
# (blocks even when the agent's approvals are bypassed). Otherwise exit 0. Never exits
# non-zero without a match.

deny() {
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked by agentbox: git worktree prune/remove/move are denied inside the sandbox. Only this worktree is mounted, so git sees every sibling worktree as missing and would delete their shared metadata. Run worktree lifecycle commands on the host; repair damage there with git worktree repair."}}'
  echo "Blocked by agentbox: destructive git worktree command. Run it on the host instead." >&2
  exit 2
}

INPUT=$(cat)

# Scan the extracted command (jq decodes JSON escapes) AND the raw payload, so an
# unexpected payload shape (a different field name, an argv array) or a missing jq
# fails closed instead of open.
SCAN="$INPUT"
if command -v jq >/dev/null 2>&1; then
  SCAN="$SCAN
$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty | if type == "array" then join(" ") else tostring end' 2>/dev/null)"
fi

# `worktree`, then any mix of spaces, quotes and backslashes (quoted or JSON-escaped
# arguments), then the subcommand. Matches regardless of prefix (env vars,
# `git -C path`, `cd x &&`). Word boundaries keep `worktree list/add` and names like
# `remove-me` allowed.
if printf '%s' "$SCAN" | grep -Eq "\\bworktree([[:space:]]|[\"'\\\\])+(prune|remove|move)\\b"; then
  deny
fi
exit 0
