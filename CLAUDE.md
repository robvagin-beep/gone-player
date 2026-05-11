# GONE Player — Context & Rules

## What This App Is

**The Swiss Army knife for DJs preparing a set** — a macOS companion that lives next to Finder and replaces nothing, but makes the 30 minutes before a set fast and deliberate.

**Positioning in one sentence:** Not a professional DJ platform, but a focused pre-session tool: drop a folder, sort by BPM, preview tracks with real effects, decide what fits — then open your DAW or controller.

**Target user:** A DJ who has music in folders. Working on a MacBook at home or at a side job. Before a set they open their folders, scan BPMs, audition candidates at the right tempo and EQ, compare two tracks in Split Mode, mark the ones that work. No database. No sync. No beat grid. Just fast, informed decisions — without touching Rekordbox until they're sure.

**Core value — the full toolkit in one window:**
- Drop a folder → instant BPM detection, sorted list
- Pitch/tempo preview: ±8% fine, ±16% wide, ±100% full varispeed
- 4-band EQ + HPF/LPF for honest auditioning (hear how it sounds in the mix)
- XY pad with 13 effect axes: Lo-Fi, Dub Delay, Gate/Slicer, Reverb, Filter sweeps
- Hot cues (4 per player) for marking phrases on the fly
- Split Mode: two independent players + visual crossfader for A/B comparison
- Snap-to-edge: the window gets out of the way when you don't need it
- macOS 13+ — runs on older MacBooks (this is a feature, not a limitation)

## What This App Is NOT

Do not add or suggest:
- Beat-grid editing or BPM sync between players
- MIDI control of any kind
- Library database / persistent tagging (no metadata beyond session ratings)
- Export, sharing, or streaming integrations
- Playlist export to Rekordbox, Spotify, Apple Music, or anything else
- Anything that positions this as a replacement for a controller setup

**Rule of thumb:** If the feature would make sense inside Rekordbox or Serato, it does not belong here. This tool is for the 30 minutes *before* you open those. Ask before adding.

---

## Architecture — Critical Rules

### 1. Audio Graph (`GONE/AudioEngine.next.swift`)

Chain is **fixed**. Never reorder or remove nodes:

```
playerNode → speedNode → pitchNode → hpfNode → lpfNode → eqNode → distortionNode → delayNode → reverbNode → gateNode → mainMixerNode
```

- `distortionNode` = Lo-Fi effect (AVAudioUnitDistortion, preset `.multiDecimated2`) — intentionally in graph
- `delayNode` = Simple/Dub Delay (AVAudioUnitDelay) — intentionally in graph
- `gateNode` = Slicer/Gate (AVAudioMixerNode) — BPM-sync volume chopping
- Spectrum values normalize to **0..0.24** ceiling (not 0..1) — all visual components normalize against this value
- `processSpectrum(samples:sampleRate:)` — sampleRate comes from the tap buffer, NOT hardcoded 44100

### 2. Per-Player Engine Architecture (Dependency Injection)

There are TWO audio engine instances:
- `AudioEngineNext.shared` — primary player engine
- `AudioEngineNext.secondary` — clone player engine (created when Split Mode activates)

**PlayerState.swift** stores `let audioEngine: AudioEngineNext` — all audio calls go through `self.audioEngine`, NOT `AudioEngineNext.shared` directly. This is the DI pattern.

**NEVER** call `AudioEngineNext.shared` directly inside PlayerState extensions or View files. Always use `state.audioEngine` or `self.audioEngine`.

### 3. PlaybackProgressFeed — Isolated Observable

`progress` and `currentTime` are NOT `@Published` on `PlayerState`. They live on `PlaybackProgressFeed`:

- Each `PlayerState` has its own `let progressFeed = PlaybackProgressFeed()` (not singleton)
- `PlaybackProgressFeed.shared` exists only for legacy PeekPanel
- Views subscribe to `state.progressFeed` via `.onReceive`, not to `PlayerState` directly
- Reset on navigation: always call `state.progressFeed.reset()` — NOT `PlaybackProgressFeed.shared.reset()` from extension code

