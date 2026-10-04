# GONE Code Audit Recommendations - 2026-05-12

This document contains my recommendations and proposals after a full code audit of the current GONE build, using `GONE_CURATOR.md` as the controlling rule file.

No Swift code was changed as part of this audit. The goal is to identify the most attention-worthy areas, explain why they matter, and prepare precise follow-up tasks for Claude review.

## Audit Scope

Reviewed project areas:

- App/window bootstrap: `GONEApp.swift`, `RootView.swift`, `WindowSnapManager.swift`, `UIHelpers.swift`
- Audio engine and playback: `GONE/AudioEngine.next.swift`, `PlayerState+Playback.swift`, `PlaybackProgressFeed.swift`
- Analysis pipeline: `PlayerState+Analysis.swift`, `LibraryScanner.swift`, `AnalysisCache.swift`, `AnalysisProgressFeed.swift`
- UI surfaces: `FullPlayerView.swift`, `TrackHeaderView.swift`, `TransportView.swift`, `WaveformView.swift`, `PlaylistView.swift`, `EQPanelView.swift`, `PitchFaderView.swift`, `PeekPanelView.swift`
- Split mode: `SplitModeManager.swift`, `ClonePlayerShell.swift`, `CrossfaderBandPanel.swift`
- Settings and helpers: `SettingsPanel.swift`, `TooltipView.swift`, `SpectrumView.swift`, `SpectrumFeed.swift`, `XYPadState.swift`, `DesignTokens.swift`, `Track.swift`

## Executive Summary

The current build is coherent and much stronger than earlier iterations: the audio graph order is intact, snap mode has a guarded state machine, `windowResizability(.automatic)` is preserved, and the app generally routes playback through `state.audioEngine`.

The main weak areas are not broad architecture failures. They are concentrated in a few places:

- The waveform ruler has a specific visual conflict: musical grid ticks become fully bright while dragging because `isDragging` forces `animT = 1` for every musical tick.
- BPM, waveform, and beat-grid analysis can still overlap in ways that contradict the comments about avoiding competing `AVAssetReader` work.
- Beat-grid detection currently detects beat phase, not musical downbeat or bar phase, but the UI labels some ticks as bar and 4-bar anchors.
- `alwaysOnTop` exists as state and persisted setting, but current window policy always applies `GWindowLevel.player`, so the toggle is not functionally meaningful.
- There are still direct singleton references from views/settings to `AudioEngineNext.shared` and `AudioEngineNext.secondary`.
- One timer still uses `Timer.scheduledTimer`, which violates the curator rule that timers must be manually added to `.common`.
- `AudioEngineNext` spectrum tap has a potential shared-buffer race between the render callback and the spectrum processing queue.

## Highest Priority Findings

### 1. Waveform ruler double-grid and seek glow

Files:

- `WaveformView.swift`

What I found:

- For analyzed tracks, fallback structural and interstitial ticks are not drawn.
- Musical grid ticks are drawn from `beatGridOffset`, `bpm`, and `duration`.
- During dragging, this line makes all musical ticks fully bright:

```swift
let animT: CGFloat = played || isDragging ? 1 : 0
```

Why it matters:

- This directly explains the observed behavior where grid ticks start glowing while scrubbing.
- It also makes the ruler feel like an active playback progress layer rather than a stable structural guide.

Recommendation:

- Keep musical grid ticks visually stable during drag.
- If a drag preview is needed, only the region up to the temporary playhead should brighten.
- Do not let `isDragging` globally brighten future ticks.
- Define explicit ruler modes:
  - fallback structural mode before beat-grid confidence is available
  - musical beat-grid mode after confidence is accepted
  - drag-preview mode that affects only the playhead/progress region

Claude task classification: LOCAL.

### 2. Beat-grid phase is not the same as bar/downbeat phase

Files:

- `LibraryScanner.swift`
- `WaveformView.swift`
- `Track.swift`
- `AnalysisCache.swift`

What I found:

- `estimateBeatGridOffset` scans phase candidates inside one beat duration.
- The returned value is a beat-phase offset.
- `WaveformView` then derives:
  - beat ticks
  - bar ticks
  - 4-bar ticks
- The code assumes the first detected beat is beat 1 of a 4/4 bar.

Why it matters:

- On steady house tracks, beat placement can be correct while bar/downbeat labels look musically shifted.
- This can create the impression that quarter/bar detection is asymmetric or wrong.

Recommendation:

