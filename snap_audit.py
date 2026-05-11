#!/usr/bin/env python3
"""
WindowSnap state machine audit — dock/expand sequence, timer correctness,
AppKit/SwiftUI bridge, window lifecycle edge cases.
"""
import os, anthropic, urllib.request, urllib.error, json

SNAP_FILES = [
    "GONE/WindowSnapManager.swift",
    "GONE/RootView.swift",
    "GONE/GONEApp.swift",
    "GONE/TransportView.swift",
    "GONE/PeekPanelView.swift",
]

SYSTEM_PROMPT = """You are a senior macOS AppKit / SwiftUI engineer auditing GONE Player's window snap system.

GONE Player magnetizes its window to screen edges. The snap system is the most delicate subsystem.

Critical invariants you MUST know:

Dock sequence (must be exactly this order):
  1. isSnapping = true
  2. slideOffScreen() starts (Timer-based, NOT NSAnimationContext)
  3. After ~80ms: prepareForSnap() → panels collapse (isSnapping guards updateWindowSize)
  4. In slideOffScreen completion: snapState = .docked → lockFrame() → isSnapping = false

Expand sequence (must be exactly this order):
  1. unlockFrame()
  2. snapState = .expanded, isSnapping = true
  3. restoreFromSnap() immediately → panels open as window slides out
  4. animateFrameTo(savedFrame) runs simultaneously
  5. In completion: isSnapping = false

Hard rules:
- NEVER use NSAnimationContext for off-screen animation (breaks off-screen destinations)
- NEVER set snapState = .docked before animation completes
- NEVER call lockFrame() before slideOffScreen completion
- NEVER remove isSnapping guard in updateWindowSize
- windowResizability = .automatic (NEVER change — .contentSize breaks snap)
- isMovableByWindowBackground = false (NEVER change — breaks vertical drag controls)
- All timers: RunLoop.main.add(timer, forMode: .common)
- Timer callbacks: MainActor.assumeIsolated inside

Audit these specific areas:

1. **State machine correctness**
   - Is the dock/expand sequence preserved exactly as documented?
   - Any path where isSnapping is cleared too early?
   - Any path where snapState transitions happen out of order?

2. **Timer management**
   - Are all timers added to RunLoop.main with .common mode?
   - Are timers invalidated before being reassigned?
   - Any retain cycles in timer closures?

3. **Window geometry**
   - savedFrame capture — is it saved before or after the slide animation?
   - lockFrame / unlockFrame — do they correctly freeze/unfreeze contentSize?
   - Does updateWindowSize correctly skip height changes when isSnapping?

4. **Edge cases**
   - What happens if the user clicks expand during the dock animation?
   - What happens if the screen geometry changes (display disconnect) while docked?
   - PeekPanel visibility — does it appear/disappear at the right snap state transitions?

5. **AppKit / SwiftUI bridge**
   - Window access pattern — resolvedMainWindow() vs NSApp.windows.first?
   - Any SwiftUI state mutation that could fight AppKit window sizing?

Output:
- 🔴 **Critical** — sequence violation, deadlock, or crash
- 🟡 **Warning** — race condition or edge case that breaks UX
- 🟢 **Note** — defensive improvement

If an area is clean, write "✅ [Area]: No issues found."
Reference exact file + approximate line."""


def call_claude_with_retry(client, **kwargs):
    import time
    for attempt in range(3):
        try:
            return client.messages.create(**kwargs)
        except Exception as e:
            if "rate_limit" in str(e).lower() and attempt < 2:
                print(f"Rate limited, waiting 65s before retry {attempt + 2}/3...")
                time.sleep(65)
            else:
                raise

def load_sources(base):
    parts = []
    for rel in SNAP_FILES:
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
        f"## 🧲 WindowSnap State Machine — Opus 4.7 + Extended Thinking + Iterative Refinement\n\n"
        f"{body}{trunc}\n\n---\n"
        f"*Audit by claude-opus-4-7 ({message.usage.input_tokens:,} in / {message.usage.output_tokens:,} out)*"
    )
    post_comment(repo, pr_number, comment, github_token)
    print("Snap audit posted.")

if __name__ == "__main__":
    main()
