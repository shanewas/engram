# Engram

Shared memory, skills, and tools for AI coding agents across all your computers.

You switch laptops, open Claude Code or Antigravity, and your agent forgets who you are, how your codebase is architected, and what skills you already built. Engram fixes that. Your agents share a single brain stored as plain markdown files in a private git repo you own.

---

## Supported Agents

Engram connects directly to:

- **Claude Code**: Wires `@<engram>/index.md` into `~/.claude/CLAUDE.md`, copies skills to `~/.claude/skills`, injects MCP servers into `~/.claude.json`.
- **Antigravity (agy)**: Wires memory rules into `~/.gemini/rules/engram.md`, copies skills to `~/.gemini/config/skills`, injects MCP servers into `~/.gemini/config/mcp_config.json`.
- **OpenCode**: Wires instructions into `~/.config/opencode/instructions.md`, copies skills to `~/.config/opencode/skills`, injects MCP servers into `~/.config/opencode/opencode.jsonc`.
- **Muse**: Wires memory into `~/.muse/instructions.md`, copies skills to `~/.muse/skills`.
- **Hermes**: Distills remote agent session logs into readable local digest notes.

---

## Quick Start (3 Steps)

### Step 1: Create your private memory repo
Click **Use this template** (or fork) on GitHub and name it `engram-memory`. Make sure it is **Private**.

### Step 2: Install on your first computer

**Windows (PowerShell):**
```powershell
irm https://raw.githubusercontent.com/<your-username>/engram-memory/main/scripts/install.ps1 | iex
```

**Linux / macOS / WSL (Bash):**
```bash
curl -fsSL https://raw.githubusercontent.com/<your-username>/engram-memory/main/scripts/install.sh | bash
```

The installer:
1. Clones your private memory repo to `~/engram` (or `%USERPROFILE%\engram`).
2. Adds the `engram` command to your PATH.
3. Finds your installed coding agents and connects them automatically.
4. Deploys your central skills and MCP servers.
5. Runs a diagnostic health check (`engram doctor`).

### Step 3: Install on your other computers
Run the same one-liner on your work laptop, home PC, or VPS. Everything you taught your agents on machine A is immediately available on machine B.

---

## How It Works

1. **Your git repo is the database.** Every note and learned fact is a git commit with a timestamp and author. You can view changes with `git log` and undo mistakes with `git revert`. No external databases, no cloud subscriptions, no lock-in.
2. **Context stays fast and cheap.** Only `index.md` is loaded at session start. It is a routing table under 100 lines. Project notes (`projects/<slug>.md`) are read by the agent on demand only when you work on that specific project.
3. **Sync runs in the background.** Sessions pull when starting and push when finishing. A 30-minute background task provides a safety net so unsaved edits still sync if an agent crashes.
4. **Skills are real folders, not symlinks.** Windows tools like Claude Code silently ignore directory symlinks. Engram copies skills as real folders into each agent's skill directory so they always work.

---

## Daily Commands

You rarely need to run commands manually, but the `engram` CLI gives you full control whenever you want it:

| Command | What it does |
|---|---|
| `engram status` | Shows branch, unpushed commits, uncommitted notes, and connected agents |
| `engram memory` | Checks line counts against budgets (`index.md` < 100 lines, projects < 300 lines) |
| `engram memory list` | Lists all active project files with line counts and last-updated dates |
| `engram remember "fact"` | Quick-captures a dated note into this month's inbox |
| `engram sync` | Pulls remote changes then pushes local edits |
| `engram connect --all` | Re-scans your computer and wires all detected agent harnesses |
| `engram skills sync` | Fans out central skills to all connected agents |
| `engram mcp sync` | Compiles and injects central MCP servers into agent configurations |
| `engram doctor` | Runs a complete health check on git remotes, configs, and agents |

---

## Memory Layout

```text
engram/
├── index.md            # Master routing table (loaded into every session, <100 lines)
├── projects/           # One file per project (lazy-loaded on demand, <300 lines)
│   ├── _template.md    # Template for new projects
│   └── my-app.md       # Architecture decisions, tech stack, gotchas
├── global/             # Cross-project preferences, coding conventions, machine facts
│   ├── preferences.md  # How you like to work
│   └── machines.md     # Node-specific paths and quirks
├── inbox/              # Append-only quick captures (merged during weekly cleanup)
│   └── 2026-09.md
├── archive/            # Retired projects and compressed historical notes
├── dotfiles/           # Declarative harness adapters and MCP registry templates
└── scripts/            # CLI engine, sync scripts, installers, and test suites
```

---

## Built-in Skills

Engram ships with skills that teach your agents how to manage memory:

- `/remember`: Captures a durable fact and files it into the right project file or inbox.
- `/consolidate`: Weekly cleanup skill. Merges inbox captures into project files, compresses old entries, archives dead projects, and trims `index.md`.
- `/migrate`: Sweeps existing pre-engram notes or `CLAUDE.md` files from a new computer into your shared memory.
- `/engram`: Controls and inspects the Engram CLI directly from inside any agent chat.

---

## Safety Guarantees

- **Secret scanner before commit**: Engram scans staged diffs for private keys, API tokens, and passwords before every push. If a secret is detected, it unstages the files and alerts you. It will never push keys to GitHub.
- **Sync never interrupts your work**: Automated hooks always exit with code 0. If GitHub is unreachable or credentials need updating, the script records the error and lets you continue coding uninterrupted.
- **Merge conflicts never lose data**: If two computers edit memory at the same time and rebase conflicts, Engram force-pushes your local work to a separate `conflict/<machine>` branch and creates an `ALERT.md` note. Nothing is overwritten or deleted.

---

## License

MIT
