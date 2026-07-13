#!/usr/bin/env bash
# Self-contained test harness for scripts/sync.sh / scripts/sync.ps1 against
# docs/sync-contract.md, which requires both implementations to behave
# identically - so this is the SAME contract test suite run against either.
#
# Builds fake worlds entirely under /tmp (a bare "origin" repo + nodeA/nodeB
# clones, each with the impl under test copied in). Never touches the real
# engram repo. Safe to run repeatedly.
#
# usage:
#   bash scripts/test-sync.sh                # sh mode (default): scripts/sync.sh
#   SYNC_IMPL=ps1 bash scripts/test-sync.sh   # ps1 mode: scripts/sync.ps1
#
# ps1 mode requires Windows/Git Bash with powershell.exe on PATH (invoked as a
# native child process - Git Bash translates PATH and cwd for it automatically).
# Auto-skips (exit 0) with a message if SYNC_IMPL=ps1 and powershell.exe isn't found.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ATTRS_SRC="$REPO_ROOT/.gitattributes"

SYNC_IMPL="${SYNC_IMPL:-sh}"
case "$SYNC_IMPL" in
  sh) SYNC_SRC="$REPO_ROOT/scripts/sync.sh" ;;
  ps1)
    command -v powershell.exe >/dev/null 2>&1 || { echo "SKIP: SYNC_IMPL=ps1 requires powershell.exe on PATH (Windows/Git Bash) - not found"; exit 0; }
    SYNC_SRC="$REPO_ROOT/scripts/sync.ps1"
    ;;
  *) echo "invalid SYNC_IMPL='$SYNC_IMPL' (expected 'sh' or 'ps1')"; exit 1 ;;
esac
SYNC_BASENAME="$(basename "$SYNC_SRC")"
SYNC_BUDGET=30; [ "$SYNC_IMPL" = "ps1" ] && SYNC_BUDGET=60

[ -f "$SYNC_SRC" ] || { echo "cannot find $SYNC_SRC"; exit 1; }
[ -f "$ATTRS_SRC" ] || { echo "cannot find $ATTRS_SRC"; exit 1; }

WORK="$(mktemp -d /tmp/engram-synctest.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

PASS=0
FAIL=0
FAILED_NAMES=()

