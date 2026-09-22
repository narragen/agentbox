# Host-side helpers for bin/agentbox. Sourced, never executed. Requires AGENTBOX_HOME.
# Everything here runs on the HOST, so it must never execute project-supplied code:
# project files are parsed, hashed or handed to Docker, never sourced.
# Written for bash 3.2 (macOS /bin/bash) as well as bash 5.
# shellcheck disable=SC2034  # globals set here are read by bin/agentbox

AGENTBOX_IMAGE="agentbox:latest"
AGENTBOX_PROJ_REPO="agentbox-proj"
AGENTBOX_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agentbox"
AGENTBOX_ENV_FILE="$AGENTBOX_CONFIG_DIR/env"
AGENTBOX_BINDS_FILE="$AGENTBOX_CONFIG_DIR/binds"
AGENTBOX_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox"
AGENTBOX_APPROVALS="$AGENTBOX_CACHE_DIR/approved"

die() { printf 'agentbox: ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'agentbox: WARN: %s\n' "$*" >&2; }
note() { printf 'agentbox: %s\n' "$*" >&2; }

# sha256_of FILE -> hex digest (shasum on macOS, sha256sum on Linux).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# require_docker -> die with the likely cause when the daemon can't be reached.
# The `docker info` probe is bounded: a watchdog kills it after AGENTBOX_DOCKER_TIMEOUT
# seconds (default 5). A daemon that accepts connections but doesn't answer — Docker
# Desktop still starting, systemd socket-activation limbo — would otherwise stall
# startup indefinitely instead of failing with a message. AGENTBOX_DOCKER_TIMEOUT is a
# test hook, and the escape hatch for a slow (e.g. remote) daemon.
require_docker() {
  # a knob like 10s, abc or -1 makes the watchdog's sleep fail, killing the watchdog
  # at once: the unbounded stall this function exists to prevent would return
  # silently. validated before the mktemp, so this die leaks no temp file.
  local t="${AGENTBOX_DOCKER_TIMEOUT:-5}"
  case "$t" in ''|*[!0-9]*|0) die "AGENTBOX_DOCKER_TIMEOUT must be a positive integer (seconds), got '$t'" ;; esac
  command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker Desktop, OrbStack or Docker Engine."
  local probe watchdog rc=0 err
  # global ERR_FILE + EXIT trap: bash runs EXIT traps even on a SIGINT death, so a
  # Ctrl-C mid-probe no longer leaks the temp file. cmd_run later REPLACES this trap
  # with its own EXIT trap — safe, the file is already gone by then; install.sh only
  # runs this check inside a subshell, so its outer shell never sees the trap.
  ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/agentbox-docker-info.XXXXXX")"
  trap '[ -z "${ERR_FILE:-}" ] || rm -f "$ERR_FILE" 2>/dev/null' EXIT
  docker info >"$ERR_FILE" 2>&1 &
  probe=$!
  # TERM first, KILL one second later: a docker that ignores TERM must still die.
  # fds pointed at /dev/null: once the probe finishes, the TERMed subshell orphans its
  # sleep for up to T seconds — but it holds no fds, so nothing can stall waiting on it.
  # on Ctrl-C the async subshell ignores SIGINT (POSIX: async lists get SIGINT ignored)
  # and stays armed up to T seconds pointing at a pid that may by then be reaped —
  # harmless barring pid wraparound.
  # the TIMED OUT line is written BEFORE the kill, marking a watchdog-fired death;
  # the classification below refuses to take a 143/137 exit as proof on its own.
  ( sleep "$t" && printf 'TIMED OUT\n' >> "$ERR_FILE" && kill -TERM "$probe" && sleep 1 && kill -KILL "$probe" ) </dev/null >/dev/null 2>&1 &
  watchdog=$!
  wait "$probe" || rc=$?
  kill -TERM "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  err="$(cat "$ERR_FILE")"
  rm -f "$ERR_FILE"
  ERR_FILE=""
  if [ "$rc" -eq 0 ]; then return 0; fi
  # 143/137 alone doesn't prove the watchdog fired — docker can die OOM-killed (137)
  # or externally TERMed (143) — so the sentinel decides; without it the probe's own
  # stderr classifies below. (a probe failing right as the sentinel is appended falls
  # through with its real error — correct.)
  case "$rc" in
    143|137) case "$err" in *TIMED\ OUT*)
      die "Docker isn't responding (it may still be starting up). Make sure the Docker daemon is running locally, then run this command again." ;;
    esac ;;
  esac
  case "$err" in
    *"permission denied"*)
      die "Docker is running but you don't have permission to use it. On Linux: sudo usermod -aG docker \$USER, then log out and back in." ;;
    *) die "can't reach the Docker daemon. Make sure Docker is running locally (start Docker Desktop, or on Linux: sudo systemctl start docker), then run this command again." ;;
  esac
}

