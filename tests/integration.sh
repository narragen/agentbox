#!/usr/bin/env bash
# End-to-end checks of the built image. Each launch uses the exact `docker run` argv
# that `agentbox run` builds (minus the TTY) and the real entrypoint; in-box checks
# are piped into the interactive zsh the entrypoint starts.
#   agentbox build && bash tests/integration.sh
# Needs Docker and network access (package registries, one Python download).
# Creates and removes its own volumes and images.
set -euo pipefail
. "$(dirname "$0")/assert.sh"
AB="$AGENTBOX_ROOT/bin/agentbox"
AGENTBOX_HOME="$AGENTBOX_ROOT"
. "$AGENTBOX_ROOT/lib/common.sh"
docker image inspect agentbox:latest >/dev/null || { echo "build the image first: agentbox build"; exit 1; }

TMP="$(mktemp -d)"
H="$TMP/home"; mkdir -p "$H/.config/agentbox"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = Box Test\n\temail = box@test.example\n' > "$GIT_CONFIG_GLOBAL"
# Every fixture directory a box is launched from. Cleanup derives the box names from
# this list (launch runs inside $(...), so it can't record them itself).
FIXTURES=("$TMP/proj" "$TMP/py312" "$TMP/pyproj" "$TMP/feature" "$TMP/dockerproj" "$TMP/bunproj")
cleanup() {
  local d n
  for d in "${FIXTURES[@]}"; do
    n="$(sandbox_name "$d")"
    docker volume ls -q | grep -E "$(volume_pattern "$n")" | xargs docker volume rm >/dev/null 2>&1 || true
    docker image rm "agentbox-proj:$n" >/dev/null 2>&1 || true
  done
  # Files written by the box may belong to its user; make them removable.
  chmod -R u+w "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# launch DIR [IN-BOX COMMANDS] -> combined output of the entrypoint and the commands.
launch() {
  local dir="$1" script="${2:-}" argv=() line out=() a vol
  while IFS= read -r line; do argv+=("$line"); done \
    < <(env -u XDG_CONFIG_HOME -u XDG_CACHE_HOME HOME="$H" AGENTBOX_DRY_RUN=1 bash "$AB" run "$dir" 2>/dev/null)
  for a in "${argv[@]}"; do
    if [ "$a" = "-it" ]; then out+=(-i); else out+=("$a"); fi
  done
  # The dry run skips volume setup; do it the way the launcher does.
  for a in "${out[@]}"; do
    case "$a" in agentbox-nm-*:*) vol="${a%%:*}"; ensure_node_volume "$vol" "${out[${#out[@]}-1]}" ;; esac
  done
  printf '%s\nexit\n' "$script" | "${out[@]}" 2>&1
}

# ---------------------------------------------------------------------------------------
echo "-- project with npm, pnpm, requirements.txt and setup.sh"
F="$TMP/proj"; mkdir -p "$F/web" "$F/.agentbox"
git init -q "$F"
printf '{"name":"root","version":"1.0.0","dependencies":{"is-number":"7.0.0"}}\n' > "$F/package.json"
printf '{"name":"web","version":"1.0.0","dependencies":{"is-odd":"3.0.1"}}\n' > "$F/web/package.json"
printf 'six==1.17.0\n' > "$F/requirements.txt"
printf 'NODE_DIRS=. web\n' > "$F/.agentbox/config"
printf 'echo SETUP-RAN\n' > "$F/.agentbox/setup.sh"
printf '{\n  // project override\n  "permission": {"bash": {"git push *": "ask"}}\n}\n' > "$F/.agentbox/opencode.jsonc"
printf '{"permissions":{"deny":["Bash(rm -rf:*)"]}}\n' > "$F/.agentbox/claude.settings.json"
printf 'cli_auth_credentials_store = "file"\n# PROJECT-CODEX-PROFILE\n' > "$F/.agentbox/codex.config.toml"
printf 'repos: []\n' > "$F/.pre-commit-config.yaml"
docker run --rm --user node -v "$F":/workspace agentbox:latest bash -c \
  'cd /workspace && npm install --package-lock-only --silent && cd web && pnpm install --lockfile-only --silent' >/dev/null
printf 'GH_TOKEN=dummy-token\nCLAUDE_CODE_OAUTH_TOKEN=\n' > "$H/.config/agentbox/env"
chmod 600 "$H/.config/agentbox/env"