- Keep current beat phase as `beatGridOffset`.
- Do not present it as reliable bar/downbeat detection unless a separate downbeat estimator exists.
- Either:
  - rename the visual logic to "beat grid" and avoid implying true bar starts, or
  - add a second field later, for example `barGridOffset`, only after a real downbeat confidence pass exists.

Claude task classification: GITHUB if downbeat inference is attempted. LOCAL if only visual naming/behavior is corrected.

### 3. BPM and waveform jobs still have duplicated analysis paths

Files:

- `PlayerState+Analysis.swift`
- `PlayerState+Playlists.swift`
- `LibraryScanner.swift`

What I found:

- `scheduleBPMAnalysis()` runs combined BPM plus waveform plus beat-grid analysis.
- `scheduleWaveformComputation()` can also run standalone waveform generation.
- Import flow can schedule both after import finishes.
- Comments say competing `AVAssetReader` work can freeze or stutter UI, but the code still has paths that may compete.

Why it matters:

- This increases disk pressure and decode work.
- It can make analysis feel inconsistent on import-heavy sessions.
- It can produce stale or partial waveform/grid states depending on which job commits first.

Recommendation:

- Make the analysis scheduler single-owner:
  - if auto BPM is enabled, combined BPM plus waveform owns waveform generation for those tracks
  - standalone waveform only runs for tracks where BPM analysis is disabled, failed, cached BPM-only, or explicitly requested
- Store task handles for BPM and waveform batches.
- Cancel or reprioritize tasks when import restarts, tracks are deleted, or clone mode shuts down.

Claude task classification: GITHUB.

### 4. Detached analysis tasks have no cancellation handles

Files:

- `PlayerState+Analysis.swift`

What I found:

- `Task.detached` is used for deep BPM analysis, BPM batch analysis, and waveform computation.
- Handles are not stored.
- The curator brief already lists this as known tech debt.

Why it matters:

- Deleting tracks, closing clone mode, or restarting analysis cannot cancel work cleanly.
- Strong `[self]` captures keep the state alive until detached work completes.

Recommendation:

- Add explicit task handles:
  - `bpmAnalysisTask`
  - `waveformAnalysisTask`
  - optional `deepAnalysisTasksByTrackId`
- Cancel before starting a replacement task.
- Check `Task.isCancelled` between decode phases and before committing to `tracks`.

Claude task classification: GITHUB.

### 5. Deep BPM re-analysis does not refresh waveform or beat-grid metadata

Files:

- `PlayerState+Analysis.swift`
- `LibraryScanner.swift`

What I found:

- `reanalyzeBPMDeep(for:)` calls `analyzeBPMDeep`.
- It commits BPM only.
- It does not update `beatGridOffset`, `beatGridConfidence`, or waveform.

Why it matters:

- If the user refreshes BPM because the grid feels wrong, the visual beat grid can remain old or missing.
- The UI can show a newly corrected BPM with stale beat-grid phase.

Recommendation:

- Either rename this action as BPM-only, or make deep analysis return the same tuple as standard combined analysis:
  - BPM
  - waveform
  - beatGridOffset
  - beatGridConfidence
- If deep analysis stays BPM-only, explicitly reset grid confidence to zero so stale grid is not trusted.

Claude task classification: LOCAL or GITHUB depending on whether scanner internals are reused or rewritten.

### 6. Window always-on-top setting is currently not meaningful

Files:

- `GONEApp.swift`
- `PlayerState.swift`
- `SettingsPanel.swift`
- `UIHelpers.swift`

What I found:

- `PlayerState.alwaysOnTop` is persisted.
- `setAlwaysOnTop(_:)` writes the state.
- `applyPresencePolicy(to:)` always sets `window.level = GWindowLevel.player`.
- This means the app is effectively always topmost regardless of `alwaysOnTop`.

Why it matters:

- The setting name suggests optional behavior, but the implementation has a fixed policy.
- Future changes may accidentally treat this as working state and create contradictory window behavior.

Recommendation:

- Decide whether the app should always float by product rule.
- If yes, remove or hide the dead setting and document fixed presence behavior.
- If no, make `applyPresencePolicy` conditional while preserving snap/fullscreen behavior.
- Do not touch `windowResizability(.automatic)` or `isMovableByWindowBackground = false`.

Claude task classification: LOCAL.

### 7. Direct audio singleton references still exist outside the intended boundary

Files:

- `SettingsPanel.swift`
- `SplitModeManager.swift`
- `FullPlayerView.swift`
- `TransportView.swift`

