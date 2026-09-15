# Stoplight

[![tests](https://github.com/justisGipson/stoplight/actions/workflows/test.yml/badge.svg)](https://github.com/justisGipson/stoplight/actions/workflows/test.yml)
[![release](https://github.com/justisGipson/stoplight/actions/workflows/release.yml/badge.svg)](https://github.com/justisGipson/stoplight/actions/workflows/release.yml)
[![latest release](https://img.shields.io/github/v/release/justisGipson/stoplight?sort=semver&color=blue)](https://github.com/justisGipson/stoplight/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](#requirements)
[![dependencies](https://img.shields.io/badge/dependencies-none-2ea043)](Package.swift)

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

**All five milestones done.** Three lamps reading live state, plus a usage window.
No hooks, no dependencies, nothing written to your Claude Code config.

What works today:

- Live session monitoring via FSEvents on `~/.claude/sessions/`, with dead
  processes reaped
- 🟢 green from `status: "busy"`
- 🟡 yellow from `status: "waiting"` — blocked on you right now — and from a
  session that finished within the last 5 minutes, decaying back to dark on a
  scheduled one-shot rather than a poll
- 🔴 red from a session whose process vanished while it was still working, and
  from a fresh API error that a session stalled on
- Hover panel per session: folder, what it is doing, the running tool, context
  size, age
- Dismissing failures, and a diagnostics line, in the menu
- **Usage & Scoreboard** window off the menu: lifetime cost, tokens, sessions and
  crashes, ranked by project and by model
- 95 passing tests

**What red catches.** Two things, neither of them an explicit failure field,
because Claude Code does not write one.

*A vanished session.* Shutting down cleanly settles to `idle` first, so a session
that disappears straight out of `busy` or `shell` was killed, crashed, or had its
terminal closed mid-task.

*A stalled API error.* The transcript records `isApiErrorMessage` with an
`apiErrorStatus` — a 429 rate limit, a 529 overload. That only counts as a failure
if the session **stopped** at it; still working means it retried and carried on,
and lighting red for a 529 that resolved itself would cry wolf.

**Why there are no hooks.** An earlier plan installed Claude Code hooks to tell
"blocked on a permission prompt" apart from "thinking". They turned out to be
unnecessary: Claude Code maps its internal `requires_action` state to
`status: "waiting"` on disk and writes a `waitingFor` of "permission prompt" or
"input needed" next to it. The distinction is already there. Nothing gets written
to your `settings.json`.

## Credits

App icon: [Traffic light icons created by Gravisio — Flaticon](https://www.flaticon.com/free-icons/traffic-light).

## Requirements

- macOS 14+ (developed on 26.5)
- Swift 6 toolchain (developed on 6.3.3)
- Xcode **not** required — Command Line Tools is enough

## Install

Grab `Stoplight.zip` from the [latest release](https://github.com/justisGipson/stoplight/releases/latest),
unzip it, and move `Stoplight.app` to `/Applications`. Then:

```sh
xattr -dr com.apple.quarantine /Applications/Stoplight.app
```

That step is needed because the build is **ad-hoc signed, not notarized** — there
is no Apple Developer certificate behind it, so Gatekeeper refuses it until the
download quarantine is cleared. The app has no Dock icon; look for the stoplight in
the menu bar.

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

## Continuous integration

| Workflow | Trigger | What it does |
|---|---|---|
| `.github/workflows/test.yml` | push to `main`, pull requests | builds and runs the suite |
| `.github/workflows/release.yml` | a `v*` tag, or run by hand | tests, builds, packages, publishes |

The release workflow stamps the tag into `CFBundleShortVersionString` *before*
building — `build.sh` signs the bundle as its last step, so editing the plist
afterwards would invalidate that signature. It packages with `ditto` rather than
`zip`, which preserves the bundle's symlinks, permissions and extended attributes,
and publishes the zip plus a SHA-256 alongside it. Running it by hand (without a
tag) uploads a build artifact and publishes nothing.

Tag a release with:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

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
Resources/
  Info.plist                 bundle metadata; LSUIElement keeps it out of the Dock
  icon-source.png            512x512 source art
  Stoplight.icns             generated by ./make-icon.sh, committed so builds need no regeneration
```

The app icon only ever shows in Finder, Get Info and Spotlight — `LSUIElement` means
there is no Dock icon. The menu bar artwork is unrelated: it stays drawn in Core
Graphics, because it has to recolour itself for a light or dark menu bar and stay
crisp with ~5px lamps, neither of which a downscaled PNG can do.

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
- **`~/.claude/projects/<slug>/<sessionId>.jsonl`** — the transcript, read by a
  bounded reverse scan (400 lines) for the running tool, the live context size and
  the most recent API error. Everything needed lives near the tail, so a transcript
  running to tens of thousands of lines is never fully parsed. Cached against file
  size and mtime, so an unchanged transcript costs nothing.
- **`~/.claude/projects/<slug>/<sessionId>.jsonl`** — live transcript, for token
  counts and the current tool name. Parsed lazily, only while the panel is open.
- **`cost-state` lines in the transcript** — Claude Code's own cumulative rollup
  per session: `totalCostUSD`, per-model input/output/thinking/cache tokens,
  durations, lines added and removed. Rare (five in a thirteen-thousand-line
  transcript) but cumulative, so only the last one matters, and it sits near the
  end. A backwards byte search finds it without parsing any JSON on the way, which
  is what makes 107 MB of transcripts scannable in well under a second.
- **`~/.claude/stats-cache.json`** — Claude Code's own totals. Shown alongside, and
  always labelled with its `lastComputedDate`, because it is recomputed only
  occasionally and can lag by weeks.

Scope is the default `~/.claude` config dir only. Multi-account was considered and
dropped: a second account cannot be auto-discovered anyway, because mapping a
running PID to a non-default `CLAUDE_CONFIG_DIR` requires reading that process's
environment, and macOS does not allow it.

`~/.claude/sessions/` is an internal Claude Code implementation detail, not a
public API. It is read through a tolerant, fail-open decoder so a format change in
a future version degrades to "unknown" instead of crashing.

## The usage window

Reached from the menu, not from hover — hover stays a glance, this is a sit-down.

Headline figures are stat tiles rather than charts: a single number does not need
a plot. The rankings are single-series magnitude bars, one hue, rounded at the data
end and square at the baseline, with values in text ink rather than the bar's
colour. There is no categorical palette anywhere in it, so there is no hue cycling
and nothing for colour to misidentify — length carries the whole message.

Persistence is a JSON file in `~/Library/Application Support/Stoplight/`, not
SQLite. The design originally called for SQLite; the actual shape is one entry per
transcript, read whole and written whole, with no query beyond summing. SQLite
would have added a C API, a schema and migrations to buy indexing nothing needs.

## Clicking a session

Rows in the hover panel are clickable. What that can do depends entirely on the
terminal, and the ceiling is lower than it sounds.

**Raising the app always works**, needs no permission, and is what
`NSRunningApplication.activate()` does: make the app frontmost, raise its
frontmost window, give it keyboard focus. It has no notion of *which* window or
tab — so if one terminal window holds several sessions, you get that window
showing whichever tab was already active.

**Choosing between windows works** when the terminal has more than one, via the
Accessibility API. Matching is on Claude Code's generated topic title, because
that is what ends up in the title bar — the folder and the session name never
appear there. macOS asks for Accessibility consent the first time you click a row.

**Choosing a tab does not work in Ghostty, and cannot be made to.** Measured with
`./Stoplight.app/Contents/MacOS/Stoplight --diagnose`: Ghostty exposes one
`AXWindow` whose entire subtree is `AXGroup → AXGroup → AXStaticText`, and its
Window menu offers only "Show Previous Tab" / "Show Next Tab" — no per-tab items.
There is no addressable handle for a tab anywhere.

Other terminals are better equipped, not worse:

| Terminal | Tab targeting |
|---|---|
| iTerm2 | AppleScript, precise (needs Automation consent) |
| Terminal.app | AppleScript, precise (needs Automation consent) |
| kitty | `kitty @ focus-window` (needs `allow_remote_control`) |
| WezTerm | `wezterm cli activate-pane` |
| Ghostty, Alacritty | app and window only |

None of that is implemented yet — the current behaviour is app + window for every
terminal. `--diagnose` prints the accessibility tree and menus for whatever
terminals are running Claude, which is how to check a new one.

## Known constraints

**The lamps are small: about 5.6px on a 24pt menu bar, 4.9px on a 22pt one.**
Three lamps stacked vertically inside ~22px leaves no more room than that. The
layout is solved for the bar height rather than scaled down to it, so they at
least stay crisp. It is also why the hover panel carries a second, full-size
stoplight — the menu bar icon signals, the panel is what you actually read.

A horizontal arrangement would afford ~8.5px lamps, which is meaningfully more
legible but reads as three loose dots rather than a stoplight. That trade was made
deliberately in favour of the stoplight.

**Green and yellow are hard to tell apart with protanopia.** Measured, not
guessed: ΔE 4.7 between `#38c759` and `#fabc17` under a protan simulation, below
even the 6–8 floor. The hues stay, because a stoplight that is not red/yellow/green
is not a stoplight. What makes it readable anyway is the fixed-slot layout — all
three lamps always drawn, red always on top — so identity is carried by which
position is bright, not by hue. Every status readout in the app is labelled in text
for the same reason.

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
2. ✅ `SessionWatcher` on `~/.claude/sessions/` + liveness reaper → real green/yellow
3. ✅ Crash detection, blocked-on-you from `status: "waiting"`, and stalled API
   errors — all without hooks
4. ✅ Panel detail: running tool, context size, failure reason
5. ✅ Usage window: lifetime cost and tokens from `cost-state` rollups, ranked by
   project and model, cached against file size and mtime
