# GONE Player — AI Handoff

> Self-contained brief for another AI agent picking this project up cold.
> Generated 2026-05-28. Verify against `git status` + `CLAUDE.md` before acting.

---

## 1. What this app is

**The Swiss Army knife for DJs preparing a set** — a native macOS companion that lives next to Finder. It owns the 30 minutes *before* a set: drop a folder, sort by BPM, audition tracks with real effects at the right tempo, mark what fits, then open Rekordbox/Serato/your DAW.

- **Platform:** macOS 13+, SwiftUI + AppKit + AVFoundation. 100% Apple frameworks, zero external dependencies.
- **Target user:** DJ with music in folders, on a MacBook, deciding what to play. No database, no sync, no beat grid.
- **Core toolkit (one window):** instant BPM detection + sorted list · pitch/tempo preview (±8% fine / ±16% wide / ±100% varispeed) · 4-band EQ + HPF/LPF · XY pad with 13 effect axes (Lo-Fi, Dub Delay, Gate/Slicer, Reverb, Filter) · 4 hot cues per player · Split Mode (two players + visual crossfader) · Snap-to-edge window.

### What it is NOT — do not add or suggest
Beat-grid editing, BPM sync between players, MIDI, library database / persistent tagging, export/sharing/streaming, playlist export to any platform. **Rule of thumb:** if the feature belongs inside Rekordbox or Serato, it does not belong here. Ask before adding anything.

---

## 2. Current state (verified 2026-05-28)

| | |
|---|---|
| Repo | `robvagin-beep/gone-player` (PUBLIC) |
| Branch | `dev` → PR #1 → `main` |
| Version | **Beta 0.9** |
| Last commit | `3677b60` fix: BPM badge — restore deep re-analysis, replace copy with refresh |
| Working tree | post-0.9 stabilization batch committed 2026-05-28 (see below); audit workflows restored |
| Release build | `~/Library/Developer/Xcode/DerivedData/GONE-*/Build/Products/Release/GONE.app` |
| Package script | `~/Desktop/GONE/package_beta08.sh` → Beta 0.9 DMG |

Recent commit arc:
```
3677b60 BPM badge — deep re-analysis restore
cede8c3 remove stateObservers from SplitModeManager — Clone exit crash root cause
46480f6 Clone Mode exit crash — BPM-only observer
b18e77c feat: Beta 0.9 — П1-П14 from task queue   ← bulk of 0.9 work
```

### Post-0.9 stabilization batch (committed 2026-05-28)

A 22-file batch (+613/−369) of stability hardening + UX polish on top of Beta 0.9:

- **Audio engine stability** (`AudioEngine.next.swift`): `stop(drain:)` blocks until in-flight `schedulePCMChunk`/`scheduleBuffer` exits `bufferQueue` — fixes the concurrent `scheduleBuffer` + `stop()` deadlock inside `AVAudioPlayerNode`. New `suppressConfigChange` flag prevents `engine.start()` racing with `stop()` during Split deactivate.
- **Split Mode re-entry guard** (`SplitModeManager.swift`): `@Published var isTransitioning` blocks activate/deactivate re-entry; held 300ms after activation so `audioOpQueue` device-switch ops finish before any deactivate is allowed.
- **Deep BPM analysis rework** (`LibraryScanner.swift`): user-triggered deep pass now scans all 4 quarters of the track independently and votes — handles long silent/ambient intros that broke single-window analysis. Runs at full CPU budget on explicit request.
- **Waveform** (`WaveformView.swift`): beat-grid confidence threshold raised 0.60 → 0.78; base "measuring-tape" ruler is now always rendered, with beat-grid ticks as an overlay (not a replacement).
- **PeekPanel** (`PeekPanelView.swift`): docked corner radius (16) vs floating; marquee text scroll rebuilt around a cancellable `Task` (`scrollTask`).
- **Pitch fader** (`PitchFaderView.swift`): scrub respects masterTempo — ON = time-stretch via `pitchNode.rate` (pitch constant), OFF = varispeed via `speedNode.rate` (vinyl feel).
- **Crossfader scroll** (`CrossfaderBandPanel.swift`): scroll-wheel control in the gap between the two windows; transparent capture layer excludes player-window areas; `momentumPhase == []` filter keeps active scroll, drops post-lift inertia; trackpad vs mouse-wheel scaled separately (0.020 vs 0.070).
- **UI polish**: `TrackHeaderView`, `PlaylistView`, `TransportView`, `SettingsPanel`, `TooltipView`, `FullPlayerView`, `EQPanelView`, `AnalysisCache`, `PlayerState(+Analysis/+Playlists)`, `GONEApp`, `RootView`, `WindowSnapManager`.

### ⚠️ Release entitlements — sandbox intentionally removed (2026-05-28)

`GONE/GONE_release.entitlements` is now **empty by design**. The app-sandbox + `files.user-selected.read-only` pair was removed so GONE can scan arbitrary music folders without per-folder re-authorization. Trade-off: this build is **not sandboxable / not Mac App Store eligible** — fine for ad-hoc DMG distribution.

