#!/usr/bin/env bash
# Plain-bash test runner (no bats dependency): sources lib/*.sh directly and
# exercises the pure functions (formatting, session selection) against fixed
# JSON fixtures. Anything that shells out to `herdr` or `tuicr` is out of
# scope here — that's covered by the manual verification steps in README.md.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JQ_BIN="${JQ_BIN:-jq}"
HERDR_BIN="herdr-should-not-be-invoked"

# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/format.sh
source "$ROOT/lib/format.sh"

failures=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$desc" "$expected" "$actual"
    failures=$((failures + 1))
  else
    printf 'ok - %s\n' "$desc"
  fi
}

assert_status() {
  local desc="$1" expected_status="$2"
  shift 2
  local actual_status=0
  "$@" >/dev/null 2>&1 || actual_status=$?
  assert_eq "$desc" "$expected_status" "$actual_status"
}

# --- format_review_comments -------------------------------------------------

comments_json=$(cat "$ROOT/tests/fixtures/comments_mixed.json")

expected_format=$(cat "$ROOT/tests/fixtures/expected_format_mixed.txt")
actual_format=$(format_review_comments "$comments_json" "repo: demo, branch: main")
assert_eq "formats mixed line/line_range/file/review comments" "$expected_format" "$actual_format"

no_context_format=$(format_review_comments "$comments_json" "")
case "$no_context_format" in
  "Code review comments from tuicr:"*) printf 'ok - %s\n' "omits header context when empty" ;;
  *)
    printf 'FAIL: %s\n  got: %q\n' "omits header context when empty" "$no_context_format"
    failures=$((failures + 1))
    ;;
esac

# --- select_active_session ---------------------------------------------------

single_session_json=$(cat "$ROOT/tests/fixtures/sessions_single.json")
result=$(select_active_session "$single_session_json")
assert_eq "single session needs no active flag" "worktree/abc123" "$(printf '%s' "$result" | "$JQ_BIN" -r '.slug')"

one_active_json=$(cat "$ROOT/tests/fixtures/sessions_one_active.json")
result=$(select_active_session "$one_active_json")
assert_eq "picks the lone active session among several" "commits/base..head" "$(printf '%s' "$result" | "$JQ_BIN" -r '.slug')"

ambiguous_json=$(cat "$ROOT/tests/fixtures/sessions_ambiguous.json")
assert_status "fails on multiple sessions with no single active one" 1 \
  select_active_session "$ambiguous_json"

empty_json='[]'
assert_status "fails on zero sessions" 1 select_active_session "$empty_json"

# --- summary ------------------------------------------------------------------

if [[ "$failures" -gt 0 ]]; then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi

printf '\nall assertions passed\n'
