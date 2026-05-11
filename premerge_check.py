#!/usr/bin/env python3
"""
Pre-merge regression check: reads CLAUDE.md fragile systems list + diff,
asks Claude Opus: does this diff risk breaking any documented fragile subsystem?
"""
import os, anthropic, urllib.request, urllib.error, json, subprocess

SYSTEM_PROMPT = """You are a senior Swift/macOS engineer doing a pre-merge regression check for GONE Player.

The CLAUDE.md below documents fragile subsystems and architecture invariants.
The diff below is what's about to be merged.

Your job: cross-reference every change in the diff against the documented fragile systems.
Answer only ONE question: **does any change in this diff risk breaking a documented fragile system?**

Fragile systems to check against:
- WindowSnapManager state machine (slide → prepareForSnap → docked → unlockFrame sequence)
- AudioEngineNext graph node order (fixed chain, no reordering)
- Per-player DI pattern (never call AudioEngineNext.shared from PlayerState/Views)
- PlaybackProgressFeed isolation (per-player instance, not singleton)
- SpectrumFeed singleton routing
- updateWindowSize called only from RootView.onChange
- RunLoop.main .common mode timers
- isMovableByWindowBackground = false
- windowResizability(.automatic)
- Hot cue keyCodes mapping

Output format:
- 🔴 **Regression risk** — specific diff line + specific rule it violates
- 🟢 **Clear** — no regression risk found for [system name]

If no regressions: say "All documented fragile systems: clear." and stop.
Be surgical. One finding per real risk."""

def load_claude_md():
    try:
        with open("CLAUDE.md", "r", encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return "(CLAUDE.md not found)"

def get_diff():
    try:
        result = subprocess.run(
            ["git", "diff", "origin/main...HEAD"],
            capture_output=True, text=True, timeout=30
        )
        return result.stdout
    except Exception as e:
        return f"(diff error: {e})"

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

    claude_md = load_claude_md()
    diff = get_diff()

    MAX_DIFF = 100_000
    original_len = len(diff)
    if original_len > MAX_DIFF:
        cut = diff.rfind("\n", 0, MAX_DIFF)
        diff = diff[:cut if cut > 0 else MAX_DIFF]
        trunc = f"\n\n> ⚠️ Diff truncated to {len(diff):,} of {original_len:,} chars."
    else:
        trunc = f"\n\n> ℹ️ Full diff: {original_len:,} chars."

    client = anthropic.Anthropic(api_key=api_key)
    message = call_claude_with_retry(client,
        model="claude-sonnet-4-6",
        max_tokens=2048,
        system=SYSTEM_PROMPT + "\n\n# CLAUDE.md\n" + claude_md,
        messages=[{"role": "user", "content": f"Pre-merge regression check.\n\n```diff\n{diff}\n```"}],
    )
    body = message.content[0].text
    comment = f"## 🛡️ Claude Pre-merge Regression Check\n\n{body}{trunc}\n\n---\n*Regression check by claude-sonnet-4-6*"
    post_comment(repo, pr_number, comment, github_token)
    print("Regression check posted.")

if __name__ == "__main__":
    main()
