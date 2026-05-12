#!/usr/bin/env python3
"""
XY FX system audit — 13 axes, @Published isolation, slicer timer,
LFO writes, spring-back, EQ curve sync, filter knob display.
"""
import os, anthropic, urllib.request, urllib.error, json

XY_FILES = [
    "GONE/RootView.swift",
    "GONE/EQPanelView.swift",
    "GONE/PlayerState.swift",
    "GONE/XYPadState.swift",
]

SYSTEM_PROMPT = """You are a senior SwiftUI / CoreAudio engineer auditing GONE Player's XY FX system.

The XY pad has 13 axes that control audio effects in real-time. Architecture rules:

- XYPadState is a separate ObservableObject (NOT on PlayerState) — prevents 60Hz @Published broadcasts to the whole view tree
- applyXYEffect in RootView.swift does NOT write to @Published state — writes directly to audio engine nodes
- EQCurveView Canvas reads xyPad.point directly (no @Published chain)
- EQKnobStack reads xyPad.point directly for HPF/LPF display when XY is active
- Slicer is Timer-based (60fps), driven by state.bpm, runs in startSlicer(), stopped in stopSlicer()
- LFO writes to state.lpfCutoff so EQ curve shows the sweep (THIS is intentional — LFO animation)
- On axis change: stopSlicer() + resetFXNodes() before starting new effect
- On xyActive deactivate: stopSlicer() + resetFXNodes()
- Spring-back: startXYSpring() animates point back to center unless holdMode is true

13 axes: filter, reso, filtVerb, loFi, reverb, delay, dubDelay, gate, slicer, bpmChop, lfo, echo, dryWet

Audit these specific areas:

1. **@Published isolation**
   - Does applyXYEffect write to ANY @Published property at 60Hz? (exception: LFO writes to lpfCutoff — intentional for curve animation, do not flag)
   - Does XYPadState correctly isolate point/active/effectAxis/holdMode from PlayerState?
   - Any .onReceive or .onChange in large views that fires 60Hz from XY changes?

2. **Slicer / BPM Chop timer**
   - Is the Timer correctly stopped before starting a new axis?
   - What if state.bpm is 0 when slicer starts — divide by zero?
   - Is the timer invalidated on deactivate?
   - Timer in RunLoop.main with .common mode?

3. **Axis transitions**
   - Is resetFXNodes() called on EVERY axis change (not just slicer→non-slicer)?
   - Are reverb/delay/distortion node states reset to neutral on deactivate?
   - Spring-back: does startXYSpring() correctly check holdMode before starting?

4. **EQ curve / knob sync**
   - EQCurveView reads xyPad.point in Canvas — does it update at 60Hz correctly?
   - EQKnobStack: do HPF/LPF knobs show correct XY-derived values for filter/reso/filtVerb axes?
   - When XY deactivates, do knobs snap back to state.hpfCutoff / state.lpfCutoff?

5. **Gate effect**
   - gateNode is AVAudioMixerNode — does volume chopping work correctly?
   - Is gate volume reset to 1.0 on deactivate?
   - Any interaction with the main mixer volume?

Output:
- 🔴 **Critical** — audio glitch root cause, crash, or incorrect effect
- 🟡 **Warning** — timing issue, divide-by-zero risk, or state leak
- 🟢 **Note** — defensive improvement

If an area is clean: "✅ [Area]: No issues found."
Reference exact file + approximate line."""


def call_claude_with_retry(client, **kwargs):
    import time
    for attempt in range(4):
        try:
            return client.messages.create(**kwargs)
        except Exception as e:
            if attempt < 3 and any(code in str(e) for code in ["529", "503", "429", "rate_limit", "overloaded"]):
                wait = [60, 90, 120][attempt]
                print(f"  API throttle ({e}) — waiting {wait}s (attempt {attempt+1}/4)...")
                time.sleep(wait)
            else:
                raise

def load_sources(base):
    parts = []
    for rel in XY_FILES:
        path = os.path.join(base, rel)
        try:
            with open(path, "r", encoding="utf-8") as f:
                content = f.read()
            parts.append(f"// ═══ {rel} ═══\n{content}")
        except FileNotFoundError:
            parts.append(f"// ═══ {rel} — NOT FOUND ═══")
    return "\n\n".join(parts)

def post_comment(repo, pr_number, body, token):
    url = f"https://api.github.com/repos/{repo}/issues/{pr_number}/comments"
    data = json.dumps({"body": body}).encode()
    req = urllib.request.Request(url, data=data, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/json",
    }, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"GitHub API error: {e.code} {e.reason}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"Network error: {e.reason}") from e

def main():
    api_key      = os.environ["ANTHROPIC_API_KEY"]
    github_token = os.environ["GITHUB_TOKEN"]
    pr_number    = os.environ.get("PR_NUMBER", "1")
    repo         = os.environ.get("REPO", "robvagin-beep/gone-player")

    base = os.path.dirname(os.path.abspath(__file__))
    sources = load_sources(base)

    original_len = len(sources)
    MAX = 180_000
    if original_len > MAX:
        cut = sources.rfind("\n", 0, MAX)
        sources = sources[:cut if cut > 0 else MAX]
        trunc = f"\n\n> ⚠️ Source truncated to {len(sources):,} of {original_len:,} chars."
    else:
        trunc = f"\n\n> ✅ Full source: {original_len:,} chars."


    ITERATIVE_PROTOCOL = """
## Iterative Refinement Protocol — five passes, output Pass 5 only.

PASS 1 — Initial sweep: list every candidate issue, no filtering.
PASS 2 — Self-critique: discard pattern-matches that aren't real failures;
  check CLAUDE.md "Already Resolved" / "Known Tech Debt" sections.
PASS 3 — Industry pattern check: compare to shipping production code
  (Apple sample apps, WWDC sessions, open-source equivalents like Mixxx).
  Cite specific techniques where applicable.
PASS 4 — Adversarial self-critique: steelman opposition to each finding.
  Could the existing code be intentionally non-standard for a reason?
PASS 5 — Final synthesis (only output):
  For each surviving issue:
  - Title
  - Location (file:line)
  - Mechanism (root cause, not symptom)
  - Real-world impact (concrete user-visible effect)
  - Fix (drop-in Swift code where possible)
  - Risk (what could regress)
  Rank by impact. Cap at 7 most consequential. If a category is clean, say so.
"""

    client = anthropic.Anthropic(api_key=api_key)
    message = call_claude_with_retry(client,
        model="claude-opus-4-7",
        max_tokens=12000,
        thinking={"type": "adaptive"},
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": ITERATIVE_PROTOCOL + "\n\n## Source\n\n" + sources}],
    )
    body = "\n\n".join(b.text for b in message.content if b.type == "text")
    comment = (
        f"## 🎛️ XY FX System — Opus 4.7 + Extended Thinking + Iterative Refinement\n\n"
        f"{body}{trunc}\n\n---\n"
        f"*Audit by claude-opus-4-7 ({message.usage.input_tokens:,} in / {message.usage.output_tokens:,} out)*"
    )
    post_comment(repo, pr_number, comment, github_token)
    print("XY FX audit posted.")

if __name__ == "__main__":
    main()
