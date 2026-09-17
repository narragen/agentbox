#!/usr/bin/env bash
# shellcheck disable=SC2088  # a literal ~ in binds-file content is the point
# Tests for bin/agentbox without Docker: `run` argv assembly (AGENTBOX_DRY_RUN=1),
# init, version/help dispatch, symlinked installs, git handling and the heal.
set -euo pipefail
. "$(dirname "$0")/assert.sh"
AB="$AGENTBOX_ROOT/bin/agentbox"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/xdg-config" XDG_CACHE_HOME="$TMP/xdg-cache"
# Keep the developer's real git config out of these tests.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global" GIT_CONFIG_NOSYSTEM=1
touch "$GIT_CONFIG_GLOBAL"
H="$TMP/home"; mkdir -p "$H"

dry() { HOME="$H" AGENTBOX_DRY_RUN=1 bash "$AB" "$@" 2>/dev/null; }
dry_all() { HOME="$H" AGENTBOX_DRY_RUN=1 bash "$AB" "$@" 2>&1; }

# --- Host binds: present paths bound, absent ones skipped ---
mkdir -p "$H/.claude/skills" "$H/.codex" "$H/.config/opencode" "$TMP/ws"
printf x > "$H/.claude/CLAUDE.md"
printf x > "$H/.codex/auth.json"
printf '{}' > "$H/.config/opencode/opencode.jsonc"
printf x > "$H/.claude/claude-learnings.md"
OUT="$(dry run "$TMP/ws")"
assert_line "binds present CLAUDE.md read-only" "$OUT" "$H/.claude/CLAUDE.md:/home/node/.claude/CLAUDE.md:ro"
assert_line "binds present skills dir read-only" "$OUT" "$H/.claude/skills:/home/node/.claude/skills:ro"
assert_line "binds codex auth.json read-write" "$OUT" "$H/.codex/auth.json:/home/node/.codex/auth.json"
assert_line "binds global opencode.jsonc read-only" "$OUT" "$H/.config/opencode/opencode.jsonc:/home/node/.config/opencode/opencode.jsonc:ro"
assert_absent "skips absent .credentials.json (protects host login)" "$OUT" ".credentials.json"
assert_absent "skips absent settings.json" "$OUT" "/home/node/.claude/settings.json"
assert_absent "personal files are not bound by default" "$OUT" "claude-learnings.md"

# --- Core wiring, element by element ---
assert_line "workspace bound" "$OUT" "$TMP/ws:/workspace"
assert_line "marker env" "$OUT" "AGENTBOX=1"
assert_line "default node dirs passed" "$OUT" "AGENTBOX_NODE_DIRS=."
assert_line "default python dir passed" "$OUT" "AGENTBOX_PYTHON_DIR=."
assert_line "runs the base image" "$OUT" "agentbox:latest"
assert_line "always runs as node" "$OUT" "node"
assert_contains "--user precedes node" "$(printf '%s\n' "$OUT" | grep -A1 -x -- '--user')" "node"
assert_line "drops all capabilities" "$OUT" "ALL"
assert_line "no-new-privileges" "$OUT" "no-new-privileges"
assert_line "an init process reaps zombies" "$OUT" "--init"
assert_absent "no node_modules volume without package.json" "$OUT" "node_modules"
assert_no_line "no env-file when none exists" "$OUT" "--env-file"
assert_absent "never sets GIT_DIR" "$OUT" "GIT_DIR"
assert_absent "never sets GIT_WORK_TREE" "$OUT" "GIT_WORK_TREE"

# Every volume the launcher mounts must be one `agentbox clean` would delete.
NW="$TMP/nodews"; mkdir -p "$NW/.agentbox" "$NW/frontend" "$NW/docs"
printf '{}' > "$NW/package.json"; printf '{}' > "$NW/frontend/package.json"
printf 'NODE_DIRS=. frontend docs\n' > "$NW/.agentbox/config"
NOUT="$(dry run "$NW")"
AGENTBOX_HOME="$AGENTBOX_ROOT"; . "$AGENTBOX_ROOT/lib/common.sh"
pat="$(volume_pattern "$(sandbox_name "$NW")")"
vols="$(printf '%s\n' "$NOUT" | sed -n 's/^\(agentbox-[^:]*\):.*/\1/p')"
assert_eq "six volumes mounted (4 agent/venv + 2 node_modules)" 6 "$(printf '%s\n' "$vols" | wc -l | tr -d ' ')"
for v in $vols; do
  if printf '%s' "$v" | grep -Eq "$pat"; then pass "clean would find $v"; else fail "clean would miss $v" "$pat"; fi
