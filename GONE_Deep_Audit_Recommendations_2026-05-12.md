# GONE Deep Systems Audit Recommendations

Date: 2026-05-12
Scope: current local codebase under `/Users/robertvagin/Desktop/GONE`
Mode: audit only. This document contains recommendations and suspected weak points. It does not describe code that was changed.

This audit follows `GONE_CURATOR.md`: no new product features, no external dependencies, no replacement of the snap state machine, no audio graph reorder, and no changes to `windowResizability(.automatic)` or `isMovableByWindowBackground = false`.

## Executive Summary

The current build has a coherent architecture: `PlayerState` owns user-facing state, `AudioEngineNext` owns playback/DSP, `LibraryScanner` owns metadata/BPM/waveform analysis, `WindowSnapManager` owns edge hiding, and `SplitModeManager` creates a second player without reusing the primary engine. The most fragile areas are not visual polish; they are timing, duplicated analysis lanes, beat-grid semantics, and state/lifecycle edges during clone/snap/import/restart.

Highest-priority areas to review before more UI work:

- BPM and beat-grid analysis may be internally consistent as "beat phase", but the UI treats it as "bar/quarter structure". That can create asymmetric-looking bars on house tracks even when BPM is correct.
- Import completion starts both BPM+waveform analysis and standalone waveform analysis. The code comments warn that competing `AVAssetReader`s can freeze UI, but the current import tail still allows overlapping readers.
- Deep BPM refresh updates BPM only. It does not recompute waveform or beat-grid offset/confidence, so the user can fix BPM while leaving a stale grid.
- Waveform grid highlighting uses `played || isDragging`, which explains why musical ticks can brighten during scrubbing.
- Analysis tasks are `Task.detached` without cancellation handles. Track deletion, reimport, app termination, or current-track changes rely on final ID checks rather than explicit cancellation.
- `AudioEngineNext` progress timer uses `.common`, but its callback does not use `MainActor.assumeIsolated`, unlike the project rule and most other timers.
- Spectrum tap handoff likely has a race risk: render thread writes `tapSampleBuffer`, while `spectrumQueue` later copies from the same shared array.
- Clone mode correctly prevents snap conflicts, but it mirrors only selected `PlayerState` fields. Some settings/session fields may intentionally stay independent; this needs explicit classification so future fields do not silently diverge.
- Several click-zone systems use local/global event monitors. They are mostly deliberate, but need a dedicated monitor ownership audit because stuck monitors can produce "button does not click" or "window steals click" symptoms.

## Curator Rules That Are Directly Relevant

Do not touch these unless the task explicitly requires it and the full file is read first:

- `AudioEngineNext` graph order must remain `playerNode -> speedNode -> pitchNode -> hpfNode -> lpfNode -> eqNode -> distortionNode -> delayNode -> reverbNode -> gateNode -> mainMixerNode`.
- `WindowSnapManager.swift` sequence is load-bearing. Any snap fix must start with full-file review.
- Views/extensions should use `state.audioEngine`; do not introduce direct `AudioEngineNext.shared` calls in views.
- Timers should be created with `Timer(timeInterval:)` and installed via `RunLoop.main.add(timer, forMode: .common)`.
- Timer callbacks should use `MainActor.assumeIsolated`.
- `updateWindowSize` should remain centralized in `RootView`.
- Use `state.progressFeed.reset()`, not `PlaybackProgressFeed.shared.reset()`, inside `PlayerState` extensions.

## System Map

### Main app and window

- `GONEApp.swift` creates `RootView`, injects `PlayerState`, configures a borderless nonactivating window, applies `GWindowLevel.player`, and sets all-spaces collection behavior.
- `RootView.swift` owns shell size, display scale, drag overlays, drop handling, snap overlay, and `updateWindowSize`.
- `WindowSnapManager.swift` owns `off/waiting/docked/peeking/expanded`.
- `PeekPanelView.swift` owns the edge HUD while docked/peeking.

### Playback and analysis

