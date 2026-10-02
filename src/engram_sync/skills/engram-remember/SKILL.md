---
name: engram-remember
description: Save a durable fact to the engram shared memory repo. Use when the user says "remember this", "save to memory", "note this for later", or when a reusable fact worth keeping across machines (function signature, decision, gotcha, environment detail) comes up during work.
---

# Remember

Memory repo: `~/engram` (or `$ENGRAM_HOME`; the path is also named in the engram block of your global instructions).

1. Compress the fact to atomic, dated bullets: `- YYYY-MM-DD — fact`. Facts, not narrative.
2. Route it. Only synced paths count, so the fact must land in one of them:
   - Known project → append under the right heading in `projects/<slug>.md`, update its `Updated:` date.
   - New project → copy `projects/_template.md` to `projects/<slug>.md`, fill what you know, add a row to the Projects table in `index.md`.
   - Cross-project preference or convention → `global/preferences.md` (or a new `global/<topic>.md`).
   - Machine or environment fact → `global/machines.md`.
   - Unclear → append to `inbox/YYYY-MM.md` (create it for the current month if missing).
3. If the project's one-liner in `index.md` changed materially, refresh it. Keep `index.md` under 100 lines.
4. Secret or credential (API key, token, password) → refuse. Say why. Don't save a redacted copy either.
5. Looks like confidential third-party material → stop and ask before saving.
6. Don't run git. Session-end and the 30-minute background sync commit and push. To sync right away, run `engram sync push`.
7. Confirm in one line what was saved and where.
