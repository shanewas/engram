---
name: consolidate
description: Consolidate the engram shared memory repo — resolve sync alerts and conflict branches, merge inbox captures into project files, dedupe, fix stale facts, compress old entries, archive dead projects, rebuild the index. Use when the user says "consolidate memory", "clean up memory", "memory maintenance", or on a weekly maintenance run.
---

# Consolidate

Goal: total always-loaded context stays small; every fact stays findable; the node's sync state is healthy. Repo: `~/engram` (Windows: `%USERPROFILE%\engram`).

Unlike `remember`, this skill **does** run git directly — sync hooks only ever touch the commit allowlist (`scripts/sync-paths.conf`; default `index.md projects/ global/ inbox/ archive/`), so resolving alerts, conflict branches, and stray files needs a human-equivalent hand on the repo.

1. Sync first: run `engram sync pull` (or `scripts/sync.sh pull` / `scripts\sync.ps1 pull`).
2. `ALERT.md` present at repo root? Read it — it names what failed and which `conflict/<host>` branch holds the commits. Resolve via step 3, then delete `ALERT.md`.
3. Conflict branches: `git fetch origin`. For each `origin/conflict/<host>` found (`git branch -r | grep conflict/`): merge its facts into the corresponding local files (newest dated fact wins — verify against actual code if the repo is reachable on this machine), commit on `main`, `git push`, then `git push origin --delete conflict/<host>`.
4. `git status --porcelain`: anything outside the allowlist that's untracked or modified never syncs automatically. Surface it in the report; if it's memory content, move it into `index.md`/`projects/`/`global/`/`inbox/`/`archive/` — until then it only exists on this machine.
5. Empty the inbox: move every entry in `inbox/*.md` into the right `projects/*.md` or `global/*.md`; delete emptied inbox files.
6. Per project file: dedupe; resolve contradictions (newest dated fact wins — verify against the actual code if the repo is reachable on this machine); compress entries older than ~90 days into a short summary block; enforce < 300 lines.
7. Archive: projects inactive > 6 months → move file to `archive/`, remove its index row, add one line to `archive/README.md`.
8. Rebuild the Projects table in `index.md`; enforce < 100 lines total.
9. Log the run: append `- YYYY-MM-DD <host>` to `archive/consolidate-log.md` (create if missing). Sync's pull-time "consolidate memory" nudge reads the last date in this file — skipping this step breaks the reminder for every machine.
10. Report in a few lines: alerts/conflict branches resolved, strays found, moved, merged, archived, contradictions found.
11. Push: `engram sync push` (or `scripts/sync.sh push` / `scripts\sync.ps1 push`). Run `engram doctor` to verify health.
