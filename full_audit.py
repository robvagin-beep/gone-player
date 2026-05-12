#!/usr/bin/env python3
"""
GONE Full Audit — ultrareview analog.

5 specialist agents run in parallel, each auditing a different axis:
  1. Architecture & invariants
  2. Concurrency & threading
  3. UI performance & SwiftUI
  4. Memory & lifecycle
  5. Feature correctness & edge cases

Then a synthesis agent combines all findings into a prioritized action plan.
Result posted as a PR comment.
"""
import os, json, time, re, anthropic, urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

REPO         = os.environ.get("REPO", "robvagin-beep/gone-player")
PR_NUMBER    = os.environ.get("PR_NUMBER", "1")
GITHUB_TOKEN = os.environ["GITHUB_TOKEN"]
API_KEY      = os.environ["ANTHROPIC_API_KEY"]

BASE = os.path.dirname(os.path.abspath(__file__))

ALL_FILES = [
    "GONE/AudioEngine.next.swift",
    "GONE/GONEApp.swift",
    "GONE/PlayerState.swift",
    "GONE/PlayerState+Playback.swift",
    "GONE/PlayerState+Analysis.swift",
    "GONE/PlayerState+Playlists.swift",
    "GONE/PlayerState+EQ.swift",
    "GONE/PlaybackProgressFeed.swift",
    "GONE/SpectrumFeed.swift",
    "GONE/LibraryScanner.swift",
    "GONE/AnalysisCache.swift",
    "GONE/SplitModeManager.swift",
    "GONE/CrossfaderBandPanel.swift",
    "GONE/WindowSnapManager.swift",
    "GONE/RootView.swift",
    "GONE/FullPlayerView.swift",
    "GONE/TrackHeaderView.swift",
    "GONE/WaveformView.swift",
    "GONE/TransportView.swift",
    "GONE/EQPanelView.swift",
    "GONE/PlaylistView.swift",
    "GONE/PeekPanelView.swift",
    "GONE/SettingsPanel.swift",
    "GONE/DesignTokens.swift",
    "GONE/Track.swift",
    "GONE/UIHelpers.swift",
    "GONE/XYPadState.swift",
    "GONE/TooltipView.swift",
]

INVARIANTS_BLOCK = """
## GONE Architecture Invariants — DO NOT violate, DO NOT flag as bugs:

- Audio graph order fixed: playerNode → speedNode → pitchNode → hpfNode → lpfNode → eqNode → distortionNode → delayNode → reverbNode → gateNode → mainMixerNode
- Views/extensions: always state.audioEngine, NEVER AudioEngineNext.shared directly
- Timers: RunLoop.main.add(timer, forMode: .common) — never Timer.scheduledTimer alone
- Timer callbacks: MainActor.assumeIsolated inside
- updateWindowSize: only from RootView.onChange, never duplicated
- progressFeed reset: self.progressFeed.reset(), never PlaybackProgressFeed.shared.reset()
- windowResizability(.automatic) — never change
- isMovableByWindowBackground = false — never change
- WindowSnapManager state machine sequence — NEVER reorder
- playbackToken / bumpToken() — VERIFIED CORRECT, never flag
- SourceKit "Cannot find type" — always false positive
- Zero external dependencies — native Apple frameworks only
- AudioEngineNext.deinit — static singletons never deinit, deinit code is dead/defensive
- Task.sleep(nanoseconds:) — acknowledged tech debt, out of scope
- EQCurveView.animateTo task churn — acknowledged, out of scope
- progressTimer capture pattern — intentional deadlock prevention
- LFO writes to state.lpfCutoff — intentional (EQ curve animation)
- XYPadState is a separate ObservableObject intentionally — prevents 60Hz @Published broadcast
- applyXYEffect does NOT write to @Published state — intentional
"""

