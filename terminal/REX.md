# Rex

Notes from trying [Rex](https://www.superlogical.com/rex/docs) (Superlogical's
terminal multiplexer, macOS app + server) as a replacement for Moestty, the
personal Ghostty fork in `~/modev/ghostty`. Started 2026-10-30 on Rex Beta 0.1.0.

## Setup

- Config: `terminal/rex/init.lua`, which `require`s `panes.lua`. Each file is
  linked into `~/.config/rex/` by `install.sh`. Apply with `rex config check && rex config reload`.
- Shortcuts set in the app's settings override `init.lua`. They're stored in
  `~/Library/Application Support/com.superlogical.rex/Shortcuts/shortcuts.json`
  (per a #feedback thread, not checked here).
- The app takes actions from the CLI (`rex -C <client> do ...`) only with
  **Settings → Rex Server → Remote Control** on.
- Docs as markdown: append `.md` to any page; index at
  `https://www.superlogical.com/rex/docs/llms.txt`.

## Claude hooks: hands off for now

`tab-status` sets titles only under Ghostty (389c1d0), so Rex tabs get no
status glyphs. That is deliberate: see what Rex does for Claude sessions out of
the box before agent-rig intervenes.

## Moestty features in Rex

| Moestty / Ghostty | Rex |
|---|---|
| `move_split` | custom `pane_move_dir`, `pane_push_dir`, `pane_rotate_split` actions in `panes.lua`, see below |
| `move_split_to_new_tab` | `pane.move_to_new_tab` |
| `move_tab_to_split` | `pane.move_to_tab…` (picker, starts from the pane) |
| `mark_tab` + `move_marked_tabs_to_new_window` | `client.tab.move_to_new_window`, one tab at a time — **no marks** |
| `toggle_tab_switcher` | nothing equivalent found yet |

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

What's in `terminal/rex/panes.lua` (required from `init.lua`) instead (2026-11-01). Every press depends only on the
layout on screen:

- **⌘⌥⇧+arrow, `pane_move_dir`.** If the neighbor that way shares the pane's
  full row (or column), the two swap (`session.swap_blocks`), and the opposite
  arrow undoes it. If the neighbor is larger, the pane moves into it
  (`session.move_block`) on whichever edge best keeps its row or column. So in
  ccc | aaa / (ddd | bbb), ddd ← lands under ccc, not beside it. With no
  neighbor that way, nothing happens.
- **⌥⇧+arrow, `pane_push_dir`.** The pane always moves, never swaps. It joins
  the neighbor's row (↑↓) or column (←→), landing on the side nearer where it
  was. On a tie, it lands nearer the window edge it was closer to. In a
  row-first 2×2, TR ↓ gives TL across the top and BL | BR | TR below, and TR ↑
  undoes it. Sizes are left as Rex splits them. ⌘⌃ was ruled out because the
  MBP keyboard can't register caps+A+F+J, and the swap chord already uses every
  finger (see brain's `keyboarding/physical-keyboard-limitations.md`).
- **⌘⌥R, `pane_rotate_split`.** Flips the pane and its split partner between
  side by side and stacked. It's based on adi's `rotate_split` in the "Rotate /
  transpose a split" #feedback thread, and refuses when the partner is a group of
  panes. Rex turned out to have a built-in Rotate Split as well; the two
  haven't been compared.

Left as good enough (2026-11-01): push has a glitch or two that haven't been
looked into, and the whole set could be refined with more study.

Why not the Moestty gesture: without a preview, each press has to commit a real
move. A version that walked the pane around a target used an invisible "still
the same move" timer, so the same key did different things depending on timing.
It wasn't predictable. Nothing found offers a preview overlay or a
modifier-release event. A key mode could hold the move open, but Rex pins a
key-hint panel up for as long as any mode is active. "Show key sequence hints"
doesn't hide it, and an option to is an accepted #feedback request, "Option to
hide or minimize the persistent key-mode panel". If Moestty's gesture is ever
wanted, the untried route is a translucent floating layer (`session.new_layer`
/ `resize_layer`) as the preview, plus a key mode with Enter to commit.

Unavoidable surprise left, from Rex's binary split tree:

- A move out of a split always hands that space to the pane's partner in the
  tree, which isn't visible. Two layouts that look the same can stretch
  differently. Swapping avoids this, which is why swap is the default.
- Push leaves a hole that the tree partner fills. In a column-first 2×2, TR ↓
  makes three full-height columns, not one-plus-three.
- Rotate pairs a pane with its tree partner. In a 2×2, the lower-left pane's
  partner is the upper-left pane if the grid was built column-first, or the
  lower-right pane if it was built row-first.
- `move_block` can't take a group of panes as its target.
  So "full-height pane ← past a stacked column" lands beside one pane of that
  column. Untried fix: `session.new_split` *can* anchor on a split, so create a
  placeholder beside the group, `swap_blocks` into it, and close the placeholder.

Related #feedback: "Move pane l/r/u/d should also change split" (active,
2026-11-01), "moving pane from vertical to horizontal" (deferred), and "Rotate /
transpose a split" (active).

## Sidebar vanished: a two-finger swipe

A two-finger horizontal trackpad swipe hides and shows the sidebar (confirmed by
chrismo, 2026-11-01). Tabs are untouched; it just looks like they are gone.
Cmd+/ (Show Sidebar) brings it back.

- Setting: "Use a gesture to toggle the sidebar" — Swipe (default), Option-swipe
  or Off (preview.21, 2026-10-26).
- Settings → Interface → Gestures → "Use trackpad gestures" turns this and the
  pane-switch swipe off together (preview.24, 2026-10-30).
- Known to misfire on horizontal scrolling in neovim, diffs and mouse-capture
  TUIs. Several #feedback threads, some deferred.

## Wrapped URLs

A URL that wraps onto the next line only highlights (and clicks) up to the
wrap (observed 2026-11-01). The upside: when the continuation line is indented,
copying the URL drops those indent spaces, so the clipboard gets a clean URL.

Two active #feedback bugs cover it: "URL parsing error caused by text wrapping"
(2026-10-23, only the first line becomes the link) and "Long-press copy
soft-wrapped link copies only first part" (2026-10-29). No team reply on either
yet, and no changelog entry.

## Font size

There is a terminal font size in the app's settings (and font family, browsable
live from the command palette), but **not in `init.lua`**, so it can't live in
this repo. `client.font.increase` zooms in 1 pt steps and isn't persisted.