- `PlayerState.swift` is the main state object.
- `PlayerState+Playback.swift` routes load/play/next/previous through `state.audioEngine`.
- `AudioEngine.next.swift` owns AVAudioEngine graph, seek, schedule, progress, spectrum, EQ, pitch, and hold-seek.
- `LibraryScanner.swift` reads metadata, artwork fallback, waveform, BPM, and beat phase.
- `PlayerState+Analysis.swift` schedules BPM+waveform and standalone waveform computation.
- `AnalysisCache.swift` stores BPM/waveform/beat-grid values.

### UI modules

- `FullPlayerView.swift` composes header, ruler, transport, pitch fader, EQ, playlist.
- `TrackHeaderView.swift` displays artwork, metadata, BPM badge, spectrum, time.
- `WaveformView.swift` draws waveform, ruler ticks, musical grid, hot cues, and handles seek.
- `TransportView.swift` owns snap/list/EQ/settings, transport buttons, volume.
- `PlaylistView.swift` owns list rendering, custom scrolling, row drag, Finder drag, keyboard navigation.
- `EQPanelView.swift`, `XYPadState.swift`, `SpectrumView.swift`, `PitchFaderView.swift` own DSP controls and visual feedback.

### Clone mode

- `SplitModeManager.swift` disables snap, creates secondary `PlayerState(engine: .secondary)`, wires callbacks, creates secondary `NSWindow`, and creates `CrossfaderGapWindow`.
- `ClonePlayerShell.swift` mirrors player shell behavior without primary-window snap/drop side effects.
- `CrossfaderBandPanel.swift` owns visual and interactive crossfader panel between windows.

## Findings And Recommendations

### 1. BPM Analyzer And Beat Grid

#### Finding: beat phase is being treated as bar/downbeat structure

Evidence:

- `LibraryScanner.estimateBeatGridOffset` scans phase candidates inside one beat duration and returns a beat offset.
- `WaveformView.ProgressRuler` then derives `barI = beatI / meterBeatsPerBar` and marks `barI % 4 == 0` as `.fourBar`.

Why this is questionable:

- Beat phase answers "where is the beat pulse?"
- Bar/downbeat answers "which beat is beat 1 of the bar?"
- Phrase/four-bar anchor answers "which bar is bar 1 of the phrase?"
- The current code appears to infer bar and four-bar anchors from whichever beat phase was strongest. On house tracks with steady kicks, any kick can win, so the displayed bar/four-bar ticks can look asymmetric or musically shifted.

Recommendation:

- Treat the current `beatGridOffset` as `beatPhaseOffset`, not as bar/downbeat truth.
- Add a separate downbeat/bar-phase confidence if the UI wants tall quarter/bar markers.
- Until downbeat exists, keep beat micro-ticks exact, but avoid presenting `.fourBar` as authoritative.
- Consider a safe visual mode: if only beat phase is known, show uniform beat ticks and neutral track-quarter anchors; reserve tall musical bars for higher-confidence downbeat logic.

Claude task hint:

```md
## Task: Separate beat phase from bar/downbeat rendering

Type: Bug fix / Refactor
Scope: LibraryScanner.swift, WaveformView.swift, Track.swift, AnalysisCache.swift
Classification: GITHUB

Context:
The analyzer currently estimates beat phase, but the waveform ruler renders this as bar and four-bar structure. This can make steady house tracks show asymmetric or shifted "quarter" markers.

Goal:
Keep BPM/beat phase useful, but stop implying bar/downbeat confidence unless the analyzer actually computes it.

Implementation notes:
Introduce naming or metadata that distinguishes beat phase from bar phase. In WaveformView, render beat ticks from beat phase and render tall bar/four-bar ticks only when a real downbeat confidence exists, or use neutral structural anchors as fallback.

Do NOT touch:
Audio graph node order, WindowSnapManager, windowResizability(.automatic), isMovableByWindowBackground.

Acceptance criteria:
- [ ] A 120 BPM house track displays evenly spaced beat ticks.
- [ ] Tall bar/four-bar marks are not shown as authoritative unless downbeat confidence exists.
- [ ] Existing cached BPM/waveform values remain readable or are versioned safely.
```

#### Finding: deep BPM refresh does not refresh grid

Evidence:

- `PlayerState+Analysis.reanalyzeBPMDeep` calls `LibraryScanner().analyzeBPMDeep`.
- It updates only `tracks[i].bpm` and `bpmAnalysisState`.
- It does not update `beatGridOffset`, `beatGridConfidence`, or waveform.

