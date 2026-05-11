#!/usr/bin/env python3
"""
One-shot UI audit: reads live source files, sends to Claude with UI-focused prompt,
posts result as a GitHub PR comment.
"""
import os
import anthropic
import urllib.request
import urllib.error
import json

UI_FILES = [
    "GONE/RootView.swift",
    "GONE/FullPlayerView.swift",
    "GONE/ClonePlayerShell.swift",
    "GONE/CrossfaderBandPanel.swift",
    "GONE/TrackHeaderView.swift",
    "GONE/WaveformView.swift",
    "GONE/EQPanelView.swift",
    "GONE/PeekPanelView.swift",
    "GONE/PitchFaderView.swift",
    "GONE/TransportView.swift",
    "GONE/PlaylistView.swift",
    "GONE/SettingsPanel.swift",
    "GONE/DesignTokens.swift",
    "GONE/SpectrumView.swift",
    "GONE/TooltipView.swift",
]

SYSTEM_PROMPT = """You are a senior Swift/macOS UI engineer performing a focused UI audit of GONE Player.

This is NOT a general code review. Focus exclusively on the UI layer:

1. **Transparent zones & hit-testing**
   - Windows and views that must pass clicks through to underlying content
   - `NSView.hitTest` overrides — do they correctly return nil for transparent regions?
   - `.contentShape` and `.allowsHitTesting` usage — any zones that accidentally capture or block events?
   - `CrossfaderGapWindow` / `BandHitTestView` — does the pass-through behavior hold for all pointer positions?

2. **Interaction with transparent / semi-transparent areas**
   - Drag gestures on glass shells, overlay views — do they fire on intended areas only?
   - Scroll wheel capture — any transparent view that accidentally intercepts scroll events meant for underlying windows?
   - Hover detection on transparent backgrounds
   - `WindowBorderDragOverlay` — coverage of drag zones vs transparent gaps

3. **Canvas rendering & optimization**
   - `CrossfaderBridgeView` Canvas — redraws on `geometryVersion` bump: are they minimal?
   - `WaveformView` Canvas — frame-rate, unnecessary invalidations
   - `BPMAnalyzingBadge` TimelineView shimmer — is 30fps appropriate? Any over-rendering?
   - `SpectrumView` — observable subscription frequency vs render cost

4. **SwiftUI layout correctness**
   - Frame anchoring — views that must stay top-fixed vs bottom-fixed
   - ZStack layering — correct visual order, no accidental occlusion
   - `ignoresSafeArea` usage — correct or overly broad?
   - Geometry readers — are any used where not needed (triggering extra layout passes)?

5. **Animation & state churn**
   - `@State`/`@Published` mutations that trigger full-view rebuilds unnecessarily
   - `withAnimation` applied too broadly
   - Tasks spawned per-frame or per-interaction that should be debounced

Report format:
- 🔴 **Critical** — broken hit-test, click-through failure, layout crash
- 🟡 **Warning** — performance issue, incorrect event routing, visual glitch potential
- 🟢 **Suggestion** — improvement, consistency, cleanup

Be direct. No filler. Flag real issues only."""



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
    for rel in UI_FILES:
        path = os.path.join(base, rel)
        try:
            with open(path, "r", encoding="utf-8") as f:
                content = f.read()
            parts.append(f"// ═══ {rel} ({'%d lines' % content.count(chr(10))}) ═══\n{content}")
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

    total_chars = len(sources)
    MAX_SOURCES = 180_000
    if total_chars > MAX_SOURCES:
        cut = sources.rfind("\n", 0, MAX_SOURCES)
        sources = sources[:cut if cut > 0 else MAX_SOURCES]
        trunc_note = f"\n\n> ⚠️ Source truncated to {len(sources):,} of {total_chars:,} characters."
    else:
        trunc_note = f"\n\n> ℹ️ Full source included ({total_chars:,} characters across {len(UI_FILES)} UI files)."

    client = anthropic.Anthropic(api_key=api_key)
    message = call_claude_with_retry(client,
        model="claude-sonnet-4-6",
        max_tokens=4096,
        system=SYSTEM_PROMPT,
        messages=[
            {
                "role": "user",
                "content": f"Audit the UI layer of GONE Player. Full source below.\n\n{sources}",
            }
        ],
    )

    body = message.content[0].text
    comment = (
        "## 🎨 Claude UI Audit — Transparent Zones, Hit-Testing, Rendering, Layout\n\n"
        f"{body}{trunc_note}\n\n---\n*UI Audit by claude-sonnet-4-6 (live source, not diff)*"
    )

    post_comment(repo, pr_number, comment, github_token)
    print("UI audit posted successfully.")


if __name__ == "__main__":
    main()
