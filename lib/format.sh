#!/usr/bin/env bash
# Sourced by bin/review-pane.sh. Not an entry point on its own.

# Formats `tuicr review comments` JSON into an agent-facing prompt, in the
# shape of herdr-nvim's prompt.lua (numbered items, then a closing
# instruction), adapted to tuicr's comment fields instead of editor marks and
# code snippets.
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
    (
      if $c.location == "line" or $c.location == "line_range" then
        if ($c.end_line // $c.start_line) != $c.start_line then
          "\($c.path):\($c.start_line)-\($c.end_line)"
        else
          "\($c.path):\($c.start_line)"
        end
      elif $c.location == "file" then
        $c.path
      else
        "(review)"
      end
    ) as $ref |
    "\($n). \($ref)\n   [\($c.comment_type)] \($c.content)\n"
  '

  printf 'Please address each comment. Reply with what you changed per item.\n'
}