Why this matters:

- The BPM badge says refresh/deep analysis.
- If the user refreshes because the ruler/grid looks wrong, the grid can remain stale.
- If BPM changes, old `beatGridOffset` is mathematically tied to the previous BPM and may no longer be valid.

Recommendation:

- Either make deep refresh run the combined analyzer (`analyzeBPMWithWaveform`) with deep options, or clear `beatGridConfidence` after BPM-only deep refresh so the UI does not show stale grid.
- Prefer one deep pipeline that returns BPM + waveform + grid metadata in one decode pass.

#### Finding: standard and deep BPM logic are duplicated

Evidence:

- `computeBPMFromSamples` exists for combined analysis.
- `analyzeBPM` repeats similar autocorrelation logic.
- `analyzeBPMDeep` repeats a third variant with different thresholds/windowing.

Why this matters:

- Half-tempo correction thresholds differ: standard/combined use 0.82, deep comments say 0.60.
- Future fixes can land in one path and not the other.
- User-facing "why is this track different after refresh?" becomes harder to reason about.

Recommendation:

- Extract one tempo candidate/scoring core:
  - input: sample window, floor, ceiling, correction policy
  - output: BPM, score, lag, confidence candidates
- Keep standard/deep as policy wrappers, not separate algorithms.

#### Finding: BPM cache versioning is correct in principle, but analyzer semantics may require a version bump

Evidence:

- `AnalysisCache.version = 6`.
- Cache stores `bpm`, `waveform`, `beatGridOffset`, `beatGridConfidence`.

Why this matters:

- If beat-grid meaning changes from "beat phase" to "downbeat/bar phase", old cached values become semantically wrong.

Recommendation:

- Any change to BPM, waveform shape, beat-grid offset meaning, or confidence threshold should bump `AnalysisCache.version`.

### 2. Waveform And Ruler Visualization

#### Finding: scrub/drag currently brightens all musical ticks

Evidence:

- In `WaveformView`, musical ticks use `let animT: CGFloat = played || isDragging ? 1 : 0`.

Why this matters:

- During seek drag, unplayed future musical ticks become bright.
- This matches the observed issue: grid lines can "light up" while scrubbing.

Recommendation:

- For musical ticks, use `played ? 1 : 0` during drag, same as fallback structural ticks.
- If drag needs feedback, highlight only the playhead/played region, not every tick.

#### Finding: analyzed and fallback grid modes are not visually explicit

Evidence:

- If `beatGridConfidence >= 0.60`, fallback structural/interstitial marks are disabled and musical ticks are drawn.
- If confidence is lower, fallback structural/interstitial marks are drawn over waveform.

Why this matters:

- Tracks with low confidence can look like they have a different/double grid.
- Tracks with high confidence can show beat ticks plus waveform peaks, which visually reads like two systems if the grid is shifted.

Recommendation:

- Add an internal display mode decision:
  - `fallbackStructural`
  - `beatPhaseOnly`
  - `downbeatGrid`
- Render each mode with distinct hierarchy so the user can tell if it is analyzer truth or fallback ruler texture.

#### Finding: `isAnalyzingBeatGrid` is passed but not rendered

Evidence:

- `ProgressRuler` receives `isAnalyzingBeatGrid`.
- It is not used in drawing.

Why this matters:

- The UI cannot distinguish "grid absent because analysis pending" from "grid absent because confidence failed".

Recommendation:

- Either remove the parameter or use it for a subtle pending state. If using it, do not add noise; a low-opacity scanning tick or disabled ruler state is enough.

#### Finding: waveform bars are 84 everywhere

Evidence:

- `analyzeBPMWithWaveform(... waveformBars: 84)`.
- Standalone waveform also computes `bars: 84`.

Why this matters:

- 84 bars is visually tuned to the current compact player. It may not scale if window scale, future width, or clone shell changes.

Recommendation:

- Keep 84 for current UI, but document it as a visual resolution contract, not an audio-analysis resolution.
- If future layout width changes, compute waveform display sampling separately from cached analysis waveform.

