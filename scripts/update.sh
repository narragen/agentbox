#!/usr/bin/env bash
# Update agentbox: pull the latest from the remote repo, reinstall, and rebuild.
#   agentbox update                  pull, confirm if breaking, reinstall, rebuild
#   agentbox update --no-build       same, but skip the image rebuild
#   agentbox update --force          skip the breaking-change confirmation
#
# Preserves the user's config (env, binds, approvals) in ~/.config/agentbox and
# ~/.cache/agentbox: they are never overwritten or deleted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$HOME/.local/bin"
BUILD=1
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) BUILD=0; shift ;;
    --force)    FORCE=1;  shift ;;
    -h|--help)  sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "usage: agentbox update [--no-build] [--force]" >&2; exit 2 ;;
  esac
done

# --- Helpers --------------------------------------------------------------------------
die() { printf 'agentbox update: ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf 'agentbox update: %s\n' "$*" >&2; }
warn() { printf 'agentbox update: WARNING: %s\n' "$*" >&2; }

# --- Pre-flight checks ----------------------------------------------------------------
command -v git >/dev/null 2>&1 || die "git not found. Install git first."
command -v curl >/dev/null 2>&1 || die "curl not found (used to check remote reachability)."

# Must have a remote (a plain clone without origin would fail later anyway, but we
# want a clear message before we start pulling).
remote_url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
[ -n "$remote_url" ] || die "no 'origin' remote in $ROOT; is this a cloned repo?"

# Can we reach the remote? (git ls-remote is cheap: it reads no objects.)
if ! git ls-remote "$remote_url" HEAD >/dev/null 2>&1; then
  die "cannot reach remote '$remote_url'. Check your network connection and that the URL is correct."
fi

# --- Determine versions before pull ---------------------------------------------------
old_ver="$(cat "$ROOT/VERSION" 2>/dev/null | head -1 | tr -d '[:space:]' || echo 0.0.0)"
old_major="${old_ver%%.*}"

# --- Pull -----------------------------------------------------------------------------
note "Pulling latest from origin ..."
if ! (cd "$ROOT" && git pull origin "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)" 2>&1); then
  die "git pull failed. Fix the merge conflicts, then run 'agentbox update' again."
fi

# --- Version comparison & breaking changes -------------------------------------------
new_ver="$(cat "$ROOT/VERSION" 2>/dev/null | head -1 | tr -d '[:space:]' || echo 0.0.0)"
new_major="${new_ver%%.*}"

if [ "$old_major" != "$new_major" ] && [ "$FORCE" != 1 ]; then
  # Major version changed — this may have breaking changes.
  echo
  echo "agentbox upgraded from $old_ver to $new_ver (major version bump)."
  echo "There may be breaking changes in this release."
  echo

  BC_FILE="$ROOT/BREAKING_CHANGES.md"
  if [ -f "$BC_FILE" ]; then
    echo "Breaking changes for this release:"
    echo "===================================="
    # Print everything after the first ## heading (the unreleased section).
    sed -n '/^## /,/^[^-]#/p' "$BC_FILE" | sed '1d'
    echo "===================================="
    echo
  else
    note "No BREAKING_CHANGES.md found; reviewing the diff for clues:"
    echo
    (cd "$ROOT" && git diff HEAD~1 --stat 2>/dev/null || echo "  (no previous commits to compare)")
    echo
  fi

  # Ask for confirmation.
  printf 'Continue with the update? [y/N] '
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes) ;;
    *) die "Aborted. The update was cancelled." ;;
  esac
  echo
fi

if [ "$old_ver" != "$new_ver" ]; then
  note "Updated $old_ver -> $new_ver"
else
  note "Already at $new_ver"
fi

# --- Reinstall (symlink + PATH) -------------------------------------------------------
TARGET="$BIN_DIR/agentbox"
REPO_BIN="$ROOT/bin/agentbox"

mkdir -p "$BIN_DIR"
if [ -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
  die "$TARGET exists and is not a symlink; move it aside and re-run."
fi
ln -sfn "$REPO_BIN" "$TARGET"
note "Linked $TARGET -> $REPO_BIN"

# Make sure BIN_DIR is on PATH for future shells.
MARKER="# added by agentbox install.sh"
case ":$PATH:" in
  *":$BIN_DIR:"*) echo "$BIN_DIR is already on PATH." ;;
  *)
    case "$(basename "${SHELL:-}")" in
      zsh) RC="$HOME/.zshrc" ;;
      bash) if [ "$(uname)" = Darwin ]; then RC="$HOME/.bash_profile"; else RC="$HOME/.bashrc"; fi ;;
      *) RC="" ;;
    esac
    if [ -z "$RC" ]; then
      note "Add $BIN_DIR to PATH in your shell's startup file (shell: ${SHELL:-unknown})."
    elif grep -qF "$MARKER" "$RC" 2>/dev/null; then
      echo "$RC already has the agentbox PATH line."
    else
      printf '\n%s\nexport PATH="%s:$PATH"\n' "$MARKER" "$BIN_DIR" >> "$RC"
      note "Added $BIN_DIR to PATH in $RC. Open a new terminal (or: source $RC)."
    fi
    ;;
esac

# --- Config files are preserved (never overwritten) -----------------------------------
# ~/.config/agentbox/env, binds, approvals, ~/.cache/agentbox/approvals are all
# untouched by this script. The installer only creates them when they don't exist,
# and we reuse that same logic via the real install.sh.
#
# If the user needs new config keys that were added to env/binds in a recent release,
# they can merge them manually — we never delete existing lines.

# --- Rebuild --------------------------------------------------------------------------
if [ "$BUILD" = 1 ]; then
  # Check docker availability without the full require_docker machinery.
  if command -v docker >/dev/null 2>&1; then
    note "Building the agentbox image (first build takes several minutes)..."
    # Use the current checkout's bin/agentbox (already updated by the symlink).
    "$ROOT/bin/agentbox" build 2>&1 || {
      warn "Image build failed. You can still run older boxes; fix the build later with: agentbox build"
    }
  else
    warn "docker not found; skipping image build. Run 'agentbox build' after installing docker."
  fi
fi

echo
echo "Done. agentbox $new_ver is up to date."
echo "In any project directory, run: agentbox"
