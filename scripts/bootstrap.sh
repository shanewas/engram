#!/usr/bin/env bash
# engram bootstrap (Linux/macOS) — one command to wire a brand-new machine.
#
#   curl -fsSL https://raw.githubusercontent.com/<you>/my-engram/main/scripts/bootstrap.sh | bash -s -- <repo-ssh-url>
# (the raw-curl form needs a PUBLIC hub repo; if your hub is private, clone it
#  first and run the form below.)
# or, from an existing clone:
#   bash scripts/bootstrap.sh
#
# Idempotent: safe to re-run. Clones the repo (if given a URL), runs setup,
# and puts `engram` on your PATH. No sudo unless /usr/local/bin is chosen.
set -eu

REPO_URL="${1:-}"
DEST="${ENGRAM_HOME:-$HOME/engram}"

if [ -n "$REPO_URL" ] && [ ! -d "$DEST/.git" ]; then
  echo "[bootstrap] cloning $REPO_URL -> $DEST"
  git clone "$REPO_URL" "$DEST"
elif [ ! -d "$DEST/.git" ]; then
  # running from inside a clone with no URL given
  DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$DEST"
[ -d .git ] || { echo "[bootstrap] $DEST is not an engram clone. Pass the repo URL as the first arg."; exit 1; }

# 1. wire the machine (hooks, cron/timer, skill links) — reuses existing setup
if [ -x scripts/setup-vps.sh ] || [ -f scripts/setup-vps.sh ]; then
  echo "[bootstrap] running setup..."
  bash scripts/setup-vps.sh </dev/null || echo "[bootstrap] setup returned nonzero (continuing)"
fi

# 2. put `engram` on PATH
chmod +x bin/engram 2>/dev/null || true
LINKDIR=""
for d in "$HOME/.local/bin" "/usr/local/bin"; do
  if [ -d "$d" ] && [ -w "$d" ]; then LINKDIR="$d"; break; fi
done
if [ -z "$LINKDIR" ]; then
  mkdir -p "$HOME/.local/bin"; LINKDIR="$HOME/.local/bin"
fi
ln -sf "$DEST/bin/engram" "$LINKDIR/engram"
echo "[bootstrap] linked engram -> $LINKDIR/engram"
case ":$PATH:" in
  *":$LINKDIR:"*) ;;
  *) echo "[bootstrap] add to your shell rc:  export PATH=\"$LINKDIR:\$PATH\"";;
esac

echo "[bootstrap] done. Try:  engram status"
