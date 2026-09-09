# Engram

Cross-machine memory system for Claude Code. Markdown in git; a private git hub repo (e.g. GitHub) is the hub; any mix of Windows/Linux nodes syncs around Claude Code sessions. This CLAUDE.md applies when working ON engram itself — day-to-day memory use goes through `index.md`, which is imported into every session by user-level `~/.claude/CLAUDE.md`.

## Layout

- `index.md` — master index, always loaded in every session. Keep small; it is the only always-loaded file.
- `projects/` — one file per project (copy `_template.md`). Lazy-loaded: Claude reads them on demand.
- `global/` — preferences, conventions, machine facts.
- `inbox/` — append-only quick captures (`YYYY-MM.md`), merged out by the consolidate skill.
- `archive/` — dead projects, compressed history.
- `bin/` — cross-platform CLI entrypoints (`engram`, `engram.cmd`, `engram.ps1`).
- `dotfiles/` — harness adapters (`harnesses.json`), MCP registry (`mcp.json.tmpl`), tool configurations.
- `scripts/` — unified CLI engine (`engram_cli.py`), harness manager (`harnesses.py`), sync, doctor, test suite.
- `plugins/engram/skills/` — `engram`, `remember`, `consolidate`, `migrate`; distributed to connected agent harnesses via `engram skills sync`.
- `AGENTS.md` — standing rules for non-Claude agents joining the memory; `SETUP-PROMPT.md` — paste-into-agent installer; `docs/roadmap.md` — improvement plan + status.

## Rules

- Facts, not prose. Atomic entries, dated `YYYY-MM-DD`.
- Size caps: `index.md` < 100 lines, each `projects/*.md` < 300 lines. The consolidate skill enforces by compressing and archiving.
- No secrets, credentials, or tokens — ever. No employer/client-confidential material without explicit approval.
- Sync is automatic: SessionStart pulls, SessionEnd pushes, 30-min scheduled task/cron as safety net. Manual: `engram sync push` / `engram sync pull` (or `scripts/sync.ps1` / `scripts/sync.sh`).
- Harness management: `engram connect <harness|--all>`, `engram skills sync`, `engram mcp sync`.
- `inbox/**` uses git union merge (never conflicts). Other files merge normally; a conflicted rebase is auto-aborted by sync and surfaces at the next consolidate run.
- Normative sync behaviour: `docs/sync-contract.md` — the doc wins over the scripts on any disagreement. After touching either sync script, run `scripts/test-sync.sh` AND `SYNC_IMPL=ps1 scripts/test-sync.sh`; both must pass identically.
