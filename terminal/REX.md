# Rex

Notes from trying [Rex](https://www.superlogical.com/rex/docs) (Superlogical's
terminal multiplexer, macOS app + server) as a replacement for Moestty, the
personal Ghostty fork in `~/modev/ghostty`. Started 2026-10-30 on Rex Beta 0.1.0.

## Setup

- Config: `terminal/rex/init.lua`, linked to `~/.config/rex/init.lua` by
  `install.sh`. Apply with `rex config check && rex config reload`.
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
| `move_split` | `pane.move` (bound in init.lua) — **instant swap only**, see below |
| `move_split_to_new_tab` | `pane.move_to_new_tab` |
| `move_tab_to_split` | `pane.move_to_tab…` (picker, starts from the pane) |
| `mark_tab` + `move_marked_tabs_to_new_window` | `client.tab.move_to_new_window`, one tab at a time — **no marks** |
| `toggle_tab_switcher` | nothing equivalent found yet |

Rex extras: floating panes (`pane.float`), detached blocks that keep running,
server-side sessions, key modes and sequences, `rex move` / `rex swap` from the
CLI. Not yet checked: what Rex's default `cmd+alt+shift+w` does (Ghostty's
closed every window, so the Ghostty config unbinds it).

### `move_split` is interactive in Moestty, a swap in Rex

Moestty's `move_split` doesn't move on the keypress. It shows a highlighted
target square in the destination pane, and further presses walk it around that
pane's four edges (top/bottom/left/right). Releasing the modifiers drops the
split there, so one gesture can also change split orientation. Rex's
`pane.move` just swaps with the neighbor.

Partly rebuildable, maybe (untested, 2026-11-01).
`rex.session.move_block{block_id, anchor_block_id, direction, side, ratio}` is
a positional move, so any edge of a neighbor is reachable. adi's `rotate_split`
in the "Rotate / transpose a split" #feedback thread uses it, finding the
sibling by walking `rex.session.view{}` layouts. Still missing: a preview
overlay and a modifier-release event (a doc search found neither). A
workaround is to move the pane for real on each press, letting the pane act as
the preview. The docs say `rex.bind` Lua functions aren't allowed inside a key
mode; adi binds a named `rex.action` by name, which might be allowed there.

Related #feedback: "Move pane l/r/u/d should also change split" (active,
2026-11-01), "moving pane from vertical to horizontal" (deferred), and "Rotate /
transpose a split" (active, has the `move_block` workaround). All are the
orientation half of this. Neither has the preview-and-commit targeting.

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