### 3. Analysis Scheduling, Freezes, And Crash Resistance

#### Finding: import tail can start competing analysis lanes

Evidence:

- After import finishes, `PlayerState+Playlists.importURLs` calls:
  - `scheduleBPMAnalysis()` when `autoBPMOnImport` is true
  - `scheduleWaveformComputation()` unconditionally
- `scheduleBPMAnalysis` uses `analyzeBPMWithWaveform`, which already computes waveform.
- `scheduleWaveformComputation` can start separate `AVAssetReader`s.

Why this matters:

- The code comments explicitly warn that competing `AVAssetReader`s freeze UI.
- The implementation still allows BPM+waveform and standalone waveform to overlap after import.

Recommendation:

- Make combined BPM+waveform the primary path for tracks that need BPM.
- Start standalone waveform only for tracks that already have BPM and are not pending/analyzing BPM.
- Alternatively, use a single `AnalysisScheduler` actor/queue that serializes per-file reads and deduplicates work by URL.

Claude task hint:

```md
## Task: Deduplicate BPM and waveform analysis scheduling

Type: Bug fix
Scope: PlayerState+Analysis.swift, PlayerState+Playlists.swift
Classification: GITHUB

Context:
Import completion currently schedules BPM analysis and waveform computation. BPM analysis already computes waveform, so the standalone waveform lane can compete for AVAssetReader access and cause stutter/freezes.

Goal:
Ensure each audio file has at most one active decode/reader job at a time.

Implementation notes:
Centralize analysis scheduling around job types: bpmAndWaveform, waveformOnly. A track pending BPM should not enter waveformOnly. Waveform-only should run only for tracks with trusted BPM/cache or when autoBPM is off.

Do NOT touch:
Audio graph node order, WindowSnapManager, RootView.updateWindowSize.

Acceptance criteria:
- [ ] Importing a folder does not start simultaneous BPM and waveform readers for the same URL.
- [ ] Current track still gets first-priority BPM/waveform.
- [ ] Tracks with cached BPM+waveform do not decode again.
```

#### Finding: no cancellation handles for detached analysis tasks

Evidence:

- `scheduleBPMAnalysis`, `scheduleWaveformComputation`, and `reanalyzeBPMDeep` use `Task.detached`.
- There are no stored task handles.

Why this matters:

- Deleting tracks, reimporting, quitting, switching clone mode, or changing current track cannot cancel in-flight work.
- ID guards prevent some bad commits, but CPU/I/O still continues.

Recommendation:

- Store task handles in `PlayerState`, or move scheduling into an `actor AnalysisScheduler`.
- Add cancellation points between batches and before committing.
- On app termination or library clear, cancel analysis before waiting for cache flush.

#### Finding: analysis concurrency is capped, but waveform-only lane uses wider concurrency than BPM lane

Evidence:

- BPM batch concurrency is `min(2, analysisConcurrency)`.
- Standalone waveform uses `Self.analysisConcurrency` up to 8.

Why this matters:

- Waveform-only can still become I/O aggressive.
- This can matter on external drives, network volumes, or when playback is active.

Recommendation:

- Use the same I/O policy for all `AVAssetReader` jobs.
- Consider dynamic concurrency:
  - current track: 1
  - playback active: 1 or 2
  - idle/background: 2-4

#### Finding: combined analyzer stores full-track samples in memory

Evidence:

- `LibraryScanner.analyzeBPMWithWaveform` appends decoded samples to `allSamples`.
- It reserves at most 1200s capacity, but does not cap appended samples.

Why this matters:

- Long mixes, AIFF/WAV, or multiple background analyses can allocate large arrays.
- Memory pressure can cause UI hitches or app termination.

Recommendation:

- Stream waveform buckets and BPM window separately.
- Keep only the 30-60s BPM window needed for tempo/grid, plus rolling waveform buckets.
- Avoid storing full decoded track when only 84 waveform bars and a BPM slice are needed.

### 4. AudioEngineNext Playback Core

#### Finding: graph order currently matches the curator rule

Evidence:

- Nodes are declared and graph comments indicate the fixed chain:
  `playerNode -> speedNode -> pitchNode -> hpfNode -> lpfNode -> eqNode -> distortionNode -> delayNode -> reverbNode -> gateNode -> mainMixerNode`.

