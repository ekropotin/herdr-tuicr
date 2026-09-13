#!/usr/bin/env bash
# Pane entrypoint (declared as the [[panes]] "review" command): this process
# *is* the review pane's controlling terminal, opened by review-paste.sh /
# review-submit.sh via `herdr plugin pane open --entrypoint review`, which
# also set HERDR_TUICR_ORIGIN_PANE and HERDR_TUICR_MODE via --env and this
# pane's cwd via --cwd.
#
# No `set -e`: tuicr exiting non-zero (e.g. the human pressed q without
# finishing every file) must not skip reading back whatever comments exist.
set -uo pipefail

ROOT="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/format.sh
source "$ROOT/lib/format.sh"

# Herdr closes this declared pane the moment this process exits — there is no
# lingering shell behind it the way `pane run`'s injected-command panes have.
# So an error exit must hold the pane open long enough to actually be read,
# instead of logging and vanishing in the same instant (confirmed live: a
# plain `log_error; exit 1` here closes the pane within ~1s of opening it).
die() {
  log_error "$*"
  printf '\nPress any key to close this pane.\n'
  read -n 1 -s -r -- _ || true
  exit 1
}

main() {
  command -v "$HERDR_BIN" &>/dev/null || die "$HERDR_BIN not found on PATH"
  command -v "$JQ_BIN" &>/dev/null || die "$JQ_BIN not found on PATH"
  command -v tuicr &>/dev/null || die "tuicr not found on PATH"

  local own_pane="${HERDR_PANE_ID:-}"
  local origin_pane="${HERDR_TUICR_ORIGIN_PANE:-}"
  local mode="${HERDR_TUICR_MODE:-paste}"
  local repo_dir="$PWD"

  if [[ -z "$origin_pane" ]]; then
    die "HERDR_TUICR_ORIGIN_PANE is not set; this pane must be opened by review-paste.sh/review-submit.sh"
  fi

  # Snapshot sessions before running tuicr so the session it just touched can
  # be told apart from any stale session already on file for this repo (see
  # select_touched_session's comment for why `active`/count-based selection
  # doesn't work here).
  local list_before
  list_before=$(run_tuicr_json review list --repo "$repo_dir") || die "Could not read back tuicr sessions"

  log_info "Reviewing $repo_dir"
  tuicr -w
  local tuicr_status=$?
  log_info "tuicr exited with status $tuicr_status"

  local list_after
  list_after=$(run_tuicr_json review list --repo "$repo_dir") || die "Could not read back the tuicr session"

  local session session_status=0
  session=$(select_touched_session "$list_before" "$list_after") || session_status=$?
  if [[ "$session_status" -eq 2 ]]; then
    notify_and_close "$own_pane" "Nothing to review (clean working tree) - not sending anything"
    exit 0
  elif [[ "$session_status" -ne 0 ]]; then
    die "Could not determine which tuicr session to read"
  fi

  local slug reviewed_count file_count
  slug=$(printf '%s\n' "$session" | "$JQ_BIN" -er '.slug')
  reviewed_count=$(printf '%s\n' "$session" | "$JQ_BIN" -er '.reviewed_count')
  file_count=$(printf '%s\n' "$session" | "$JQ_BIN" -er '.file_count')

  local comments_json
  comments_json=$(run_tuicr_json review comments --repo "$repo_dir" --session "$slug") || die "Could not read back review comments"

  local comment_count
  comment_count=$(printf '%s\n' "$comments_json" | "$JQ_BIN" -er 'length')

  if [[ "$comment_count" -eq 0 ]]; then
    if [[ "$reviewed_count" -eq "$file_count" ]]; then
      log_info "Review complete, nothing to flag ($reviewed_count/$file_count files reviewed) - not sending anything"
    else
      log_warn "No comments and review incomplete ($reviewed_count/$file_count files reviewed) - not sending anything"
    fi
    close_own_pane "$own_pane"
    exit 0
  fi

  local header_context text
  header_context=$(git_context "$repo_dir") || header_context=""
  text=$(format_review_comments "$comments_json" "$header_context")

  log_info "Sending $comment_count comment(s) to pane $origin_pane (mode: $mode)"
  dispatch_review "$mode" "$origin_pane" "$text" || die "Failed to deliver comments to pane $origin_pane"

  close_own_pane "$own_pane"
}

main "$@"