This is critical for Split Mode: each player's waveform and time display must read from its own feed.

### 4. SpectrumFeed — Isolated Observable

`@Published var spectrumData` was removed from `PlayerState`. It lives in `SpectrumFeed.shared` (singleton).

- `AppDelegate.bindAudioEngine`: `engine.onSpectrum → SpectrumFeed.shared.data`
- `SpectrumView` and `PixelSpectrumView` use `@ObservedObject private var feed = SpectrumFeed.shared`

### 5. SplitModeManager (`SplitModeManager.swift`)

Manages the second player window and crossfader panel:

- `SplitModeManager.shared` is `@MainActor ObservableObject`
- `private(set) var secondaryState: PlayerState?` — access from GONEApp for hot cues
- On `activate()`: creates `PlayerState(engine: .secondary)`, copies tracks from primary, opens second window
- On `deactivate()`: `Task.detached { AudioEngineNext.secondary.stop() }` — off main thread (avoids hang)
- Output device sync: when secondary engine starts, it must match primary's output device:
  ```swift
  let primaryDeviceID = AudioEngineNext.shared.currentOutputDeviceID()
  AudioEngineNext.secondary.setOutputDevice(primaryDeviceID)
  ```
- Crossfader gain: equal-power law `cos(t * π/2)` for primary, `cos((1-t) * π/2)` for secondary

### 6. CrossfaderBandPanel (`CrossfaderBandPanel.swift`)

`NSPanel` that floats between two player windows:

- Hit-test only within 60px radius of the A-B line segment (`BandHitTestView.hitTest`)
- `geometryVersion: Int` on `SplitModeManager` — increment to trigger Canvas redraw (do NOT replace `hc?.rootView` on every resize, that causes unnecessary SwiftUI allocation)
- Canvas reads `panel.frameA/B` directly for geometry

### 7. Snap Edge System (`WindowSnapManager.swift`)

The most delicate subsystem. Do NOT modify without reading the full state machine.

**Dock sequence:**
1. `isSnapping = true`
2. `slideOffScreen()` starts (Timer-based, NOT NSAnimationContext — NSAnimationContext breaks off-screen destinations)
3. After ~80ms: `prepareForSnap()` → panels collapse (`isSnapping` guards `updateWindowSize` height shift)
4. In `slideOffScreen` completion: `snapState = .docked` → `lockFrame()` → `isSnapping = false`

**Expand sequence:**
1. `unlockFrame()`
2. `snapState = .expanded`, `isSnapping = true`
3. `restoreFromSnap()` immediately → panels open as window slides out
4. `animateFrameTo(savedFrame)` runs simultaneously
5. In completion: `isSnapping = false`

**Never:**
- Use `NSAnimationContext` for off-screen animation (breaks)
- Set `snapState = .docked` before animation completes
- Call `lockFrame()` before `slideOffScreen` completion
- Remove `isSnapping` guard in `updateWindowSize`

### 8. Window Architecture (`GONEApp.swift`)

- `windowResizability` = `.automatic` — NEVER change (`.contentSize` breaks snap)
- `isMovableByWindowBackground = false` — NEVER set to true (breaks vertical drag controls)
- `updateWindowSize` called only from `RootView.onChange` — do NOT duplicate
- All timers: `RunLoop.main.add(timer, forMode: .common)` — not `.default`
- Timer callbacks: `MainActor.assumeIsolated` inside

### 9. Hot Cues (`GONEApp.swift` + `PlayerState.swift`)

- Primary player: keys 1–4 (keyCodes 18/19/20/21)
- Secondary player: keys 5–8 (keyCodes 23/22/26/28) — only when SplitMode active
- `PlayerState.hotCues: [Double?] = [nil, nil, nil, nil]` — session only, not persisted
- Reset in both `load()` and `playTrack()`

