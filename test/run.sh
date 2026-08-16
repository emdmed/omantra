#!/usr/bin/env bash
# Run every test_*.sh and report once. Each file is its own process, so one
# blowing up on `set -e` cannot take the rest of the suite with it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failed=0

for t in "$ROOT"/test/test_*.sh; do
  printf '\n\033[1m%s\033[0m\n' "$(basename "$t")"
  bash "$t" || failed=$((failed + 1))
done

printf '\n'
if [ "$failed" -gt 0 ]; then
  printf '\033[31m%d test file(s) failed\033[0m\n' "$failed"
  exit 1
fi
printf '\033[32mall tests passed\033[0m\n'