AGENTS = [
    {
        "name": "Architecture",
        "emoji": "🏗️",
        "focus": """You are auditing GONE Player's ARCHITECTURE and structural integrity.

Focus areas:
1. DI pattern violations — any direct AudioEngineNext.shared call from views/extensions
2. Audio graph node order — any reordering, missing nodes, or bypass misuse
3. WindowSnapManager state machine — any sequence violations
4. Per-player isolation — PlaybackProgressFeed and SpectrumFeed routing correctness
5. SplitModeManager — activate/deactivate sequence, secondary engine lifecycle
6. AppKit/SwiftUI bridge — NSApp.windows, resolvedMainWindow usage
7. Ownership and singleton misuse across the codebase

For each issue: file + line + what's wrong + what the correct pattern is.
Severity: 🔴 Critical / 🟡 Warning / 🟢 Note
Format each finding as: `ARCH-N: [severity] file:line — description`""",
    },
    {
        "name": "Concurrency",
        "emoji": "⚡",
        "focus": """You are auditing GONE Player's CONCURRENCY and threading safety.

Focus areas:
1. @MainActor isolation — any main-thread mutations from background tasks
2. RunLoop.main .common mode — any Timer.scheduledTimer without RunLoop add
3. Task.detached strong captures — retain cycles or unexpected captures
4. DispatchQueue.main.async vs sync — deadlock risks
5. Audio tap callbacks — any @Published writes inside installTap closures
6. spectrumQueue serial queue — any unserialized spectrum mutations
7. bumpToken / playbackToken concurrency — any TOCTOU that isn't already documented
8. PlayerState @MainActor annotation completeness — any non-isolated mutations
9. Analysis pipeline cancellation — Task handles, race on rapid track changes

Severity: 🔴 Critical / 🟡 Warning / 🟢 Note
Format: `CONC-N: [severity] file:line — description`""",
    },
    {
        "name": "UI Performance",
        "emoji": "🎨",
        "focus": """You are auditing GONE Player's UI PERFORMANCE and SwiftUI efficiency.

Focus areas:
1. @Published at 60Hz — any ObservableObject property that fires every frame unnecessarily
2. Canvas redraw triggers — any Canvas that redraws more than needed
3. WaveformView — draw path construction, beat grid drawing, seek overlay performance
4. Spectrum views — bar drawing efficiency, data normalization per frame
5. .onReceive chains — any chain that causes full view re-render on high-frequency updates
6. PlaylistView row construction — any expensive computation in row body
7. SwiftUI animation conflicts — .animation modifiers fighting with explicit animations
8. EQCurveView — path construction per frame, animation task correctness
9. Image/artwork loading — main thread decode, cache miss behavior

Severity: 🔴 Critical (frame drop/janky) / 🟡 Warning (inefficient) / 🟢 Note
Format: `PERF-N: [severity] file:line — description`""",
    },
    {
        "name": "Memory",
        "emoji": "🧠",
        "focus": """You are auditing GONE Player's MEMORY management and object lifecycle.

Focus areas:
1. Retain cycles — [weak self] missing in Task closures, timers, NotificationCenter observers
2. Observer cleanup — NotificationCenter observers removed on deinit/disappear
3. Large buffers — audio PCM buffers held longer than needed
4. ArtworkCache — eviction policy, memory pressure response, disk cache growth
5. AnalysisCache — unbounded growth, memory pressure handling
6. SplitModeManager secondary state — PlayerState released on deactivate
7. Window references — NSWindow strong refs in closures or observers
8. Audio engine lifecycle — engine.stop() called on all paths, no leaked nodes
9. Task accumulation — detached tasks that run after their parent state is gone

Severity: 🔴 Critical (crash/leak) / 🟡 Warning (gradual growth) / 🟢 Note
Format: `MEM-N: [severity] file:line — description`""",
    },
    {
        "name": "Correctness",
        "emoji": "✅",
        "focus": """You are auditing GONE Player's FEATURE CORRECTNESS and edge cases.

Focus areas:
1. BPM edge cases — bpm=0 divide-by-zero in slicer, gateNode volume chop, tempo calc
2. Empty playlist — any crash or bad state when tracks.isEmpty
3. Rapid track changes — load() called before previous analysis completes
4. Split Mode edge cases — clone window on single-display, clone playlist empty state
5. Hot cue edge cases — cue set past end of track, cue on unloaded track
6. Snap system — dock/expand on resize, multi-display, notch MacBook behavior
7. Audio device change — output device switch mid-playback behavior
8. File access — missing file, unreadable file, permission denied in import
9. BPM analysis — very short tracks (<10s), very long tracks (>2h), non-audio files slipping through
10. Crossfader — equal-power law correctness, extreme positions (0.0, 1.0)

Severity: 🔴 Critical (crash/silent data loss) / 🟡 Warning (wrong behavior) / 🟢 Note
Format: `CORR-N: [severity] file:line — description`""",
    },
]

SYNTHESIS_SYSTEM = INVARIANTS_BLOCK + """
You are the lead engineer synthesizing audit findings from 5 specialist agents.

Your job:
1. Deduplicate overlapping findings across agents
2. Elevate the most critical issues to the top
3. Group related findings
4. Mark anything that violates documented invariants as FALSE POSITIVE (do not include)
5. For each valid finding: assign a fix priority (P0/P1/P2/P3)
6. Output a structured report

Output format:

## 🔴 P0 — Fix immediately (crash / data loss / audio glitch)
- **[ID]** `file:line` — description. *Fix:* what to do.

## 🟡 P1 — Fix before next release
- **[ID]** `file:line` — description. *Fix:* what to do.

## 🟢 P2 — Improvements
- **[ID]** `file:line` — description. *Fix:* what to do.

## 📋 P3 — Tech debt / notes
- brief list

## ✅ Clean areas
- list areas with no actionable findings

## ❌ False positives rejected
- brief list of what was rejected and why

Keep each finding to 2 sentences max. Total report: under 2000 words.
"""


