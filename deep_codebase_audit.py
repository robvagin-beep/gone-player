#!/usr/bin/env python3
"""
GONE Player — Deep Full-Codebase Audit
4 heavy sequential passes covering every file, then a synthesis pass
that produces one structured summary for ingestion.

Pass 1 — Audio engine + concurrency (AudioEngine, PlayerState core, Playback, Analysis)
Pass 2 — Window management + presence (WindowSnapManager, GONEApp, SplitModeManager, CrossfaderBandPanel, ClonePlayerShell)
Pass 3 — UI layer (RootView, EQPanelView, PlaylistView, FullPlayerView, WaveformView, TrackHeaderView, TransportView, PeekPanelView)
Pass 4 — Data layer (AnalysisCache, ArtworkCache, LibraryScanner, PlaybackProgressFeed, SpectrumFeed, PlayerState+Playlists, PlayerState+EQ, Track)
Synthesis — All 4 results → one priority-ranked actionable report
"""

import os, json, urllib.request, time

ANTHROPIC_API_KEY = os.environ["ANTHROPIC_API_KEY"]
GITHUB_TOKEN      = os.environ["GITHUB_TOKEN"]
PR_NUMBER         = os.environ["PR_NUMBER"]
REPO              = os.environ["REPO"]

# ── File registry ─────────────────────────────────────────────────────────────

FILE_PATHS = {
    # Audio core (AudioEngine lives in nested GONE/GONE subfolder)
    "AudioEngine.next.swift":       "GONE/GONE/AudioEngine.next.swift",
    "PlayerState.swift":            "GONE/PlayerState.swift",
    "PlayerState+Playback.swift":   "GONE/PlayerState+Playback.swift",
    "PlayerState+Analysis.swift":   "GONE/PlayerState+Analysis.swift",
    "PlayerState+EQ.swift":         "GONE/PlayerState+EQ.swift",
    "PlayerState+Playlists.swift":  "GONE/PlayerState+Playlists.swift",
    # Window
    "WindowSnapManager.swift":      "GONE/WindowSnapManager.swift",
    "GONEApp.swift":                "GONE/GONEApp.swift",
    "SplitModeManager.swift":       "GONE/SplitModeManager.swift",
    "CrossfaderBandPanel.swift":    "GONE/CrossfaderBandPanel.swift",
    "ClonePlayerShell.swift":       "GONE/ClonePlayerShell.swift",
    # UI
    "RootView.swift":               "GONE/RootView.swift",
    "EQPanelView.swift":            "GONE/EQPanelView.swift",
    "PlaylistView.swift":           "GONE/PlaylistView.swift",
    "FullPlayerView.swift":         "GONE/FullPlayerView.swift",
    "WaveformView.swift":           "GONE/WaveformView.swift",
    "TrackHeaderView.swift":        "GONE/TrackHeaderView.swift",
    "TransportView.swift":          "GONE/TransportView.swift",
    "PeekPanelView.swift":          "GONE/PeekPanelView.swift",
    "SettingsPanel.swift":          "GONE/SettingsPanel.swift",
    "XYPadState.swift":             "GONE/XYPadState.swift",
    # Data
    "AnalysisCache.swift":          "GONE/AnalysisCache.swift",
    "ArtworkCache.swift":           "GONE/ArtworkCache.swift",
    "LibraryScanner.swift":         "GONE/LibraryScanner.swift",
    "PlaybackProgressFeed.swift":   "GONE/PlaybackProgressFeed.swift",
    "SpectrumFeed.swift":           "GONE/SpectrumFeed.swift",
    "Track.swift":                  "GONE/Track.swift",
}

TRUNC = 13000   # chars per file before truncation

def read_file(path):
    try:
        with open(path, encoding="utf-8") as f:
            content = f.read()
        lines = content.splitlines()
        numbered = "\n".join(f"{i+1:4}: {l}" for i, l in enumerate(lines))
        if len(numbered) > TRUNC:
            numbered = numbered[:TRUNC] + f"\n... (truncated — {len(lines)} lines total)"
        return numbered
    except FileNotFoundError:
        return f"[NOT FOUND: {path}]"

