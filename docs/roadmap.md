# Roadmap: easier use, non-technical-friendly

Bar: *one command per machine, plain words, never needs to know what git is.* Every item traces to real friction from the first live rollout (2026-07). The envelope is fixed: markdown + git + cron, no GUI, no daemon, no database — improvements wrap the machinery in questions and plain language, they don't replace it.

## Tier 1 — quick wins

| # | Item | Status |
|---|---|---|
| 1 | Interactive setup wizard (`scripts/setup.sh` / `setup.ps1`): asks hub / role / skip-folders in plain words, creates the private repo via `gh` when possible, wraps the existing setup scripts | ✅ done |
| 2 | Refuse to run half-connected: sync prints a NOT CONNECTED warning into the session when no `origin` exists; doctor fails loudly on no-remote and on a never-pushed hub | ✅ done |
| 3 | Setup auto-registers the machine in `global/machines.md` (host, OS, path, role, skips) | ✅ done (in wizard) |
| 4 | OneDrive/Dropbox/Google Drive detection at setup, with a plain warning | ✅ done (in wizard) |
| 5 | Plain-language `ALERT.md`: every alert opens with "nothing is lost + how to fix it" before the technical detail | ✅ done |

## Tier 2 — structural

| # | Item | Status |
|---|---|---|
| 6 | Data-driven allowlist: `scripts/sync-paths.conf` read by both sync scripts; one edit instead of three files in lockstep | ✅ done |
| 7 | Secret-scan false-positive escape hatch: `engram:not-a-secret` line marker, named in the alert — the sanctioned path instead of bypass culture | ✅ done |
| 8 | Sync profiles: "skip folders on this machine?" as a setup question (sparse checkout under the hood) | ✅ done (in wizard) |
| 9 | `migrate` skill: import a machine's existing CLAUDE.md / notes memory | ✅ done |
| 10 | `AGENTS.md`: canonical integration snippet for non-Claude agents (read index, write inbox only) | ✅ done |

## Tier 3 — the non-technical leap

| # | Item | Status |
|---|---|---|
| 11 | Status in human words: `doctor.sh --status` / `doctor.ps1 -Status` — healthy/not, last sync age, machines seen | ✅ done |
| 12 | Claude-driven install: `SETUP-PROMPT.md` — paste into Claude Code on a new machine, zero terminal knowledge needed | ✅ done |
| 13 | Maintenance nudge: successful pull reminds "consolidate memory" when `archive/consolidate-log.md`'s last entry is ≥ 7 days old | ✅ done |

## Tier 4 — no babysitting

Every item removes a point where a human had to notice something and act.

| # | Item | Status |
|---|---|---|
| 14 | Union merge on every memory path (`index.md`, `projects/`, `global/`, `archive/`, not just `inbox/`): same-line edits on two machines keep both lines instead of blocking the node behind an `ALERT.md`; only modify/delete still escalates | ✅ done |
| 15 | Drain on pull: a SessionEnd push that committed but died before the network push is finished by the next SessionStart pull | ✅ done |
| 16 | Offline is not silent: a failed pull/push prints one `[engram] memory did not sync (offline?)` line into the session, so the model knows memory may be stale | ✅ done |
| 17 | `engram sync` actually pushes (it only pulled), `engram doctor --status` works, `engram include/exclude` keep the conf's comments, `engram restore` finds the runbook, `bin/engram` is a launcher only (the bash verbs had drifted) | ✅ done |
| 18 | macOS: no GNU `date -d`, no `setsid` — both handled | ✅ done |
| 19 | `engram init <hub-url>`: one idempotent command replacing the five setup/bootstrap scripts (clone, connect --all, hooks, cron/task, machines.md) | open |
| 20 | `engram doctor --fix`: every WARN/FAIL with a mechanical remedy (hooks, cron, skills, import line) applies it | open |
| 21 | Scheduled consolidate: weekly `claude -p "consolidate memory"` from cron/task, so the dedupe/archive pass needs nobody | open |

## Deliberately not doing

GUI app, background daemon, database, web service. The durability story is "plain markdown + git, cron is the only moving part" — everything above stays inside that envelope.

## Open / next

- `doctor --status` as a rendered HTML page (optional, low priority).
- PowerShell test parity for every tier-4 behaviour must be verified on a Windows node: `SYNC_IMPL=ps1 scripts/test-sync.sh` (tests 5b, 10, 16a/b are new).
