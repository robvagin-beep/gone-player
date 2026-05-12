"""
Beat-grid overlay audit — runs on Anthropic servers via GitHub Actions.

Focuses on four concerns that Claude Code cannot easily verify locally:
  1. Render-path allocation budget (no per-tick Path at 30fps)
  2. LOD density guard correctness for long tracks / high BPM
  3. Hot-cue z-order and Split Mode isolation guarantees
  4. Fallback safety when bpm == 0 or duration == 0
"""

import os
import json
import urllib.request
import urllib.error
import anthropic

SYSTEM = """You are a senior Swift/macOS graphics engineer auditing a beat-grid overlay
added to a Canvas-based progress ruler in a macOS DJ player app (GONE Player).

The Canvas redraws at 30 fps during playback. Every allocation or stroke call inside
the Canvas closure directly affects frame budget. Be concrete: name lines, name numbers,
name edge cases. Do not re-flag items already listed in CLAUDE.md's 'Already Resolved' section.

Audit dimensions — cover ALL of these:

1. ALLOCATION BUDGET
   - How many Path structs are allocated per frame?
   - Are there any per-tick allocations inside the beat loop?
   - Does the implementation batch ticks into ≤3 paths before stroking?

2. LOD / DENSITY GUARD
   - At 128 BPM, 6-minute track, 700px ruler width: what does pxPerBeat equal?
     Verify the LOD tier correctly kicks in (beats suppressed, only bars drawn).
   - At 80 BPM, 3 minutes, 700px: same analysis.
   - What happens when pxPerBar < 3? Does phraseOnly mode engage correctly?
   - Is the beat range loop bounded (firstBeat / lastBeat correct)?

3. HOT CUE Z-ORDER
   - Are hot cues drawn AFTER the beat grid in the Canvas render pass?
   - Can beat ticks visually obscure hot cue markers?

4. SPLIT MODE ISOLATION
   - ProgressRulerRow reads bpm/duration from state.current — each PlayerState
     instance is independent. Does the beat grid correctly use per-player values?

5. FALLBACK SAFETY
   - bpm == 0: does the grid skip without crash or empty-path stroke?
   - duration == 0: same.
   - meterBeatsPerBar == 0: guarded?
   - beatDuration not finite (NaN/Inf): guarded?

6. FUTURE READINESS
   - Is beatGridOffset plumbed through correctly for a future offset-detection pass?
   - Is meterBeatsPerBar wired so a non-4/4 meter can be passed later?

Output format — group by severity:
🔴 Critical — crash, data loss, broken canvas invariant
🟡 Warning  — perf regression, incorrect LOD, wrong z-order
🟢 Info     — minor style, missed guard, future consideration

End with one sentence: overall render safety rating (Safe / Marginal / Unsafe) + why.
"""


def call_claude(client, system: str, content: str) -> str:
    import time
    for attempt in range(4):
        try:
            msg = client.messages.create(
                model="claude-opus-4-7",
                max_tokens=3000,
                system=system,
                messages=[{"role": "user", "content": content}],
            )
            return msg.content[0].text
        except Exception as e:
            if attempt < 3 and any(c in str(e) for c in ["529", "503", "429", "rate_limit", "overloaded"]):
                wait = [60, 90, 120][attempt]
                print(f"  API throttle ({e}) — waiting {wait}s (attempt {attempt+1}/4)...")
                time.sleep(wait)
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

    waveform_src = load_file("GONE/WaveformView.swift")
    claude_md    = load_file("CLAUDE.md")

    MAX = 60_000
    if len(waveform_src) > MAX:
        waveform_src = waveform_src[:MAX] + "\n... (truncated)"

    content = f"""## CLAUDE.md (architecture rules + already-resolved list)
{claude_md}

## WaveformView.swift (full source — audit target)
```swift
{waveform_src}
```
"""

    client = anthropic.Anthropic(api_key=api_key)
    result = call_claude(client, SYSTEM, content)

    comment = (
        "## 🎵 Beat-Grid Overlay Audit\n\n"
        f"{result}\n\n"
        "---\n"
        "*Audited by claude-opus-4-7 on Anthropic infrastructure via GitHub Actions*"
    )
    post_comment(repo, pr_number, comment, github_token)
    print("Beat-grid audit posted.")


if __name__ == "__main__":
    main()
