# Zero-knowledge setup: paste this into Claude Code

Don't want to touch a terminal? Open Claude Code on the new machine and paste everything below the line. Claude runs the setup, verifies it, and reports back in plain language.

Before pasting, have ready: your private hub repo URL (`https://github.com/<you>/<repo>.git`) — or, if this is your very first machine, just say so when Claude asks and it will help create one.

---

Set up this machine as a node of my engram cross-machine memory system. Work step by step, verify each step, and stop and explain in plain language if anything fails — never improvise past a failure.

1. Ask me for my private engram hub repo URL (or, if I don't have one yet, help me create a private GitHub repo and use that). Confirm `git` is installed.

2. Clone the repo to the default location — `~/engram` on Linux/macOS, `%USERPROFILE%\engram` on Windows — unless I tell you a different path. If the target is inside a OneDrive/Dropbox/Google Drive-synced folder, warn me and suggest an alternative before continuing.

3. Ask me two questions: (a) should this machine be able to save new memories, or only read them? (b) should any top-level memory folders be skipped on this machine (kept on the hub but not stored here)?

4. Run the guided setup from the clone — `bash scripts/setup.sh` on Linux, `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup.ps1` on Windows — and answer its questions with what I told you. If a git login prompt appears, let me complete it; that is the one manual step.

5. Verify: run `scripts/doctor.sh --status` (Windows: `scripts\doctor.ps1 -Status`) and confirm the node is healthy and synced. If the full doctor reports failures, fix them and re-verify.

6. If this machine already has memory worth keeping (an existing `~/.claude/CLAUDE.md`, project CLAUDE.md files, or notes I point you at), offer to run the `migrate` skill to import it.

7. Report back: the hub URL, where the clone lives, this machine's role (read/write or read-only), any skipped folders, and the two phrases I need to remember — "remember this: …" to save a fact, and "consolidate memory" for weekly tidy-up.
