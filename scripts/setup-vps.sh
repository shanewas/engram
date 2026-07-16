#!/usr/bin/env bash
# Engram node setup (Linux). Idempotent — safe to rerun.
#   1. clone repo to ~/engram (if missing; --remote <url> required on first run)
#   2. import index.md into ~/.claude/CLAUDE.md (idempotent)
#   3. merge SessionStart(pull)/SessionEnd(push) hooks into ~/.claude/settings.json (jq;
#      preserves other keys/hooks, replaces rather than duplicates an existing engram hook)
#   4. COPY skills into ~/.claude/skills as real directories (never symlink — Claude
#      Code's skill discovery does not follow links and will silently fail to load them)
#   5. --read-only: mark node read-only (push degrades to pull; push URL disabled)
#   6. install a 30-min cron push (safety net for killed/short sessions)
#
# usage: bash setup-vps.sh [--remote <git-url>] [--read-only] [--no-cron]
set -euo pipefail

REMOTE=""
READ_ONLY=0
NO_CRON=0

usage() {
  cat <<'EOF'
usage: setup-vps.sh [--remote <git-url>] [--read-only] [--no-cron]
  --remote <url>   git remote to clone from (required if ~/engram doesn't exist yet)
  --read-only      mark this node read-only: push degrades to pull, push URL disabled
  --no-cron        do not install the 30-min cron push (also removes any existing one)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --remote)
      REMOTE="${2:-}"
      [ -n "$REMOTE" ] || { echo "[engram] --remote requires a value" >&2; exit 1; }
      shift 2
      ;;
    --remote=*)
      REMOTE="${1#*=}"
      shift
      ;;
    --read-only)
      READ_ONLY=1
      shift
      ;;
    --no-cron)
      NO_CRON=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[engram] unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

DIR="$HOME/engram"

# --- 0. jq required (needed for the settings.json merge below) ---------------
command -v jq >/dev/null 2>&1 || {
  echo "[engram] jq is required but was not found. Install it first, e.g.:" >&2
  echo "         sudo apt install -y jq" >&2
  exit 1
}

# --- 1. clone if missing -------------------------------------------------------
if [ ! -d "$DIR/.git" ]; then
  if [ -z "$REMOTE" ]; then
    echo "[engram] $DIR does not exist and no --remote <url> was given" >&2
    exit 1
  fi
  git clone "$REMOTE" "$DIR"
  echo "[engram] cloned $REMOTE -> $DIR"
else
  echo "[engram] repo already present at $DIR"
fi
chmod +x "$DIR"/scripts/*.sh 2>/dev/null || true

# --- 2. import line in user-level CLAUDE.md ------------------------------------
MD="$HOME/.claude/CLAUDE.md"
mkdir -p "$(dirname "$MD")"
touch "$MD"
if ! grep -qs "engram/index.md" "$MD"; then
  printf '\n# Engram shared memory (added by engram setup)\n@%s/index.md\n' "$DIR" >> "$MD"
  echo "[engram] import added -> $MD"
else
  echo "[engram] import already present -> $MD"
fi

# --- 3. hooks in user-level settings.json (jq merge) ---------------------------
SET="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SET")"
[ -s "$SET" ] || echo '{}' > "$SET"
jq empty "$SET" >/dev/null 2>&1 || {
  echo "[engram] $SET exists but is not valid JSON — fix or remove it manually, then rerun" >&2
  exit 1
}

# SessionStart: synchronous pull, bounded by the hook's own timeout (20s).
# SessionEnd: detached push — setsid+nohup+& so the hook returns instantly and
# the push survives the hook process being torn down (see docs/sync-contract.md §8).
PULL_CMD="bash \"$DIR/scripts/sync.sh\" pull"
PUSH_CMD="setsid nohup bash \"$DIR/scripts/sync.sh\" push >/dev/null 2>&1 &"

tmp="$(mktemp)"
jq \
  --arg pull "$PULL_CMD" \
  --arg push "$PUSH_CMD" \
  '
  def set_engram_hook(event; cmd; tmo):
    (.hooks[event] // []) as $existing
    | ($existing | map(select(((.hooks // []) | map(.command // "") | any(contains("engram/scripts/sync.sh"))) | not))) as $kept
    | .hooks[event] = ($kept + [{matcher: "*", hooks: [{type: "command", command: cmd, timeout: tmo}]}]);

  .hooks //= {}
  | set_engram_hook("SessionStart"; $pull; 20)
  | set_engram_hook("SessionEnd"; $push; 10)
  ' "$SET" > "$tmp" && mv "$tmp" "$SET"
echo "[engram] hooks merged -> $SET"

# --- 4. skills: COPY as real directories, never symlink ------------------------
mkdir -p "$HOME/.claude/skills"
if [ -d "$DIR/plugins/engram/skills" ]; then
  for s in "$DIR/plugins/engram/skills"/*/; do
    [ -d "$s" ] || continue
    name="$(basename "$s")"
    target="$HOME/.claude/skills/$name"
    if [ -L "$target" ] || [ -e "$target" ]; then
      rm -rf "$target"
    fi
    cp -r "$s" "$target"
    echo "[engram] skill copied: $name"
  done
fi

# --- 5. read-only node ----------------------------------------------------------
if [ "$READ_ONLY" = "1" ]; then
  touch "$DIR/.git/engram-readonly"
  git -C "$DIR" remote set-url --push origin DISABLED
  echo "[engram] node marked read-only: push degrades to pull, push URL disabled"
fi

# --- 6. 30-min cron push (idempotent: strip old engram lines first) -----------
EXISTING_CRON="$(crontab -l 2>/dev/null | grep -v 'engram/scripts/sync.sh' || true)"
if [ "$NO_CRON" = "1" ]; then
  printf '%s\n' "$EXISTING_CRON" | crontab -
  echo "[engram] --no-cron: any existing cron entry removed; none installed"
else
  {
    [ -n "$EXISTING_CRON" ] && printf '%s\n' "$EXISTING_CRON"
    printf '*/30 * * * * bash "%s/scripts/sync.sh" push >/dev/null 2>&1\n' "$DIR"
  } | crontab -
  echo "[engram] cron installed (every 30 min)"
fi

echo
echo "[engram] node ready: $DIR"
