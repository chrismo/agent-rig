# Rex

Notes from trying [Rex](https://www.superlogical.com/rex/docs) (Superlogical's
terminal multiplexer, macOS app + server) as a replacement for Moestty, the
personal Ghostty fork in `~/modev/ghostty`. Started 2026-10-30 on Rex Beta 0.1.0.

## Setup

- Config: `terminal/rex/init.lua`, which `require`s `panes.lua` and `sessions.lua`. Each file is
  linked into `~/.config/rex/` by `install.sh`. Apply with `rex config check && rex config reload`.
  `rex config check` doesn't compare a binding's args with what its action declares. The client
  does that when it loads the keymap and reports mismatches as problems, so run
  `bats terminal/rex-keybindings.bats` first. It does the same check.
- Shortcuts set in the app's settings override `init.lua`. They're stored in
  `~/Library/Application Support/com.superlogical.rex/Shortcuts/shortcuts.json`
  (per a #feedback thread, not checked here).
- The app takes actions from the CLI (`rex -C <client> do ...`) only with
  **Settings → Rex Server → Remote Control** on.
- Docs as markdown: append `.md` to any page; index at
  `https://www.superlogical.com/rex/docs/llms.txt`.

## Claude hooks: Activity needs OSC 7501

Out of the box, Claude sessions never appear in Rex's Activity filter (checked
2026-11-05): Rex's only Claude hook is `session-start`, and Activity is fed by
programs sending OSC 7501 status reports (pi does; Claude doesn't). Turning on
`rex skill setup --session-naming` changed nothing.

`bin/rex-status` sends the report from the UserPromptSubmit, PostToolUse,
PermissionRequest and Stop hooks (`install.sh`). Confirmed: the session shows in
Activity with a working animation, and a permission prompt shows as Blocked
with "Claude needs permission".

`tab-status` still sets titles only under Ghostty (389c1d0).

## Moestty features in Rex

| Moestty / Ghostty | Rex |
|---|---|
| `move_split` | custom `pane_move_dir` (swap) and `pane_aim` (live-move mode) actions in `panes.lua`, see below |
| `move_split_to_new_tab` | `pane.move_to_new_tab` |
| `move_tab_to_split` | `pane.move_to_tab…` (picker, starts from the pane) |
| `mark_tab` + `move_marked_tabs_to_new_window` | `client.tab.move_to_new_window`, one tab at a time — **no marks** |
| `toggle_tab_switcher` | command palette searches tabs across sessions; see below |

Rex extras: floating panes (`pane.float`), detached blocks that keep running,
server-side sessions, key modes and sequences, `rex move` / `rex swap` from the
CLI. Not yet checked: what Rex's default `cmd+alt+shift+w` does (Ghostty's
closed every window, so the Ghostty config unbinds it).

### `move_split`: replaced, not rebuilt

Moestty's `move_split` doesn't move on the keypress. It shows a highlighted
target square in the destination pane, and further presses walk it around that
pane's four edges (top/bottom/left/right). Releasing the modifiers drops the
split there, so one gesture can also change split orientation. Rex's built-in
`pane.move` just swaps with the neighbor.

