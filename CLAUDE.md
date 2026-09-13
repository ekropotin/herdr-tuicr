# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A [Herdr](https://herdr.dev) plugin, pure Bash (no compiled binary — `jq` + the `herdr`/`tuicr` CLIs cover everything). It wires `tuicr` (an interactive terminal code-review TUI) into Herdr's pane system: a hotkey opens `tuicr` in a split pane scoped to the pressing pane's cwd, and when the human finishes the review, the comments are automatically formatted and delivered back into the input of whichever pane triggered it — either pasted (`review-paste`) or auto-submitted (`review-submit`).

See README.md for user-facing install/usage/config docs. This file covers development.

## Commands

```sh
tests/run.sh                                  # unit tests (bash + jq only, no herdr/tuicr needed)
shellcheck bin/*.sh lib/*.sh tests/run.sh      # lint (what CI runs)
```

There is no single-test runner — `tests/run.sh` is a flat sequence of assertions against `tests/fixtures/*.json`; comment out or temporarily isolate a block to run just one during development.

For live/manual testing against a real Herdr session:

```sh
herdr plugin link /path/to/herdr-tuicr        # register the plugin from a local checkout
herdr server reload-config                     # after editing ~/.config/herdr/config.toml keybindings
herdr plugin action invoke review-paste --plugin ekropotin.herdr-tuicr   # trigger without a keybinding
herdr plugin log list --plugin ekropotin.herdr-tuicr                     # inspect the last action run's stdout/exit code
```

`plugin action invoke` (and a real keypress) resolves to whatever pane currently has UI focus — there's no way to target a specific pane from the CLI, so tests that need a specific origin pane instead run `bin/review-paste.sh`/`review-submit.sh` directly with `HERDR_ENV=1 HERDR_PANE_ID=<pane>` set by hand.

## Architecture

```
herdr-plugin.toml         manifest: 2 actions (review-paste, review-submit), 1 declared pane (review)
bin/review-paste.sh        action entrypoint, contexts=["pane"] -> mode=paste
bin/review-submit.sh       action entrypoint, contexts=["pane"] -> mode=submit
bin/review-pane.sh          the declared "review" pane's own process
lib/common.sh               shared helpers (see below)
lib/format.sh                format_review_comments: pure, jq-based, unit-tested standalone
```

Flow per hotkey press:

1. Herdr runs `review-paste.sh`/`review-submit.sh` with `HERDR_PANE_ID` set to the exact pane that had focus (the *origin* pane — where the agent this review is for is running).
2. That script resolves the origin pane's cwd (`herdr pane get` -> `.result.pane.foreground_cwd`) and opens the declared `review` pane via `herdr plugin pane open --entrypoint review`, passing the origin pane id and paste/submit mode through `--env` (`open_review_pane` in lib/common.sh).
3. `review-pane.sh` runs *as* that new pane's controlling process: snapshots `tuicr review list` and every existing session's comments (`snapshot_comments_by_path`), runs `tuicr -w` interactively (the human reviews here), snapshots the list again, figures out which session it just touched (`select_touched_session`), reads back its current comments and diffs them against the pre-run snapshot (`diff_new_comments`) to find what's actually new, formats that (`format_review_comments`), and dispatches to the origin pane — `herdr pane send-text` (paste) or `herdr agent prompt` (submit) — then closes itself.

Everything communicates through `--env` variables on the declared pane (`HERDR_TUICR_ORIGIN_PANE`, `HERDR_TUICR_MODE`) and `HERDR_PANE_ID` (Herdr's own, set to whichever pane a process is actually running in).

## Non-obvious constraints (found by live-testing against a real Herdr session, not documented anywhere else)

- **`herdr plugin pane open`'s response shape differs from `pane split`/`pane get`.** The new pane is nested at `.result.plugin_pane.pane`, not `.result.pane`. Getting this wrong fails silently (jq `-e` exits non-zero, the calling script just returns 1).
- **A declared `[[panes]]` process is killed the instant it exits.** Unlike `herdr pane run`'s injected-command panes (which leave the shell sitting at its prompt), there's no lingering shell here — a bare `log_error; exit 1` closes the pane before a human can read it. Any message that must be seen has to pause on a keypress first; see `die()` (bin/review-pane.sh) and `notify_and_close()` (lib/common.sh).
- **tuicr's `location` field is a ready-to-display string, not an enum.** `tuicr review comments` returns things like `"src/main.rs:42"`, `"src/main.rs:10-15"`, `"src/main.rs:49 [old]"`, `"README.md"` (file-level), or the literal string `"review"` (review-level) — use it directly rather than reconstructing it from `path`/`start_line`/`end_line`/`side`.
- **tuicr sessions never expire, and `active` is useless for this plugin's purpose.** `tuicr review list` keeps reporting a session even after its underlying JSON file is deleted by hand, and by the time this plugin reads a session back, `tuicr -w` has already exited — so `active` is always `false` regardless of whether the review just happened or happened days ago. Picking "the only session on file" is wrong the moment a stale session exists for the same repo (confirmed live: it silently delivered comments from an unrelated past review). The fix, `select_touched_session`, diffs `tuicr review list` output captured before and after running `tuicr -w` by `(path, updated_at)` and only ever reads back the session that actually changed.
- **A session-level "touch" isn't the same as "new content", and `tuicr review comments` never gives you the past.** tuicr bumps a session's `updated_at` on any explicit save (`:wq`), even one that adds nothing new — so `select_touched_session` alone can't tell "genuinely new comments" apart from "reopened an unchanged review and quit". And `tuicr review comments --session <slug>` always reads current on-disk state; calling it again after tuicr has exited to get the "before" comments just re-reads the *after* state, comparing it against itself (confirmed live: this silently dropped every real new comment). The fix is `snapshot_comments_by_path`, called *before* `tuicr -w` runs at all, plus `diff_new_comments` comparing `(id, content)` afterward — capture-before-run is the only correct order.
- **Comment types are tuicr's own config, not this plugin's.** `[[comment_types]]` in the user's `~/.config/tuicr/config.toml` controls what's selectable in the TUI; this plugin's formatter just passes through whatever `comment_type` tuicr reports, omitting the `[type]` tag entirely when it's the default `"none"`.
- **Avoid `prefix+r`/`prefix+shift+r`** when suggesting example keybindings — they collide with Herdr's built-in `resize_mode`/`reload_config` (check `herdr --default-config` plus the user's own `[[keys.command]]` entries before picking new ones).

## Testing conventions

`tests/run.sh` sources `lib/common.sh` and `lib/format.sh` directly and asserts against fixtures in `tests/fixtures/`. `HERDR_BIN` is deliberately set to a nonexistent command in the test runner so any code path that accidentally shells out to `herdr` fails loudly instead of hanging. When changing `select_touched_session` or `format_review_comments`, update the fixtures rather than hand-writing expected output — regenerate with the function itself (source the libs, call the function, redirect to the fixture file) so the expected output can't drift from what the code actually produces.
