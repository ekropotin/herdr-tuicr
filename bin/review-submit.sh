#!/usr/bin/env bash
# Action entrypoint (contexts = ["pane"]): hotkey for "review, then
# auto-submit the comments to the origin agent".
set -euo pipefail

ROOT="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

main() {
  require_command "$HERDR_BIN" "Herdr"
  require_command "$JQ_BIN" "jq"

  if [[ "${HERDR_ENV:-}" != "1" ]]; then
    log_error "Not running inside a Herdr-managed pane"
    exit 1
  fi

  local origin_pane="${HERDR_PANE_ID:-}"
  if [[ -z "$origin_pane" ]]; then
    log_error 'HERDR_PANE_ID is not set; this action must be bound with contexts=["pane"]'
    exit 1
  fi

  local repo_dir
  repo_dir=$(resolve_repo_dir "$origin_pane") || {
    log_error "Could not resolve the working directory of pane $origin_pane"
    exit 1
  }

  log_info "Opening tuicr review pane (submit mode) for $repo_dir"
  open_review_pane "submit" "$origin_pane" "$repo_dir"
}

main "$@"
