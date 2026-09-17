# Shared helpers for deps.d installers. Sourced by each NN-name.sh, never run directly.
# Each installer sets AGENTBOX_INSTALLER (its log label) before sourcing this.

AGENTBOX_WORKSPACE="${AGENTBOX_WORKSPACE:-/workspace}"
AGENTBOX_LIB="${BASH_SOURCE[0]}"

log() { printf 'agentbox[%s]: %s\n' "$AGENTBOX_INSTALLER" "$*"; }

# toolchain_versions -> the versions an install depends on. A new Node major changes
# native-module ABIs, and a new uv or pnpm can lay out environments differently, so a
# toolchain bump (agentbox update) must trigger a reinstall.
toolchain_versions() {
  local tool
  for tool in node pnpm uv; do
    printf '%s %s\n' "$tool" "$("$tool" --version 2>/dev/null || echo none)"
  done
}

# stamp_of FILE... -> a hash of each given file's path and contents, the toolchain
# versions, and the source of both the calling installer and this library. Changing
# any of them triggers a reinstall. Missing files are skipped (their appearance later
# still changes the hash).
stamp_of() {
  local f
  {
    for f in "$@"; do
      if [ -f "$f" ]; then printf '%s\n' "$f"; cat "$f"; fi
    done
    toolchain_versions
    cat "$0" "$AGENTBOX_LIB"
  } | sha256sum | cut -d' ' -f1
}

# up_to_date STAMP_FILE STAMP -> success when the recorded stamp matches and
# AGENTBOX_FORCE isn't set.
up_to_date() {
  [ "${AGENTBOX_FORCE:-0}" != 1 ] && [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]
}