# sandbox_name ABS_PATH -> "<leaf>-<hash>", unique per directory.
# leaf: basename limited to Docker's name charset, leading dots/dashes dropped, capped
#       at 48 chars. hash: cksum of the absolute path, so ~/a/app and ~/b/app never
#       share a container or volumes. Pass the `cd DIR && pwd` form (not `pwd -P`).
sandbox_name() {
  local leaf hash
  leaf="$(printf '%s' "$(basename "$1")" | tr -c 'A-Za-z0-9_.-' '-' | sed -E 's/^[.-]+//' | cut -c1-48)"
  [ -n "$leaf" ] || leaf="ws"
  hash="$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
  printf '%s-%s' "$leaf" "$hash"
}

# Per-box volume names. `agentbox clean` finds them with volume_pattern, so every
# name must come from these helpers (tests check that they agree).
agent_volume() { printf 'agentbox-%s-%s' "$1" "$2"; }                  # KIND NAME
node_volume() {                                                         # DIR NAME
  printf 'agentbox-nm-%s-%s' "$(printf '%s' "$1" | cksum | cut -d' ' -f1)" "$2"
}
# volume_pattern NAME -> an anchored regex matching every volume of that box.
volume_pattern() {
  local esc
  esc="$(printf '%s' "$1" | sed 's/[.]/\\./g')"
  printf '^agentbox-(claude|codex|opencode|venv|nm-[0-9]+)-%s$' "$esc"
}

# build_args -> BUILD_ARGS: one --build-arg per line of versions.env (validated,
# never sourced), plus the Linux UID/GID remap.
build_args() {
  local line
  BUILD_ARGS=()
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    if ! printf '%s' "$line" | grep -Eq '^[A-Z][A-Z0-9_]*=[A-Za-z0-9._-]+$'; then
      die "bad line in $AGENTBOX_HOME/versions.env: '$line' (expected KEY=VALUE)"
    fi
    BUILD_ARGS+=(--build-arg "$line")
  done < "$AGENTBOX_HOME/versions.env"
  # Linux: match the box user to yours (see the Dockerfile). Never remap to root.
  if [ "$(uname -s)" = Linux ] && [ "$(id -u)" != 0 ]; then
    BUILD_ARGS+=(--build-arg "HOST_UID=$(id -u)" --build-arg "HOST_GID=$(id -g)")
  fi
}

# normalize_rel_dir DIR -> DIR without leading "./" or trailing "/" ("." stays ".").
normalize_rel_dir() {
  local d="$1"
  while [ "${d#./}" != "$d" ]; do d="${d#./}"; done
  while [ "${d%/}" != "$d" ]; do d="${d%/}"; done
  printf '%s' "${d:-.}"
}