pass() {
  PASS=$((PASS+1))
  printf 'PASS: %s\n' "$1"
}
fail() {
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("$1")
  printf 'FAIL: %s\n' "$1"
  if [ $# -gt 1 ]; then
    printf '      %s\n' "$2"
  fi
}

# Quiets down noisy git plumbing output for setup steps only (never used to
# hide the behaviour actually under test).
q() { "$@" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# world builder: $1 = base dir. Creates:
#   $base/origin.git   bare "hub"
#   $base/nodeA         clone, with scripts/$SYNC_BASENAME + hostname shims (echo "nodeA")
#   $base/nodeB         clone, with scripts/$SYNC_BASENAME + hostname shims (echo "nodeB")
# Both clones get the real repo's .gitattributes (inbox/** merge=union) via the
# seed commit, exactly as production nodes would via git clone.
# ---------------------------------------------------------------------------
make_world() {
  local base="$1" seed="$1/seed" origin="$1/origin.git" n
  mkdir -p "$base"

  q git init -q --bare "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/main >/dev/null

  q git clone -q "$origin" "$seed"
  git -C "$seed" config user.email seed@test.local
  git -C "$seed" config user.name "seed"
  mkdir -p "$seed/projects" "$seed/global" "$seed/inbox" "$seed/archive"
  printf '# index\n\nseed index.\n' > "$seed/index.md"
  : > "$seed/projects/.gitkeep"
  : > "$seed/global/.gitkeep"
  : > "$seed/inbox/.gitkeep"
  : > "$seed/archive/.gitkeep"
  cp "$ATTRS_SRC" "$seed/.gitattributes"
  printf 'ALERT.md\n*.tmp\n' > "$seed/.gitignore"
  q git -C "$seed" add -A
  q git -C "$seed" commit -q -m seed
  q git -C "$seed" push -q origin HEAD:main
  rm -rf "$seed"

  for n in nodeA nodeB; do
    q git clone -q "$origin" "$base/$n"
    git -C "$base/$n" config user.email "${n}@test.local"
    git -C "$base/$n" config user.name "$n"
    mkdir -p "$base/$n/scripts" "$base/$n/bin"
    cp "$SYNC_SRC" "$base/$n/scripts/$SYNC_BASENAME"
    chmod +x "$base/$n/scripts/$SYNC_BASENAME"
    # sh shim: bash resolves `hostname` via PATH.
    printf '#!/bin/sh\necho %s\n' "$n" > "$base/$n/bin/hostname"
    chmod +x "$base/$n/bin/hostname"
    # ps1 shim: powershell.exe resolves external commands via PATH+PATHEXT, so
    # this .cmd shadows System32\hostname.exe once $node/bin is prepended to
    # PATH. Written unconditionally - harmless for sh mode.
    printf '@echo off\r\necho %s\r\n' "$n" > "$base/$n/bin/hostname.cmd"
  done
}

# run the sync impl under test for a node. Its own bin/hostname (sh) /
# bin/hostname.cmd (ps1) shim (nodeA/nodeB) shadows the real `hostname`
# command via PATH, so each node gets a distinct simulated host without any
# test-only hook baked into sync.sh/sync.ps1 themselves. Optional $3 wraps the
# call in `timeout $3` seconds - for tests that probe hang/unreachable-remote
# paths; the budget exists to catch a HANG, not to race the clock.
run_sync() {
  local node="$1" mode="$2" budget="${3:-}"
  local -a cmd
  if [ "$SYNC_IMPL" = "ps1" ]; then
    cmd=(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "scripts/$SYNC_BASENAME" "$mode")
  else
    cmd=(bash "scripts/$SYNC_BASENAME" "$mode")
  fi
  if [ -n "$budget" ]; then
    ( cd "$node" && PATH="$node/bin:$PATH" timeout "$budget" "${cmd[@]}" )
  else
    ( cd "$node" && PATH="$node/bin:$PATH" "${cmd[@]}" )
  fi
}

# ===========================================================================
# 1. push works
# ===========================================================================
test_push_basic() {
  local base="$WORK/t1" origin nodeA
  make_world "$base"
  origin="$base/origin.git"; nodeA="$base/nodeA"

  echo "hello from A" > "$nodeA/projects/x.md"
  q run_sync "$nodeA" push

  if git -C "$origin" show main:projects/x.md 2>/dev/null | grep -q "hello from A"; then
    local msg
    msg="$(git -C "$origin" log -1 --format=%s main 2>/dev/null)"
    case "$msg" in
      sync\(nodea\):*) pass "1 push works (commit landed on origin/main, message='$msg')" ;;
      *) fail "1 push works" "landed, but commit message unexpected: '$msg'" ;;
    esac
  else
    fail "1 push works" "origin/main does not contain expected projects/x.md content"
  fi
}

# ===========================================================================
# 2. pull works
# ===========================================================================
test_pull_basic() {
  local base="$WORK/t2" nodeA nodeB
  make_world "$base"
  nodeA="$base/nodeA"; nodeB="$base/nodeB"

  echo "hello from A" > "$nodeA/projects/x.md"
  q run_sync "$nodeA" push
  q run_sync "$nodeB" pull

  if [ -f "$nodeB/projects/x.md" ] && grep -q "hello from A" "$nodeB/projects/x.md"; then
    pass "2 pull works (nodeB sees nodeA's pushed file)"
  else
    fail "2 pull works" "nodeB/projects/x.md missing or wrong content after pull"
  fi
}

# ===========================================================================
# 3. allowlist: disallowed files never staged; allowed changes are
# ===========================================================================
test_allowlist() {
  local base="$WORK/t3" origin nodeA
  make_world "$base"
  origin="$base/origin.git"; nodeA="$base/nodeA"

  echo "junk" > "$nodeA/scratch.bin"
  mkdir -p "$nodeA/scripts"
  echo "echo evil" > "$nodeA/scripts/evil.sh"
  printf '\n- allowlist marker\n' >> "$nodeA/index.md"
  echo "- allowlist project note" > "$nodeA/projects/x.md"

  q run_sync "$nodeA" push

  local ok=1 detail=""
  if git -C "$origin" show main:scratch.bin >/dev/null 2>&1; then ok=0; detail="$detail scratch.bin was committed;"; fi
  if git -C "$origin" show main:scripts/evil.sh >/dev/null 2>&1; then ok=0; detail="$detail scripts/evil.sh was committed;"; fi
  if ! git -C "$origin" show main:projects/x.md 2>/dev/null | grep -q "allowlist project note"; then ok=0; detail="$detail projects/x.md NOT committed;"; fi
  if ! git -C "$origin" show main:index.md 2>/dev/null | grep -q "allowlist marker"; then ok=0; detail="$detail index.md NOT committed;"; fi
  [ -f "$nodeA/scratch.bin" ] || { ok=0; detail="$detail scratch.bin disappeared locally;"; }
  [ -f "$nodeA/scripts/evil.sh" ] || { ok=0; detail="$detail scripts/evil.sh disappeared locally;"; }

  if [ "$ok" = 1 ]; then
    pass "3 allowlist (scratch.bin / scripts/evil.sh excluded; index.md / projects/x.md committed)"
  else
    fail "3 allowlist" "$detail"
  fi
}