What I found:

- `SettingsPanel` directly calls `AudioEngineNext.shared` and `.secondary`.
- `SplitModeManager` necessarily creates and manages `.secondary`, but also reads `.shared`.
- `FullPlayerView` and `TransportView` compare `state.audioEngine !== AudioEngineNext.secondary` to distinguish primary from clone.

Why it matters:

- The curator rule says views/extensions should use `state.audioEngine`, not direct `.shared`.
- Direct identity checks make UI behavior depend on singleton identity instead of explicit player role.

Recommendation:

- Add explicit player role to `PlayerState`, for example `playerRole: .primary | .secondary`.
- Use that role for UI decisions such as settings visibility and empty overlay behavior.
- Keep `SplitModeManager` as the only place that knows how to instantiate and wire the secondary engine.

Claude task classification: GITHUB if role is threaded broadly. LOCAL if only settings visibility is corrected.

### 8. One timer violates the `.common` timer rule

Files:

- `TransportView.swift`

What I found:

- `ClickNSView.mouseDown` uses:

```swift
Timer.scheduledTimer(withTimeInterval: threshold, repeats: false)
```

Why it matters:

- The curator rule says timers must use `RunLoop.main.add(timer, forMode: .common)`.
- A scheduled timer can behave incorrectly during tracking modes.

Recommendation:

- Replace it with `Timer(timeInterval:repeats:block:)`.
- Add it to `RunLoop.main` with `.common`.
- Keep `MainActor.assumeIsolated` in the callback.

Claude task classification: LOCAL.

### 9. Audio spectrum tap may have a shared-buffer race

Files:

- `GONE/AudioEngine.next.swift`

What I found:

- The tap callback writes samples into shared buffers.
- The spectrum queue later reads/copies those buffers.
- The audio render callback can mutate the buffer while the queue is processing.

Why it matters:

- This is not guaranteed to crash, but it can cause spectrum jitter, inconsistent visual data, or undefined reads.
- The current code tries to avoid render-thread allocations, which is correct, but still needs a safe handoff boundary.

Recommendation:

- Use a small lock-free or double-buffered handoff:
  - render thread writes into one preallocated buffer
  - processing queue reads a different committed buffer
  - swap only at safe boundaries
- Do not allocate arrays in the render callback.
- Do not move FFT work onto the render callback.

Claude task classification: GITHUB.

### 10. Analysis cache settings appear partially disconnected

Files:

- `PlayerState.swift`
- `AnalysisCache.swift`
- `SettingsPanel.swift`

What I found:

- `bpmCacheEnabled` and `bpmCacheFolder` exist in `PlayerState`.
- They do not appear to be loaded or persisted with other settings.
- `AnalysisCache` uses its own Application Support path.

Why it matters:

- These fields look like planned settings but may not affect runtime behavior.
- Dead settings can mislead future implementation work.

Recommendation:

- Either wire them fully into `AnalysisCache`, persistence, and Settings UI, or remove/defer them from `PlayerState`.
- Do not expose cache location controls until they actually affect read/write paths.

Claude task classification: LOCAL.

## Node-by-Node Recommendations

### `GONEApp.swift`

Current strengths:

- Window policy is centralized.
- Main window uses correct borderless, nonactivating setup.
- `isMovableByWindowBackground = false` is preserved.
- `windowResizability(.automatic)` is preserved.
- `canJoinAllSpaces` is already applied.

Attention points:

- `alwaysOnTop` state is ignored because `applyPresencePolicy` always sets player level.
- `applicationDidBecomeActive` auto-expands docked/peeking windows, which may conflict with the edge-hiding metaphor if activation happens by Cmd+Tab or app focus changes.
- `applicationWillTerminate` blocks up to 2 seconds for cache flushing. This is acceptable but should stay isolated to termination.

Proposal:

- Treat window presence as one explicit policy enum instead of mixing `alwaysOnTop`, snap state, and fixed `GWindowLevel.player`.
- Keep the current topmost behavior unless a specific product decision says otherwise.

### `WindowSnapManager.swift`

Current strengths:

- State machine is explicit.
- Frame lock exists to prevent SwiftUI/window-resizability drift.
- Dock token prevents stale dock completions from re-locking after disable.
- Space-change observer corrects frame drift and alpha artifacts.
- Timers are mostly `.common` and use `MainActor.assumeIsolated`.

Attention points:

