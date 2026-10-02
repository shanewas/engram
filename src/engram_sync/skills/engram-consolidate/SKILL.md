---
name: engram-consolidate
description: Consolidate the engram memory repo — resolve sync alerts and conflict branches, merge inbox captures into project files, dedupe, compress old entries, archive dead projects, rebuild the index. Use when the user says "consolidate memory", "clean up memory", "memory maintenance", when an engram ALERT names a conflict branch, or when sync prints the weekly consolidation reminder.
---

# Consolidate

Goal: always-loaded context stays small, every fact stays findable, this machine syncs cleanly. Repo: `~/engram` (or `$ENGRAM_HOME`).

Unlike `engram-remember`, this skill runs git directly. Sync only ever commits the allowlist in `.engram/sync-paths.conf`, so alerts, conflict branches and stray files need a hand on the repo.

1. `engram sync pull`.
2. `ALERT.md` at the repo root? Read it. It names what failed and which `conflict/<host>` branch holds the commits. Resolve via step 3, then delete `ALERT.md`.
3. `git fetch origin`. For each `origin/conflict/<host>`: merge its facts into the matching files on `main` (newest dated fact wins), commit, `git push`, then `git push origin --delete conflict/<host>`.
4. `git status --porcelain`: anything untracked or modified outside the allowlist never syncs. Report it; if it is memory content, move it into `index.md` / `projects/` / `global/` / `inbox/` / `archive/`.
5. Empty the inbox: move every entry in `inbox/*.md` into the right `projects/*.md` or `global/*.md`, then delete the emptied inbox files.
6. Per project file: dedupe (memory paths union-merge, so concurrent edits on two machines leave both versions of a line), keep the newest, resolve contradictions (newest dated fact wins; check the code if it is reachable), compress entries older than ~90 days into a short summary, keep each file under 300 lines. Dedupe `global/*.md` and `index.md` the same way.
7. Projects inactive more than 6 months: move the file to `archive/`, remove its index row, add one line to `archive/README.md`.
8. Rebuild the Projects table in `index.md`; keep it under 100 lines.
9. Append `- YYYY-MM-DD <host>` to `archive/consolidate-log.md` (create if missing). Sync's weekly reminder reads the last date here.
10. Report in a few lines: alerts and conflict branches resolved, strays found, entries moved or merged, projects archived, contradictions found.
11. `engram sync push`, then `engram doctor`.