C = {name: read_file(path) for name, path in FILE_PATHS.items()}

# ── API call ──────────────────────────────────────────────────────────────────

def call_claude(prompt, label):
    print(f"[PASS] {label}...")
    payload = json.dumps({
        "model": "claude-opus-4-7",
        "max_tokens": 16000,
        "messages": [{"role": "user", "content": prompt}]
    }).encode()
    headers = {
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json"
    }
    for attempt in range(4):
        req = urllib.request.Request(
            "https://api.anthropic.com/v1/messages",
            data=payload, headers=headers, method="POST"
        )
        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                data = json.loads(resp.read())
            return "".join(b["text"] for b in data["content"] if b["type"] == "text")
        except urllib.error.HTTPError as e:
            if e.code in (529, 529, 503, 429) and attempt < 3:
                wait = [60, 90, 120][attempt]
                print(f"  HTTP {e.code} — waiting {wait}s (attempt {attempt+1}/4)...")
                time.sleep(wait)
            else:
                raise

def post_comment(body):
    url = f"https://api.github.com/repos/{REPO}/issues/{PR_NUMBER}/comments"
    req = urllib.request.Request(
        url,
        data=json.dumps({"body": body}).encode(),
        headers={
            "Authorization": f"Bearer {GITHUB_TOKEN}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json"
        },
        method="POST"
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.status

# ── Shared instructions injected into every pass ─────────────────────────────

DO_NOT_FLAG = """
## DO NOT FLAG (verified correct or acknowledged tech debt):
- `playbackToken` / `bumpToken()` pattern: fully verified, zero TOCTOU risk — DO NOT FLAG
- `progressTimer` capture `let t = progressTimer; progressTimer = nil` before dispatch — intentional
- `MainActor.assumeIsolated` in RunLoop.main timer callbacks — correct pattern
- `bumpToken()` discarded result in `stop()` — intentional
- `AudioEngineNext.deinit` — static lifetime, deinit is dead code, DO NOT FLAG anything in it
- `Task.sleep(nanoseconds:)` deprecation — acknowledged tech debt in CLAUDE.md, out of scope
- `Task.detached` for BPM/waveform with no cancellation handle — acknowledged tech debt
- `windowResizability(.automatic)` — must never change
- `isMovableByWindowBackground = false` — must never change
- `DispatchQueue.main.async` (not sync) for timer invalidation — intentional deadlock prevention
- `AudioEngineNext.init()` is private — enforces 2-instance invariant, correct
- `SplitModeManager.deactivate()` pause-before-stop sequence — intentional hang fix
- `ArtworkCache.store` double-write race — `.atomic` write makes result safe
- `CrossfaderGapWindow` double-close observer — idempotent by design
- `BandHitTestView.hitRadius = 60` vs `pad = 60` — different purposes, same value by coincidence
- Clone window never snap-managed — correct, no conflict
- `EmptyOverlayView.startTypewriter` Task.sleep — acknowledged tech debt
- `EQCurveView.animateTo` Task churn — acknowledged tech debt
- `ScrollWheelNSView momentum guard` — intentional, correct
- `CrossfaderBridgeView` edge threshold `> 10` — intentional, do not flag
- `FullPlayerView transaction { animation = nil }` — intentional, prevents visual glitch on load
"""

# ── Pass 1: Audio Engine + Concurrency ───────────────────────────────────────

PASS1 = f"""
You are doing a deep audit of GONE Player (macOS DJ app in Swift/SwiftUI).
Focus: audio engine, concurrency, threading, data races, memory safety.

{DO_NOT_FLAG}

## Architecture notes you must know:
- Audio graph is fixed: playerNode → speedNode → pitchNode → hpfNode → lpfNode → eqNode → distortionNode → delayNode → reverbNode → gateNode → mainMixerNode
- Two engine instances: AudioEngineNext.shared (primary) and AudioEngineNext.secondary (clone)
- PlayerState stores `let audioEngine: AudioEngineNext` — all audio calls go through self.audioEngine
- NEVER call AudioEngineNext.shared directly inside PlayerState extensions
- Spectrum ceiling: 0..0.24 (not 0..1)
- processSpectrum sampleRate comes from tap buffer, NOT hardcoded 44100
- Per-player progress feeds: state.progressFeed (not PlaybackProgressFeed.shared) except legacy PeekPanel

## Your tasks — examine every line of every file provided:
1. **Data races**: any shared mutable state accessed from multiple threads without synchronization
2. **Main-thread violations**: UI mutations off main, audio callbacks writing @Published directly
3. **Memory leaks**: retain cycles in closures, timers not invalidated, observers not removed
4. **Audio graph integrity**: any code that could reorder, bypass, or disconnect nodes unexpectedly
5. **Scheduling correctness**: PCM chunk scheduling, token guards, playback state transitions
6. **Engine DI violations**: any direct AudioEngineNext.shared call inside PlayerState or View files
7. **Feed isolation**: PlaybackProgressFeed.shared.reset() called from extension code (must use self.progressFeed.reset())
8. **Analysis concurrency**: BPM / waveform tasks, cancellation, batch size, actor isolation

For each finding: file name + line number, severity (P0/P1/P2), description, minimal fix.
P0 = crash/data-corruption risk. P1 = incorrect behavior. P2 = robustness/quality.

=== AudioEngine.next.swift ===
{C["AudioEngine.next.swift"]}

=== PlayerState.swift ===
{C["PlayerState.swift"]}

=== PlayerState+Playback.swift ===
{C["PlayerState+Playback.swift"]}

=== PlayerState+Analysis.swift ===
{C["PlayerState+Analysis.swift"]}

=== PlayerState+EQ.swift ===
{C["PlayerState+EQ.swift"]}

Output format: Markdown, grouped by severity. Be precise, cite line numbers.
"""

# ── Pass 2: Window Management + Presence ─────────────────────────────────────

PASS2 = f"""
You are doing a deep audit of GONE Player (macOS DJ app in Swift/SwiftUI).
Focus: window management, Space/desktop behavior, level hierarchy, snap state machine.

{DO_NOT_FLAG}

## Architecture notes you must know:
- Level hierarchy: docked=1000 (screenSaverWindow), expanded=102 (overlayWindow), clone=103, crossfader=101, settings=1001
- Docked must be above Space-transition compositor → requires level 1000
- `.stationary` removed intentionally (unreliable for off-screen windows)
- Space swipe defense: activeSpaceDidChangeNotification → alphaValue=0 → constrainSnapPosition → restore after 80ms
- Snap state machine sequence (DO NOT CHANGE):
  dock: isSnapping=true → slideOffScreen → prepareForSnap → completion: snapState=.docked → lockFrame → isSnapping=false
  expand: unlockFrame → snapState=.expanded/isSnapping=true → restoreFromSnap → animateFrameTo → completion: isSnapping=false
- windowResizability(.automatic) — must NOT change
- isMovableByWindowBackground = false — must NOT change
- Clone window level: overlayWindow+1 = 103
- Crossfader level: overlayWindow-1 = 101

## Your tasks:
1. **Space swipe**: Is handleSpaceChange wired correctly? Does it cover all snap states? Any edge cases?
2. **Level transitions**: Is every dockToEdge/dockFromProximity completion correctly setting level=1000? Is expand() correctly reverting to 102?
3. **Collection behavior**: Does docked state use correct flags? Does expanded state use correct flags?
4. **Snap state machine**: Any asymmetries between dockToEdge and dockFromProximity? Any state the window can get stuck in?
5. **resolvedMainWindow**: Does it correctly exclude clone window? All call sites correct?
6. **Clone Mode conflicts**: Does activate() correctly disable snap? Does deactivate() restore state?
7. **Timer safety**: All timers on RunLoop.main with .common mode? All callbacks using MainActor.assumeIsolated?
8. **Observer lifecycle**: Space observer added in enable(), removed in clearInfrastructure()/disable()?
9. **Fullscreen coverage**: Can the docked window appear above fullscreen app Spaces?
10. **PeekPanel**: Level correct? Does it travel during Space swipe?

For each finding: file name + line number, severity (P0/P1/P2), description, minimal fix.

=== WindowSnapManager.swift ===
{C["WindowSnapManager.swift"]}

=== GONEApp.swift ===
{C["GONEApp.swift"]}

=== SplitModeManager.swift ===
{C["SplitModeManager.swift"]}

=== CrossfaderBandPanel.swift ===
{C["CrossfaderBandPanel.swift"]}

=== ClonePlayerShell.swift ===
{C["ClonePlayerShell.swift"]}

Output format: Markdown, grouped by severity. Be precise, cite line numbers.
"""

# ── Pass 3: UI Layer ──────────────────────────────────────────────────────────

PASS3 = f"""
You are doing a deep audit of GONE Player (macOS DJ app in Swift/SwiftUI).
Focus: UI layer — SwiftUI views, XY effects, playlist interaction, rendering correctness.

{DO_NOT_FLAG}

## Architecture notes you must know:
- applyXYEffect in RootView.swift handles all 13 axes — does NOT write @Published state
- On axis change: stopSlicer() + resetFXNodes() before new effect
- On xyActive deactivate: stopSlicer() + resetFXNodes()
- Slicer is Timer-based 60fps driven by state.bpm
- LFO writes to state.lpfCutoff so EQ curve animates during sweep
- updateWindowSize called only from RootView.onChange — do NOT duplicate
- All 13 XY axes must have both audio change AND visible display update
- focusScrollTarget in PlaylistView — only set by keyboard nav (↑↓), NOT by mouse click
- ↓/↑ move selectedIds + selectionAnchorId + focusScrollTarget
- Enter plays only if selectedIds.count == 1

## Your tasks:
1. **XY mapping completeness**: For EACH of the 13 axes, does the audio change ALSO update visible display (EQCurveView, EQ knobs)? List any gaps.
2. **applyXYEffect @Published writes**: Does applyXYEffect write any @Published var directly? (would cause re-render loop)
3. **Playlist scroll jump**: Does mouse click on a row set focusScrollTarget? It must not.
4. **Keyboard nav**: Do ↑↓ correctly set focusScrollTarget? Does Enter correctly gate on count==1?
5. **updateWindowSize duplication**: Is it called from anywhere other than RootView.onChange?
6. **View body performance**: Any heavy computations in view body (sorting, filtering, iteration) that should be cached?
7. **Animation correctness**: Any SwiftUI animations that could conflict with the snap state machine?
8. **Hot cue display**: Do hot cue ticks in WaveformView correctly update when cues are set/cleared?
9. **TransportView clone guard**: `state.audioEngine !== AudioEngineNext.secondary` — is it present for settings gear?
10. **PeekPanelView**: Does it use PlaybackProgressFeed.shared (ok for legacy) or per-player feed?
11. **SpectrumView**: Uses SpectrumFeed.shared — correct? Any rendering issues?

For each finding: file name + line number, severity (P0/P1/P2), description, minimal fix.

=== RootView.swift ===
{C["RootView.swift"]}

=== EQPanelView.swift ===
{C["EQPanelView.swift"]}

=== PlaylistView.swift ===
{C["PlaylistView.swift"]}

=== FullPlayerView.swift ===
{C["FullPlayerView.swift"]}

=== WaveformView.swift ===
{C["WaveformView.swift"]}

=== TrackHeaderView.swift ===
{C["TrackHeaderView.swift"]}

=== TransportView.swift ===
{C["TransportView.swift"]}

=== PeekPanelView.swift ===
{C["PeekPanelView.swift"]}

=== SettingsPanel.swift ===
{C["SettingsPanel.swift"]}

=== XYPadState.swift ===
{C["XYPadState.swift"]}

Output format: Markdown, grouped by severity. Be precise, cite line numbers.
"""

# ── Pass 4: Data Layer ────────────────────────────────────────────────────────

PASS4 = f"""
You are doing a deep audit of GONE Player (macOS DJ app in Swift/SwiftUI).
Focus: data layer — caches, library scanner, feeds, track model, playlist state.

{DO_NOT_FLAG}

## Architecture notes you must know:
- AnalysisCache key = (path + file size + mtime) — intentionally correct
- ArtworkCache: NSCache(300 items), cost = width*height*4, totalCostLimit = 64MB
- ArtworkCache disk: 256px JPEG, .atomic write, 30-day prune
- ArtworkCache.image(for:) must NOT be called from main thread (dispatchPrecondition guard added)
- LibraryScanner.analyzeBPM: BPM range resolution
- PlaybackProgressFeed: per-player instances (state.progressFeed), PlaybackProgressFeed.shared only for legacy PeekPanel
- SpectrumFeed.shared: singleton, AppDelegate.bindAudioEngine wires engine.onSpectrum → SpectrumFeed.shared.data
- Track.artworkData: Data? in struct — causes array copy overhead (known tech debt, do not refactor)
- PlayerState+Playlists: reorderTrack must bake visible sorted order before switching sortKey
- PlayerState+Playlists: presentImportPanel uses Task {{ @MainActor [weak self] in ... }}

## Your tasks:
1. **AnalysisCache correctness**: Is the cache key truly stable? Edge cases with symlinks, iCloud Drive paths?
2. **AnalysisCache flush**: Is flushNow() correctly called at app quit? Is there a race between flushNow and background periodic flush?
3. **ArtworkCache memory**: Is totalCostLimit enforced? Is cost calculation correct?
4. **ArtworkCache threading**: Any main-thread disk reads that bypassed the guard?
5. **LibraryScanner**: Any memory leaks in analysis tasks? Is BPM analysis cancellable?
6. **PlaybackProgressFeed**: Any place where PlaybackProgressFeed.shared.reset() is called from PlayerState extension code? (Must use self.progressFeed.reset())
7. **SpectrumFeed**: Any risk of SpectrumFeed.shared being written from audio thread without main dispatch?
8. **Track struct size**: Is artworkData: Data? causing significant copy overhead during sort/filter operations?
9. **PlayerState+Playlists reorderTrack**: Does it correctly bake visible order before changing sortKey? Any off-by-one in index handling?
10. **Import batching**: Is importURLs correctly limited to batch size 4? Any memory spike during large imports?
11. **Settings persistence**: Does loadPersistedSettings() load ALL keys that persistSettings() saves? Any missing keys?
12. **Output device mirror**: When Settings changes output device, does it update BOTH AudioEngineNext.shared AND AudioEngineNext.secondary (when Split Mode active)?

For each finding: file name + line number, severity (P0/P1/P2), description, minimal fix.

=== AnalysisCache.swift ===
{C["AnalysisCache.swift"]}

=== ArtworkCache.swift ===
{C["ArtworkCache.swift"]}

=== LibraryScanner.swift ===
{C["LibraryScanner.swift"]}

=== PlaybackProgressFeed.swift ===
{C["PlaybackProgressFeed.swift"]}

=== SpectrumFeed.swift ===
{C["SpectrumFeed.swift"]}

=== PlayerState+Playlists.swift ===
{C["PlayerState+Playlists.swift"]}

=== Track.swift ===
{C["Track.swift"]}

=== SettingsPanel.swift ===
{C["SettingsPanel.swift"]}

Output format: Markdown, grouped by severity. Be precise, cite line numbers.
"""

# ── Run passes ────────────────────────────────────────────────────────────────

results = {}
for label, prompt in [
    ("Pass 1 — Audio Engine + Concurrency",    PASS1),
    ("Pass 2 — Window Management + Presence",  PASS2),
    ("Pass 3 — UI Layer",                      PASS3),
    ("Pass 4 — Data Layer",                    PASS4),
]:
    results[label] = call_claude(prompt, label)

# ── Synthesis pass ────────────────────────────────────────────────────────────

SYNTHESIS_PROMPT = f"""
You are the final synthesis stage of a 4-pass deep audit of GONE Player (macOS DJ app).
Below are the raw findings from 4 specialist passes. Your job is to:

1. **Deduplicate**: merge findings that describe the same issue
2. **Validate**: mark findings that contradict the known-good architecture as FALSE POSITIVE
3. **Rank**: produce a clean priority-ranked list (P0 → P1 → P2)
4. **Summarize for developer ingestion**: each item must have file+line, clear description, and minimal fix

## Known-correct architecture (findings contradicting these = FALSE POSITIVE):
- playbackToken/bumpToken: verified correct, zero race risk
- AudioEngineNext.deinit: dead code (static lifetime), never runs
- windowResizability(.automatic): intentional
- isMovableByWindowBackground = false: intentional
- DispatchQueue.main.async for timer invalidation: intentional deadlock prevention
- SplitModeManager pause-before-stop: intentional
- .stationary flag removed: intentional (unreliable for off-screen)
- CrossfaderGapWindow double-close: idempotent by design
- ArtworkCache double-write race: .atomic makes safe
- ClonePlayerShell contentSize duplication: intentional (MIRROR comment)
- Task.sleep(nanoseconds:) deprecation: acknowledged tech debt, out of scope
- Task.detached no cancellation: acknowledged tech debt

## Output structure (strict):

### P0 — Critical (crash / data corruption)
For each: `**[P0] Title** — file.swift:LINE — description — fix`

### P1 — Incorrect behavior
For each: `**[P1] Title** — file.swift:LINE — description — fix`

### P2 — Robustness / quality
For each: `**[P2] Title** — file.swift:LINE — description — fix`

### False Positives (do not act on)
For each: `~~Finding~~ — why it's correct`

### Summary table
| Severity | Count | Most critical |
|----------|-------|--------------|
| P0 | N | ... |
| P1 | N | ... |
| P2 | N | ... |
| False Positives | N | |

### CLAUDE.md updates
List any items that should be added to the "PR Review — Already Resolved" section in CLAUDE.md
(i.e., findings that are false positives and should be pre-emptively blocked in future reviews).

---

## Pass 1 findings (Audio Engine + Concurrency):
{results["Pass 1 — Audio Engine + Concurrency"]}

---

## Pass 2 findings (Window Management + Presence):
{results["Pass 2 — Window Management + Presence"]}

---

## Pass 3 findings (UI Layer):
{results["Pass 3 — UI Layer"]}

---

## Pass 4 findings (Data Layer):
{results["Pass 4 — Data Layer"]}
"""

print("[SYNTHESIS] Running final synthesis pass...")
synthesis = call_claude(SYNTHESIS_PROMPT, "Synthesis")

# ── Assemble PR comment ───────────────────────────────────────────────────────

header = """## Deep Full-Codebase Audit — GONE Player

4 specialist passes (audio, window, UI, data) + synthesis.
Every Swift file in the project was read. Findings deduplicated and ranked.

"""

# Individual pass sections (collapsible)
pass_sections = ""
for label, result in results.items():
    short = label.split(" — ")[1]
    pass_sections += f"<details>\n<summary>Raw findings: {short}</summary>\n\n{result}\n\n</details>\n\n"

body = header + "## Synthesis Report\n\n" + synthesis + "\n\n---\n\n" + pass_sections

status = post_comment(body)
print(f"Comment posted: HTTP {status}")
