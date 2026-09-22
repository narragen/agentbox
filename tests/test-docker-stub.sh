#!/usr/bin/env bash
# Tests for the parts of bin/agentbox that talk to Docker (clean, build, the
# interactive run paths), against a stub `docker` that records its arguments.
set -euo pipefail
. "$(dirname "$0")/assert.sh"
AB="$AGENTBOX_ROOT/bin/agentbox"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/cfg" XDG_CACHE_HOME="$TMP/cache" HOME="$TMP/home"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"; touch "$GIT_CONFIG_GLOBAL"
STUB="$TMP/stub"; mkdir -p "$STUB"
export DOCKER_LOG="$TMP/docker.log"

# Stub knobs (env): STUB_PS (ps -q output), STUB_VOLUMES (volume ls output),
# STUB_IMAGES (space-separated images that exist), STUB_BUILD_FAIL=1,
# STUB_CHOWN_FAIL=1, STUB_RUN_SCRIPT (bash run in place of the box),
# STUB_INFO_FAIL=1 (info prints the daemon-down stderr and exits 1),
# STUB_INFO_PERM=1 (info fails with a permission error), STUB_INFO_HANG=1
# (info sleeps 60; pair with AGENTBOX_DOCKER_TIMEOUT=1), STUB_INFO_TERM_SELF=1
# (info TERMs its own process: a 143 death no watchdog caused).
cat > "$STUB/docker" <<'EOF2'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1" in
  info)
    if [ "${STUB_INFO_FAIL:-0}" = 1 ]; then
      printf 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?' >&2
      exit 1
    fi
    if [ "${STUB_INFO_PERM:-0}" = 1 ]; then
      printf 'permission denied while trying to connect to the Docker daemon socket' >&2
      exit 1
    fi
    # exec: the watchdog kills the stub itself, so a child sleep would be orphaned
    if [ "${STUB_INFO_HANG:-0}" = 1 ]; then exec sleep 60; fi
    if [ "${STUB_INFO_TERM_SELF:-0}" = 1 ]; then kill -TERM $$; fi
    exit 0 ;;
  ps) printf '%s' "${STUB_PS:-}"; exit 0 ;;
  volume)
    case "$2" in
      ls) printf '%s' "${STUB_VOLUMES:-}" ;;
      inspect) case " ${STUB_EXISTING_VOLUMES:-} " in *" $3 "*) exit 0 ;; *) exit 1 ;; esac ;;
    esac
    exit 0 ;;
  image)
    [ "$2" = inspect ] || exit 0
    case " ${STUB_IMAGES:-} " in *" $3 "*) exit 0 ;; *) exit 1 ;; esac ;;
  build) [ "${STUB_BUILD_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
  exec) exit 0 ;;
  run)
    case "$*" in *"--entrypoint chown"*) [ "${STUB_CHOWN_FAIL:-0}" = 1 ] && exit 1; exit 0 ;; esac
    [ -n "${STUB_RUN_SCRIPT:-}" ] && bash -c "$STUB_RUN_SCRIPT"
    exit 0 ;;
esac
exit 0
EOF2
chmod +x "$STUB/docker"
export PATH="$STUB:$PATH"
AGENTBOX_HOME="$AGENTBOX_ROOT"; . "$AGENTBOX_ROOT/lib/common.sh"

WS="$TMP/ws"; mkdir -p "$WS"
NAME="$(sandbox_name "$WS")"
log() { cat "$DOCKER_LOG" 2>/dev/null || true; }
reset() { : > "$DOCKER_LOG"; }

# --- docker daemon check ---
# require_docker runs first in every command, so a daemon problem must stop the
# sequence before any other docker call.

reset
t0="$(date +%s)"
rc=0; out="$(STUB_INFO_FAIL=1 bash "$AB" build "$WS" 2>&1)" || rc=$?
t1="$(date +%s)"
assert_eq "unreachable daemon: build exits non-zero" 1 "$rc"
assert_contains "unreachable daemon explains itself" "$out" "can't reach the Docker daemon"
assert_contains "and says to make sure Docker runs locally" "$out" "Make sure Docker is running locally"
assert_eq "build stops at the daemon check" "info" "$(log)"
# a fd-holding orphaned watchdog sleep made this path take exactly the 5s timeout
if [ "$((t1 - t0))" -lt 4 ]; then pass "daemon-down exits promptly (no fd held hostage)"; else fail "daemon-down exits promptly (no fd held hostage)" "took $((t1 - t0))s"; fi