# ===========================================================================
# 4. secret scan: AKIA / ghp_ / private key each refused, unstaged, alerted
# ===========================================================================
test_secret_scan() {
  local secrets=(
    "aws_key = AKIA1234567890ABCDEF"
    "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789ABCD"
    "-----BEGIN RSA PRIVATE KEY-----"
  )
  local labels=("AKIA (AWS key)" "ghp_ (GitHub token)" "PRIVATE KEY block")
  local i
  for i in 0 1 2; do
    local base="$WORK/t4_$i" origin nodeA
    make_world "$base"
    origin="$base/origin.git"; nodeA="$base/nodeA"

    printf '\n%s\n' "${secrets[$i]}" >> "$nodeA/projects/x.md"
    local out rc
    out="$(run_sync "$nodeA" push)"
    rc=$?

    local ok=1 detail=""
    [ "$rc" -eq 0 ] || { ok=0; detail="$detail rc=$rc (expected 0);"; }
    [ -f "$nodeA/ALERT.md" ] || { ok=0; detail="$detail ALERT.md missing;"; }
    q git -C "$nodeA" diff --cached --quiet || { ok=0; detail="$detail something left STAGED;"; }
    # projects/x.md may be a brand-new (untracked) file in some sub-cases, so
    # `git diff` (which ignores untracked files) can't be used here - check the
    # actual working-tree content and HEAD directly instead.
    grep -qF -- "${secrets[$i]}" "$nodeA/projects/x.md" 2>/dev/null || { ok=0; detail="$detail secret content missing from working tree (should be preserved, unstaged);"; }
    if git -C "$nodeA" show HEAD:projects/x.md 2>/dev/null | grep -qF -- "${secrets[$i]}"; then
      ok=0; detail="$detail secret content found in HEAD (should not be committed);"
    fi
    if git -C "$origin" show main:projects/x.md 2>/dev/null | grep -qF -- "${secrets[$i]}"; then
      ok=0; detail="$detail SECRET LEAKED to origin/main;"
    fi
    if [ -f "$nodeA/ALERT.md" ] && grep -qF -- "${secrets[$i]}" "$nodeA/ALERT.md"; then
      ok=0; detail="$detail ALERT.md contains the raw secret (should be redacted);"
    fi

    if [ "$ok" = 1 ]; then
      pass "4.$i secret scan (${labels[$i]}): refused, unstaged, ALERT.md written, origin clean"
    else
      fail "4.$i secret scan (${labels[$i]})" "$detail"
    fi
  done
}

# ===========================================================================
# 5. union merge on inbox/**: both nodes' lines survive, no conflict
# ===========================================================================
test_union_merge() {
  local base="$WORK/t5" origin nodeA nodeB
  make_world "$base"
  origin="$base/origin.git"; nodeA="$base/nodeA"; nodeB="$base/nodeB"

  echo "- base entry" > "$nodeA/inbox/2026-07.md"
  q run_sync "$nodeA" push
  q run_sync "$nodeB" pull

  echo "- entry from A" >> "$nodeA/inbox/2026-07.md"
  echo "- entry from B" >> "$nodeB/inbox/2026-07.md"

  q run_sync "$nodeA" push
  local out rc
  out="$(run_sync "$nodeB" push)"
  rc=$?

  local content ok=1 detail=""
  content="$(git -C "$origin" show main:inbox/2026-07.md 2>/dev/null)"
  [ "$rc" -eq 0 ] || { ok=0; detail="$detail rc=$rc;"; }
  printf '%s' "$content" | grep -q "entry from A" || { ok=0; detail="$detail missing A's line;"; }
  printf '%s' "$content" | grep -q "entry from B" || { ok=0; detail="$detail missing B's line;"; }
  if git -C "$origin" branch --list 'conflict/*' 2>/dev/null | grep -q conflict; then
    ok=0; detail="$detail unexpected conflict/* branch on origin;"
  fi
  [ -f "$nodeB/ALERT.md" ] && { ok=0; detail="$detail unexpected ALERT.md on nodeB;"; }

  if [ "$ok" = 1 ]; then
    pass "5 union merge (both inbox lines survive, no conflict, no alert)"
  else
    fail "5 union merge" "$detail content=[$content]"
  fi
}

