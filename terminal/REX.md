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
| `move_split` | custom `pane_move_dir` and `pane_push_dir` actions in `panes.lua`, see below |
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

Instead, `terminal/rex/panes.lua` adds a swap/move-into on ⌘⌥⇧+arrow and a
push into the neighbor's row or column on ⌥⇧+arrow (2026-11-01). ⌘⌃ was ruled
out for push because the MBP keyboard can't register caps+A+F+J, and the swap
chord already uses every finger (see brain's
`keyboarding/physical-keyboard-limitations.md`). For flipping a split between
side by side and stacked, use Rex's built-in Rotate Split.

Left as good enough: push has a glitch or two that haven't been looked into.

Why not the Moestty gesture: without a preview, each press has to commit a real
move. A version that walked the pane around a target used an invisible "still
the same move" timer, so the same key did different things depending on timing.
It wasn't predictable. Nothing found offers a preview overlay or a
modifier-release event. A key mode could hold the move open, but Rex pins a
key-hint panel up for as long as any mode is active. "Show key sequence hints"
doesn't hide it; the accepted request to hide or minimize that panel is tracked
in [Feedback threads](#feedback-threads). If Moestty's gesture is ever wanted,
the untried route is a translucent floating layer (`session.new_layer` /
`resize_layer`) as the preview, plus a key mode with Enter to commit.

Unavoidable surprise left, from Rex's binary split tree:

- A move out of a split always hands that space to the pane's partner in the
  tree, which isn't visible. Two layouts that look the same can stretch
  differently.
- Push leaves a hole that the tree partner fills. In a column-first 2×2, TR ↓
  makes three full-height columns, not one-plus-three.
- `move_block` can't take a group of panes as its target.
  So "full-height pane ← past a stacked column" lands beside one pane of that
  column. Untried fix: `session.new_split` *can* anchor on a split, so create a
  placeholder beside the group, `swap_blocks` into it, and close the placeholder.

Related pane-movement requests are tracked in [Feedback threads](#feedback-threads).

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
below were checked 2026-11-02 and may change.

### Accepted

- [Settings in config files](https://discord.com/channels/1546797889009881158/1556737365475598464) — **accepted**. Export GUI settings to a file; not confirmation that this has shipped.
- [Option to hide or minimize the persistent key-mode panel](https://discord.com/channels/1546797889009881158/1564056474735616010) — **accepted**.

### Active

- [Move pane l/r/u/d should also change split](https://discord.com/channels/1546797889009881158/1566477829627977738) — feature request.
- [Rotate / transpose a split](https://discord.com/channels/1546797889009881158/1559678526943137813) — feature request.
- [URL parsing error caused by text wrapping](https://discord.com/channels/1546797889009881158/1563062398829723658) — bug; wrapped URL is only linked through the first line.
- [Increasing font and then setting font](https://discord.com/channels/1546797889009881158/1565674794035183626) — bug; changing size while zoomed reportedly doesn't apply until zoom is reset.

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
