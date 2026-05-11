#!/usr/bin/env python3
"""
MAX Engineering Audit — Verification Pass
Reads the current codebase and verifies each disputed claim from GONE26_MAX_ENGINEERING_AUDIT.md.
For each point: is it still present, already fixed, or a false positive in the current code?
"""

import os, sys, urllib.request, json

ANTHROPIC_API_KEY = os.environ["ANTHROPIC_API_KEY"]
GITHUB_TOKEN      = os.environ["GITHUB_TOKEN"]
PR_NUMBER         = os.environ["PR_NUMBER"]
REPO              = os.environ["REPO"]

FILES = {
    "GONEApp.swift":              "GONE/GONEApp.swift",
    "WindowSnapManager.swift":    "GONE/WindowSnapManager.swift",
    "PlayerState.swift":          "GONE/PlayerState.swift",
    "PlayerState+Analysis.swift": "GONE/PlayerState+Analysis.swift",
    "SplitModeManager.swift":     "GONE/SplitModeManager.swift",
    "AudioEngine.next.swift":     "GONE/GONE/AudioEngine.next.swift",
    "AnalysisCache.swift":        "GONE/AnalysisCache.swift",
    "ArtworkCache.swift":         "GONE/ArtworkCache.swift",
    "PlaylistView.swift":         "GONE/PlaylistView.swift",
    "EQPanelView.swift":          "GONE/EQPanelView.swift",
    "RootView.swift":             "GONE/RootView.swift",
    "SettingsPanel.swift":        "GONE/SettingsPanel.swift",
}

def read_file(path):
    try:
        with open(path, encoding="utf-8") as f:
            content = f.read()
        lines = content.splitlines()
        numbered = "\n".join(f"{i+1:4}: {l}" for i, l in enumerate(lines))
        if len(numbered) > 14000:
            numbered = numbered[:14000] + f"\n... (+{len(lines)} lines total, truncated)"
        return numbered
    except FileNotFoundError:
        return f"[NOT FOUND: {path}]"

def call_claude(prompt, pass_name):
    print(f"Running pass: {pass_name}...")
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps({
            "model": "claude-opus-4-7",
            "max_tokens": 16000,
            "messages": [{"role": "user", "content": prompt}]
        }).encode(),
        headers={
            "x-api-key": ANTHROPIC_API_KEY,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json"
        },
        method="POST"
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        data = json.loads(resp.read())
    return "".join(b["text"] for b in data["content"] if b["type"] == "text")

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

contents = {name: read_file(path) for name, path in FILES.items()}

# ── Pass 1: setSnapEnabled repair path + snap restore (P0.2) ────────────────

PASS1_PROMPT = f"""
You are auditing GONE Player (macOS DJ app) to verify or refute specific claims from an external audit.

CONTEXT: The external audit claimed "setSnapEnabled(true) may return early without repairing dead runtime state."
Also: "snapEnabled is saved but not loaded on relaunch."

YOUR TASK: Read the actual code below and answer definitively:
1. Is snapEnabled now loaded in loadPersistedSettings()? Show the exact line.
2. Is there a two-stage restore (load pref → arm WindowSnapManager) after the window is configured?
3. Is the setSnapEnabled() guard in GONEApp still a problem? Walk through the exact guard logic.
   Specifically: if snapEnabled==true AND snapState==.off (startup), does the guard block execution?
4. Can the user re-call setSnapEnabled(true) to repair a dead/stale WindowSnapManager?
   Trace the exact code path.
5. Are there any remaining gaps between "UI shows lightning enabled" and "WindowSnapManager is actually armed"?

For each question: cite exact file + line numbers. Verdict per question: FIXED / STILL PRESENT / FALSE POSITIVE.

=== PlayerState.swift ===
{contents["PlayerState.swift"]}

=== GONEApp.swift ===
{contents["GONEApp.swift"]}

=== WindowSnapManager.swift ===
{contents["WindowSnapManager.swift"]}

Format response as markdown with clear verdicts per question. Be specific, cite line numbers.
"""

# ── Pass 2: tapSampleBuffer race (P0.3) ─────────────────────────────────────

PASS2_PROMPT = f"""
You are auditing GONE Player (macOS DJ app) to verify or refute a specific claim.

EXTERNAL AUDIT CLAIM: "tapSampleBuffer is a single shared mutable buffer written by audio render thread
and read asynchronously by spectrumQueue — this is unsafe and can corrupt spectrum display."

YOUR TASK:
1. Find `tapSampleBuffer` in AudioEngine.next.swift. Show its declaration and every write/read site.
2. Identify the threads involved: what thread writes? What thread reads?
3. Is there any synchronization (lock, actor, atomic, copy-on-write)?
4. Is this actually a data race? Provide a concrete scenario where it fails.
5. If it IS unsafe: what is the minimal fix? (pool of N preallocated buffers, or Double-buffering, or actor isolation)
6. If it is NOT unsafe (e.g., already protected): explain why.

Cite exact line numbers. Verdict: DATA RACE PRESENT / PROTECTED / FALSE POSITIVE.

=== AudioEngine.next.swift ===
{contents["AudioEngine.next.swift"]}
"""

# ── Pass 3: Output device mirror while Clone active (P0.5) ──────────────────

