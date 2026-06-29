# GONE Player — Agent Context

> Onboarding primer for any agent picking up work on GONE. Read this first.
> Authoritative deep reference: `CLAUDE.md` in repo root (exhaustive invariants + resolved-PR list).
> This file = the essentials: what the app is, the held changes to deal with first, and what you must not break.

---

## 0. Status snapshot

- **Branch model:** single branch `main` is the source of truth (consolidated 2026-06-29; old `dev` retired, dead `loop/*` + `parker/*` branches removed). `origin` has only `main`.
- **HEAD:** `13fc6fc` · local == origin, in sync. Working tree clean.
- **Release tag:** `beta-1.1` @ `3752ae2`. Shipping version: Beta 1.1, build 15.
- **CI:** only `pr-review.yml` + `premerge-check.yml` remain (23 dead agentic audit workflows were removed). `.github/scripts/claude_review.py` is used by `pr-review` — keep it.
- **Version aligned:** `project.pbxproj` `MARKETING_VERSION = 1.1` / `CURRENT_PROJECT_VERSION = 15`, matching UI + DMG (commit `267ba7f`).
- **Recently landed** (clean `xcodebuild` compile, runtime still worth an eyeball — see section 2): audio channel-layout pin `520e8cc`, window scaled-frame `13fc6fc`, `print`→`os.Logger` `775a336`. Each is its own commit so any one reverts cleanly.

### Workflow (non-negotiable)
- Edits go into the **source files only**. Robert runs and tests through **Xcode → Run**. You do not build/ship.
- DMG packaging / copying to `/Applications` — **only on Robert's explicit command** (`package_beta10.sh`).
- Commit to `main` → `git push origin main`. No other branches unless asked.
- SourceKit "Cannot find type X in scope" is a **false positive** from `PBXFileSystemSynchronizedRootGroup`. Fix = Clean Build Folder (Shift+Cmd+K), never edit code to "satisfy" it.

---

## 1. What GONE is (and why it exists)

**The Swiss Army knife for DJs preparing a set.** A compact macOS companion that lives next to Finder and replaces nothing, but makes the 30 minutes before a set fast and deliberate.

**One sentence:** Not a professional DJ platform — a focused pre-session tool. Drop a folder, sort by BPM, preview tracks with real effects + EQ, compare two tracks side by side, mark what fits, then open Rekordbox/Serato when you're sure.

**Target user:** a DJ who keeps music in folders, working on a MacBook (incl. older 2010–2015 models, macOS 13+). No database, no sync, no beat grid. Just fast, informed decisions.

**Core value — the full toolkit in one window:**
- Drop folder → instant BPM detection, sorted list
- Pitch/tempo preview: ±8% fine, ±16% wide, ±100% varispeed (Master Tempo)
- 4-band EQ + HPF/LPF for honest auditioning
- XY pad, 13 effect axes (Lo-Fi, Dub Delay, Gate/Slicer, Reverb, filter sweeps)
- Hot cues (4 per player), Split Mode (two players + visual crossfader for A/B)
- Snap-to-edge: window gets out of the way when not needed

### Scope guard — do NOT add or suggest
Beat-grid editing or BPM sync between players · MIDI · library database / persistent tagging · export/sharing/streaming · playlist export to Rekordbox/Spotify/Apple Music · anything that turns this into a controller-replacement.

**Rule of thumb:** if the feature belongs inside Rekordbox or Serato, it does not belong here. This is for the 30 minutes *before* you open those. Ask before adding.

---

## 2. Recently landed changes — runtime-verify in normal use

Landed 2026-06-29 (`520e8cc`, `13fc6fc`, `775a336`) after a clean `xcodebuild` Debug compile. The runtime edge cases below were not interactively driven, so keep an eye on them in normal use. Each change is an isolated commit, so any single one reverts cleanly.

### Fix 1 — `GONE/GONE/AudioEngine.next.swift` (channel-layout pin)

Fixes a `scheduleBuffer` crash when the output device reports a mono / mismatched channel layout.

