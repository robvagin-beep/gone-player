# GONE Final Sweep Brief

Read-only style brief for Claude review and next-pass planning.
This document assumes the recent stabilization pass is already in place:

- snap / peek sequence cleaned up
- settings / tooltip panel lifecycle tightened
- split mode window lifecycle tightened
- crossfader gap sync improved
- feed objects isolated to `@MainActor`
- clone shell window reference cleanup added

The goal here is not to re-open solved work.
The goal is to identify the remaining tails that still seem worth attention, explain why they still matter, and outline the most plausible solution direction for each.

This document deliberately frames points as likely weak spots, not absolute truths.

---

## 1. Audio Engine Control Isolation
Files:
- `GONE/GONE/GONE/AudioEngine.next.swift`
- `GONE/GONE/GONEApp.swift`

### Why this still deserves attention
`AudioEngineNext` is structurally strong, but it still relies on a large implicit contract:

- many properties are annotated only by comments as “Main-thread only”
- callbacks (`onProgress`, `onSpectrum`, `onFinished`, `onError`) are externally assigned and can fan out into multiple UI/state surfaces
- engine control, scheduling, progress timers, and output-device mutation are split across:
  - main thread assumptions
  - a prefetch queue
  - a spectrum queue
  - split mode audio queue

The code looks disciplined, but the discipline is mostly conventional rather than enforced by type-level isolation.

### What may still be weak
- `AudioEngineNext` may still be too easy to call from the wrong thread without the compiler stopping it.
- `GONEApp.bindAudioEngine()` may still be duplicating feed propagation:
  - into `playerState.progress`
  - into `playerState.progressFeed`
  - into `PlaybackProgressFeed.shared`
  - into `playerState.spectrumFeed`
  - into `SpectrumFeed.shared`
- `onSpectrum` in `GONEApp` still writes feeds directly without an explicit main-hop, unlike `onProgress`.

### Suggested direction
Do not rewrite the engine.
Instead, consider a narrow control-boundary pass:

1. Define which engine methods are allowed off-main and which are main-only.
2. Enforce that explicitly:
   - either by `@MainActor` on the public UI-facing control API
   - or by a dedicated serial command queue abstraction for all control mutations
3. Normalize callback delivery:
   - either always dispatch UI-facing callbacks to main inside the engine
   - or require every binder to do it, but then make that contract explicit and uniform
4. Reduce duplicated feed writes if possible, especially where both `.shared` and per-state feeds are updated in parallel.

Most likely best approach:
- keep `AudioEngineNext` structurally as-is
- tighten callback delivery and control isolation rather than redesigning playback architecture

---

## 2. Analysis Scheduling Still Feels Heavier Than the Product Probably Needs
Files:
- `GONE/GONE/PlayerState+Analysis.swift`
- `GONE/GONE/LibraryScanner.swift`
- `GONE/GONE/AnalysisCache.swift`
- `GONE/GONE/PlayerState+Playback.swift`

### Why this still deserves attention
This area is technically much stronger than before.
`AnalysisCache` is one of the best files in the repo now.
The remaining issue is less correctness and more workload semantics.

The code still appears to support multiple overlapping user stories at once:

- current-track-first analysis
- deep BPM reanalysis
- background BPM sweep
- background waveform sweep
- import-time deferred analysis
- cache rehydration

That all works, but it may still be more concurrent and more stateful than the product actually needs.

### What may still be weak
- `scheduleCurrentTrackAnalysis()` still triggers:
  - `scheduleBPMAnalysis()`
  - `scheduleWaveformComputation(currentOnly: true)`
- The BPM lane and waveform lane are still separate schedulers even though the code already has combined BPM+waveform work in `analyzeBPMWithWaveform`.
- The background queues may still have more moving parts than necessary:
  - lane 1 priority current-track
  - lane 2 background queue
  - cache hits
  - import deferrals
  - priority IDs
- `LibraryScanner` is strong, but it is still being asked to do heavy decode work from multiple pathways.

### Suggested direction
Do not weaken current responsiveness.
Instead, question whether the analysis model should be made more single-track-centric:

1. Consider whether BPM and waveform should share one scheduler more often.
2. Consider whether “current track first” should be the only eager path, with library-wide backfill delayed more aggressively.
3. Consider whether waveform-only passes should be rarer if combined BPM+waveform already exists.
4. Keep `AnalysisCache` as the foundation. It is likely already the right abstraction.

