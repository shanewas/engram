# Dotfiles: sync harness config alongside memory

Memory syncs through the allowlist. Harness configuration (Claude Code settings, `CLAUDE.md`, rules, hooks,
plugin lists, MCP servers, other agents' config) syncs through `dotfiles/` plus `scripts/dotfiles.py`. Same repo,
same pull hook, deliberately separate write path: `dotfiles/` is never auto-committed. A broken `settings.json`
committed by a hook would reach every machine within one session.

## Commands

```
python3 scripts/dotfiles.py apply [--dry-run] [--force] [--skip-installs]
python3 scripts/dotfiles.py save  [--no-stage]
python3 scripts/dotfiles.py doctor
```

Stdlib only, Python 3.8+. `apply` always exits 0 (it runs inside a SessionStart hook). Windows: `python -X utf8`.

## Files

| Path | Role |
|---|---|
| `dotfiles/targets.conf` | one line per target: `kind\|source\|dest[\|exclude=glob,glob]`. `kind` is `file` (rendered template) or `dir` (verbatim copy). `dest` may use `{{HOME}}` and `{{APPDATA}}`. |
| `dotfiles/<harness>/...` | the captured files. Templates carry placeholders, see below. |
| `dotfiles/hosts/<hostname>.json` | per-machine values: `vars`, `overlay` (JSON deep-merge per source), `append` (text suffix per source). Hostname lowercased, non `[a-z0-9-]` replaced by `-`. |
| `dotfiles/marketplaces.txt`, `plugins.txt` | `name\|source` and `plugin@marketplace` lines; `apply` installs what is missing via the `claude` CLI |
| `dotfiles/claude/mcp.json.tmpl` | user-scope MCP servers, added with `claude mcp add-json` when absent, never removed |
| `dotfiles/externals.txt` | `name\|git url\|expected VERSION\|skills-to-keep`; cloned into `~/.claude/skills/<name>` and set up when missing |
| `~/.config/dotfiles/secrets.env` | `KEY=value`, per machine, never in git |
| `~/.config/dotfiles/state.json` | sha256 of the last render per target, drives the drift guard |
| `.git/engram-apply-dotfiles` | opt-in marker; without it `apply` does nothing on that machine |

## Placeholders

| In a template | Rendered as |
|---|---|
| `{{HOME}}` | home directory, native separators |
| `{{HOME_JSON}}` | home with backslashes doubled, for JSON strings on Windows |
| `{{HOME_FWD}}` | home with forward slashes |
| `{{VAR:name}}` | `hosts/<host>.json` → `vars.name` |
| `{{SECRET:NAME}}` | `secrets.env` → `NAME`; values are JSON-escaped inside `.json` targets |

A missing var or secret skips that one target and writes `ALERT.md`; every other target still applies.

## Drift guard

`apply` compares three hashes per target: the new render, the live file, and the last render recorded in
`state.json`.

- live == last render → the repo version is written.
- live changed, render unchanged → left alone, `local edit not saved: <file>` printed. Run `save`.
- both changed → left alone, `ALERT.md` names the file. Decide with `save` (keep local) or `apply --force` (take repo).

`dir` targets delete a destination file only if `state.json` lists it as previously applied, so files you add by
hand next to synced ones survive.

## save

Reverse of `apply`: reads the live files, subtracts the host overlay and append, swaps secret values and host
vars back to placeholders, writes into `dotfiles/`, refreshes `plugins/engram/skills` from the live skill
copies, refreshes `state.json`, stages `dotfiles/` and runs the secret scan on the staged diff (contract §7
patterns plus a JSON-quoted variant). A hit unstages and writes `ALERT.md`. Commit and push stay manual.

## Bootstrap a new machine

1. `git pull` in the repo.
2. Create `~/.config/dotfiles/secrets.env` with every name from `grep -rhoE "\{\{SECRET:\w+\}\}" dotfiles | sort -u`.
3. Create `dotfiles/hosts/<hostname>.json`, minimum `{"vars": {}, "overlay": {}, "append": {}}`.
4. `touch .git/engram-apply-dotfiles`.
5. `python3 scripts/dotfiles.py apply --dry-run`, read the `write` list.
6. `python3 scripts/dotfiles.py apply --force` once (no state exists yet), then restart Claude Code.
7. `python3 scripts/dotfiles.py doctor` must be all PASS.

## First capture on the machine you already have set up

Fill `dotfiles/targets.conf` (the shipped one covers Claude Code), then `python3 scripts/dotfiles.py save --no-stage`,
inspect `dotfiles/`, confirm `apply --dry-run` prints nothing to write, then `save` again to stage with the
secret scan and commit.

## Not synced on purpose

`~/.claude.json` as a whole (OAuth and UI state; only `mcpServers` entries get added), path-keyed auto-memory
under `~/.claude/projects/`, credentials files, session history. Anything that embeds a password belongs in
`secrets.env` behind a placeholder or outside the sync entirely.
