#!/usr/bin/env python3
"""
Hang / freeze audit: looks for the root cause of a progressive hang in GONE Player.
Symptom: app loads fine, tracks play, then after some time freezes with spinning beachball.
Uses extended thinking for deeper analysis.
"""
import os
import anthropic
import urllib.request
import urllib.error
import json

# Files most likely involved in a hang: audio engine, timers, async tasks, import pipeline
HANG_FILES = [
    "GONE/GONEApp.swift",
    "GONE/PlayerState.swift",
    "GONE/PlayerState+Playback.swift",
    "GONE/PlayerState+Analysis.swift",
    "GONE/PlayerState+Playlists.swift",
    "GONE/AudioEngine.next.swift",
    "GONE/LibraryScanner.swift",
    "GONE/PlaybackProgressFeed.swift",
    "GONE/WindowSnapManager.swift",
    "GONE/SplitModeManager.swift",
    "GONE/ArtworkCache.swift",
]

SYSTEM_PROMPT = """You are a senior Swift/macOS concurrency and performance engineer
specializing in diagnosing hangs, deadlocks, and spinning beachballs (SPOD) in AppKit/SwiftUI apps.

You have deep expertise in:
- Main thread blocking causes (synchronous I/O, lock contention, DispatchQueue.main.sync)
- Timer accumulation and runloop starvation
- Swift Concurrency (Task, actor, async/await) pitfalls
- AVAudioEngine render thread / main thread interaction
- RunLoop modes and timer firing under load
- Memory pressure triggering GC / page-outs that stall the main thread
- @MainActor over-use blocking the cooperative thread pool

Your job is to find the root cause of a PROGRESSIVE hang — one that appears after normal use,
not immediately on launch. Focus on patterns that accumulate over time."""

RESEARCH_PROMPT = """## Symptom

GONE Player (macOS 13+, SwiftUI/AppKit) exhibits a progressive hang:
1. App launches correctly
2. Tracks load and display
3. Playback works
4. After some time (could be after importing many tracks, playing several tracks,
   or just after extended use) — the app freezes. Spinning beachball appears on cursor.
   The freeze appears total (UI stops responding).

## Your task

Read the full source below. Find every code pattern that could cause a PROGRESSIVE HANG.
"Progressive" means it accumulates — it won't cause an instant freeze but will degrade
over time or after repeated operations.

Focus on these categories:

### 1. Main-thread blocking
- Any `DispatchQueue.main.sync` (instant deadlock if called from main)
- Any synchronous file I/O, AVAudioFile read, or Data(contentsOf:) on main thread
- Any `@MainActor` function that awaits something that can take unbounded time
- Any `semaphore.wait()` or `NSLock.lock()` on main thread that could block

### 2. Timer accumulation / runloop starvation
- Timers created on track load / play that are NOT invalidated on the next load
- Multiple concurrent `progressTimer`, `holdSeekTimer`, `slicerTimer`, `lfoTimer` instances
  — if old ones aren't stopped before new ones start, they pile up and saturate the runloop
- Timers firing at 60Hz with expensive closures that run on `.main` run loop

### 3. Task pile-up without cancellation
- `Task.detached` calls for BPM analysis or waveform computation with no stored handle
  → if the user imports a large folder (100+ tracks), can concurrent analysis tasks
  overwhelm the cooperative thread pool and starve the main actor?
- `Task.sleep` inside a loop that ignores `CancellationError` (try?) — leaked tasks
  that never terminate
- Animation tasks in EQCurveView (animTask) or typewriter tasks — if onAppear fires
  repeatedly, do tasks stack up?

### 4. AVAudioEngine / render thread interaction
- Any main-thread operation that waits for the render thread (implicit or explicit)
- `engine.stop()` / `engine.start()` called from main thread while render is active
  — these are blocking calls
- `playerNode.scheduleBuffer` completion closures: do any dispatch back to main sync?
- `removeTap` / `installTap` from main thread while tap is firing — potential deadlock

### 5. Memory pressure causing stall
- Waveform Float arrays accumulating per track (no eviction)
- Artwork Data stored in Track struct (value type → copied on every array mutation)
  — CLAUDE.md flags this as "significant overhead during import batches"
- ArtworkCache NSCache + disk: is disk write blocking at any point?
- Large imports (100+ tracks): does the tracks array balloon and cause page pressure?

### 6. SwiftUI @MainActor queue saturation
- High-frequency @Published writes (xyPoint, lpfCutoff at 60Hz) that cause
  SwiftUI to queue thousands of pending view updates — can this overflow the main actor queue?
- `withAnimation` wrapping high-frequency state changes

### 7. Specific patterns to flag
For EACH issue found:
- Quote the exact file and the specific lines
- Explain WHY it causes a progressive hang (not an instant crash)
- Rate severity: 🔴 likely cause / 🟡 contributing factor / 🟢 unlikely but possible
- Suggest the minimal fix

## Output format

### Executive summary (3-5 sentences: what is the most likely root cause)

### 🔴 Most likely causes (each with file:line, mechanism, fix)

### 🟡 Contributing factors

### 🟢 Unlikely but worth noting

### Recommended investigation order
(What to instrument / add logging to first, to narrow down the actual hang in a real run)
"""



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

def load_sources(base: str) -> str:
    parts = []
    for rel in HANG_FILES:
        path = os.path.join(base, rel)
        try:
            with open(path, "r", encoding="utf-8") as f:
                content = f.read()
            parts.append(f"// ═══ {rel} ({content.count(chr(10))} lines) ═══\n{content}")
        except FileNotFoundError:
            parts.append(f"// ═══ {rel} — NOT FOUND ═══\n")
    return "\n\n".join(parts)


def post_comment(repo: str, pr_number: str, body: str, token: str) -> None:
    url = f"https://api.github.com/repos/{repo}/issues/{pr_number}/comments"
    data = json.dumps({"body": body}).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"GitHub API error: {e.code} {e.reason}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"Network error: {e.reason}") from e


def main() -> None:
    api_key      = os.environ["ANTHROPIC_API_KEY"]
    github_token = os.environ["GITHUB_TOKEN"]
    pr_number    = os.environ.get("PR_NUMBER", "1")
    repo         = os.environ.get("REPO", "robvagin-beep/gone-player")

    base = os.path.dirname(os.path.abspath(__file__))
    sources = load_sources(base)

    original_len = len(sources)
    MAX = 200_000
    if original_len > MAX:
        cut = sources.rfind("\n", 0, MAX)
        sources = sources[:cut if cut > 0 else MAX]
        trunc = f"\n\n> ⚠️ Source truncated to {len(sources):,} of {original_len:,} chars."
    else:
        trunc = f"\n\n> ℹ️ Full source: {original_len:,} chars across {len(HANG_FILES)} files."

    client = anthropic.Anthropic(api_key=api_key)
    message = call_claude_with_retry(client,
        model="claude-sonnet-4-6",
        max_tokens=8000,
        system=SYSTEM_PROMPT,
        messages=[{
            "role": "user",
            "content": f"{RESEARCH_PROMPT}\n\n## Source files\n\n{sources}",
        }],
    )

    body = message.content[0].text

    comment = (
        "## 🧊 Hang / Freeze Audit — Progressive Blocking Analysis\n\n"
        f"{body}{trunc}\n\n---\n"
        f"*Hang Audit by claude-sonnet-4-6 "
        f"({message.usage.input_tokens:,} in / {message.usage.output_tokens:,} out)*"
    )

    post_comment(repo, pr_number, comment, github_token)
    print("Hang audit posted successfully.")


if __name__ == "__main__":
    main()
