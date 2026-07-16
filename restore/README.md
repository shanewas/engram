# Disaster recovery

Your memory is a git repository. That is the whole backup: every fact is a commit
on a remote you control. Losing a machine loses nothing that was pushed.

## Restore a machine

```bash
git clone <your-engram-repo-url> ~/engram      # Windows: %USERPROFILE%\engram
bash ~/engram/scripts/bootstrap.sh             # re-wires hooks, cron/timer, PATH
engram status                                  # confirm it synced
```

That's it — all facts (`index.md`, `projects/`, `global/`, `inbox/`, `archive/`)
are back at the position of the last push.

## What git does NOT cover

- **Uncommitted local edits** and **anything written since the last push.** Sync runs
  on an interval (default every 30 min) plus session hooks, so worst-case loss is one
  interval. Run `engram sync` before shutting a machine down to flush.
- **Anything you deliberately kept out of the sync allowlist** (`scripts/sync-paths.conf`).
  Only listed paths are pushed — that's the access model, but it means excluded paths
  live only on the machine that wrote them. Decide consciously with `engram include`/`exclude`.
- **A live memory MCP server, if you run one.** The *data* it serves is in this repo and
  restores with it, but the server process, its config, and its secrets are separate —
  back those up wherever you keep infrastructure secrets, never in this repo.

## Verify your backup is real

```bash
engram status      # "unpushed: 0" means the remote has everything
engram audit 20    # the last 20 changes, attributed and diffable
```

If `unpushed` is non-zero, a machine is holding commits the remote doesn't have yet —
run `engram sync` there.
