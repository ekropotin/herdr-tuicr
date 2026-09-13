#!/usr/bin/env bash
# Sourced by bin/review-pane.sh. Not an entry point on its own.

# Formats `tuicr review comments` JSON into an agent-facing prompt, in the
# shape of herdr-nvim's prompt.lua (numbered items, then a closing
# instruction), adapted to tuicr's comment fields instead of editor marks and
# code snippets.
#
# `location` is tuicr's own ready-to-display string (e.g. "src/main.rs:42",
# "src/main.rs:10-15", "src/main.rs:49 [old]", "README.md" for a file
# comment, or the literal "review" for a review-level comment) — verified
# live against `tuicr review comments` output for all four target types, so
# this reuses it directly rather than reconstructing it from path/
# start_line/end_line/side. `comment_type` comes back as "none" for a plain
# inline TUI comment (as opposed to one added with an explicit --type via
# `tuicr review add`), so that tag is omitted rather than printed literally.
format_review_comments() {
  local comments_json="$1"
  local header_context="${2:-}"

  local header="Code review comments from tuicr"
  [[ -n "$header_context" ]] && header="$header ($header_context)"
  printf '%s:\n\n' "$header"

  printf '%s\n' "$comments_json" | "$JQ_BIN" -r '
    to_entries[] |
    (.key + 1) as $n |
    .value as $c |
    (if ($c.comment_type // "none") == "none" then "" else "[\($c.comment_type)] " end) as $tag |
    "\($n). \($c.location)\n   \($tag)\($c.content)\n"
  '

  printf 'Please address each comment. Reply with what you changed per item.\n'
}
