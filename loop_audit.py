#!/usr/bin/env python3
"""
GONE Audit Loop — three passes, then implements fixes directly.

Pass 1 — Extract findings from audit comment.
Pass 2 — Adversarial: challenge each finding against CLAUDE.md invariants.
          Reject false positives. Keep only real, scoped, safe fixes.
Pass 3 — For each valid finding: write exact Swift patch (JSON format).
          Apply patches to files, commit to new branch, open PR.

Robert only needs to approve or close the resulting PR.
"""
import os, json, time, subprocess, re, anthropic, urllib.request, urllib.error

REPO          = os.environ.get("REPO", "robvagin-beep/gone-player")
PR_NUMBER     = os.environ.get("PR_NUMBER", "1")
AUDIT_COMMENT = os.environ.get("AUDIT_COMMENT", "")
COMMENT_ID    = os.environ.get("COMMENT_ID", "0")
GITHUB_TOKEN  = os.environ["GITHUB_TOKEN"]
API_KEY       = os.environ["ANTHROPIC_API_KEY"]

BASE = os.path.dirname(os.path.abspath(__file__))

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
    "GONE/UIHelpers.swift",
    "GONE/XYPadState.swift",
    "GONE/TooltipView.swift",
]

INVARIANTS = """
## GONE Player — Architecture invariants (NEVER violate)

Audio graph order (fixed, never reorder):
  playerNode → speedNode → pitchNode → hpfNode → lpfNode → eqNode
  → distortionNode → delayNode → reverbNode → gateNode → mainMixerNode

Hard rules:
- Views and extensions: ALWAYS state.audioEngine, NEVER AudioEngineNext.shared directly
- Timers: RunLoop.main.add(timer, forMode: .common) — never Timer.scheduledTimer alone
- Timer callbacks: MainActor.assumeIsolated inside
- updateWindowSize: only from RootView.onChange, never duplicated
- progressFeed reset in extensions: self.progressFeed.reset(), never PlaybackProgressFeed.shared.reset()
- windowResizability(.automatic) — never change
- isMovableByWindowBackground = false — never change
- WindowSnapManager state machine sequence — never reorder without reading full file
- playbackToken / bumpToken() pattern — VERIFIED CORRECT, never flag
- SourceKit "Cannot find type" — always false positive, not a bug
- Zero external dependencies — native Apple frameworks only

## Already-resolved items (DO NOT FLAG AGAIN)
See full list in CLAUDE.md section "PR Review — Already Resolved".
Key examples:
- progressTimer capture pattern — intentional deadlock prevention
- AudioEngineNext.deinit — static singletons never deinit, all deinit code is dead/defensive
- Task.sleep(nanoseconds:) — acknowledged tech debt, out of scope
- EQCurveView.animateTo task churn — acknowledged, out of scope
- ClonePlayerShell resize animation — correct by design
"""


def call_claude(client, system, user, max_tokens=14000):
    for attempt in range(4):
        try:
            msg = client.messages.create(
                model="claude-opus-4-7",
                max_tokens=max_tokens,
                thinking={"type": "adaptive"},
                system=system,
                messages=[{"role": "user", "content": user}],
            )
            return "\n\n".join(b.text for b in msg.content if b.type == "text")
        except Exception as e:
            if attempt < 3 and any(code in str(e) for code in ["529", "503", "429", "rate_limit"]):
                wait = [60, 90, 120][attempt]
                print(f"  API throttle ({e}) — waiting {wait}s...")
                time.sleep(wait)
            else:
                raise


def load_sources():
    parts = []
    for rel in ALL_FILES:
        path = os.path.join(BASE, rel)
        try:
            with open(path, encoding="utf-8") as f:
                content = f.read()
            parts.append(f"// ═══ {rel} ═══\n{content}")
        except FileNotFoundError:
            pass
    combined = "\n\n".join(parts)
    MAX = 180_000
    if len(combined) > MAX:
        cut = combined.rfind("\n", 0, MAX)
        combined = combined[:cut if cut > 0 else MAX]
    return combined