done

name_of() { printf '%s\n' "$1" | grep -A1 -x -- '--name' | tail -1; }
mkdir -p "$TMP/other/ws"
if [ "$(name_of "$OUT")" != "$(name_of "$(dry run "$TMP/other/ws")")" ]; then
  pass "same-basename dirs get different boxes"
else
  fail "same-basename dirs get different boxes"
fi

# --- node_modules volumes ---
assert_contains "root node_modules volume at a clean path" "$NOUT" ":/workspace/node_modules"
assert_contains "frontend node_modules volume" "$NOUT" ":/workspace/frontend/node_modules"
assert_absent "dir without package.json gets no volume" "$NOUT" "/workspace/docs/node_modules"
assert_line "configured node dirs passed to the box" "$NOUT" "AGENTBOX_NODE_DIRS=. frontend docs"
printf 'NODE_DIRS=../escape\n' > "$NW/.agentbox/config"
assert_contains "invalid config aborts the launch with the reason" "$(dry_all run "$NW" || true)" "relative path inside the project"

# --- Paths with spaces stay one argument ---
SP="$TMP/with space"; mkdir -p "$SP"
assert_line "a path with spaces is a single argv element" "$(dry run "$SP")" "$SP:/workspace"

# --- Project image ---
PW="$TMP/projws"; mkdir -p "$PW/.agentbox"; printf 'FROM x\n' > "$PW/.agentbox/Dockerfile"
assert_contains "project Dockerfile selects the project image" "$(dry run "$PW")" "agentbox-proj:projws-"

# --- Env file ---
mkdir -p "$XDG_CONFIG_HOME/agentbox"
printf 'GH_TOKEN=secret-value\n' > "$XDG_CONFIG_HOME/agentbox/env"
chmod 644 "$XDG_CONFIG_HOME/agentbox/env"
assert_line "env file passed with --env-file" "$(dry run "$TMP/ws")" "--env-file"
assert_contains "warns when env file is readable by others" "$(dry_all run "$TMP/ws")" "readable by other users"
chmod 600 "$XDG_CONFIG_HOME/agentbox/env"
assert_absent "no warning at mode 600" "$(dry_all run "$TMP/ws")" "readable by other users"
assert_absent "token values never appear in argv" "$(dry run "$TMP/ws")" "secret-value"
rm "$XDG_CONFIG_HOME/agentbox/env"

# --- User binds file ---
printf '~/.claude/claude-learnings.md:/home/node/.claude/claude-learnings.md:rw\n' > "$XDG_CONFIG_HOME/agentbox/binds"
assert_line "user binds are mounted" "$(dry run "$TMP/ws")" "$H/.claude/claude-learnings.md:/home/node/.claude/claude-learnings.md:rw"
printf 'bogus\n' > "$XDG_CONFIG_HOME/agentbox/binds"
assert_contains "a broken binds file aborts the launch" "$(dry_all run "$TMP/ws" || true)" "expected SOURCE:DEST"
rm "$XDG_CONFIG_HOME/agentbox/binds"

# --- Time zone ---
if [ -L /etc/localtime ]; then
  assert_contains "host time zone passed" "$(dry run "$TMP/ws")" "TZ="
fi

# --- Git identity: name/email only ---
GW="$TMP/gitws"; git init -q "$GW"
cat > "$GIT_CONFIG_GLOBAL" <<'CFG'
[user]
	name = Dev Eloper
	email = dev@example.com
[credential]
	helper = osxkeychain
[url "git@github.com:"]
	insteadOf = https://github.com/
[commit]
	gpgsign = true
