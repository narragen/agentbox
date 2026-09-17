#!/usr/bin/env bash
# Tests for image/agentbox-deps and image/deps.d/*, run on the host against stub
# package managers that record their arguments (no network, no Docker).
set -euo pipefail
. "$(dirname "$0")/assert.sh"
DEPS="$AGENTBOX_ROOT/image/agentbox-deps"
command -v sha256sum >/dev/null || command -v shasum >/dev/null || { echo "needs sha256sum"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/stub"; mkdir -p "$STUB"
# sha256sum may be missing on older macOS; the installers only need its output format.
if ! command -v sha256sum >/dev/null; then
  printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > "$STUB/sha256sum"
fi
export PM_LOG="$TMP/pm.log"
for pm in npm pnpm corepack bun; do
  cat > "$STUB/$pm" <<EOF2
#!/usr/bin/env bash
[ "\${1:-}" = --version ] && { echo "\${FAKE_${pm}_VERSION:-1.0.0}"; exit 0; }
echo "$pm \$* (in \$(basename "\$PWD"))" >> "\$PM_LOG"
[ "\${FAIL_PM:-}" = "$pm" ] && exit 1
exit 0
EOF2
done
cat > "$STUB/node" <<'EOF2'
#!/usr/bin/env bash
echo "${FAKE_NODE_VERSION:-v24.0.0}"
EOF2
cat > "$STUB/uv" <<'EOF2'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { echo "uv 0.1.0"; exit 0; }
echo "uv $*" >> "$PM_LOG"
[ "${FAIL_PM:-}" = uv ] && exit 1
mkvenv() { mkdir -p "$1/bin"; printf '#!/bin/sh\nexit 0\n' > "$1/bin/python"; chmod +x "$1/bin/python"; }
case "$1" in
  sync) mkvenv "$UV_PROJECT_ENVIRONMENT" ;;
  venv) rm -rf "${!#}"; mkvenv "${!#}" ;;
esac
exit 0
EOF2
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"

W="$TMP/ws"
export AGENTBOX_WORKSPACE="$W" AGENTBOX_DEPS_DIR="$AGENTBOX_ROOT/image/deps.d"
export UV_PROJECT_ENVIRONMENT="$TMP/venvs/project"

fresh() { rm -rf "$W" "$TMP/venvs"; mkdir -p "$W"; : > "$PM_LOG"; }
deps() { bash "$DEPS" "$@" 2>&1; }
pmlog() { cat "$PM_LOG"; }
nm() { mkdir -p "$W/${1:-.}/node_modules"; }   # the launcher's volume mount point

# --- Node: package manager chosen by lockfile ---
fresh; printf '{}' > "$W/package.json"; touch "$W/package-lock.json"; nm
out="$(deps)"
assert_contains "package-lock.json -> npm ci" "$(pmlog)" "npm ci --no-audit --no-fund"
assert_contains "install reported done" "$out" "agentbox[node]: .: done"
: > "$PM_LOG"; out="$(deps)"
assert_contains "unchanged -> skipped" "$out" "agentbox[node]: .: up to date"
assert_eq "unchanged -> no package manager call" "" "$(pmlog)"
: > "$PM_LOG"; out="$(deps --force)"
assert_contains "--force reinstalls" "$(pmlog)" "npm ci"
: > "$PM_LOG"; echo '{"x":1}' > "$W/package-lock.json"; deps >/dev/null
assert_contains "lockfile change -> reinstall" "$(pmlog)" "npm ci"
: > "$PM_LOG"; FAKE_NODE_VERSION=v26.0.0 deps >/dev/null
assert_contains "Node upgrade -> reinstall" "$(pmlog)" "npm ci"

fresh; printf '{}' > "$W/package.json"; touch "$W/pnpm-lock.yaml"; nm
deps >/dev/null
assert_contains "pnpm-lock.yaml -> pnpm frozen" "$(pmlog)" "pnpm install --frozen-lockfile"

