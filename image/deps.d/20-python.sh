#!/usr/bin/env bash
# Python dependencies, installed with uv into $UV_PROJECT_ENVIRONMENT (a per-box
# volume, kept outside /workspace so it never collides with a host .venv).
#
# In AGENTBOX_PYTHON_DIR (default "."):
#   pyproject.toml with a [project] table -> uv sync (--locked when uv.lock exists)
#   otherwise requirements.txt / requirements-dev.txt -> uv pip install into a fresh venv
# .python-version is honoured in both cases.
set -euo pipefail
# shellcheck disable=SC2034  # read by lib.bash
AGENTBOX_INSTALLER=python
# shellcheck source=lib.bash
. "$(dirname "$0")/lib.bash"

dir="${AGENTBOX_PYTHON_DIR:-.}"
root="$AGENTBOX_WORKSPACE/$dir"
[ "$dir" = . ] && root="$AGENTBOX_WORKSPACE"
venv="${UV_PROJECT_ENVIRONMENT:?UV_PROJECT_ENVIRONMENT must be set (the image sets it)}"

reqs=()
for f in requirements.txt requirements-dev.txt; do
  [ -f "$root/$f" ] && reqs+=("$f")
done

mode=""
if [ -f "$root/pyproject.toml" ] && grep -q '^\[project\]' "$root/pyproject.toml"; then
  mode=sync
elif [ "${#reqs[@]}" -gt 0 ]; then
  mode=pip
elif [ -f "$root/pyproject.toml" ]; then
  log "$dir/pyproject.toml has no [project] table (Poetry?); skipping. Install from .agentbox/setup.sh instead."
  exit 0
else
  exit 0
fi

stamp_file="$venv/.agentbox-stamp"
stamp="$(stamp_of "$root"/pyproject.toml "$root"/uv.lock "$root"/.python-version \
  "$root"/requirements.txt "$root"/requirements-dev.txt)"
# A matching stamp is not enough: the venv's interpreter must still run (it links to a
# Python outside the venv).
if up_to_date "$stamp_file" "$stamp" && "$venv/bin/python" -c '' 2>/dev/null; then
  log "$dir: up to date"
  exit 0
fi

cd "$root"
log "$dir: installing ($mode)"
if [ "$mode" = sync ]; then
  if [ -f uv.lock ]; then
    uv sync --locked
  else
    log "no uv.lock found; 'uv sync' will create one in your project"
    uv sync
  fi
else
  uv venv --clear "$venv"
  req_args=()
  for f in "${reqs[@]}"; do req_args+=(-r "$f"); done
  uv pip install --python "$venv/bin/python" "${req_args[@]}"
fi
printf '%s\n' "$stamp" > "$stamp_file"
log "$dir: done"
