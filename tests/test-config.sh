#!/usr/bin/env bash
# shellcheck disable=SC2088  # a literal ~ in binds-file content is the point
# Unit tests for lib/common.sh: naming, config and binds parsing, versions.env handling.
set -euo pipefail
. "$(dirname "$0")/assert.sh"
AGENTBOX_HOME="$AGENTBOX_ROOT"
. "$AGENTBOX_ROOT/lib/common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- sandbox_name ---
a="$(sandbox_name /x/a/app)"
b="$(sandbox_name /x/b/app)"
case "$a" in app-[0-9]*) pass "name is <leaf>-<hash>" ;; *) fail "name is <leaf>-<hash>" "$a" ;; esac
if [ "$a" != "$b" ]; then pass "same basename, different paths -> different names"; else fail "basename collision" "$a"; fi
assert_eq "name is stable" "$a" "$(sandbox_name /x/a/app)"
case "$(sandbox_name '/x/.hidden dir')" in hidden-dir-[0-9]*) pass "leading dot dropped, space sanitized" ;; *) fail "sanitize" "$(sandbox_name '/x/.hidden dir')" ;; esac
case "$(sandbox_name /x/...)" in ws-[0-9]*) pass "all-dot leaf falls back to ws" ;; *) fail "empty leaf fallback" "$(sandbox_name /x/...)" ;; esac
long="$(sandbox_name "/x/$(printf 'a%.0s' $(seq 1 100))")"
if [ "${#long}" -le 60 ]; then pass "long leaf is capped"; else fail "long leaf is capped" "${#long} chars"; fi

# --- volume names and the clean pattern must agree ---
n="my.app-123"
pat="$(volume_pattern "$n")"
for v in "$(agent_volume claude "$n")" "$(agent_volume codex "$n")" "$(agent_volume opencode "$n")" \
         "$(agent_volume venv "$n")" "$(node_volume . "$n")" "$(node_volume web/app "$n")"; do
  if printf '%s' "$v" | grep -Eq "$pat"; then pass "clean pattern matches $v"; else fail "clean pattern matches $v" "$pat"; fi
done
for v in agentbox-claude-myXapp-123 agentbox-claude-my.app-123-9 xagentbox-claude-my.app-123 \
         other-claude-my.app-123 agentbox-nm-x-my.app-123 agentbox-pyenv-my.app-123; do
  if printf '%s' "$v" | grep -Eq "$pat"; then fail "clean pattern rejects $v" "$pat"; else pass "clean pattern rejects $v"; fi
done
if [ "$(node_volume a "$n")" != "$(node_volume b "$n")" ]; then pass "node volumes differ per directory"; else fail "node volumes differ per directory"; fi

# --- load_config ---
ws="$TMP/ws"; mkdir -p "$ws/.agentbox"
load_config "$ws"
assert_eq "defaults without config: NODE_DIRS" "." "$NODE_DIRS"
assert_eq "defaults without config: PYTHON_DIR" "." "$PYTHON_DIR"

printf '# comment\n\n  NODE_DIRS=./ frontend/ packages/web\nPYTHON_DIR="backend"\n' > "$ws/.agentbox/config"
load_config "$ws"
assert_eq "NODE_DIRS parsed and normalized" ". frontend packages/web" "$NODE_DIRS"
assert_eq "PYTHON_DIR parsed, quotes stripped" "backend" "$PYTHON_DIR"

bad() {  # DESC CONTENT EXPECTED_MSG
  printf '%s\n' "$2" > "$ws/.agentbox/config"
  local out rc=0
  out="$( (load_config "$ws") 2>&1 )" || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "rc=$rc out=$out"; fi
}
bad "rejects parent traversal" "NODE_DIRS=../other" "relative path inside the project"
bad "rejects absolute path" "PYTHON_DIR=/etc" "relative path inside the project"
bad "rejects shell metacharacters" "NODE_DIRS=\$(touch /tmp/pwned)" "relative path inside the project"
bad "rejects unknown keys" "PORTS=3000" "unknown key 'PORTS'"
bad "rejects lines without =" "NODE_DIRS" "expected KEY=VALUE"
bad "rejects empty NODE_DIRS" "NODE_DIRS=" "NODE_DIRS is empty"
bad "a glob is not expanded against the current directory" "NODE_DIRS=*" "entry '*'"

printf 'NODE_DIRS=$(touch %s/pwned)\n' "$TMP" > "$ws/.agentbox/config"
(load_config "$ws") >/dev/null 2>&1 || true
if [ ! -e "$TMP/pwned" ]; then pass "config content is never executed"; else fail "config content was executed"; fi

