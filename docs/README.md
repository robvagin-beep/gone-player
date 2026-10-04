# Docs

Working notes from building GONE with AI agents. They are kept as they were written: each one describes the state of the app on its date.

| File | What it is |
|---|---|
| `GONE_BACKLOG.md` | the live backlog |
| `GONE_SYSTEM_TOC.md` | map of the codebase: feature → file |
| `GONE_AGENT_CONTEXT.md` | short context every agent session starts with |
| `GONE_AI_HANDOFF.md` | handoff between sessions |
| `GONE_GPT_BRIEF.md` | brief for a second model |
| `codex-tasks.md` | tasks handed to Codex |
| `GONE_Tasks_Beta08.md` | task queue for Beta 0.8–0.9 |
| `GONE_AUDIT.md`, `GONE_Code_Audit_Recommendations_2026-05-12.md`, `GONE_Deep_Audit_Recommendations_2026-05-12.md`, `GONE_Claude_Final_Sweep.md` | code audits and their follow-ups |
| `website/` | design brief for the GONE landing page |
| `assets/` | images used by the README |

The rules the agents follow live in [`../CLAUDE.md`](../CLAUDE.md).

**Moved on 2026-10-04:** the audit, packaging and pre-merge scripts went from the repository root to [`../tools/`](../tools/), and these notes went from the root to `docs/`. Older notes still name them at their old place. Run the scripts from the repository root, for example `python3 tools/full_audit.py`.