def post_comment(body):
    url = f"https://api.github.com/repos/{REPO}/issues/{PR_NUMBER}/comments"
    data = json.dumps({"body": body}).encode()
    req = urllib.request.Request(url, data=data, headers={
        "Authorization": f"Bearer {GITHUB_TOKEN}",
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/json",
    }, method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def fetch_applied_history():
    """Return set of normalized fix titles previously applied in this PR."""
    url = f"https://api.github.com/repos/{REPO}/issues/{PR_NUMBER}/comments?per_page=100"
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {GITHUB_TOKEN}",
        "Accept": "application/vnd.github+json",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            comments = json.loads(resp.read())
    except Exception:
        return set()
    applied = set()
    for comment in comments:
        body = comment.get("body", "")
        if "🔁 Loop PR opened" not in body:
            continue
        for line in body.split("\n"):
            # Match table rows: | F1 | title | `file` | risk |
            m = re.match(r'\|\s*[A-Z]\d+\s*\|\s*(.+?)\s*\|', line)
            if m:
                applied.add(m.group(1).strip().lower())
    return applied


def create_pr(branch, title, body):
    url = f"https://api.github.com/repos/{REPO}/pulls"
    data = json.dumps({
        "title": title,
        "body": body,
        "head": branch,
        "base": "dev",
    }).encode()
    req = urllib.request.Request(url, data=data, headers={
        "Authorization": f"Bearer {GITHUB_TOKEN}",
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/json",
    }, method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def apply_patch(file_rel, old_code, new_code):
    """Replace old_code with new_code in file. Returns True if applied."""
    path = os.path.join(BASE, file_rel)
    try:
        with open(path, encoding="utf-8") as f:
            content = f.read()
        if old_code.strip() not in content:
            return False, "old_code not found in file"
        updated = content.replace(old_code.strip(), new_code.strip(), 1)
        with open(path, "w", encoding="utf-8") as f:
            f.write(updated)
        return True, "ok"
    except FileNotFoundError:
        return False, f"file not found: {path}"


def git(cmd):
    result = subprocess.run(
        f"git {cmd}", shell=True, cwd=BASE,
        capture_output=True, text=True
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def main():
    if not AUDIT_COMMENT.strip():
        print("No audit comment, skipping.")
        return

    # Safety: skip if this is already a loop output
    skip_markers = ["🔁 Loop", "Loop PR opened", "Fix N:", "## Summary\n- Total valid"]
    if any(m in AUDIT_COMMENT for m in skip_markers):
        print("Loop or fix comment detected — skipping to prevent recursion.")
        return

    client = anthropic.Anthropic(api_key=API_KEY)
    sources = load_sources()

    # ── PASS 1+2: Extract findings, challenge each one ────────────────────────
    print("[PASS 1+2] Extracting and challenging findings...")
    validation_result = call_claude(
        client,
        system=INVARIANTS + """
You are a senior Swift/macOS engineer reviewing audit findings.

Your job:
1. Read the audit comment and extract every finding.
2. For each finding, apply adversarial scrutiny:
   - Is it a false positive per the invariants above?
   - Is it already in the "Already-resolved" list?
   - Is the proposed fix safe and minimal?
   - Does it touch protected systems without justification?
3. Output a JSON array only — no prose before or after.

JSON format:
[
  {
    "id": "F1",
    "title": "short title",
    "file": "GONE/Filename.swift",
    "valid": true,
    "reason": "one sentence why it is real / why it is a false positive",
    "risk": "critical|warning|note",
    "old_code": "exact existing Swift code to replace (verbatim from source, 3-20 lines)",
    "new_code": "exact replacement Swift code"
  }
]

Rules:
- valid=false for anything in invariants or already-resolved list
- old_code must be verbatim — it will be used for string replacement
- new_code must be a drop-in replacement — same indentation, same context
- If a finding is valid but requires a broad refactor (touching 5+ files or restructuring), set valid=false and note "requires broader refactor — out of scope for auto-fix"
- Maximum 8 valid fixes per loop run
""",
        user=f"## Audit comment\n\n{AUDIT_COMMENT}\n\n## Source code\n\n{sources}",
        max_tokens=16000,
    )

    # Extract JSON from response
    json_match = re.search(r'\[\s*\{.*\}\s*\]', validation_result, re.DOTALL)
    if not json_match:
        post_comment(
            f"## 🔁 Loop — Validation pass\n\n"
            f"Could not extract structured findings. Raw analysis:\n\n"
            f"{validation_result}\n\n---\n*Loop by claude-opus-4-7*"
        )
        return

    try:
        findings = json.loads(json_match.group(0))
    except json.JSONDecodeError as e:
        post_comment(f"## 🔁 Loop — JSON parse error\n\n```\n{e}\n```\n\nRaw:\n\n{validation_result[:2000]}")
        return

    valid_findings = [f for f in findings if f.get("valid")]
    invalid_findings = [f for f in findings if not f.get("valid")]

    print(f"  Valid: {len(valid_findings)} | Skipped: {len(invalid_findings)}")

    # ── Deduplication: filter out already-applied fixes ───────────────────────
    applied_history = fetch_applied_history()
    duplicate_findings = []
    if applied_history:
        fresh = []
        for f in valid_findings:
            if f.get("title", "").lower().strip() in applied_history:
                duplicate_findings.append(f)
            else:
                fresh.append(f)
        valid_findings = fresh
        if duplicate_findings:
            print(f"  Duplicates (already applied): {len(duplicate_findings)}")

    if not valid_findings:
        lines = [f"## 🔁 Loop — No new fixes\n"]
        if invalid_findings:
            lines.append(f"**Rejected as false positives ({len(invalid_findings)}):**\n")
            for f in invalid_findings:
                lines.append(f"- **{f['id']}** {f['title']}: {f['reason']}")
        if duplicate_findings:
            lines.append(f"\n**Already applied in this PR ({len(duplicate_findings)}) — skipped:**\n")
            for f in duplicate_findings:
                lines.append(f"- **{f['id']}** {f['title']}: previously implemented, no action needed")
        post_comment("\n".join(lines) + "\n\n---\n*Loop by claude-opus-4-7*")
        return

    # ── PASS 3: Apply patches ─────────────────────────────────────────────────
    branch = f"loop/fix-comment-{COMMENT_ID}"
    print(f"[PASS 3] Creating branch {branch}...")
    git(f"checkout -b {branch}")

    applied = []
    failed = []

    for finding in valid_findings:
        fid      = finding.get("id", "?")
        title    = finding.get("title", "fix")
        file_rel = finding.get("file", "")
        old_code = finding.get("old_code", "")
        new_code = finding.get("new_code", "")

        if not file_rel or not old_code or not new_code:
            failed.append((fid, title, "missing file/old_code/new_code"))
            continue

        ok, msg = apply_patch(file_rel, old_code, new_code)
        if ok:
            git(f'add "{file_rel}"')
            applied.append((fid, title, file_rel))
            print(f"  ✅ {fid} {title}")
        else:
            failed.append((fid, title, msg))
            print(f"  ❌ {fid} {title} — {msg}")

    if not applied:
        git("checkout dev")
        git(f"branch -D {branch}")
        lines = ["## 🔁 Loop — Patches could not be applied\n"]
        for fid, title, reason in failed:
            lines.append(f"- **{fid}** {title}: `{reason}`")
        post_comment("\n".join(lines) + "\n\n---\n*Loop by claude-opus-4-7*")
        return

    # Commit
    fix_list = ", ".join(f[0] for f in applied)
    commit_msg = f"loop: auto-fix {fix_list} from audit comment #{COMMENT_ID}"
    git(f'commit -m "{commit_msg}"')
    git(f"push origin {branch}")

    # Open PR
    pr_body_lines = [
        f"## 🔁 Auto-fix from audit loop\n",
        f"Source audit: PR #{PR_NUMBER} comment #{COMMENT_ID}\n",
        f"### Applied fixes ({len(applied)})\n",
    ]
    for fid, title, file_rel in applied:
        f_data = next((x for x in valid_findings if x["id"] == fid), {})
        pr_body_lines.append(f"**{fid} — {title}**")
        pr_body_lines.append(f"- File: `{file_rel}`")
        pr_body_lines.append(f"- Risk: {f_data.get('risk','?')}")
        pr_body_lines.append(f"- {f_data.get('reason','')}\n")

    if failed:
        pr_body_lines.append(f"\n### Not applied ({len(failed)})\n")
        for fid, title, reason in failed:
            pr_body_lines.append(f"- **{fid}** {title}: `{reason}`")

    if duplicate_findings:
        pr_body_lines.append(f"\n### Already applied — skipped ({len(duplicate_findings)})\n")
        for f in duplicate_findings:
            pr_body_lines.append(f"- **{f['id']}** {f['title']}: previously implemented in this PR, no action needed")

    if invalid_findings:
        pr_body_lines.append(f"\n### Rejected as false positives ({len(invalid_findings)})\n")
        for f in invalid_findings:
            pr_body_lines.append(f"- **{f['id']}** {f['title']}: {f['reason']}")

    pr_body_lines.append("\n---\n⚠️ **Review before merging.** Each fix is minimal and scoped. Approve or close.")
    pr_body_lines.append("*Generated by claude-opus-4-7 loop audit*")

    pr = create_pr(
        branch=branch,
        title=f"[Loop] Auto-fix {len(applied)} findings from audit",
        body="\n".join(pr_body_lines),
    )

    pr_url = pr.get("html_url", "")
    post_comment(
        f"## 🔁 Loop PR opened\n\n"
        f"Applied **{len(applied)}** fix(es) → [{branch}]({pr_url})\n\n"
        f"| ID | Fix | File | Risk |\n|---|---|---|---|\n" +
        "\n".join(
            f"| {fid} | {title} | `{file_rel}` | {next((x.get('risk','?') for x in valid_findings if x['id']==fid), '?')} |"
            for fid, title, file_rel in applied
        ) +
        f"\n\n**Review and merge (or close) the PR above.**\n\n---\n*Loop by claude-opus-4-7*"
    )
    print(f"PR opened: {pr_url}")


if __name__ == "__main__":
    main()