- `animateFrameTo` appears unused.
- Snap restore depends on carefully timed delayed state changes.
- `savedWindowWidth`, `savedFrame`, `savedOrigin`, and `isSnapping` must remain in sequence.
- `peekVisible` and visual `PeekPanelView` dimensions are not obviously derived from the same source of truth.

Proposal:

- Do not refactor this file broadly.
- If touched, make a state-transition table first:
  - off
  - waiting
  - docked
  - peeking
  - expanded
- Add comments or assertions around legal transitions rather than rewriting the manager.

### `RootView.swift`

Current strengths:

- `updateWindowSize` is centralized in RootView.
- `state.isSnapping` guards window resizing during snap motion.
- Shell scaling is centralized and visually coherent.

Attention points:

- `BottomResizeHandle` directly changes `playlistPanelHeight`, which is fine, but it drives window resizing indirectly through RootView.
- Drag overlays and resize handles need continued protection from stealing button events.

Proposal:

- Keep `updateWindowSize` only here.
- If new resize behavior is added, keep it routed through state changes, not direct window frame duplication.

### `AudioEngine.next.swift`

Current strengths:

- Audio graph order matches the curator rule:

```text
playerNode -> speedNode -> pitchNode -> hpfNode -> lpfNode -> eqNode -> distortionNode -> delayNode -> reverbNode -> gateNode -> mainMixerNode
```

- Playback chunk scheduling is token-guarded.
- Hold seek and progress handling are separated.
- Pitch bypass behavior at neutral rate is deliberate and correct.

Attention points:

- `startProgressTimer` uses `.common`, but the callback does not use `MainActor.assumeIsolated`.
- First buffer scheduling can block the caller because it synchronously reads via `bufferQueue.sync`.
- Spectrum tap handoff likely needs safer buffering.
- Reopening `AVAudioFile` per chunk is simple and safe, but may become a performance point on slow storage.

Proposal:

- Do not reorder the audio graph.
- Do not move decode or FFT work to the render callback.
- Treat spectrum handoff and first-buffer scheduling as measured performance tasks.

### `PlayerState.swift`

Current strengths:

- Single source of truth is mostly preserved.
- UI-heavy feeds were split out to avoid over-broadcasting `PlayerState`.
- Timer-heavy XY/LFO/slicer state uses `.common` timers and `MainActor.assumeIsolated`.

Attention points:

- `alwaysOnTop` is persisted but currently not meaningful.
- `bpmCacheEnabled` and `bpmCacheFolder` look disconnected.
- `windowScale` is persisted twice.
- Default `bpmAnalysisCeiling` differs between property default and fallback load value.

Proposal:

- Clean persisted settings so every persisted field either works or is removed from persistence.
- Add a short persistence map comment so future settings are not half-wired.

### `PlayerState+Analysis.swift`

Current strengths:

- Current track gets priority.
- Batch concurrency is capped.
- Combined BPM plus waveform pass is the right direction.
- Cache hit path avoids unnecessary decode.

Attention points:

- Detached tasks lack cancellation handles.
- Standalone waveform and combined BPM analysis can still overlap.
- Deep BPM reanalysis updates BPM only.
- Analysis comments and actual scheduling behavior do not fully match.

Proposal:

- Make a single analysis coordinator responsible for pending, active, canceled, and completed states.
- Keep combined decode as the primary path.
- Use standalone waveform only as fallback.

### `LibraryScanner.swift`

Current strengths:

- Uses native frameworks only.
- BPM detection, waveform, and beat-grid phase are implemented without dependencies.
- Security-scoped resource access is handled.

Attention points:

- Combined analysis stores full-track samples in memory.
- BPM logic is duplicated across standard and deep analysis.
- Beat phase is treated downstream as bar/downbeat phase.
- The confidence score can accept beat phase but not prove musical phrase alignment.

Proposal:

- Consolidate BPM scoring helpers.
- Keep beat phase and bar/downbeat phase as different concepts.
- If memory becomes an issue, stream waveform bucket generation rather than retaining all samples.

### `WaveformView.swift`

Current strengths:

- Canvas-based drawing is efficient and controllable.
- Fallback and analyzed grid modes are already partially separated.
- Hot cues render topmost.

Attention points:

- `isDragging` brightens all musical ticks.
- `isAnalyzingBeatGrid` is passed but not used.
- The track-quarter fallback and musical grid use different conceptual structures.
- `BarTracker` is mostly useful for fallback mode now, less so for analyzed mode.

Proposal:

