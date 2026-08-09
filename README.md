# Translit

Automatic ru/en keyboard layout switcher for macOS, in the spirit of Punto
Switcher. Type «ghbdtn» — get «привет»: the word is erased, the system layout
is switched, and the word is retyped in the right layout.

Status bar app, Swift/SwiftPM, no dependencies. Fully event-driven: zero CPU
while you are not typing, a few microseconds of integer math per word while
you are. Resident footprint is a few megabytes.

## How it works

1. A `CGEventTap` on `keyDown` buffers the current word as **keycodes**
   (physical keys), not characters.
2. On a word separator (Space, Enter, Tab, layout-invariant punctuation) the
   buffer is read through both layouts — the same keys are «ghbdtn» in the
   English projection and «привет» in the Russian one.
3. Each reading is scored with bigram log-probability tables baked into the
   binary (`Sources/translit/Bigrams.swift`, ~2 KB). A reading containing a
   non-letter key (e.g. `;`) is impossible for that language.
4. **Is it a word?** Bloom filters over the 50k most frequent words of each
   language (98 KB each, same file) answer this, and their verdict outranks
   the scores in both directions — bigrams rate the meaningless "inere"
   above «штуку», and rate the real «абзац» below the plausibility floor.
   A fix fires when the result is a known word and the typed text is not,
   and is refused in the mirror case.
5. When neither reading is a known word, the alternative layout wins only if
   it beats the typed one by `switchMargin` (1 bit per character) and is
   itself plausible (`plausibilityFloor`). Then: the separator keystroke is swallowed, the word
   is erased with synthetic Backspaces, `TISSelectInputSource` switches the
   layout, the word and the separator are retyped. Works for Enter too — the
   fix happens *before* the Enter is delivered, so chat messages go out
   corrected.

Keycode→character maps are built at startup from the actual input sources via
`UCKeyTranslate`, so any QWERTY/ЙЦУКЕН variants installed on the machine work.

## Undo and exceptions

Backspace **immediately after** an auto-fix reverts it verbatim (original
layout and characters restored) and adds the word to a persistent exception
list — it will never be auto-fixed again. Any other key confirms the fix.

## User dictionary

Two plain-text lists in `~/.config/translit/` (a symlink into this dotfiles
repo, so edits travel between machines with the usual sync):

- **rules.txt** — words fixed *always*, bypassing statistics and the minimum
  word length. This is how short words work: statistics cannot decide «b» vs
  «и» or «yt» vs «не», the rule list can. Direction is implied by the
  alphabet: Latin entries fix en→ru («b» is «и» typed in the English layout),
  Cyrillic entries fix ru→en («еру» is "the" typed in the Russian one).
  Ships with ~40 common short words in both directions.
- **exceptions.txt** — words never fixed; Backspace-undo appends here
  automatically.

One word per line, `#` comments, case-insensitive. Both files are watched
(dispatch sources, event-driven) and reload within half a second of saving —
edit mid-flight from the menu («Правила…» / «Исключения…») or any editor,
no restart needed. `--test <word>` reports dictionary hits alongside scores.

## Safety rails

- Password fields: secure input (`IsSecureEventInputEnabled`) disables fixing.
- Hotkeys (⌘/⌃), mouse clicks, arrows, app switches, manual layout switches —
  reset the buffer; words with digits or ⌥-characters are never touched.
- Per-app exclusions (defaults: Terminal, iTerm2) — toggle for the frontmost
  app from the status bar menu.
- Words shorter than 3 letters are ignored.
- The "Pop" click on every fix can be silenced from the menu («Звук при
  исправлении»).

## Auto-update

Updates come from [GitHub Releases](https://github.com/arolus/translit/releases):
CI builds `Translit.app` for every new `VERSION` pushed to `main`, and the app
checks `releases/latest` at startup and every 6 hours, downloads the zip and
swaps `~/Applications/Translit.app` — no toolchain needed on the machine.
Toggle: «Автообновление» in the menu; «Проверить обновления» forces a check.

Release flow for maintainers: bump `VERSION` (`./build.sh --bump` or edit by
hand), push to `main` — CI does the rest. A plain `./build.sh` never bumps,
so local rebuilds don't trigger releases.

Caveat: the ad-hoc signature identity changes with each binary, so macOS asks
for the Accessibility permission again after every update (the stale TCC entry
is reset deliberately — it would look enabled while not working). The app
polls and picks the permission up as soon as it is granted.

## Build & install

```sh
git clone https://github.com/arolus/translit.git && cd translit
./install.sh    # builds, → /Applications, LaunchAgent com.arsidian.translit
```

Or grab a prebuilt `Translit.app.zip` from the
[releases](https://github.com/arolus/translit/releases) and unzip into
/Applications — enable «Запускать при входе» from the status bar menu to
start it at login (install.sh sets that up automatically). `./build.sh`
alone rebuilds the bundle without installing.

Requires an enabled Russian keyboard layout and the Accessibility permission
(the system prompt appears on first start; the app polls until granted).

Debug scoring without installing:

```sh
./.build/release/translit --test ghbdtn
# en reading: "ghbdtn"  score -26.29
# ru reading: "привет"  score -12.43
# verdict: ru wins by 13.86
```

## Retraining the tables

`train/train.js` (Node) counts letter bigrams per language from any text you
feed it — mixed-language files are fine, Cyrillic words feed the Russian
table and Latin words the English one — and regenerates `Bigrams.swift`:

```sh
node train/train.js /usr/share/dict/words ~/Projects/**/*.md
./build.sh
```

It also prints held-out validation accuracy and the score-gap percentiles the
`switchMargin`/`plausibilityFloor` constants in `main.swift` were picked from
(~99.3% accuracy on the current corpus in both directions).

## Measuring against real dictionaries

`--eval <wordlist> <ru|en>` runs the engine's actual decision over a word
list, twice per word: typed correctly (any fix is a false positive) and
typed with the other layout active (a fix is the point). Add `--verbose` for
examples of both kinds of miss.

Against Hunspell dictionaries (194k words, none of which the thresholds were
tuned on):

| corpus | wrongly changed | rescued |
|---|---|---|
| ru_RU.dic, 146k words | 0.09% | 98.3% |
| en_US.dic, 48k words | 0.16% | 98.1% |

The residue on both axes is dominated by acronyms and abbreviations (вуз,
квн, bbq, dj, ghz) whose wrong-layout twin is a plausible word — genuinely
ambiguous, and what `exceptions.txt` is for. Frequency-list tails
(OpenSubtitles 300k) score worse (~0.3% / ~95%) mostly because they are full
of misspellings and foreign words.

## Known limitations

- Corrections rely on Backspace behaving as "delete one char" — fine in text
  fields, meaningless in vim normal mode etc.; exclude such apps.
- Fast typing during the ~0.2 s fix window can interleave with the synthetic
  keystrokes.
- Only two layouts (ru + first ASCII-capable); a third active layout pauses
  the engine.