# ===========================================================================
# 6. conflict escalation
# ===========================================================================
test_conflict_escalation() {
  local base="$WORK/t6" origin nodeA nodeB
  make_world "$base"
  origin="$base/origin.git"; nodeA="$base/nodeA"; nodeB="$base/nodeB"

  echo "line one" > "$nodeA/projects/x.md"
  q run_sync "$nodeA" push
  q run_sync "$nodeB" pull

  echo "edited by A" > "$nodeA/projects/x.md"
  echo "edited by B" > "$nodeB/projects/x.md"

  q run_sync "$nodeA" push
  local rc
  run_sync "$nodeB" push >/dev/null
  rc=$?

  local ok=1 detail=""
  [ "$rc" -eq 0 ] || { ok=0; detail="$detail rc=$rc (expected 0);"; }
  if ls "$nodeB/.git" 2>/dev/null | grep -q '^rebase-'; then
    ok=0; detail="$detail half-finished rebase left behind;"
  fi
  if ! git -C "$origin" show-ref --verify --quiet refs/heads/conflict/nodeb; then
    ok=0; detail="$detail conflict/nodeb branch missing on origin;"
  else
    local content
    content="$(git -C "$origin" show conflict/nodeb:projects/x.md 2>/dev/null)"
    printf '%s' "$content" | grep -q "edited by B" || { ok=0; detail="$detail conflict/nodeb does not contain nodeB's edit;"; }
  fi
  [ -f "$nodeB/ALERT.md" ] || { ok=0; detail="$detail ALERT.md missing on nodeB;"; }
  local state
  state="$(cat "$nodeB/.git/engram-state" 2>/dev/null)"
  case "$state" in
    err\ *) : ;;
    *) ok=0; detail="$detail engram-state is '$state' (expected 'err ...');" ;;
  esac

  if [ "$ok" = 1 ]; then
    pass "6 conflict escalation (nodeB: exit 0, clean rebase state, conflict/nodeb on origin, ALERT.md, state=err)"
  else
    fail "6 conflict escalation" "$detail"
  fi
}

# ===========================================================================
# 7. alert surfaces on pull (printed to stdout)
# ===========================================================================
test_alert_surfaces_on_pull() {
  local base="$WORK/t7" nodeA
  make_world "$base"
  nodeA="$base/nodeA"

  printf '# Engram sync ALERT\n\nSENTINEL-NEEDS-ATTENTION-42\n' > "$nodeA/ALERT.md"
  # Point origin at an unreachable address so this pull fails (network), rather
  # than succeeding (which would legitimately clear ALERT.md per the contract)
  # or conflicting (which would overwrite it with escalate's own content) -
  # isolates exactly the "print pre-existing alert" behaviour.
  git -C "$nodeA" remote set-url origin "ssh://git@192.0.2.1/nonexistent.git"

  local out rc
  out="$(run_sync "$nodeA" pull "$SYNC_BUDGET")"
  rc=$?

  local ok=1 detail=""
  [ "$rc" -eq 0 ] || { ok=0; detail="$detail rc=$rc;"; }
  printf '%s' "$out" | grep -q "SENTINEL-NEEDS-ATTENTION-42" || { ok=0; detail="$detail alert content not in stdout (got: $out);"; }
  [ -f "$nodeA/ALERT.md" ] || { ok=0; detail="$detail ALERT.md unexpectedly deleted;"; }

  if [ "$ok" = 1 ]; then
    pass "7 alert surfaces on pull (ALERT.md contents printed to stdout)"
  else
    fail "7 alert surfaces on pull" "$detail"
  fi
}

