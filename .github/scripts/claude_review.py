import os
import anthropic
import urllib.request
import urllib.error
import json

SYSTEM_PROMPT = """You are a senior Swift/macOS engineer reviewing a pull request for GONE Player — a lightweight macOS pre-listen tool for hobbyist DJs (macOS 13+, 100% Apple native frameworks, no external dependencies).

## Critical architecture rules to enforce:

**Audio graph node order is FIXED** — never reorder:
playerNode → speedNode → pitchNode → hpfNode → lpfNode → eqNode → distortionNode → delayNode → reverbNode → gateNode → mainMixerNode

**Per-player DI pattern** — NEVER call `AudioEngineNext.shared` directly inside PlayerState extensions or View files. Always use `self.audioEngine` or `state.audioEngine`.

**Progress feed** — `progress` and `currentTime` are NOT `@Published` on PlayerState. They live on `PlaybackProgressFeed`. Always use `state.progressFeed.reset()`, NEVER `PlaybackProgressFeed.shared.reset()` from extension code.

**Spectrum feed** — `@Published var spectrumData` was removed from PlayerState. Lives in `SpectrumFeed.shared`.

**WindowSnapManager state machine** — sequence must be: isSnapping=true → slideOffScreen → prepareForSnap → snapState=.docked → lockFrame → isSnapping=false. Never use NSAnimationContext for off-screen animation.

**Window settings** — `windowResizability(.automatic)` and `isMovableByWindowBackground = false` must never change.

**Timers** — always `RunLoop.main.add(timer, forMode: .common)`, callbacks use `MainActor.assumeIsolated`.

**XY FX** — `applyXYEffect` must NOT write to @Published state (prevents SwiftUI re-render loop).

**No external dependencies** — 100% Apple native frameworks only.

## What to look for:
- Bugs and crashes (force unwraps, race conditions, memory leaks, retain cycles)
- Violations of the architecture rules above
- Main thread blocking (audio/analysis work must be Task.detached)
- SwiftUI re-render loops
- Timer/observer leaks (missing invalidate/removeObserver)
- Incorrect use of shared singletons vs per-player instances

## Already resolved — do NOT flag these again:
- `playbackToken` / `bumpToken()` locking: NSLock-protected, atomic increment, correct usage throughout
- `progressTimer` capture pattern: local `let t = progressTimer; progressTimer = nil` before async dispatch — intentional
- `stopHoldSeek()` thread safety: has same main-thread dispatch guard as progressTimer
- `holdSeekTimer` in deinit: already invalidated
- `AudioEngineNext.secondary.pause()` before window close in `SplitModeManager.deactivate()`: intentional hang-fix
- `stopHoldSeek()` restoring pitch state: `applyPitchState()` is called at end — restores pitchNode.bypass and speedNode.rate
- `CrossfaderGapWindow.close()` + deinit observer cleanup: both paths clear observers, idempotent by design
- `BandHitTestView.hitRadius`: set to 60px (matches spec)
- `BandHitTestView` segment guard: uses distance² > 16 (not exact equality)
- `ArtworkCache.writeToDisk`: runs on background queue, uses `.atomic` write
- `DispatchQueue.main.async` (not sync) for timer invalidation off-main: intentional deadlock prevention
- `MainActor.assumeIsolated` in RunLoop.main timer callbacks: correct pattern per CLAUDE.md
- `model="claude-opus-4-7"`: this model ID is valid and the workflow runs successfully — do not flag
- `Task.sleep(nanoseconds:)` deprecation: acknowledged tech debt in CLAUDE.md, out of scope for this PR
- `AudioEngineNext.secondary` eager init: pre-existing architecture, out of scope for this PR
- `currentURL`/`audioFile` thread safety: pre-existing architecture concern, out of scope
- `EQCurveView.animateTo` Task churn: pre-existing, out of scope
- `AudioEngineNext.init()` is `private` — enforces 2-instance invariant
- `AudioEngineNext.deinit` timer thread guard: capture pattern added, same as `stop()`
- `BandHitTestView.hitRadius` is `let` — never reassigned
- `ClonePlayerShell.resizeWindow` screen bounds: clamps to `screen.visibleFrame`
- `EmptyOverlayView.startTypewriter`: `animTask?.cancel()` called at top before new task
- `CrossfaderBridgeView` `@ObservedObject var manager`: correctly declared, Canvas redraws on crossfade change ✓
- `SplitModeManager.activate()` copies `primaryState.volume` to `secondaryState` ✓
- `bumpToken()` discarded in `stop()`: intentional — stop() does not schedule any buffers
- `AudioEngineNext.stop()` `stopHoldSeek()` off-main: has main-thread dispatch guard for timer invalidation
- `CrossfaderGapWindow` double-close observer cleanup: idempotent, safe
- `ClonePlayerShell.resizeWindow` vs snap: clone window is never snap-managed, no conflict possible

## Output format:
Write in English. Group findings by severity:
- 🔴 **Critical** — crashes, data loss, broken architecture invariants
- 🟡 **Warning** — performance issues, potential bugs, rule violations
- 🟢 **Suggestion** — minor improvements, style, cleanup

Only flag issues NOT in the "Already resolved" list above. End with a brief summary (2-3 sentences). Be direct, no filler."""


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


def main() -> None:
    api_key = os.environ["ANTHROPIC_API_KEY"]
    github_token = os.environ["GITHUB_TOKEN"]
    pr_number = os.environ["PR_NUMBER"]
    repo = os.environ["REPO"]
    pr_title = os.environ.get("PR_TITLE", "")

    with open("pr_diff.txt", "r", encoding="utf-8", errors="replace") as f:
        diff = f.read()

    # Truncate if massive — Claude handles up to ~180k tokens, cap at 120k chars
    MAX_DIFF = 120_000
    truncated = ""
    if len(diff) > MAX_DIFF:
        diff = diff[:MAX_DIFF]
        truncated = f"\n\n> ⚠️ Diff was truncated to {MAX_DIFF} characters."

    if not diff.strip():
        print("Empty diff, skipping review.")
        return

    client = anthropic.Anthropic(api_key=api_key)

    message = client.messages.create(
        model="claude-opus-4-7",
        max_tokens=4096,
        system=SYSTEM_PROMPT,
        messages=[
            {
                "role": "user",
                "content": f"PR: {pr_title}\n\n```diff\n{diff}\n```",
            }
        ],
    )

    review_body = message.content[0].text
    comment = f"## Claude Code Review\n\n{review_body}{truncated}\n\n---\n*Reviewed by claude-opus-4-7*"

    post_comment(repo, pr_number, comment, github_token)
    print("Review posted successfully.")


if __name__ == "__main__":
    main()
