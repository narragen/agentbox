#!/usr/bin/env bash
# Tests for scripts/update-versions.sh, with curl stubbed (no network).
set -euo pipefail
. "$(dirname "$0")/assert.sh"
SCRIPT="$AGENTBOX_ROOT/scripts/update-versions.sh"
command -v jq >/dev/null || { echo "jq is required for this test"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/stub"; mkdir -p "$STUB"
# Fake curl: STUB_MODE=fail -> exit 22 (HTTP error / offline); empty -> '{}';
# otherwise answer every registry with version STUB_VERSION, and the MCR tag list
# with STUB_TAGS.
cat > "$STUB/curl" <<'EOF2'
#!/usr/bin/env bash
url="${!#}"
case "${STUB_MODE:-ok}" in
  fail) exit 22 ;;
  empty) echo '{}'; exit 0 ;;
esac
case "$url" in
  *registry.npmjs.org*) printf '{"version":"%s"}' "$STUB_VERSION" ;;
  *api.github.com*) printf '{"tag_name":"v%s"}' "$STUB_VERSION" ;;
  *pypi.org*) printf '{"info":{"version":"%s"}}' "$STUB_VERSION" ;;
  *mcr.microsoft.com*) printf '{"tags":[%s]}' "${STUB_TAGS:-}" ;;
  *) exit 22 ;;
esac
EOF2
chmod +x "$STUB/curl"

V="$TMP/versions.env"
reset_versions() {
  cat > "$V" <<'EOF2'
# comment
CLAUDE_CODE_VERSION=1.0.0
NODE_VERSION=24
PYTHON_VERSION=3.14
PLAYWRIGHT_VERSION=1.0.0
PLAYWRIGHT_MCP_VERSION=0.0.1
UV_VERSION=0.1.0
PRE_COMMIT_VERSION=1.0.0
EOF2
}
upd() { PATH="$STUB:$PATH" AGENTBOX_VERSIONS_FILE="$V" bash "$SCRIPT" "$@" 2>&1; }

reset_versions
rc=0; out="$(STUB_MODE=fail upd)" || rc=$?
assert_eq "offline: exits non-zero" 1 "$rc"
assert_contains "offline: says the lookup failed" "$out" "LOOKUP FAILED"
assert_absent "offline: never claims everything is current" "$out" "Everything is current"
rc=0; out="$(STUB_MODE=empty upd)" || rc=$?
assert_eq "malformed response: exits non-zero" 1 "$rc"
rc=0; STUB_MODE=fail upd --apply >/dev/null || rc=$?
assert_eq "offline --apply changes nothing" "1.0.0" "$(sed -n 's/^CLAUDE_CODE_VERSION=//p' "$V")"

out="$(STUB_VERSION=1.0.0 upd || true)"
assert_contains "manual pins are labelled" "$out" "manual (bump by hand)"

out="$(STUB_VERSION=2.0.0 STUB_TAGS='"v2.0.0-noble"' upd)"
assert_contains "newer versions are reported" "$out" "update available"
assert_contains "report-only suggests --apply" "$out" "update --apply"
assert_eq "report-only changes nothing" "1.0.0" "$(sed -n 's/^CLAUDE_CODE_VERSION=//p' "$V")"

STUB_VERSION=2.0.0 STUB_TAGS='"v2.0.0-noble"' upd --apply >/dev/null
assert_eq "--apply bumps npm pins" "2.0.0" "$(sed -n 's/^CLAUDE_CODE_VERSION=//p' "$V")"
assert_eq "--apply bumps GitHub pins (v stripped)" "2.0.0" "$(sed -n 's/^UV_VERSION=//p' "$V")"
assert_eq "--apply bumps PyPI pins" "2.0.0" "$(sed -n 's/^PRE_COMMIT_VERSION=//p' "$V")"
assert_eq "--apply bumps PLAYWRIGHT_VERSION" "2.0.0" "$(sed -n 's/^PLAYWRIGHT_VERSION=//p' "$V")"
assert_eq "PLAYWRIGHT_VERSION= doesn't clobber PLAYWRIGHT_MCP_VERSION's line" 2 "$(grep -c '^PLAYWRIGHT' "$V")"
assert_eq "--apply leaves NODE_VERSION alone" "24" "$(sed -n 's/^NODE_VERSION=//p' "$V")"
assert_eq "--apply leaves comments alone" "# comment" "$(head -1 "$V")"

reset_versions
out="$(STUB_VERSION=2.0.0 STUB_TAGS='"v1.0.0-noble"' upd --apply)"
assert_contains "Playwright waits for its image" "$out" "waiting (no v2.0.0-noble image yet)"
assert_eq "waiting Playwright pin is not applied" "1.0.0" "$(sed -n 's/^PLAYWRIGHT_VERSION=//p' "$V")"
assert_eq "other pins still applied" "2.0.0" "$(sed -n 's/^CLAUDE_CODE_VERSION=//p' "$V")"

printf 'MYSTERY_VERSION=1\n' >> "$V"
rc=0; out="$(STUB_VERSION=1.0.0 upd)" || rc=$?
assert_eq "unknown key: exits non-zero" 1 "$rc"
assert_contains "unknown key is named" "$out" "unknown key 'MYSTERY_VERSION'"

rc=0; upd --bogus >/dev/null || rc=$?
assert_eq "bad argument exits 2" 2 "$rc"

# The real versions.env must only hold keys the script knows.
rc=0; out="$(STUB_VERSION=0 STUB_TAGS='"v0-noble"' PATH="$STUB:$PATH" bash "$SCRIPT" 2>&1)" || rc=$?
assert_absent "every real pin has a source" "$out" "unknown key"

finish
