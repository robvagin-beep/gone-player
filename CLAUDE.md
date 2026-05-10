# GONE Player — Context & Rules

## What This App Is

A lightweight macOS pre-listen tool for hobbyist DJs working alongside Finder.

**Target user:** Someone who has music in folders, working on a MacBook at a side job or at home. Before a set, they open their folders, sort by BPM, audition tracks quickly, adjust tempo, and decide what fits — without opening Rekordbox. The app stays on screen next to Finder, small, always on top, out of the way.

**Core value:**
- Fast folder drop → instant BPM detection
- Pitch/tempo preview (±8 / ±16 / ±100%)
- Quick 4-band EQ sculpting for auditioning (not mixing)
- Snap-to-edge when you need the screen
- Split Mode: two independent players with visual crossfader (for side-by-side comparison, not live mixing)
- macOS 13+ support — runs on older MacBooks too (this is a feature, not a limitation)

## What This App Is NOT

Do not add or suggest:
- Beat-grid editing, sync (BPM match between players)
- MIDI control of any kind
- Library database / tagging system (no persistent metadata beyond ratings)
- Export or sharing features
- Social features, playlists export to Spotify/Apple Music/etc
- Anything that makes it "more like Rekordbox"

If you find yourself thinking "this would be great for DJs" — stop. Ask first.

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
- `Track.artworkData: Data?` in struct — causes array copy overhead during import batches (significant refactor, coordinate separately)
- `splitPlaylistView` / `secondaryPlaylistTabId` in PlayerState — orphan state, no UI yet

---

## PR Review — Already Resolved (do NOT flag again)

These items have been explicitly fixed or are intentional design decisions. Flagging them wastes review budget.

### Threading / Timers
- `playbackToken` / `bumpToken()`: NSLock-protected, atomic `&+=`, correct usage — no race
- `progressTimer` capture: `let t = progressTimer; progressTimer = nil` before dispatch — intentional deadlock prevention (async, not sync)
- `stopHoldSeek()` off-main: has identical main-thread dispatch guard as `progressTimer`
- `holdSeekTimer` in `deinit`: captured and dispatched to main in deinit, same pattern as progressTimer
- `DispatchQueue.main.async` (not sync) for timer invalidation: intentional — `stop()` called from `Task.detached` in Split Mode deactivate; sync would deadlock
- `MainActor.assumeIsolated` in RunLoop.main timer callbacks: correct pattern per project rules
- `bumpToken()` discarded in `stop()`: intentional — `stop()` does not schedule buffers, only needs to invalidate in-flight ones

### Audio Engine
- `AudioEngineNext.init()` is `private` — enforces 2-instance invariant (`shared` + `secondary`)
- `AudioEngineNext.secondary` eager init: pre-existing architecture — out of scope
- `currentURL`/`audioFile` thread safety: pre-existing architecture concern — out of scope
- `stopHoldSeek()` → `applyPitchState()`: correctly restores `pitchNode.bypass`, `speedNode.rate`, and pitch state on hold-seek end
- `SplitModeManager.deactivate()` calls `AudioEngineNext.secondary.pause()` on main before `stop()` off-main — hang fix, intentional sequence
- `SplitModeManager.activate()` copies `primaryState.volume` to `secondaryState` on line ~126 ✓

### Crossfader / Clone
- `CrossfaderBridgeView` `@ObservedObject var manager`: correctly declared, Canvas redraws on `crossfade` change ✓
- `CrossfaderGapWindow` double-close observer cleanup: idempotent by design — both `close()` and `deinit` remove observers safely
- `ClonePlayerShell.resizeWindow` vs snap: clone window is never snap-managed — no conflict possible
- `ClonePlayerShell.resizeWindow` screen bounds: clamps both bottom (`>= vis.minY`) AND top (`<= vis.maxY - height`)
- `ScrollWheelNSView` momentum: `guard event.momentumPhase == .stationary` blocks trackpad inertia ✓
- `EmptyOverlayView` in clone: gated with `state.audioEngine !== AudioEngineNext.secondary`
- `BandHitTestView.hitTest` pass-through: root content view returning `nil` causes AppKit to route event to window below ✓
- `BandHitTestView.hitRadius`: `let`, value 60px — matches spec
- `BandHitTestView` segment guard: uses `distance² > 16` (not exact equality) to handle pre-geometry and coincident-window states

### SwiftUI / Views
- `EmptyOverlayView.startTypewriter`: `animTask?.cancel()` called at top of method before creating new task ✓
- `EQCurveView.animateTo` Task churn: pre-existing, acknowledged tech debt — out of scope
- `Task.sleep(nanoseconds:)` deprecation: acknowledged tech debt in CLAUDE.md — out of scope for this PR
- `ArtworkCache.writeToDisk`: runs on `.utility` background queue, uses `.atomic` write option ✓

### CI / Tooling
- `model="claude-opus-4-7"` in `claude_review.py`: this model ID is valid and the workflow runs successfully — do not flag as invalid
- `urllib` timeout: `urlopen(req, timeout=30)` added ✓
