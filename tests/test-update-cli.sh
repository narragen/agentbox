#!/usr/bin/env bash
# Tests for scripts/update.sh (agentbox update command).
# All git/docker calls are intercepted by stubs in a temp directory.
set -euo pipefail
. "$(dirname "$0")/assert.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ROOT
SCRIPT="$ROOT/scripts/update.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Create stubs --------------------------------------------------------------------
SBIN="$TMP/bin"
export TMP
mkdir -p "$SBIN" "$TMP/log"

FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.config/agentbox" "$FAKE_HOME/.cache/agentbox" "$FAKE_HOME/.local/bin"

# --- Git stub ------------------------------------------------------------------------
#
# Controlled by these env vars (must be exported before calling run_update):
#   GIT_REMOTE_URL   - for "git remote get-url origin" (empty = no remote)
#   GIT_PULL_EXIT    - exit code for "git pull" (0=ok, 1=fail)
#   GIT_PULL_VERSION - if non-empty, writes this to $ROOT/VERSION after pull
#   GIT_BREAKING     - "1" to create BREAKING_CHANGES.md after pull
cat > "$SBIN/git" <<'EOF'
#!/usr/bin/env bash
# Debug: record env and args
echo "RAW=$@ GRU=${GIT_REMOTE_URL:-UNSET}" > /tmp/git-debug.txt
_args=()
_i=1
while [ $_i -le $# ]; do
  eval "_arg=\${$_i}"
  if [ "$_arg" = "-C" ]; then
    _i=$(($_i + 2))
    continue
  fi
  _args+=("$_arg")
  _i=$(($_i + 1))
done
set -- "${_args[@]}"

case "${1:-}" in
  remote)
    case "${2:-}" in
      get-url)
        if [ "${3:-}" = "origin" ]; then
          if [ -n "${GIT_REMOTE_URL:-}" ]; then
            printf '%s\n' "$GIT_REMOTE_URL"
            exit 0
          fi
        fi
        ;;
    esac
    ;;
  ls-remote) exit 0 ;;
  rev-parse)
    case "${*:-}" in *--abbrev-ref*) printf 'main\n'; exit 0 ;; esac ;;
  diff) exit 0 ;;
  config) exit 0 ;;
  pull)
    if [ "${GIT_PULL_EXIT:-0}" != "0" ]; then
      echo "error: could not pull" >&2; exit 1
    fi
    if [ -n "${GIT_PULL_VERSION:-}" ]; then
      printf '%s\n' "$GIT_PULL_VERSION" > "$ROOT/VERSION"
    fi
    if [ "${GIT_BREAKING:-}" = "1" ]; then
      cat > "$ROOT/BREAKING_CHANGES.md" <<'BCEOF'
# Breaking Changes

## 1.0.0

- Changed the default Docker user from root to node.
- Renamed .agentbox/settings to .agentbox/config.
BCEOF
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SBIN/git"

# --- Docker stub ---------------------------------------------------------------------
cat > "$SBIN/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$TMP/log/docker.log"
exit 0
EOF
chmod +x "$SBIN/docker"

# --- Helper --------------------------------------------------------------------------
# Run the update script with stubs in PATH and FAKE_HOME set.
# Caller must export GIT_REMOTE_URL, GIT_PULL_EXIT, GIT_PULL_VERSION, GIT_BREAKING
# before calling this function.
run_update() {
  PATH="$SBIN:$PATH" HOME="$FAKE_HOME" SHELL="/bin/zsh" bash "$SCRIPT" "$@" 2>&1
}

reset_ver() { printf '%s\n' "$1" > "$ROOT/VERSION"; }

# Set default stub values (exported so they propagate into $() subshells).
export GIT_REMOTE_URL="https://github.com/test/agentbox"
export GIT_PULL_EXIT=0
export GIT_PULL_VERSION=""
export GIT_BREAKING=""

# --- Tests --------------------------------------------------------------------------

# 1. Basic update: pull, version bump, symlink, PATH injection, mentions done.
reset_ver "0.1.0"
export GIT_PULL_VERSION="0.2.0"
out="$(run_update)" || true
assert_contains "basic: shows version update" "$out" "0.1.0 -> 0.2.0"
assert_contains "basic: mentions done" "$out" "Done"

# 2. Config preservation: env file survives.
reset_ver "0.1.0"
printf 'GH_TOKEN=ghp_test123\nCLAUDE_CODE_OAUTH_TOKEN=sk-ant-abc\n' > "$FAKE_HOME/.config/agentbox/env"
export GIT_PULL_VERSION="0.2.0"
run_update >/dev/null 2>&1 || true
assert_eq "env: GH_TOKEN line preserved" "GH_TOKEN=ghp_test123" \
  "$(sed -n '1p' "$FAKE_HOME/.config/agentbox/env")"
