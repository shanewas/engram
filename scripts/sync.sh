#!/usr/bin/env bash
# engram sync — see docs/sync-contract.md (normative spec; that file is the source
# of truth — if this script and the doc ever disagree, the doc wins and this is a bug).
#
# Invariant: every code path below ends in `exit 0`. This script must never block,
# hang, or crash a Claude Code session, no matter how badly the sync itself goes.
#
# usage: sync.sh [pull|push]   (default: pull)
set -u

# ---------------------------------------------------------------------------
# 0. locate repo root, bail out fast and quietly if this isn't a real checkout
# ---------------------------------------------------------------------------
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 0
cd "$DIR" 2>/dev/null || exit 0
[ -d .git ] || exit 0   # not a git repo at all — nothing to do, never blocks

MODE="${1:-pull}"
case "$MODE" in
  pull|push) ;;
  *) MODE=pull ;;
esac

LOCKFILE=".git/engram-sync.lock"
STATEFILE=".git/engram-state"
ALERTFILE="ALERT.md"
READONLY_MARKER=".git/engram-readonly"
STALE_SECS=300
NUDGE_DAYS=7

# §3 commit allowlist: read from scripts/sync-paths.conf (one path per line,
# '#' comments). The conf lives under scripts/ = code, so changing WHAT syncs
# still requires a deliberate manual commit. Absolute paths and '..' entries
# are ignored; missing/empty conf falls back to the built-in default.
ALLOWLIST_DEFAULT="index.md projects global inbox archive"
ALLOWLIST_CONF="scripts/sync-paths.conf"
load_allowlist() {
  local raw="" p out=""
  if [ -f "$ALLOWLIST_CONF" ]; then
    raw="$(sed 's/#.*//' "$ALLOWLIST_CONF" 2>/dev/null)"
  fi
  for p in $raw; do
    case "$p" in
      /*|*..*) continue ;;
    esac
    out="$out $p"
  done
  ALLOWLIST="${out# }"
  [ -n "$ALLOWLIST" ] || ALLOWLIST="$ALLOWLIST_DEFAULT"
}
load_allowlist

# ---------------------------------------------------------------------------
# §1 guards — apply to every remote git operation
# ---------------------------------------------------------------------------
export GIT_TERMINAL_PROMPT=0
export GCM_INTERACTIVE=never
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"

# per-invocation config for remote ops (pull/push/ls-remote); local-only git
# commands (add/commit/diff/reset/rebase --abort) don't need these.
git_remote() {
  git -c credential.interactive=false -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 "$@"
}

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# hostname, sanitized: lowercase, anything not [a-z0-9-] becomes '-'
HOST="$(hostname 2>/dev/null || printf '%s' "${HOSTNAME:-}")"
HOST="$(printf '%s' "$HOST" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]/-/g')"
[ -n "$HOST" ] || HOST="unknown-host"

set_state_ok()  { printf 'ok %s\n' "$(iso_now)" > "$STATEFILE" 2>/dev/null || true; }
set_state_err() { printf 'err %s %s\n' "$(iso_now)" "$1" > "$STATEFILE" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# §2 lock — .git/engram-sync.lock holds "<pid> <iso8601>"
#   held (< 5 min old) -> exit 0 immediately, do nothing else (§2)
#   stale (>= 5 min)   -> steal it
#   always released on any exit, including signals (trap)
# ---------------------------------------------------------------------------
LOCK_OURS=0
release_lock() {
  [ "$LOCK_OURS" = "1" ] && rm -f "$LOCKFILE" 2>/dev/null
  return 0
}
trap release_lock EXIT INT TERM

acquire_lock() {
  # noclobber makes this an atomic create (O_EXCL-style): two concurrent syncs
  # can't both believe they created it.
  if ( set -o noclobber; printf '%s %s\n' "$$" "$(iso_now)" > "$LOCKFILE" ) 2>/dev/null; then
    LOCK_OURS=1
    return 0
  fi

  [ -f "$LOCKFILE" ] || return 1

  local ts lock_epoch now_epoch age
  ts="$(awk '{print $2; exit}' "$LOCKFILE" 2>/dev/null)"
  lock_epoch="$(date -u -d "$ts" +%s 2>/dev/null)" || lock_epoch=0
  now_epoch="$(date -u +%s)"
  age=$(( now_epoch - lock_epoch ))

  if [ "$age" -gt "$STALE_SECS" ]; then
    # stale (or an unparsable timestamp, which forces lock_epoch=0 -> huge age) - steal it.
    local tmp
    tmp="$(mktemp "${LOCKFILE}.XXXXXX" 2>/dev/null)" || tmp="${LOCKFILE}.tmp.$$"
    printf '%s %s\n' "$$" "$(iso_now)" > "$tmp" 2>/dev/null
    if mv -f "$tmp" "$LOCKFILE" 2>/dev/null; then
      LOCK_OURS=1
      return 0
    fi
    return 1
  fi

  return 1   # held, and fresh
}

# read-only node: push degrades to pull (checked before the lock, per contract §4 push step 0)
if [ "$MODE" = "push" ] && [ -e "$READONLY_MARKER" ]; then
  MODE=pull
fi

if ! acquire_lock; then
  exit 0
fi

# ---------------------------------------------------------------------------
# self-heal: a previous run that crashed mid-rebase leaves one of these behind.
# ---------------------------------------------------------------------------
self_heal_rebase() {
  if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
    git rebase --abort >/dev/null 2>&1 || true
  fi
}
self_heal_rebase

# ---------------------------------------------------------------------------
# §4 step 0 (both modes) — a node with no 'origin' remote cannot sync at all.
# That is a standing configuration failure, not a transient one: warn loudly
# (stdout lands in the session context via the SessionStart hook), record err,
# and stop. Silence here would be exactly the "silently diverges" failure the
# contract forbids.
# ---------------------------------------------------------------------------
if ! git remote get-url origin >/dev/null 2>&1; then
  cat <<'EOF'
[engram] NOT CONNECTED: this memory repo has no 'origin' remote, so nothing
syncs to or from your other machines. Facts saved here stay on this machine
only. Fix it once: create a private GitHub repo, then run
    git remote add origin <your-private-repo-url>
from the repo root and re-run sync — or run scripts/setup.sh for a guided setup.
EOF
  set_state_err "no origin remote configured"
  [ -f "$ALERTFILE" ] && cat "$ALERTFILE" 2>/dev/null
  exit 0
fi

# ---------------------------------------------------------------------------
# §6 skills refresh — real directories only, never symlinks/junctions (Claude
# Code's skill discovery does not follow them and will silently fail to load).
# ---------------------------------------------------------------------------
refresh_skills() {
  [ -n "${HOME:-}" ] || return 0
  local src="$DIR/.claude/skills" dst="$HOME/.claude/skills"
  [ -d "$src" ] || return 0
  mkdir -p "$dst" 2>/dev/null || return 0
  local d name
  for d in "$src"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    [ -n "$name" ] || continue
    if [ -e "$dst/$name" ] || [ -L "$dst/$name" ]; then
      rm -rf "$dst/$name" 2>/dev/null
    fi
    cp -r "$d" "$dst/$name" 2>/dev/null
  done
}

# ---------------------------------------------------------------------------
# §5 escalation — this node holds commit(s) it cannot get to origin/main.
# ---------------------------------------------------------------------------
escalate() {
  local reason="$1" branch="conflict/${HOST}" out rc
  out="$(git_remote push --force origin "HEAD:${branch}" 2>&1)"
  rc=$?
  {
    printf '# Engram sync ALERT\n\n'
    if [ "$rc" -eq 0 ]; then
      printf '**Your memory could not sync — but nothing is lost.** This machine'\''s\n'
      printf 'changes are parked safely on the hub. To fix it, open Claude Code and\n'
      printf 'say: "consolidate memory".\n\n'
    else
      printf '**Your memory could not sync, and parking the changes on the hub also\n'
      printf 'failed — they exist only on this machine right now.** Nothing is\n'
      printf 'deleted. Check your internet connection / git login, then re-run sync.\n\n'
    fi
    printf 'Details (for the fix):\n\n'
    printf -- '- node: %s\n' "$HOST"
    printf -- '- time: %s\n' "$(iso_now)"
    printf -- '- reason: %s\n\n' "$reason"
    if [ "$rc" -eq 0 ]; then
      printf 'This node has commit(s) that could not be merged into origin/main.\n'
      printf 'They are safe: force-pushed to the scratch branch `%s` on origin.\n\n' "$branch"
      printf 'Action required: run the consolidate skill to merge `%s` into main, then delete the branch.\n' "$branch"
    else
      printf 'This node has commit(s) that could not be merged into origin/main, AND\n'
      printf 'the fallback push to `%s` also failed:\n\n' "$branch"
      printf '```\n%s\n```\n\n' "$out"
      printf 'These commits currently exist ONLY on this node. Check connectivity/auth and re-run sync.\n'
    fi
  } > "$ALERTFILE" 2>/dev/null
  set_state_err "$reason"
}

# ---------------------------------------------------------------------------
# shared pull-rebase step. Sets PULL_OUTPUT. Returns 0 ok, 1 conflict, 2 other failure.
# ---------------------------------------------------------------------------
PULL_OUTPUT=""
do_pull_rebase() {
  local out rc
  out="$(git_remote pull --rebase --autostash 2>&1)"
  rc=$?
  PULL_OUTPUT="$out"
  [ "$rc" -eq 0 ] && return 0
  if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
    git rebase --abort >/dev/null 2>&1 || true
    return 1
  fi
  return 2
}

# ---------------------------------------------------------------------------
# §7 secret scan — scans ADDED lines of the staged diff only.
# Echoes matched pattern labels (one per line); empty output = clean.
# ---------------------------------------------------------------------------
scan_secrets() {
  local added
  added="$(git diff --cached -U0 --text 2>/dev/null | grep -E '^\+' | grep -Ev '^\+\+\+')"
  # §7 false-positive escape hatch: a line tagged 'engram:not-a-secret' is
  # excluded from the scan. The sanctioned path for already-redacted text —
  # the alternative is people learning to bypass the scan entirely.
  added="$(printf '%s\n' "$added" | grep -v 'engram:not-a-secret')"
  [ -n "$added" ] || return 0

  local labels=(
    "AWS access key"
    "GitHub token"
    "Slack token"
    "OpenAI-style key"
    "Anthropic key"
    "Google API key"
    "private key block"
    "JWT"
  )
  local patterns=(
    'AKIA[0-9A-Z]{16}'
    'gh[pousr]_[A-Za-z0-9]{36}'
    'xox[baprs]-[A-Za-z0-9-]{10,}'
    'sk-[A-Za-z0-9]{20,}'
    'sk-ant-[A-Za-z0-9_-]{20,}'
    'AIza[0-9A-Za-z_-]{35}'
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.'
  )
  local i hit=""
  for i in "${!patterns[@]}"; do
    if printf '%s\n' "$added" | grep -Eq -- "${patterns[$i]}"; then
      hit="${hit}${labels[$i]}"$'\n'
    fi
  done
  # generic pattern is case-insensitive in the spec via (?i); ERE has no inline
  # flag for that, so: strip it and run this one pattern through grep -Ei.
  if printf '%s\n' "$added" | grep -Eqi -- '(password|passwd|secret|token|api[_-]?key)\s*[:=]\s*\S{12,}'; then
    hit="${hit}generic credential-like string"$'\n'
  fi
  printf '%s' "$hit"
}

write_secret_alert() {
  local labels="$1"
  {
    printf '# Engram sync ALERT\n\n'
    printf '**Upload stopped: something that looks like a password or key was found\n'
    printf 'in your changes.** Nothing was uploaded and nothing is lost — the change\n'
    printf 'is still in your files, just not synced yet.\n\n'
    printf 'Details (for the fix):\n\n'
    printf -- '- node: %s\n' "$HOST"
    printf -- '- time: %s\n' "$(iso_now)"
    printf -- '- reason: secret scan matched staged changes; commit refused\n\n'
    printf 'Patterns matched:\n'
    printf '%s\n' "$labels" | sed '/^$/d; s/^/- /'
    printf '\nThe change was NOT committed and remains unstaged in your working tree.\n'
    printf 'To fix, open the file and either:\n\n'
    printf -- '- remove the secret (real secrets never belong in memory), or\n'
    printf -- '- if the line is a false alarm (e.g. already-redacted text), append\n'
    printf '  `<!-- engram:not-a-secret -->` to that exact line.\n\n'
    printf 'Then re-run: scripts/sync.sh push (Windows: scripts\\sync.ps1 push).\n'
    printf 'Never work around this scan by committing manually.\n'
  } > "$ALERTFILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# §4 modes
# ---------------------------------------------------------------------------
# Maintenance nudge: the consolidate skill appends "- YYYY-MM-DD <host>" to
# archive/consolidate-log.md on every run (synced — the newest date is
# cluster-wide). Printed on successful pull only: that stdout reaches the
# session context. No log file = never consolidated = stay quiet (fresh setup).
consolidate_nudge() {
  local log="archive/consolidate-log.md" last last_epoch now_epoch age_days
  [ -f "$log" ] || return 0
  last="$(grep -Eo '^- [0-9]{4}-[0-9]{2}-[0-9]{2}' "$log" 2>/dev/null | tail -1 | cut -c3-)"
  [ -n "$last" ] || return 0
  last_epoch="$(date -u -d "$last" +%s 2>/dev/null)" || return 0
  now_epoch="$(date -u +%s)"
  age_days=$(( (now_epoch - last_epoch) / 86400 ))
  if [ "$age_days" -ge "$NUDGE_DAYS" ]; then
    printf '[engram] Last memory consolidation was %s days ago — say "consolidate memory" when convenient.\n' "$age_days"
  fi
}

if [ "$MODE" = "pull" ]; then
  do_pull_rebase
  case $? in
    0)
      refresh_skills
      rm -f "$ALERTFILE" 2>/dev/null || true
      set_state_ok
      consolidate_nudge
      ;;
    1)
      escalate "pull: rebase onto origin/main conflicted"
      ;;
    2)
      set_state_err "pull failed: ${PULL_OUTPUT:0:200}"
      ;;
  esac
else
  # push
  for p in $ALLOWLIST; do
    [ -e "$p" ] && git add -- "$p" >/dev/null 2>&1
  done

  secret_hit="$(scan_secrets)"
  if [ -n "$secret_hit" ]; then
    git reset >/dev/null 2>&1 || true
    write_secret_alert "$secret_hit"
    set_state_err "secret scan hit"
  else
    committed_or_clean=1
    if ! git diff --cached --quiet 2>/dev/null; then
      commit_out="$(git commit -q -m "sync(${HOST}): $(iso_now)" 2>&1)"
      commit_rc=$?
      if [ "$commit_rc" -ne 0 ]; then
        committed_or_clean=0
        set_state_err "push: commit failed: ${commit_out:0:200}"
      fi
    fi

    if [ "$committed_or_clean" = "1" ]; then
      do_pull_rebase
      rc=$?
      case $rc in
        0)
          push_out="$(git_remote push 2>&1)"
          push_rc=$?
          if [ "$push_rc" -eq 0 ]; then
            rm -f "$ALERTFILE" 2>/dev/null || true
            set_state_ok
          else
            escalate "push failed: ${push_out:0:200}"
          fi
          ;;
        1)
          escalate "push: pre-push rebase onto origin/main conflicted"
          ;;
        2)
          set_state_err "push: pre-push pull failed: ${PULL_OUTPUT:0:200}"
          ;;
      esac
    fi
  fi
fi

# Surface any outstanding alert to stdout. SessionStart hook stdout is injected
# into the session context — this is how the model learns a node is broken.
if [ -f "$ALERTFILE" ]; then
  cat "$ALERTFILE" 2>/dev/null
fi

exit 0
