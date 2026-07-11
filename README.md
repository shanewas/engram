# Engram

Persistent, versioned, cross-machine memory for Claude Code. Facts live as plain markdown in a git repo you own; a private GitHub repo is the hub; every node — desktop, laptop, VPS — syncs automatically around Claude Code sessions (SessionStart pull, SessionEnd push, 30-min scheduled task/cron as a backstop). No database, no service, no lock-in: just markdown and git.

## How it works

- `index.md` is always loaded — pulled into every session via `@import` in `~/.claude/CLAUDE.md`.
- `projects/*.md` are lazy-read on demand, one project at a time.
- The `remember` skill captures new facts as they surface; `consolidate` compacts, dedupes, and enforces size caps.
- Sync scripts commit only an allowlisted set of paths and scan every diff for secrets before committing.
- A node that can't sync escalates to a `conflict/<host>` branch + `ALERT.md` instead of silently diverging.

Full behavior is normative in [`docs/sync-contract.md`](docs/sync-contract.md) — read it before touching sync code.

## Layout

| Path | Contents |
|---|---|
| `index.md` | always-loaded routing table — what memory exists, where to read it |
| `projects/` | one file per project, lazy-read on demand |
| `global/` | preferences, conventions, machine facts |
| `inbox/` | append-only quick captures (`YYYY-MM.md`) — union-merged, never conflicts |
| `archive/` | dead projects, compressed history |
| `scripts/` | sync + node setup (Windows/VPS) |
| `.claude/skills/` | `remember`, `consolidate` |
| `docs/` | normative specs (sync contract) |

## Quickstart

Requires: git on every node; `jq` on Linux nodes; Claude Code with hooks + skills support.

1. **Get the template**: clone (or fork) this repo, then point it at a **private** repo you own — your memory must not live in a public one:

```
git clone https://github.com/shanewas/engram.git %USERPROFILE%\engram
gh repo create my-engram --private
```

2. **Wire the node** — Windows:

```
powershell -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\engram\scripts\bootstrap.ps1 -Remote https://github.com/<you>/my-engram.git
```

Linux / VPS (after the same clone to `~/engram`):

```
bash ~/engram/scripts/setup-vps.sh --remote <your-private-url>
```

3. Restart Claude Code. Every further machine: clone your **private** repo instead, run the same bootstrap/setup with no `-Remote`.

**Read-only node** (e.g. a corporate machine — never pushes):

```
scripts\bootstrap.ps1 -ReadOnly          # Windows
bash scripts/setup-vps.sh --read-only    # Linux
```

## Privacy model

This public repo is a template — the structure and sync machinery, not a shared data store. Your memory lives in **your own private repo instance**. Two hard rules are enforced by the machinery, not left to convention:

- **No secrets.** Every push is scanned for credential-shaped strings before committing; a hit unstages the change and raises `ALERT.md` instead of committing it.
- **No scope creep.** The sync commit allowlist is `index.md`, `projects/`, `global/`, `inbox/`, `archive/` — changes to `scripts/`, `docs/`, or `CLAUDE.md` never auto-commit.

## Health & troubleshooting

- `scripts\doctor.ps1` / `scripts/doctor.sh` — checks hooks are wired, skills are copied (not linked), the scheduled task/cron is registered, and the remote is reachable.
- `scripts/test-sync.sh` — contract compliance tests (`SYNC_IMPL=ps1` runs them against the PowerShell implementation).

## Runbook

- Manual sync now: `scripts\sync.ps1 push` (Windows) / `./scripts/sync.sh push` (Linux).
- `ALERT.md` present: read it (it names what failed and which `conflict/<host>` branch holds the commits), then run the `consolidate` skill to merge and delete the branch.
- Memory looks stale: `git -C ~/engram log --oneline -5` — a repeated unpushed commit or a live `conflict/<host>` branch on origin means an unresolved conflict; run `consolidate`.
- Restore an old memory state: `git log -- projects/x.md` → `git checkout <sha> -- projects/x.md`.
- New machine later: clone your private repo + run `bootstrap.ps1` / `setup-vps.sh`. Nothing else.

## Supported platforms

Linux + Windows (PowerShell 5.1+). macOS untested (`sync.sh` lock staleness uses GNU `date -d`; that is the single upgrade point).

## License

MIT — see [LICENSE](LICENSE).
