# Engram

**Give Claude Code a memory that follows you everywhere.**

Tell Claude something once on your desktop — a decision, a gotcha, how you like things done — and it already knows it the next time you open Claude Code on your laptop, office PC, or server. No copy-pasting notes between machines, no re-explaining your projects every session.

Everything is stored as plain markdown files in a private GitHub repo **you own**. No database, no cloud service, no subscription. If you ever stop using Engram, your notes are still just readable text files.

## How it works

Think of it as one shared notebook that all your computers keep in sync:

1. **Your private GitHub repo is the central copy.** Every computer keeps its own local copy and syncs with it automatically.
2. **One small file, `index.md`, is loaded into every Claude Code session.** It's a table of contents: it tells Claude what memory exists and where. Claude opens the detailed files (one per project, plus your preferences) only when it actually needs them — so your memory can grow without slowing sessions down.
3. **Syncing happens by itself.** Your computer pulls the latest memory when a session starts, pushes your new memories when it ends, and a background task runs every 30 minutes as a backup. You never have to think about it.
4. **Two built-in skills do the writing.** Say *"remember this"* and Claude saves the fact to the right file. Once a week, say *"consolidate memory"* and Claude tidies everything up — merges quick notes, removes duplicates, archives dead projects.

And if something goes wrong — say two computers edit the same line at the same time — nothing is ever lost. The stuck changes are parked safely on the central repo, a warning file appears, and the next session tells you about it so Claude can fix it.

## What you need

- A [GitHub](https://github.com) account (a free one is fine)
- `git` installed on every computer
- `jq` installed on Linux computers (`sudo apt install -y jq`)
- Claude Code (for the automatic loading and skills — a computer without it can still sync, see below)

## Setup

### Step 1 — Create your own private repo (once)

This repo you're reading is only a **template**. Your actual memories must live in a separate, **private** repo that only you can see:

```
gh repo create my-engram --private
```

(Or click "New repository" on GitHub and tick **Private**.)

### Step 2 — Set up your first computer

Clone the template, then run the setup script pointing at your private repo:

**Windows:**

```
git clone https://github.com/shanewas/engram.git %USERPROFILE%\engram
powershell -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\engram\scripts\bootstrap.ps1 -Remote https://github.com/<you>/my-engram.git
```

**Linux / server:**

```
git clone https://github.com/shanewas/engram.git ~/engram
bash ~/engram/scripts/setup-vps.sh --remote https://github.com/<you>/my-engram.git
```

The script connects your local copy to your private repo, hooks up the automatic syncing, installs the skills, and sets up the 30-minute background sync. Restart Claude Code and you're done.

> **Tip:** make sure `git push` to your private repo works without asking for a password (use an SSH key, or let git remember your token). Engram never pops up a login prompt — if it can't log in, it just waits and warns you instead.

### Step 3 — Every other computer

**All your computers share the same private repo** — that's the whole point. On each additional machine, clone *your private repo* (not this template) and run the same setup with no remote argument:

**Windows:**

```
git clone https://github.com/<you>/my-engram.git %USERPROFILE%\engram
powershell -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\engram\scripts\bootstrap.ps1
```

**Linux / server:**

```
git clone https://github.com/<you>/my-engram.git ~/engram
bash ~/engram/scripts/setup-vps.sh
```

That's it. Adding a new machine later is the same two commands.

### Optional: read-only computers

For a machine that should *read* your memory but never *write* to it (a work computer, for example):

```
scripts\bootstrap.ps1 -ReadOnly          # Windows
bash scripts/setup-vps.sh --read-only    # Linux
```

### Optional: computers without Claude Code

A machine running some other AI tool can still join. The setup script's 30-minute background sync works on its own, and the memory is just markdown — point your other tool at `~/engram/index.md` and let it add quick notes to `inbox/`. Claude will file them properly at the next tidy-up.

## Everyday use

You mostly don't do anything — Claude reads and writes memory on its own. The two phrases worth knowing:

| Say this | What happens |
|---|---|
| *"remember this"* | Claude saves the fact to the right memory file |
| *"consolidate memory"* (weekly) | Claude tidies up: merges notes, removes duplicates, fixes stale facts, archives dead projects |

Want to sync by hand right now? `scripts\sync.ps1 push` (Windows) or `./scripts/sync.sh push` (Linux).

## Where things live

| Folder / file | What's in it |
|---|---|
| `index.md` | The table of contents — loaded into every session |
| `projects/` | One file per project |
| `global/` | Your preferences and facts about your machines |
| `inbox/` | Quick captures, filed properly at the next tidy-up |
| `archive/` | Old projects and compressed history |
| `scripts/` | Setup and sync scripts |
| `.claude/skills/` | The `remember` and `consolidate` skills |

## Is my data safe?

- **It's your repo.** Memories live in a private repo on your own GitHub account. Nothing is shared with anyone, including this template's author.
- **Passwords and keys are blocked.** Before every sync, Engram scans your changes for anything that looks like a password, API key, or token. If it finds one, it refuses to upload and warns you instead.
- **Only memory files sync automatically.** Scripts and settings never upload on their own — changing those always takes a deliberate manual step.
- **Nothing is ever silently lost.** History is kept forever (it's git underneath), and sync problems are parked safely and flagged instead of dropped.

## When something looks wrong

- **Health check:** run `scripts\doctor.ps1` (Windows) or `scripts/doctor.sh` (Linux). It verifies everything is wired up and can reach GitHub.
- **A file called `ALERT.md` appeared:** a sync hit a snag. Open it — it says what happened — then tell Claude to *"consolidate memory"* and it will sort it out. Your changes are safe on the central repo the whole time.
- **Memory seems out of date:** run the health check, or just sync by hand (see above).
- **Want an old version of a memory back?** It's git, so every version is kept:
  `git log -- projects/x.md` then `git checkout <sha> -- projects/x.md`

## Supported platforms

Windows (PowerShell 5.1+) and Linux. macOS is untested for now.

## For contributors

The exact sync behaviour both scripts must follow is specified in [`docs/sync-contract.md`](docs/sync-contract.md) — read it before touching sync code, and run `scripts/test-sync.sh` (plus `SYNC_IMPL=ps1 scripts/test-sync.sh`) after.

## License

MIT — see [LICENSE](LICENSE).
