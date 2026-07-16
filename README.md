# Engram

Cross-machine memory for Claude Code and other coding agents. Facts live as plain markdown in a private git repo you own; sync scripts move them between your machines automatically.

## How it works

- **The git repo is the store and the audit log.** Every fact is a commit — attributed, timestamped, revertible with `git revert`. There is no database and no service; if you stop using Engram, you keep readable markdown files.
- **`index.md` is loaded into every Claude Code session** (via `@import` in `~/.claude/CLAUDE.md`). It is a routing table, kept under 100 lines: it tells Claude what memory exists and where. Detail files (`projects/<name>.md`, `global/*.md`) are read lazily during the session.
- **Sync is automatic.** A SessionStart hook pulls, a SessionEnd hook pushes, and a 30-minute cron/scheduled task pushes as the durability backstop. Sync never blocks a session and never prompts for credentials (see [`docs/sync-contract.md`](docs/sync-contract.md)).
- **An allowlist bounds what syncs.** Only paths listed in `scripts/sync-paths.conf` (default: `index.md`, `projects/`, `global/`, `inbox/`, `archive/`) are ever auto-committed. Scripts, docs, and config require a deliberate manual commit.
- **Skills do the writing.** `remember` routes a fact to the right file, `consolidate` does weekly maintenance, `migrate` imports pre-existing CLAUDE.md memory. They live in [`plugins/engram/skills/`](plugins/engram/skills/) and are copied to `~/.claude/skills` on setup and on every pull (or loaded directly when installed as a plugin).

## Requirements

