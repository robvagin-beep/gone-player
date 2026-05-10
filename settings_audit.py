#!/usr/bin/env python3
"""
Settings panel UX audit — reads SettingsPanel.swift + design tokens + RootView
for drag zone, style consistency, and layout quality.
"""
import os, anthropic, urllib.request, urllib.error, json

SETTINGS_FILES = [
    "GONE/SettingsPanel.swift",
    "GONE/DesignTokens.swift",
    "GONE/RootView.swift",
    "GONE/TransportView.swift",
    "GONE/TrackHeaderView.swift",
]

SYSTEM_PROMPT = """You are a senior macOS UI/UX designer and Swift engineer auditing the Settings panel of GONE Player.

GONE Player is a dark, glass-aesthetic macOS app — a "Swiss Army knife" for DJs preparing a set.
Visual style: deep dark backgrounds, glass/frosted overlays, subtle white outlines, monospaced data labels,
accent colors only for active state. Everything feels precise and minimal.

Audit the SettingsPanel.swift against the rest of the app's design language.
Your job: find real UX problems and style inconsistencies that hurt usability or feel out of place.

Focus on these areas:

1. **Drag zone for repositioning the panel**
   - Is the draggable area obvious to a new user? Is there a visual affordance (handle dots, cursor change, label)?
   - Is the drag zone large enough — or is it a narrow strip that requires precision?
   - Does `minimumDistance: 8` feel right, or would 3-4 be better for a small floating panel?
   - What happens if the user tries to drag from the content area — does it fail silently?

2. **Visual style consistency with the main app**
   - Do `MiniToggle`, `SRow`, `GMapSlider` match the app's dark glass aesthetic?
   - Are colors, corner radii, and typography consistent with `DesignTokens.swift` (`G.*` tokens)?
   - Any `.background(.ultraThinMaterial)` or system controls that look out of place in a dark custom UI?
   - Font sizes, weights, and letter spacing — do they match `G.mono()` / `G.sans()` usage elsewhere?

3. **Layout and information architecture**
   - Are the three tabs (General, BPM, Display/About) the right grouping? Anything missing or misplaced?
   - `SRow` label + sub-label pattern — is the hierarchy clear enough at small sizes?
   - `GMapSlider` — is the custom drag slider more or less intuitive than a native `Slider`?
   - Is the About tab content (app description, version, links) sufficient and well-formatted?

4. **Interaction quality**
   - Toggle response — `MiniToggle` is a custom ZStack Button. Does it have proper hover/press states?
   - `MiniStepper` (+/-) — is the tap target large enough (minimum 44pt)?
   - Keyboard navigation — can the panel be operated without a mouse?
   - Is there a visible close affordance, or does the user have to click the gear icon again?

5. **Specific improvements to suggest**
   - Be concrete: "Replace X with Y because Z"
   - Prioritize changes that would visually align the panel with the main window's design language
   - Flag anything that looks like a placeholder or rushed implementation

Output format:
- 🔴 **Broken** — interaction that fails or is confusing in a way that blocks the user
- 🟡 **Needs work** — inconsistency or awkwardness that degrades the experience
- 🟢 **Polish** — small improvement that would raise the quality bar

Be specific and constructive. No generic design advice — only things grounded in the actual code."""

def load_sources(base):
    parts = []
    for rel in SETTINGS_FILES:
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
    message = client.messages.create(
        model="claude-opus-4-7",
        max_tokens=4096,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": f"Settings panel UX audit for GONE Player.\n\n{sources}"}],
    )
    body = message.content[0].text
    comment = f"## 🎛️ Claude Settings Panel UX Audit\n\n{body}{trunc}\n\n---\n*Settings UX Audit by claude-opus-4-7 (full source)*"
    post_comment(repo, pr_number, comment, github_token)
    print("Settings audit posted.")

if __name__ == "__main__":
    main()
