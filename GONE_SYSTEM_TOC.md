# GONE Player — system TOC and interaction map

Version: 0.2
Date: 2026-06-12
Status: living navigation map (snapshot refreshed after the Beta 1.0 sprint)
Owner: Robert / GONE operator

---

## Purpose

This file is the top-level navigation map for future work on GONE Player

It does not replace `CLAUDE.md`, `GONE_BACKLOG.md`, or code comments

It tells a working AI:

- what to read first
- which files own which part of the app
- which docs are current, stale, or archival
- which routes are broken
- how to create a handoff before context compaction or session loss

---

## Start here

Every GONE session starts with this order:

1. Read `GONE_SYSTEM_TOC.md`
2. Read `CLAUDE.md`
3. Read `GONE_BACKLOG.md`
4. Check `git status --short --branch`
5. If touching code, read the exact files listed in the routing table
6. If the task is large, audit-only, or multi-file, delegate through GitHub/Anthropic instead of implementing locally

Hard rule:

```text
No code changes are made locally unless Robert explicitly says: "сделай здесь прямо сейчас"
```

---

## Current repo state snapshot

Snapshot date: 2026-06-12

```text
Branch: dev (synced with origin/dev)
Version: Beta 1.0 (package_beta10.sh)
Working tree: clean
Workflows: full audit suite restored in .github/workflows (25 files, workflow_dispatch on PR #1)
```

Architecture highlights since 0.9 (details in CLAUDE.md §8 and git log):
- Primary window is a true FloatingPlayerPanel (NSPanel), bootstrap in AppDelegate
- Full-width snap model: snapped window keeps width, body slides past the edge;
  dock side is a setting (right default / left mirrored)
- All decode/DSP is nonisolated (MainActor-by-default trap) — UI stays responsive
- BPM: multi-window voting + breaks rescue + dance-floor sanity + genre presets;
  normalizeDanceBPM is the single normalization for all three paths
- Waveform: 1-device-px lattice, solid #8C8C8C dividers, opacity-only hierarchy

---

## Source of truth map

| Source | Role | Status | Read when |
|---|---|---|---|
| `GONE_SYSTEM_TOC.md` | top-level navigation and session rules | current draft | always first |
| `CLAUDE.md` | product context, architecture invariants, file map, false positives | current but needs small status updates | before any code/task reasoning |
| `GONE_BACKLOG.md` | living task queue and GitHub issue queue | current but workflow map stale | choosing or sending tasks |
| `GONE_CURATOR.md` | task framing rules and local vs GitHub classification | useful but status stale | writing GitHub/Claude tasks |
| `GONE_Tasks_Beta08.md` | Beta 0.8 to 0.9 task queue | partly historical | only when comparing old task queue |
| `GONE_Code_Audit_Recommendations_2026-05-12.md` | large audit recommendations | archival / source for issues | only when preparing audit issues |
| `GONE_Deep_Audit_Recommendations_2026-05-12.md` | deep audit recommendations | archival / source for issues | only when preparing audit issues |
| `GONE_Sweep_Action_Plan.md` | sweep action plan | untracked, review before canonical use | only for sweep planning |
| `GONE_GPT_BRIEF.md` | external GPT research brief | archival / external review | when sending context to non-repo AI |
| `codex-tasks.md` | older Codex task list | likely stale | only if explicitly referenced |

---

## Resolved historical blockers (2026-05-13 list — all addressed)

The five blockers from the 0.1 audit are closed: audit workflows restored, CI route
confirmed (workflow_dispatch + PR review), version/status docs updated. Section kept
for history; current truth is CLAUDE.md + git log.

## Stale or disconnected blocks found (historical, 2026-05-13)

### 1. Workflow map in `GONE_BACKLOG.md` is stale

`GONE_BACKLOG.md` maps issues to workflows such as:

```text
audio-engine-audit.yml
bpm-analysis-audit.yml
hang-audit.yml
launch-perf-audit.yml
playlist-audit.yml
snap-audit.yml
ui-audit.yml
```

But those workflow files are currently staged as deleted and no longer physically present

Current physical workflows:

```text
.github/workflows/pr-review.yml
.github/workflows/premerge-check.yml
```

Action needed:

```text
Replace issue-to-workflow map with current route:
GitHub Issue / PR → PR Review workflow, or restore audit workflows before referencing them
```

### 2. `premerge-check.yml` references a missing script

Current workflow:

```text
.github/workflows/premerge-check.yml → python premerge_check.py
```

But:

```text
premerge_check.py is staged as deleted
```

Action needed:

```text
Either restore premerge_check.py, update workflow to an existing script, or mark premerge route as blocked
```

### 3. `GONE_CURATOR.md` status is stale

It says:

```text
Beta version: 0.7
Package script: package_beta07.sh
```

Current memory/backlog says:

```text
Beta version: 0.9
Package script: package_beta08.sh
```

Action needed:

```text
Update Current Build Status in GONE_CURATOR.md or mark it as historical task-framing document
```

### 4. Issue delegation route is ambiguous

Docs say:

```text
gh issue create + label claude-task → claude-review workflow
```