OUT1="$(launch "$F")"
assert_contains "root npm install ran" "$OUT1" "agentbox[node]: .: done"
assert_contains "web pnpm install ran" "$OUT1" "agentbox[node]: web: done"
assert_contains "python install ran" "$OUT1" "agentbox[python]: .: done"
assert_contains "project setup.sh ran" "$OUT1" "SETUP-RAN"
assert_contains "banner shown" "$OUT1" "agentbox ready"
assert_contains "pre-commit hint instead of an install" "$OUT1" "this repo uses pre-commit"
assert_absent "no setup warnings" "$OUT1" "WARN"
if [ ! -e "$F/.git/hooks/pre-commit" ]; then pass "host .git/hooks/pre-commit untouched"; else fail "the box installed a pre-commit hook into the host repo"; fi

echo "-- relaunch is cached"
OUT2="$(launch "$F")"
assert_contains "node skipped when unchanged" "$OUT2" "agentbox[node]: .: up to date"
assert_contains "python skipped when unchanged" "$OUT2" "agentbox[python]: .: up to date"

echo "-- inside the box (fresh agent volumes, real entrypoint and zsh)"
PNAME="$(sandbox_name "$(cd "$F" && pwd)")"
docker volume rm "$(agent_volume claude "$PNAME")" "$(agent_volume codex "$PNAME")" >/dev/null
MCP_CLI="/usr/local/share/npm-global/lib/node_modules/@playwright/mcp/cli.js"
IN="$(launch "$F" '
setopt nobanghist
cd /workspace
echo "WHO $(id -un) $(id -u)"
sudo true 2>/dev/null || echo NO-SUDO
node -e "require(\"is-number\"); console.log(\"NODE-ROOT-OK\")"
(cd web && node -e "require(\"is-odd\"); console.log(\"NODE-WEB-OK\")")
python -c "import six, sys; print(\"PY-OK\", sys.prefix)"
touch /workspace/written-by-box && echo "OWNER $(stat -c %u /workspace/written-by-box)"
echo "TOKEN-GH ${GH_TOKEN:-unset} TOKEN-CC ${CLAUDE_CODE_OAUTH_TOKEN-unset}"
echo "INSTEADOF $(git config --global --get-all url.https://github.com/.insteadof | wc -l)"
echo "GCEXPIRE $(git config --global --get gc.worktreePruneExpire)"
echo "SKIPDIALOG $(jq -r .skipDangerousModePermissionPrompt /etc/claude-code/managed-settings.json)"
command claude mcp list 2>/dev/null | grep -F playwright | sed "s/^/CLAUDE-MCP /"
command codex mcp list 2>/dev/null | grep -F playwright | sed "s/^/CODEX-MCP /"
opencode debug config 2>/dev/null > /tmp/oc.json
# v2: permissions are an array of {action, resource, effect} objects
jq -r '.permissions[] | .action + ":" + .resource' /tmp/oc.json | sort | sed "s/^/OC-BASH /"
# v2: MCP servers moved to .mcp.servers.<name>.command
jq -r '.mcp.servers.playwright.command[]' /tmp/oc.json | paste -sd' ' | sed "s/^/OC-MCP /"
mkdir -p ~/.local/bin
printf "#!/bin/sh\necho STUB-ARGS \"\$*\"\n" > ~/.local/bin/codex
cp ~/.local/bin/codex ~/.local/bin/claude
chmod +x ~/.local/bin/codex ~/.local/bin/claude
hash -r
command -v codex | sed "s/^/CODEX-RESOLVES /"
codex exec hello </dev/null | sed "s/^/CODEX-EXEC /"
codex login status </dev/null | sed "s/^/CODEX-LOGIN /"
codex </dev/null | sed "s/^/CODEX-BARE /"
grep -c PROJECT-CODEX-PROFILE ~/.codex/container.config.toml | sed "s/^/CODEX-PROFILE /"
claude -p hi </dev/null | sed "s/^/CLAUDE-ARGS /"
echo "{\"tool_input\":{\"command\":\"git worktree prune\"}}" | /etc/agentbox/hooks/guard-git-worktree.sh >/dev/null 2>&1; echo "GUARD-EXIT $?"
')"
assert_contains "runs as node" "$IN" "WHO node"
assert_contains "no sudo in the box" "$IN" "NO-SUDO"
assert_contains "root node_modules resolves" "$IN" "NODE-ROOT-OK"
assert_contains "web node_modules resolves" "$IN" "NODE-WEB-OK"
assert_contains "venv python has requirements" "$IN" "PY-OK /home/node/.venvs/project"
if [ "$(uname -s)" = Linux ]; then
  assert_contains "files written in the box belong to the host user" "$IN" "OWNER $(id -u)"