Recommendation:

- Do not reorder. If a future issue concerns EQ/pitch/filter behavior, debug parameter mapping first, not graph order.

#### Finding: first PCM chunk is scheduled synchronously

Evidence:

- `scheduleFrom` uses `bufferQueue.sync` for the first chunk.

Why this matters:

- This guarantees PCM is ready before play, but a slow disk read can block the caller.
- If called from main during load/seek, this can feel like a UI freeze.

Recommendation:

- Keep the correctness goal, but investigate an async pre-roll path:
  - set scheduling state
  - enqueue first chunk
  - start play after first chunk callback or completion
- Do this only with a careful playback regression test; the current sync behavior is simple and reliable.

#### Finding: progress timer callback does not use `MainActor.assumeIsolated`

Evidence:

- `startProgressTimer` creates `Timer(timeInterval:)`, adds it to `.common`, but callback is `self?.tickProgress()`.

Why this matters:

- Project rule says timer callbacks should use `MainActor.assumeIsolated`.
- Other timers follow that rule.

Recommendation:

- Align progress timer with the same timer pattern used in `PlayerState` and `WindowSnapManager`.

#### Finding: spectrum tap buffer handoff may race

Evidence:

- Render tap writes into `tapSampleBuffer`.
- `spectrumQueue.async` later reads `let samples = self.tapSampleBuffer`.

Why this matters:

- The render thread may mutate the shared buffer again before the spectrum queue copies it.
- It may produce visual glitches, and it is risky because one thread writes while another reads the same Swift array storage.

Recommendation:

- Use double buffering or a lock-free ring buffer for sample snapshots.
- Keep render-thread work allocation-free.
- Copy into a preallocated queue-owned buffer before FFT.

### 5. Window Snap, Peek, And Always-On-Top

#### Finding: always-on-top setting is persisted but not functionally conditional

Evidence:

- `PlayerState.alwaysOnTop` is persisted.
- `AppDelegate.applyPresencePolicy` always sets `window.level = GWindowLevel.player`.
- `setAlwaysOnTop` updates state and reapplies the same policy.

Why this matters:

- The setting behaves like a stored label, not a switch.
- This may be intentional after the decision to keep the player above all windows, but the code name suggests a toggle.

Recommendation:

- Either classify `alwaysOnTop` as always-on invariant and remove/disable the UI switch, or make the setting truly affect level.
- Given current product direction, prefer treating topmost as invariant and avoid exposing a fake toggle.

#### Finding: app activation expands docked/peeking snap state

Evidence:

- `applicationDidBecomeActive` calls `snap.expandCurrentWindow()` if snap state is `.docked` or `.peeking`.

Why this matters:

- Cmd-Tab/app activation can override the hidden edge state.
- If user expects docked state to remain hidden across Spaces/app switching, this is a policy conflict.

Recommendation:

- Decide explicitly:
  - App activation expands if user intentionally switches to GONE.
  - Space switch / app focus should not expand if cursor did not approach the tab.
- If changing, handle only intentional foreground activation, not every focus event.

#### Finding: snap and clone are intentionally incompatible

Evidence:

- `SplitModeManager.activate` disables snap and remembers `snapWasEnabled`.
- `deactivate` restores snap if it was enabled.

Recommendation:

- Keep this policy. Do not try to support docked snap while clone mode is active unless the whole snap/clone state machine is redesigned.

#### Finding: peek panel has separate hit zones for docked and peeking states

Evidence:

- Docked: the full panel can tap/drag.
- Peeking: only an 18px left strip gets the vertical drag gesture; content taps expand or use controls.

Why this matters:

- This is correct for avoiding button/drag conflicts, but it is fragile if panel width or offset changes.

Recommendation:

- Add a small internal hit-zone map comment or debug overlay mode before future UI tuning.
- Any visual width change in `PeekPanelView` should be reviewed against `WindowSnapManager.tabVisible`, `peekVisible`, and drag strip width.

### 6. Clone Mode And Crossfader

#### Finding: clone environment injection is currently handled by `FullPlayerView`

Evidence:

