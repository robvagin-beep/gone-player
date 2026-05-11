#!/usr/bin/env python3
"""
Performance audit: reads full source of state + UI files,
asks Claude Opus to find render/rebuild churn, @Published over-mutation,
Canvas invalidation, Task/Timer waste.
"""
import os, anthropic, urllib.request, urllib.error, json

PERF_FILES = [
    "GONE/PlayerState.swift",
    "GONE/RootView.swift",
    "GONE/EQPanelView.swift",
    "GONE/TrackHeaderView.swift",
    "GONE/WaveformView.swift",
    "GONE/CrossfaderBandPanel.swift",
    "GONE/PlaylistView.swift",
    "GONE/TransportView.swift",
    "GONE/SpectrumView.swift",
    "GONE/PeekPanelView.swift",
    "GONE/SplitModeManager.swift",
    "GONE/PlaybackProgressFeed.swift",
    "GONE/SpectrumFeed.swift",
]

SYSTEM_PROMPT = """You are a senior Swift/macOS performance engineer auditing GONE Player.

Focus exclusively on render/rebuild performance. Do NOT flag architecture, style, or threading.

Look for:
1. **@Published over-mutation** — properties written at gesture rate (≥30Hz) that trigger unnecessary view tree rebuilds. For each: name the property, which views subscribe, whether the write can be batched or removed.
2. **SwiftUI rebuild cascade** — which `@ObservedObject` / `@EnvironmentObject` subscriptions cause the widest view invalidation. Flag any `PlayerState` publish that unnecessarily rebuilds unrelated panels.
3. **Canvas invalidation triggers** — Canvas closures that read @Published values they don't need, causing unnecessary redraws. Or Canvas closures that should read a value (for dependency) but don't.
4. **Task / Timer churn** — tasks created per gesture delta that cancel immediately without completing. Timers that fire unnecessarily when the view is off-screen or the state hasn't meaningfully changed.
5. **Expensive view body computations** — computed properties or inline calculations in `.body` that run every rebuild (string formatting, math, allocations).

Output format:
- 🔴 **High impact** — measurable jank on macOS 13 MacBook (older hardware is the target)
- 🟡 **Medium impact** — noticeable on tight loops or fast interaction
- 🟢 **Low impact** — minor, worth fixing when passing through

For each finding: name the specific property/view/closure, describe the cost, suggest the fix in one sentence.
Be direct. No filler. Real issues only."""


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
    for rel in PERF_FILES:
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
        trunc = f"\n\n> ℹ️ Full source: {original_len:,} chars across {len(PERF_FILES)} files."

    ITERATIVE_PROTOCOL = """
## Iterative Refinement Protocol — execute internally, output only the final synthesis

Perform FIVE passes internally. Output only Pass 5.

PASS 1 — Initial sweep: every candidate render churn, @Published over-broadcast,
  Canvas rebuild waste, Task leak, .onChange chain over-firing.

PASS 2 — Self-critique: check CLAUDE.md "Already Resolved" section. Discard
  pattern-matches that are documented as intentional.

PASS 3 — Industry pattern check: Apple's SwiftUI WWDC sessions on performance
  ("Demystify SwiftUI Performance"), TimelineView vs Timer patterns,
  ObservableObject isolation patterns. Cite specific recommendations.

PASS 4 — Adversarial self-critique: steelman opposition to each finding.
  Some @Published broadcasts may be load-bearing for view updates user expects.

PASS 5 — Final synthesis (only output):

For each surviving issue:
- **Title**
- **Location** (file:line)
- **Hot-path frequency** (how often it fires: 60Hz, on-tap, etc.)
- **CPU/GPU cost** (estimate or relative)
- **Real-world impact** (what user sees on older MacBook)
- **Fix** (concrete Swift code, drop-in)
- **Risk** (what could regress)

Rank by impact. Cap at 7 most consequential. Real issues only.
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
        f"## ⚡ Performance Audit — Opus 4.7 + Extended Thinking + Iterative Refinement\n\n"
        f"{body}{trunc}\n\n---\n*Performance Audit by claude-opus-4-7 "
        f"({message.usage.input_tokens:,} in / {message.usage.output_tokens:,} out)*"
    )
    post_comment(repo, pr_number, comment, github_token)
    print("Performance audit posted.")

if __name__ == "__main__":
    main()
