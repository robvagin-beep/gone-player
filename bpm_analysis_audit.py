#!/usr/bin/env python3
"""
BPM Analysis pipeline audit (Opus 4.7 + extended thinking + iterative refinement).
Target: minimize time-to-BPM after dropping a folder of tracks.
"""
import os, anthropic, urllib.request, urllib.error, json, time

BPM_FILES = [
    "GONE/LibraryScanner.swift",
    "GONE/PlayerState+Analysis.swift",
    "GONE/PlayerState+Playlists.swift",
    "GONE/AnalysisProgressFeed.swift",
    "GONE/Track.swift",
    "GONE/AudioEngine.next.swift",
]

SYSTEM_PROMPT = """You are a senior DSP / audio engineering specialist auditing the
BPM detection pipeline of GONE Player — a macOS DJ preview tool.

User-stated priority: BPM analysis must be as fast as possible. After dropping a
folder with 50–200 tracks, the BPM column should populate rapidly. Currently the
user perceives it as too slow.

Domain knowledge you MUST apply:

- Standard BPM detection algorithms: onset detection (spectral flux, energy,
  high-frequency content), autocorrelation of onset envelope, comb filter bank,
  beat-tracking via dynamic programming.
- Apple-native: AVAudioFile reading, vDSP for FFT/autocorrelation, Accelerate framework.
- Sampling strategy: full-track analysis is expensive; many libraries sample
  only a representative middle section (30–60 seconds) and downsample heavily.
- Concurrency: Swift TaskGroup with bounded concurrency = 2 currently. CPU has
  more cores; can we go higher without thrashing I/O?
- Half/double tempo ambiguity: standard problem with autocorrelation, often
  handled by perceptual bias toward 90–140 BPM.
- File format costs: M4A/AAC decoding is slower than WAV/AIFF; can we read fewer
  frames? Can we use AVAssetReader with a downsampling format converter?
- Caching: BPM values should persist across launches (audit if they do).
- Background priority: .userInitiated vs .utility — what's appropriate?

Focus the audit on:
1. Algorithmic inefficiency (reading too many samples, redundant FFTs)
2. Concurrency limits (is concurrency=2 leaving cores idle?)
3. File reading cost (full decode vs streamed downsample)
4. Cache misses (re-analyzing tracks already analyzed)
5. Main-thread blocking on @Published progress updates at high frequency
6. Memory pressure from accumulated Float buffers
7. Algorithmic improvements possible without changing the algorithm class
"""

ITERATIVE_PROTOCOL = """
## Iterative Refinement Protocol — execute internally, output only the final synthesis

Perform FIVE passes internally. Output only Pass 5.

**PASS 1 — Initial sweep**: every candidate issue, no filtering.

**PASS 2 — Self-critique**: discard pattern-matches that aren't real failures.
  Check CLAUDE.md exclusions if relevant.

**PASS 3 — Industry pattern check**: compare to Mixxx (open source BPM detection),
  aubio library, Apple's WWDC audio sessions, Essentia framework. Cite specific
  techniques from these references where applicable.

**PASS 4 — Adversarial self-critique**: steelman opposition to each finding.
  Is your "industry knowledge" actually accurate? Could the existing code be
  intentionally non-standard for a reason?

**PASS 5 — Final synthesis (the only output)**:

For each surviving issue:
- **Title**
- **Location** (file:line range)
- **Real-world impact** (e.g., "saves ~3 seconds per 100-track folder")
- **Root cause** (mechanism)
- **Fix** (concrete Swift code, drop-in if possible)
- **Risk** (what could break)
- **Expected gain** (quantitative)

Rank by impact. Cap at 7 most consequential. If a category is clean, say so.
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
    for rel in BPM_FILES:
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
        f"## 🥁 BPM Analysis Pipeline Audit — Opus 4.7 + Extended Thinking + Iterative Refinement\n\n"
        f"{body}{trunc}\n\n---\n*BPM Audit by claude-opus-4-7 "
        f"({message.usage.input_tokens:,} in / {message.usage.output_tokens:,} out)*"
    )
    post_comment(repo, pr_number, comment, github_token)
    print("BPM audit posted.")

if __name__ == "__main__":
    main()