# valid_rel_dir DIR -> success for a plain relative path inside the project.
valid_rel_dir() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._/-]+$' || return 1
  case "/$1/" in */../*|//*) return 1 ;; esac
  return 0
}

# trim STRING -> STRING without surrounding whitespace.
trim() { printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

# load_config WORKSPACE -> sets NODE_DIRS and PYTHON_DIR from .agentbox/config.
# The file is PARSED, not sourced: a cloned repo must not run code on the host.
load_config() {
  local file="$1/.agentbox/config" line key value d
  NODE_DIRS="."
  PYTHON_DIR="."
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(trim "$line")"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) die "$file: expected KEY=VALUE, got '$line'" ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    value="${value#\"}"; value="${value%\"}"
    case "$key" in
      NODE_DIRS)
        NODE_DIRS=""
        set -f  # a value like `*` must not expand against the host's current directory
        for d in $value; do
          valid_rel_dir "$d" || { set +f; die "$file: NODE_DIRS entry '$d' must be a relative path inside the project"; }
          NODE_DIRS="${NODE_DIRS:+$NODE_DIRS }$(normalize_rel_dir "$d")"
        done
        set +f
        [ -n "$NODE_DIRS" ] || die "$file: NODE_DIRS is empty (remove the line to use the default '.')" ;;
      PYTHON_DIR)
        valid_rel_dir "$value" || die "$file: PYTHON_DIR '$value' must be a relative path inside the project"
        PYTHON_DIR="$(normalize_rel_dir "$value")" ;;
      *) die "$file: unknown key '$key' (known: NODE_DIRS, PYTHON_DIR)" ;;
    esac
  done < "$file"
}

# load_user_binds -> USER_BINDS: extra docker -v specs from ~/.config/agentbox/binds.
# Your own file, but still parsed rather than sourced.
# Line format: SOURCE:DEST[:ro|:rw]   (default ro; a leading ~/ means your home)
load_user_binds() {
  local line src dest mode rest n=0
  USER_BINDS=()
  [ -f "$AGENTBOX_BINDS_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="$(trim "$line")"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *,*) die "$AGENTBOX_BINDS_FILE:$n: commas aren't allowed in bind paths" ;; esac
    src="${line%%:*}"
    rest="${line#*:}"
    [ "$rest" != "$line" ] || die "$AGENTBOX_BINDS_FILE:$n: expected SOURCE:DEST[:ro|:rw], got '$line'"
    dest="${rest%%:*}"
    mode="ro"
    if [ "$dest" != "$rest" ]; then mode="${rest#*:}"; fi
    # shellcheck disable=SC2088  # matching a literal ~ written in the file
    case "$src" in "~/"*) src="$HOME/${src#"~/"}" ;; esac
    case "$src" in /*) ;; *) die "$AGENTBOX_BINDS_FILE:$n: source must be absolute or start with ~/ (got '$src')" ;; esac
    case "$dest" in /*) ;; *) die "$AGENTBOX_BINDS_FILE:$n: destination must be an absolute path in the box (got '$dest')" ;; esac
    case "$mode" in ro|rw) ;; *) die "$AGENTBOX_BINDS_FILE:$n: mode must be ro or rw (got '$mode')" ;; esac
    if [ ! -e "$src" ]; then
      warn "$AGENTBOX_BINDS_FILE:$n: $src doesn't exist; skipping it"
      continue
    fi
    USER_BINDS+=("$src:$dest:$mode")
  done < "$AGENTBOX_BINDS_FILE"
}

# project_image WORKSPACE NAME -> the image to run: the project's extension image when
# .agentbox/Dockerfile exists, else the base image.
project_image() {
  if [ -f "$1/.agentbox/Dockerfile" ]; then
    printf '%s:%s' "$AGENTBOX_PROJ_REPO" "$2"
  else
    printf '%s' "$AGENTBOX_IMAGE"
  fi
}

# build_images WORKSPACE NAME [quiet] -> build the base image, then the project image.
# Both are cached no-ops when nothing changed. "quiet" applies only while the base
# image already exists: a first build takes minutes and must not look hung.
build_images() {
  local ws="$1" name="$2" q=()
  if [ "${3:-}" = quiet ] && docker image inspect "$AGENTBOX_IMAGE" >/dev/null 2>&1; then
    q=(--quiet)
  else
    note "building $AGENTBOX_IMAGE (the first build takes several minutes)"
  fi
  build_args
  docker build ${q[@]+"${q[@]}"} -t "$AGENTBOX_IMAGE" "${BUILD_ARGS[@]}" "$AGENTBOX_HOME/image" >/dev/null || return 1
  if [ -f "$ws/.agentbox/Dockerfile" ]; then
    docker build ${q[@]+"${q[@]}"} -t "$AGENTBOX_PROJ_REPO:$name" --build-arg "AGENTBOX_IMAGE=$AGENTBOX_IMAGE" \
      "$ws/.agentbox" >/dev/null || return 1
  fi
}

# ensure_node_volume VOLUME IMAGE -> create it owned by `node`. A fresh volume mounted
# inside the workspace bind has no image directory to copy ownership from, so it
# would start root-owned, and the box has no sudo to fix that later. A volume whose
# chown failed is removed again, so the next launch retries instead of inheriting it.
ensure_node_volume() {
  docker volume inspect "$1" >/dev/null 2>&1 && return 0
  docker volume create "$1" >/dev/null || die "could not create volume $1"
  if ! docker run --rm --user root --entrypoint chown -v "$1":/v "$2" node:node /v; then
    docker volume rm "$1" >/dev/null 2>&1 || true
    die "could not set ownership on volume $1"
  fi
}

# --- Approving project code -------------------------------------------------------------
# .agentbox/setup.sh and .agentbox/Dockerfile run automatically, with your tokens and
# open network. Ask once per file content before letting them.

# approve_project_code WORKSPACE -> returns when every such file is approved; dies if
# the user declines or there is no terminal to ask on.
approve_project_code() {
  local ws="$1" rel file key answer lines
  for rel in .agentbox/setup.sh .agentbox/Dockerfile; do
    file="$ws/$rel"
    [ -f "$file" ] || continue
    key="$(sha256_of "$file") $ws/$rel"
    if [ -f "$AGENTBOX_APPROVALS" ] && grep -Fxq -- "$key" "$AGENTBOX_APPROVALS"; then
      continue
    fi
    [ -t 0 ] || die "$rel is new or changed and needs your approval. Run agentbox in a terminal to review it."
    lines="$(wc -l < "$file" | tr -d ' ')"
    {
      echo
      echo "agentbox: $rel is new, or changed since you approved it."
      echo "It runs automatically in the box, with your tokens and network access:"
      echo "----------------------------------------------------------------------"
      sed -n '1,60p' "$file"
      [ "$lines" -le 60 ] || echo "... ($lines lines in total; open $file to read the rest)"
      echo "----------------------------------------------------------------------"
      printf 'Run it? [y/N] '
    } >&2
    read -r answer || answer=""
    case "$answer" in
      y|Y|yes) mkdir -p "$AGENTBOX_CACHE_DIR" && printf '%s\n' "$key" >> "$AGENTBOX_APPROVALS" ;;
      *) die "not approved: $rel. Nothing was run." ;;
    esac
  done
}

# --- Git ------------------------------------------------------------------------------------
# resolve_git_dirs WORKSPACE -> sets GIT_KIND (none|main|linked), GIT_GITDIR and
# GIT_COMMON by reading files, without `git rev-parse` (which a broken repo config can
# break). Dies for a .git pointer that agentbox can't mount safely.
resolve_git_dirs() {
  local ws="$1" gitdir commondir back
  GIT_KIND=none; GIT_GITDIR=""; GIT_COMMON=""
  if [ -d "$ws/.git" ]; then
    GIT_KIND=main; GIT_GITDIR="$ws/.git"; GIT_COMMON="$ws/.git"
    return 0
  fi
  [ -f "$ws/.git" ] || return 0
  gitdir="$(sed -n 's/^gitdir: *//p' "$ws/.git" | head -1)"
  case "$gitdir" in
    /*) ;;
    "") die "$ws/.git is not a valid gitdir pointer" ;;
    *) die "$ws/.git uses a relative path (worktree.useRelativePaths), which agentbox can't mount. On the host, run: git -c worktree.useRelativePaths=false worktree repair" ;;
  esac
  [ -d "$gitdir" ] || die "$ws/.git points at $gitdir, which doesn't exist"
  if [ -f "$gitdir/commondir" ]; then
    commondir="$(cat "$gitdir/commondir")"
    case "$commondir" in
      /*) GIT_COMMON="$commondir" ;;
      *) GIT_COMMON="$(cd "$gitdir" && cd "$commondir" && pwd -P)" || die "can't resolve $gitdir/commondir" ;;
    esac
  else
    GIT_COMMON="$gitdir"   # a submodule: its git dir is self-contained
  fi
  { [ -f "$GIT_COMMON/HEAD" ] && [ -d "$GIT_COMMON/objects" ]; } || die "$GIT_COMMON is not a git directory"
  # A crafted .git file could point at an unrelated repo, which would then be mounted
  # read-write. A real worktree's metadata points back at this checkout; a real
  # submodule's config names its work tree.
  if [ -f "$gitdir/gitdir" ]; then
    back="$(cat "$gitdir/gitdir")"
    [ "$back" = "$ws/.git" ] || [ "$back" = "$(cd -P "$ws" && pwd)/.git" ] \
      || die "$ws/.git points at $gitdir, but that worktree belongs to $back. Refusing to mount it; run 'git worktree repair' on the host."
  elif ! git config -f "$gitdir/config" --get core.worktree >/dev/null 2>&1; then
    die "$ws/.git points at $gitdir, which isn't a worktree or submodule of this directory. Refusing to mount it."
  fi
  GIT_KIND=linked
  GIT_GITDIR="$gitdir"
}

# heal_stray_worktree WORKSPACE -> backstop: remove `core.worktree = /workspace` from the
# shared config. That path exists only in the box, so host git would think the main
# worktree is gone. agentbox no longer exports GIT_DIR/GIT_WORK_TREE (which is what
# used to write it), but a tool inside the box still could.
heal_stray_worktree() {
  local cfg val
  cfg="$( (resolve_git_dirs "$1" && [ -n "$GIT_COMMON" ] && printf '%s' "$GIT_COMMON/config") 2>/dev/null || true)"
  [ -n "$cfg" ] && [ -f "$cfg" ] || return 0
  val="$(git config -f "$cfg" --get core.worktree 2>/dev/null)" || true
  if [ "$val" = "/workspace" ]; then
    git config -f "$cfg" --unset core.worktree 2>/dev/null \
      && note "removed stray core.worktree=/workspace from $cfg"
  fi
  # Best effort: never fail the launch (or taint the exit code via the EXIT trap).
  return 0
}

# Git config keys that make HOST git run a program. Code in the box can write them.
RISKY_GIT_KEYS='^(core\.(fsmonitor|hookspath|pager|editor|sshcommand|askpass|gitproxy)|alias\.|filter\.|credential\.|gpg\.|include\.|includeif\.|pager\.|sequence\.editor|interactive\.difffilter|uploadpack\.|diff\.external|diff\..*\.(textconv|command)|merge\..*\.driver|remote\..*\.(uploadpack|receivepack|vcs)|http\..*proxy)'

# git_exec_snapshot WORKSPACE -> hooks and risky config entries, one per line, sorted.
git_exec_snapshot() {
  (
    resolve_git_dirs "$1" 2>/dev/null || exit 0
    [ -n "$GIT_COMMON" ] || exit 0
    for f in "$GIT_COMMON"/hooks/*; do
      [ -f "$f" ] || continue
      case "$f" in *.sample) continue ;; esac
      printf 'hook %s %s\n' "$(basename "$f")" "$(sha256_of "$f")"
    done
    for f in "$GIT_COMMON/config" "$GIT_GITDIR/config.worktree"; do
      [ -f "$f" ] || continue
      git config -f "$f" --list 2>/dev/null | grep -iE "$RISKY_GIT_KEYS" | sed "s|^|config $(basename "$f") |"
    done
  ) | LC_ALL=C sort
}

# warn_git_exec_changes WORKSPACE BEFORE -> loud warning when hooks or risky config
# changed during the session. Detection, not prevention: the next host git command
# would run whatever was planted.
warn_git_exec_changes() {
  local after
  after="$(git_exec_snapshot "$1")"
  [ "$after" = "$2" ] && return 0
  {
    echo
    echo "agentbox: WARNING: the box changed git hooks or git config that can run programs on your HOST:"
    diff <(printf '%s\n' "$2") <(printf '%s\n' "$after") | sed -n 's/^< /  removed: /p; s/^> /  added:   /p'
    echo "Review them in $1/.git before running git outside the box."
  } >&2
}