Instead, `terminal/rex/panes.lua` adds a swap/move-into on ⇧⌥⌘+arrow and,
since 2026-11-05, an aim mode on ⇧⌥+arrow (below). Before that, ⇧⌥+arrow was a
push into the neighbor's row or column (2026-11-01; see
[Shortcut layout](#shortcut-layout) for its detour on 2026-11-04). ⌘⌃ was ruled
out for push because the MBP keyboard can't register caps+A+F+J, and the swap
chord already uses every finger (see brain's
`keyboarding/physical-keyboard-limitations.md`). Push covers flipping a split
between side by side and stacked, so a separate rotate was dropped (2026-11-01).

Rex has no native rotate. `pane_rotate_split` was ours, written after adi's
`rotate_split` in the "Rotate / transpose a split" #feedback thread, and it was
dropped for push, not for anything built in. It showed in the command palette
because every `rex.action` does — which is how it got mistaken for native. Bind
`rex.bind(key, fn)` when an action should stay off the palette.

Aim mode (2026-11-05) is the closest to Moestty's gesture. ⇧⌥+arrow enters an
exclusive key mode (`rex.mode`) and moves the pane, live, to the nearest edge
spot of another pane that way. Arrows keep walking it, Enter keeps it, and Esc
undoes each step, last first. The move is the preview, because nothing else
showed:

- `session.set_block_label` sets the block's label, but the pane header shows
  the terminal's title, and no API sets that.
- The terminal's `set_theme` (background tint) changed nothing, whether called
  from the CLI or from a palette action.
- A floating layer placed with `session.new_layer` / `resize_layer` should work
  as an overlay, but chrismo turned it down.

Lessons from the walk:

- Landing spots computed once, at the start, made later presses unpredictable
  once the layout had moved, so each press now starts from where the pane is.
- Swap spots threw the other pane back to where the moved one started, so the
  walk never swaps; ⇧⌥⌘ still does.
- An edge that faces the moving pane across a matching span would only shuffle
  sizes, so it's skipped.
- Esc can only get close when the pane started beside a group of panes
  (`move_block` limit below), and split ratios may shift.
- Config Lua state survives between action calls (checked 2026-11-05), so the
  mode keeps its history in a local.

Rex pins a key-hint panel up for as long as any mode is active. "Show key
sequence hints" doesn't hide it; the accepted request to hide or minimize that
panel is tracked in [Feedback threads](#feedback-threads), and hadn't shipped as
of 2026-11-05; chrismo chose to wait for it. Fallback if it never ships: drop the
mode. ⇧⌥+arrows always move live, with no Enter, and an undo chord
(⇧⌥+Backspace, say) takes back the current run of moves. A run ends when a
different pane moves or anything else changes the layout, which `session.view`'s
`revision` shows. That depends on the layout, not on a timer. Untried: whether a
focus change alone bumps `revision` (it would end the run, which is fine). Before aim mode, a version without a mode walked the pane with an
invisible "still the same move" timer, so the same key did different things
depending on timing. It wasn't predictable.

Unavoidable surprise left, from Rex's binary split tree:

- A move out of a split always hands that space to the pane's partner in the
  tree, which isn't visible. Two layouts that look the same can stretch
  differently.
- A move leaves a hole that the tree partner fills. In a column-first 2×2, TR ↓
  makes three full-height columns, not one-plus-three.
- `move_block` can't take a group of panes as its target.
  So "full-height pane ← past a stacked column" lands beside one pane of that
  column. Untried fix: `session.new_split` *can* anchor on a split, so create a
  placeholder beside the group, `swap_blocks` into it, and close the placeholder.

Related pane-movement requests are tracked in [Feedback threads](#feedback-threads).

## Shortcut layout

Reorganized 2026-11-04 so switching tabs is a home-row chord: ⌃Tab and ⇧⌘[ ]
aren't on the caps-lock Karabiner layer, but arrows, PgUp/PgDn and all four
modifiers are. Modifiers are written in that layer's order, ⌃⇧⌥⌘. The m and v
are Dvorak letters, sitting below ← and → the way PgUp/PgDn sit above.

| Chord | arrows: panes | PgUp/PgDn: tabs | m/v: sessions |
|---|---|---|---|
| ⌥⌘ | focus | previous/next tab | previous/next session |
| ⇧⌥⌘ | swap (`pane_move_dir`) | move tab | move session (`session_move`) |
| ⇧⌥ | aim mode (`pane_aim`) | free | collapse then previous / next |
| ⇧⌘ | resize | free | — |

The key cluster names the thing, the chord names the verb: ⌥⌘ goes to it, ⇧⌥⌘
moves it. Pane arrows are where Ghostty had them; an interim layout put tabs on
⌥⌘+arrows and pane focus on ⇧⌥, and muscle memory fought it all day.

Ruled out along the way:

- ⌃ chords. With any other modifier, ⌃ jams the MBP keyboard on the caps layer:
  ⌃⌘ (push note above), and ⌃⇧, ⌃⌥ and ⌃⇧⌥ (all tried, 2026-11-04). ⌃+arrow
  alone hits macOS defaults.
- Key modes for everyday chords: not wanted, partly because Rex pins the key-hint
  panel while one is active. Aim mode is the one exception.
- ⇧+arrow alone would take selection away from nvim and other TUIs.
- `pane_rotate` (ff054c4), a quarter turn around the pane's tree partner. Not the
  move wanted. Lessons: `move_block` can't anchor on a group, and a turn back
  doesn't always undo a turn, because a pane's tree partner can change.
- An accordion on session switching (go to a session, collapse the rest). It
  worked, but keeping exactly one session open was too big a change; chrismo
  wants to choose what stays expanded. The deferred #feedback request
  "Auto-collapse inactive sessions in the sidebar" asks for that built in.

Next/previous tab crosses into the neighboring session and wraps at the ends
(observed by chrismo, 2026-11-04). Collapsing a session only changes the sidebar,
but it keeps the ⌘1–9 numbers easier to track. Collapse and session switching need
separate keys: with every session collapsed, tab switching can't leave the current
session, but next/previous session still can, and expands the session it lands on
(observed by chrismo). That same auto-expand left a plain expand key with nothing
to do, so ⇧⌥v became collapse-then-next (2026-11-05). No API reports which sessions
are collapsed, so "go to the previous/next *expanded* session" is a TODO in
`sessions.lua`. The active bug "Show
Activity forgets session collapse state when toggled" means ⌘. can lose collapses.

Moving a session uses the server's `session.move` through `rex.call`;
`rex.session.move` and `rex.session.list` aren't callable from Lua (tried
2026-11-04). The `session.list` order matches the sidebar.

Open: whether next/previous tab and ⌘1–9 follow the ⌘. Activity filter. Neither
the docs nor #feedback say. Rex's default ⌥⌘W (Close Tab) sits beside the ⌥⌘
chords; Ghostty's config unbinds the equivalent, Rex's doesn't.

## Sessions, tabs and panes

- To create a named session without first getting a random name: ⌘K, type the
  name, then Enter. ⇧⌘N creates a new session instead; don't use it to submit
  the name in the picker.
- The command palette (⇧⌘P) can search tab names across sessions. For panes,
  use ⌥⌘+arrow to focus directionally or ⌘[ / ⌘] to cycle; no searchable pane
  picker found. ⌘1–9 selects tabs; ⌥⌘PgUp/PgDn (and the default ⌃Tab) cycles them.
- Settings → Integrations → Agent Behavior → "Let agents name sessions" lets
  agents label sessions for their work. Useful for a single agent task, but
  multiple agents can rename the same session, and people report the setting
  not applying to alternate Claude config directories.
- A running tab or pane can't currently be moved to another session via the
  documented CLI/API, so the agent skill can't do it either. `rex window move`
  reorders within a session; `rex move` requires both panes in the same session.
  "Move Tab to New Window" opens another app window, not a new session. Starting
  again in the destination loses terminal state and scrollback. See the tracked
  cross-session movement request below.

## Sidebar vanished: a two-finger swipe

A two-finger horizontal trackpad swipe hides and shows the sidebar (confirmed by
chrismo, 2026-11-01). Tabs are untouched; it just looks like they are gone.
Cmd+/ (Show Sidebar) brings it back.

- Setting: "Use a gesture to toggle the sidebar" — Swipe (default), Option-swipe
  or Off (preview.21, 2026-10-26).
- Settings → Interface → Gestures → "Use trackpad gestures" turns this and the
  pane-switch swipe off together (preview.24, 2026-10-30).
- Known to misfire on horizontal scrolling in neovim, diffs and mouse-capture
  TUIs. Related feedback threads are listed in [Feedback threads](#feedback-threads);
  I haven't identified each thread individually.

## Wrapped URLs

A URL that wraps onto the next line only highlights (and clicks) up to the
wrap (observed 2026-11-01). The upside: when the continuation line is indented,
copying the URL drops those indent spaces, so the clipboard gets a clean URL.

Two active #feedback bugs cover it: "URL parsing error caused by text wrapping"
and "Long-press copy soft-wrapped link copies only first part." Their tracking
links and latest status are in [Feedback threads](#feedback-threads). No changelog
entry found.

## Font size

There is a terminal font size in the app's settings (and font family, browsable
live from the command palette), but **not in `init.lua`**, so it can't live in
this repo. `client.font.increase` zooms in 1 pt steps and isn't persisted.

The accepted settings-export request is tracked in [Feedback threads](#feedback-threads).
The team said GUI settings would remain machine-written, with a way to export
them to a file; that thread doesn't confirm the export has shipped. When it does,
track the exported file under `terminal/rex/`.

Set the size in the Settings dialog. `defaults write com.superlogical.rex
Workspace.terminalFontPointSize` has no effect on the running app (tried
2026-10-30: new panes ignored it, then came up at an unexplained 24×48 px
cells). Current choice: monofur at 18 pt, which renders small for its size.

To check the size a new pane gets, open a throwaway pane and read its cell size
(`rex block call ... size`). With monofur on Retina, `cell_height_px` came out
at 2× the point size (16 pt → 32, 18 pt → 36).
Related font requests and bugs are listed in [Feedback threads](#feedback-threads).

## Feedback threads

A curated list of Rex Beta feedback threads mentioned in these notes—not
necessarily every thread followed in Discord. The MCP can search/list community
feedback, but doesn't expose the signed-in user's personal follow list. Statuses
below were checked 2026-11-02 unless otherwise noted and may change.

### Accepted

- [Settings in config files](https://discord.com/channels/1546797889009881158/1556737365475598464) — **accepted**. Export GUI settings to a file; not confirmation that this has shipped.
- [Option to hide or minimize the persistent key-mode panel](https://discord.com/channels/1546797889009881158/1564056474735616010) — **accepted**.

### Active

- [Move a pane to a new (or existing) session](https://discord.com/channels/1546797889009881158/1563606338615902309) — feature request, also asks for moving whole tabs across sessions while keeping programs running; active as of 2026-11-04.
- [Move pane l/r/u/d should also change split](https://discord.com/channels/1546797889009881158/1566477829627977738) — feature request.
- [Rotate / transpose a split](https://discord.com/channels/1546797889009881158/1559678526943137813) — feature request.
- [URL parsing error caused by text wrapping](https://discord.com/channels/1546797889009881158/1563062398829723658) — bug; wrapped URL is only linked through the first line.
- [Increasing font and then setting font](https://discord.com/channels/1546797889009881158/1565674794035183626) — bug; changing size while zoomed reportedly doesn't apply until zoom is reset.
- [Option-drag for rectangular (column) text selection](https://discord.com/channels/1546797889009881158/1567758434781102161) — feature request filed by chrismo; Option-drag currently makes a normal line-wise selection. Active as of 2026-11-05.

### Deferred

- [Programmatically change app settings in `init.lua`](https://discord.com/channels/1546797889009881158/1566745573933981768) — duplicate; MCP showed deferred on 2026-11-02.

- [Moving pane from vertical to horizontal](https://discord.com/channels/1546797889009881158/1563356601245507651) — feature request.
- [Default font size](https://discord.com/channels/1546797889009881158/1564729631553093675) — report that Rex defaults to 12 pt vs Ghostty's 13 pt.
- [Allow for file as source of truth for Rex config](https://discord.com/channels/1546797889009881158/1564597424230629400) — define all settings in a file rather than the GUI.

### Duplicate / status to verify

- [Expose font family, size, and smoothing in Lua API](https://discord.com/channels/1546797889009881158/1565462610533552292) — marked as a duplicate of the accepted settings-in-config-files thread in these notes; MCP currently reports it as deferred.
- "Long-press copy soft-wrapped link copies only first part" — mentioned above, but I couldn't retrieve its thread in the MCP search; link and current status need verification.
- Sidebar gesture/swipe feedback — multiple threads mentioned above; individual links and statuses not yet collected.

## Community MCP

Docs, changelog and the Rex Beta Discord's #feedback forum (with team
decisions), searchable by agents. Requires Discord sign-in as a beta member.

```sh
claude mcp add --transport http --scope user superlogical https://www.superlogical.com/rex/community-mcp
```

Then `/mcp` → `superlogical` → Authenticate. Named `superlogical`, not `rex`,
per their docs, to avoid clashing with the rex skill and CLI. Search it before
filing anything in the Discord, which is the only place to report bugs.