### 10. Keyboard Navigation (`GONEApp.swift` + `PlaylistView.swift`)

- `GONEApp.installKeyMonitor`: when `state.playlistOpen`, arrow keys return `event` (pass through to SwiftUI), NOT nil (no autoplay)
- `PlaylistView.PlaylistTracksPane`: handles ↓/↑/Enter locally with `@State focusScrollTarget`
- ↓/↑ move `selectedIds` + `selectionAnchorId` + `focusScrollTarget` — no playback
- Enter plays only if `selectedIds.count == 1`

### 11. XY FX System (`EQPanelView.swift` + `PlayerState.swift` + `RootView.swift`)

13 axes total. `applyXYEffect` in `RootView.swift` handles all of them.

Key rules:
- `applyXYEffect` does NOT write to `@Published` state (prevents SwiftUI re-render loop)
- On axis change: `stopSlicer()` + `resetFXNodes()` before starting new effect
- On `xyActive` deactivate: `stopSlicer()` + `resetFXNodes()`
- Slicer is Timer-based (60fps), driven by `state.bpm`; runs in `startSlicer()`, stopped in `stopSlicer()`
- LFO writes to `state.lpfCutoff` so EQ curve animates during sweep

### 12. AppKit / SwiftUI Bridge

- Window access: `AppDelegate.resolvedMainWindow()` or `WindowSnapManager.shared.currentWindow`
- NEVER use `NSApp.windows.first` directly
- Clone player uses `FullPlayerView()` (not `RootView`) to avoid triggering `updateWindowSize` on primary window
- TransportView hides settings gear in clone window: `if state.audioEngine !== AudioEngineNext.secondary`

### 13. Xcode Project

- File sync: `PBXFileSystemSynchronizedRootGroup` — Xcode auto-discovers files in folder
- Do NOT add files to `.pbxproj` manually
- SourceKit "Cannot find type X in scope" = false positives — fix: Clean Build Folder (Shift+Cmd+K)

---

## What You Can Safely Change

- Colors, spacing, font sizes, corner radii in `DesignTokens.swift`
- Text labels, SF Symbol names in any view
- Animation timing values in existing animation blocks
- EQ presets in `PlayerState+EQ.swift`
- New computed properties in PlayerState extensions
- Context menu items in `PlaylistRowView`
- Padding / layout inside existing SwiftUI views
- `ArtworkCache` cache policy (expiry, size)
- BPM range resolution in `LibraryScanner.analyzeBPM`

## What You Must NOT Change

- `WindowSnapManager.swift` state machine sequence
- `updateWindowSize` logic in `RootView.swift`
- Audio graph node order in `AudioEngine.next.swift`
- `isMovableByWindowBackground` setting (must stay `false`)
- `windowResizability(.automatic)` in `GONEApp.swift`
- `RunLoop.main.add(timer, forMode: .common)` patterns
- Direct calls to `AudioEngineNext.shared` from inside PlayerState extensions or Views (use `self.audioEngine` / `state.audioEngine`)
- `PlaybackProgressFeed.shared.reset()` from extension code — use `self.progressFeed.reset()`

---

## Conventions

```
Design tokens    → DesignTokens.swift  (G.* prefix)
State            → PlayerState + extensions in PlayerState+*.swift
Audio            → state.audioEngine (injected, NOT AudioEngineNext.shared directly)
Window snap      → WindowSnapManager.shared (singleton)
Spectrum feed    → SpectrumFeed.shared (singleton)
Progress feed    → state.progressFeed (per-player instance)
Split mode       → SplitModeManager.shared (singleton)
UI               → SwiftUI views, AppKit only where SwiftUI falls short
```

**No external dependencies** — 100% Apple native frameworks only.

**Fonts:** `G.mono()` for data/numbers, `G.sans()` for labels and text.

**Colors:** always use `G.*` tokens, never raw hex in views.

**Async:** `Task.detached` for analysis, `@MainActor` for all UI mutations.

---

