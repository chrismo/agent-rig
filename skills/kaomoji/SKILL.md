---
name: kaomoji
description: Summon a Japanese-style emoticon (kaomoji) and put it on the clipboard. Pick one that fits the mood — the user's, the moment's, or the conversation's. Invoked as /kaomoji, optionally with a mood or a free-text vibe.
allowed-tools: Bash
model: haiku
effort: low
---

# kaomoji — summon a face

Pick the face that fits, copy it, say one line. **Do it in a single Bash call.**
The full catalog is below, so you never need to run a lookup first.

## Do exactly this

One tool call, then one line of prose. Nothing else:

```
printf '%s' '(・へ・)' | pbcopy
```

Single-quote the face — they're full of backslashes and parens. If the face
itself contains a single quote, use `kaomoji <mood>` instead to draw one.

Then reply with just the face and a short clause on why. Example:

> `(・へ・)` — copied. Rage was too hot for "blerg"; this is the *oh, come on* face.

Do not run a lookup, do not verify with `pbpaste`, do not explain your process.
One call, one line.

## Choosing

Match the *intensity*, not just the valence. "Bummed" is deflated, not weeping.
"Blerg" is exasperated, not enraged. When the argument is free text, map it to
the nearest face below rather than the nearest mood name.

With no argument, read the session: just shipped → celebrate, third failed test
→ table-flip, Friday afternoon → friday. If nothing stands out, run bare
`kaomoji`.

## The catalog

```
bear          ʕ•ᴥ•ʔ  ʕ￫ᴥ￩ʔ  ʕっ•ᴥ•ʔっ  ʕ•̀ω•́ʔ✧

cat           (=^･ω･^=)  ฅ^•ﻌ•^ฅ  (=①ω①=)  ヾ(=｀ω´=)ノ”

celebrate     ヽ(*⌒▽⌒*)ﾉ  (っ˘ω˘ς )  ＼(^▽^)／  (*≧▽≦)ﾉ ~☆
              ٩(ˊᗜˋ*)و

confused      (・_・?)  (⊙_⊙)?  (°ロ°) !  ٩(͡๏_๏)۶
              (¬_¬)  (・∀・)?

determined    (ง •̀_•́)ง  ᕦ(ò_óˇ)ᕤ  (๑•̀ㅂ•́)و✧  o(￣ヘ￣o＃)

dunno         (•_•)  (￢_￢)  ( ˘⌒˘ )  (・へ・)

excited       ヽ(°〇°)ﾉ  (ﾉ◕ヮ◕)ﾉ*:･ﾟ✧  ＼(≧▽≦)／  o(≧∇≦o)
              (★^O^★)  ヽ(＾Д＾)ﾉ  (๑>◡<๑)  ٩(◕‿◕)۶

friday        ヽ(o^▽^o)ノ  (´｡• ᵕ •｡`) ♡  (ノ^_^)ノ  ＼(٥⁀▽⁀ )／
              (っ^▿^)۶🍺  (*≧∀≦*)

happy         (◕‿◕)  (＾▽＾)  (´･ω･`)ﾉ  ヽ(´▽`)/
              (*^▽^*)  (๑˃ᴗ˂)ﻭ  (✿◠‿◠)  (≧◡≦)
              ＼(^o^)／  (◍•ᴗ•◍)

love          (♥ω♥*)  (*♡∀♡)  (´,,•ω•,,)♡  ♡( ◡‿◡ )
              (っ˘з(˘⌣˘ )

oops          (・_・;)  (￣▽￣;)  (； ･`д･´)  (°ロ°;)
              (⁄ ⁄•⁄ω⁄•⁄ ⁄)

rage          (╬ ಠ益ಠ)  ヽ(≧Д≦)ノ  (＃`Д´)  (ﾉಥ益ಥ)ﾉ
              ୧((#Φ益Φ#))୨

sad           (╥﹏╥)  (っ- ‸ - ς)  (｡•́︿•̀｡)  (ಥ﹏ಥ)
              (´；ω；`)  (◞‸◟)

shrug         ¯\_(ツ)_/¯  ╮(￣▽￣)╭  ┐(´д`)┌  ╮(︶︿︶)╭
              乁( ⁰͡ Ĺ̯ ⁰͡ )ㄏ

smug          (¬‿¬)  ( ͡° ͜ʖ ͡°)  (￣ω￣)  ヽ(・∀・)ﾉ
              (^_~)  ( •_•)>⌐■-■  (⌐■_■)

strut         ᕕ( ᐛ )ᕗ  ᕕ(⌐■_■)ᕗ ♪  ᕙ(⇀‸↼‶)ᕗ  ᕕ( ᐖ )ᕗ
              ♪┏(・o･)┛♪  ᕕ(╯°□°)ᕗ

table-flip    (╯°□°)╯︵ ┻━┻  (ノಠ益ಠ)ノ彡┻━┻  ┻━┻ ︵ヽ(`Д´)ﾉ︵ ┻━┻  (ノ`Д´)ノ彡┻━┻

table-unflip  ┬─┬ノ( º _ ºノ)  ┬──┬ ¯\_(ツ)  (╮°-°)╮┳━┳

tired         (－_－) zzZ  (｡-‿-｡)  ( ˘･з･)  (・_・;)
              (￣﹃￣)  （￣o￣） . z Z
```

## Synonyms and partials (for the shell, not for you)

`bin/kaomoji` accepts aliases (`mad` → rage, `meh` → shrug, `argh` → table-flip)
and substring partials (`determ` → determined; `table` pools table-flip and
table-unflip). That's a convenience for typing in a terminal — you have the
whole catalog above, so just pick the face directly.

## Adding faces

Faces live in the `MOODS` array in `bin/kaomoji` in the agent-rig repo — edit
there, never `~/.local/bin/kaomoji` (a symlink).

The catalog above is **generated**, not hand-maintained. After editing the
faces, regenerate it and run the tests (one of which asserts the block matches
`kaomoji faces` exactly, so drift fails the suite):

```
./bin/kaomoji-sync-skill
PATH="/opt/homebrew/opt/bash/bin:$PATH" bats bin/kaomoji.bats
```