fresh; printf '{"packageManager":"yarn@4.5.0"}' > "$W/package.json"; touch "$W/yarn.lock"; nm
deps >/dev/null
assert_contains "Yarn 2+ -> --immutable" "$(pmlog)" "corepack yarn install --immutable"
fresh; printf '{"packageManager":"yarn@1.22.22"}' > "$W/package.json"; touch "$W/yarn.lock"; nm
deps >/dev/null
assert_contains "Yarn 1 -> --frozen-lockfile" "$(pmlog)" "corepack yarn install --frozen-lockfile"
fresh; printf '{}' > "$W/package.json"; touch "$W/yarn.lock"; nm
deps >/dev/null
assert_contains "yarn.lock without packageManager -> classic flags" "$(pmlog)" "corepack yarn install --frozen-lockfile"

fresh; printf '{}' > "$W/package.json"; touch "$W/bun.lockb"; nm
out="$(deps)"
assert_contains "bun.lockb -> bun install --frozen-lockfile" "$(pmlog)" "bun install --frozen-lockfile"
assert_contains "bun install reported done" "$out" "agentbox[node]: .: done"

fresh; printf '{}' > "$W/package.json"; touch "$W/bun.lock"; nm
out="$(deps)"
assert_contains "bun.lock -> bun install --frozen-lockfile" "$(pmlog)" "bun install --frozen-lockfile"
: > "$PM_LOG"; out="$(deps)"
assert_contains "bun unchanged -> skipped" "$out" "agentbox[node]: .: up to date"
assert_eq "bun unchanged -> no package manager call" "" "$(pmlog)"
: > "$PM_LOG"; printf 'x\n' >> "$W/bun.lock"; deps >/dev/null
assert_contains "bun lockfile change -> reinstall" "$(pmlog)" "bun install"

fresh; printf '{}' > "$W/package.json"; touch "$W/bun.lock"; nm
rc=0; out="$(FAIL_PM=bun deps)" || rc=$?
assert_eq "bun failure exits non-zero" 1 "$rc"
assert_contains "bun failure named per directory" "$out" "agentbox[node]: .: install FAILED"
if [ ! -f "$W/node_modules/.agentbox-stamp" ]; then pass "failed bun install leaves no stamp"; else fail "failed bun install leaves no stamp"; fi

fresh; printf '{}' > "$W/package.json"; nm
out="$(deps)"
assert_contains "no lockfile -> npm install" "$(pmlog)" "npm install --no-audit --no-fund"
assert_contains "no lockfile -> warns it writes one" "$out" "will create package-lock.json"

fresh; printf '{}' > "$W/package.json"; touch "$W/package-lock.json"; nm
rc=0; out="$(FAIL_PM=npm deps)" || rc=$?
assert_eq "install failure exits non-zero" 1 "$rc"
assert_contains "failure is named per directory" "$out" "agentbox[node]: .: install FAILED"
assert_contains "summary names the installer" "$out" "FAILED in: 10-node.sh"
if [ ! -f "$W/node_modules/.agentbox-stamp" ]; then pass "failed install leaves no stamp"; else fail "failed install leaves no stamp"; fi

# NODE_DIRS: subdirectories, and dirs without package.json are skipped.
fresh; mkdir -p "$W/web" "$W/docs"; printf '{}' > "$W/web/package.json"; touch "$W/web/pnpm-lock.yaml"; nm web
AGENTBOX_NODE_DIRS="web docs" deps >/dev/null
assert_contains "NODE_DIRS subdirectory installed in place" "$(pmlog)" "pnpm install --frozen-lockfile (in web)"
assert_absent "dir without package.json skipped" "$(pmlog)" "(in docs)"

# Workspaces are refused, at the root and from a member.
fresh; printf '{}' > "$W/package.json"; touch "$W/pnpm-lock.yaml"; printf 'onlyBuiltDependencies:\n  - esbuild\n' > "$W/pnpm-workspace.yaml"; nm
deps >/dev/null
assert_contains "settings-only pnpm-workspace.yaml is not a workspace" "$(pmlog)" "pnpm install --frozen-lockfile"
fresh; printf '{}' > "$W/package.json"; touch "$W/pnpm-lock.yaml"; printf 'packages:\n  - apps/*\n' > "$W/pnpm-workspace.yaml"; nm
rc=0; out="$(deps)" || rc=$?
assert_eq "pnpm workspace refused" 1 "$rc"
assert_contains "workspace refusal explains why" "$out" "workspace, which agentbox doesn't support yet"
assert_eq "workspace: no install attempted" "" "$(pmlog)"
fresh; mkdir -p "$W/packages/a"; printf '{"workspaces":["packages/*"]}' > "$W/package.json"; printf '{}' > "$W/packages/a/package.json"; nm packages/a
rc=0; out="$(AGENTBOX_NODE_DIRS=packages/a deps)" || rc=$?
assert_eq "npm workspace member refused" 1 "$rc"
assert_eq "member: no install attempted" "" "$(pmlog)"