fi
assert_contains "GH_TOKEN reaches the box" "$IN" "TOKEN-GH dummy-token"
assert_contains "an empty token is dropped, not exported" "$IN" "TOKEN-CC unset"
assert_contains "GH_TOKEN enables three SSH->HTTPS rewrites" "$IN" "INSTEADOF 3"
assert_contains "git gc never prunes worktrees in the box" "$IN" "GCEXPIRE never"
assert_contains "Claude's bypass dialog is pre-accepted by managed settings" "$IN" "SKIPDIALOG true"
assert_contains "entrypoint registers Playwright with Claude (fresh volume)" "$IN" "CLAUDE-MCP playwright: node $MCP_CLI --browser chromium --no-sandbox"
assert_contains "entrypoint registers Playwright with Codex (fresh volume)" "$IN" "CODEX-MCP playwright"
assert_contains "opencode wrapper merges base, project (JSONC) and managed rules in order" "$IN" "OC-BASH bash:git push *"
assert_contains "opencode wrapper merges base, project (JSONC) and managed rules in order" "$IN" "OC-BASH bash:git worktree prune *"
assert_contains "opencode Playwright MCP has the resolved path" "$IN" "OC-MCP node $MCP_CLI --browser chromium --no-sandbox"
assert_contains "codex runtime commands skip Codex's sandbox and use the profile" "$IN" "CODEX-EXEC STUB-ARGS --dangerously-bypass-approvals-and-sandbox --profile container exec hello"
assert_contains "codex with no arguments gets the same flags" "$IN" "CODEX-BARE STUB-ARGS --dangerously-bypass-approvals-and-sandbox --profile container"
assert_contains "codex non-runtime subcommands get no flags" "$IN" "CODEX-LOGIN STUB-ARGS login status"
assert_contains "project codex.config.toml becomes the profile" "$IN" "CODEX-PROFILE 1"
assert_contains "claude gets bypass plus the project settings" "$IN" "CLAUDE-ARGS STUB-ARGS --dangerously-skip-permissions --settings /workspace/.agentbox/claude.settings.json -p hi"
assert_contains "worktree guard blocks" "$IN" "GUARD-EXIT 2"
if [ -z "$(ls -A "$F/node_modules")" ]; then pass "host node_modules untouched (volume-backed)"; else fail "host node_modules untouched"; fi

echo "-- dependency file changes"
printf 'six==1.17.0\npackaging==25.0\n' > "$F/requirements.txt"
OUT3="$(launch "$F")"
assert_contains "python reinstalls after requirements change" "$OUT3" "agentbox[python]: .: installing"
assert_contains "node still cached" "$OUT3" "agentbox[node]: .: up to date"
printf '{"name":"root","version":"1.0.0","dependencies":{"is-number":"7.0.0","is-odd":"3.0.1"}}\n' > "$F/package.json"
OUT4="$(launch "$F")"
assert_contains "out-of-sync lockfile: npm ci failure reported" "$OUT4" "agentbox[node]: .: install FAILED"
assert_contains "failure summary names the installer" "$OUT4" "dependency setup FAILED in: 10-node.sh"
assert_contains "shell still starts" "$OUT4" "agentbox ready"

