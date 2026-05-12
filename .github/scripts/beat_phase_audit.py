"""
Beat-phase detection audit — runs on Anthropic servers via GitHub Actions.

Audits the estimateBeatGridOffset algorithm for correctness and musical alignment quality.
Focus: does the phase detection approach actually find the first beat reliably,
and does the confidence metric correctly reflect alignment quality?

Reference implementations for comparison: Pioneer CDJ/Rekordbox, Traktor, Serato.
All three use autocorrelation-based onset detection with phase refinement — same family
as the implementation here.
"""

import os
import json
import urllib.request
import urllib.error
import anthropic

SYSTEM = """You are a senior DSP engineer and DJ software expert auditing a beat-phase
detection algorithm added to a macOS DJ preparation tool (GONE Player).

The algorithm's goal: given a decoded audio signal (11025 Hz mono, hopSize=128 → ~86.1 fps
onset frames) and a known BPM, find the phase offset of the first beat in seconds.

This is the same problem solved by Pioneer Rekordbox, Native Instruments Traktor,
Serato DJ, and djay Pro. The reference implementations use:
  1. Onset strength envelope (half-wave rectified energy differential)
  2. Phase scan over [0, beatDuration) at multiple candidates
  3. Sub-frame interpolation for sub-sample precision
  4. Confidence metric normalized against the score distribution

Audit this implementation against that reference. Be concrete: name functions, line numbers,
specific failure modes. Do not re-flag items already listed in CLAUDE.md's 'Already Resolved' section.

Audit dimensions — cover ALL of these:

1. ONSET QUALITY
   - Is half-wave rectified energy differential a sufficient onset function for kick/snare detection?
   - Would spectral flux give better results for pitched onsets (melodic tracks, no kick)?
   - What happens for tracks with very sparse onsets (ambient, pad-heavy material)?

2. PHASE SCAN CORRECTNESS
   - 64 candidates over [0, beatDuration): is this resolution adequate?
     At 128 BPM, beatDuration ≈ 0.469s → step = 7.3ms per candidate. Is 7ms sufficient?
   - Hann window ±1 frame at ~11.6ms per frame: does this correctly tolerate jitter?
   - For long tracks (5+ minutes), does summing over the entire onset array bias results
     toward the high-energy section (e.g., drop at 2:00)?

3. SUB-FRAME REFINEMENT
   - Is parabolic interpolation implemented correctly?
   - Does the modular wrap (bestCI ± 1 using % candidateN) produce correct results
     at the boundaries (bestCI = 0 and bestCI = 63)?

4. CONFIDENCE METRIC
   - Z-score: does it correctly reflect how much better the best candidate is vs noise?
   - The mapping 1 - 1/(1 + z*0.5): what z-score produces confidence 0.30 (the threshold)?
     Is this threshold appropriate for DJ use (false positives cause visible grid misalignment)?
   - For a 4/4 kick track at 128 BPM: what realistic z-score range is expected?
   - For an ambient pad track: what z-score range is expected?

5. MUSICAL CORRECTNESS
   - After phase detection, does the grid align to the *first* beat at time 0+offset,
     or to some beat in the middle of the track?
   - How does the result behave for tracks with a count-in (4 bars of silence before drop)?
   - 4/4 assumption: is it correct to always phase-scan with the full beatDuration,
     or would scanning with barDuration (4×beatDuration) improve downbeat alignment?

6. INTEGRATION SAFETY
   - Is estimateBeatGridOffset called AFTER BPM detection in the same pass?
   - Is the onset array shared correctly (computed once, used for both BPM autocorrelation
     and phase detection)?
   - Is the result written to Track.beatGridOffset and Track.beatGridConfidence correctly?
   - Is there a guard against applying a stale analysis result to the wrong track?

7. PERFORMANCE
   - Worst case: 128 BPM, 10-minute track at 86.1fps → how many onset frames?
   - Phase scan: 64 candidates × N frames iterations — is this O(N) or O(N×candidates)?
   - Is this safe to run synchronously after the BPM analysis in the same Task.detached?

Output format — group by severity:
🔴 Critical — wrong result, crash, or grid misaligned for a large class of tracks
🟡 Warning  — degraded accuracy for specific track types, confidence metric miscalibrated
🟢 Info     — minor improvement, future consideration, edge case

End with one sentence: overall beat-phase detection quality rating
(Production-ready / Needs tuning / Fundamentally flawed) + why.
"""


def call_claude(client: anthropic.Anthropic, system: str, content: str) -> str:
    for attempt in range(4):
        try:
            msg = client.messages.create(
                model="claude-opus-4-7",
                max_tokens=4000,
                system=system,
                messages=[{"role": "user", "content": content}],
            )
            return msg.content[0].text
        except Exception as e:
            if attempt < 3 and any(c in str(e) for c in ["529", "503", "429", "rate_limit", "overloaded"]):
                import time
                print(f"Rate limited, retry {attempt + 2}/3 in 65s...")
                wait = [60, 90, 120][attempt]; print(f"  API throttle — waiting {wait}s..."); time.sleep(wait)
            else:
                raise


def post_comment(repo: str, pr_number: str, body: str, token: str) -> None:
    url = f"https://api.github.com/repos/{repo}/issues/{pr_number}/comments"
    data = json.dumps({"body": body}).encode()
    req = urllib.request.Request(
        url, data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        resp.read()


def load_file(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return f"(file not found: {path})"


def main() -> None:
    api_key      = os.environ["ANTHROPIC_API_KEY"]
    github_token = os.environ["GITHUB_TOKEN"]
    pr_number    = os.environ["PR_NUMBER"]
    repo         = os.environ["REPO"]

    scanner_src  = load_file("GONE/LibraryScanner.swift")
    track_src    = load_file("GONE/Track.swift")
    analysis_src = load_file("GONE/PlayerState+Analysis.swift")
    claude_md    = load_file("CLAUDE.md")

    MAX = 60_000
    if len(scanner_src) > MAX:
        scanner_src = scanner_src[:MAX] + "\n... (truncated)"

    content = f"""## CLAUDE.md (architecture rules + already-resolved list)
{claude_md}

## Track.swift (data model — beat grid fields)
```swift
{track_src}
```

## PlayerState+Analysis.swift (analysis pipeline — writes beat grid to Track)
```swift
{analysis_src}
```

## LibraryScanner.swift (audit target — BPM detection + phase detection)
```swift
{scanner_src}
```
"""

    client = anthropic.Anthropic(api_key=api_key)
    result = call_claude(client, SYSTEM, content)

    comment = (
        "## 🎛️ Beat-Phase Detection Audit\n\n"
        f"{result}\n\n"
        "---\n"
        "*Audited by claude-opus-4-7 on Anthropic infrastructure via GitHub Actions*"
    )
    post_comment(repo, pr_number, comment, github_token)
    print("Beat-phase audit posted.")


if __name__ == "__main__":
    main()
