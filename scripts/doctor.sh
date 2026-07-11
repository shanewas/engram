#!/usr/bin/env bash
# engram doctor — health check for one node. Read-only: makes no changes.
# usage: bash doctor.sh
# exit 0 = all checks passed. exit 1 = at least one FAIL.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || { echo "[FAIL] cannot resolve engram root"; exit 1; }
cd "$DIR" 2>/dev/null || { echo "[FAIL] cannot cd to $DIR"; exit 1; }

FAILURES=0
pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1"; FAILURES=$((FAILURES+1)); }
warn() { printf '[WARN] %s\n' "$1"; }
info() { printf '[INFO] %s\n' "$1"; }

export GIT_TERMINAL_PROMPT=0
export GCM_INTERACTIVE=never
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"

echo "engram doctor — $DIR"
echo

# 1. repo + origin + reachability ---------------------------------------------
if [ -d .git ]; then
  pass "repo: $DIR is a git repository"
else
  fail "repo: $DIR is NOT a git repository"
fi

ORIGIN_URL="$(git remote get-url origin 2>/dev/null)"
if [ -n "$ORIGIN_URL" ]; then
  pass "origin configured: $ORIGIN_URL"
  if timeout 15 git -c credential.interactive=false -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 ls-remote --exit-code origin >/dev/null 2>&1; then
    pass "origin reachable (git ls-remote)"
  else
    fail "origin NOT reachable (git ls-remote failed or timed out)"
  fi
else
  fail "origin: no remote named 'origin' configured"
fi

# 2. CLAUDE.md import -----------------------------------------------------------
MD="${HOME:-}/.claude/CLAUDE.md"
if [ -n "${HOME:-}" ] && [ -f "$MD" ] && grep -qs "engram/index.md" "$MD"; then
  pass "CLAUDE.md: import line present in $MD"
else
  fail "CLAUDE.md: no engram/index.md import found in $MD"
fi
if [ -f "$DIR/index.md" ]; then
  pass "CLAUDE.md: import target $DIR/index.md exists"
else
  fail "CLAUDE.md: import target $DIR/index.md is MISSING"
fi

# 3. settings.json hooks --------------------------------------------------------
SET="${HOME:-}/.claude/settings.json"
if [ -f "$SET" ] && command -v jq >/dev/null 2>&1 && jq empty "$SET" >/dev/null 2>&1; then
  pass "settings.json: valid JSON ($SET)"
  if jq -e '(.hooks.SessionStart // []) | any(.hooks[]?.command // "" | contains("engram") and contains("sync.sh"))' "$SET" >/dev/null 2>&1; then
    pass "settings.json: SessionStart engram hook present"
  else
    fail "settings.json: SessionStart engram hook MISSING"
  fi
  if jq -e '(.hooks.SessionEnd // []) | any(.hooks[]?.command // "" | contains("engram") and contains("sync.sh"))' "$SET" >/dev/null 2>&1; then
    pass "settings.json: SessionEnd engram hook present"
  else
    fail "settings.json: SessionEnd engram hook MISSING"
  fi
else
  fail "settings.json: missing, unreadable, or not valid JSON ($SET)"
fi

# 4. skills are real dirs (not symlinks), each with SKILL.md --------------------
if [ -d "$DIR/.claude/skills" ]; then
  for d in "$DIR/.claude/skills"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    target="${HOME:-}/.claude/skills/$name"
    if [ -L "$target" ]; then
      fail "skill '$name': $target is a SYMLINK (Claude Code will not load it)"
    elif [ -d "$target" ] && [ -f "$target/SKILL.md" ]; then
      pass "skill '$name': real directory with SKILL.md"
    else
      fail "skill '$name': missing or has no SKILL.md at $target"
    fi
  done
else
  warn "no .claude/skills directory in repo — nothing to check"
fi

# 5. cron ------------------------------------------------------------------------
if crontab -l 2>/dev/null | grep -q 'engram/scripts/sync.sh'; then
  pass "cron: engram sync entry installed"
else
  fail "cron: no engram sync entry in crontab"
fi

# 6. ALERT.md ----------------------------------------------------------------------
if [ -f "$DIR/ALERT.md" ]; then
  fail "ALERT.md present — this node flagged a problem"
  echo "----- ALERT.md -----"
  cat "$DIR/ALERT.md"
  echo "---------------------"
else
  pass "no ALERT.md — no outstanding issue flagged"
fi

# 7. last sync state + age --------------------------------------------------------
STATE_FILE=".git/engram-state"
if [ -f "$STATE_FILE" ]; then
  kind=""; ts=""; reason=""
  read -r kind ts reason < "$STATE_FILE" 2>/dev/null
  now_epoch="$(date -u +%s)"
  ts_epoch="$(date -u -d "${ts:-}" +%s 2>/dev/null)" || ts_epoch=0
  age=$(( now_epoch - ts_epoch ))
  if [ "$kind" = "ok" ]; then
    if [ "$ts_epoch" -gt 0 ] && [ "$age" -le 5400 ]; then
      pass "last sync: ok at $ts (${age}s ago)"
    else
      fail "last sync: ok at $ts but STALE (${age}s ago, > 90min)"
    fi
  elif [ "$kind" = "err" ]; then
    fail "last sync: err at $ts — $reason"
  else
    fail "last sync: unreadable state file content in $STATE_FILE"
  fi
else
  fail "last sync: no $STATE_FILE yet — sync has never run on this node"
fi

# 8. read-only push guard ---------------------------------------------------------
if [ -e ".git/engram-readonly" ]; then
  pushurl="$(git remote get-url --push origin 2>/dev/null)"
  if [ "$pushurl" = "DISABLED" ]; then
    pass "read-only: push URL disabled as expected"
  else
    fail "read-only: marker present but push URL is '$pushurl', not DISABLED"
  fi
else
  info "read-only: node is not marked read-only (no .git/engram-readonly)"
fi

# 9. index.md size (warn only, does not fail the run) -----------------------------
if [ -f "$DIR/index.md" ]; then
  lines="$(wc -l < "$DIR/index.md" | tr -d ' ')"
  if [ "$lines" -gt 100 ]; then
    warn "index.md is $lines lines (> 100) — consolidate skill should trim this"
  else
    pass "index.md is $lines lines (<= 100)"
  fi
fi

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "engram doctor: $FAILURES check(s) FAILED"
  exit 1
else
  echo "engram doctor: all checks passed"
  exit 0
fi
