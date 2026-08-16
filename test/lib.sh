#!/usr/bin/env bash
# A test harness sized for this repo: three assertions and a counter. Anything
# larger would be more code than the thing it tests.

TESTS_RUN=0
TESTS_FAILED=0

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# assert_eq <expected> <actual> <description>
assert_eq() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    fail "$3"
    printf '       expected: %q\n       actual:   %q\n' "$1" "$2"
  fi
}

# assert_fails <description> <command...> — the command must exit non-zero
# *without* taking the test run down with it.
assert_fails() {
  local desc="$1"; shift
  TESTS_RUN=$((TESTS_RUN + 1))
  if "$@" >/dev/null 2>&1; then
    fail "$desc (expected non-zero exit)"
  else
    pass "$desc"
  fi
}

summary() {
  printf '\n%d assertions, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