- `SplitModeManager` injects only `PlayerState`.
- `FullPlayerView` injects `state.analysisFeed` and `state.xyPad` into relevant subtrees.

Conclusion:

- Missing `AnalysisProgressFeed` / `XYPadState` environment objects are not an active issue in the current structure.
- This should be rechecked if `TrackHeaderView` or `EQPanelView` are ever used outside `FullPlayerView`.

#### Finding: clone state mirroring is partial

Evidence:

- `SplitModeManager.makeSecondWindow` copies playlist/navigation, transport, pitch, and EQ/DSP fields.
- It does not copy every `PlayerState` field.

Why this matters:

- Some fields should be independent per deck.
- Some fields should probably mirror global settings.
- Without an explicit list, new state fields may silently be forgotten.

Recommendation:

- Add a clone-state policy table in code or docs:
  - per-deck: currentId, isPlaying, progress, hotCues, pitch, EQ?
  - shared/global: windowScale, gradient map, output device, analysis settings?
  - disabled in clone: snap, settings panel, import UX?
- Use this table when adding any new `PlayerState` property.

#### Finding: secondary engine teardown is carefully guarded, but still worth stress testing

Evidence:

- `deactivate` clears callbacks, calls `markStopped`, closes windows, then stops secondary on `audioOpQueue`.
- Comments mention avoiding Core Audio lock deadlock.

Recommendation:

- Create a manual crash-test checklist:
  - activate clone while playing
  - deactivate while playing
  - change output device while clone active
  - activate/deactivate repeatedly
  - close primary window while clone active
  - close secondary window while clone active

#### Finding: crossfader scroll may ignore common wheel events

Evidence:

- `BandHitTestView.scrollWheel` returns unless `event.momentumPhase == .stationary`.

Why this is questionable:

- On some devices, normal scroll events may have `.none` instead of `.stationary`.
- If so, scroll-to-crossfade can silently fail.

Recommendation:

- Verify event phases on trackpad and mouse wheel.
- Accept `.stationary` and `.none` if testing confirms `.none` is normal non-momentum input.

### 7. Click Zones, Event Monitors, And Interaction Conflicts

#### Finding: one timer still uses `Timer.scheduledTimer`

Evidence:

- `TransportView.ClickNSView` uses `Timer.scheduledTimer`.

Why this matters:

- Curator rule says timers should use `RunLoop.main.add(timer, forMode: .common)`.
- `scheduledTimer` defaults to default run loop mode and can behave differently during tracking/dragging.

Recommendation:

- Convert it to the house timer pattern if snap-button click behavior becomes flaky.

#### Finding: local/global monitor ownership needs a dedicated pass

Evidence:

- `GONEApp` key monitor.
- `WindowSnapManager` activity/global click/space/proximity monitors.
- `SettingsPanel` local/global outside-click monitors.
- `PlaylistView` keyboard and row drag monitors.
- `TooltipView` follow timer/panels.

Why this matters:

- Multiple monitors can create symptoms that look unrelated: clicks swallowed, ESC intercepted, drag state stuck, snap timer reset unexpectedly.

Recommendation:

- Make a monitor inventory table:
  - owner
  - event type
  - install trigger
  - remove trigger
  - whether it returns nil/event
  - whether it should run during snap/clone/import/settings
- This is analysis-only first; do not refactor monitors blindly.

#### Finding: playlist row drag uses per-row NSView monitors

Evidence:

- `RowDragNSView` installs local monitors for mouse down/up/drag.
- It is likely safe because `LazyVStack` keeps visible rows limited.

Why this matters:

- Still worth stress testing with many tracks, split view, and resize.

Recommendation:

- Verify monitors are removed when rows leave window.
- If future bugs appear, consolidate row drag into one playlist-level coordinator rather than per-row monitors.

### 8. Restart, Persistence, And Recovery

#### Finding: settings persistence is broad but not complete

Evidence:

- `PlayerState.loadPersistedSettings`/`persistSettings` handle volume, pitchRange, masterTempo, repeat, windowScale, gradient, BPM range, import behavior, snap, debug, magnify.
- `bpmCacheEnabled` and `bpmCacheFolder` exist in state but are not loaded/saved here.