reset
rc=0; out="$(STUB_INFO_FAIL=1 bash "$AB" clean -y "$WS" 2>&1)" || rc=$?
assert_eq "unreachable daemon: clean exits non-zero" 1 "$rc"
assert_contains "clean reports the unreachable daemon" "$out" "can't reach the Docker daemon"
assert_contains "and says to make sure Docker runs locally" "$out" "Make sure Docker is running locally"
assert_eq "clean stops at the daemon check" "info" "$(log)"

reset
out="$(STUB_INFO_FAIL=1 pty bash "$AB" run "$WS" </dev/null 2>&1 || true)"
assert_contains "run reports the unreachable daemon" "$out" "can't reach the Docker daemon"
assert_contains "and says to make sure Docker runs locally" "$out" "Make sure Docker is running locally"
assert_eq "run stops at the daemon check" "info" "$(log)"

# A daemon that accepts connections but never answers: the probe must be killed
# (timeout 10 keeps a broken watchdog from hanging CI; macOS runners lack it).
if command -v timeout >/dev/null 2>&1; then TO=(timeout 10); else TO=(); fi
reset
t0="$(date +%s)"
rc=0; out="$(STUB_INFO_HANG=1 AGENTBOX_DOCKER_TIMEOUT=1 ${TO[@]+"${TO[@]}"} bash "$AB" build "$WS" 2>&1)" || rc=$?
t1="$(date +%s)"
assert_eq "hung daemon: build exits non-zero" 1 "$rc"
assert_contains "hung daemon explains itself" "$out" "isn't responding"
if [ "$((t1 - t0))" -lt 10 ]; then pass "hung daemon check returns within 10s"; else fail "hung daemon check returns within 10s" "took $((t1 - t0))s"; fi

reset
rc=0; out="$(STUB_INFO_PERM=1 bash "$AB" build "$WS" 2>&1)" || rc=$?
assert_eq "permission problem: build exits non-zero" 1 "$rc"
assert_contains "permission problem is explained" "$out" "usermod -aG docker"

# A bad knob (10s, abc, -1) would kill the watchdog's sleep and silently remove
# the stall bound the check exists to provide.
reset
rc=0; out="$(AGENTBOX_DOCKER_TIMEOUT=abc bash "$AB" build "$WS" 2>&1)" || rc=$?
assert_eq "bad timeout knob: build exits non-zero" 1 "$rc"
assert_contains "bad timeout knob is explained" "$out" "must be a positive integer"

# A docker that dies by signal on its own (OOM-killed -> 137, TERMed by something
# else -> 143) must not be reported as a watchdog timeout: only the TIMED OUT
# sentinel the watchdog writes before killing earns "isn't responding".
reset
rc=0; out="$(STUB_INFO_TERM_SELF=1 bash "$AB" build "$WS" 2>&1)" || rc=$?
assert_eq "self-TERMed docker: build exits non-zero" 1 "$rc"
assert_contains "self-TERM reports the unreachable daemon" "$out" "can't reach the Docker daemon"
assert_absent "self-TERM isn't called a timeout" "$out" "isn't responding"

