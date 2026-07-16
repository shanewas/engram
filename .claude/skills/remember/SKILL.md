---
name: remember
description: Save a durable fact to the engram shared memory repo. Use when the user says "remember this", "save to memory", "note this for later", or when a reusable fact worth persisting across machines (function signature, decision, gotcha, environment detail) surfaces during work.
---

# Remember

Persist a fact into the engram memory repo. Canonical location: `~/engram` (Windows: `%USERPROFILE%\engram`). If not there, check the path given in the engram index already in your context.

1. Identify the fact. Compress to atomic, dated bullets: `- YYYY-MM-DD — fact`. Facts, not narrative.
2. Route it — only these paths sync, nothing else, so the fact must land in one of them:
   - Belongs to a known project → append under the right heading in `projects/<slug>.md`, update its `Updated:` date.
   - New project → copy `projects/_template.md` to `projects/<slug>.md`, fill what you know, add a row to the Projects table in `index.md`.
   - Cross-project preference or convention → `global/preferences.md` or `global/conventions.md` (create if missing).
   - Machine/environment fact → `global/machines.md`.
   - Unclear → append to `inbox/YYYY-MM.md` (create from current month if missing).
3. If the project's one-liner in `index.md` changed materially, refresh it.
4. Secret or credential (API key, token, password) → refuse. Say why, don't save it anywhere, don't "redact and save" either.
5. Looks like office client-confidential material → stop and ask before saving.
6. Never run git commands — SessionEnd/scheduled hooks handle commit and push. Writing outside `index.md`, `projects/`, `global/`, `inbox/`, `archive/` (e.g. `scripts/`, `docs/`, `.claude/`, `CLAUDE.md`, `PLAN.md`) won't sync automatically — those need a deliberate manual commit, so don't route memory there.
7. Live mirror (optional — only if you run a memory MCP server and its connector is available in this session): after the git write, also `vault_retain` the same atomic fact so non-filesystem clients (phone, web chat) can read it live.
   - Mirror only to the write-bank your MCP server actually allows (its write allowlist). Other bank names are refused server-side.
   - Never mirror anything step 4 or 5 flagged (secrets, client-confidential). Those stay git-only — git already syncs them privately across your nodes, whereas an MCP endpoint may be internet-reachable.
   - The git file is canonical; the mirror is best-effort. If the mirror call fails, the fact is still saved — don't error, just note it.
8. Confirm to the user in one line: what was saved, where (and whether it was mirrored).