PASS3_PROMPT = f"""
You are auditing GONE Player (macOS DJ app) to verify or refute a specific claim.

EXTERNAL AUDIT CLAIM: "Settings output device change only updates AudioEngineNext.shared;
AudioEngineNext.secondary is not updated when Clone Mode is active."

YOUR TASK:
1. Find where the output device change is triggered in SettingsPanel.swift or GONEApp.swift.
2. Trace exactly which engine(s) receive the setOutputDevice call.
3. If SplitModeManager.isActive, does AudioEngineNext.secondary also get updated?
4. Is there an existing mirror/propagation path for this case?
5. If NOT mirrored: what is the minimal fix? (hook in the observer that already fires on device change)

Cite exact line numbers. Verdict: BUG CONFIRMED / ALREADY MIRRORED / FALSE POSITIVE.

=== SettingsPanel.swift ===
{contents["SettingsPanel.swift"]}

=== GONEApp.swift ===
{contents["GONEApp.swift"]}

=== SplitModeManager.swift ===
{contents["SplitModeManager.swift"]}

=== AudioEngine.next.swift ===
{contents["AudioEngine.next.swift"]}
"""

# ── Pass 4: EQ/XY mapping completeness (P0.6) ───────────────────────────────

PASS4_PROMPT = f"""
You are auditing GONE Player (macOS DJ app) to verify or refute a specific claim.

EXTERNAL AUDIT CLAIM: "EQ/XY display mapping is incomplete for LPF/HPF/BPF.
Moving the XY pad on filter axes does not update visible knobs/curve in EQPanelView."

YOUR TASK:
1. List all XY axis modes in EQPanelView.swift or RootView.swift (there should be ~13).
2. For each filter-like axis (.filter, .lowpass, .highpass, .bandpass, .reso, .filtVerb),
   trace whether the audio engine state change ALSO updates a visible display variable.
3. Specifically: when .lowpass axis is active and XY moves, does EQCurveView see the change?
   Does EQKnobStack see it?
4. Is there any duplicated formula that could drift out of sync?
5. Which axes (if any) have a mapping gap between "audio changes" and "display updates"?

Cite exact line numbers. Verdict per axis: DISPLAY SYNCED / DISPLAY LAG / NOT MAPPED.

=== EQPanelView.swift ===
{contents["EQPanelView.swift"]}

=== RootView.swift (first 14000 chars) ===
{contents["RootView.swift"]}
"""

# ── Pass 5: dockFromProximity sequence + playlist click scroll (P1.3 + P1.4) ─

PASS5_PROMPT = f"""
You are auditing GONE Player (macOS DJ app) to verify or refute two specific claims.

CLAIM A (P1.3): "dockFromProximity sets snapState=.docked BEFORE animation completes.
dockToEdge correctly sets it only in the completion handler. This asymmetry means the UI
shows docked state before the window is physically docked."

YOUR TASK for Claim A:
1. In WindowSnapManager, show the exact sequence in dockToEdge: when is snapState set?
2. Show the exact sequence in dockFromProximity: when is snapState set?
3. Is the asymmetry actually present? Is it a bug or intentional design?
4. If asymmetric, what observable failure does it cause?

CLAIM B (P1.4): "Mouse click on a playlist row causes the list to scroll/jump to center that row.
Keyboard navigation should scroll, but mouse click should not."

YOUR TASK for Claim B:
1. Find where `focusScrollTarget` is set in PlaylistView.swift.
2. Identify which code paths set it: keyboard navigation? Mouse click? Double-click? Track load?
3. Is a mouse click on a visible row causing an unexpected scroll to center it?
4. If yes: what is the minimal fix to separate keyboard-scroll reason from click reason?

Cite exact line numbers. Verdicts: ASYMMETRY PRESENT/ABSENT and SCROLL JUMP PRESENT/ABSENT.

=== WindowSnapManager.swift ===
{contents["WindowSnapManager.swift"]}

=== PlaylistView.swift (first 14000 chars) ===
{contents["PlaylistView.swift"]}
"""

passes = [
    ("P0.2 — setSnapEnabled repair + snap restore", PASS1_PROMPT),
    ("P0.3 — tapSampleBuffer render-thread race",   PASS2_PROMPT),
    ("P0.5 — output device mirror (Clone Mode)",    PASS3_PROMPT),
    ("P0.6 — EQ/XY display mapping completeness",  PASS4_PROMPT),
    ("P1.3 + P1.4 — dock sequence + scroll jump",  PASS5_PROMPT),
]

all_results = []
for name, prompt in passes:
    result = call_claude(prompt, name)
    all_results.append((name, result))

# Assemble final comment
header = """## Claude Code Review — MAX Audit Verification

External audit (GONE26_MAX_ENGINEERING_AUDIT.md) flagged 10 P0 issues.
This pass reads the current codebase and verdicts each disputed point.

**Already fixed before this audit ran:**
- P0.1: `snapEnabled` now loaded in `loadPersistedSettings()` + two-stage runtime restore ✅
- P0.4: Full audio snapshot (vol/pitch/EQ/HPF/LPF/reverb) applied to secondary engine on Clone activate ✅
- P0.8: `AnalysisCache` already uses (path + size + mtime) — confirmed correct ✅
- P0.9/P0.10: Window level matrix unified (overlay=102/screenSaver=1000) — confirmed correct ✅
- P1.1: `resolvedMainWindow()` now explicitly excludes clone window ✅

**Delegated to this pass for verification:**

---

"""

body = header
for name, result in all_results:
    body += f"### {name}\n\n{result}\n\n---\n\n"

status = post_comment(body)
print(f"Comment posted: HTTP {status}")
