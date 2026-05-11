#!/usr/bin/env python3
"""
AnalysisCache + ArtworkCache audit for GONE Player.
Targets: disk write races, actor isolation, version invalidation,
NSCache eviction, key correctness, corruption scenarios.
"""
import os, anthropic, urllib.request, urllib.error, json

CACHE_FILES = [
    "GONE/AnalysisCache.swift",
    "GONE/ArtworkCache.swift",
    "GONE/PlayerState+Analysis.swift",
    "GONE/LibraryScanner.swift",
    "GONE/Track.swift",
]

SYSTEM_PROMPT = """You are a senior Swift/macOS storage engineer specializing in
on-disk caches, actor isolation, and data integrity in macOS apps.

You have deep expertise in:
- Swift actor isolation rules: what's safe to call from nonisolated context
- NSCache eviction behavior — memory pressure, countLimit vs totalCostLimit
- Atomic file writes — what .atomic guarantees and where it can still fail
- Cache key design — mtime granularity, symlink resolution, APFS clone behavior
- Concurrent actor access patterns — when two Task.detached can race on actor methods
- JSON encode/decode safety with floating-point values (Float vs Double)
- Application Support vs Caches directory — backup policy implications

GONE Player cache architecture:
- AnalysisCache: actor, JSON file in Application Support/GONE/analysis-cache.json
  Keyed by (standardized path, file size, mtime). Writes coalesced via 1.5s debounce.
- ArtworkCache: final class (@unchecked Sendable), NSCache<NSString,NSImage> + disk JPEG
  Stored in Caches/GONE/artwork/<uuid>.jpg. Pruned at launch (>30 days old).
- Both are accessed from Task.detached (off-main) concurrently with UI reads."""

