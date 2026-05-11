#!/usr/bin/env python3
"""
Memory leak & retain cycle audit for GONE Player.
Targets: Task.detached captures, NSWindow/NSPanel lifecycle, timer closures,
actor/ObservableObject ownership, ArtworkCache eviction, waveform array growth.
"""
import os, anthropic, urllib.request, urllib.error, json

MEMORY_FILES = [
    "GONE/GONEApp.swift",
    "GONE/PlayerState.swift",
    "GONE/PlayerState+Playback.swift",
    "GONE/PlayerState+Analysis.swift",
    "GONE/PlayerState+Playlists.swift",
    "GONE/AudioEngine.next.swift",
    "GONE/SplitModeManager.swift",
    "GONE/CrossfaderBandPanel.swift",
    "GONE/ArtworkCache.swift",
    "GONE/AnalysisCache.swift",
    "GONE/PlaybackProgressFeed.swift",
    "GONE/SpectrumFeed.swift",
    "GONE/WindowSnapManager.swift",
]

SYSTEM_PROMPT = """You are a senior Swift/macOS memory engineer specializing in
retain cycles, memory leaks, and unbounded growth in AppKit/SwiftUI apps.

You have deep expertise in:
- ARC retain cycles: strong reference cycles in closures, delegates, timers
- Swift Concurrency captures: Task.detached [self] vs [weak self] — when each is safe
- @ObservableObject / @StateObject ownership chains
- NSWindow / NSPanel lifecycle — when windows leak (missing close observers, strong delegates)
- Actor isolation and accidental strong captures across actor boundaries
- NSCache eviction behavior — what triggers it, what prevents it
- Value-type (struct) copy-on-write overhead with large payloads
- Timer strong references: RunLoop retains timers; timers retain their closure target

Critical context for GONE Player:
- PlayerState is @MainActor ObservableObject — it's the root state object
- AudioEngineNext.shared and .secondary are static stored properties (never released)
- Task.detached for BPM/waveform have NO stored cancellation handles (known tech debt)
- ArtworkCache is a final class with NSCache<NSString, NSImage> — 300 count limit
- AnalysisCache is an actor — writes are coalesced via flushSoon
- SplitModeManager creates a second PlayerState on activate() and nils it on deactivate()
- CrossfaderBandPanel.swift is an NSPanel that floats between two player windows
- timers use RunLoop.main.add(timer, forMode: .common) — RunLoop retains them"""

RESEARCH_PROMPT = """## Audit objective

Find every memory leak, retain cycle, and unbounded-growth pattern in GONE Player.

### 1. Retain cycles in closures
- Timer closures that capture `self` strongly (timers are retained by RunLoop,
  which retains their closure, which retains self — classic cycle)
- Task.detached / Task { } closures capturing self — when is [weak self] required?
- NotificationCenter / KVO observers that are never removed
- NSWindow close/resize callbacks with strong self captures

### 2. Task.detached leaks
- Tasks with `try? await Task.sleep` inside a loop that catches CancellationError with `try?`
  — these never terminate even after the owning object is released
- `Task.detached { [self] in ... }` — explicitly extends lifetime, intentional?
- Analysis pipeline: 100-track import fires N tasks with no cancellation handle.
  What happens to memory if the user closes the window mid-import?

### 3. NSWindow / NSPanel lifecycle
- CrossfaderBandPanel: is it properly released when Split Mode deactivates?
- Does the panel hold strong references to the two player windows?
- PeekPanel: timer-based show/hide — does the timer capture the panel?
- Any windowWillClose / deinit that removes observers?

### 4. PlayerState lifecycle in Split Mode
- SplitModeManager.activate() creates PlayerState(engine: .secondary)
- SplitModeManager.deactivate() sets secondaryState = nil
- Are there any other strong references to secondaryState that prevent dealloc?
  (EnvironmentObject injection, closures, Task captures)
- AudioEngineNext.secondary is static — does it hold back-references to PlayerState?

### 5. Unbounded growth
- `tracks: [Track]` with `waveform: [Float]` (84 floats per track) — bounded by playlist size
- ArtworkCache NSCache: countLimit=300, but 300 NSImages at full resolution could be 300 MB
  — is there a byte limit?
- AnalysisCache `map: [String: AnalysisCacheEntry]` — grows without bound in memory,
  only pruned on disk. Large libraries: how many entries? Memory cost?
- SpectrumFeed: `@Published var data: [Float]` at 60Hz — retained per frame?

### 6. @ObservableObject subscription leaks
- SwiftUI creates Combine subscriptions for every @ObservedObject / @EnvironmentObject
- If a View is removed but its subscriptions aren't cancelled (retain cycle via AnyCancellable)
- XYPadState, AnalysisProgressFeed, SplitModeManager — are they all properly scoped?

### 7. Specific patterns to audit
For each issue found:
- File + approximate line
- Mechanism (why it leaks / grows)
- Real-world scenario that triggers it (e.g., "import 200 tracks, then close window")
- Fix (minimal code change)
- Risk of fix regressing existing behavior

## Output format
🔴 **Definite leak** — reference cycle proven, object never releases
🟡 **Likely leak** — strong capture in async context, probable cycle
🟢 **Growth risk** — no leak, but unbounded memory growth under real use
✅ **Clean** — area is fine, say so explicitly
"""


