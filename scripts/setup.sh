#!/usr/bin/env bash
# engram guided setup (Linux) — asks a few plain questions, then wires this
# machine. Wraps setup-vps.sh; no sync/setup logic is reimplemented here.
#
# Run it from inside a clone of your engram repo:
#   bash ~/engram/scripts/setup.sh
#
# Interactive by design. For scripted/headless setup use setup-vps.sh directly.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || { echo "[engram] cannot resolve repo root"; exit 1; }
cd "$DIR" || exit 1
[ -d .git ] || { echo "[engram] $DIR is not a git repository — clone your engram repo first, then run this from inside it"; exit 1; }

if [ ! -t 0 ]; then
  echo "[engram] setup.sh is interactive and needs a terminal."
  echo "         For scripted setup use: bash scripts/setup-vps.sh --remote <url> [--read-only]"
  exit 1
fi

say()  { printf '%s\n' "$*"; }
ask()  { printf '%s' "$1"; IFS= read -r REPLY; }
yes_no() {  # $1 prompt, $2 default (y|n) -> returns 0 for yes
  local d="${2:-y}" hint="[Y/n]"
  [ "$d" = "n" ] && hint="[y/N]"
  ask "$1 $hint "
  case "${REPLY:-$d}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

HOST="$(hostname 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]/-/g')"
[ -n "$HOST" ] || HOST="unknown-host"
TODAY="$(date -u +%Y-%m-%d)"

say ""
say "── Engram setup ──────────────────────────────────────────────"
say "This connects the memory folder at:"
say "    $DIR"
say "to your private hub on GitHub, so every machine shares one brain."
say "Three questions, then it wires itself. Nothing here needs git knowledge."
say ""

# ── 0. cloud-sync folder check (OneDrive/Dropbox fight git for file locks) ──
case "$DIR" in
  *OneDrive*|*Dropbox*|*"Google Drive"*|*GoogleDrive*)
    say "⚠️  This folder appears to be inside a cloud-sync folder (OneDrive/Dropbox/"
    say "   Google Drive). Two sync systems on the same folder fight each other:"
    say "   expect file locks and duplicated work. Recommended: move the clone"
    say "   outside the cloud-synced area, or exclude it from that service."
    yes_no "   Continue here anyway?" n || { say "Stopped. Re-clone somewhere else and rerun."; exit 1; }
    ;;
esac

# ── 1. the hub ────────────────────────────────────────────────────────────────
ORIGIN_URL="$(git remote get-url origin 2>/dev/null)"
if [ -n "$ORIGIN_URL" ]; then
  say "Q1. Hub: this machine is already pointed at:"
  say "    $ORIGIN_URL"
  if ! yes_no "    Keep using it?"; then
    ask "    Paste the correct repo URL: "
    [ -n "$REPLY" ] && git remote set-url origin "$REPLY" && ORIGIN_URL="$REPLY"
  fi
else
  say "Q1. Hub: your memory needs one private GitHub repo that all machines share."
  if yes_no "    Do you already have one?" n; then
    ask "    Paste its URL (https://github.com/<you>/<repo>.git): "
    [ -n "$REPLY" ] || { say "No URL given — stopped."; exit 1; }
    git remote add origin "$REPLY" || git remote set-url origin "$REPLY"
    ORIGIN_URL="$REPLY"
  elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    ask "    I can create one for you. Name it [engram-memory]: "
    NAME="${REPLY:-engram-memory}"
    if gh repo create "$NAME" --private >/dev/null 2>&1; then
      OWNER="$(gh api user -q .login 2>/dev/null)"
      ORIGIN_URL="https://github.com/${OWNER}/${NAME}.git"
      git remote add origin "$ORIGIN_URL" || git remote set-url origin "$ORIGIN_URL"
      say "    Created private repo: $ORIGIN_URL"
    else
      say "    Could not create it (name taken, or no permission). Create a PRIVATE"
      say "    repo at https://github.com/new then rerun this setup."
      exit 1
    fi
  else
    say "    Create one first: go to https://github.com/new, name it (e.g."
    say "    engram-memory), set visibility to PRIVATE, click Create. Then:"
    ask "    Paste its URL here: "
    [ -n "$REPLY" ] || { say "No URL given — stopped."; exit 1; }
    git remote add origin "$REPLY" || git remote set-url origin "$REPLY"
    ORIGIN_URL="$REPLY"
  fi
