#!/usr/bin/env python3
"""
Audit Loop — reads the latest audit comment from Anthropic,
re-sends findings back with full source context, and produces
concrete code-level fixes as a follow-up PR comment.

Triggered automatically when github-actions[bot] posts to the PR.
"""
import os, anthropic, urllib.request, urllib.error, json

# All source files that may be referenced in any audit
ALL_FILES = [
    "GONE/AudioEngine.next.swift",
    "GONE/GONEApp.swift",
    "GONE/PlayerState.swift",
    "GONE/PlayerState+Playback.swift",
    "GONE/PlayerState+Analysis.swift",
    "GONE/PlayerState+Playlists.swift",
    "GONE/PlayerState+EQ.swift",
    "GONE/PlaybackProgressFeed.swift",
    "GONE/SpectrumFeed.swift",
    "GONE/LibraryScanner.swift",
    "GONE/AnalysisCache.swift",
    "GONE/SplitModeManager.swift",
    "GONE/CrossfaderBandPanel.swift",
    "GONE/WindowSnapManager.swift",
    "GONE/RootView.swift",
    "GONE/FullPlayerView.swift",
    "GONE/TrackHeaderView.swift",
    "GONE/WaveformView.swift",
    "GONE/TransportView.swift",
    "GONE/EQPanelView.swift",
    "GONE/PlaylistView.swift",
    "GONE/PeekPanelView.swift",
    "GONE/SettingsPanel.swift",
    "GONE/DesignTokens.swift",
    "GONE/Track.swift",
]

SYSTEM_PROMPT = """You are a senior Swift/macOS engineer working on GONE Player — a native macOS DJ pre-session tool.

## Architecture invariants (NEVER violate)

Audio graph order (fixed):
  playerNode → speedNode → pitchNode → hpfNode → lpfNode → eqNode → distortionNode → delayNode → reverbNode → gateNode → mainMixerNode

Rules:
- Two engine instances: AudioEngineNext.shared (primary) + AudioEngineNext.secondary (clone)
- Views and extensions ALWAYS use state.audioEngine, NEVER AudioEngineNext.shared directly
- All timers: RunLoop.main.add(timer, forMode: .common) — never Timer.scheduledTimer alone
- Timer callbacks: MainActor.assumeIsolated
- updateWindowSize: only called from RootView.onChange
- progressFeed.reset(): use self.progressFeed.reset() in extensions, never PlaybackProgressFeed.shared.reset()
- windowResizability(.automatic) — never change
- isMovableByWindowBackground = false — never change
- WindowSnapManager state machine sequence — never modify without reading the full file
- playbackToken / bumpToken() pattern is VERIFIED CORRECT — do not flag it
- SourceKit "Cannot find type X in scope" = always false positive from PBXFileSystemSynchronizedRootGroup

## Your role

You receive:
1. A previous audit comment that identified specific bugs, risks, or architecture violations.
2. The full source code of the affected files.

Your job is to produce **concrete code fixes** for each finding that is valid.

For each finding:
- Confirm it is real (not a false positive per the invariants above)
- Identify exact file and approximate line
- Write the exact Swift code replacement — show old code then new code
- Keep each fix minimal — do not touch anything not needed for that fix
- If a finding is a false positive per CLAUDE.md invariants, say so explicitly and skip it

Output format for each fix:

### Fix N: [short title]
**File:** `filename.swift`
**Finding:** one sentence describing the bug
**Risk:** Critical / Warning / Note

```swift
// BEFORE
[old code]

// AFTER
[new code]
```

**Why:** one sentence on what this prevents.

---

After all fixes, add:
## Summary
- Total valid findings: N
- Total false positives skipped: N
- Fixes safe to apply immediately: list titles
- Fixes requiring broader refactor first: list titles
"""


def call_claude_with_retry(client, **kwargs):
    import time
    for attempt in range(3):
        try:
            return client.messages.create(**kwargs)
        except Exception as e:
            if ("rate_limit" in str(e).lower() or "529" in str(e)) and attempt < 2:
                wait = 65 if attempt == 0 else 120
                print(f"API throttled, waiting {wait}s before retry {attempt + 2}/3...")
                time.sleep(wait)
            else:
                raise


def load_sources(base):
    parts = []
    for rel in ALL_FILES:
        path = os.path.join(base, rel)
        try:
            with open(path, "r", encoding="utf-8") as f:
                content = f.read()
            parts.append(f"// ═══ {rel} ═══\n{content}")
        except FileNotFoundError:
            pass  # skip missing files silently
    return "\n\n".join(parts)


def post_comment(repo, pr_number, body, token):
    url = f"https://api.github.com/repos/{repo}/issues/{pr_number}/comments"
    data = json.dumps({"body": body}).encode()
    req = urllib.request.Request(url, data=data, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/json",
    }, method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        resp.read()


def main():
    api_key       = os.environ["ANTHROPIC_API_KEY"]
    github_token  = os.environ["GITHUB_TOKEN"]
    pr_number     = os.environ.get("PR_NUMBER", "1")
    repo          = os.environ.get("REPO", "robvagin-beep/gone-player")
    audit_comment = os.environ.get("AUDIT_COMMENT", "")

    if not audit_comment.strip():
        print("No audit comment found, skipping.")
        return

    # Skip loop comments to avoid infinite recursion
    if "Loop iteration" in audit_comment or "Fix N:" in audit_comment:
        print("Loop comment detected, skipping to avoid recursion.")
        return

    base = os.path.dirname(os.path.abspath(__file__))
    sources = load_sources(base)

    MAX = 180_000
    original_len = len(sources)
    if original_len > MAX:
        cut = sources.rfind("\n", 0, MAX)
        sources = sources[:cut if cut > 0 else MAX]
        trunc_note = f"\n\n> ⚠️ Source truncated to {len(sources):,} / {original_len:,} chars."
    else:
        trunc_note = f"\n\n> ✅ Full source: {original_len:,} chars."

    user_prompt = f"""## Previous audit findings

{audit_comment}

---

## Full source code

{sources}

---

Produce exact Swift code fixes for every valid finding above.
Skip false positives (reference CLAUDE.md invariants).
Keep each fix minimal — change only what is needed.
"""

    client = anthropic.Anthropic(api_key=api_key)
    message = call_claude_with_retry(client,
        model="claude-opus-4-7",
        max_tokens=14000,
        thinking={"type": "adaptive"},
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": user_prompt}],
    )

    body = "\n\n".join(b.text for b in message.content if b.type == "text")
    comment = (
        f"## 🔁 Loop iteration — Code Fixes from Audit\n\n"
        f"{body}{trunc_note}\n\n---\n"
        f"*Loop Audit by claude-opus-4-7 "
        f"({message.usage.input_tokens:,} in / {message.usage.output_tokens:,} out)*"
    )

    post_comment(repo, pr_number, comment, github_token)
    print("Loop audit fix comment posted.")


if __name__ == "__main__":
    main()
