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

main() {
  require_command "$HERDR_BIN" "Herdr"
  require_command "$JQ_BIN" "jq"
  require_command tuicr "tuicr"

  local own_pane="${HERDR_PANE_ID:-}"
  local origin_pane="${HERDR_TUICR_ORIGIN_PANE:-}"
  local mode="${HERDR_TUICR_MODE:-paste}"
  local repo_dir="$PWD"

  if [[ -z "$origin_pane" ]]; then
    log_error "HERDR_TUICR_ORIGIN_PANE is not set; this pane must be opened by review-paste.sh/review-submit.sh"
    exit 1
  fi

  log_info "Reviewing $repo_dir"
  tuicr -w
  local tuicr_status=$?
  log_info "tuicr exited with status $tuicr_status"

  local list_json
  list_json=$(run_tuicr_json review list --repo "$repo_dir") || exit 1

  local session
  if ! session=$(select_active_session "$list_json"); then
    # select_active_session already logged the reason; leave the pane open
    # (no close_own_pane call) so the human can read it before closing by hand.
    exit 1
  fi

  local slug reviewed_count file_count
  slug=$(printf '%s\n' "$session" | "$JQ_BIN" -er '.slug')
  reviewed_count=$(printf '%s\n' "$session" | "$JQ_BIN" -er '.reviewed_count')
  file_count=$(printf '%s\n' "$session" | "$JQ_BIN" -er '.file_count')

  local comments_json
  comments_json=$(run_tuicr_json review comments --repo "$repo_dir" --session "$slug") || exit 1

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
  if ! dispatch_review "$mode" "$origin_pane" "$text"; then
    log_error "Failed to deliver comments to pane $origin_pane"
    exit 1
  fi

  close_own_pane "$own_pane"
}

main "$@"
