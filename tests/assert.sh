# Minimal assertions for agentbox's shell tests. Source it; call `finish` at the end.
# Written for bash 3.2 (macOS /bin/bash) as well as bash 5.
# shellcheck disable=SC2034  # AGENTBOX_ROOT is read by the test files

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; [ -z "${2:-}" ] || echo "         $2"; fails=$((fails + 1)); }

assert_contains() {  # DESC HAYSTACK NEEDLE
  if printf '%s' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "expected to find: $3"; fi
}
assert_absent() {  # DESC HAYSTACK NEEDLE
  if printf '%s' "$2" | grep -qF -- "$3"; then fail "$1" "expected NOT to find: $3"; else pass "$1"; fi
}
# assert_line / assert_no_line: an exact whole line. Use these for docker argv, which
# dry runs print one element per line, so a substring can't match the wrong element.
assert_line() {  # DESC HAYSTACK LINE
  if printf '%s\n' "$2" | grep -qFx -- "$3"; then pass "$1"; else fail "$1" "expected the exact line: $3"; fi
}
assert_no_line() {  # DESC HAYSTACK LINE
  if printf '%s\n' "$2" | grep -qFx -- "$3"; then fail "$1" "expected NO line: $3"; else pass "$1"; fi
}
assert_eq() {  # DESC EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}

# pty CMD... -> run CMD with a pseudo-terminal on stdin/stdout (for code that insists
# on an interactive terminal). Feeds this function's stdin to CMD.
pty() {
  if [ "$(uname -s)" = Darwin ]; then
    script -q /dev/null "$@"
  else
    local cmd="" a
    for a in "$@"; do cmd="$cmd $(printf '%q' "$a")"; done
    script -qec "$cmd" /dev/null
  fi
}

# feed ANSWER -> write ANSWER to stdout once a pty program is waiting for it. macOS
# `script` forwards end-of-input ahead of piped bytes, so hold the pipe open.
feed() { sleep 0.3; printf '%s\n' "$1"; sleep 1; }

finish() {
  echo
  if [ "$fails" -eq 0 ]; then echo "All passed."; else echo "$fails failure(s)."; exit 1; fi
}

AGENTBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