Why this matters:

- UI may expose settings that do not persist, or future code may assume these are functional.

Recommendation:

- Either wire these fields into persistence/cache behavior or remove/hide them until used.

#### Finding: `windowScale` is saved twice

Evidence:

- `persistSettings` sets `windowScale`, then later sets `isMagnified ? magnifyBaseScale : windowScale` for the same key.

Why this matters:

- The second write is probably intentional to avoid persisting magnified override.
- The first write is redundant and can confuse future readers.

Recommendation:

- Keep the base-scale behavior, but make the code single-write and explicit.

#### Finding: BPM ceiling default and fallback differ

Evidence:

- Default `bpmAnalysisCeiling` is 200.
- Invalid persisted fallback resets to 180.

Why this matters:

- A corrupted/default migration can silently change analysis range.

Recommendation:

- Use one canonical default.

#### Finding: app termination blocks up to 2 seconds for cache flush

Evidence:

- `applicationWillTerminate` waits on a semaphore for `AnalysisCache.shared.flushNow()`.

Why this matters:

- It protects cache writes but can delay quit.
- If analysis tasks keep touching cache at shutdown, flush order can still be ambiguous.

Recommendation:

- If cancellation handles are added, cancel analysis first, then flush cache once.

### 9. UI Rendering And Performance

#### Finding: artwork loading uses GCD inside `.task`

Evidence:

- `ArtSwatchView.task(id:)` increments generation and uses `DispatchQueue.global` then `DispatchQueue.main`.

Why this matters:

- It works and has generation protection.
- It is not cancellable in the Swift concurrency sense, so fast scrolling/track switching can still do unnecessary work.

Recommendation:

- Not urgent. If artwork becomes a performance issue, convert `ArtworkCache.image` access to async and let `.task(id:)` cancellation do real cancellation.

#### Finding: spectrum rendering has idle animation and real audio feed separation

Evidence:

- `SpectrumView`/`PeekPanelView.PixelSpectrumView` keep display animation independent from audio engine state.

Recommendation:

- Preserve this. Any future spectrum tuning should be visual-only unless changing the actual tap pipeline.

#### Finding: `VolumeSlider` hover height can cause small layout shifts

Evidence:

- Volume body height changes between normal and hover.

Why this matters:

- In a tightly tuned mini-player, even 1-2 px can create perceived jitter.

Recommendation:

- If users report transport row jitter, keep outer hit frame constant and animate only fill/brightness.

### 10. Settings And Global Panels

#### Finding: SettingsPanel uses direct singleton engine references by design

Evidence:

- Settings output-device logic references `AudioEngineNext.shared` and `.secondary`.

Why this matters:

- Curator rule mainly forbids `.shared` in Views/Extensions where `state.audioEngine` should be used.
- Settings is a global panel controlling devices for both engines, so direct references may be justified.

Recommendation:

- Document this exception in the file if it remains.

#### Finding: settings panel outside-click monitors are another monitor owner

Recommendation:

- Include SettingsPanel in the monitor ownership audit.
- Verify panel close during drag and clone mode.

## Crash-Test Matrix

Use this matrix before declaring the current build stable. It is not a request to implement tests immediately; it is a checklist of risky interactions discovered by code review.

### Analysis / import

- Import 200+ tracks from internal SSD, then external drive.
- Start playback while analysis is running.
- Reanalyze BPM while a track is playing.
- Delete/move a track while it is analyzing.
- Quit app while analysis is running.
- Relaunch and verify cached BPM/waveform/grid values.

### Waveform / seek

- Drag seek across analyzed track; future grid ticks should not all brighten.
- Drag seek across fallback/non-analyzed track; only played side should brighten.
- Check a steady 120 BPM house track; beat ticks should be even.
- Check a track with silence intro; first visible grid should not imply false downbeat.
- Check long 10+ minute tracks for memory and UI smoothness.

### Snap / peek

- Enable snap, wait for dock.
- Hover to peek, click to expand.
- Drag peek vertically.
- Double-click bolt to dock immediately.
- Import while docked/peeking.
- Switch macOS Spaces while docked/peeking.
- Activate app from Dock/Cmd-Tab while docked/peeking.

