---
name: engram
description: Operate the engram-sync memory system — check sync health, pull or push memory, connect agent harnesses, read an ALERT. Use when the user says "engram", "sync memory", "is memory synced", "connect <agent> to memory", or when ALERT text from engram appears in context.
---

# Engram

Cross-machine memory for coding agents. A private git repo (default `~/engram`, override `ENGRAM_HOME`) holds markdown facts; `engram-sync` pulls at session start, pushes at session end, and pushes every 30 minutes in the background.

## Commands

| Task | Command |
|---|---|
| Health check | `engram doctor` |
| Pull / push now | `engram sync pull` / `engram sync push` |
| Connect agents (skills + instructions + hooks) | `engram connect` (all detected) or `engram connect claude codex` |
| Remove from an agent | `engram disconnect <harness>` |
| Background sync on/off | `engram schedule on` / `engram schedule off` |
| New machine | `pip install engram-sync` then `engram init <owner/repo or git URL>` |

Harnesses: `claude`, `codex`, `opencode`, `antigravity`, `muse`.

## Rules

- `ALERT.md` at the repo root, or `# Engram sync ALERT` in context, means this machine could not sync. Surface it to the user first, then fix it: a conflict ALERT → run the `engram-consolidate` skill; a secret-scan ALERT → remove the secret or mark a false positive with `<!-- engram:not-a-secret -->` on that line, then `engram sync push`.
- Only paths listed in `.engram/sync-paths.conf` sync automatically (default `index.md projects/ global/ inbox/ archive/`). Anything else needs a deliberate manual commit.
- Never commit around the secret scan. Never store credentials in memory.
- To save a fact, use the `engram-remember` skill.
