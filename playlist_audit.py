#!/usr/bin/env python3
"""
Playlist & Library pipeline audit for GONE Player.
Targets: import flow, batch processing, tabs, drag & drop, cascade,
sort correctness, keyboard navigation, state consistency.
"""
import os, anthropic, urllib.request, urllib.error, json

PLAYLIST_FILES = [
    "GONE/PlayerState.swift",
    "GONE/PlayerState+Playlists.swift",
    "GONE/PlayerState+Playback.swift",
    "GONE/PlayerState+Analysis.swift",
    "GONE/PlaylistView.swift",
    "GONE/LibraryScanner.swift",
    "GONE/Track.swift",
    "GONE/GONEApp.swift",
]

SYSTEM_PROMPT = """You are a senior SwiftUI/AppKit engineer auditing a music library
management pipeline in GONE Player — a macOS DJ tool (macOS 13+).

GONE Player's library model:
- No persistent database — playlists are session-only tabs in memory
- Tracks are imported by drag-and-drop or folder open (NSOpenPanel)
- Each tab ("playlist") is an independent [Track] array in PlayerState
- Import is batched: up to 4 concurrent readMetadata calls, committed to main thread per batch
- BPM + waveform analysis runs AFTER import, also async
- Sort: manual drag-to-reorder OR auto-sort by BPM/title/artist/duration
- Split Mode: two independent PlayerState instances sharing a track list copy

Your deep expertise covers:
- SwiftUI List + ForEach drag-and-drop reordering edge cases
- Batch async commit patterns (merge conflicts between batches)
- Keyboard navigation in SwiftUI (focusState, onKeyPress, event monitors)
- UUID-based track identity vs index-based operations
- Value-type array mutation under concurrent read (CoW)
- Tab/playlist lifecycle: create, rename, delete, switch"""

RESEARCH_PROMPT = """## Audit objective

Find every correctness bug, race condition, and UX failure in the
playlist and library import pipeline.

### 1. Import pipeline correctness
- Batch size 4: tracks from the same album — do they maintain relative order?
- `placeholderTrack` added before metadata read — what if readMetadata fails?
  Does the placeholder get cleaned up or remain as a ghost track?
- The merge step in importURLs: `updated.hasArtwork = track.hasArtwork || t[idx].hasArtwork`
  and `updated.waveform = t[idx].waveform` — can a race between two batches
  corrupt a track's state?
- If the user drags another folder in WHILE a first import is running,
  what happens? Does `isImporting` guard correctly serialize them?
- Duplicate detection: if the user drops the same folder twice,
  are duplicates filtered? If not, what breaks downstream (BPM analysis runs twice)?

### 2. Tab / playlist state
- Tab switch: does `currentId` get reset or preserved?
- Delete tab: if the deleted tab is current, which tab becomes active?
- Rename tab: is there a max-length guard? What if the user sets an empty name?
- `secondaryPlaylistTabId` exists in PlayerState but has no UI — what state does
  it hold, and can it become stale/inconsistent?

### 3. Drag-to-reorder correctness
- SwiftUI `.onMove` with auto-sort enabled: if auto-sort is on, can the user drag?
  What happens if they do? Does the move get immediately overridden by a sort?
- After manual reorder: does `currentId` track correctly?
  If track at index 3 is moved to index 1, does "current" still point to the right track?
- Drag during active BPM analysis: the analysis pipeline holds a snapshot of `pending`
  tracks. If the user reorders, does the queue order update correctly via `bpmPriorityId`?

### 4. Sort correctness
- Auto-sort on drag: when is it triggered? Does it run on every file drop or
  only when the folder contains unsorted tracks?
- BPM sort with `bpm == 0` tracks (pending analysis) — where do they sort to?
  Do they stay in place or jump to top/bottom?
- Sort stability: if two tracks have equal BPM, is their relative order preserved?
- Sort during playback: does current track position jump?

### 5. Keyboard navigation
- Arrow key event monitor in GONEApp: passes events through to SwiftUI when
  `playlistOpen`. Can this conflict with other SwiftUI focus handlers?
- `focusScrollTarget` in PlaylistView: is it correctly reset when the playlist
  switches tabs or the track list changes?
- Enter key plays only if `selectedIds.count == 1` — what if count == 0?
  Is there a guard? What if the user presses Enter on an empty playlist?
- Multi-select: Shift+click and Cmd+click — are both supported?
  Does `selectionAnchorId` correctly handle the Shift+click range?

### 6. State consistency across Split Mode
- SplitModeManager.activate() copies tracks from primary to secondary.
  If primary is still importing when Split Mode activates, does secondary
  get a partial or complete track list?
- After Split Mode deactivates, does primary's playlist state remain unchanged?
- Hot cue reset: `playTrack()` resets `hotCues = [nil,nil,nil,nil]`.
  In Split Mode, do primary and secondary hot cues stay independent?

### 7. Specific patterns to flag
For each issue:
- File + approximate line
- Concrete user action that triggers it
- Visible symptom (what the user sees)
- Fix with code snippet where possible
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
    for rel in PLAYLIST_FILES:
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
        trunc = f"\n\n> ℹ️ Full source: {original_len:,} chars across {len(PLAYLIST_FILES)} files."

    ITERATIVE_PROTOCOL = """
## Iterative Refinement Protocol — five passes, output Pass 5 only.

PASS 1: every import, sort, drag, keyboard nav, tab, and Split Mode candidate issue.
PASS 2: self-critique — distinguish theoretical races from real observable bugs.
  Check CLAUDE.md "Already Resolved" section before flagging anything.
PASS 3: compare to shipping music apps (Doppler, Vinyls, Swinsian) import patterns.
PASS 4: adversarial — could "bugs" be intentional constraints of the session-only model?
PASS 5: synthesis. Cap at 7. Rank by user-visible impact. Include drop-in fix where possible.
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
        "## 📂 Playlist & Library Pipeline Audit — Opus 4.7 + Extended Thinking\n\n"
        f"{body}{trunc}\n\n---\n"
        f"*Playlist Audit by claude-opus-4-7 ({message.usage.input_tokens:,} in / {message.usage.output_tokens:,} out)*"
    )
    post_comment(repo, pr_number, comment, github_token)
    print("Playlist audit posted.")

if __name__ == "__main__":
    main()