```swift
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            currentURL = url
            // Pin the player node's output bus to THIS file's channel layout before scheduling.
            // The graph is wired with `format: nil`, so the player's output format otherwise
            // follows whatever the current hardware/virtual output device presents. When that
            // device reports a mono (or otherwise mismatched) layout, scheduleBuffer aborts with
            // 'required condition is false: _outputFormat.channelCount == buffer.format.channelCount'.
            // Reconnecting here guarantees the scheduled PCM buffers always match the node.
            // playerNode is stopped (stop() above), so reconnecting is safe; node ORDER is unchanged.
            engine.connect(playerNode, to: speedNode, format: file.processingFormat)
            scheduledStartFrame = 0
```

Why it's safe: only reconnects `playerNode → speedNode` (the first edge), node **order is unchanged**, and `playerNode` is already stopped. Test focus: playback on mono/odd output devices (USB interfaces, aggregate devices), and that normal stereo playback is unaffected.

### Fix 2 — `GONE/RootView.swift` (scaled layout frame)

Fixes the window never shrinking below 100% when `windowScale` < 1.

```swift
        .scaleEffect(state.windowScale)
        // scaleEffect is render-only — it does NOT change the SwiftUI layout size. The content
        // frame above stays at the UNSCALED shellSize, so NSHostingView kept reporting 472pt as
        // its ideal size and pinned the panel to it; updateWindowSize's scaled target lost the
        // fight and the window never shrank below 100%. Pinning the layout footprint to the
        // scaled size makes the hosting ideal == updateWindowSize target. At 100% this is a
        // no-op (scaledShellSize == shellSize), so existing behaviour is unchanged.
        .frame(width: scaledShellSize.width, height: scaledShellSize.height, alignment: .top)
        .background(Color.clear)
```

Why it's safe: at 100% scale `scaledShellSize == shellSize`, so it's a no-op for existing behaviour. Test focus: scale slider in Settings below 100%, window actually shrinks; magnify/hover-zoom still behaves; snap docking still lines up.

### #5 — `GONE/GONE/AudioEngine.next.swift` (logging, `775a336`)

Three error-path `print` calls became `audioEngineLog.error(...)` (`Logger`, category `AudioEngine`, `.public`). The `onError?(msg)` callback is untouched. No behavioural change; pure logging hygiene.

> Rejected from the same review pass (do not re-propose): swapping `playbackToken`'s lock, blocking-lock on the FFT path, caching `AVAudioFile` across the prefetch queue, gating FFT on `onSpectrum == nil`, speculative format validation in `load()`. Reasons live in the session history — three of these undo verified/deliberate designs (the file-per-chunk cursor is the fix for a real playback race).

---

## 3. What you must NOT break (architectural invariants)

These are load-bearing. Breaking any of them causes crashes, hangs, or UI-wide re-render storms. Full rationale per item is in `CLAUDE.md`.

### Audio
- **Audio graph order is fixed** — never reorder or remove nodes:
  `playerNode → speedNode → pitchNode → hpfNode → lpfNode → eqNode → distortionNode → delayNode → reverbNode → gateNode → mainMixerNode`
  (`distortionNode` = Lo-Fi, `delayNode` = Simple/Dub Delay, `gateNode` = Slicer — all intentional.)
- **Two engine instances only:** `AudioEngineNext.shared` (primary) + `AudioEngineNext.secondary` (clone). `init()` is `private` to enforce this. `AudioEngineNext.deinit` never runs (static lifetime) — its cleanup code is defensive dead code, don't touch.
- **Dependency injection:** inside `PlayerState` extensions and Views, always call `state.audioEngine` / `self.audioEngine` — **never** `AudioEngineNext.shared` directly.
- Spectrum normalizes to a **0..0.24** ceiling, not 0..1. `processSpectrum` takes sampleRate from the tap buffer, not hardcoded 44100.

### State / feeds (these exist to stop whole-tree re-renders)
- `progress` / `currentTime` are **not** `@Published` on `PlayerState` — they live on per-player `state.progressFeed` (a `PlaybackProgressFeed`). Reset via `state.progressFeed.reset()`, never `PlaybackProgressFeed.shared.reset()` from extension code.
- Spectrum lives on `SpectrumFeed.shared` (singleton), not `@Published` on PlayerState.
- Snap countdown lives on `state.snapTimerFeed` (isolated). **Never** re-add a `@Published` countdown to PlayerState — it rewrites at mouse-move rate and re-renders everything.
- `XYPadState` (`state.xyPad`) is isolated, 60Hz writes must not touch `PlayerState.objectWillChange`.