The removed keys are preserved as a comment inside the entitlements file for one-paste restore. If a sandboxed/MAS build is ever needed, paste them back. Do NOT "fix" the empty file by re-adding sandbox unless that's the explicit goal.

---

## 3. Architecture — critical invariants (never violate)

1. **Audio graph is fixed forever:**
   `playerNode → speedNode → pitchNode → hpfNode → lpfNode → eqNode → distortionNode → delayNode → reverbNode → gateNode → mainMixerNode`
   (`distortionNode`=Lo-Fi, `delayNode`=Dub Delay, `gateNode`=Slicer. Spectrum normalizes to **0..0.24** ceiling, not 0..1. `processSpectrum` sampleRate comes from the tap buffer, not hardcoded 44100.)
2. **Two engine instances:** `AudioEngineNext.shared` (primary) + `AudioEngineNext.secondary` (clone). In Views & PlayerState extensions use `state.audioEngine` / `self.audioEngine` — **never** `.shared` directly. (`init()` is private to enforce the 2-instance invariant.)
3. **Per-player feeds:** `state.progressFeed` (per-instance), `SpectrumFeed.shared` (singleton). `PlaybackProgressFeed.shared` exists only for legacy PeekPanel. Reset progress via `self.progressFeed.reset()`, not the singleton.
4. **Timers:** `RunLoop.main.add(timer, forMode: .common)` + `MainActor.assumeIsolated` inside callback. Never bare `Timer.scheduledTimer`.
5. **WindowSnapManager state machine** — most delicate subsystem. Dock: `isSnapping=true → slideOffScreen (Timer, NOT NSAnimationContext) → prepareForSnap → [completion] snapState=.docked → lockFrame → isSnapping=false`. Never use NSAnimationContext for off-screen destinations; never set `.docked` or `lockFrame` before slide completion. Read the whole file before touching.
6. **`windowResizability(.automatic)`** and **`isMovableByWindowBackground = false`** — never change.
7. **`updateWindowSize`** — called only from `RootView.onChange`. Do not duplicate.
8. **XY FX** (`applyXYEffect` in `RootView.swift`): never writes to `@Published` state (prevents re-render loop). On axis change / deactivate: `stopSlicer()` + `resetFXNodes()`. Slicer is Timer-based 60fps driven by `state.bpm`.
9. **Xcode project:** `PBXFileSystemSynchronizedRootGroup` — files auto-discovered, do NOT edit `.pbxproj` manually. SourceKit "Cannot find type X in scope" = false positive → Clean Build Folder (Shift+Cmd+K).

> ⚠️ `AudioEngine.next.swift` lives in a **nested** `GONE/GONE/` subfolder, not the flat file group.

---

## 4. File map (`GONE/GONE/`)

```
GONEApp.swift              app entry, AppDelegate, key monitor, hot cues, magnify
PlayerState.swift          single source of truth; XY/LFO/Slicer timers
PlayerState+Playback.swift load/play/prev/next/delete; hot cue reset
PlayerState+Analysis.swift BPM (concurrency=2) + waveform async; task cancellation
PlayerState+Playlists.swift tabs, import (batch 4), sort, session
PlayerState+EQ.swift       EQ presets, reverb cycling
GONE/AudioEngine.next.swift  AVAudioEngine graph (nested folder)
PlaybackProgressFeed.swift per-player progress/time ObservableObject
SpectrumFeed.swift         singleton spectrum ObservableObject
SplitModeManager.swift     two-player Split Mode + crossfader coordination
CrossfaderBandPanel.swift  NSPanel crossfader UI + hit-test + Canvas
SettingsPanel.swift        settings overlay (scale, magnify, snap delay)
LibraryScanner.swift       metadata + waveform + BPM decode (half-tempo 0.82)
ArtworkCache.swift         NSCache(300) + disk 256px JPEG
Track.swift                Track struct + TrackFlag + BPMAnalysisState
DesignTokens.swift         G.* design constants
RootView.swift             shell, XY wiring, onChange, top-anchor, drag overlay
FullPlayerView.swift       player layout (clone window uses this, not RootView)
TrackHeaderView.swift      artwork, title, badges, spectrum
WaveformView.swift         waveform Canvas + seek + hot cue ticks + A-B loop
SpectrumView.swift         bars/osc spectrum
TransportView.swift        transport, volume, snap/pin, repeat
PitchFaderView.swift       vertical pitch slider + MT button
EQPanelView.swift          EQ faders, HPF/LPF, XY pad (13 axes), FX selector
PlaylistView.swift         playlist panel, tabs, rows, keyboard nav
PeekPanelView.swift        snap-edge HUD: mini transport + spectrum
WindowSnapManager.swift    snap state machine
```

Artwork pipeline (do not regress): embedded → ID3 APIC → iTunes covr → all-formats scan → folder files. **No QuickLook fallback** (returns generic macOS icon, not real art).

---

## 5. Task status — Beta 0.8 → 0.9

Full spec: `GONE_Tasks_Beta08.md`. Source of truth for what each П means.

