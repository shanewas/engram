---
name: engram
description: Control and inspect the Engram memory system, agent harnesses, central skills, and MCP servers. Use when the user says "engram", "sync memory", "run doctor", "connect harness", "sync skills", "check memory", or asks about cross-machine setup.
---

# Engram CLI & Memory Management

Engram is a cross-machine memory, skills, and dotfiles management system for AI coding agents.
Binary entry point: `engram` on PATH (`engram.cmd` / `engram.ps1` on Windows, `bin/engram` on Linux/macOS).
Python fallback: `python <engram_root>/scripts/engram_cli.py`.

## Quick Actions

| Task | Command |
|---|---|
| Health check & diagnostics | `engram doctor` |
| View active topology & harnesses | `engram status` |
| Manual memory pull / push | `engram sync pull` / `engram sync push` |
| Connect all detected agent harnesses | `engram connect --all` |
| Connect a specific agent harness | `engram connect <claude|antigravity|opencode|muse>` |
| Distribute central skills to harnesses | `engram skills sync` |
| List central skills | `engram skills list` |
| Distribute central MCP configs | `engram mcp sync` |
| Quick capture durable fact | `engram remember "<dated fact>"` |
| Inspect memory index and projects | `engram memory status` / `engram memory list` |
| Check dotfiles synchronization | `engram dotfiles doctor` |

## Core Invariants

1. **Facts, not narrative**: All memory entries must be atomic, dated (`YYYY-MM-DD`), and placed in appropriate files (`projects/*.md`, `global/*.md`, or `inbox/YYYY-MM.md`).
2. **Never store secrets**: API tokens, private keys, and passwords must never enter git. Put them in `~/.config/dotfiles/secrets.env`.
3. **Multi-harness sync**: Skills are distributed via real directory copies (`shutil.copytree`) to avoid symlink failure in tools like Claude Code on Windows.
4. **Sync hooks exit 0**: Automated session hooks must never abort an active AI coding session.