# ===========================================================================
# 8. lock: fresh lock blocks; stale (>5min) lock is stolen
# ===========================================================================
test_lock() {
  local base="$WORK/t8" origin nodeA
  make_world "$base"
  origin="$base/origin.git"; nodeA="$base/nodeA"

  printf '999999 %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$nodeA/.git/engram-sync.lock"
  echo "should stay blocked" > "$nodeA/projects/x.md"
  local rc
  run_sync "$nodeA" push >/dev/null
  rc=$?

  local ok=1 detail=""
  [ "$rc" -eq 0 ] || { ok=0; detail="$detail rc=$rc (expected 0);"; }
  git -C "$origin" show main:projects/x.md >/dev/null 2>&1 && { ok=0; detail="$detail push happened despite held lock;"; }
  [ -f "$nodeA/.git/engram-sync.lock" ] || { ok=0; detail="$detail lock file disappeared (should be untouched);"; }
  if [ "$ok" = 1 ]; then
    pass "8a lock (fresh, <5min): held lock blocks push, exits 0, does nothing"
  else
    fail "8a lock (fresh, held)" "$detail"
  fi

  printf '999999 %s\n' "2020-01-01T00:00:00Z" > "$nodeA/.git/engram-sync.lock"
  local ok2=1 detail2=""
  run_sync "$nodeA" push >/dev/null
  rc=$?
  [ "$rc" -eq 0 ] || { ok2=0; detail2="$detail2 rc=$rc (expected 0);"; }
  git -C "$origin" show main:projects/x.md >/dev/null 2>&1 || { ok2=0; detail2="$detail2 push did NOT happen after stealing stale lock;"; }
  [ -f "$nodeA/.git/engram-sync.lock" ] && { ok2=0; detail2="$detail2 lock file left behind after successful run;"; }
  if [ "$ok2" = 1 ]; then
    pass "8b lock (stale, >5min): stolen, sync proceeds, lock released afterward"
  else
    fail "8b lock (stale, stolen)" "$detail2"
  fi
}

# ===========================================================================
# 9. read-only node: push degrades to pull, never commits/pushes
# ===========================================================================
test_readonly() {
  local base="$WORK/t9" origin nodeA nodeB
  make_world "$base"
  origin="$base/origin.git"; nodeA="$base/nodeA"; nodeB="$base/nodeB"

  echo "from B" > "$nodeB/projects/y.md"
  q run_sync "$nodeB" push

  touch "$nodeA/.git/engram-readonly"
  printf '\nlocal edit on readonly node\n' >> "$nodeA/index.md"

  local rc
  run_sync "$nodeA" push >/dev/null
  rc=$?

  local ok=1 detail=""
  [ "$rc" -eq 0 ] || { ok=0; detail="$detail rc=$rc (expected 0);"; }
  [ -f "$nodeA/projects/y.md" ] || { ok=0; detail="$detail nodeA did not pull nodeB's file;"; }
  if git -C "$origin" log main --format=%an 2>/dev/null | grep -qi nodea; then
    ok=0; detail="$detail nodeA's commit appeared on origin despite read-only;"
  fi
  local after_head origin_head
  after_head="$(git -C "$nodeA" rev-parse HEAD 2>/dev/null)"
  origin_head="$(git -C "$origin" rev-parse main 2>/dev/null)"
  if [ "$after_head" != "$origin_head" ]; then
    ok=0; detail="$detail nodeA HEAD does not match origin/main after pull-only push;"
  fi
  if git -C "$nodeA" diff --quiet 2>/dev/null; then
    ok=0; detail="$detail local edit was not preserved (working tree clean, expected a diff);"
  fi

  if [ "$ok" = 1 ]; then
    pass "9 read-only node (push degrades to pull; local edit preserved uncommitted, unpushed)"
  else
    fail "9 read-only node" "$detail"
  fi
}

