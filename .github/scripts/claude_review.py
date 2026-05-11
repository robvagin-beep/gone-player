import os
import anthropic
import urllib.request
import urllib.error
import json

SYSTEM_HEADER = """You are a senior Swift/macOS engineer reviewing a pull request for GONE Player.

The full project context, architecture rules, and list of already-resolved items are in CLAUDE.md below.
Read the "PR Review — Already Resolved" section carefully — do NOT flag anything listed there.

"""

OUTPUT_FORMAT = """
## Output format:
Write in English. Group findings by severity:
- 🔴 **Critical** — crashes, data loss, broken architecture invariants
- 🟡 **Warning** — performance issues, potential bugs, rule violations
- 🟢 **Suggestion** — minor improvements, style, cleanup

Only flag issues NOT listed in the "Already Resolved" section of CLAUDE.md above.
End with a brief summary (2-3 sentences). Be direct, no filler."""


def load_claude_md() -> str:
    try:
        with open("CLAUDE.md", "r", encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return "(CLAUDE.md not found)"


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
        raise RuntimeError(f"Network error posting comment: {e.reason}") from e


def main() -> None:
    api_key = os.environ["ANTHROPIC_API_KEY"]
    github_token = os.environ["GITHUB_TOKEN"]
    pr_number = os.environ["PR_NUMBER"]
    repo = os.environ["REPO"]
    pr_title = os.environ.get("PR_TITLE", "")

    claude_md = load_claude_md()
    system_prompt = SYSTEM_HEADER + claude_md + OUTPUT_FORMAT

    with open("pr_diff.txt", "r", encoding="utf-8", errors="replace") as f:
        diff = f.read()

    MAX_DIFF = 120_000
    truncated = ""
    original_len = len(diff)
    if original_len > MAX_DIFF:
        cut = diff.rfind("\n", 0, MAX_DIFF)
        diff = diff[:cut if cut > 0 else MAX_DIFF]
        truncated = f"\n\n> ⚠️ Diff truncated to {len(diff):,} of {original_len:,} characters."

    if not diff.strip():
        print("Empty diff, skipping review.")
        return

    client = anthropic.Anthropic(api_key=api_key)

    message = call_claude_with_retry(client,
        model="claude-sonnet-4-6",
        max_tokens=4096,
        system=system_prompt,
        messages=[
            {
                "role": "user",
                "content": f"PR: {pr_title}\n\n```diff\n{diff}\n```",
            }
        ],
    )

    review_body = message.content[0].text
    comment = f"## Claude Code Review\n\n{review_body}{truncated}\n\n---\n*Reviewed by claude-sonnet-4-6*"

    post_comment(repo, pr_number, comment, github_token)
    print("Review posted successfully.")


if __name__ == "__main__":
    main()