- Remove global drag glow from musical grid.
- Decide whether analyzed mode should show:
  - only waveform plus beat ticks
  - waveform plus track quarters plus beat ticks
  - separate muted structural layer and active progress layer
- Use `isAnalyzingBeatGrid` only if it has a real visual state, otherwise remove it.

### `TransportView.swift`

Current strengths:

- Left, center, and right control groups are visually clean.
- Secondary player hides settings via engine identity check.
- Hold seek has a careful AppKit detector.

Attention points:

- `ClickNSView` uses `Timer.scheduledTimer`.
- Views compare `state.audioEngine` against `AudioEngineNext.secondary`.
- Volume slider changes height on hover, which can cause subtle vertical reflow.

Proposal:

- Fix the scheduled timer.
- Replace engine identity UI checks with a `PlayerRole`.
- Keep volume behavior unless visual jitter is observed.

### `TrackHeaderView.swift`

Current strengths:

- Header is lightweight and visually consistent.
- Time label is cached to avoid excessive formatting.
- Artwork is explicitly excluded from gradient map.

Attention points:

- `ArtSwatchView` uses `DispatchQueue.global` rather than Swift concurrency.
- BPM refresh action triggers BPM-only deep analysis, not grid refresh.

Proposal:

- Keep UI as is.
- If touching artwork loading later, consider task-based cancellation by `trackId`.
- Make BPM refresh wording match actual behavior or upgrade deep analysis to refresh grid.

### `PlaylistView.swift`

Current strengths:

- Custom playlist scrolling, keyboard navigation, drag-to-Finder, split-pane drag, and summary footer are carefully handled.
- The `PlaylistCursorBox` solves stale SwiftUI closure capture in key monitors.
- Header BPM and Time are right-aligned now by `align: .trailing`.

Attention points:

- File is large and mixes many responsibilities.
- `RowDragNSView` installs local monitors per row. This is powerful but can be expensive with many visible rows.
- `PlaylistCursorBox` has unused read closures.
- Context menu and row overlay are intertwined with row rendering.

Proposal:

- Do not rewrite playlist behavior broadly.
- If cleaning, split into files by responsibility without changing behavior:
  - playlist pane
  - row rendering
  - row drag bridge
  - header/sort controls
  - footer/scrollbar

### `EQPanelView.swift`

Current strengths:

- EQ faders use block-fill controls matching the desired visual direction.
- XY pad visual no longer writes `@Published` state at 60 Hz for every curve update.
- Curve computation caches base EQ response.

Attention points:

- EQ preset application changes `eqBands` but does not directly call `audioEngine.setEQ` in `applyPreset`; this may depend on caller-side behavior.
- XY effect display and audio effect mapping must stay in sync.

Proposal:

- Verify all preset entry points call the engine after state changes.
- Keep display-only curve reads separate from audio side effects.

### `XYPadState.swift`

Current strengths:

- XY state is separated from `PlayerState`, reducing whole-tree updates.
- Active/axis/hold side effects are centralized in one binding setup.

Attention points:

- Uses Combine sinks despite project direction preferring async where practical.
- Axis switching resets several effects, which is correct, but future axes must be added in both display and audio mapping.

Proposal:

- Keep as is unless performance or lifecycle issues appear.
- If refactored later, preserve the separation from `PlayerState`.

### `PitchFaderView.swift`

Current strengths:

- Pitch rail is self-contained.
- BPM range and pitch fader paths are visually distinct.
- Master Tempo and range controls are clear.

Attention points:

- BPM range constants are local to the view while analysis floor/ceiling are settings-driven elsewhere.
- This may be intentional because BPM Fit and BPM Analysis are different features, but it should be documented.

Proposal:

- Add a comment clarifying that pitch BPM range is not the analysis BPM range.

### `PeekPanelView.swift`

Current strengths:

- Docked and peeking states have separate visual treatment.
- Drag gesture and file drop behavior are isolated.
- Spectrum/preview panel has been tuned visually.

Attention points:

- Visual widths are hardcoded and not clearly derived from `WindowSnapManager.tabVisible`.
- Docked NSWindow width can be `tabVisible`, while peek UI paints wider using overlay/offset mechanics.
- This is working but fragile.

Proposal:

- Document the geometry relationship between `snapTabWidth`, `peekVisible`, and `PeekPanelView` widths.
- If adjusted later, change the constants in one coordinated pass.

### `SplitModeManager.swift`

Current strengths:

