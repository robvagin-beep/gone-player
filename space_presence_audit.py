#!/usr/bin/env python3
"""
Space & Omnipresence Audit — GONE Player
Verifies that the window presence architecture is correct:
- Docked tab: always visible on every Space and above fullscreen app Spaces
- Expanded: above all app windows, on all Spaces
- Space swipe: no body artifact during transition
- Level hierarchy: docked > expanded > clone > crossfader
"""

import os, sys, re, urllib.request, json

ANTHROPIC_API_KEY = os.environ["ANTHROPIC_API_KEY"]
GITHUB_TOKEN      = os.environ["GITHUB_TOKEN"]
PR_NUMBER         = os.environ["PR_NUMBER"]
REPO              = os.environ["REPO"]

FILES_TO_READ = [
    "GONE/WindowSnapManager.swift",
    "GONE/GONEApp.swift",
    "GONE/SplitModeManager.swift",
    "GONE/CrossfaderBandPanel.swift",
]

def read_file(path):
    try:
        with open(path, encoding="utf-8") as f:
            content = f.read()
        lines = content.splitlines()
        numbered = "\n".join(f"{i+1:4}: {l}" for i, l in enumerate(lines))
        # Truncate per file to avoid token overflow
        if len(numbered) > 12000:
            numbered = numbered[:12000] + f"\n... (truncated, {len(lines)} lines total)"
        return numbered
    except FileNotFoundError:
        return f"[FILE NOT FOUND: {path}]"

def call_claude(prompt):
    import time
    for attempt in range(4):
        req = urllib.request.Request(
            "https://api.anthropic.com/v1/messages",
            data=json.dumps({
                "model": "claude-opus-4-7",
                "max_tokens": 16000,
                "messages": [{"role": "user", "content": prompt}]
            }).encode(),
            headers={
                "x-api-key": ANTHROPIC_API_KEY,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json"
            },
            method="POST"
        )
        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                data = json.loads(resp.read())
            return "".join(b["text"] for b in data["content"] if b["type"] == "text")
        except Exception as e:
            if attempt < 3 and any(code in str(e) for code in ["529", "503", "429", "overloaded"]):
                wait = [60, 90, 120][attempt]
                print(f"  API throttle ({e}) — waiting {wait}s (attempt {attempt+1}/4)...")
                time.sleep(wait)
            else:
                raise

def post_comment(body):
    url = f"https://api.github.com/repos/{REPO}/issues/{PR_NUMBER}/comments"
    req = urllib.request.Request(
        url,
        data=json.dumps({"body": body}).encode(),
        headers={
            "Authorization": f"Bearer {GITHUB_TOKEN}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json"
        },
        method="POST"
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.status

file_contents = {path: read_file(path) for path in FILES_TO_READ}

PROMPT = f"""You are auditing a macOS DJ app called GONE Player for correct omnipresent window behavior.
The app must satisfy these requirements:

1. **Docked state** (window tab at screen right edge, body off-screen):
   - Always on every virtual desktop/Space — never travels with one Space during swipe
   - Visible above fullscreen app Spaces
   - Window body NEVER visible during Space swipe transition
   - Level: screenSaverWindow (1000) — must be above the Space-transition compositor layer
   - Collection behavior: canJoinAllSpaces + fullScreenAuxiliary + transient (NOT stationary — unreliable for off-screen windows)

2. **Expanded/waiting state**:
   - Above all application windows including fullscreen app windows
   - On all Spaces
   - Level: overlayWindow (102) — DRM-safe, above all apps
   - Collection behavior: canJoinAllSpaces + fullScreenAuxiliary + managed

3. **Space swipe artifact defense**:
   - NSWorkspace.activeSpaceDidChangeNotification observer installed in enable(), removed in disable()/clearInfrastructure()
   - On notification: briefly set alphaValue=0, call constrainSnapPosition(), restore after ~80ms

4. **Level hierarchy for Split Mode** (both players visible simultaneously):
   - Main player (expanded): overlayWindow = 102
   - Clone player: overlayWindow+1 = 103
   - Crossfader panel: overlayWindow-1 = 101
   - This ensures players render above crossfader endpoints

5. **State transitions**:
   - dockToEdge/dockFromProximity completion → level = screenSaverWindow (1000)
   - expand() start → level = overlayWindow (102)
   - disable() → level = overlayWindow (102)

KNOWN ROOT CAUSE: The docked window is positioned at x = screen.maxX - tabVisible (19px),
meaning the window body extends beyond the screen boundary. The Space-transition compositor
can reveal this off-screen content during swipes. The fixes are:
- Level 1000 (screenSaverWindow) to be above the transition compositor layer
- activeSpaceDidChangeNotification to force-reposition after each transition

IMPORTANT — DO NOT FLAG:
- SourceKit false positives (Cannot find type X in scope)
- .stationary removal (intentional — unreliable for off-screen windows)
- WindowSnapManager state machine sequence (verified correct)
- windowResizability(.automatic) (must not change)
- isMovableByWindowBackground = false (must not change)

Here are the source files:

=== WindowSnapManager.swift ===
{file_contents["GONE/WindowSnapManager.swift"]}

=== GONEApp.swift ===
{file_contents["GONE/GONEApp.swift"]}

=== SplitModeManager.swift ===
{file_contents["GONE/SplitModeManager.swift"]}

=== CrossfaderBandPanel.swift ===
{file_contents["GONE/CrossfaderBandPanel.swift"]}

Perform a thorough audit. For each finding, classify as:
- **CRITICAL**: causes the window to travel with a Space or be invisible when it should be visible
- **HIGH**: causes incorrect level or missing Space enrollment
- **MEDIUM**: robustness gap that could cause intermittent issues
- **INFO**: architectural note, not a bug

Format the output as a GitHub PR comment in Markdown:
## Space & Omnipresence Audit

For each issue:
**[SEVERITY] Short title**
File: `filename.swift` line N
Problem: ...
Fix: ...

End with a summary section:
## Summary
- Total issues: N (X critical, Y high, Z medium)
- Docked level scheme: correct/incorrect
- Expanded level scheme: correct/incorrect
- Space swipe defense: implemented/missing
- Split Mode level hierarchy: correct/incorrect
"""

print("Running Space & Omnipresence Audit...")
result = call_claude(PROMPT)

comment = f"## Claude Code Review — Space & Omnipresence Audit\n\n{result}"
status = post_comment(comment)
print(f"Comment posted: HTTP {status}")
print(result)