RESEARCH_PROMPT = """## Audit objective

Find every correctness bug, race condition, data-loss scenario, and
design weakness in AnalysisCache and ArtworkCache.

### 1. AnalysisCache actor correctness
- `fileKey(for:)` is `nonisolated` — it calls FileManager from any thread.
  FileManager is thread-safe for attribute reads, but: is `url.standardized`
  guaranteed to produce the same path on every call for the same file?
  What about symlinks, APFS clones, or files on external drives?
- `get(for:)` checks `abs(entry.mtime - f.mtime) < 1.0` — is 1-second tolerance
  correct for HFS+ (1s mtime resolution) and APFS (nanosecond)?
  Could a file modified within the same second as a cache write get a false hit?
- `putBPMAndWaveform` vs separate `putBPM` + `putWaveform` — if both are called
  in rapid succession for the same URL (race between two analysis tasks for the
  same track), can the second write clobber the first's waveform or BPM?
- `flushSoon` uses `Task { await flushSoon() }` — this creates an untracked Task
  inside an actor method. If the actor is deinit'd (impossible for shared singleton
  but worth checking), does this leak?
- The JSON flush in `Task.detached(priority: .utility)` — if the app is force-quit
  between the 1.5s debounce and the write, is any data lost? How much?
- `analyzerVersion` is hardcoded to 1. What is the upgrade path when the algorithm
  changes? Old entries are dropped on load — correct. But if version bumps while
  the app is running (impossible, but): no issue.
- `waveform: [Float]` stored as JSON — Float is 32-bit; JSON encodes as Double.
  Is there precision loss on the round-trip that could cause visible waveform artifacts?

### 2. ArtworkCache thread safety
- `@unchecked Sendable` — the class is manually responsible for thread safety.
  NSCache is thread-safe. FileManager operations are individually thread-safe.
  But the `store` method: reads `fileExists`, then dispatches `writeToDisk` async.
  Two concurrent `store` calls for the same UUID can both pass `fileExists` and
  both write. `.atomic` write makes the result safe, but is there a window where
  `image(for:)` returns nil between the two writes?
- `image(for:)` reads from disk synchronously on the calling thread.
  `dispatchPrecondition(condition: .notOnQueue(.main))` is only in DEBUG.
  Is there any code path that could call this from the main thread in Release?
- `prune()` runs on `.background` at launch. `image(for:)` can run concurrently
  on `.userInitiated`. Both access the same directory.
  If prune deletes a file that image(for:) just found but hasn't read yet — is that safe?
- The 30-day prune cutoff uses `creationDateKey` not `contentModificationDateKey`.
  If a file is overwritten (store called again for same UUID), its creation date
  doesn't update. Is this the correct expiry signal?
- NSCache `countLimit = 300` — no `totalCostLimit`. 300 NSImages at 256×256 pixels,
  RGBA = 256KB each → up to 75 MB in memory. Is this acceptable?
  Should there be a byte-based limit?

### 3. Cache invalidation correctness
- File moved to a different path (user reorganizes folder): AnalysisCache key is
  by standardized path — the old entry becomes orphaned (never evicted from memory
  map). Over many sessions with reorganized libraries, does the in-memory map grow?
- File renamed but content unchanged: new path = cache miss → re-analysis.
  Is this the desired behavior? (Yes, per design, but flag as a UX note.)
- External drive disconnected: `fileKey(for:)` calls `attributesOfItem` which will
  fail → returns nil → cache miss. Correct. But does the error propagate cleanly?
- `analyzerVersion` bump scenario: all waveforms are recomputed on next launch.
  With a 200-track library this means 200 full-track decodes. Should there be
  a migration path instead of wholesale invalidation?

### 4. ArtworkCache and AnalysisCache interaction
- `analyzeBPMWithWaveform` stores waveform in AnalysisCache via `putBPMAndWaveform`.
  `ArtworkCache.store` is called from `readMetadata` in LibraryScanner.
  Both are called during import — do they compete for I/O in a way that matters?
- `computeWaveformAndCommit` checks AnalysisCache hit first. `analyzeBPMAndCommit`
  also stores waveform on success. If both run concurrently for the same track
  (edge case: waveform pipeline starts before BPM pipeline hits cache),
  can the state be inconsistent?

### 5. Specific patterns to flag
For each issue:
- File + approximate line
- Exact failure scenario (file system state + app state that triggers it)
- Data visible impact (wrong BPM shown, artwork missing, corruption)
- Fix with code snippet
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
    for rel in CACHE_FILES:
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
        trunc = f"\n\n> ℹ️ Full source: {original_len:,} chars across {len(CACHE_FILES)} files."

    ITERATIVE_PROTOCOL = """
## Iterative Refinement Protocol — five passes, output Pass 5 only.

PASS 1: every cache key design, race condition, data-loss, and growth candidate.
PASS 2: self-critique — distinguish theoretical from observable. Check CLAUDE.md exclusions.
  ArtworkCache double-write race is documented as "acceptable" — do not re-flag.
PASS 3: compare to Apple's NSURLCache, URLSession disk cache, and open-source
  cache implementations (Kingfisher, Nuke) for best practices.
PASS 4: adversarial — could the 1.5s debounce window be problematic on sudden quit?
  What does macOS guarantee about SIGTERM → write window?
PASS 5: synthesis. Cap at 6 most consequential. Include precise file:line and fix.
"""

    client = anthropic.Anthropic(api_key=api_key)
    message = call_claude_with_retry(client,
        model="claude-opus-4-7",
        max_tokens=10000,
        thinking={"type": "adaptive"},
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": ITERATIVE_PROTOCOL + "\n\n" + RESEARCH_PROMPT + "\n\n## Source files\n\n" + sources}],
    )
    body = "\n\n".join(b.text for b in message.content if b.type == "text")
    comment = (
        "## 💾 AnalysisCache + ArtworkCache Audit — Opus 4.7 + Extended Thinking\n\n"
        f"{body}{trunc}\n\n---\n"
        f"*Cache Audit by claude-opus-4-7 ({message.usage.input_tokens:,} in / {message.usage.output_tokens:,} out)*"
    )
    post_comment(repo, pr_number, comment, github_token)
    print("Cache audit posted.")

if __name__ == "__main__":
    main()