Community feedback (from the MCP below):

- [settings in config files](https://discord.com/channels/1546797889009881158/1556737365475598464) —
  **accepted** (planned). Mitchell's reply sets the direction: Lua is for
  human-written config, so settings won't become `init.lua` calls. The app keeps
  them in a machine-written location (only macOS user defaults today, changing
  "very soon") and will get an export to a file, like "Copy as Lua" already
  does for shortcuts. When that lands, track the exported file under
  `terminal/rex/`. He also notes `init.lua` can already `require()` other files.

Set the size in the Settings dialog. `defaults write com.superlogical.rex
Workspace.terminalFontPointSize` has no effect on the running app (tried
2026-10-30: new panes ignored it, then came up at an unexplained 24×48 px
cells). Current choice: monofur at 18 pt, which renders small for its size.

To check the size a new pane gets, open a throwaway pane and read its cell size
(`rex block call ... size`). With monofur on Retina, `cell_height_px` came out
at 2× the point size (16 pt → 32, 18 pt → 36).
- [Expose font family, size, and smoothing in lua API](https://discord.com/channels/1546797889009881158/1565462610533552292) —
  the dotfiles request. Closed 2026-10-29 as a dupe of the one above.
- [Increasing font and then setting font](https://discord.com/channels/1546797889009881158/1565674794035183626) —
  while zoomed, changing the size in settings does nothing until the zoom is
  reset. Open as of 2026-10-30.
- [Default font size](https://discord.com/channels/1546797889009881158/1564729631553093675) —
  a user reports Rex defaults to 12 pt (Ghostty 13). Deferred.

## Community MCP

Docs, changelog and the Rex Beta Discord's #feedback forum (with team
decisions), searchable by agents. Requires Discord sign-in as a beta member.

```sh
claude mcp add --transport http --scope user superlogical https://www.superlogical.com/rex/community-mcp
```

Then `/mcp` → `superlogical` → Authenticate. Named `superlogical`, not `rex`,
per their docs, to avoid clashing with the rex skill and CLI. Search it before
filing anything in the Discord, which is the only place to report bugs.
