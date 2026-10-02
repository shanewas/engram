# engram-sync

Shared memory for AI coding agents across all your machines. Facts live as markdown in a private git repo you own. Claude Code, Codex, OpenCode, Antigravity and Muse all read the same memory, and every machine pulls and pushes it automatically.

```
pip install engram-sync
engram init yourname/agent-memory
```

`init` takes a GitHub `owner/name` or any git URL. Create the repo first as an empty **private** repo. On the first machine `init` seeds it. On every other machine `init` clones it. Then `init`:

1. connects every agent it finds on this machine (details below);
2. schedules a background push every 30 minutes (Windows Task Scheduler, or cron on Linux/macOS);
3. runs the first sync.

Run `engram doctor` to check everything is wired up.

## What lands in each agent

| Agent | Skills copied to | Instructions added to | Session hooks |
|---|---|---|---|
| Claude Code | `~/.claude/skills` | `~/.claude/CLAUDE.md` (with an `@import` of `index.md`) | pull on start, push on end |
| Codex | `$CODEX_HOME/skills` (`~/.codex/skills`) | `~/.codex/AGENTS.md` | background sync |
| OpenCode | `~/.config/opencode/skills` | `~/.config/opencode/AGENTS.md`, only if you already have one (otherwise OpenCode reads `~/.claude/CLAUDE.md`) | background sync |
| Antigravity | `~/.gemini/config/skills` | `~/.gemini/rules/engram.md` | background sync |
| Muse | `~/.config/muse/skills` | reads `~/.claude/CLAUDE.md` | background sync |

Three skills ship with the package: `engram` (operate sync), `engram-remember` (save a fact to the right file) and `engram-consolidate` (weekly cleanup, conflict repair). Put your own skills in `skills/<name>/SKILL.md` inside the memory repo and every connected agent on every machine gets them on the next pull.

Instructions go between `<!-- engram-sync:begin -->` and `<!-- engram-sync:end -->` markers. Your own text around the markers is never touched. A skill folder you created yourself is never overwritten, even if it has the same name as one of engram's. `engram disconnect` removes exactly what `connect` added.

## Commands

| Command | Does |
|---|---|
| `engram init <repo>` | clone or seed the memory repo, connect agents, schedule sync |
| `engram sync pull` / `push` | sync now; always exits 0 so it can never break an agent session |
| `engram connect [agent …]` | connect all detected agents, or the named ones (`claude codex opencode antigravity muse`) |
| `engram disconnect [agent …]` | undo `connect` |
| `engram schedule on` / `off` | the 30-minute background push |
| `engram doctor` | health check: repo, remote, last sync, schedule, agents |

The memory repo defaults to `~/engram`. Use `--repo <path>` or `$ENGRAM_HOME` to put it elsewhere.

## Memory repo layout

```
index.md          routing table, loaded into every session (keep under 100 lines)
projects/<x>.md   one file per project, read on demand
global/           preferences and machine facts
inbox/YYYY-MM.md  quick captures, merged out by engram-consolidate
archive/          dormant projects and the consolidate log
skills/           optional: your own skills, shared to every agent
.engram/sync-paths.conf   what syncs automatically
```

## Safety

- Sync commits only the paths in `.engram/sync-paths.conf`. Anything else in the repo needs a manual commit.
- Each push scans added lines for AWS, GitHub, Slack, OpenAI, Anthropic and Google keys, private keys, JWTs and `password=`-style strings. On a match nothing is committed and `ALERT.md` explains the fix. Mark a known false positive with `<!-- engram:not-a-secret -->` on that line.
- When two machines can't merge (one deleted a file the other edited), the losing machine force-pushes its commits to `conflict/<host>` on your remote and writes `ALERT.md`. The next session sees the alert. Saying "consolidate memory" merges the branch back. No commit is ever left only on one machine.
- Git never prompts. Every remote call runs with prompts and credential dialogs disabled and with stall timeouts, so a session never hangs on a password box.

Full rules: [docs/sync-contract.md](docs/sync-contract.md).

## Requirements

Python 3.9+ and git on PATH. No other dependencies. Authenticate git to your remote the usual way (GitHub CLI, credential manager or SSH key) before `init`.

## Development

```
pip install -e .
python -m unittest discover -s tests -t .
```

## License

MIT
