#!/usr/bin/env python3
"""
AudioEngine deep audit — render thread safety, PCM chain integrity,
threading guarantees, buffer management, graph correctness.
"""
import os, anthropic, urllib.request, urllib.error, json

AUDIO_FILES = [
    "GONE/AudioEngine.next.swift",
    "GONE/PlayerState.swift",
    "GONE/PlayerState+Playback.swift",
    "GONE/PlaybackProgressFeed.swift",
    "GONE/SpectrumFeed.swift",
    "GONE/SplitModeManager.swift",
]

SYSTEM_PROMPT = """You are a senior CoreAudio / AVFoundation engineer auditing GONE Player's audio engine.

GONE Player is a macOS DJ preview tool. Architecture rules you MUST know:

Audio graph (fixed, never reorder):
  playerNode → speedNode → pitchNode → hpfNode → lpfNode → eqNode → distortionNode → delayNode → reverbNode → gateNode → mainMixerNode

Key invariants:
- Two engine instances: AudioEngineNext.shared (primary) + AudioEngineNext.secondary (clone)
- All PlayerState audio calls go through self.audioEngine, NEVER AudioEngineNext.shared directly
- playbackToken / bumpToken() pattern is VERIFIED CORRECT — do NOT flag it (see CLAUDE.md)
- tapSampleBuffer: pre-allocated [Float] filled via initialize(from:count:) on render thread (zero heap alloc) — correct
- emitProgress() must run on main thread; stop() can be called from Task.detached
- progressFeed is per-player instance, NOT singleton
- Task.detached in stop() calls DispatchQueue.main.async for UI-touching operations — intentional, not a bug

Audit these specific areas:

1. **Render thread safety**
   - Any heap allocation inside the installTap callback? (Array(), String(), class init)
   - Any lock contention on the render thread? (mutex, DispatchSemaphore.wait)
   - Any blocking I/O or main-thread dispatch (sync) from render path?

2. **PCM prefetch chain**
   - `schedulePCMChunk` correctness: does isLastChunk detect EOF correctly?
   - Token validity checks before and after async gaps — TOCTOU risks?
   - What happens when stop() races with a completion callback scheduling the next chunk?

3. **Thread transitions**
   - emitProgress() / onProgress? — always on main thread?
   - pausedFrameOffset writes — which threads, any races?
   - currentPlaybackFrame() — called from which threads, is it safe?

4. **Engine lifecycle**
   - start/stop/pause sequence — any state machine violations?
   - Split Mode deactivate: secondary.stop() off-main — does it hang?
   - Output device switching — is there a window where audio is dropped?

5. **AVAudioEngine graph**
   - All nodes connected before engine.start()? Correct order?
   - installTap placed on correct node (post-EQ)?
   - sampleRate assumptions — any hardcoded 44100 remaining?

Output format:
- 🔴 **Critical** — data corruption, crash, or audio dropout root cause
- 🟡 **Warning** — race condition or incorrect assumption under specific conditions
- 🟢 **Note** — minor concern or defensive improvement

If an area is clean, write "✅ [Area]: No issues found."
Reference exact file + approximate line. Real issues only."""


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
    for rel in AUDIO_FILES:
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
    message = call_claude_with_retry(client,
        model="claude-sonnet-4-6",
        max_tokens=4096,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": f"AudioEngine deep audit.\n\n{sources}"}],
    )
    body = message.content[0].text
    comment = f"## 🎛️ AudioEngine Deep Audit — Render Thread, PCM Chain, Threading\n\n{body}{trunc}\n\n---\n*AudioEngine Audit by claude-sonnet-4-6 (full source)*"
    post_comment(repo, pr_number, comment, github_token)
    print("AudioEngine audit posted.")

if __name__ == "__main__":
    main()