assert_eq "env: CLAUDE line preserved" "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-abc" \
  "$(sed -n '2p' "$FAKE_HOME/.config/agentbox/env")"

# 3. Config preservation: binds file survives.
reset_ver "0.1.0"
printf '~/.claude/foo:/home/node/.claude/foo\n' > "$FAKE_HOME/.config/agentbox/binds"
export GIT_PULL_VERSION="0.3.0"
run_update >/dev/null 2>&1 || true
assert_eq "binds: preserved" "~/.claude/foo:/home/node/.claude/foo" \
  "$(cat "$FAKE_HOME/.config/agentbox/binds")"

# 4. Config preservation: approvals file survives.
reset_ver "0.1.0"
printf 'abc123 .agentbox/setup.sh\n' > "$FAKE_HOME/.cache/agentbox/approved"
export GIT_PULL_VERSION="0.4.0"
run_update >/dev/null 2>&1 || true
assert_eq "approvals: preserved" "abc123 .agentbox/setup.sh" \
  "$(cat "$FAKE_HOME/.cache/agentbox/approved")"

# 5. --no-build: skips docker build.
reset_ver "0.1.0"
: > "$TMP/log/docker.log"
export GIT_PULL_VERSION="0.5.0"
out="$(run_update --no-build)" || true
assert_contains "--no-build: mentions done" "$out" "Done"
if [ -f "$TMP/log/docker.log" ] && grep -q "docker build" "$TMP/log/docker.log" 2>/dev/null; then
  fail "--no-build: docker build was called"
else
  pass "--no-build: no docker build"
fi

# 6. Major bump, user declines.
reset_ver "0.9.0"
export GIT_PULL_VERSION="1.0.0" GIT_BREAKING="1"
rc=0; out="$(printf 'n\n' | run_update 2>&1)" || rc=$?
assert_eq "major decline: exits 1" 1 "$rc"
assert_contains "major decline: says aborted" "$out" "Aborted"

# 7. Major bump, user confirms.
reset_ver "0.9.0"
export GIT_PULL_VERSION="1.0.0" GIT_BREAKING="1"
out="$(printf 'y\n' | run_update 2>&1)" || true
assert_contains "major confirm: shows Done" "$out" "Done"
assert_contains "major confirm: shows breaking changes" "$out" "Changed the default Docker"

# 8. --force skips confirmation.
reset_ver "0.9.0"
export GIT_PULL_VERSION="1.0.0" GIT_BREAKING="1"
out="$(run_update --force 2>&1)" || true
assert_contains "--force: shows Done" "$out" "Done"
assert_absent "--force: no prompt" "$out" "[y/N]"

# 9. No version change: says up to date.
reset_ver "0.5.0"
export GIT_PULL_VERSION="0.5.0"
out="$(run_update 2>&1)" || true
assert_contains "no change: up to date" "$out" "Already at 0.5.0"

# 10. Pull failure.
reset_ver "0.1.0"
export GIT_PULL_EXIT=1 GIT_PULL_VERSION=""
rc=0; out="$(run_update 2>&1)" || rc=$?
assert_eq "pull fail: exits 1" 1 "$rc"
assert_contains "pull fail: mentions git pull" "$out" "git pull failed"

# 11. No remote.
reset_ver "0.1.0"
export GIT_REMOTE_URL="" GIT_PULL_EXIT=0 GIT_PULL_VERSION="0.2.0" GIT_BREAKING=""
rc=0; out="$(run_update 2>&1)" || rc=$?
assert_eq "no remote: exits 1" 1 "$rc"
assert_contains "no remote: mentions origin" "$out" "origin"

# 12. Bad argument.
rc=0; out="$(run_update --bogus 2>&1)" || rc=$?
assert_eq "bad arg: exits 2" 2 "$rc"

# 13. Help exits 0.
rc=0; out="$(run_update --help 2>&1)" || rc=$?
assert_eq "help: exits 0" 0 "$rc"

# 14. Symlink re-link.
reset_ver "0.5.0"
export GIT_REMOTE_URL="https://github.com/test/agentbox"
rm -f "$FAKE_HOME/.local/bin/agentbox"
ln -s "/old/path/agentbox" "$FAKE_HOME/.local/bin/agentbox"
export GIT_PULL_VERSION="0.5.0"
run_update >/dev/null 2>&1 || true
if [ -L "$FAKE_HOME/.local/bin/agentbox" ]; then
  target="$(readlink "$FAKE_HOME/.local/bin/agentbox")"
  assert_eq "symlink: current repo" "$ROOT/bin/agentbox" "$target"
else
  fail "symlink: not a symlink"
fi

finish
