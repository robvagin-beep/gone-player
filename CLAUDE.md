# GONE Player — Context & Rules

## What This App Is

A lightweight macOS pre-listen tool for hobbyist DJs working alongside Finder.

**Target user:** Someone who has music in folders, working on a MacBook at a side job or at home. Before a set, they open their folders, sort by BPM, audition tracks quickly, adjust tempo, and decide what fits — without opening Rekordbox. The app stays on screen next to Finder, small, always on top, out of the way.

**Core value:**
- Fast folder drop → instant BPM detection
- Pitch/tempo preview (±8 / ±16 / ±100%)
- Quick 4-band EQ sculpting for auditioning (not mixing)
- Snap-to-edge when you need the screen
- macOS 13+ support — runs on older MacBooks too (this is a feature, not a limitation)

## What This App Is NOT

Do not add or suggest:
- Crossfader, sync, beat-grid editing
- Hot cues, loops, cue points (beyond simple playhead seek)
- MIDI control of any kind
- Library database / tagging system (no persistent metadata beyond ratings)
- Real-time performance tools
- Export or sharing features
- Social features, playlists export to Spotify/Apple Music/etc
- Any feature that makes it "more like Rekordbox"

If you find yourself thinking "this would be great for DJs" — stop. Ask first.

---

## Architecture — Critical Rules

### 1. Snap Edge System (`WindowSnapManager.swift`)
This is the most delicate part. Do NOT modify without reading and understanding the full state machine.

**The dock sequence:**
1. (async block) → `isSnapping = true`
2. `slideOffScreen()` starts immediately
3. After ~80ms: `prepareForSnap()` → panels collapse (isSnapping blocks updateWindowSize height shift)
4. In slideOffScreen completion: `snapState = .docked` → `lockFrame()` → `isSnapping = false`

**The expand sequence:**
1. `unlockFrame()`
2. `snapState = .expanded`, `isSnapping = true`
3. `restoreFromSnap()` immediately → panels start opening as window slides out
4. `animateFrameTo(savedFrame)` runs simultaneously
5. In completion: `isSnapping = false`

**Never:**
- Replace `slideOffScreen` Timer with `NSAnimationContext` for off-screen destinations
- Set `snapState = .docked` before the animation completes
- Call `lockFrame()` before `slideOffScreen` completion
- Remove `isSnapping` guard in `updateWindowSize`

### 2. Audio Graph (`AudioEngine.next.swift`)
Chain is fixed: `playerNode → speedNode → pitchNode → hpfNode → lpfNode → eqNode → reverbNode → mainMixerNode`

- Do not reorder nodes
- Do not add nodes without updating the full chain
- Spectrum values are normalized to **0..0.24** ceiling (not 0..1) — all visual components normalize against 0.24

### 3. Window Architecture (`GONEApp.swift`)
- `windowResizability` must stay `.automatic` — `.contentSize` breaks snap position
- Window is borderless, clear, no shadow — do not add titlebar
- `updateWindowSize` is called from `RootView.onChange` — do not move or duplicate it

### 4. AppKit / SwiftUI Bridge
- Window access: always through `AppDelegate.resolvedMainWindow()` or `WindowSnapManager.shared.currentWindow`
- Never use `NSApp.windows.first` directly for operations
- All timers: `RunLoop.main.add(timer, forMode: .common)` — not `.default`
- Timer callbacks: `MainActor.assumeIsolated` inside

### 5. Xcode Project
- File sync: `PBXFileSystemSynchronizedRootGroup` — Xcode auto-discovers files in folder
- Do NOT add files to the `.pbxproj` manually
- SourceKit errors "Cannot find type X in scope" are **false positives** from stale index
  - The project compiles correctly in Xcode
  - Fix: Clean Build Folder (Shift+Cmd+K)
  - Do NOT restructure files to "fix" these errors

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
- BPM range resolution (60–200 range in `LibraryScanner.analyzeBPM`)

## What You Must NOT Change

- `WindowSnapManager.swift` state machine sequence
- `updateWindowSize` logic in `RootView.swift`
- Audio graph node order or chain in `AudioEngine.next.swift`
- AppDelegate window configuration (`configureWindow`)
- `RunLoop.main.add(timer, forMode: .common)` patterns — do not change to `.default`
- `PlayerState` class itself — do not add new `@StateObject` or split into multiple ObservableObjects
- `.windowResizability(.automatic)` in `GONEApp.swift`

---

## Conventions

```
Design tokens    → DesignTokens.swift  (G.* prefix)
State            → PlayerState + extensions in PlayerState+*.swift
Audio            → AudioEngineNext.shared (singleton)
Window snap      → WindowSnapManager.shared (singleton)
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
  GONEApp.swift              — app entry, AppDelegate, window setup
  PlayerState.swift          — single source of truth for all state
  PlayerState+Playback.swift — load/play/prev/next/delete
  PlayerState+Analysis.swift — BPM + waveform async computation
  PlayerState+Playlists.swift— tabs, import, sort
  PlayerState+EQ.swift       — presets, reverb cycling
  GONE/AudioEngine.next.swift— AVAudioEngine graph (double-folder, legacy)
  LibraryScanner.swift       — metadata + waveform + BPM decode
  ArtworkCache.swift         — NSCache + disk cache for artwork
  Track.swift                — Track struct + BPMAnalysisState enum
  DesignTokens.swift         — G.* design constants
  RootView.swift             — shell, drag overlay, drop zone, window sizing
  FullPlayerView.swift       — player layout, panel accordion
  TrackHeaderView.swift      — artwork, title, badges, spectrum
  WaveformView.swift         — waveform canvas + seek
  SpectrumView.swift         — bars/osc spectrum (tap to switch)
  TransportView.swift        — transport controls, volume, snap/pin buttons
  PitchFaderView.swift       — vertical pitch slider + MT button
  EQPanelView.swift          — 4-band EQ faders, HPF/LPF/FX knobs, curve
  PlaylistView.swift         — playlist panel, tabs, rows, sort headers
  PeekPanelView.swift        — snap edge HUD: mini transport + meter
  WindowSnapManager.swift    — snap state machine
```

---

## Current Known Gaps (do NOT touch without instruction)

- Playlist tabs UI: state machine is ready, UI tab bar needs wiring — complex, wait for instruction
- `splitPlaylistView` / `secondaryPlaylistTabId` — orphan state, no UI yet
- App icon: not added to Assets.xcassets
- AIFF artwork: some files don't load art (known bug, needs investigation)