CFG
GOUT="$(dry run "$GW")"
src="$(printf '%s\n' "$GOUT" | grep -F ':/home/node/.gitconfig-host:ro' | sed 's#:/home/node/.gitconfig-host:ro$##')"
if [ -n "$src" ] && [ -f "$src" ]; then
  snippet="$(cat "$src")"
  assert_contains "identity snippet has name" "$snippet" "Dev Eloper"
  assert_contains "identity snippet has email" "$snippet" "dev@example.com"
  assert_absent "identity snippet drops credential helper" "$snippet" "osxkeychain"
  assert_absent "identity snippet drops url rewrites" "$snippet" "insteadOf"
  assert_absent "identity snippet drops signing" "$snippet" "gpgsign"
  case "$src" in "$XDG_CACHE_HOME"/*) pass "snippet lives in the per-user cache dir" ;; *) fail "snippet location" "$src" ;; esac
else
  fail "identity snippet mounted" "src=$src"
fi
: > "$GIT_CONFIG_GLOBAL"
assert_absent "no identity, no snippet mount" "$(dry run "$GW")" ".gitconfig-host"

# includeIf: identity is resolved in the target directory's context.
WREAL="$(cd "$GW" && pwd -P)"
cat > "$GIT_CONFIG_GLOBAL" <<CFG
[user]
	name = Global Dev
	email = global@example.com
[includeIf "gitdir:$WREAL/"]
	path = $TMP/gitconfig-work
CFG
printf '[user]\n\tname = Work Identity\n\temail = work@corp.example\n' > "$TMP/gitconfig-work"
IOUT="$(dry run "$GW")"
isrc="$(printf '%s\n' "$IOUT" | grep -F ':/home/node/.gitconfig-host:ro' | sed 's#:/home/node/.gitconfig-host:ro$##')"
assert_contains "includeIf identity used" "$(cat "$isrc")" "Work Identity"
assert_absent "global identity not used" "$(cat "$isrc")" "Global Dev"

# --- Linked worktree: only the common .git is mounted, at the same path ---
R="$TMP/repo"; git init -q "$R"
git -C "$R" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$R" worktree add -q "$TMP/linked" -b linked
RREAL="$(cd "$R/.git" && pwd -P)"  # git records physical paths (macOS /var -> /private/var)
LOUT="$(dry run "$TMP/linked")"
assert_line "linked worktree mounts the common .git at its own path" "$LOUT" "$RREAL:$RREAL"
assert_absent "linked worktree gets no GIT_DIR" "$LOUT" "GIT_DIR"
assert_absent "the 'linked worktree' note stays off stdout (argv)" "$LOUT" "agentbox: "
assert_contains "the note goes to stderr" "$(dry_all run "$TMP/linked")" "linked worktree: also mounting"
assert_no_line "main checkout mounts nothing extra" "$(dry run "$R")" "$RREAL:$RREAL"

mkdir -p "$R/sub"
SOUT="$(dry_all run "$R/sub")"
assert_contains "repo subdirectory warns that git won't work" "$SOUT" "is not its root"
assert_no_line "repo subdirectory mounts no .git" "$SOUT" "$RREAL:$RREAL"

# A .git FILE that points somewhere it shouldn't is refused, not mounted.
CR="$TMP/crafted"; mkdir -p "$CR"
printf 'gitdir: %s\n' "$RREAL" > "$CR/.git"
assert_contains "a .git file pointing at another repo is refused" "$(dry_all run "$CR" || true)" "isn't a worktree or submodule"
printf 'gitdir: %s/worktrees/linked\n' "$RREAL" > "$CR/.git"
assert_contains "a .git file borrowing another worktree's record is refused" "$(dry_all run "$CR" || true)" "belongs to"
printf 'gitdir: ../repo/.git/worktrees/linked\n' > "$CR/.git"
assert_contains "relative worktree paths get a clear error" "$(dry_all run "$CR" || true)" "useRelativePaths"

# --- core.worktree heal, main and linked (with rev-parse broken) ---
git config -f "$R/.git/config" core.worktree /workspace
assert_contains "heal logged (main)" "$(dry_all run "$R")" "removed stray core.worktree=/workspace"
assert_eq "heal cleared (main)" "" "$(git config -f "$R/.git/config" --get core.worktree || true)"

git config -f "$R/.git/config" core.worktree /workspace
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/git" <<STUBEOF
#!/usr/bin/env bash
case " \$* " in *" rev-parse "*) exit 1 ;; esac
exec "$(command -v git)" "\$@"
STUBEOF
chmod +x "$STUB/git"
PATH="$STUB:$PATH" HOME="$H" AGENTBOX_DRY_RUN=1 bash "$AB" run "$TMP/linked" >/dev/null 2>&1
assert_eq "heal works through a linked worktree without rev-parse" "" "$(git config -f "$R/.git/config" --get core.worktree || true)"

git config -f "$R/.git/config" core.worktree /elsewhere
dry run "$R" >/dev/null
assert_eq "a legitimate core.worktree is left alone" "/elsewhere" "$(git config -f "$R/.git/config" --get core.worktree)"
git config -f "$R/.git/config" --unset core.worktree

# --- Broad folders are refused ---
assert_contains "home folder is refused" "$(HOME="$TMP/ws" AGENTBOX_DRY_RUN=1 bash "$AB" run "$TMP/ws" 2>&1 || true)" "your home folder"
assert_contains "a folder containing home is refused" "$(HOME="$TMP/ws/me" AGENTBOX_DRY_RUN=1 bash "$AB" run "$TMP/ws" 2>&1 || true)" "your home folder"
assert_contains "/ is refused" "$(dry_all run / || true)" "refusing to open"
assert_line "a project inside home is fine" "$(HOME="$TMP" AGENTBOX_DRY_RUN=1 bash "$AB" run "$TMP/ws" 2>/dev/null)" "$TMP/ws:/workspace"

# --- Command forms ---
assert_line "bare directory argument runs" "$(dry "$TMP/ws")" "$TMP/ws:/workspace"
assert_line "no arguments uses the current directory" "$(cd "$TMP/ws" && HOME="$H" AGENTBOX_DRY_RUN=1 bash "$AB" 2>/dev/null)" "$TMP/ws:/workspace"
rc=0; HOME="$H" bash "$AB" bogus-cmd >/dev/null 2>&1 || rc=$?
assert_eq "unknown command exits 2" 2 "$rc"
rc=0; HOME="$H" bash "$AB" -x >/dev/null 2>&1 || rc=$?
assert_eq "unknown flag exits 2" 2 "$rc"
rc=0; HOME="$H" bash "$AB" help >/dev/null 2>&1 || rc=$?
assert_eq "help exits 0" 0 "$rc"
assert_contains "missing directory is reported" "$(HOME="$H" AGENTBOX_DRY_RUN=1 bash "$AB" run "$TMP/nope" 2>&1 || true)" "not a directory"
VOUT="$(HOME="$H" bash "$AB" version)"
assert_contains "version names the checkout" "$VOUT" "agentbox "
assert_contains "version lists pins" "$VOUT" "CLAUDE_CODE_VERSION="
rc=0; PIPED="$(HOME="$H" bash "$AB" run "$TMP/ws" </dev/null 2>&1)" || rc=$?
assert_contains "refuses to run without a terminal" "$PIPED" "needs an interactive terminal"

# --- Symlinked install (how every user runs it) ---
mkdir -p "$TMP/bin1" "$TMP/bin2"
ln -s "$AB" "$TMP/bin1/agentbox"                       # absolute link
ln -s ../bin1/agentbox "$TMP/bin2/agentbox"            # relative link to a link
assert_contains "absolute symlink finds its home" "$(HOME="$H" "$TMP/bin1/agentbox" version)" "($AGENTBOX_ROOT)"
assert_contains "relative symlink chain finds its home" "$(HOME="$H" "$TMP/bin2/agentbox" version)" "($AGENTBOX_ROOT)"
assert_line "symlinked run works" "$(HOME="$H" AGENTBOX_DRY_RUN=1 "$TMP/bin2/agentbox" run "$TMP/ws" 2>/dev/null)" "$TMP/ws:/workspace"

# --- init ---
IW="$TMP/initws"; mkdir -p "$IW"
IOUT="$(HOME="$H" bash "$AB" init "$IW")"
for f in "$AGENTBOX_ROOT"/templates/*; do
  b="$(basename "$f")"
  if cmp -s "$f" "$IW/.agentbox/$b"; then pass "init copies $b"; else fail "init copies $b"; fi
done
echo "mine" > "$IW/.agentbox/config"
IOUT2="$(HOME="$H" bash "$AB" init "$IW")"
assert_contains "second init reports existing files" "$IOUT2" "exists   .agentbox/config"
assert_eq "init never overwrites" "mine" "$(cat "$IW/.agentbox/config")"
if [ ! -e "$IW/.agentbox/codex.config.toml" ]; then pass "the Codex template stays inactive (.example)"; else fail "init activated codex.config.toml"; fi

finish