- Snap and Clone Mode incompatibility is explicitly handled.
- Secondary audio operations are serialized on `audioOpQueue`.
- Secondary window uses same player level and collection behavior.

Attention points:

- Direct singleton access is concentrated here, which is acceptable for the split coordinator, but should not leak into views.
- Secondary state is manually copied field by field. New state fields can be missed.
- Deactivation stops secondary engine asynchronously after closing windows.

Proposal:

- Add a `PlayerState.copyRuntimeState(from:)` or similar helper if split mode grows.
- Keep secondary engine ownership inside `SplitModeManager`.

### `CrossfaderBandPanel.swift`

Current strengths:

- Crossfader panel is below player windows and has pass-through hit testing away from the bar.
- Geometry observers keep it positioned between players.

Attention points:

- `scrollWheel` ignores events unless `event.momentumPhase == .stationary`; this may drop ordinary wheel events depending on device.
- The hit radius is large by design but may capture unexpected scrolls near the gap.

Proposal:

- If scroll feels inconsistent, audit actual event phases on trackpad and mouse wheel.
- Keep the panel below player windows.

### `SettingsPanel.swift`

Current strengths:

- Settings panel is separate, nonactivating, and follows anchor window movement.
- It uses `GWindowLevel.floatingPanel`.

Attention points:

- Audio settings directly mutate `AudioEngineNext.shared` and `.secondary`.
- Display and snap settings are persisted through `PlayerState`, but some state fields are not.
- Version shown in Info is `0.4 BETA`, while curator brief says current beta is `0.7`.

Proposal:

- Route output-device changes through player/split coordinators rather than direct singleton calls from the view.
- Update version display as a separate tiny task if release labeling matters.

### `TooltipView.swift`

Current strengths:

- Tooltips and drag value bubbles are external panels, so they are not clipped by the player.
- Follow timer uses `.common` and `MainActor.assumeIsolated`.

Attention points:

- Tooltip panel and drag value panel duplicate panel setup logic.

Proposal:

- Not urgent. If cleaned, extract a small shared floating panel factory.

### `SpectrumView.swift`

Current strengths:

- Idle and playing states are blended.
- Peak decay is sharper now and visually intentional.
- Spectrum feed is isolated from PlayerState.

Attention points:

- UI spectrum quality depends on safe handoff from `AudioEngineNext`.
- Current display assumes `feed.data` count can be mapped into 24 visual columns.

Proposal:

- Keep the visual code.
- Fix any low-level handoff/race in the engine first.

### `AnalysisCache.swift`

Current strengths:

- Actor isolation is appropriate.
- Atomic write through temporary file is good.
- Cache key includes path, size, and modification date.

Attention points:

- Cache version must be bumped when analysis semantics change.
- `putBPM` can store BPM-only cache data, while combined analysis requires beat-grid confidence for BPM cache hits.

Proposal:

- Define cache payload policy:
  - waveform-only allowed
  - BPM-only allowed or deprecated
  - BPM plus grid required for analyzed state
- Bump cache version if beat-grid algorithm changes.

## Proposed Claude Task Blocks

**-> GITHUB ACTIONS TASK**

Push the following as a new GitHub Issue in `robvagin-beep/gone-player` with label `claude-task`, then trigger the `claude-review` workflow via `workflow_dispatch` or by commenting `@claude` on the issue.

## Task: Stabilize Waveform Grid and Drag Highlight

**Type:** Bug fix  
**Scope:** `GONE/GONE/WaveformView.swift`, optionally `GONE/GONE/Track.swift` if naming is clarified  
**Classification:** LOCAL

### Context
On some tracks the waveform/ruler appears to have a double grid. While scrubbing, grid ticks become bright in a way that looks like a visual bug. Current code globally brightens musical ticks during drag.

### Goal
Waveform grid should remain visually stable. Dragging should preview seek position without lighting every future musical tick.

### Implementation notes
Replace the global `isDragging` brightness rule for musical ticks. Future ticks should not become fully bright just because the user is dragging. If drag feedback is needed, apply it only up to `playheadX` or only to the playhead marker.

### Do NOT touch
- Audio graph node order
- `WindowSnapManager.swift`
- `windowResizability(.automatic)`
- `isMovableByWindowBackground = false`

### Acceptance criteria
- [ ] Scrubbing no longer brightens the entire musical grid.
- [ ] Already-played waveform/progress remains visible.
- [ ] Hot cue markers remain topmost.
- [ ] Fallback ruler still appears for tracks without beat-grid confidence.