def load_sources():
    parts = []
    for rel in ALL_FILES:
        path = os.path.join(BASE, rel)
        try:
            with open(path, encoding="utf-8") as f:
                content = f.read()
            parts.append(f"// ═══ {rel} ═══\n{content}")
        except FileNotFoundError:
            pass
    combined = "\n\n".join(parts)
    MAX = 160_000
    if len(combined) > MAX:
        cut = combined.rfind("\n", 0, MAX)
        combined = combined[:cut if cut > 0 else MAX]
    return combined


def call_claude(client, system, user, max_tokens=8000):
    for attempt in range(4):
        try:
            msg = client.messages.create(
                model="claude-opus-4-7",
                max_tokens=max_tokens,
                thinking={"type": "adaptive"},
                system=system,
                messages=[{"role": "user", "content": user}],
            )
            return "\n\n".join(b.text for b in msg.content if b.type == "text")
        except Exception as e:
            if attempt < 3 and any(code in str(e) for code in ["529", "503", "429", "overloaded", "rate_limit"]):
                wait = [60, 90, 120][attempt]
                print(f"  [{system[:20]}] throttle — waiting {wait}s...")
                time.sleep(wait)
            else:
                raise


def run_agent(agent, sources, api_key):
    client = anthropic.Anthropic(api_key=api_key)
    system = INVARIANTS_BLOCK + "\n\n" + agent["focus"]
    user = f"Audit the following GONE Player source code.\n\n{sources}"
    print(f"  {agent['emoji']} {agent['name']} agent started...")
    result = call_claude(client, system, user, max_tokens=8000)
    print(f"  {agent['emoji']} {agent['name']} agent done ({len(result)} chars)")
    return agent["name"], agent["emoji"], result


def post_comment(body):
    url = f"https://api.github.com/repos/{REPO}/issues/{PR_NUMBER}/comments"
    data = json.dumps({"body": body}).encode()
    req = urllib.request.Request(url, data=data, headers={
        "Authorization": f"Bearer {GITHUB_TOKEN}",
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/json",
    }, method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def main():
    print("GONE Full Audit — 5 parallel agents + synthesis")
    client = anthropic.Anthropic(api_key=API_KEY)
    sources = load_sources()
    print(f"Source loaded: {len(sources):,} chars")

    # ── Phase 1: 5 agents in parallel ────────────────────────────────────────
    print("\n[Phase 1] Running 5 specialist agents in parallel...")
    agent_results = {}
    with ThreadPoolExecutor(max_workers=5) as pool:
        futures = {
            pool.submit(run_agent, agent, sources, API_KEY): agent
            for agent in AGENTS
        }
        for future in as_completed(futures):
            try:
                name, emoji, result = future.result()
                agent_results[name] = (emoji, result)
            except Exception as e:
                agent = futures[future]
                print(f"  ❌ {agent['name']} failed: {e}")
                agent_results[agent["name"]] = (agent["emoji"], f"Agent failed: {e}")

    # ── Phase 2: Synthesis ────────────────────────────────────────────────────
    print("\n[Phase 2] Synthesis pass...")
    combined = "\n\n".join(
        f"## {emoji} {name} Agent Findings\n\n{result}"
        for name, (emoji, result) in agent_results.items()
    )
    synthesis = call_claude(
        client,
        system=SYNTHESIS_SYSTEM,
        user=f"Synthesize these findings from 5 specialist agents:\n\n{combined}",
        max_tokens=12000,
    )

    # ── Post result ───────────────────────────────────────────────────────────
    agent_sections = "\n\n".join(
        f"<details>\n<summary>{emoji} {name} Agent (raw)</summary>\n\n{result}\n\n</details>"
        for name, (emoji, result) in agent_results.items()
    )

    comment = (
        f"## 🔬 Full Audit — {len(AGENTS)} Agents + Synthesis\n\n"
        f"{synthesis}\n\n"
        f"---\n\n"
        f"<details>\n<summary>📋 Raw agent outputs</summary>\n\n"
        f"{agent_sections}\n\n"
        f"</details>\n\n"
        f"---\n*Full audit by Claude claude-opus-4-7 × {len(AGENTS)} agents — loop will process findings automatically*"
    )

    post_comment(comment)
    print("\nFull audit posted to PR.")


if __name__ == "__main__":
    main()