### Clone mode

- Activate clone while playing.
- Deactivate clone while both players are playing.
- Change output device during clone.
- Close secondary window.
- Close primary window.
- Toggle EQ/playlist before clone activation and verify clone layout.
- Check hot cue keys 1-4 primary and 5-8 secondary.

### Click zones

- Snap button single click vs double click.
- Hold previous/next short tap vs long hold.
- Playlist row drag vs row selection.
- Finder drag export vs internal row drag.
- Split playlist cross-pane drag copy/move.
- Crossfader drag and scroll input.
- Settings panel outside click close.

## Proposed Claude Review Issues

These are scoped as review/implementation tasks, not feature requests.

### Issue 1: Analysis scheduler deduplication

Goal: prevent competing `AVAssetReader` jobs and centralize BPM/waveform job ownership.

Likely files:

- `PlayerState+Analysis.swift`
- `PlayerState+Playlists.swift`
- `AnalysisCache.swift`
- `LibraryScanner.swift`

Do not touch:

- `AudioEngine.next.swift` graph order
- `WindowSnapManager.swift`
- `RootView.updateWindowSize`

### Issue 2: Beat-grid semantics cleanup

Goal: separate BPM, beat phase, downbeat/bar phase, confidence, and visual mode.

Likely files:

- `LibraryScanner.swift`
- `WaveformView.swift`
- `Track.swift`
- `AnalysisCache.swift`

Do not touch:

- playback engine graph
- snap manager
- playlist logic

### Issue 3: Waveform drag highlight bug

Goal: stop scrubbing from globally brightening future grid ticks.

Likely files:

- `WaveformView.swift`

Do not touch:

- analysis algorithm unless needed for visual-mode naming.

### Issue 4: Timer and monitor consistency audit

Goal: bring remaining timers/monitors into the house pattern and document ownership.

Likely files:

- `TransportView.swift`
- `WindowSnapManager.swift`
- `PlaylistView.swift`
- `SettingsPanel.swift`
- `TooltipView.swift`
- `GONEApp.swift`

Do not touch:

- snap sequence unless a specific monitor bug is found.

### Issue 5: Clone state policy

Goal: define exactly which `PlayerState` fields are copied, shared, or independent in clone mode.

Likely files:

- `SplitModeManager.swift`
- `ClonePlayerShell.swift`
- `PlayerState.swift`

Do not touch:

- crossfader audio math unless a clone-state field requires it.

### Issue 6: Spectrum tap handoff safety

Goal: remove shared-buffer race risk while keeping render thread allocation-free.

Likely files:

- `AudioEngine.next.swift`
- `SpectrumFeed.swift`
- `SpectrumView.swift` only if display behavior changes.

Do not touch:

- audio graph order.

## Current Confidence Levels

High confidence:

- Deep BPM refresh does not update beat grid.
- Import can schedule BPM+waveform and waveform-only paths together.
- Dragging waveform can brighten all musical ticks.
- `alwaysOnTop` state is not a real level toggle.
- `TransportView.ClickNSView` uses `Timer.scheduledTimer`.
- BPM ceiling default/fallback mismatch exists.
- `windowScale` is saved twice.

Medium confidence:

- Beat phase being displayed as bar/four-bar structure explains asymmetric grid on house tracks.
- Spectrum tap shared buffer can race.
- Full-sample storage in combined analysis can create memory pressure on long tracks.
- Crossfader scroll may drop `.none` phase events depending on hardware.

Needs verification:

- Whether clone mode should copy global visual settings beyond the current mirrored set.
- Whether activation should expand snap state in all cases.
- Whether playlist row monitors can ever remain installed after rapid list mutation.
- Whether waveform-only background concurrency causes visible stutter on the target Mac.

## Final Recommendation Order

1. Fix analysis scheduling deduplication before adding more analyzer logic.
2. Fix waveform drag highlight because it is isolated and likely low-risk.
3. Redefine beat-grid semantics before tuning visual tick heights again.
4. Add task cancellation handles or an `AnalysisScheduler` actor before heavy crash testing.
5. Audit event monitors/timers after the analysis pipeline is stable.
6. Formalize clone state policy before adding more clone-specific behavior.

