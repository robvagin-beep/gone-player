#!/usr/bin/env python3
"""
Split Mode & Crossfader deep audit — two-player DI, crossfader geometry,
clone window lifecycle, equal-power law, output device sync.
"""
import os, anthropic, urllib.request, urllib.error, json

SPLIT_FILES = [
    "GONE/SplitModeManager.swift",
    "GONE/CrossfaderBandPanel.swift",
    "GONE/ClonePlayerShell.swift",
    "GONE/GONEApp.swift",
    "GONE/FullPlayerView.swift",
]

SYSTEM_PROMPT = """You are a senior macOS SwiftUI/AppKit engineer auditing GONE Player's Split Mode system.

Split Mode opens a second independent player window. Architecture rules you MUST know:

- Two engine instances: AudioEngineNext.shared (primary) + AudioEngineNext.secondary (clone)
- SplitModeManager.shared is @MainActor ObservableObject
- On activate(): creates PlayerState(engine: .secondary), copies tracks, opens second window
- On deactivate(): Task.detached { AudioEngineNext.secondary.stop() } — off main thread (intentional, prevents hang)
- Output device sync on activate: secondary must match primary's output device ID
- Crossfader gain: equal-power law cos(t*π/2) for primary, cos((1-t)*π/2) for secondary
- CrossfaderBandPanel: NSPanel, hit-test only within 60px radius of A-B line segment
- geometryVersion: Int on SplitModeManager — increment to trigger Canvas redraw (do NOT replace hc?.rootView)
- Clone window uses FullPlayerView(), NOT RootView() — avoids triggering updateWindowSize on primary
- TransportView hides settings gear in clone: state.audioEngine !== AudioEngineNext.secondary

Items marked DO NOT FLAG (already resolved):
- CrossfaderGapWindow observer reference cycle — resolved by design
- ClonePlayerShell.resizeWindow coalesced animation — intentional, acceptable
- EmptyOverlayView gating — already gated with audioEngine !== secondary check
- BandHitTestView.hitTest pass-through — nil from content view = routes to window below, correct
- CrossfaderBridgeView edge threshold > 10 — 4 occurrences, intentionally co-located

Audit these specific areas:

1. **Dependency injection correctness**
   - Does every audio call in clone window go through state.audioEngine (secondary), not shared?
   - Are there any direct AudioEngineNext.shared calls inside FullPlayerView or its children?
   - Does hot cue setup correctly identify primary vs secondary player by engine identity?

2. **Crossfader equal-power law**
   - Is cos(t*π/2) applied correctly for both channels?
   - Edge cases: t=0 (full primary), t=1 (full secondary), t=0.5 (equal mix)?
   - Is gain applied at the right node (mainMixerNode volume)?

3. **Clone window lifecycle**
   - WindowRefCapture race condition at first appearance — is it resolved?
   - Does deactivate() correctly stop secondary engine off-main without hanging?
   - Does close() on clone window trigger proper cleanup?

4. **CrossfaderBandPanel geometry**
   - Does the Canvas correctly read frameA/B from the panel?
   - Is geometryVersion incremented on resize events?
   - Hit test radius 60px — is it applied correctly?

5. **Output device sync**
   - Does secondary engine get primary's output device ID on activate?
   - What happens if user changes output device while Split Mode is active?

Output:
- 🔴 **Critical** — wrong audio routing, crash, or data corruption
- 🟡 **Warning** — race condition, wrong DI, or UX break
- 🟢 **Note** — defensive improvement

If an area is clean: "✅ [Area]: No issues found."
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
    for rel in SPLIT_FILES:
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

    client = anthropic.Anthropic(api_key=api_key)
    message = call_claude_with_retry(client,
        model="claude-sonnet-4-6",
        max_tokens=4096,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": f"Split Mode & Crossfader audit.\n\n{sources}"}],
    )
    body = message.content[0].text
    comment = f"## ✂️ Split Mode & Crossfader Deep Audit\n\n{body}{trunc}\n\n---\n*Split Mode Audit by claude-sonnet-4-6 (full source)*"
    post_comment(repo, pr_number, comment, github_token)
    print("Split mode audit posted.")

if __name__ == "__main__":
    main()