## File Map

```
GONE/GONE/
  GONEApp.swift                — app entry, AppDelegate, key monitor, hot cues, magnify
  PlayerState.swift            — single source of truth; XY/LFO/Slicer timers; magnify state
  PlayerState+Playback.swift   — load/play/prev/next/delete; hot cue reset
  PlayerState+Analysis.swift   — BPM (concurrency=2) + waveform async
  PlayerState+Playlists.swift  — tabs, import (batch 4), sort, auto-sort on drag
  PlayerState+EQ.swift         — EQ presets, reverb cycling
  GONE/AudioEngine.next.swift  — AVAudioEngine graph (double-folder, legacy path)
  PlaybackProgressFeed.swift   — per-player progress/currentTime ObservableObject
  SpectrumFeed.swift           — singleton spectrum ObservableObject
  SplitModeManager.swift       — two-player Split Mode + crossfader coordination
  CrossfaderBandPanel.swift    — NSPanel crossfader UI + BandHitTestView + Canvas
  SettingsPanel.swift          — settings overlay (scale, magnify, snap delay)
  LibraryScanner.swift         — metadata + waveform + BPM decode
  ArtworkCache.swift           — NSCache(300) + disk 256px JPEG
  Track.swift                  — Track struct + BPMAnalysisState enum
  DesignTokens.swift           — G.* design constants
  RootView.swift               — shell, XY wiring, onChange, top-anchor, drag overlay
  FullPlayerView.swift         — player layout, panel accordion (used by clone window)
  TrackHeaderView.swift        — artwork, title, badges, spectrum
  WaveformView.swift           — waveform Canvas + seek + hot cue ticks
  SpectrumView.swift           — bars/osc spectrum
  TransportView.swift          — transport, volume, snap/pin, repeat badge
  PitchFaderView.swift         — vertical pitch slider + MT button
  EQPanelView.swift            — EQ faders, HPF/LPF, XY pad (13 axes), FX
  PlaylistView.swift           — playlist panel, tabs, rows, keyboard nav, cascade
  PeekPanelView.swift          — snap edge HUD: mini transport + spectrum
  WindowSnapManager.swift      — snap state machine
```

---

## Known Tech Debt (do NOT touch without instruction)

- `Task.detached` for BPM/waveform have no stored cancellation handles — tech debt, not a bug
- `Task.sleep(nanoseconds:)` deprecated — replace with `Task.sleep(for: .milliseconds(N))` on next pass
- Dual SnapState enums: `WindowSnapManager.SnapState` and `PlayerState.SnapMode` are functionally identical — consolidate when touching snap system
- `presentImportPanel` uses `NSApp.keyWindow` — should use `AppDelegate.resolvedMainWindow()` (low risk)
- `splitPlaylistView` / `secondaryPlaylistTabId` in PlayerState — orphan state, no UI yet (was after artworkData note)
- `splitPlaylistView` / `secondaryPlaylistTabId` in PlayerState — orphan state, no UI yet

---

## PR Review — Already Resolved (do NOT flag again)

These items have been explicitly fixed or are intentional design decisions. Flagging them wastes review budget.

