#!/usr/bin/env python3
"""
Deep security and vulnerability audit — reads all source files,
asks Claude Opus to find real vulnerabilities: path traversal, unsafe I/O,
sandbox issues, input validation gaps, memory concerns, privacy risks.
"""
import os, anthropic, urllib.request, urllib.error, json

ALL_SOURCE_FILES = [
    "GONE/GONEApp.swift",
    "GONE/PlayerState.swift",
    "GONE/PlayerState+Playback.swift",
    "GONE/PlayerState+Analysis.swift",
    "GONE/PlayerState+Playlists.swift",
    "GONE/PlayerState+EQ.swift",
    "GONE/ArtworkCache.swift",
    "GONE/LibraryScanner.swift",
    "GONE/Track.swift",
    "GONE/SplitModeManager.swift",
    "GONE/CrossfaderBandPanel.swift",
    "GONE/WindowSnapManager.swift",
    "GONE/SettingsPanel.swift",
    "GONE/RootView.swift",
    "GONE/FullPlayerView.swift",
    "GONE/TrackHeaderView.swift",
    "GONE/WaveformView.swift",
    "GONE/PlaylistView.swift",
    "GONE/TransportView.swift",
    "GONE/EQPanelView.swift",
    "GONE/PeekPanelView.swift",
    "GONE/PitchFaderView.swift",
    "GONE/SpectrumView.swift",
    "GONE/ClonePlayerShell.swift",
]

SYSTEM_PROMPT = """You are a senior macOS security engineer performing a deep vulnerability audit of GONE Player.

This is a macOS SwiftUI/AppKit app that reads audio files from disk, caches artwork, and manages windows.
It uses no external dependencies — 100% Apple native frameworks only.
It runs in the macOS App Sandbox.

Audit for real security and privacy vulnerabilities only. Do NOT report style, performance, or architecture issues.

Check these specific areas:

1. **Path traversal / file system safety**
   - Do any file paths get constructed from user-supplied data without validation?
   - Can a specially crafted filename escape the intended directory?
   - `ArtworkCache` disk writes — is the path fully controlled?
   - `LibraryScanner` — does it follow symlinks? Can it be directed outside the music folder?

2. **Sandbox compliance and entitlements**
   - Any API calls that would require entitlements beyond a standard music player?
   - `CoreAudio AudioObjectGetPropertyData` — does this require additional entitlements?
   - `NSOpenPanel` scope — are security-scoped bookmarks used for persistent folder access?
   - Window level `screenSaverWindow - 1` — does this affect sandbox behavior?

3. **Input validation and injection**
   - Track metadata (title, artist, BPM) read from audio file tags — is any used unsanitized in file paths, shell commands, or UI contexts that could cause issues?
   - BPM values fed to timer intervals — are there bounds checks preventing zero or negative values causing divide-by-zero or runaway timers?
   - File extension checks — is file type validated beyond the extension string?

4. **Unsafe memory / concurrency**
   - `@unchecked Sendable` declarations — are the types they annotate actually safe?
   - Any `UnsafePointer`, `withUnsafeMutablePointer`, or raw buffer operations?
   - Race conditions that could lead to use-after-free or invalid state beyond the documented tech debt?

5. **Data privacy**
   - Is any user data (file paths, track names) sent anywhere external?
   - `ArtworkCache` — does it write artwork data outside the expected cache directory?
   - Are file system URLs logged in a way that could expose personal directory structure?

6. **Cryptographic / key material**
   - Any hardcoded credentials, tokens, or API keys in source?

Output format:
- 🔴 **Critical** — exploitable vulnerability, data loss, or sandbox escape risk
- 🟡 **Warning** — potential vulnerability requiring specific conditions
- 🟢 **Note** — good practice violation that could become a vulnerability

If an area is clean, write "✅ [Area]: No issues found."
Be precise. Reference exact file + line context. Real issues only — no theoretical concerns without concrete code evidence."""

def load_sources(base):
    parts = []
    for rel in ALL_SOURCE_FILES:
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
    MAX = 200_000
    if original_len > MAX:
        cut = sources.rfind("\n", 0, MAX)
        sources = sources[:cut if cut > 0 else MAX]
        trunc = f"\n\n> ⚠️ Source truncated to {len(sources):,} of {original_len:,} chars."
    else:
        trunc = f"\n\n> ✅ Full source included: {original_len:,} chars."

    client = anthropic.Anthropic(api_key=api_key)
    message = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=4096,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": f"Deep security audit of GONE Player.\n\n{sources}"}],
    )
    body = message.content[0].text
    comment = f"## 🔐 Claude Security & Vulnerability Audit\n\n{body}{trunc}\n\n---\n*Security Audit by claude-sonnet-4-6 (full source)*"
    post_comment(repo, pr_number, comment, github_token)
    print("Security audit posted.")

if __name__ == "__main__":
    main()