**-> GITHUB ACTIONS TASK**

Push the following as a new GitHub Issue in `robvagin-beep/gone-player` with label `claude-task`, then trigger the `claude-review` workflow via `workflow_dispatch` or by commenting `@claude` on the issue.

## Task: Consolidate BPM, Waveform, and Beat-Grid Scheduling

**Type:** Refactor  
**Scope:** `GONE/GONE/PlayerState+Analysis.swift`, `GONE/GONE/PlayerState+Playlists.swift`, `GONE/GONE/LibraryScanner.swift`, `GONE/GONE/AnalysisCache.swift`  
**Classification:** GITHUB

### Context
The project has a combined BPM plus waveform analyzer, but standalone waveform computation can still run in parallel with BPM analysis. Comments say competing `AVAssetReader` work can freeze or stutter the UI.

### Goal
Make analysis scheduling single-owner and predictable. Avoid duplicate decodes for the same track and allow cancellation/prioritization.

### Implementation notes
Store task handles for BPM and waveform jobs. If auto BPM is enabled, combined analysis owns waveform and beat-grid generation. Standalone waveform should only run when BPM analysis is disabled, failed, cached incompletely, or explicitly requested.

### Do NOT touch
- Audio graph node order
- Playback engine scheduling unless strictly necessary
- `PlaybackProgressFeed.shared.reset()`

### Acceptance criteria
- [ ] Import does not start competing BPM and waveform readers for the same file.
- [ ] Track deletion or reimport can cancel obsolete analysis work.
- [ ] Current track still gets first priority.
- [ ] Cache hits still avoid decode.

**-> GITHUB ACTIONS TASK**

Push the following as a new GitHub Issue in `robvagin-beep/gone-player` with label `claude-task`, then trigger the `claude-review` workflow via `workflow_dispatch` or by commenting `@claude` on the issue.

## Task: Clarify Beat Grid vs Bar Grid Semantics

**Type:** Bug fix / Refactor  
**Scope:** `GONE/GONE/LibraryScanner.swift`, `GONE/GONE/WaveformView.swift`, `GONE/GONE/Track.swift`, `GONE/GONE/AnalysisCache.swift`  
**Classification:** GITHUB

### Context
The analyzer estimates beat phase, but the UI promotes that into bar and 4-bar ticks. On steady house tracks this can look asymmetric if the beat phase is correct but the downbeat phase is unknown.

### Goal
Avoid presenting beat-phase data as reliable bar/downbeat data unless downbeat confidence exists.

### Implementation notes
Either rename/limit the visual output to beat-grid semantics, or add a separate downbeat/bar-grid field with confidence. Do not fake 4-bar anchors from beat phase unless the product accepts them as approximate visual structure.

### Do NOT touch
- Audio graph node order
- `WindowSnapManager.swift`
- Existing cache format without version consideration

### Acceptance criteria
- [ ] Beat ticks remain correctly positioned by BPM and beat phase.
- [ ] Bar or 4-bar ticks are either clearly approximate or backed by separate confidence.
- [ ] Cache version is bumped if stored analysis semantics change.

**-> GITHUB ACTIONS TASK**

Push the following as a new GitHub Issue in `robvagin-beep/gone-player` with label `claude-task`, then trigger the `claude-review` workflow via `workflow_dispatch` or by commenting `@claude` on the issue.

## Task: Audit Window Presence Policy and Always-On-Top State

**Type:** Refactor  
**Scope:** `GONE/GONE/GONEApp.swift`, `GONE/GONE/PlayerState.swift`, `GONE/GONE/SettingsPanel.swift`, `GONE/GONE/UIHelpers.swift`  
**Classification:** GITHUB

### Context
The app currently applies `GWindowLevel.player` unconditionally, while `PlayerState.alwaysOnTop` is persisted as if it were a setting.

### Goal
Make window presence policy explicit and non-contradictory.

### Implementation notes
Decide whether GONE is always topmost by design. If yes, remove or hide dead setting state. If no, make `applyPresencePolicy` conditional while preserving snap behavior and all-Spaces behavior.

### Do NOT touch
- `windowResizability(.automatic)`
- `isMovableByWindowBackground = false`
- `WindowSnapManager.swift` transition order unless fully audited

### Acceptance criteria
- [ ] No persisted setting suggests behavior that is ignored.
- [ ] Snap mode still appears over other windows and full-screen spaces.
- [ ] Normal mode behavior is documented and predictable.

**-> GITHUB ACTIONS TASK**

