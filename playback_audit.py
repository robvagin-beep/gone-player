#!/usr/bin/env python3
"""
Playback accuracy audit for GONE Player.
Targets: PCM chunk scheduling, seek correctness, hot cues, pitch/speed
accuracy, progress feed, Split Mode playback independence.
"""
import os, anthropic, urllib.request, urllib.error, json

PLAYBACK_FILES = [
    "GONE/PlayerState+Playback.swift",
    "GONE/AudioEngine.next.swift",
    "GONE/PlayerState.swift",
    "GONE/GONEApp.swift",
    "GONE/PlaybackProgressFeed.swift",
    "GONE/SplitModeManager.swift",
    "GONE/WaveformView.swift",
    "GONE/TransportView.swift",
]

SYSTEM_PROMPT = """You are a senior audio software engineer with deep expertise in
AVAudioEngine, PCM scheduling, and real-time playback accuracy on macOS.

You have deep expertise in:
- AVAudioPlayerNode scheduling: scheduleBuffer, scheduleFile, completion handlers
- PCM chunked playback: frame-accurate seeking, chunk boundary stitching
- Sample rate conversion and pitch/speed correction accuracy
- AVAudioUnitTimePitch vs AVAudioUnitVarispeed tradeoffs
- Playback token patterns for concurrency-safe seek/stop
- Progress timer accuracy: RunLoop-based vs display-link-based approaches
- Hot cue implementation: frame offset calculation, seek-to-cue accuracy
- Split Mode: two independent AVAudioEngine instances, crossfader gain law

GONE Player audio architecture:
- Fixed chain: playerNode → speedNode → pitchNode → hpf → lpf → eq → distortion → delay → reverb → gate → mainMixer
- PCM chunked playback: large files split into chunks, pre-scheduled as circular buffer
- playbackToken (UInt64): bumped on every load/seek/stop — guards stale completions
- progressTimer: RunLoop.main, .common mode, 1/60s interval
- Hot cues: [Double?] — stores playback time offset (seconds), not frame index
- Pitch: AVAudioUnitTimePitch for semitone shifts, speedNode rate for tempo
- Split Mode: AudioEngineNext.secondary mirrors primary's output device on activate"""

RESEARCH_PROMPT = """## Audit objective

Find every playback accuracy bug, seek error, timing drift, and
state corruption issue in the playback pipeline.

### 1. PCM chunk scheduling correctness
- Chunk boundary stitching: when chunk N completes, chunk N+1 is scheduled
  in the completion handler. Is there a guaranteed gap-free stitch?
  What if the completion handler fires late (main thread busy)?
- Frame offset calculation for seek: converting seconds → sample frames →
  chunk start frame. Is the math correct for all sample rates (44100, 48000, 96000)?
  Is there an off-by-one at chunk boundaries?
- `startFrame` passed to `schedulePCMChunk` — is it relative to the file start
  or to the chunk start? Verify the arithmetic is consistent throughout.
- After seek: old scheduled buffers from the previous position — are they
  all cancelled before new chunks are scheduled? Does `playerNode.stop()`
  followed immediately by `scheduleBuffer` guarantee the old buffer is gone?
- What happens if the user seeks to the VERY END of the track?
  Does the chunk math produce a zero-length chunk? Is that guarded?

### 2. playbackToken race conditions
- `bumpToken()` returns the new token value. Callers use it to guard
  stale completion handlers. Verify: is there any path where a stale
  handler can schedule a buffer AFTER a new track has started loading?
- `stop()` bumps token but does NOT await the next completion handler.
  If a completion handler is already enqueued on the main thread and fires
  AFTER `stop()` completes, does it correctly detect the stale token?

### 3. Progress timer accuracy
- `progressTimer` fires at 60Hz on RunLoop.main with .common mode.
  Under heavy analysis load (100 tracks importing), does the main runloop
  get starved enough to cause visible progress bar stutter?
- `currentTime` calculation: `playerNode.lastRenderTime` + node time offset.
  Is this calculation correct when speedNode.rate != 1.0?
  Does displayed time track the audible position accurately at 1.5× speed?
- Progress is broadcast via `progressFeed.send()`. In Split Mode, each
  player has its own `progressFeed`. Are they guaranteed never to cross-contaminate?

### 4. Hot cue accuracy
- Hot cues store Double (seconds). On recall, they trigger a seek.
  Is the seek frame calculation `time × sampleRate` rounded correctly?
  At 48000 Hz, rounding errors could place the cue ±1 frame — audible?
- Hot cue set during a pitch-shifted playback: is the stored time the
  real wall-clock time or the pitch-adjusted time?
  On recall at a different pitch, does the cue land in the right place?
- Secondary player (keys 5-8): does `SplitModeManager.secondaryState`
  access correctly route hot cue actions to the secondary PlayerState?

### 5. Pitch + speed correctness
- varispeed range ±100% means `speedNode.rate` can go from 0 to 2.0.
  At rate → 0, AVAudioUnitVarispeed behavior is undefined — does the engine stall?
  Is there a floor guard (e.g., min 0.05)?
- Pitch node bypass during hold-seek: `stopHoldSeek()` restores
  `pitchNode.bypass` and `speedNode.rate`. Is the restoration order correct?
  (bypass pitch before restoring rate, or vice versa?)
- MT (musical transposition) button: what does it toggle? Does it affect
  the displayed BPM or just the pitch node?

### 6. Split Mode playback independence
- Two AVAudioEngine instances: do they share any mutable state?
- Crossfader at position 0.0 (full primary): does secondary still consume CPU
  for decoding? Is it paused or just muted?
- Output device sync: `AudioEngineNext.secondary.setOutputDevice(primaryDeviceID)`
  — if the user changes the output device AFTER Split Mode is active, does
  secondary track the change?
- When Split Mode deactivates: `AudioEngineNext.secondary.pause()` on main,
  then `stop()` off-main. Is there a window where audio artifacts are produced
  during the pause→stop transition?

### 7. WaveformView seek accuracy
- Tap-to-seek in WaveformView: converts tap X position to a time offset.
  Is the math correct for tracks with non-zero start offset (chunked from middle)?
- During seek, is the waveform playhead updated optimistically (before audio confirms)
  or after the seek completes?

For each issue:
- File + approximate line
- Concrete reproduction (track length, sample rate, speed setting that triggers it)
- Audible/visible symptom
- Fix
"""