def call_claude_with_retry(client, **kwargs):
    import time
    for attempt in range(3):
        try:
            return client.messages.create(**kwargs)
        except Exception as e:
            if "rate_limit" in str(e).lower() and attempt < 2:
                print(f"Rate limited, waiting 65s... (attempt {attempt + 2}/3)")
                time.sleep(65)
            else:
                raise

def load_sources(base):
    parts = []
    for rel in MEMORY_FILES:
        path = os.path.join(base, rel)
        try:
            with open(path, "r", encoding="utf-8") as f:
                content = f.read()
            parts.append(f"// ═══ {rel} ({content.count(chr(10))} lines) ═══\n{content}")
        except FileNotFoundError:
            parts.append(f"// ═══ {rel} — NOT FOUND ═══\n")
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

    base    = os.path.dirname(os.path.abspath(__file__))
    sources = load_sources(base)

    original_len = len(sources)
    MAX = 200_000
    if original_len > MAX:
        cut = sources.rfind("\n", 0, MAX)
        sources = sources[:cut if cut > 0 else MAX]
        trunc = f"\n\n> ⚠️ Source truncated to {len(sources):,} of {original_len:,} chars."
    else:
        trunc = f"\n\n> ℹ️ Full source: {original_len:,} chars across {len(MEMORY_FILES)} files."

    ITERATIVE_PROTOCOL = """
## Iterative Refinement Protocol — five passes, output Pass 5 only.

PASS 1: list every retain cycle and unbounded-growth candidate.
PASS 2: self-critique — check CLAUDE.md "Already Resolved" and "Known Tech Debt".
  Statics (AudioEngineNext) never release — don't flag as leak.
  Task.detached [self] in analysis — intentional per CLAUDE.md, check if cycle closes.
PASS 3: industry patterns — Apple's ARC docs, Swift Concurrency lifecycle proposals,
  NSCache sizing best practices.
PASS 4: adversarial — steelman. Could strong captures be intentional to guarantee
  completion of in-flight audio operations?
PASS 5: final synthesis. Cap at 7 most consequential. Rank by real-world memory impact.
"""

    client = anthropic.Anthropic(api_key=api_key)
    message = call_claude_with_retry(client,
        model="claude-opus-4-7",
        max_tokens=12000,
        thinking={"type": "adaptive"},
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": ITERATIVE_PROTOCOL + "\n\n" + RESEARCH_PROMPT + "\n\n## Source files\n\n" + sources}],
    )
    body = "\n\n".join(b.text for b in message.content if b.type == "text")
    comment = (
        "## 🧠 Memory Leak & Retain Cycle Audit — Opus 4.7 + Extended Thinking\n\n"
        f"{body}{trunc}\n\n---\n"
        f"*Memory Audit by claude-opus-4-7 ({message.usage.input_tokens:,} in / {message.usage.output_tokens:,} out)*"
    )
    post_comment(repo, pr_number, comment, github_token)
    print("Memory audit posted.")

if __name__ == "__main__":
    main()
