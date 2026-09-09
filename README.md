# Engram

Cross-machine memory for Claude Code, Antigravity (agy), OpenCode, Muse, and other coding agents. Facts live as plain markdown in a private git repo you own; sync scripts move them between your machines automatically.

## How it works

- **The git repo is the store and the audit log.** Every fact is a commit: attributed, timestamped, revertible with `git revert`. There is no database and no service; if you stop using Engram, you keep readable markdown files.
- **`index.md` is loaded into your agent sessions** (via `@import` in `~/.claude/CLAUDE.md`, rules in `~/.gemini/rules/engram.md`, or agent instructions). It is a routing table, kept under 100 lines: it tells the agent what memory exists and where. Detail files (`projects/<name>.md`, `global/*.md`) are read lazily during the session.
- **Sync is automatic.** A SessionStart hook pulls, a SessionEnd hook pushes, and a 30-minute cron/scheduled task pushes as the durability backstop. Sync never blocks a session and never prompts for credentials (see [`docs/sync-contract.md`](docs/sync-contract.md)).
- **An allowlist bounds what syncs.** Only paths listed in `scripts/sync-paths.conf` (default: `index.md`, `projects/`, `global/`, `inbox/`, `archive/`) are ever auto-committed. Scripts, docs, and config require a deliberate manual commit.
- **Skills do the writing.** `remember` routes a fact to the right file, `consolidate` does weekly maintenance, `migrate` imports pre-existing CLAUDE.md memory. They live in [`plugins/engram/skills/`](plugins/engram/skills/) and are copied to `~/.claude/skills` and `~/.gemini/config/skills` on setup and on every pull.

## Requirements

- git on every machine
- Python 3.8+ (for cross-platform CLI and dotfiles engine)
- `jq` on Linux (`sudo apt install -y jq`)
- A private GitHub repo (or any git remote) as the hub
- Non-interactive `git push` (SSH key or cached token). Engram never opens a login prompt; if auth fails it records the error and retries later.

## Install

Your memories live in a private repo, not in this one. First machine: clone this template, push it to your private hub. Every other machine: clone the private hub.

**One line on Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/<you>/my-engram/main/scripts/install.ps1 | iex
```

**One line on Linux/macOS/WSL (Bash):**

```bash
curl -fsSL https://raw.githubusercontent.com/<you>/my-engram/main/scripts/install.sh | bash -s -- git@github.com:<you>/my-engram.git
```

The installer clones the repository, adds `bin/` to your PATH, scaffolds `~/.config/dotfiles/secrets.env`, auto-detects installed coding agents, connects them, and runs `engram doctor`.

**Manual / from an existing clone:**

```bash
bash scripts/setup.sh                                              # Linux
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup.ps1       # Windows
```

**Headless (servers, CI):**

```bash
bash scripts/setup-vps.sh --remote git@github.com:<you>/my-engram.git [--read-only] [--no-cron]
```

## The `engram` CLI

The `engram` CLI runs natively on Windows (`bin\engram.cmd`, `bin\engram.ps1`), Linux, and macOS (`bin/engram`):

| Command | Description |
|---|---|
| `engram status` | Branch, unpushed/behind counts, uncommitted files, alerts, and connected harnesses |
| `engram sync` / `pull` / `push` | Sync memory now (never blocks; conflicts park on a branch) |
| `engram connect <name\|--all>` | Wire memory, skills, and MCP to an agent (`claude`, `antigravity`, `opencode`, `muse`, `hermes`) |
| `engram disconnect <name>` | Unwire memory from an agent harness |
| `engram harnesses` | List supported and detected agent harnesses on this machine |
| `engram skills list` / `sync` | List available skills or deploy them to all connected harnesses |
| `engram mcp list` / `sync` | List central MCP servers or compile configs for each harness |
| `engram paths` | What syncs, and what is tracked but deliberately not auto-synced |
| `engram include <path>` / `exclude <path>` | Edit the allowlist (then commit `sync-paths.conf`) |
| `engram audit [N]` | Last N memory changes (hash, timestamp, message), each diffable via `git show` |
| `engram remember <text>` | Quick-capture a dated bullet into `inbox/YYYY-MM.md` |
| `engram hermes [digest]` | Digest VPS Hermes session logs into local Obsidian inbox |
| `engram dotfiles apply` / `save` | Sync harness config (settings, hooks, rules, plugin lists) next to memory |
| `engram doctor [--status]` | Complete system health check |
| `engram restore` | Show the disaster-recovery runbook (`restore/RESTORE-memory.md`) |

## Agent Harnesses

Engram can connect to multiple coding agents on the same computer:

1. **Claude Code**: Wires `@<engram>/index.md` into `~/.claude/CLAUDE.md`, copies skills to `~/.claude/skills`, injects MCP servers into `~/.claude.json`.
2. **Antigravity (agy)**: Wires memory rules into `~/.gemini/rules/engram.md`, copies skills to `~/.gemini/config/skills`, injects MCP servers into `~/.gemini/config/mcp_config.json`.
3. **OpenCode**: Wires instructions into `~/.config/opencode/instructions.md`, copies skills to `~/.config/opencode/skills`, configures `opencode.jsonc`.
4. **Muse**: Wires memory into `~/.muse/instructions.md`, copies skills to `~/.muse/skills`.
5. **Hermes Bridge**: Links VPS memory sessions from `vault/<bank>/sessions/` into local Obsidian digests.

Run `engram connect --all` to automatically configure every detected agent on a new machine.

## Data safety and failure modes

- **Secret scan before every push.** Staged additions are scanned for AWS/GitHub/Slack/OpenAI/Anthropic/Google key patterns, private keys, JWTs, and generic `password=`/`token=` shapes. A hit unstages everything, writes `ALERT.md`, and refuses to commit. False positives are bypassed only by marking the exact line with `engram:not-a-secret` (patterns and rules in [`docs/sync-contract.md`](docs/sync-contract.md) §7).
- **Conflicts never lose data.** If a rebase conflicts or a push is rejected, the node force-pushes its commits to a per-host `conflict/<host>` branch on the hub, writes a local `ALERT.md`, and the next session surfaces it. "consolidate memory" merges the branch and deletes it.
- **History is git.** Recover any old version with `git log -- projects/x.md` then `git checkout <sha> -- projects/x.md`. Losing a machine loses at most one sync interval (~30 min) of unpushed writes; see [`restore/README.md`](restore/README.md).
- **Sync never blocks or prompts.** Every remote operation runs with terminal prompts and credential dialogs disabled and a low-speed timeout; sync scripts always exit 0.
