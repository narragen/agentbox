#!/usr/bin/env bash
# Node.js / TypeScript dependencies.
#
# For each directory in AGENTBOX_NODE_DIRS (default ".") that has a package.json,
# install with the package manager its lockfile implies. The launcher mounts a per-box
# volume at <dir>/node_modules, so installs persist across launches and never mix with
# a host (e.g. macOS-built) node_modules.
#
# Installs are frozen to the lockfile: a lockfile out of sync with package.json fails
# loudly rather than silently rewriting a file in your repo.
#
# Workspaces (pnpm, npm, yarn, bun) are refused: a workspace install writes node_modules
# links into every member directory, which on the host tree are not volumes.
set -euo pipefail
# shellcheck disable=SC2034  # read by lib.bash
AGENTBOX_INSTALLER=node
# shellcheck source=lib.bash
. "$(dirname "$0")/lib.bash"

install_in_cwd() {
  if [ -f pnpm-lock.yaml ]; then
    pnpm install --frozen-lockfile
  elif [ -f yarn.lock ]; then
    # corepack runs the yarn version pinned in package.json's packageManager field.
    if grep -Eq '"packageManager"[[:space:]]*:[[:space:]]*"yarn@[2-9]' package.json; then
      corepack yarn install --immutable
    else
      corepack yarn install --frozen-lockfile
    fi
  elif [ -f bun.lock ] || [ -f bun.lockb ]; then
    # Branch only fires when a bun lockfile exists, so --frozen-lockfile installs
    # exactly that lockfile and fails loudly if package.json disagrees.
    bun install --frozen-lockfile
  elif [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then
    npm ci --no-audit --no-fund
  else
    log "no lockfile found; 'npm install' will create package-lock.json in your project"
    npm install --no-audit --no-fund
  fi
}

# in_workspace DIR -> success when DIR or any parent up to the project root declares a
# pnpm/npm/yarn/bun workspace. pnpm 10+ also keeps plain settings in
# pnpm-workspace.yaml, so that file only counts when it lists `packages:`. bun has no
# workspace file of its own: bun workspaces use package.json's "workspaces" field, same
# as npm/yarn, so the package.json check already covers them.
in_workspace() {
  local d="$1"
  while :; do
    if { [ -f "$d/pnpm-workspace.yaml" ] && grep -Eq '^packages:' "$d/pnpm-workspace.yaml"; } \
      || { [ -f "$d/package.json" ] && grep -Eq '"workspaces"[[:space:]]*:' "$d/package.json"; }; then
      return 0
    fi
    case "$d" in "$AGENTBOX_WORKSPACE"|/) return 1 ;; esac
    d="$(dirname "$d")"
  done
}

rc=0
set -f  # directory names come from config; never glob them
for dir in ${AGENTBOX_NODE_DIRS:-.}; do
  set +f
  root="$AGENTBOX_WORKSPACE/$dir"
  [ "$dir" = . ] && root="$AGENTBOX_WORKSPACE"
  [ -f "$root/package.json" ] || continue
  if in_workspace "$root"; then
    log "$dir: part of a pnpm/npm/yarn/bun workspace, which agentbox doesn't support yet (installing would write node_modules into member folders on your host). Skipped."
    rc=1
    continue
  fi
  stamp_file="$root/node_modules/.agentbox-stamp"
  stamp="$(stamp_of "$root"/package.json "$root"/pnpm-lock.yaml "$root"/pnpm-workspace.yaml \
    "$root"/yarn.lock "$root"/package-lock.json "$root"/npm-shrinkwrap.json "$root"/.npmrc \
    "$root"/bun.lock "$root"/bun.lockb "$root"/bunfig.toml)"
  if up_to_date "$stamp_file" "$stamp"; then
    log "$dir: up to date"
    continue
  fi
  log "$dir: installing"
  if (cd "$root" && install_in_cwd); then
    printf '%s\n' "$stamp" > "$stamp_file"
    log "$dir: done"
  else
    log "$dir: install FAILED"
    rc=1
  fi
done
exit "$rc"
