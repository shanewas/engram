# Engram — shared memory index

<!-- Loaded into every Claude Code session on every machine.
     Keep under 100 lines — treat any excess as a build failure; it costs context in every session, forever.
     May be one session stale (SessionStart pull can land after this file is imported); sync is automatic. -->

Persistent cross-machine memory lives in this repo (canonical path `~/engram`). This file is a **routing table, not a fact store** — it says what memory exists and where to read it. Syncs between your machines via git.

## Check first, every session

If `ALERT.md` exists at the repo root, or ALERT text appears anywhere in this session's context (the sync `pull` hook prints it on SessionStart): **stop, surface it to the user immediately, and resolve before other work.** It means this node failed to sync — a rebase conflicted or a push was rejected. Resolution: run the `consolidate` skill.

## Use it

- Before assuming anything about a project below, read its file under `projects/` — never answer from the one-liner alone.
- Learned a durable fact (function signature, API shape, decision, gotcha, env detail)? Use the `remember` skill, or append it directly to the right file and refresh its one-liner here.
- Unsure where a fact belongs → append to `inbox/YYYY-MM.md`.
- Never store secrets, credentials, or tokens here. No confidential third-party material without the user's explicit approval.

## Global

| File | Contents |
|---|---|
| global/preferences.md | how the user works — style, formats, biases |
| global/machines.md | the nodes — paths, egress, read/write status |

## Projects

| Project | File | One-liner |
|---|---|---|
| (none yet — copy `projects/_template.md` to add one) | | |

## Maintenance

Weekly `consolidate` skill run: resolve `ALERT.md`, merge/delete `conflict/<host>` branches, drain inbox into project files, dedupe, compress entries older than 90 days, archive dead projects, rebuild this index.