- git on every machine
- `jq` on Linux (`sudo apt install -y jq`)
- A private GitHub repo (or any git remote) as the hub
- Claude Code, for the session hooks and skills. A machine without it can still sync — see [Non-Claude agents](#non-claude-agents).
- Non-interactive `git push` (SSH key or cached token). Engram never opens a login prompt; if auth fails it records the error and retries later.

## Install

Your memories live in a private repo, not in this one. First machine: clone this template, push it to your private hub. Every other machine: clone the private hub.

> Upgrading an existing hub from before the plugin: the skills moved from `.claude/skills/` to `plugins/engram/skills/`. A normal template pull brings both, so sync keeps working — just don't cherry-pick only `scripts/`.

**As a Claude Code plugin (skills + sync hooks):**

```
/plugin marketplace add shanewas/engram
/plugin install engram@engram-tools
/engram-setup git@github.com:<you>/my-engram.git
```

The plugin ships the skills and the SessionStart/SessionEnd sync hooks; `/engram-setup` clones your hub repo, wires `index.md` into your session, and removes any hooks a prior script install left behind. It does not install the 30-minute background cron — for an always-on headless box, also run the script setup below. The rest of this section is the script-based install, which does the same wiring without the plugin.

**One line (Linux/macOS):**

```
curl -fsSL https://raw.githubusercontent.com/<you>/my-engram/main/scripts/bootstrap.sh | bash -s -- git@github.com:<you>/my-engram.git
```

The raw-curl form only works if your hub repo is public. Most hubs are private — clone first, then run bootstrap from inside:

```
git clone git@github.com:<you>/my-engram.git ~/engram
bash ~/engram/scripts/bootstrap.sh
```

Bootstrap clones (if needed), runs setup, and symlinks `engram` onto your PATH.

**Manual / interactive:**

```
bash ~/engram/scripts/setup.sh                                              # Linux
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup.ps1       # Windows (clone to %USERPROFILE%\engram)
```

Setup asks three questions (hub URL, read-write or read-only, folders to skip), then wires the hooks, skills, and the 30-minute sync. Restart Claude Code afterward.

**Headless (servers, CI):**

```
bash scripts/setup-vps.sh --remote git@github.com:<you>/my-engram.git [--read-only] [--no-cron]
```

**No terminal at all:** paste [`SETUP-PROMPT.md`](SETUP-PROMPT.md) into Claude Code on the new machine and let it run the setup.

## Usage

Two phrases inside Claude Code:

| Say | Effect |
|---|---|
| "remember this: ..." | the `remember` skill routes the fact to the right memory file |
| "consolidate memory" (weekly) | the `consolidate` skill drains the inbox, dedupes, resolves alerts and conflict branches, rebuilds the index |

From the terminal (`bin/engram`, Linux/macOS only):

| Command | What it does |
|---|---|
| `engram status` | branch, unpushed/behind counts, uncommitted files, alerts |
| `engram sync` / `pull` / `push` | sync now (never blocks; conflicts park on a branch) |
| `engram paths` | what syncs, and what is tracked but deliberately not auto-synced |
| `engram include <path>` / `exclude <path>` | edit the allowlist (then commit `sync-paths.conf`) |
| `engram audit [N]` | last N memory changes — hash, timestamp, message — each diffable via `git show` |
| `engram remember <text>` | quick-capture a dated bullet into `inbox/YYYY-MM.md` |
| `engram doctor [--status]` | health check; `--status` is a plain-language summary |
| `engram setup` / `restore` | interactive setup; show the disaster-recovery runbook |

Windows equivalents: `scripts\sync.ps1`, `scripts\doctor.ps1` — there is no `engram` CLI on Windows.

## Configuration

- **`scripts/sync-paths.conf`** is the sync allowlist: one path per line, `#` comments. Nothing outside it is ever auto-committed. The file itself is treated as code — changing it requires a manual commit, so the rules are versioned like everything else.
- **Read-only nodes:** setup with `--read-only` (or answer "read only" in the wizard) creates `.git/engram-readonly`; `push` degrades to `pull` on that machine.
- **Repo location:** `~/engram` by default, overridable with `ENGRAM_HOME`. Avoid OneDrive/Dropbox-synced folders.

## Data safety and failure modes

- **Secret scan before every push.** Staged additions are scanned for AWS/GitHub/Slack/OpenAI/Anthropic/Google key patterns, private keys, JWTs, and generic `password=`/`token=` shapes. A hit unstages everything, writes `ALERT.md`, and refuses to commit. False positives are bypassed only by marking the exact line with `engram:not-a-secret` (patterns and rules in [`docs/sync-contract.md`](docs/sync-contract.md) §7).
- **Conflicts never lose data.** If a rebase conflicts or a push is rejected, the node force-pushes its commits to a per-host `conflict/<host>` branch on the hub, writes a local `ALERT.md`, and the next session surfaces it. "consolidate memory" merges the branch and deletes it.
- **History is git.** Recover any old version with `git log -- projects/x.md` then `git checkout <sha> -- projects/x.md`. Losing a machine loses at most one sync interval (~30 min) of unpushed writes — see [`restore/README.md`](restore/README.md).
- **Sync never blocks or prompts.** Every remote operation runs with terminal prompts and credential dialogs disabled and a low-speed timeout; sync scripts always exit 0.

## Non-Claude agents

Any other agent on a machine can join with three standing rules — read `index.md` at session start, append dated bullets to `inbox/`, touch nothing else. `inbox/` uses git union merge, so appends never conflict. The prompt block to paste is in [`AGENTS.md`](AGENTS.md). Machines without Claude Code still sync via the 30-minute cron installed by `setup-vps.sh` (Windows: scheduled task via `bootstrap.ps1`).

## Platform support

- **Linux** — full support (`sync.sh`, `setup.sh`, `setup-vps.sh`, `doctor.sh`, `engram` CLI).
- **Windows** — full support via PowerShell 5.1+ (`sync.ps1`, `setup.ps1`, `bootstrap.ps1`, `doctor.ps1`); no `engram` CLI.
- **macOS** — the bash scripts and CLI should work but are untested.

## Contributing

`sync.sh` and `sync.ps1` must behave identically; the normative spec is [`docs/sync-contract.md`](docs/sync-contract.md). Read it before touching sync code, then run the contract tests against both:

```
bash scripts/test-sync.sh                 # tests sync.sh
SYNC_IMPL=ps1 bash scripts/test-sync.sh   # tests sync.ps1 (needs Git Bash + powershell.exe)
```

## License

MIT — see [LICENSE](LICENSE).