# --- Python ---
fresh; printf '[project]\nname="x"\n' > "$W/pyproject.toml"; touch "$W/uv.lock"
out="$(deps)"
assert_contains "pyproject + uv.lock -> uv sync --locked" "$(pmlog)" "uv sync --locked"
: > "$PM_LOG"; out="$(deps)"
assert_contains "python unchanged -> skipped" "$out" "agentbox[python]: .: up to date"
rm "$UV_PROJECT_ENVIRONMENT/bin/python"
: > "$PM_LOG"; out="$(deps)"
assert_contains "broken venv interpreter -> reinstall despite the stamp" "$(pmlog)" "uv sync --locked"
: > "$PM_LOG"; echo "3.12" > "$W/.python-version"; deps >/dev/null
assert_contains ".python-version change -> reinstall" "$(pmlog)" "uv sync"

fresh; printf '[project]\nname="x"\n' > "$W/pyproject.toml"
out="$(deps)"
assert_contains "pyproject without uv.lock -> uv sync" "$(pmlog)" "uv sync"
assert_absent "without uv.lock: not --locked" "$(pmlog)" "--locked"
assert_contains "without uv.lock: warns it writes one" "$out" "will create one"

fresh; printf '[project]\nname="x"\n' > "$W/pyproject.toml"; echo six > "$W/requirements.txt"; touch "$W/uv.lock"
deps >/dev/null
assert_contains "pyproject wins over requirements.txt" "$(pmlog)" "uv sync"
assert_absent "requirements not installed alongside" "$(pmlog)" "pip install"

fresh; echo six > "$W/requirements.txt"; echo pytest > "$W/requirements-dev.txt"
deps >/dev/null
assert_contains "requirements -> fresh venv" "$(pmlog)" "uv venv --clear $UV_PROJECT_ENVIRONMENT"
assert_contains "both requirements files installed" "$(pmlog)" "-r requirements.txt -r requirements-dev.txt"

fresh; printf '[tool.poetry]\nname="x"\n' > "$W/pyproject.toml"
out="$(deps)"
assert_contains "Poetry-style pyproject skipped with a note" "$out" "no [project] table"
assert_eq "Poetry: nothing run" "" "$(pmlog)"

fresh; mkdir -p "$W/backend"; printf '[project]\nname="x"\n' > "$W/backend/pyproject.toml"; touch "$W/backend/uv.lock"
AGENTBOX_PYTHON_DIR=backend deps >/dev/null
assert_contains "PYTHON_DIR honoured" "$(pmlog)" "uv sync --locked"

fresh; echo six > "$W/requirements.txt"
rc=0; out="$(FAIL_PM=uv deps)" || rc=$?
assert_eq "python failure exits non-zero" 1 "$rc"
assert_contains "python failure named" "$out" "FAILED in: 20-python.sh"

fresh
out="$(deps)"
assert_eq "empty project: nothing to do" "" "$out"

# --- setup.sh and arguments ---
fresh; mkdir -p "$W/.agentbox"; printf 'echo "SETUP in $(basename "$PWD")"\n' > "$W/.agentbox/setup.sh"
out="$(deps)"
assert_contains "setup.sh runs from the project root" "$out" "SETUP in ws"
printf 'exit 3\n' > "$W/.agentbox/setup.sh"
rc=0; out="$(deps)" || rc=$?
assert_eq "setup.sh failure exits non-zero" 1 "$rc"
assert_contains "setup.sh failure named" "$out" "FAILED in: .agentbox/setup.sh"
rc=0; deps --bogus >/dev/null || rc=$?
assert_eq "bad argument exits 2" 2 "$rc"

finish
