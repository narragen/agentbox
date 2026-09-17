#!/usr/bin/env bash
# Install agentbox: put `agentbox` on your PATH (a symlink back into this checkout, so
# `git pull` updates it), create the token file, and build the image.
#
#   ./install.sh [--bin-dir DIR] [--no-build]
#   ./install.sh --uninstall [--bin-dir DIR]
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
BUILD=1
UNINSTALL=0
ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/agentbox/env"
MARKER="# added by agentbox install.sh"

die() { printf 'install: ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --bin-dir) [ $# -ge 2 ] || die "--bin-dir needs a value"; BIN_DIR="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

TARGET="$BIN_DIR/agentbox"

if [ "$UNINSTALL" = 1 ]; then
  if [ -L "$TARGET" ] && [ "$(readlink "$TARGET")" = "$REPO/bin/agentbox" ]; then
    rm "$TARGET"
    echo "Removed $TARGET."
  else
    echo "$TARGET is not a link to this checkout; left alone."
  fi
  echo "Left in place (see README, Uninstall): $(dirname "$ENV_FILE"), the PATH line"
  echo "in your shell rc (marked '$MARKER'), and agentbox's Docker images and volumes."
  exit 0
fi

command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker Desktop, OrbStack or Docker Engine first."
command -v git >/dev/null 2>&1 || die "git not found."

# 1. Symlink onto PATH.
mkdir -p "$BIN_DIR"
if [ -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
  die "$TARGET exists and is not a symlink; move it aside and re-run."
fi
ln -sfn "$REPO/bin/agentbox" "$TARGET"
echo "Linked $TARGET -> $REPO/bin/agentbox"

# 2. Make sure BIN_DIR is on PATH for future shells.
case ":$PATH:" in
  *":$BIN_DIR:"*) echo "$BIN_DIR is already on PATH." ;;
  *)
    case "$(basename "${SHELL:-}")" in
      zsh) RC="$HOME/.zshrc" ;;
      bash) if [ "$(uname)" = Darwin ]; then RC="$HOME/.bash_profile"; else RC="$HOME/.bashrc"; fi ;;
      *) RC="" ;;
    esac
    if [ -z "$RC" ]; then
      echo "Add $BIN_DIR to PATH in your shell's startup file (shell: ${SHELL:-unknown})."
    elif grep -qF "$MARKER" "$RC" 2>/dev/null; then
      echo "$RC already has the agentbox PATH line; open a new terminal to pick it up."
    else
      printf '\n%s\nexport PATH="%s:$PATH"\n' "$MARKER" "$BIN_DIR" >> "$RC"
      echo "Added $BIN_DIR to PATH in $RC. Open a new terminal (or: source $RC)."
    fi
    ;;
esac

# 3. Token file shared by every box (passed with docker --env-file).
if [ ! -f "$ENV_FILE" ]; then
  mkdir -p "$(dirname "$ENV_FILE")"
  (umask 077 && cat > "$ENV_FILE" <<'ENV'
# agentbox: environment for every box (docker --env-file format).
# One KEY=value per line. No quotes (they would become part of the value), no `export`.
# Empty values of these token keys are dropped inside the box.

# GitHub CLI + git push over HTTPS (fine-grained PAT recommended).
GH_TOKEN=
# Long-lived Claude subscription token from `claude setup-token`. Needed on macOS,
# where the live login sits in the Keychain and the box can't read it.
CLAUDE_CODE_OAUTH_TOKEN=
# Codex access token; logged in once per box, then ~/.codex/auth.json takes over.
CODEX_ACCESS_TOKEN=
ENV
  )
  echo "Created $ENV_FILE (mode 600). Fill in the tokens you use."
else
  echo "Keeping existing $ENV_FILE."
fi

# 4. Optional extra host mounts (see README: "Bind mounts").
BINDS_FILE="$(dirname "$ENV_FILE")/binds"
if [ ! -f "$BINDS_FILE" ]; then
  cat > "$BINDS_FILE" <<'BINDS'
# agentbox: extra host files or directories to mount into every box.
# One per line: SOURCE:DEST[:ro|:rw]   (default ro; ~/ means your home directory)
# Read-write mounts let code in ANY box change these files; use rw sparingly.
#
# ~/.claude/statusline-command.sh:/home/node/.claude/statusline-command.sh:ro
# ~/.claude/memory:/home/node/.claude/memory:rw
BINDS
  echo "Created $BINDS_FILE (all lines commented out)."
fi

# 5. Build the image.
if [ "$BUILD" = 1 ]; then
  if ! docker_err="$(docker info 2>&1 >/dev/null)"; then
    case "$docker_err" in
      *"permission denied"*) die "Docker is running but you don't have permission to use it. On Linux: sudo usermod -aG docker \$USER, log out and back in, then run: agentbox build" ;;
      *) die "can't reach the Docker daemon. Start Docker, then run: agentbox build" ;;
    esac
  fi
  echo "Building the agentbox image (first build takes several minutes)..."
  "$REPO/bin/agentbox" build
fi

echo
echo "Done. In any project directory, run: agentbox"