### Threading / Timers
- `playbackToken` / `bumpToken()`: **DO NOT FLAG. Pattern is fully verified.** `schedulePCMChunk(url:format:startFrame:chunkFrames:totalFrames:token:)` accepts `token: UInt64` as a value-type parameter. Inside the function body and all nested `playerNode.scheduleBuffer` completion closures, ONLY this local `token` parameter is referenced (never `self._playbackToken` or `self.playbackToken`). Guard checks use `guard token == playbackToken` — `token` is the immutable local, `playbackToken` is the current-value lock read. There is zero TOCTOU risk because the local `token` cannot change; the right-hand `playbackToken` read may change (that's the point — it detects cancellation). `bumpToken()` callers use its returned value to verify scheduling should proceed; no caller reads `self.playbackToken` before AND after `bumpToken()` expecting them to match.
- `progressTimer` capture: `let t = progressTimer; progressTimer = nil` before dispatch — intentional deadlock prevention (async, not sync)
- `stopHoldSeek()` off-main: has identical main-thread dispatch guard as `progressTimer`
- `holdSeekTimer` in `deinit`: captured and dispatched to main in deinit, same pattern as progressTimer
- `DispatchQueue.main.async` (not sync) for timer invalidation: intentional — `stop()` called from `Task.detached` in Split Mode deactivate; sync would deadlock
- `MainActor.assumeIsolated` in RunLoop.main timer callbacks: correct pattern per project rules
- `bumpToken()` discarded in `stop()`: intentional — `stop()` does not schedule buffers, only needs to invalidate in-flight ones

### Audio Engine
- `AudioEngineNext.init()` is `private` — enforces 2-instance invariant (`shared` + `secondary`). Declared at line 106 of `AudioEngine.next.swift`. Diff truncation may hide it, but the restriction is real and verified.
- `AudioEngineNext.secondary` eager init: pre-existing architecture — out of scope
- `currentURL`/`audioFile` thread safety: pre-existing architecture concern — out of scope
- `stopHoldSeek()` → `applyPitchState()`: correctly restores `pitchNode.bypass`, `speedNode.rate`, and pitch state on hold-seek end
- `SplitModeManager.deactivate()` calls `AudioEngineNext.secondary.markStopped()` (NOT pause()) on main before `stop()` off-main. `pause()` was replaced because it called `playerNode.pause()` which contests Core Audio IO lock with concurrent `setOutputDevice()` on audioOpQueue → deadlock. `markStopped()` only sets `isUserPlaying=false` + invalidates timer without touching the player node.
- `SplitModeManager.activate()` copies `primaryState.volume` to `secondaryState` on line ~126 ✓

### Crossfader / Clone
- `CrossfaderBridgeView` `@ObservedObject var manager`: correctly declared, Canvas redraws on `crossfade` change ✓
- `CrossfaderGapWindow` double-close observer cleanup: idempotent by design — both `close()` and `deinit` remove observers safely
- `ClonePlayerShell.resizeWindow` vs snap: clone window is never snap-managed — no conflict possible
- `ClonePlayerShell.resizeWindow` screen bounds: clamps both bottom (`>= vis.minY`) AND top (`<= vis.maxY - height`)
- `ClonePlayerShell.WindowRefCapture` initial nil race: fixed — capture callback calls `resizeWindow(to: shellSize, window: w)` directly with the freshly received window, reconciling any frame mismatch before `myWindow` state propagates ✓
- `ClonePlayerShell` playlist height bounds `max(160, min(700, newH))`: `// MIRROR: RootView.swift` comment added; intentional duplication, no shared helper ✓
- `ScrollWheelNSView` momentum: `guard event.momentumPhase == .stationary` blocks trackpad inertia ✓. Regular mouse wheel and Magic Mouse wheel events arrive with `momentumPhase = .stationary` and ARE captured. The guard only drops trackpad inertia (post-lift coasting) — active scroll phases are correctly handled.
- `ScrollWheelNSView hasPreciseScrollingDeltas` mouse scaling: trackpad gives pixel-scale continuous deltas (large); mouse wheel gives ~1.0 per notch. Non-precise (mouse) events are boosted by `mouseDetentScale = 10.0` so ~30 notches spans full crossfader range. Intentional direction. Named constant ✓
- `EmptyOverlayView` in clone: gated with `state.audioEngine !== AudioEngineNext.secondary`
- `BandHitTestView.hitTest` pass-through: root content view returning `nil` causes AppKit to route event to window below ✓
- `BandHitTestView.hitRadius`: `let`, value 60px — matches spec
- `BandHitTestView` segment guard: uses `distance² > 16` (not exact equality) to handle pre-geometry and coincident-window states
- `CrossfaderGapWindow` degenerate overlap: when windows are co-located, panel shrinks to 120×120; `CrossfaderBridgeView` Canvas has `guard len > 4 else { return }` → draws nothing, panel is invisible and non-interactive. Not a bug.

### SwiftUI / Views
- `EmptyOverlayView.startTypewriter`: `animTask?.cancel()` called at top of method before creating new task ✓
- `EQCurveView.animateTo` Task churn: pre-existing, acknowledged tech debt — out of scope
- `Task.sleep(nanoseconds:)` deprecation: acknowledged tech debt in CLAUDE.md — out of scope for this PR
- `ArtworkCache.writeToDisk`: runs on `.utility` background queue, uses `.atomic` write option ✓
- `ArtworkCache.store` double-write race: two concurrent calls for same UUID may both pass the `fileExists` guard and both dispatch writes. `.atomic` makes the result safe; redundant work is acceptable for a cache.
- `ArtworkCache.image(for:)` synchronous disk read: caller (`TrackHeaderView`) already dispatches to `DispatchQueue.global(qos: .userInitiated)` before calling. Not called from view body directly — no main-thread hitch. `dispatchPrecondition(condition: .notOnQueue(.main))` added as debug guard ✓
- `FullPlayerView` `transaction { animation = nil }`: disables animations on the base ZStack intentionally — opacity/height changes on track load must not animate to avoid visual glitches during drop.
- `AudioEngineNext.deinit` tap/FFT ordering AND thread safety: `AudioEngineNext.shared` and `AudioEngineNext.secondary` are static stored properties with application lifetime — Swift statics are never released before process exit, so `deinit` NEVER runs in practice. All `deinit` code (timer capture, `removeTap`, `vDSP_destroy_fftsetup`) is defensive dead code for compiler completeness. Do NOT flag anything in `AudioEngineNext.deinit`.
- `ClonePlayerShell.resizeWindow` animation: uses `setFrame(animate: true)` — smooth resize matching primary window feel ✓
- `ClonePlayerShell.contentSize` logic duplication: intentionally mirrors `RootView.playerContentSize` — clone and primary windows have different resize drivers; a shared helper would couple unrelated subsystems.
- `EmptyOverlayView.startTypewriter` `Task.sleep(nanoseconds:)`: project-wide tech debt, acknowledged in CLAUDE.md — out of scope for this PR. Timing literals extracted to named constants (`charDelayNs`, `holdDelayNs`, `eraseDelayNs`, `gapDelayNs`) ✓
- `ArtworkCache.prune` frequency: runs once at launch; 30-day expiry on 256px JPEGs. Growth is negligible — periodic pruning is out of scope.
- `BandHitTestView.hitRadius` vs plaque dimensions: 60px is intentionally generous for usability; not coupled to visual plaque size by design. `pad = 60` in `CrossfaderGapWindow` serves a different purpose (bounding box expansion) and is coincidentally the same value. Code comment added to `CrossfaderGapWindow` explaining the distinction ✓
- `CrossfaderBridgeView` edge threshold `> 10`: 4 occurrences across Canvas and drag gesture — intentionally co-located, named constant would be premature abstraction for a single-file component. DO NOT FLAG.
- `CrossfaderBridgeView` `t_edgeA`/`t_edgeB` duplication between Canvas and DragGesture: both closures compute the same active-range geometry. This is intentional — Canvas and gesture handler are independent SwiftUI callbacks that each run in different contexts; a shared helper would require a method on the view. Out of scope. DO NOT FLAG.
- `BandHitTestView.distanceToSegment` distance² vs distance units: `dx*dx+dy*dy > 16` is the guard for segment length (4² = 16pt², distance). `distanceToSegment` returns Euclidean distance, compared against `hitRadius` (also distance). No unit mismatch. Named constant `4*4` vs `16` is cosmetic. DO NOT FLAG.
- `EmptyOverlayView.startTypewriter` displayText mutation before cancel check: cosmetic — view disappears on track load. DO NOT FLAG.
- `EmptyOverlayView.messages` localization: app is not localized, these strings are intentional product copy. DO NOT FLAG.
- `FullPlayerView.contentHeight` / `ClonePlayerShell.contentSize` static helper: intentional duplication, `MIRROR` comment adequate. DO NOT FLAG.
- `EQCurveView.animateTo` step/duration constants: acknowledged tech debt. DO NOT FLAG.
- `CrossfaderBridgeView` Canvas magic numbers (`barHW`, `ext`, `tHL`, `tHW`, `cornerR`): geometry constants local to the Canvas closure — no duplication elsewhere. DO NOT FLAG.
- `CrossfaderGapWindow` `pad = 60` vs `BandHitTestView.hitRadius = 60`: two different purposes, coincidentally same value. Code comment added explaining this. Renaming to `boundingBoxPad`/`clickHitRadius` is unnecessary verbosity. DO NOT FLAG.
- `AudioEngineNext.tokenLock` vs `OSAllocatedUnfairLock`: `NSLock` is correct and clear; lock is NOT on the hot render path (it guards scheduling, not buffer decode). Not a performance concern.
- `CrossfaderGapWindow` observer reference cycle: `windowA`/`windowB` are `weak`; if both go nil before `close()`, observers release naturally when panel deinits. `if !observers.isEmpty` guard in `close()` makes repeated-close idempotent. Correct by design.
- `ClonePlayerShell.resizeWindow` coalesced animation: SwiftUI coalesces `onChange` deliveries per run loop tick, so multiple panel-state changes in one tick produce one `setFrame(animate:)` call. If a second call arrives during the ~80ms animation, AppKit interrupts and restarts from current position — this is acceptable behavior (slight visual stutter, not a jump to wrong position). For a casual DJ app, this is not a problem. Do NOT flag.
- `EmptyOverlayView` arrow animation: `withAnimation(.repeatForever)` in `onAppear` is managed by SwiftUI's animation system; view leaving hierarchy cancels it automatically. `onDisappear` explicit cancel not required.
- `ArtworkCache.prune` vs `image(for:)` race: `FileManager` operations are individually thread-safe. Pruning during first image read is benign — worst case a just-pruned file is missed and the original `artworkData` fallback is used.
- `claude_review.py` diff truncation: now snaps to last newline before limit via `rfind("\n")` ✓

### CI / Tooling
- `model="claude-opus-4-7"` in `claude_review.py`: this model ID is valid and the workflow runs successfully — do not flag as invalid
- `urllib` timeout: `urlopen(req, timeout=30)` added ✓

### Deep Audit — Confirmed False Positives (2026-05-11)
- `spectrumQueue` serial-queue manages `spectrumSmooth`/`lastSpectrumEmit` — serial queue makes writes safe; cross-thread reset hop is a robustness preference, not a crash path. Do NOT flag as data race.
- `AudioEngineNext.deinit` observer/timer cleanup — static lifetime; deinit NEVER runs. Do NOT flag.
- `@MainActor` on `PlayerState` — call-site discipline intentional; full annotation is tech debt, out of scope for non-architectural PRs.
- `Task.detached` strong self capture in analysis pipeline — singleton-like PlayerState; acknowledged tech debt.
- `ProgressRulerRow.onSeek` optimistic local progress write — intentional scrubber snappiness.
- Clone window Space behavior — confirmed correct via `.canJoinAllSpaces` on all three windows; Split Mode disables Snap, making clone Space observer unnecessary.
- `CrossfaderGapWindow` is `NSPanel` — `resolvedMainWindow`'s `!($0 is NSPanel)` predicate correctly excludes it. Do NOT flag.
- `installActivityMonitor` churn during Settings open — `scheduleInactivityDock` early-return is the gate; acceptable.
- PeekPanel inherits parent window level/Space — not a separate panel.
- `Track.artworkData: Data?` — field has been REMOVED; only `hasArtwork: Bool` remains. Do NOT flag array-copy concerns.
