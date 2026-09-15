# Stoplight

A macOS menu bar app that shows, at a glance, whether any Claude Code session on
this machine needs you.

Three lamps in a stoplight housing. Each is an independent aggregate, so any
combination can be lit at once:

| Lamp | Meaning |
|---|---|
| 🔴 red | a session errored, crashed, or hit a limit |
| 🟡 yellow | a session needs **you** — permission prompt, a question, or a turn that just finished |
| 🟢 green | a session is working; leave it alone |
| dark | nothing in that bucket |

All three lamps are always drawn — unlit ones are dimmed rather than hidden — so
"which lamp is on" reads as brightness at a fixed slot and never depends on being
able to distinguish hue.

The icon is an upright housing with red on top, laid out natively at menu bar size.
Hovering opens a detail panel carrying a second, much larger stoplight. Clicking
opens the menu.

## Status

**Milestone 1 of 5. The UI works; it is not yet connected to any data.**

What works today:

- Menu bar icon, drawn with Core Graphics, adapts to light/dark menu bars
- Hover → detail panel, after a 0.22s hover-intent delay
- Click → menu
- 22 passing tests

What does not exist yet: **any real session monitoring.** The lamp counts are
hardcoded. Use *Cycle demo state* in the menu to walk the six lamp permutations
and see how the rendering behaves.

## Requirements

- macOS 14+ (developed on 26.5)
- Swift 6 toolchain (developed on 6.3.3)
- Xcode **not** required — Command Line Tools is enough

## Build and run

```sh
./build.sh          # release build, assembles and ad-hoc signs Stoplight.app
open Stoplight.app
```

`build.sh debug` builds the debug configuration instead. The ad-hoc `codesign`
step is not optional on Apple Silicon — an unsigned bundle is killed on launch.

There is no login item yet; launch it by hand.

## Tests

```sh
./test.sh                        # all tests
./test.sh --filter Icon          # a subset
```

`test.sh` exists because of a real toolchain wrinkle. Swift Testing ships inside
Command Line Tools, but SwiftPM only wires up its framework search paths when
`XCTest` is also present — and `XCTest` is Xcode-only. So `swift test` on its own
fails with `no such module 'Testing'`. The script points at `Testing.framework`
and `lib_TestingInterop.dylib` explicitly, resolving both from `xcode-select -p`
so that installing Xcode later does not break it.

## Layout

```
Sources/StoplightCore/     everything testable
  LightState.swift           lamp buckets, summary text
  StoplightIcon.swift        Core Graphics drawing + rotation geometry
  StatusItemController.swift status item, hover, menu
  PopoverView.swift          SwiftUI hover panel
Sources/Stoplight/
  main.swift                 four-line shim: activation policy + run loop
Tests/StoplightCoreTests/
```

The library/executable split is load-bearing: an executable target cannot be
`@testable import`ed cleanly, so all real code lives in `StoplightCore`.

## How it will get its data

Claude Code already maintains the state this app needs, so there is no process
scraping or log tailing involved.

- **`~/.claude/sessions/<pid>.json`** — the primary source. Claude Code writes one
  file per live session, carrying `pid`, `sessionId`, `cwd`, `status`, `version`
  and timestamps. Watching that one directory with FSEvents gives push-based
  updates and 0% idle CPU. Session files can outlive their process, so entries are
  reaped with `kill(pid, 0)`.
- **Hooks** (`Notification`, `Stop`, `SessionEnd`) — `status` alone cannot separate
  "thinking" from "blocked on a permission prompt", which is exactly the
  green/yellow split. Hooks supply that transition.
- **`~/.claude/projects/<slug>/<sessionId>.jsonl`** — live transcript, for token
  counts and the current tool name. Parsed lazily, only while the panel is open.
- **`~/.claude/stats-cache.json`** — pre-aggregated daily counts, to backfill the
  scoreboard.

Scope is the default `~/.claude` config dir only. Multi-account was considered and
dropped: a second account cannot be auto-discovered anyway, because mapping a
running PID to a non-default `CLAUDE_CONFIG_DIR` requires reading that process's
environment, and macOS does not allow it.

`~/.claude/sessions/` is an internal Claude Code implementation detail, not a
public API. It is read through a tolerant, fail-open decoder so a format change in
a future version degrades to "unknown" instead of crashing.

## Known constraints

**The lamps are small: about 5.6px on a 24pt menu bar, 4.9px on a 22pt one.**
Three lamps stacked vertically inside ~22px leaves no more room than that. The
layout is solved for the bar height rather than scaled down to it, so they at
least stay crisp. It is also why the hover panel carries a second, full-size
stoplight — the menu bar icon signals, the panel is what you actually read.

A horizontal arrangement would afford ~8.5px lamps, which is meaningfully more
legible but reads as three loose dots rather than a stoplight. That trade was made
deliberately in favour of the stoplight.

## Development notes

**Hover on a status item is not a built-in.** `NSStatusItem` has no hover support;
it requires an `NSTrackingArea` on `statusItem.button`, handled manually.

**Tracking-area selectors must be spelled explicitly.** On a class that is not an
`NSResponder`, Swift maps `mouseEntered(with:)` to the ObjC selector
`mouseEnteredWith:`, but `NSTrackingArea` only ever calls `mouseEntered:`. The
mismatch fails silently — no crash, no warning, hover simply never fires. Hence
`@objc(mouseEntered:)`. `StatusItemControllerTests` locks this down from both
directions.

**The hover surface is an `NSPanel`, not an `NSPopover`.** A popover from a
background `.accessory` app needs the app activated to display reliably, and
activating on hover would pull focus off whatever you were typing in. A
non-activating panel renders without ever taking focus.

**No `toolTip` on the button.** AppKit owns tooltips and its tooltip wins over the
panel.

**The icon deliberately does not animate.** An earlier version drew it horizontally
and rotated it upright on hover. Because the artwork's bounding box changes as it
turns, every frame resized the `NSStatusItem`, and AppKit relayouts the whole menu
bar whenever that happens — visibly choppy, and it shoved neighbouring icons
around. Drawing it upright from the start removed the animation, the per-frame
relayout and the downscaling blur together.

## Roadmap

1. ✅ Menu bar item, drawn lamps, hover/click split
2. `SessionWatcher` on `~/.claude/sessions/` + liveness reaper → real green/dark
3. Hooks → yellow and red; install/uninstall flow
4. Panel detail: session rows, cwd, elapsed, current tool
5. SQLite scoreboard + `stats-cache.json` backfill
