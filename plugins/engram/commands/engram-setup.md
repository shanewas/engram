---
description: Set up engram — clone your memory hub repo and wire it into Claude Code (run once per machine after installing the plugin)
argument-hint: <hub-git-url>
---

You are wiring engram on this machine. The plugin already provides the skills and
the SessionStart/SessionEnd sync hooks; this command sets up the memory repo they
operate on. The hub git URL is: `$ARGUMENTS`

Do the following, then report what you did in plain language. Stop and ask if any
step is ambiguous.

1. **Locate or clone the hub repo.** Target directory is `$ENGRAM_HOME` if that env
   var is set, otherwise `~/engram`.
   - If the target already contains a `.git`, leave it — just report the path.
   - Otherwise, if a hub URL was given in `$ARGUMENTS`, clone it there:
     `git clone <hub-url> <target>`
   - If no `.git` and no URL was given, stop and ask the user for their hub repo URL
     (or tell them to create one from the template at https://github.com/shanewas/engram).

2. **Load the memory index every session.** Idempotently add an import of the hub's
   `index.md` to `~/.claude/CLAUDE.md` (create the file if missing). Skip if a line
   containing `engram/index.md` is already present:
   ```
   printf '\n# Engram shared memory (added by engram setup)\n@%s/index.md\n' "<target>" >> ~/.claude/CLAUDE.md
   ```

3. **Remove any legacy script-installed hooks.** If the user previously ran
   `setup.sh`/`setup-vps.sh`, `~/.claude/settings.json` has its own engram
   SessionStart/SessionEnd hooks. The plugin now provides those, so strip the old ones
   to avoid syncing twice per session. Only touch engram hooks (commands containing
   `engram/scripts/sync.sh`); leave every other hook untouched. Requires `jq`:
   ```
   jq '(.hooks // {}) as $h
       | .hooks = ($h | to_entries
         | map(.value |= map(select(((.hooks // []) | map(.command // "")
             | any(contains("engram/scripts/sync.sh"))) | not)))
         | from_entries)' ~/.claude/settings.json > /tmp/engram-settings.json \
     && mv /tmp/engram-settings.json ~/.claude/settings.json
   ```
   If `jq` is missing or settings.json is absent, skip this step and note it.

4. **Optional CLI.** The hub repo ships `bin/engram`. If the user wants the terminal
   command, symlink it onto their PATH:
   `ln -sf "<target>/bin/engram" ~/.local/bin/engram` (ensure `~/.local/bin` is on PATH).

5. **Verify.** Run `bash "<target>/scripts/sync.sh" pull` once and confirm it exits
   cleanly, then report: the hub path, that the index import is in place, whether legacy
   hooks were removed, and that the plugin's session hooks will handle sync from now on.

Note: the plugin does NOT install the 30-minute background cron (plugins can't).
SessionEnd sync covers normal interactive use. For an always-on headless box that
needs the periodic push, run the hub's `bash <target>/scripts/setup-vps.sh` there —
it installs the cron (and can coexist; step 3's strip keeps the session hooks single).