# ===========================================================================
# 10. never blocks: unreachable remote still exits 0, never times out
# ===========================================================================
test_never_blocks() {
  local base="$WORK/t10" nodeA
  make_world "$base"
  nodeA="$base/nodeA"
  git -C "$nodeA" remote set-url origin "ssh://git@192.0.2.1/nonexistent.git"

  local mode
  for mode in pull push; do
    local start dur rc
    start=$(date +%s)
    run_sync "$nodeA" "$mode" "$SYNC_BUDGET" >/dev/null 2>&1
    rc=$?
    dur=$(( $(date +%s) - start ))
    if [ "$rc" -eq 124 ]; then
      fail "10 never blocks ($mode)" "TIMED OUT (rc=124) after ${dur}s - sync hung"
    elif [ "$rc" -ne 0 ]; then
      fail "10 never blocks ($mode)" "unexpected exit code $rc after ${dur}s"
    else
      pass "10 never blocks ($mode): exit 0 in ${dur}s against an unreachable remote"
    fi
  done
}

# ===========================================================================
# 11. exit 0 always: not a git repo at all
# ===========================================================================
test_not_a_git_repo() {
  local base="$WORK/t11"
  mkdir -p "$base/scripts"
  cp "$SYNC_SRC" "$base/scripts/$SYNC_BASENAME"
  chmod +x "$base/scripts/$SYNC_BASENAME"

  local mode
  for mode in pull push; do
    run_sync "$base" "$mode" >/tmp/engram_t11_out.$$ 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
      pass "11 not a git repo ($mode): exit 0, no crash"
    else
      fail "11 not a git repo ($mode)" "exit code $rc; output: $(cat /tmp/engram_t11_out.$$)"
    fi
    rm -f /tmp/engram_t11_out.$$
  done
}

# ===========================================================================
# 12. allowlist conf: scripts/sync-paths.conf drives what syncs; unsafe entries ignored
# ===========================================================================
test_allowlist_conf() {
  local base="$WORK/t12" origin nodeA
  make_world "$base"
  origin="$base/origin.git"; nodeA="$base/nodeA"

  cat > "$nodeA/scripts/sync-paths.conf" <<'EOF'
# test conf — default list plus an extra folder
index.md
projects
global
inbox
archive
vault    # trailing comment
/etc
../escape
EOF
  mkdir -p "$nodeA/vault"
  echo "deep archive note" > "$nodeA/vault/v.md"
  echo "echo evil" > "$nodeA/scripts/evil2.sh"

  q run_sync "$nodeA" push

  local ok=1 detail=""
  git -C "$origin" show main:vault/v.md 2>/dev/null | grep -q "deep archive note" || { ok=0; detail="$detail conf-added vault/ NOT committed;"; }
  git -C "$origin" show main:scripts/evil2.sh >/dev/null 2>&1 && { ok=0; detail="$detail scripts/evil2.sh committed (conf must not widen to scripts/);"; }
  git -C "$origin" show main:scripts/sync-paths.conf >/dev/null 2>&1 && { ok=0; detail="$detail the conf itself was committed (it is code);"; }

  if [ "$ok" = 1 ]; then
    pass "12 allowlist conf (vault/ synced via conf; scripts/ and the conf itself still excluded; unsafe entries ignored)"
  else
    fail "12 allowlist conf" "$detail"
  fi
}

# ===========================================================================
# 13. secret scan marker: engram:not-a-secret line is exempt; unmarked twin still refused
# ===========================================================================
test_secret_marker() {
  local base="$WORK/t13a" origin nodeA
  make_world "$base"
  origin="$base/origin.git"; nodeA="$base/nodeA"

  printf '\n- API Token: cfat_REDACTED_PLACEHOLDER_1234 <!-- engram:not-a-secret -->\n' >> "$nodeA/projects/x.md"
  q run_sync "$nodeA" push

  local ok=1 detail=""
  git -C "$origin" show main:projects/x.md 2>/dev/null | grep -q "engram:not-a-secret" || { ok=0; detail="$detail marked line did NOT commit;"; }
  [ -f "$nodeA/ALERT.md" ] && { ok=0; detail="$detail ALERT.md raised despite marker;"; }
  if [ "$ok" = 1 ]; then
    pass "13a secret marker (marked false-positive line commits, no alert)"
  else
    fail "13a secret marker (marked line)" "$detail"
  fi

  local base2="$WORK/t13b" origin2 nodeA2
  make_world "$base2"
  origin2="$base2/origin.git"; nodeA2="$base2/nodeA"

  printf '\n- API Token: cfat_REDACTED_PLACEHOLDER_1234\n' >> "$nodeA2/projects/x.md"
  q run_sync "$nodeA2" push

  local ok2=1 detail2=""
  git -C "$origin2" show main:projects/x.md 2>/dev/null | grep -q "cfat_REDACTED" && { ok2=0; detail2="$detail2 unmarked credential-like line LEAKED;"; }
  [ -f "$nodeA2/ALERT.md" ] || { ok2=0; detail2="$detail2 ALERT.md missing;"; }
  if [ -f "$nodeA2/ALERT.md" ] && ! grep -q "engram:not-a-secret" "$nodeA2/ALERT.md"; then
    ok2=0; detail2="$detail2 alert does not name the marker escape hatch;"
  fi
  if [ "$ok2" = 1 ]; then
    pass "13b secret marker (unmarked twin still refused; alert names the marker)"
  else
    fail "13b secret marker (unmarked line)" "$detail2"
  fi
}