fi

# ── 2. role ───────────────────────────────────────────────────────────────────
READ_ONLY=0
say ""
say "Q2. Should this machine be able to SAVE new memories, or only READ them?"
say "    (Choose read-only for e.g. a work computer that must never upload.)"
if ! yes_no "    Allow saving from this machine?"; then
  READ_ONLY=1
fi

# ── 3. what to keep on this machine ──────────────────────────────────────────
SKIPS=""
say ""
say "Q3. Normally every machine keeps a full copy of the memory. You can skip"
say "    some top-level folders on THIS machine (they stay on the hub and other"
say "    machines — e.g. skip a large 'vault' archive on a work computer)."
ask "    Folders to skip, comma-separated (blank = keep everything): "
if [ -n "${REPLY// /}" ]; then
  SKIPS="$(printf '%s' "$REPLY" | tr ',' ' ')"
  # shellcheck disable=SC2086
  set -- $SKIPS
  PATTERNS=('/*')
  for f in "$@"; do PATTERNS+=("!$f"); done
  if git sparse-checkout set --no-cone "${PATTERNS[@]}" 2>/dev/null; then
    say "    OK — this machine will not keep: $SKIPS"
  else
    say "    ⚠️  Could not apply the skip list (old git version?) — keeping everything."
    SKIPS=""
  fi
fi

# ── 4. first push, if the hub is empty (the one step that may ask for login) ──
if [ "$READ_ONLY" = "0" ]; then
  if ! git ls-remote --exit-code origin main >/dev/null 2>&1; then
    say ""
    say "The hub is empty — publishing this machine's copy as the starting point."
    say "(If git asks you to log in, that's normal — one time only.)"
    git branch -M main 2>/dev/null
    if ! git push -u origin main; then
      say "⚠️  Publishing failed — usually a login problem. Fix git access to"
      say "   $ORIGIN_URL and rerun this setup. Nothing else was changed yet."
      exit 1
    fi
  fi
else
  if ! git ls-remote --exit-code origin main >/dev/null 2>&1; then
    say ""
    say "⚠️  The hub is empty and this machine is read-only, so it cannot publish"
    say "   the first copy. Set up a read/write machine first, then rerun here."
  fi
fi

# ── 5. wire the node (hooks, import, skills, cron) via setup-vps.sh ──────────
say ""
FLAGS=()
[ "$READ_ONLY" = "1" ] && FLAGS+=("--read-only")
bash "$DIR/scripts/setup-vps.sh" "${FLAGS[@]+"${FLAGS[@]}"}" || exit 1

# ── 6. register this machine in global/machines.md (memory — auto-syncs) ─────
MACH="global/machines.md"
mkdir -p global
[ -f "$MACH" ] || printf '# Machines\n\nUpdated: %s\n' "$TODAY" > "$MACH"
if grep -q "^## $HOST " "$MACH" 2>/dev/null; then
  say "[engram] machines.md already has a section for $HOST — left as is"
else
  ROLE="read/write"; [ "$READ_ONLY" = "1" ] && ROLE="READ-ONLY"
  {
    printf '\n## %s (Linux) — %s — registered by setup %s\n\n' "$HOST" "$ROLE" "$TODAY"
    printf -- '- engram: %s\n' "$DIR"
    if [ -n "$SKIPS" ]; then printf -- '- skips (sparse checkout): %s\n' "$SKIPS"; else printf -- '- skips: none (full copy)\n'; fi
  } >> "$MACH"
  say "[engram] machine registered in $MACH (will sync to all machines)"
fi

# ── 7. sync + health check + plain outro ─────────────────────────────────────
bash "$DIR/scripts/sync.sh" push >/dev/null 2>&1
say ""
bash "$DIR/scripts/doctor.sh" --status
say ""
say "── Done ──────────────────────────────────────────────────────"
say "Restart Claude Code to activate the memory. From then on:"
say "  • say \"remember this: <fact>\" to save something everywhere"
say "  • say \"consolidate memory\" about once a week to tidy up"
say "Health check any time:  bash scripts/doctor.sh --status"
exit 0