**Done (commit `b18e77c`):** П1–П14
- П1 Snap bolt guarded on empty playlist · П2 analysis task cancellation · П3 single progress broadcast/frame · П4 O(1) `current` via track index · П5 AnalysisCache eviction · П6 colour track flags · П7 persistent session · П8 delta BPM in Split · П9 A-B loop · П10 vertical drag while snapped · П11 waveform drag glow on active tick · П12 FX left/right click zones · П13 Clone exit button active state · П14 BPM badge tap-to-copy

**Pending (P3 tech debt, not started):**
- П15 `Task.sleep(nanoseconds:)` → `Task.sleep(for: .milliseconds(N))` (grep-and-replace, all files)
- П16 `presentImportPanel` → `resolvedMainWindow()` instead of `NSApp.keyWindow`
- П17 collapse dual SnapState enums (`WindowSnapManager.SnapState` vs `PlayerState.SnapMode`) — only if no other snap work in same session
- П18 remove orphan `splitPlaylistView` / `secondaryPlaylistTabId` (no UI)

---

## 6. Open blockers — need Robert's decision

1. 45 audit workflows + scripts staged as **deleted** — intentional cleanup or accidental? (`git status` shows them under `.github/workflows/`)
2. `premerge-check.yml` calls `python premerge_check.py`, but that script is staged as deleted → fix, remove the workflow, or restore the script?
3. `GONE_BACKLOG.md` maps tasks to deleted workflow names → update or drop the map
4. `GONE_CURATOR.md` still says Beta 0.7 / `package_beta07.sh` → bump to 0.9 or mark archival
5. Docs reference `gh issue create + label claude-task → workflow`, but no such workflow exists physically. Confirm real CI route before relying on it.

---

## 7. CI / delegation rules

- **Heavy work (audits, multi-file refactors, big features) is delegated to GitHub + Anthropic API, not done in a local session.** Local agent is allowed: read files, audit docs, write planning/handoff markdown, prepare issue text, run inspection commands. Blocked without explicit "do it here now": Swift edits, feature/hotfix implementation, refactors, packaging/CI/workflow changes.
- **Confirmed working CI route:** PR → `pr-review.yml` → `.github/scripts/claude_review.py` (model `claude-opus-4-7`) → Anthropic API review comments.
- **Unconfirmed route (do not use until verified):** issue + `claude-task` label → workflow. No matching workflow file exists.
- Physical workflows present: `pr-review.yml`, `premerge-check.yml`. Physical scripts: `beat_grid_audit.py`, `beat_phase_audit.py`, `claude_review.py`.

---

## 8. Packaging to DMG (no Developer ID) — strict order

1. **Build Release in Xcode**, not via `xcodebuild` in a script. Switch scheme to Release → Cmd+B → "Build Succeeded" (~2 min). `xcodebuild` ignores DerivedData cache → 10+ min full rebuild.
2. **Info.plist first, then sign** — order is strict:
   `PlistBuddy -c "Add :CFBundleDisplayName string ..."` then `codesign --force --deep --sign - --entitlements GONE/GONE_release.entitlements ...`. Reversed order → invalid signature → crash (`OSStatus -67030`, `_libsecinit_appsandbox`).
3. **Release entitlements** (`GONE/GONE_release.entitlements`): `app-sandbox=true`, `files.user-selected.read-only=true`. `get-task-allow` Debug only — never in Release.

Script `package_beta08.sh` does: locate Release build in DerivedData → PlistBuddy name → ad-hoc codesign → `hdiutil create` DMG → open Desktop.

---

## 9. Do-not-flag list (verified false positives / intentional)

`CLAUDE.md` §"PR Review — Already Resolved" holds the full list. Highlights so review budget isn't wasted:
- `playbackToken` / `bumpToken()` — value-type token param, zero TOCTOU. Verified.
- `AudioEngineNext.deinit` — static singletons, deinit never runs; all cleanup there is defensive dead code.
- `progressTimer` / `holdSeekTimer` capture-then-async invalidation — intentional deadlock prevention.
- `SplitModeManager.deactivate()` uses `markStopped()` then off-main `stop()` — avoids Core Audio IO-lock deadlock.
- `MainActor.assumeIsolated` in RunLoop.main timer callbacks — correct per project rules.
- `Task.sleep(nanoseconds:)` deprecation — acknowledged tech debt (П15), out of scope for unrelated PRs.
- Dual SnapState enums — acknowledged (П17).
- `Track.artworkData` — REMOVED; only `hasArtwork: Bool` remains.

---

## 10. Session start checklist (canonical order)

1. `GONE_SYSTEM_TOC.md` — navigator + stale docs + blockers
2. `CLAUDE.md` — architectural invariants + do-not-flag list
3. `GONE_Tasks_Beta08.md` — task spec (П1–П18)
4. `git status --short --branch` — real repo state (memory can be stale)

Audit docs (`GONE_*_Audit_*.md`, `GONE_Sweep_*`, `codex-tasks.md`) are **source material, not active routing truth** — read only when preparing GitHub issues, never follow blindly.
