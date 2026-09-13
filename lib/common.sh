#!/usr/bin/env bash
# Sourced by bin/*.sh. Not an entry point on its own.

PLUGIN_ID="ekropotin.herdr-tuicr"
HERDR_BIN="${HERDR_BIN:-herdr}"
JQ_BIN="${JQ_BIN:-jq}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
  printf "%b[herdr-tuicr]%b %s\n" "$GREEN" "$NC" "$*"
}

log_warn() {
  printf "%b[herdr-tuicr]%b %s\n" "$YELLOW" "$NC" "$*"
}

log_error() {
  printf "%b[herdr-tuicr]%b %s\n" "$RED" "$NC" "$*" >&2
}

require_command() {
  local command_name="$1"
  local display_name="$2"

  if ! command -v "$command_name" &>/dev/null; then
    log_error "$display_name not found on PATH"
    exit 1
  fi
}

# Reads a `key = "value"` or `key = value` line from this plugin's own
# config.toml (see config.toml.example), or prints $2 (default) if the file
# or key is absent. Deliberately not a real TOML parser: the config surface
# is a handful of flat scalar keys, so grep/sed covers it without a
# dependency beyond what tuicr's own wrapper scripts already require.
plugin_config_value() {
  local key="$1"
  local default_value="$2"
  local config_file
  config_file="$("$HERDR_BIN" plugin config-dir "$PLUGIN_ID" 2>/dev/null)/config.toml"

  if [[ -n "$config_file" && -f "$config_file" ]]; then
    local line value
    line=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$config_file" | tail -n1)
    if [[ -n "$line" ]]; then
      value="${line#*=}"
      value="$(echo "$value" | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*(#.*)?$//')"
      if [[ -n "$value" ]]; then
        printf '%s' "$value"
        return 0
      fi
    fi
  fi

  printf '%s' "$default_value"
}

# Resolves the repository directory to review from an origin pane id: the
# foreground process's cwd, same field herdr-nvim and tuicr's own wrappers
# rely on.
resolve_repo_dir() {
  local pane_id="$1"
  local pane_json
  pane_json=$("$HERDR_BIN" pane get "$pane_id") || return 1
  printf '%s\n' "$pane_json" | "$JQ_BIN" -er '.result.pane.foreground_cwd'
}

# Opens the declared `review` pane split off $origin_pane, honoring the
# configured pane_direction (right/down open directly; left opens right then
# swaps, since `herdr pane split`/`plugin pane open` only support right/down).
open_review_pane() {
  local mode="$1"
  local origin_pane="$2"
  local repo_dir="$3"

  local configured_direction open_direction swap_left
  configured_direction=$(plugin_config_value "pane_direction" "right")
  open_direction="$configured_direction"
  swap_left=false

  case "$configured_direction" in
    left)
      open_direction="right"
      swap_left=true
      ;;
    right|down) ;;
    *)
      log_warn "Unknown pane_direction '$configured_direction'; using 'right'"
      open_direction="right"
      ;;
  esac

  local open_json new_pane_id
  open_json=$("$HERDR_BIN" plugin pane open \
    --plugin "$PLUGIN_ID" \
    --entrypoint review \
    --placement split \
    --direction "$open_direction" \
    --target-pane "$origin_pane" \
    --cwd "$repo_dir" \
    --focus \
    --env "HERDR_TUICR_ORIGIN_PANE=$origin_pane" \
    --env "HERDR_TUICR_MODE=$mode") || return 1

  new_pane_id=$(printf '%s\n' "$open_json" | "$JQ_BIN" -er '.result.plugin_pane.pane.pane_id') || return 1

  if [[ "$swap_left" == true ]]; then
    "$HERDR_BIN" pane swap --direction left --pane "$new_pane_id" >/dev/null
  fi
}

# Prints "repo: <name>, branch: <branch>" for a git checkout, or nothing (and
# fails) for a jj-only workspace or non-repo directory — same best-effort,
# silent-on-failure header context herdr-nvim's init.lua builds.
git_context() {
  local dir="$1"
  local root branch
  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
  printf 'repo: %s, branch: %s' "$(basename "$root")" "$branch"
}

# Picks the one tuicr session to read back from `tuicr review list` JSON.
# Prints the chosen session object on success. Mirrors the SKILL.md
# convention: a lone session needs no `active` check; with several, exactly
# one `"active": true` breaks the tie; anything else is genuinely ambiguous
# and is left for the human to resolve (a stale review pane, not a crash).
select_active_session() {
  local list_json="$1"
  local count active_count

  count=$(printf '%s\n' "$list_json" | "$JQ_BIN" -er 'length') || return 1

  if [[ "$count" -eq 0 ]]; then
    log_error "No tuicr sessions found for this repository"
    return 1
  fi

  if [[ "$count" -eq 1 ]]; then
    printf '%s\n' "$list_json" | "$JQ_BIN" -er '.[0]'
    return 0
  fi

  active_count=$(printf '%s\n' "$list_json" | "$JQ_BIN" -er '[.[] | select(.active == true)] | length')

  if [[ "$active_count" -eq 1 ]]; then
    printf '%s\n' "$list_json" | "$JQ_BIN" -er '[.[] | select(.active == true)][0]'
    return 0
  fi

  log_error "Ambiguous tuicr sessions for this repository ($count found, $active_count marked active)"
  return 1
}

# Sends the formatted review text to the origin pane: `submit` auto-presses
# Enter via `herdr agent prompt`, anything else (paste) leaves it in the
# input via `herdr pane send-text` — same two verbs herdr-nvim's dispatch.lua
# uses for the identical send/submit split.
dispatch_review() {
  local mode="$1"
  local pane="$2"
  local text="$3"

  case "$mode" in
    submit)
      "$HERDR_BIN" agent prompt "$pane" "$text" >/dev/null
      ;;
    *)
      "$HERDR_BIN" pane send-text "$pane" "$text" >/dev/null
      ;;
  esac
}

# Runs `tuicr "$@"`, expecting JSON on stdout. Stderr is captured separately
# and only surfaced (via log_error) on failure, so a stray warning tuicr
# writes to stderr on a *successful* run can never end up concatenated onto
# the JSON this prints to stdout.
run_tuicr_json() {
  local err_file out status
  err_file=$(mktemp)
  out=$(tuicr "$@" 2>"$err_file")
  status=$?
  if [[ "$status" -ne 0 ]]; then
    log_error "tuicr $* failed: $(cat "$err_file")"
    rm -f "$err_file"
    return "$status"
  fi
  rm -f "$err_file"
  printf '%s' "$out"
}

close_own_pane() {
  local pane="$1"
  [[ -n "$pane" ]] || return 0
  "$HERDR_BIN" plugin pane close "$pane" >/dev/null 2>&1 || true
}