# ===========================================================================
# 14. no origin remote: exit 0, NOT CONNECTED warning on stdout, state err
# ===========================================================================
test_no_origin() {
  local base="$WORK/t14" nodeA
  make_world "$base"
  nodeA="$base/nodeA"
  q git -C "$nodeA" remote remove origin

  local mode
  for mode in pull push; do
    echo "local edit" > "$nodeA/projects/x.md"
    local out rc
    out="$(run_sync "$nodeA" "$mode")"
    rc=$?
    local ok=1 detail=""
    [ "$rc" -eq 0 ] || { ok=0; detail="$detail rc=$rc (expected 0);"; }
    printf '%s' "$out" | grep -q "NOT CONNECTED" || { ok=0; detail="$detail stdout lacks NOT CONNECTED warning (got: $out);"; }
    case "$(cat "$nodeA/.git/engram-state" 2>/dev/null)" in
      err\ *no\ origin*) : ;;
      *) ok=0; detail="$detail engram-state not 'err ... no origin ...';" ;;
    esac
    if [ "$ok" = 1 ]; then
      pass "14 no origin remote ($mode): exit 0, loud warning, state err"
    else
      fail "14 no origin remote ($mode)" "$detail"
    fi
  done
}

# ===========================================================================
# 15. consolidate nudge: stale log nudges on successful pull; fresh log stays quiet
# ===========================================================================
test_consolidate_nudge() {
  local base="$WORK/t15" nodeA
  make_world "$base"
  nodeA="$base/nodeA"

  printf '# consolidate log\n\n- 2020-01-01 nodea\n' > "$nodeA/archive/consolidate-log.md"
  local out
  out="$(run_sync "$nodeA" pull)"
  local ok=1 detail=""
  printf '%s' "$out" | grep -qi "consolidat" || { ok=0; detail="$detail stale log produced no nudge (got: $out);"; }
  if [ "$ok" = 1 ]; then
    pass "15a consolidate nudge (stale log -> reminder printed on pull)"
  else
    fail "15a consolidate nudge (stale)" "$detail"
  fi

  printf '# consolidate log\n\n- %s nodea\n' "$(date -u +%Y-%m-%d)" > "$nodeA/archive/consolidate-log.md"
  out="$(run_sync "$nodeA" pull)"
  local ok2=1 detail2=""
  printf '%s' "$out" | grep -qi "consolidat" && { ok2=0; detail2="$detail2 fresh log still nudged (got: $out);"; }
  if [ "$ok2" = 1 ]; then
    pass "15b consolidate nudge (fresh log -> quiet)"
  else
    fail "15b consolidate nudge (fresh)" "$detail2"
  fi
}

# ===========================================================================
main() {
  echo "== engram sync contract tests (SYNC_IMPL=$SYNC_IMPL) =="
  echo "impl under test: $SYNC_SRC"
  echo "scratch dir:     $WORK"
  echo

  test_push_basic
  test_pull_basic
  test_allowlist
  test_secret_scan
  test_union_merge
  test_conflict_escalation
  test_alert_surfaces_on_pull
  test_lock
  test_readonly
  test_never_blocks
  test_not_a_git_repo
  test_allowlist_conf
  test_secret_marker
  test_no_origin
  test_consolidate_nudge

  echo
  echo "== summary: $PASS passed, $FAIL failed (of $((PASS+FAIL)) checks) =="
  if [ "$FAIL" -gt 0 ]; then
    echo "FAILED:"
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
  fi
  exit 0
}
main