# No docker on PATH at all. The PATH must be built docker-less rather than assumed
# to be: CI runners have /usr/bin/docker (with a live daemon), which would run a
# real `docker build` inside this unit suite. Full /bin+/usr/bin symlink copies
# minus docker (-f: on merged-/usr the two globs hit the same names); the farm
# lives in the suite's $TMP and the outer test shell keeps its own PATH.
reset
NDBIN="$TMP/nodocker-bin"; mkdir -p "$NDBIN"
ln -sfn /bin/* "$NDBIN"/
ln -sfn /usr/bin/* "$NDBIN"/
rm -f "$NDBIN/docker"
rc=0; out="$(PATH="$NDBIN" bash "$AB" build "$WS" 2>&1)" || rc=$?
assert_eq "missing docker: build exits non-zero" 1 "$rc"
assert_contains "missing docker is explained" "$out" "docker not found"

# --- clean ---
reset
MATCH="$(agent_volume claude "$NAME")
$(node_volume . "$NAME")
agentbox-claude-$NAME-9
xagentbox-codex-$NAME"
out="$(STUB_VOLUMES="$MATCH" bash "$AB" clean -y "$WS")"
assert_line "clean removes exactly this box's volumes" "$(log)" "volume rm $(agent_volume claude "$NAME") $(node_volume . "$NAME")"
assert_contains "clean reports the count" "$out" "removed 2 volume(s)"

reset
out="$(printf 'n\n' | STUB_VOLUMES="$(agent_volume claude "$NAME")" bash "$AB" clean "$WS" || true)"
assert_contains "clean asks and can be declined" "$out" "Aborted."
assert_absent "declined clean removes nothing" "$(log)" "volume rm"

reset
rc=0; out="$(STUB_PS=abc123 bash "$AB" clean -y "$WS" 2>&1)" || rc=$?
assert_contains "clean refuses while the box runs" "$out" "is running"
assert_absent "running box: nothing removed" "$(log)" "volume rm"

reset
out="$(STUB_IMAGES="agentbox-proj:$NAME" bash "$AB" clean -y "$WS")"
assert_contains "clean with no volumes says so" "$out" "no volumes"
assert_line "clean removes the project image" "$(log)" "image rm agentbox-proj:$NAME"

# --- build ---
reset
bash "$AB" build "$WS" 2>/dev/null
assert_contains "build builds the base image" "$(log)" "build -t agentbox:latest"
assert_absent "explicit build is never quiet" "$(log)" "--quiet"
PW="$TMP/proj"; mkdir -p "$PW/.agentbox"; printf 'FROM x\n' > "$PW/.agentbox/Dockerfile"
PNAME="$(sandbox_name "$PW")"
mkdir -p "$XDG_CACHE_HOME/agentbox"
printf '%s %s\n' "$(sha256_of "$PW/.agentbox/Dockerfile")" "$PW/.agentbox/Dockerfile" > "$XDG_CACHE_HOME/agentbox/approved"
reset
bash "$AB" build "$PW" 2>/dev/null
assert_contains "project image built on top of the base" "$(log)" "build -t agentbox-proj:$PNAME --build-arg AGENTBOX_IMAGE=agentbox:latest $PW/.agentbox"
rc=0; STUB_BUILD_FAIL=1 bash "$AB" build "$WS" >/dev/null 2>&1 || rc=$?
assert_eq "failed build exits non-zero" 1 "$rc"

# --- run (needs a terminal) ---
reset
out="$(STUB_PS=abc123 pty bash "$AB" run "$WS" </dev/null 2>&1 || true)"
assert_contains "a running box is joined" "$(log)" "exec -it -w /workspace agentbox-$NAME zsh"
assert_absent "joining starts no second container" "$(log)" "run -it"

reset
out="$(STUB_IMAGES="agentbox:latest" pty bash "$AB" run "$WS" </dev/null 2>&1 || true)"
assert_contains "routine launch builds quietly" "$(log)" "build --quiet -t agentbox:latest"
assert_contains "and then runs the box" "$(log)" "run -it --rm --init"

reset
out="$(pty bash "$AB" run "$WS" </dev/null 2>&1 || true)"
assert_absent "first build (no image yet) is not quiet" "$(log)" "--quiet"
assert_contains "first build is announced" "$out" "first build takes several minutes"

reset
out="$(STUB_BUILD_FAIL=1 STUB_IMAGES="agentbox:latest" pty bash "$AB" run "$WS" </dev/null 2>&1 || true)"
assert_contains "failed build falls back with a warning" "$out" "may be out of date"
assert_contains "fallback still launches" "$(log)" "run -it"
reset
out="$(STUB_BUILD_FAIL=1 pty bash "$AB" run "$WS" </dev/null 2>&1 || true)"
assert_contains "failed build without an image stops" "$out" "no earlier agentbox:latest"
assert_absent "and launches nothing" "$(log)" "run -it"

# node_modules volume: created, chowned, mount point made on the host.
NW="$TMP/node"; mkdir -p "$NW"; printf '{}' > "$NW/package.json"
NNAME="$(sandbox_name "$NW")"
reset
out="$(STUB_IMAGES="agentbox:latest" pty bash "$AB" run "$NW" </dev/null 2>&1 || true)"
assert_contains "node volume created" "$(log)" "volume create $(node_volume . "$NNAME")"
assert_contains "node volume handed to node" "$(log)" "--entrypoint chown -v $(node_volume . "$NNAME"):/v agentbox:latest node:node /v"
if [ -d "$NW/node_modules" ]; then pass "host node_modules mount point created first"; else fail "host node_modules mount point created first"; fi
reset
out="$(STUB_CHOWN_FAIL=1 STUB_IMAGES="agentbox:latest" pty bash "$AB" run "$NW" </dev/null 2>&1 || true)"
assert_contains "failed chown stops the launch" "$out" "could not set ownership"
assert_contains "failed chown removes the half-made volume" "$(log)" "volume rm $(node_volume . "$NNAME")"
reset
out="$(STUB_EXISTING_VOLUMES="$(node_volume . "$NNAME")" STUB_IMAGES="agentbox:latest" pty bash "$AB" run "$NW" </dev/null 2>&1 || true)"
assert_absent "existing node volume is reused" "$(log)" "volume create"

# Approval of project code.
AW="$TMP/approve"; mkdir -p "$AW/.agentbox"; printf 'echo hi\n' > "$AW/.agentbox/setup.sh"
reset
out="$(feed n | STUB_IMAGES="agentbox:latest" pty bash "$AB" run "$AW" 2>&1 || true)"
assert_contains "new setup.sh is shown for review" "$out" "echo hi"
assert_contains "declining stops the launch" "$out" "not approved: .agentbox/setup.sh"
assert_absent "declined: nothing built or run" "$(log)" "run -it"
reset
out="$(feed y | STUB_IMAGES="agentbox:latest" pty bash "$AB" run "$AW" 2>&1 || true)"
assert_contains "approved: the box runs" "$(log)" "run -it"
reset
out="$(STUB_IMAGES="agentbox:latest" pty bash "$AB" run "$AW" </dev/null 2>&1 || true)"
assert_absent "approved content isn't asked about again" "$out" "Run it?"
printf 'echo changed\n' > "$AW/.agentbox/setup.sh"
reset
out="$(feed n | STUB_IMAGES="agentbox:latest" pty bash "$AB" run "$AW" 2>&1 || true)"
assert_contains "changed setup.sh is asked about again" "$out" "echo changed"

# Git hooks or risky config planted by the session are reported on exit.
GW="$TMP/gitws"; git init -q "$GW"
reset
out="$(STUB_IMAGES="agentbox:latest" STUB_RUN_SCRIPT="printf '#!/bin/sh\n' > '$GW/.git/hooks/post-checkout'; git config -f '$GW/.git/config' core.fsmonitor 'evil'" pty bash "$AB" run "$GW" </dev/null 2>&1 || true)"
assert_contains "planted hook reported" "$out" "added:   hook post-checkout"
assert_contains "planted fsmonitor reported" "$out" "core.fsmonitor=evil"
reset
out="$(STUB_IMAGES="agentbox:latest" STUB_RUN_SCRIPT="git -C '$GW' config user.name someone; git -C '$GW' config branch.main.remote origin" pty bash "$AB" run "$GW" </dev/null 2>&1 || true)"
assert_absent "ordinary config changes don't warn" "$out" "WARNING"

# The leak heal also runs when the box exits.
reset
out="$(STUB_IMAGES="agentbox:latest" STUB_RUN_SCRIPT="git config -f '$GW/.git/config' core.worktree /workspace" pty bash "$AB" run "$GW" </dev/null 2>&1 || true)"
assert_eq "core.worktree leaked during the session is removed on exit" "" "$(git config -f "$GW/.git/config" --get core.worktree || true)"

finish