def call_claude_with_retry(client, **kwargs):
    import time
    for attempt in range(3):
        try:
            return client.messages.create(**kwargs)
        except Exception as e:
            if "rate_limit" in str(e).lower() and attempt < 2:
                print(f"Rate limited, waiting 65s... (attempt {attempt + 2}/3)")
                time.sleep(65)
            else:
                raise

def load_sources(base):
    parts = []
    for rel in PLAYBACK_FILES:
        path = os.path.join(base, rel)
        try:
            with open(path, "r", encoding="utf-8") as f:
                content = f.read()
            parts.append(f"// ═══ {rel} ({content.count(chr(10))} lines) ═══\n{content}")
        except FileNotFoundError:
            parts.append(f"// ═══ {rel} — NOT FOUND ═══\n")
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

    base    = os.path.dirname(os.path.abspath(__file__))
    sources = load_sources(base)

    original_len = len(sources)
    MAX = 200_000
    if original_len > MAX:
        cut = sources.rfind("\n", 0, MAX)
        sources = sources[:cut if cut > 0 else MAX]
        trunc = f"\n\n> ⚠️ Source truncated to {len(sources):,} of {original_len:,} chars."
    else:
        trunc = f"\n\n> ℹ️ Full source: {original_len:,} chars across {len(PLAYBACK_FILES)} files."

    ITERATIVE_PROTOCOL = """
## Iterative Refinement Protocol — five passes, output Pass 5 only.

PASS 1: every seek math error, token race, progress drift, hot cue miss,
  pitch/speed edge case, and Split Mode interaction candidate.
PASS 2: self-critique — check CLAUDE.md "Already Resolved".
  playbackToken pattern is fully verified — do not re-flag.
  progressTimer capture pattern is verified — do not re-flag.
PASS 3: compare to Mixxx source (open-source DJ software), Apple's
  AVAudioEngine sample code, and WWDC "AVAudioEngine in Practice" sessions.
PASS 4: adversarial — steelman edge cases. Could off-by-one in frame math
  be below audible threshold? Is hot cue ±1 frame actually audible?
PASS 5: synthesis. Cap at 7. Rank by audible user impact.
  Focus on "DJ hears a glitch" severity, not theoretical correctness.
"""

    client = anthropic.Anthropic(api_key=api_key)
    message = call_claude_with_retry(client,
        model="claude-opus-4-7",
        max_tokens=12000,
        thinking={"type": "adaptive"},
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": ITERATIVE_PROTOCOL + "\n\n" + RESEARCH_PROMPT + "\n\n## Source files\n\n" + sources}],
    )
    body = "\n\n".join(b.text for b in message.content if b.type == "text")
    comment = (
        "## 🎵 Playback Accuracy Audit — Opus 4.7 + Extended Thinking\n\n"
        f"{body}{trunc}\n\n---\n"
        f"*Playback Audit by claude-opus-4-7 ({message.usage.input_tokens:,} in / {message.usage.output_tokens:,} out)*"
    )
    post_comment(repo, pr_number, comment, github_token)
    print("Playback audit posted.")

if __name__ == "__main__":
    main()