# --- load_user_binds ---
AGENTBOX_BINDS_FILE="$TMP/binds"
HOME_SAVE="$HOME"; HOME="$TMP/h"; mkdir -p "$HOME/.claude/memory"; touch "$HOME/.claude/s.sh"
printf '# c\n~/.claude/memory:/home/node/.claude/memory:rw\n~/.claude/s.sh:/home/node/.claude/s.sh\n~/missing:/x\n' > "$AGENTBOX_BINDS_FILE"
out="$(load_user_binds 2>&1; printf '%s\n' "${USER_BINDS[@]}")"
load_user_binds 2>/dev/null
assert_eq "binds: two entries kept" 2 "${#USER_BINDS[@]}"
assert_line "binds: ~ expanded, rw kept" "$(printf '%s\n' "${USER_BINDS[@]}")" "$HOME/.claude/memory:/home/node/.claude/memory:rw"
assert_line "binds: mode defaults to ro" "$(printf '%s\n' "${USER_BINDS[@]}")" "$HOME/.claude/s.sh:/home/node/.claude/s.sh:ro"
assert_contains "binds: missing source warned" "$out" "missing doesn't exist"
badbind() {  # DESC LINE MSG
  printf '%s\n' "$2" > "$AGENTBOX_BINDS_FILE"
  local o rc=0
  o="$( (load_user_binds) 2>&1 )" || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$o" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "rc=$rc out=$o"; fi
}
badbind "binds: relative source rejected" "rel/path:/x" "source must be absolute"
badbind "binds: relative destination rejected" "~/.claude/s.sh:rel" "destination must be an absolute"
badbind "binds: bad mode rejected" "~/.claude/s.sh:/x:rwx" "mode must be ro or rw"
badbind "binds: comma rejected (docker mount option injection)" "~/.claude/s.sh:/x,readonly=false" "commas"
badbind "binds: missing destination rejected" "~/.claude/s.sh" "expected SOURCE:DEST"
HOME="$HOME_SAVE"

# --- build_args ---
fake="$TMP/fakehome"; mkdir -p "$fake"
printf '# c\nFOO_VERSION=1.2.3\n\nBAR=24\n' > "$fake/versions.env"
AGENTBOX_HOME="$fake" build_args
joined="${BUILD_ARGS[*]}"
assert_contains "build_args includes FOO_VERSION" "$joined" "--build-arg FOO_VERSION=1.2.3"
assert_contains "build_args includes BAR" "$joined" "--build-arg BAR=24"
printf 'FOO=1; rm -rf /\n' > "$fake/versions.env"
rc=0; (AGENTBOX_HOME="$fake" build_args) >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then pass "build_args rejects malformed values"; else fail "build_args rejects malformed values"; fi

# Every versions.env pin must correspond to a Dockerfile ARG (with or without a
# default): a mistyped key would otherwise leave the ARG empty and install "latest".
# HOST_UID/HOST_GID are excluded — they're runtime config, not version pins.
args_in_dockerfile="$(sed -nE 's/^ARG ([A-Z_]+)(=.*)?/\1/p' "$AGENTBOX_ROOT/image/Dockerfile" | sort -u)"
keys_in_versions="$(sed -nE 's/^([A-Z][A-Z0-9_]*)=.*/\1/p' "$AGENTBOX_ROOT/versions.env" | sort -u)"
missing_in_dockerfile="$(comm -23 <(echo "$keys_in_versions") <(echo "$args_in_dockerfile"))"
if [ -n "$missing_in_dockerfile" ]; then
  fail "versions.env keys present in Dockerfile ARGs" "missing from Dockerfile: $missing_in_dockerfile"
else
  pass "versions.env keys present in Dockerfile ARGs"
fi

# The Linux UID remap: present for a normal Linux user, never for root, never on macOS.
STUB="$TMP/stub"; mkdir -p "$STUB"
printf '#!/bin/sh\necho "$FAKE_UNAME"\n' > "$STUB/uname"
printf '#!/bin/sh\ncase "$1" in -u) echo "$FAKE_UID";; -g) echo 2000;; esac\n' > "$STUB/id"
chmod +x "$STUB/uname" "$STUB/id"
remap() { PATH="$STUB:$PATH" FAKE_UNAME="$1" FAKE_UID="$2" bash -c ". '$AGENTBOX_ROOT/lib/common.sh'; AGENTBOX_HOME='$AGENTBOX_ROOT'; build_args; echo \"\${BUILD_ARGS[*]}\""; }
assert_contains "Linux user gets HOST_UID" "$(remap Linux 1500)" "HOST_UID=1500"
assert_absent "Linux root is never remapped" "$(remap Linux 0)" "HOST_UID"
assert_absent "macOS is never remapped" "$(remap Darwin 501)" "HOST_UID"

finish
