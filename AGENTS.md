# AGENTS.md

Guidance for LLM agents working in this repository.

## Project

telega.el — a full-featured Telegram client for GNU Emacs. GPL-3.
This checkout is a fork of zevlg/telega.el at v0.8.671 (master branch).

Two parts:
- **Emacs Lisp** — top-level `telega*.el` files plus `contrib/` (optional add-ons).
- **telega-server** — `server/`, a small **C** daemon (this version predates the
  Rust rewrite) that speaks JSON over stdin/stdout to **TDLib** (`libtdjson`,
  built via `server/Makefile` using pkg-config; zlib/appindicator/VOIP optional).
  Targeted TDLib: `1.8.66` (`telega-tdlib-min-version`, telega.el:14).

## Build / test commands

```sh
make                       # build server + byte-compile all elisp
make telega-server         # build server only (make -C server)
make server-reinstall      # clean + rebuild + install server to ~/.telega
make test_el               # ert tests: emacs -Q -batch -L . -l etc/telega-make -f telega-run-tests
make test_server           # server/run_tests.py (JSON<->plist roundtrip vs built binary)
make compile               # byte-compile everything
make update-version        # bump TDLib version constant
```

- `make test` runs both test suites. CI (`.github/workflows/test.yml`) =
  byte-compile + `test_el` on Emacs 28.1 and snapshot.
- Elisp tests live in **`test.el`** (all `ert-deftest`s). They are pure elisp
  against fake chat data injected via `telega--info-update` — **no server or
  Telegram account needed**. Add tests there for new logic.
- Validate elisp changes with:
  `emacs --batch -L . -f package-initialize --eval '(load "telega")'` or byte-compile the touched files.

## Module map

Entry point: `telega.el` (requires all modules, runs `telega-load-hook` at :426).

| File | Responsibility |
|---|---|
| telega-core.el | core state, plists accessors (`telega--tl-get/-prop/-type`), buffer macros (`with-telega-root-buffer`, `with-telega-chatbuf`) |
| telega-server.el | server lifecycle: locate/build (`telega-server-build`), start (`telega-server--start`), send/call (`telega-server--send`, `telega-server--call` with hashtable of callbacks) |
| telega-tdlib.el | 1:1 wrappers for TDLib methods (`telega--sendMessage`, …); sync via `with-telega-server-reply`, async via `:callback` kw |
| telega-tdlib-events.el | handling of TDLib updates |
| telega-root.el | `*Telega Root*` chat-list buffer, timers (status dots, loading, idle) |
| telega-chat.el | chat buffers, input line, `telega-chat-mode` |
| telega-msg.el / telega-user.el | message and user objects (plain plists with `:@type`, NOT EIEIO) |
| telega-ins.el | inserters: how msgs/photos/stickers/buttons get rendered into buffers |
| telega-media.el | image creation/downscaling (`telega-media--create-image`, avatars via SVG), file download |
| telega-sticker.el / telega-util.el | stickers/animated playback; SVG generation & utilities |
| telega-ffplay.el | external ffplay/ffmpeg for animation & media playback |
| telega-customize.el | ALL defcustoms + faces, grouped per subsystem (`telega`, `telega-root`, `telega-chat`, `telega-symbol`, `telega-faces`, `telega-hooks`, …) |
| telega-notifications.el, telega-emoji.el, telega-webpage.el, telega-filter.el, telega-sort.el, telega-inline.el, telega-rich-text.el, telega-transient.el (EIEIO menus only), etc. | subsystems |
| contrib/ | optional add-ons (adblock, dashboard, mnz, bridge-bot, …) |
| docs/ | manual built from docstrings via ellit-org → `docs/Makefile` exports HTML |

## Conventions

- `telega--foo` = internal/private; `telega-foo` = public API.
- TDLib method wrappers mirror TDLib names exactly: `telega--<TdlibName>`.
- Data objects (chats, msgs, users) are **plists with `:@type`**; predicates
  check `:type` (e.g. `telega-msg-p`). EIEIO classes are used only for
  transient menus.
- New user options belong in `telega-customize.el` in the matching defcustom
  group; document via docstring (the manual scrapes docstrings).
- Hooks are defcustoms in the `telega-hooks` group; autoload cookies are plain
  `;;;###autoload`.
- Symbols/glyphs are customizable via `telega-symbol-*` defcustoms
  (group `telega-symbol`, telega-customize.el:2353+).
- Global user rules (see ~/.qoder/AGENTS.md): work on branch `ai/<topic>`,
  commit as `MODEL (AGENT) <MODEL@PROVIDER>`, small simple commented code,
  no technical debt, validate with `emacs --batch` before loading into a live
  session (`emacsclient`).

## Performance / display machinery (read before touching)

- Image insertion: `telega-ins-image-create` / `telega-media--create-image`
  (telega-media.el:449, telega-ins.el:~150–231); text fallback when
  `(not (display-graphic-p (telega-x-frame)))`.
- `telega-use-images` (telega-customize.el:227) is the master images switch.
- Avatars are generated as SVG (telega-media.el:862+, telega-util.el:268+) —
  expensive; switched by `telega-{root,user,chat}-show-avatars`.
- Animated stickers: telega-sticker.el:970–1078 (`telega-sticker-animated-play`,
  `telega-animation-play-inline`, `telega-animation-height`).
- Root buffer redraw timers: telega-root.el:491–1327
  (`telega-status-animate-interval`).
- Message bodies render via `line-prefix`/display props
  (telega-ins.el:3203, telega-core.el:2480).
- This checkout has **no** tty-touch support: no `touch-screen` /
  `no-bitmap` terminal-parameter handling anywhere.

## Gotchas

- Running telega needs a working `telega-server` binary + built TDLib;
  the elisp test suite does not.
- `server/` is C here, upstream master is Rust — don't copy upstream Rust-era
  advice blindly.
- Don't run two `guix` rebuilds in parallel; avoid heavy builds on this host
  (4 GB RAM, use `-j1`).
