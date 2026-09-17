#!/usr/bin/env bash
# Run the host-side test suites (no Docker needed; `docker` is stubbed where used).
# Runs each suite with the same bash that runs this script, so `/bin/bash
# tests/run-all.sh` checks macOS's bash 3.2. The image is covered by integration.sh.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
rc=0
for t in test-*.sh; do
  echo "== $t"
  "$BASH" "$t" || rc=1
  echo
done
if [ "$rc" -eq 0 ]; then echo "ALL SUITES PASSED"; else echo "SOME SUITES FAILED"; fi
exit "$rc"
