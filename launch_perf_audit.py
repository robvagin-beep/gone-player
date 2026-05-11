#!/usr/bin/env python3
"""
Cold-start launch performance audit (Opus 4.7 + extended thinking + iterative refinement).
Target: minimize time from icon click to interactive UI.
"""
import os, anthropic, urllib.request, urllib.error, json, time

LAUNCH_FILES = [
    "GONE/GONEApp.swift",
    "GONE/PlayerState.swift",
    "GONE/PlayerState+Playback.swift",
    "GONE/PlayerState+Playlists.swift",
    "GONE/AudioEngine.next.swift",
    "GONE/ArtworkCache.swift",
    "GONE/RootView.swift",
    "GONE/FullPlayerView.swift",
    "GONE/WindowSnapManager.swift",
    "GONE/DesignTokens.swift",
]

SYSTEM_PROMPT = """You are a senior macOS performance engineer auditing the cold-start
sequence of GONE Player.

User-stated priority: launch must be as fast as possible. Currently from icon click
to interactive UI feels slower than it should for a native SwiftUI app.

Domain knowledge you MUST apply:

- AppKit/SwiftUI launch sequence: applicationDidFinishLaunching → SwiftUI WindowGroup
  body → first frame → first paint. Anything synchronous in this chain delays first paint.
- Lazy initialization: stored properties initialized in PlayerState.init() run on the
  main thread BEFORE first frame. AVAudioEngine setup, ArtworkCache prune, persisted
  settings load — all candidates for lazy/async deferral.
- AVAudioEngine.start() can take 100-500ms on first call. Should it be deferred to
  first playback attempt instead of running at launch?
- UserDefaults reads at launch: many @AppStorage / settings reads — these are
  property-list deserialization, not free.
- ArtworkCache.prune() on launch: file system traversal of cache directory. Should
  run on background queue with .background QoS, not block launch.
- Window configuration: setting collectionBehavior, level, frame — fast individually
  but Mach IPC to WindowServer adds up.
- SwiftUI view tree size: large initial body computation delays first paint. Are
  any views over-eagerly constructed before they're needed?
- Persisted state restoration: tracks list, last-played, snap state — disk I/O.
- Image asset decoding: SF Symbols, custom logos — defer non-critical assets.

Focus areas:
1. Synchronous work on main thread before first paint
2. Engine initialization (lazy vs eager)
3. UserDefaults / settings load patterns
4. Cache pruning frequency (should it really run every launch?)
5. SwiftUI view body cost (heavy initial computation)
6. Font / image asset preload
7. Window configuration call ordering
8. Async work that COULD be deferred to after first paint
"""

ITERATIVE_PROTOCOL = """
## Iterative Refinement Protocol — execute internally, output only the final synthesis

Perform FIVE passes internally. Output only Pass 5.

**PASS 1 — Initial sweep**: every candidate launch-time cost, no filtering.

**PASS 2 — Self-critique**: discard items that don't actually run on main thread
  before first paint, or that are negligibly cheap.

**PASS 3 — Industry pattern check**: compare to Apple's recommendations from WWDC
  "App Startup Time" sessions, Instruments App Launch template, Apple sample code
  for music apps (e.g., Apple Music's launch sequence as documented in WWDC).
  Cite specific Instruments measurement techniques.

**PASS 4 — Adversarial self-critique**: steelman the opposition. Some "deferable"
  work may need to be eager for correctness (e.g., snap state restoration must
  happen before window is shown to avoid visual jump). Catch yourself.

**PASS 5 — Final synthesis (the only output)**:

For each surviving issue:
- **Title**
- **Location** (file:line range)
- **Stage of launch** (pre-paint / first-paint / post-paint)
- **Estimated cost** (ms, or relative if uncertain)
- **Real-world impact** (e.g., "saves ~80ms before first interactive frame")
- **Fix** (concrete Swift code or pattern)
- **Risk** (what could break — visual flicker, lost state, etc.)

Rank by ms saved. Cap at 7 most consequential.
"""

def call_claude_with_retry(client, **kwargs):
    for attempt in range(3):
        try:
            return client.messages.create(**kwargs)
        except Exception as e:
            if "rate_limit" in str(e).lower() and attempt < 2:
                print(f"Rate limited, waiting 65s (retry {attempt + 2}/3)")
                time.sleep(65)
            else:
                raise

def load_sources(base):
    parts = []
    for rel in LAUNCH_FILES:
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
    api_key = os.environ["ANTHROPIC_API_KEY"]
    github_token = os.environ["GITHUB_TOKEN"]
    pr_number = os.environ.get("PR_NUMBER", "1")
    repo = os.environ.get("REPO", "robvagin-beep/gone-player")

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

    client = anthropic.Anthropic(api_key=api_key)
    message = call_claude_with_retry(client,
        model="claude-opus-4-7",
        max_tokens=12000,
        thinking={"type": "adaptive"},
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": ITERATIVE_PROTOCOL + "\n\n## Source code\n\n" + sources}],
    )
    body = "\n\n".join(b.text for b in message.content if b.type == "text")
    comment = (
        f"## 🚀 Cold-Start Launch Performance Audit — Opus 4.7 + Extended Thinking + Iterative Refinement\n\n"
        f"{body}{trunc}\n\n---\n*Launch Perf Audit by claude-opus-4-7 "
        f"({message.usage.input_tokens:,} in / {message.usage.output_tokens:,} out)*"
    )
    post_comment(repo, pr_number, comment, github_token)
    print("Launch audit posted.")

if __name__ == "__main__":
    main()