Most likely best approach:
- preserve cache
- preserve current-track priority
- reduce scheduler multiplicity rather than improving per-scheduler cleverness

---

## 3. Root Shell Still Carries Too Many Responsibilities
Files:
- `GONE/GONE/RootView.swift`
- `GONE/GONE/PeekPanelView.swift`
- `GONE/GONE/WindowSnapManager.swift`

### Why this still deserves attention
The most dangerous snap/peek issues were already cleaned up.
What remains is more about long-term maintainability than active breakage.

`RootView` still owns too many different concerns at once:

- shell geometry
- display scaling
- window resize orchestration
- drop target
- peek panel overlay
- XY pad audio routing
- spring reset behavior
- header double-click

This is not necessarily broken.
But it still means future changes can easily collide.

### What may still be weak
- `RootView` still responds directly to several `xyPad` publishers and translates them into engine mutations.
- `updateWindowSize()` is still a large coordination hinge between shell layout and AppKit window geometry.
- `PeekPanelView` still contains tuned-by-eye layout compensation:
  - manual inset choices
  - manual horizontal offset
  - state-specific interaction surfaces

### Suggested direction
Do not re-open snap sequence work.
Do not rewrite peek UI.
Instead, if another pass is justified, it should be about responsibility boundaries:

1. Consider extracting XY bridging out of `RootView` into a dedicated binder/coordinator layer.
2. Consider making shell geometry and shell behavior more separable:
   - shell view
   - window-sizing coordinator
3. Treat `PeekPanelView` as a tuned stateful surface and avoid touching its visuals unless behavior truly requires it.

Most likely best approach:
- leave visuals alone
- reduce behavioral density in `RootView`

---

## 4. Playlist Model vs Playlist UI Is Still Only Partially Reconciled
Files:
- `GONE/GONE/PlayerState.swift`
- `GONE/GONE/PlayerState+Playlists.swift`
- `GONE/GONE/PlayerState+Playback.swift`
- `GONE/GONE/PlaylistView.swift`

### Why this still deserves attention
The UI is visibly much simpler now.
The model still preserves a larger world:

- multiple playlist tabs
- split playlist mode
- active/secondary tab semantics
- playing-tab override semantics

Some of that is still required by split workflows.
Some of it may now be legacy complexity.

### What may still be weak
- The product surface mostly reads like a simpler playlist now, but the state model still thinks in tab-first terms.
- `PlaylistView` still contains a lot of drag/drop/split/import/selection behavior in one very large file.
- The bottom layout and pane logic are visually improved, but still rely on fairly manual composition.
- The recent `playingTabId` cleanup helped, but the broader semantic split is still there.

### Suggested direction
Do not rip out tabs blindly.
Do not simplify the model without respecting split mode.

A safer next pass would be:

1. Map which tab/split behaviors are still genuinely product-relevant.
2. Separate “playlist structure required for split mode” from “legacy tab semantics no longer surfaced.”
3. Reduce `PlaylistView` by extracting behavior-heavy subareas:
   - drop overlays
   - row selection logic
   - split chooser overlay
   - bottom summary / empty-state composition

Most likely best approach:
- keep split-capable data model
- remove or isolate legacy semantics that no longer serve the visible UI

---

## 5. Spectrum / Waveform / Header Are Strong, but Still Dense
Files:
- `GONE/GONE/SpectrumView.swift`
- `GONE/GONE/WaveformView.swift`
- `GONE/GONE/TrackHeaderView.swift`

### Why this still deserves attention
These files are no longer unstable, but they still mix:

- product feel
- rendering math
- interaction semantics
- cache/update concerns

That is fine while they stay small.
`WaveformView` in particular is no longer small in terms of conceptual density.

### What may still be weak
#### `SpectrumView`
- tuned-by-eye constants still dominate:
  - peak hold
  - gravity
  - scale
  - blend timing
  - idle pattern math
- the file is clean, but its behavior is still empirical rather than explained by a small set of named modes

#### `WaveformView`
- beat-grid mapping, progress animation, and ruler rendering all live together
- animation state (`BarTracker`, `GridTransitionState`) is embedded directly in view logic
- it still feels like one more complexity increase could make it hard to safely touch

#### `TrackHeaderView`
- artwork loading is safer than before, but still manually dispatched via `DispatchQueue.global`
- time-label caching, track-index caching, analysis badge behavior, and right-column spectrum display all live in one file

### Suggested direction
These are not crisis files.
They are candidates for clarity passes only if the rest of the architecture is already stable.

