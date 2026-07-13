# Engram for non-Claude agents

Claude Code gets wired into this memory automatically (hooks, `@import`, skills). Any **other** agent on a machine — a chat assistant, a bot, a scheduled job — can join the same brain with three standing rules. Put this block (paths adjusted) into that agent's system prompt, workspace instructions, or auto-loaded memory:

```text
Shared cross-machine memory lives in the git repo at <ENGRAM_PATH>.
1. READ: at session start, read <ENGRAM_PATH>/index.md. It is a routing
   table — follow it to projects/<name>.md or global/*.md when you need
   context. Never load large folders wholesale.
2. WRITE: when a durable fact worth keeping surfaces (a decision,
   preference, gotcha, environment detail), append it to
   <ENGRAM_PATH>/inbox/YYYY-MM.md (current month) as a dated bullet:
   "- YYYY-MM-DD — fact". Atomic facts only — no session logs, no prose.
   Never write secrets, credentials, or other people's private material.
3. HANDS OFF: only write inside inbox/. Never modify scripts/, docs/,
   CLAUDE.md, .claude/, or the git configuration; never run git commands
   in this repo — sync is automatic (cron/scheduled task).
```

Why the inbox and nothing else: `inbox/**` uses git union merge, so an agent appending there can never create a conflict with any other machine, and the `consolidate` skill (run from Claude Code) later files those captures into the right project files. The agent gets full read access and safe write access without being able to break sync, leak scope, or fight another writer.

If the machine doesn't run Claude Code at all, sync still works: `scripts/setup-vps.sh` installs a 30-minute cron that pulls and pushes on its own (Windows: `bootstrap.ps1` registers the scheduled task).
