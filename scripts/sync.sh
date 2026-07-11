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
ALLOWLIST="index.md projects global inbox archive"

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
    printf -- '- node: %s\n' "$HOST"
    printf -- '- time: %s\n' "$(iso_now)"
    printf -- '- reason: secret scan matched staged changes; commit refused\n\n'
    printf 'Patterns matched:\n'
    printf '%s\n' "$labels" | sed '/^$/d; s/^/- /'
    printf '\nThe change was NOT committed and remains unstaged in your working tree.\n'
    printf 'Remove the secret, then re-run: scripts/sync.sh push\n'
  } > "$ALERTFILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# §4 modes
# ---------------------------------------------------------------------------
if [ "$MODE" = "pull" ]; then
  do_pull_rebase
  case $? in
    0)
      refresh_skills
      rm -f "$ALERTFILE" 2>/dev/null || true
      set_state_ok
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
