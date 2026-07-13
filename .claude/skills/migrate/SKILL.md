---
name: migrate
description: Import this machine's existing memory into the engram shared memory repo — user-level CLAUDE.md, per-project CLAUDE.md learned facts, and note folders the user points at. Use when the user says "migrate my memory", "import my notes into engram", "move my CLAUDE.md into memory", or right after setting up engram on a machine that already has history.
---

# Migrate

One-time (per machine) import of pre-engram memory into the shared repo. Repo: `~/engram` (Windows: `%USERPROFILE%\engram`); if not there, use the path in the engram index already in your context.

Run this on the machine that holds the memory — you cannot migrate another machine's files remotely. Each machine with history gets its own run; sync dedupes nothing, so consolidate afterwards.

## Sources to sweep

1. `~/.claude/CLAUDE.md` (user-level).
2. Each project the user works on here: its `CLAUDE.md` and `.claude/` memory files. Ask the user for their usual projects folder if unknown.
3. Any note folders the user names (e.g. an Obsidian vault) — only sweep what they explicitly point at.

## Routing rules

For each fact found, decide what it is, then place it:

- **Personal preference / working style / convention** → `global/preferences.md`.
- **Machine or environment fact** → `global/machines.md`, under this machine's section.
- **Project fact** (decision, gotcha, API shape, signature) → `projects/<slug>.md`; copy `projects/_template.md` for a new project and add its row to the `index.md` table.
- **Unsure** → append to `inbox/YYYY-MM.md` as `- YYYY-MM-DD — fact`; consolidate will file it.

Convert to atomic, dated bullets (`- YYYY-MM-DD — fact`). Compress prose; drop narrative.

## What stays behind

- **Repo-specific build/run instructions stay in that project's own CLAUDE.md** — engram gets learned facts, not how-to-compile docs. When a CLAUDE.md mixes both, split it: copy the facts out, leave the instructions in place.
- **Secrets, credentials, tokens: never migrate** — not even redacted. Skip and tell the user what was skipped and where it lives.
- **Employer/client-confidential material: ask before migrating.**

## Finish

1. Refresh affected one-liners in `index.md`.
2. Do NOT run git — sync hooks handle commit/push.
3. Report in a few lines: sources swept, facts moved (per destination), skipped items and why.
4. Suggest running `consolidate` after every machine has migrated, to dedupe across them.