### Window / panel
- Primary player is a real **`FloatingPlayerPanel` (NSPanel)** created in `applicationDidFinishLaunching` (variant D bootstrap). The only SwiftUI scene is `Settings { EmptyView() }`. **Do not** reintroduce a `WindowGroup` for the player (a patched NSWindow can't overlay other apps' fullscreen Spaces; a real panel can). No alpha tricks at launch.
- Always-on-top is **unconditional** (level toggle was removed). "Invisible mode" is the sanctioned way to make the player unobtrusive — do not re-add a level toggle.
- `isMovableByWindowBackground = false` — **never** set true (breaks vertical drag controls).
- `updateWindowSize` is called **only** from `RootView.onChange` — do not duplicate.
- `windowResizability(.automatic)` — do not change.
- `.fullScreenAuxiliary` is part of every presence-policy path — keep it.

### Snap state machine (`WindowSnapManager.swift`) — most delicate subsystem
- Do not modify the dock/expand sequence without reading the whole file.
- Off-screen slide is **Timer-based**, never `NSAnimationContext` (breaks off-screen destinations).
- Don't set `snapState = .docked` before the animation completes; don't call `lockFrame()` before `slideOffScreen` completion; don't remove the `isSnapping` guard in `updateWindowSize`.

### Concurrency
- Project is built with `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`. **Any new worker/DSP class must be marked `nonisolated`** or it silently runs on main and freezes the UI (this exact bug cost 2.1s UI hangs in `LibraryScanner` until fixed).
- All timers: `RunLoop.main.add(timer, forMode: .common)` (not `.default`). Timer callbacks wrap work in `MainActor.assumeIsolated`.

### XY FX
- `applyXYEffect` (in `RootView.swift`) must **not** write to `@Published` state (prevents a re-render loop). On axis change / deactivate: `stopSlicer()` + `resetFXNodes()`.

### Xcode project
- Files auto-discovered via `PBXFileSystemSynchronizedRootGroup` — do **not** add files to `.pbxproj` manually.

---

## 4. Feature → file (where to look)

| Area | File(s) |
|---|---|
| Audio graph, playback, pitch/speed, prefetch | `GONE/AudioEngine.next.swift` ⚠️ nested in `GONE/GONE/` |
| Player state, XY/LFO/Slicer timers, magnify | `PlayerState.swift` |
| Load / prev / next / hot-cue reset | `PlayerState+Playback.swift` |
| BPM + waveform analysis, task cancellation | `PlayerState+Analysis.swift` + `LibraryScanner.swift` |
| Playlist, tabs, import, sort | `PlayerState+Playlists.swift` + `PlaylistView.swift` |
| EQ presets, reverb | `PlayerState+EQ.swift` |
| Snap-to-edge state machine | `WindowSnapManager.swift` |
| Split Mode (two players) | `SplitModeManager.swift` |
| Crossfader between windows | `CrossfaderBandPanel.swift` |
| Waveform + hot-cue ticks + seek | `WaveformView.swift` |
| Spectrum | `SpectrumView.swift` + `SpectrumFeed.swift` |
| Per-player progress feed | `PlaybackProgressFeed.swift` |
| Transport, volume, repeat, hold-seek | `TransportView.swift` |
| XY pad (13 axes) + EQ faders | `EQPanelView.swift` (+ `XYPadState.swift`) |
| Window entry, key monitor, hot cues, magnify | `GONEApp.swift` |
| Shell, XY wiring, top-anchor, scale frame | `RootView.swift` |
| Design tokens (`G.*`) | `DesignTokens.swift` |

---

## 5. Conventions

- Fonts: `G.mono()` for data/numbers, `G.sans()` for labels. Colors: always `G.*` tokens, never raw hex in views.
- Async: `Task.detached` for analysis, `@MainActor` for all UI mutation.
- **No external dependencies** — 100% Apple-native frameworks.
- Before flagging anything as a bug, check the "PR Review — Already Resolved" section in `CLAUDE.md` — a long list of intentional decisions and confirmed false positives is documented there to save review budget.
