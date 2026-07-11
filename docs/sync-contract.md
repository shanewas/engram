# Engram sync contract

Normative spec. `scripts/sync.ps1` (Windows) and `scripts/sync.sh` (Linux) MUST implement identical behaviour. Any divergence is a bug.

Repo root = parent of `scripts/`. Hostname = lowercased, `[^a-z0-9-]` → `-`.

## Invariants

1. **Never blocks a Claude session.** Always `exit 0`, on every path, including catastrophic failure.
2. **Never hangs.** Every remote git operation runs under the guards below. No interactive prompt can ever appear.
3. **Never silently diverges.** A node that cannot sync MUST escalate (see §5). Silent local-only state is forbidden — it is data loss in a memory system.
4. **Never commits outside the allowlist.** The model writes to this repo autonomously; blast radius is bounded structurally, not by prompt.

## 1. Guards (apply to every remote op)

Environment:

```
GIT_TERMINAL_PROMPT=0
GCM_INTERACTIVE=never
GIT_SSH_COMMAND=ssh -o BatchMode=yes -o ConnectTimeout=10
```

Per-invocation config (`git -c ... <cmd>`):

```
credential.interactive=false
http.lowSpeedLimit=1000
http.lowSpeedTime=15
```

`GIT_TERMINAL_PROMPT=0` does **not** suppress Git Credential Manager's GUI dialog — `GCM_INTERACTIVE=never` + `credential.interactive=false` are what prevent the most likely real-world hang on Windows. Do **not** wrap git in `Start-Job`/background-kill timeout wrappers: killing the wrapper orphans `git.exe`, which leaves `index.lock` and a half-finished rebase behind. The wall-clock ceiling belongs at the hook layer (`timeout` in settings.json), not in the script.

## 2. Lock

`.git/engram-sync.lock`, containing the pid and an ISO-8601 UTC timestamp.

- Held → **exit 0 immediately** (do not wait). A concurrent sync is already doing the work.
- Stale (> 5 min old) → steal it.
- Always released, including on error.

## 3. Paths

| Path | Meaning |
|---|---|
| `.git/engram-state` | `ok <iso8601>` or `err <iso8601> <reason>` — last sync outcome |
| `ALERT.md` | repo root, **gitignored**, local-only. Its existence means this node needs human/model attention. |

Commit allowlist — nothing else is ever staged:

```
index.md  projects/  global/  inbox/  archive/
```

Changes to `scripts/`, `CLAUDE.md`, `PLAN.md`, `docs/`, `.claude/` are *code*, not memory: they require a deliberate manual commit. `consolidate` surfaces untracked strays.

## 4. Modes

### `pull`

1. Acquire lock (held → exit 0).
2. Self-heal: if `.git/rebase-merge` or `.git/rebase-apply` exists → `git rebase --abort`.
3. `git pull --rebase --autostash` (guarded).
   - success → refresh skills (§6); delete `ALERT.md`; state = ok.
   - conflict → `git rebase --abort`; **escalate** (§5).
   - network/auth failure → state = err. No escalation (transient; not divergence).
4. If `ALERT.md` exists, **print its contents to stdout**. SessionStart hook stdout is injected into the session context — this is how the model itself learns the node is broken.
5. `exit 0`.

### `push`

0. Read-only node (`.git/engram-readonly` exists) → run `pull` instead, exit 0.
1. Acquire lock (held → exit 0).
2. Self-heal rebase as above.
3. `git add --` over the allowlist (skip paths that don't exist).
4. **Secret scan** `git diff --cached` (§7). Hit → `git reset` (unstage), write `ALERT.md`, exit 0. Never commit a suspected secret.
5. Commit if the staged diff is non-empty. Message: `sync(<host>): <iso8601>`.
6. `git pull --rebase --autostash` (guarded). Conflict → `rebase --abort`; **escalate**; exit 0.
7. `git push` (guarded). Failure → **escalate**; exit 0.
8. Delete `ALERT.md`; state = ok; `exit 0`.

## 5. Escalation (the anti-divergence mechanism)

Triggered when a rebase conflicts or a push is rejected — i.e. whenever this node holds commits it cannot get to `origin/main`.

1. `git push --force origin HEAD:conflict/<host>` (guarded). This is a per-host scratch branch, always safe to force. **No local-only commit is ever stranded** — the work is on the hub even when main is blocked.
2. Write `ALERT.md` stating: what failed, that `conflict/<host>` holds this node's commits, and that `consolidate` must merge and delete it.
3. State = err.

Rationale: the failure is routed to the operator, and the operator is the model. `index.md` (always loaded) carries the standing instruction to act on `ALERT.md`; the pull hook prints it into context. A memory system that silently stops syncing while the user keeps writing to it is worse than one that loudly fails.

## 6. Skills refresh

`~/.claude/skills` **must contain real directories, not symlinks/junctions** — Claude Code's skill discovery does not follow them (it will silently fail to load). Setup copies `.claude/skills/*` there; every successful `pull` re-copies, so a skill edited on one machine propagates to the others.

## 7. Secret scan patterns

Case-sensitive unless noted. Scan added lines only.

```
AKIA[0-9A-Z]{16}                          AWS access key
gh[pousr]_[A-Za-z0-9]{36}                 GitHub token
xox[baprs]-[A-Za-z0-9-]{10,}              Slack token
sk-[A-Za-z0-9]{20,}                       OpenAI-style key
sk-ant-[A-Za-z0-9_-]{20,}                 Anthropic key
AIza[0-9A-Za-z_-]{35}                     Google API key
-----BEGIN [A-Z ]*PRIVATE KEY-----        private key
eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.  JWT
(?i)(password|passwd|secret|token|api[_-]?key)\s*[:=]\s*\S{12,}   generic
```

The allowlist bounds *which files* sync; the scan catches a secret pasted *into* an allowed `.md`. Both are needed.

## 8. Hook wiring

| Hook | Command | Why |
|---|---|---|
| SessionStart | `sync pull`, synchronous, `timeout: 20` | Must finish before the session works; bounded so it can't wedge startup. |
| SessionEnd | `sync push`, **detached/fire-and-forget** | SessionEnd hooks can be killed before a network push completes. Detaching makes truncation irrelevant: the hook returns instantly, the push outlives it. |
| Scheduled (30 min) | `sync push` | The real durability guarantee. Treat SessionEnd as best-effort. |

## 9. Known Claude Code behaviours designed around

- `@import` in `~/.claude/CLAUDE.md` must use **forward slashes** on Windows (`@<home>/engram/index.md`, e.g. `@C:/Users/yourname/engram/index.md`) — backslash paths hit a path-parsing bug.
- Imports resolve at session start. A `pull` in SessionStart may land *after* the index is read, so the always-loaded index can be one session stale. Acceptable: the 30-min sync means the tree is nearly always fresh already, and `projects/*.md` are lazy-read *during* the session — after the pull — so the actual content is current.
- `settings.json` must be written **UTF-8 without BOM**. PowerShell 5.1's `Set-Content -Encoding UTF8` emits a BOM.