But current workflow files show PR review, not an issue-trigger workflow

Action needed:

```text
Confirm actual GitHub route:
- issue comment trigger exists remotely?
- PR-only review is current path?
- audit workflows intentionally removed?
```

Until confirmed, do not assume `claude-task` issue label triggers processing

### 5. Multiple audit docs overlap

Current audit docs:

```text
GONE_Code_Audit_Recommendations_2026-05-12.md
GONE_Deep_Audit_Recommendations_2026-05-12.md
GONE_Claude_Final_Sweep.md
GONE_Sweep_Action_Plan.md
GONE_AUDIT.md
```

Risk:

```text
Future AI may reopen solved issues or pull old recommendations without checking CLAUDE.md false positives
```

Action needed:

```text
Treat audit docs as source material only
Current truth stays in CLAUDE.md + GONE_BACKLOG.md + git state
```

---

## Feature to file routing

| If task is about | Read first | Then read | Do not touch without explicit need |
|---|---|---|---|
| product scope / what belongs | `CLAUDE.md`, `GONE_CURATOR.md` | `GONE_BACKLOG.md` | Swift files |
| task queue / priorities | `GONE_BACKLOG.md` | `GONE_CURATOR.md` | audit docs unless preparing issue |
| audio playback / graph / pitch / speed | `CLAUDE.md` | `GONE/GONE/AudioEngine.next.swift`, `GONE/PlayerState+Playback.swift` | node order |
| BPM / waveform / analysis | `CLAUDE.md`, `GONE_BACKLOG.md` | `GONE/PlayerState+Analysis.swift`, `GONE/LibraryScanner.swift`, `GONE/AnalysisCache.swift` | UI unless symptom requires |
| playlist / tabs / import | `CLAUDE.md` | `GONE/PlaylistView.swift`, `GONE/PlayerState+Playlists.swift` | audio engine |
| Snap edge / bolt / dock / peek | `CLAUDE.md` | `GONE/WindowSnapManager.swift`, `GONE/RootView.swift`, `GONE/GONEApp.swift`, `GONE/PeekPanelView.swift` | state machine sequence |
| Split / Clone / crossfader | `CLAUDE.md` | `GONE/SplitModeManager.swift`, `GONE/CrossfaderBandPanel.swift`, `GONE/FullPlayerView.swift`, `GONE/ClonePlayerShell.swift` | primary snap logic unless conflict |
| hot cues / keyboard | `CLAUDE.md` | `GONE/GONEApp.swift`, `GONE/PlayerState.swift`, `GONE/PlaylistView.swift` | unrelated playlist model |
| XY / FX / EQ | `CLAUDE.md` | `GONE/EQPanelView.swift`, `GONE/RootView.swift`, `GONE/PlayerState.swift`, `GONE/PlayerState+EQ.swift` | audio graph order |
| waveform UI / beat ticks | `CLAUDE.md` | `GONE/WaveformView.swift`, `GONE/PlayerState+Analysis.swift`, `GONE/LibraryScanner.swift` | BPM scheduler unless needed |
| spectrum UI / spectrum feed | `CLAUDE.md` | `GONE/SpectrumView.swift`, `GONE/SpectrumFeed.swift`, `GONE/GONE/AudioEngine.next.swift`, `GONE/TrackHeaderView.swift` | visual redesign |
| window / AppKit bridge | `CLAUDE.md` | `GONE/GONEApp.swift`, `GONE/UIHelpers.swift`, `GONE/WindowSnapManager.swift` | SwiftUI shell unless needed |
| packaging / DMG | `CLAUDE.md` | `package_beta08.sh`, `GONE/GONE_release.entitlements` | xcodebuild-in-script |
| CI / Anthropic review | `GONE_SYSTEM_TOC.md` | `.github/workflows/*.yml`, `.github/scripts/*.py`, `GONE_BACKLOG.md` | old workflow references |

---

## Current core invariants

Never violate:

```text
Audio graph order:
playerNode → speedNode → pitchNode → hpfNode → lpfNode → eqNode → distortionNode → delayNode → reverbNode → gateNode → mainMixerNode
```

```text
Use state.audioEngine / self.audioEngine in views and PlayerState extensions
Do not call AudioEngineNext.shared directly there
```

```text
WindowSnapManager state machine is fragile
Read full file before changing it
Do not replace timer-based snap with NSAnimationContext
```

```text
Timers use RunLoop.main.add(timer, forMode: .common)
Timer callbacks use MainActor.assumeIsolated where existing pattern requires it
```

```text
updateWindowSize is called only from RootView.onChange
windowResizability(.automatic) remains
isMovableByWindowBackground = false remains
```

---

## Interaction policy

### Local vs GitHub

Local allowed:

```text
reading files
auditing docs
creating planning / handoff markdown
preparing GitHub issue text
small inspection commands
```

Local blocked unless Robert explicitly says "сделай здесь прямо сейчас":

```text
Swift code edits
feature implementation
hotfixes
multi-file refactors
architecture changes
packaging changes
workflow/script edits that affect CI behavior
```

GitHub / Anthropic route preferred:

```text
large audits
whole-app review
multi-file Swift changes
Snap / SplitMode / audio graph work
performance / threading passes
```

---

## Handoff and compact protocol

Purpose:

Prevent loss of work when a long terminal / Codex / AI session approaches compaction or context loss

### Trigger

Create or update `GONE_SESSION_HANDOFF.md` when any of these is true:

```text
The session is long and context compaction is likely
The user says "сохранить", "handoff", "compact", "заканчиваем", or "продолжим потом"
The work involved more than one subsystem
The work changed or analyzed task routing, backlog, CI, or architecture rules
The assistant is about to stop after discovering unresolved contradictions
There is a risk future AI would need to re-analyze the same files
```

Operational rule:

```text
If the assistant can see that context is running low, create handoff at roughly the last 10-15 percent of usable context
If only 5 percent remains, write a compact emergency handoff with current state, files touched/read, decisions, and next action
```

### Required handoff sections

```md
# GONE session handoff

Date:
Branch:
Latest commit:
Working tree state:
Session goal:

## What was read

## What was found

## Decisions made

## Files changed

## Code untouched

## Broken or stale routes

## Current blockers

## Next best action

## Do not redo

## Commands/results worth preserving
```

### Handoff location

Default:

```text
/Users/robertvagin/Desktop/GONE/GONE_SESSION_HANDOFF.md
```

If the work is about a specific task or issue:

```text
/Users/robertvagin/Desktop/GONE/handoffs/YYYY-MM-DD-short-topic.md
```

### Compact emergency template

Use this if context is nearly gone:

```md
# GONE compact handoff

Date:
Current task:
Branch/status:
Files read:
Key findings:
Stale docs/routes:
Files changed:
Next action:
Do not redo:
```

---

## Change log protocol

For now, do not create a heavy project-wide changelog for every discussion

Use this rule:

```text
Code changes are tracked by git
Architecture/doc-routing changes are tracked in GONE_SYSTEM_TOC.md or GONE_SESSION_HANDOFF.md
Release/package changes should be added to a future GONE_CHANGELOG.md only when preparing a build
```

Recommended future file:

```text
GONE_CHANGELOG.md
```

Template:

```md
# GONE changelog

| Date | Area | Change | Source | Impact | Follow-up |
|---|---|---|---|---|---|
```

---

## TOC maintenance rules

Update this file when:

```text
A new subsystem appears
A file changes ownership
A workflow/script route changes
A backlog route changes
A doc becomes stale or archival
A new handoff/changelog rule is added
A GitHub delegation path changes
```

Do not update this file for:

```text
tiny UI tweaks
copy changes
single-line bug fixes
routine git status changes
```

---

## Immediate cleanup actions recommended

Do not execute these automatically

1. Decide whether deleted audit workflows/scripts are intentional
2. If intentional, remove old workflow mapping from `GONE_BACKLOG.md`
3. Fix or disable `premerge-check.yml` because `premerge_check.py` is missing
4. Update `GONE_CURATOR.md` current status from Beta 0.7/package_beta07 to Beta 0.9/package_beta08, or mark it as historical
5. Decide whether `GONE_BACKLOG.md` should become tracked canonical backlog
6. Decide whether `GONE_CURATOR.md` should become tracked canonical task-framing doc
7. Add `GONE_SESSION_HANDOFF.md` when the next long work session starts
8. Keep audit docs as archival source material, not active routing truth

---

## Current answer to "where do I go?"

If you only know the symptom:

```text
Read CLAUDE.md → find subsystem in Feature to file routing → read exact file(s) → check GONE_BACKLOG.md for current task priority
```

If you are planning work:

```text
Read GONE_BACKLOG.md → check if workflow route is current → prepare GitHub task if large
```

If context is getting long:

```text
Write GONE_SESSION_HANDOFF.md before continuing
```

If a doc disagrees with code or git state:

```text
Git state and current files win
Mark the doc as stale in this TOC
Do not silently follow old docs
```


---

## Roadmap — systems not yet given the BPM/waveform treatment

Worked-through reference standard: research → labeled bench/measurement → iterate →
verify (see BPM 12/12 corpus and waveform lattice work, 2026-06-10..12).

| System | Current state | The treatment it still needs |
|---|---|---|
| Key detection | Read from tags only (TKEY/iTunes) | Native chromagram + Camelot mapping, bench vs Mixed In Key tags |
| Beat-grid phase | Energy-onset estimate, weak-grid sentinel | Phase tiebreak research (issue #9), downbeat anchoring |
| Loudness / auto-gain | Absent (P2 backlog) | LUFS estimation in the analysis pass, gain to -14 LUFS via mixer |
| Track structure | Absent (P4 idea) | Energy-section detection (intro/drop/outro) on the waveform, QM tempogram refs |
| Codecs | mp3/flac/wav/aiff/m4a/aac/caf | ogg/opus = conscious gap (needs third-party decoder; no-deps rule). Revisit only if the rule changes |
| Snap tab | Full-width model, Space-swipe ghosting accepted | Dedicated mini tab panel (separate small window) — kills the off-screen body class entirely |