Most likely best approach:
- `SpectrumView`: leave behavior intact, just document its modes better if touched
- `WaveformView`: consider separating tick/grid model computation from draw code
- `TrackHeaderView`: if touched again, narrow it to view composition and push artwork loading/cache retrieval into a smaller helper abstraction

---

## 6. EQ Panel Is Visually Mature but Still Monolithic
Files:
- `GONE/GONE/EQPanelView.swift`
- `GONE/GONE/PlayerState+EQ.swift`

### Why this still deserves attention
This area looks much better now, and it is no longer one of the risk hotspots.
The remaining issue is file density and manual geometry.

### What may still be weak
- `EQPanelView.swift` is still a large file with:
  - faders
  - curve
  - XY controls
  - knob stack
  - various control helper types
- the file still relies on many hand-tuned constants and layout assumptions

### Suggested direction
Do not redesign it.
Do not touch layout unless there is a visual reason.

If another pass is justified:
1. Split by responsibility, not by microscopic components.
2. Keep the exact current visual behavior.
3. Prefer extracting subviews whose interfaces already feel stable:
   - curve view area
   - XY control row
   - knob stack
   - fader column primitives

Most likely best approach:
- structural split for maintainability only

---

## 7. Design Tokens Still Mix Foundation and Behavior
Files:
- `GONE/GONE/DesignTokens.swift`

### Why this still deserves attention
The file is compact and useful.
The issue is not scale.
The issue is conceptual mixing.

It currently contains:

- design constants
- fonts
- color helpers
- `fmtTime`
- cursor behavior
- gradient map behavior
- deterministic artwork gradient

### What may still be weak
- This is less a token file than a small “UI foundation + helper behavior” file.
- That may be fine now, but it means any future foundational work will keep accreting here.

### Suggested direction
Do not split it prematurely.
But if the project gets one more structural pass:

1. Keep `G` for actual tokens.
2. Move generic UI behavior helpers elsewhere:
   - cursor helper
   - gradient map helper
   - formatting helpers
   - artwork placeholder gradient helper

Most likely best approach:
- postpone until broader structural cleanup is otherwise done

---

## 8. What Looks Healthy Enough Not to Re-open Right Now
These areas seem comparatively strong and do not look like the best place to spend risk budget next:

- `AnalysisCache.swift`
  - actor-based
  - versioned
  - coalesced writes
  - path/mtime/size invalidation

- `LibraryScanner.swift`
  - very capable and already mature
  - likely performance-sensitive, but not obviously structurally confused

- `PitchFaderView.swift`
  - one of the cleaner control views

- `WindowSnapManager.swift`
  - after recent fixes, likely not perfect, but no longer the best place for speculative churn

- `SettingsPanel.swift` / `TooltipView.swift`
  - lifecycle issues were recently cleaned up

---

## 9. Suggested Priority Order for Claude
If Claude is going to reason through the remaining work, the most plausible order now seems:

1. **AudioEngine / binding ownership clarity**
   - especially callback delivery and control isolation

2. **Analysis scheduling simplification**
   - not cache removal
   - not scanner rewrite
   - just reducing concurrent semantic complexity

3. **RootView responsibility split**
   - especially XY bridge vs shell geometry concerns

4. **Playlist model/UI reconciliation**
   - only after confirming which split/tab semantics still matter

5. **Waveform / header / spectrum clarity pass**
   - not a redesign
   - just better separation of rendering vs state/logic

6. **EQ / design token structural cleanup**
   - lowest urgency

---

## 10. Direct Prompt Framing for Claude
Suggested framing:

> Treat the current build as the strongest known baseline.
> Do not reopen recently stabilized snap/peek/panel lifecycle work unless you find a concrete contradiction.
> Focus only on the remaining untouched tails:
> - audio engine control isolation
> - analysis scheduling complexity
> - root shell responsibility density
> - playlist model/UI drift
> - waveform/spectrum/header clarity
> - EQ/design-token structural density
>
> For each area:
> 1. identify whether the concern is real or overstated
> 2. explain the concrete risk
> 3. propose the narrowest structurally-correct solution
> 4. avoid redesigns unless the current structure is fundamentally misleading

---

## 11. Bottom Line
The codebase no longer mainly looks “broken.”
It now looks like a working product with several overlapping coordination layers that are becoming mature at different speeds.

The remaining work does not appear to be about emergency fixes.
It appears to be about deciding which complexity is truly intrinsic to the product, and which complexity is just residue from the app getting here.
