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
| `move_split` | `pane.move` (bound in init.lua) |
| `move_split_to_new_tab` | `pane.move_to_new_tab` |
| `move_tab_to_split` | `pane.move_to_tab…` (picker, starts from the pane) |
| `mark_tab` + `move_marked_tabs_to_new_window` | `client.tab.move_to_new_window`, one tab at a time — **no marks** |
| `toggle_tab_switcher` | nothing equivalent found yet |

Rex extras: floating panes (`pane.float`), detached blocks that keep running,
server-side sessions, key modes and sequences, `rex move` / `rex swap` from the
CLI. Not yet checked: what Rex's default `cmd+alt+shift+w` does (Ghostty's
closed every window, so the Ghostty config unbinds it).

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
  `terminal/rex/`. Until then the only scriptable route is
  `defaults write com.superlogical.rex Workspace.terminalFontPointSize ...`.
  He also notes `init.lua` can already `require()` other files.
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
