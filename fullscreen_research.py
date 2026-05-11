#!/usr/bin/env python3
"""
Research task: how to make GONE Player visible above macOS fullscreen Spaces.
Sends a deep research prompt to Claude Opus (extended thinking),
posts the result as a PR comment.
"""
import os
import anthropic
import urllib.request
import urllib.error
import json

SYSTEM_PROMPT = """You are a senior macOS/AppKit engineer with deep expertise in
window management, CGWindowServer, SkyLight framework, and the macOS Space/Mission Control
architecture. You have shipped App Store utilities that float above fullscreen apps
(think PopClip, Raycast, Lungo, Bartender, 1Password mini).

Answer with maximum technical depth. Include actual CGWindowLevel integer values,
exact NSWindowCollectionBehavior flag combinations, and working Swift code snippets.
No filler. No hedging. If something requires a private API, say so and explain the
App Store risk explicitly."""

RESEARCH_PROMPT = """## Task

GONE Player is a macOS 13+ SwiftUI/AppKit DJ utility. It must float above everything —
including fullscreen apps that occupy their own virtual Spaces.

## Current setup (GONEApp.swift)

```swift
window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))  // = 1000
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
```

Result: the window appears above all normal windows and travels across regular Spaces.
**Problem:** when any app (browser, Figma, Rekordbox) goes fullscreen it creates its own
Space. GONE is NOT visible in that Space — it disappears.

## Architecture constraints (must not break)

- `isMovableByWindowBackground = false` (drag controls live in the view, not the titlebar)
- `windowResizability(.automatic)` in SwiftUI WindowGroup
- Snap-to-edge system (WindowSnapManager) animates frames off-screen and back — must keep working
- 100% Apple native frameworks, no external dependencies
- Sandboxed macOS app, targeting App Store (macOS 13+)
- `hidesOnDeactivate = false` already set
- Window style: `.borderless + .nonactivatingPanel` used for child panels (crossfader, settings)

## Research questions — answer all of them

**1. Root cause**
Why does `screenSaverWindow` (1000) + `.canJoinAllSpaces + .fullScreenAuxiliary` fail to
appear in fullscreen Spaces? What layer does macOS fullscreen actually use? Is `.stationary`
interfering (it prevents cross-Space travel animations — does it also block the window from
following to fullscreen Spaces)?

**2. CGWindowLevel values**
What are the integer values for: `kCGMaximumWindowLevelKey`, `kCGOverlayWindowLevelKey`,
`kCGCursorWindowLevelKey`, `kCGStatusWindowLevelKey`?
What level does the macOS menu bar sit at in a fullscreen Space?
Is there a public level that is above the fullscreen-app layer?

**3. NSWindowCollectionBehavior combinations**
What exact flag combination allows a window to appear in fullscreen Spaces?
Does `.moveToActiveSpace` instead of (or in addition to) `.canJoinAllSpaces` help?
Does removing `.stationary` help?
What does `.fullScreenAuxiliary` actually guarantee vs. what people expect?
Is `.participatesInCycle` or `.ignoresCycle` relevant?

**4. activationPolicy**
Does `.accessory` or `.prohibited` vs `.regular` affect visibility in fullscreen Spaces?
GONE currently uses default (`.regular`). Should it switch?

**5. Panel vs Window**
For child panels (NSPanel with `.nonactivatingPanel`) does the behavior differ from NSWindow?
CrossfaderGapWindow and SettingsPanel are NSPanel — do they need different treatment?

**6. The .fullScreenPrimary companion trick**
Some developers report that adding a tiny (1×1) invisible companion window with
`.fullScreenPrimary` forces the real window into the fullscreen Space.
Does this actually work? What are the side effects?

**7. Private API options**
What does `CGSSetWindowTags` do and which tag bits are relevant?
What does `CGSAddWindowToSpace` / `CGSCopySpacesForWindows` do?
Is using SkyLight.framework directly viable for a sandboxed App Store app?
What is `_NSWindowStyle` undocumented value 1 << 14 (`NSWindowStyleMaskNonactivatingPanel` analogue)?

**8. Entitlements**
Is any entitlement required for legitimate high-level window placement?
Can a sandboxed app get a window above fullscreen without private API?

**9. Multi-display edge case**
With "Displays have separate Spaces" = OFF in Mission Control prefs, does behavior change?
Is there a runtime API to detect this setting (`NSScreen.screensHaveSeparateSpaces`)?

**10. Tested working solutions from shipping apps**
What specific technique do PopClip, Raycast, Lungo, Amphetamine, Bartender use?
Are any of them open source or have published their approach?

**11. Mission Control (Exposé) visibility**
When the user activates Mission Control (swipe up with 3 fingers, or F3), all app windows
appear in a bird's-eye overview. GONE currently disappears entirely in Mission Control.

- What `NSWindowCollectionBehavior` flags control whether a window appears in Mission Control?
- Does `.stationary` cause the window to be hidden in Mission Control?
- Is `.managed` the correct flag to make the window appear as a normal tiled window?
- Can a window participate in Mission Control while ALSO being visible in fullscreen Spaces?
- What is the expected behavior for a "docked" (snapped off-screen) window — should it
  appear as a tiny sliver at the edge, or be hidden entirely?

**12. Docked / snapped-to-edge state in Mission Control**
GONE has a snap system: the window slides off-screen to the left/right edge, leaving just
a peek strip (PeekPanelView) visible. In this docked state:
- The window frame is mostly off-screen — only ~18px visible
- The snap state is `.docked` in WindowSnapManager

When docked and Mission Control activates:
- Should GONE appear in Mission Control at all (as a small strip)?
- If not, how do we hide it gracefully? `.canJoinAllSpaces + .stationary` currently hides it
  completely even when NOT docked — is there a way to have it visible when normal but
  hidden when docked?
- Is there a way to animate the window back to its saved position before Mission Control
  activates, then re-dock after Mission Control exits?

## Deliverable format

### 1. Root cause (2-3 paragraphs)

### 2. Public API solution (code-first)
Complete Swift snippet — just the lines that replace the current window.level and
window.collectionBehavior setup. Must work on macOS 13+, sandbox-safe, App Store-safe.

### 3. If public API is insufficient — private API option
Code snippet + explicit App Store risk rating (Low / Medium / High / Certain rejection).

### 4. The .fullScreenPrimary trick — verdict
Does it work? Code snippet if yes, explanation if no.

### 5. Recommended approach for GONE
Specific recommendation given the constraints. What to change in GONEApp.swift.

### 6. Mission Control solution
What `NSWindowCollectionBehavior` flags make the window appear correctly in Mission Control
(not disappear) while still floating above fullscreen Spaces?
Specific code for GONEApp.swift. Include handling for the docked state.

### 7. Test checklist
Bullet list: exactly what to test to confirm the fix works across all cases
(regular Space, fullscreen Space, multiple displays, Mission Control, Exposé, docked state)
"""


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

    client = anthropic.Anthropic(api_key=api_key)
    message = call_claude_with_retry(client,
        model="claude-sonnet-4-6",
        max_tokens=8000,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": RESEARCH_PROMPT}],
    )

    body = message.content[0].text

    comment = (
        "## 🪟 Fullscreen Space Layering — Research Report\n\n"
        f"{body}\n\n---\n"
        f"*Research by claude-sonnet-4-6 "
        f"({message.usage.input_tokens:,} in / {message.usage.output_tokens:,} out)*"
    )

    post_comment(repo, pr_number, comment, github_token)
    print("Fullscreen research posted successfully.")


if __name__ == "__main__":
    main()