# ---------------------------------------------------------------------------------------
echo "-- a project pinned to a different Python survives relaunch"
P="$TMP/py312"; mkdir -p "$P"
printf '3.12\n' > "$P/.python-version"
printf 'six==1.17.0\n' > "$P/requirements.txt"
launch "$P" >/dev/null
PY2="$(launch "$P" 'python -c "import six, sys; print(\"PY312\", sys.version_info[:2])"')"
assert_contains "second launch: still up to date" "$PY2" "agentbox[python]: .: up to date"
assert_contains "second launch: the 3.12 venv still works" "$PY2" "PY312 (3, 12)"

echo "-- pyproject + uv.lock in PYTHON_DIR"
Q="$TMP/pyproj"; mkdir -p "$Q/backend" "$Q/.agentbox"
printf '[project]\nname = "demo"\nversion = "0.1.0"\nrequires-python = ">=3.12"\ndependencies = ["six==1.17.0"]\n' > "$Q/backend/pyproject.toml"
printf 'PYTHON_DIR=backend\n' > "$Q/.agentbox/config"
docker run --rm --user node -v "$Q":/workspace agentbox:latest bash -c 'cd /workspace/backend && uv lock -q' >/dev/null
QO="$(launch "$Q" 'python -c "import six; print(\"UVSYNC-OK\")"')"
assert_contains "uv sync --locked in backend/" "$QO" "agentbox[python]: backend: done"
assert_contains "synced packages importable" "$QO" "UVSYNC-OK"

# ---------------------------------------------------------------------------------------
echo "-- bun project"
B="$TMP/bunproj"; mkdir -p "$B"
printf '{"name":"bunproj","version":"1.0.0","dependencies":{"is-number":"7.0.0"}}\n' > "$B/package.json"
printf 'console.log("BUN-REQUIRE", require("is-number")(7))\n' > "$B/check.js"
# Generate a real bun.lock with the image's own bun (follows the npm/pnpm fixture pattern).
docker run --rm --user node -v "$B":/workspace agentbox:latest bash -c \
  'cd /workspace && bun install --lockfile-only' >/dev/null
# sha256 of a file, via shasum where sha256sum is missing (older macOS), as in test-deps.sh.
file_hash() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
BUN_LOCK_HASH="$(file_hash "$B/bun.lock")"
BUN_PIN="$(sed -n 's/^BUN_VERSION=//p' "$AGENTBOX_ROOT/versions.env")"
BO="$(launch "$B")"
assert_contains "bun install ran" "$BO" "agentbox[node]: .: installing"
assert_contains "bun frozen install succeeded" "$BO" "agentbox[node]: .: done"
BO2="$(launch "$B" 'echo "BUN-VER $(bun --version) BUNX $(bunx --version)"
cd /workspace && bun run check.js')"
assert_contains "bun relaunch is cached" "$BO2" "agentbox[node]: .: up to date"
assert_contains "bun and bunx on PATH at the versions.env pin" "$BO2" "BUN-VER $BUN_PIN BUNX $BUN_PIN"
assert_contains "bun resolves the frozen install" "$BO2" "BUN-REQUIRE true"
printf '{"name":"bunproj","version":"1.0.0","dependencies":{"is-number":"7.0.0","is-odd":"3.0.1"}}\n' > "$B/package.json"
BO3="$(launch "$B")"
assert_contains "out-of-sync lockfile: bun failure reported" "$BO3" "agentbox[node]: .: install FAILED"
assert_eq "host bun.lock untouched by frozen installs" "$BUN_LOCK_HASH" "$(file_hash "$B/bun.lock")"

# ---------------------------------------------------------------------------------------
echo "-- linked worktree"
R="$TMP/repo"; git init -q -b main "$R"
git -C "$R" commit -q --allow-empty -m init
git -C "$R" worktree add -q "$TMP/feature" -b feature
git -C "$R" worktree add -q "$TMP/sibling" -b sibling
# Make the sibling's metadata look old enough for gc's default expiry (3 months).
find "$R/.git/worktrees/sibling" -exec touch -t 202001010000 {} +
WT="$(launch "$TMP/feature" '
cd /workspace
echo "BRANCH $(git rev-parse --abbrev-ref HEAD)"
echo "STATUS [$(git status --porcelain)]"
git commit -q --allow-empty -m from-box && echo COMMIT-OK
mkdir -p /tmp/scratch && cd /tmp/scratch && git init -q && git remote add upstream https://example.invalid/x && echo NESTED-OK
cd /workspace && git gc -q && echo GC-OK
')"
assert_contains "git sees the linked branch" "$WT" "BRANCH feature"
assert_contains "git status is clean" "$WT" "STATUS []"
assert_contains "commits work" "$WT" "COMMIT-OK"
assert_eq "the commit landed on the feature branch" "from-box" "$(git -C "$R" log -1 --format=%s feature)"
assert_contains "a nested git init stays nested" "$WT" "NESTED-OK"
assert_eq "host repo has no stray core.worktree" "" "$(git -C "$R" config --get core.worktree || true)"
assert_eq "host repo has no stray remote" "" "$(git -C "$R" remote)"
assert_contains "git gc ran" "$WT" "GC-OK"
assert_contains "git gc kept the sibling worktree" "$(git -C "$R" worktree list)" "$TMP/sibling"

# ---------------------------------------------------------------------------------------
echo "-- project Dockerfile (ending as root) still runs the box as node"
D="$TMP/dockerproj"; mkdir -p "$D/.agentbox"
printf 'ARG AGENTBOX_IMAGE\nFROM ${AGENTBOX_IMAGE}\nUSER root\nRUN echo marker > /etc/agentbox-proj-marker\n' > "$D/.agentbox/Dockerfile"
DNAME="$(sandbox_name "$(cd "$D" && pwd)")"
build_images "$(cd "$D" && pwd)" "$DNAME" quiet 2>/dev/null
DO="$(launch "$D" 'echo "PROJ $(cat /etc/agentbox-proj-marker) $(id -u)"')"
assert_contains "project image is used" "$DO" "PROJ marker"
assert_absent "and the box is not root" "$DO" "PROJ marker 0"

finish