Push the following as a new GitHub Issue in `robvagin-beep/gone-player` with label `claude-task`, then trigger the `claude-review` workflow via `workflow_dispatch` or by commenting `@claude` on the issue.

## Task: Replace Audio Singleton Checks in Views with Player Role

**Type:** Refactor  
**Scope:** `GONE/GONE/PlayerState.swift`, `GONE/GONE/SplitModeManager.swift`, `GONE/GONE/FullPlayerView.swift`, `GONE/GONE/TransportView.swift`, `GONE/GONE/SettingsPanel.swift`  
**Classification:** GITHUB

### Context
Some views compare `state.audioEngine` against `AudioEngineNext.secondary` or directly call `AudioEngineNext.shared`. This violates the intended boundary where views should use `state.audioEngine`.

### Goal
Make primary/secondary UI behavior explicit without singleton identity checks in views.

### Implementation notes
Add a simple player role to `PlayerState`, for example `.primary` and `.secondary`. Use role for settings visibility and empty overlay behavior. Keep secondary engine ownership inside `SplitModeManager`.

### Do NOT touch
- Audio graph node order
- Split Mode crossfader gain law
- `WindowSnapManager.swift`

### Acceptance criteria
- [ ] Views no longer need to compare against `AudioEngineNext.secondary`.
- [ ] Primary player still shows Settings.
- [ ] Secondary player still hides Settings.
- [ ] Split Mode playback remains independent.

**-> GITHUB ACTIONS TASK**

Push the following as a new GitHub Issue in `robvagin-beep/gone-player` with label `claude-task`, then trigger the `claude-review` workflow via `workflow_dispatch` or by commenting `@claude` on the issue.

## Task: Fix Timer Rule Violations

**Type:** Bug fix  
**Scope:** `GONE/GONE/TransportView.swift`, audit-only pass across timer sites  
**Classification:** LOCAL

### Context
Curator rules require timers to be created manually and added to `.common`. `ClickNSView` currently uses `Timer.scheduledTimer`.

### Goal
All timers should follow the same run-loop behavior.

### Implementation notes
Replace `Timer.scheduledTimer` with `Timer(timeInterval:repeats:block:)` and add it with `RunLoop.main.add(timer, forMode: .common)`. Keep callback actor isolation.

### Do NOT touch
- Hold-seek behavior
- Snap state machine
- Audio graph

### Acceptance criteria
- [ ] No `Timer.scheduledTimer` remains.
- [ ] Single/double click behavior on the snap button remains responsive.
- [ ] Timer callback still uses `MainActor.assumeIsolated`.

**-> GITHUB ACTIONS TASK**

Push the following as a new GitHub Issue in `robvagin-beep/gone-player` with label `claude-task`, then trigger the `claude-review` workflow via `workflow_dispatch` or by commenting `@claude` on the issue.

## Task: Make Spectrum Tap Handoff Thread-Safe

**Type:** Bug fix / Performance  
**Scope:** `GONE/GONE/GONE/AudioEngine.next.swift`, `GONE/GONE/SpectrumFeed.swift`, `GONE/GONE/SpectrumView.swift` only if API shape changes  
**Classification:** GITHUB

### Context
The spectrum tap tries to avoid allocations on the render thread, which is correct, but the current shared-buffer handoff can allow the render callback and processing queue to touch the same sample storage.

### Goal
Keep render-thread work allocation-free while making the handoff safe.

### Implementation notes
Use a preallocated double buffer or small ring buffer. The tap writes to one buffer and publishes an immutable snapshot index. The spectrum queue reads only committed buffers. Do not run FFT on the render thread.

### Do NOT touch
- Audio graph node order
- Playback chunk scheduling unless required for tap lifecycle
- Spectrum visual design

### Acceptance criteria
- [ ] No allocations are added to the render callback.
- [ ] Spectrum queue does not read a buffer being mutated by the tap.
- [ ] Spectrum animation remains responsive.

## Final Recommendation Order

1. Fix `WaveformView` drag glow and double-grid visual priority first because it matches the current user-observed bug.
2. Consolidate analysis scheduling next because it affects BPM, waveform, beat-grid correctness, and import smoothness.
3. Clarify beat-grid vs bar-grid semantics before making the ruler more visually authoritative.
4. Clean window presence and singleton role boundaries after the visual/audio correctness issues.
5. Fix timer rule violation as a small safe task.
6. Address spectrum tap handoff as a performance/safety task, not a visual redesign.

