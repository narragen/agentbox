#!/usr/bin/env bash
# Tests for install.sh in a throwaway HOME, with docker stubbed.
set -euo pipefail
. "$(dirname "$0")/assert.sh"
INSTALL="$AGENTBOX_ROOT/install.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/stub"; mkdir -p "$STUB"
printf '#!/bin/sh\nexit 0\n' > "$STUB/docker"; chmod +x "$STUB/docker"
BASEPATH="$STUB:/usr/bin:/bin"

inst() {  # HOME SHELL ARGS...
  local home="$1" sh="$2"; shift 2
  env -u XDG_CONFIG_HOME HOME="$home" SHELL="$sh" PATH="$BASEPATH" bash "$INSTALL" "$@" 2>&1
}

# --- zsh user, fresh install ---
H="$TMP/zsh"; mkdir -p "$H"
out="$(inst "$H" /bin/zsh --no-build)"
assert_eq "links bin/agentbox" "$AGENTBOX_ROOT/bin/agentbox" "$(readlink "$H/.local/bin/agentbox")"
assert_eq "one PATH marker in .zshrc" 1 "$(grep -c 'added by agentbox install.sh' "$H/.zshrc")"
assert_contains "PATH line names the bin dir" "$(cat "$H/.zshrc")" "export PATH=\"$H/.local/bin:\$PATH\""
assert_eq "env file is private" "-rw-------" "$(ls -l "$H/.config/agentbox/env" | cut -c1-10)"
assert_contains "env file lists the token keys" "$(cat "$H/.config/agentbox/env")" "CLAUDE_CODE_OAUTH_TOKEN="
assert_contains "binds template created, all commented" "$(grep -v '^#' "$H/.config/agentbox/binds" || echo EMPTY)" "EMPTY"
assert_contains "tells the user to open a new terminal" "$out" "Open a new terminal"

# The file the installer creates is the one the launcher reads.
mkdir -p "$TMP/ws"
assert_line "launcher passes the installed env file" \
  "$(HOME="$H" AGENTBOX_DRY_RUN=1 env -u XDG_CONFIG_HOME bash "$AGENTBOX_ROOT/bin/agentbox" run "$TMP/ws" 2>/dev/null | grep -A1 -x -- --env-file | tail -1)" \
  "$H/.config/agentbox/env"

# --- rerun is idempotent and keeps user data ---
echo "GH_TOKEN=mine" >> "$H/.config/agentbox/env"
inst "$H" /bin/zsh --no-build >/dev/null
assert_eq "rerun: still one PATH marker" 1 "$(grep -c 'added by agentbox install.sh' "$H/.zshrc")"
assert_contains "rerun: env file kept" "$(cat "$H/.config/agentbox/env")" "GH_TOKEN=mine"

# --- already on PATH: rc untouched ---
H2="$TMP/onpath"; mkdir -p "$H2/.local/bin"
env -u XDG_CONFIG_HOME HOME="$H2" SHELL=/bin/zsh PATH="$H2/.local/bin:$BASEPATH" bash "$INSTALL" --no-build >/dev/null
if [ ! -e "$H2/.zshrc" ]; then pass "no rc edit when already on PATH"; else fail "no rc edit when already on PATH"; fi

# --- bash: macOS uses .bash_profile, Linux .bashrc ---
H3="$TMP/bash"; mkdir -p "$H3"
inst "$H3" /bin/bash --no-build >/dev/null
if [ "$(uname -s)" = Darwin ]; then rc_file="$H3/.bash_profile"; else rc_file="$H3/.bashrc"; fi
assert_eq "bash rc file gets the PATH line" 1 "$(grep -c 'added by agentbox install.sh' "$rc_file")"

# --- other shells: instructions only ---
H4="$TMP/fish"; mkdir -p "$H4"
out="$(inst "$H4" /usr/bin/fish --no-build)"
assert_contains "unknown shell gets instructions" "$out" "Add $H4/.local/bin to PATH"
if [ ! -e "$H4/.zshrc" ] && [ ! -e "$H4/.bashrc" ] && [ ! -e "$H4/.bash_profile" ]; then pass "unknown shell: no rc file written"; else fail "unknown shell: no rc file written"; fi

# --- refuses to replace a real file ---
H5="$TMP/occupied"; mkdir -p "$H5/.local/bin"; echo "mine" > "$H5/.local/bin/agentbox"
rc=0; out="$(inst "$H5" /bin/zsh --no-build)" || rc=$?
assert_eq "existing non-link target: exits non-zero" 1 "$rc"
assert_eq "existing non-link target: untouched" "mine" "$(cat "$H5/.local/bin/agentbox")"

# --- options ---
H6="$TMP/custom"; mkdir -p "$H6"
inst "$H6" /bin/zsh --no-build --bin-dir "$H6/tools" >/dev/null
assert_eq "--bin-dir is honoured" "$AGENTBOX_ROOT/bin/agentbox" "$(readlink "$H6/tools/agentbox")"
rc=0; inst "$H6" /bin/zsh --bin-dir >/dev/null || rc=$?
assert_eq "--bin-dir without a value fails" 1 "$rc"
rc=0; inst "$H6" /bin/zsh --bogus >/dev/null || rc=$?
assert_eq "unknown option fails" 1 "$rc"
assert_contains "--help prints usage" "$(inst "$H6" /bin/zsh --help)" "./install.sh [--bin-dir DIR] [--no-build]"
assert_absent "--help doesn't print code" "$(inst "$H6" /bin/zsh --help)" "set -euo"

# --- no docker ---
rc=0; out="$(env -u XDG_CONFIG_HOME HOME="$TMP/nodocker" SHELL=/bin/zsh PATH=/usr/bin:/bin bash "$INSTALL" --no-build 2>&1)" || rc=$?
assert_contains "missing docker is explained" "$out" "docker not found"

# --- docker present but unusable ---
printf '#!/bin/sh\necho "permission denied while trying to connect to the Docker daemon socket" >&2\nexit 1\n' > "$STUB/docker"
rc=0; out="$(inst "$TMP/perm" /bin/zsh)" || rc=$?
assert_contains "docker permission problem is explained" "$out" "usermod -aG docker"
printf '#!/bin/sh\necho "Cannot connect to the Docker daemon" >&2\nexit 1\n' > "$STUB/docker"
rc=0; out="$(inst "$TMP/down" /bin/zsh)" || rc=$?
assert_contains "stopped docker is explained" "$out" "can't reach the Docker daemon"

# --- uninstall ---
inst "$H" /bin/zsh --uninstall >/dev/null
if [ ! -e "$H/.local/bin/agentbox" ]; then pass "uninstall removes the link"; else fail "uninstall removes the link"; fi
assert_contains "uninstall keeps the env file" "$(cat "$H/.config/agentbox/env")" "GH_TOKEN=mine"
ln -s /somewhere/else "$H/.local/bin/agentbox"
out="$(inst "$H" /bin/zsh --uninstall)"
assert_contains "uninstall leaves a foreign link alone" "$out" "left alone"
assert_eq "foreign link still there" "/somewhere/else" "$(readlink "$H/.local/bin/agentbox")"

finish
