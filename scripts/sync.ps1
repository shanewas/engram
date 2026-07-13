# engram sync (Windows) - see docs/sync-contract.md (normative spec; that file is the
# source of truth - if this script and the doc ever disagree, the doc wins and this is a
# bug). scripts/sync.sh is the reference implementation; both must behave identically.
#
# Invariant: every code path below ends in `exit 0`. This script must never block,
# hang, or crash a Claude Code session, no matter how badly the sync itself goes.
# No Start-Job/timeout wrappers (contract section 1): killing a wrapper orphans git.exe
# and leaves index.lock behind. Hangs are prevented by the env/config guards instead.
#
# usage: powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 [pull|push]   (default: pull)
param([string]$Mode = 'pull')
$ErrorActionPreference = 'SilentlyContinue'

# --- 0. locate repo root, bail out fast and quietly if this isn't a real checkout ---
$repo = Split-Path -Parent $PSScriptRoot
if (-not $repo -or -not (Test-Path (Join-Path $repo '.git'))) { exit 0 }
Set-Location $repo
if ($Mode -ne 'pull' -and $Mode -ne 'push') { $Mode = 'pull' }

$LockFile       = Join-Path $repo '.git\engram-sync.lock'
$StateFile      = Join-Path $repo '.git\engram-state'
$AlertFile      = Join-Path $repo 'ALERT.md'
$ReadOnlyMarker = Join-Path $repo '.git\engram-readonly'
$StaleSecs      = 300
$NudgeDays      = 7

# section 3 commit allowlist: read from scripts/sync-paths.conf (one path per
# line, '#' comments). The conf lives under scripts/ = code, so changing WHAT
# syncs still requires a deliberate manual commit. Absolute/drive-rooted paths
# and '..' entries are ignored; missing/empty conf falls back to the default.
$AllowlistDefault = @('index.md', 'projects', 'global', 'inbox', 'archive')
$AllowlistConf    = Join-Path $repo 'scripts\sync-paths.conf'
$Allowlist = @()
if (Test-Path $AllowlistConf) {
    foreach ($line in @(Get-Content $AllowlistConf 2>$null)) {
        $p = (([string]$line) -replace '#.*$', '').Trim()
        if (-not $p) { continue }
        if ($p.StartsWith('/') -or $p.StartsWith('\') -or $p -match '^[A-Za-z]:' -or $p -match '\.\.') { continue }
        $Allowlist += $p
    }
}
if ($Allowlist.Count -eq 0) { $Allowlist = $AllowlistDefault }

# --- section 1: guards - apply to every remote git operation ---
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE     = 'never'
$env:GIT_SSH_COMMAND     = 'ssh -o BatchMode=yes -o ConnectTimeout=10'

# per-invocation config for remote ops (pull/push); local-only git commands don't need it.
function Invoke-GitRemote { & git -c credential.interactive=false -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 @args }

function Get-IsoNow { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }

# All engram-written files are UTF-8 WITHOUT BOM (PS 5.1 Set-Content -Encoding UTF8 adds one).
function Write-NoBom([string]$Path, [string]$Text) {
    try { [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false)) } catch {}
}

# hostname: external command resolved via PATH (test harness shims it), never
# $env:COMPUTERNAME. Sanitized: lowercase, anything not [a-z0-9-] becomes '-'.
$rawHost  = (& hostname 2>$null | Select-Object -First 1)
$NodeName = ''
if ($rawHost) { $NodeName = [regex]::Replace(([string]$rawHost).Trim().ToLower(), '[^a-z0-9-]', '-') }
if (-not $NodeName) { $NodeName = 'unknown-host' }

function Set-StateOk  { Write-NoBom $StateFile ("ok {0}`n" -f (Get-IsoNow)) }
function Set-StateErr([string]$Reason) { Write-NoBom $StateFile ("err {0} {1}`n" -f (Get-IsoNow), $Reason) }

function Get-Snip([string]$s) { if ($s -and $s.Length -gt 200) { $s.Substring(0, 200) } else { $s } }

# --- section 2: lock - .git/engram-sync.lock holds "<pid> <iso8601>" ---
#   held (< 5 min old) -> exit 0 immediately, do nothing else
#   stale (>= 5 min, or unparsable timestamp) -> steal it
#   released in finally, only if we own it
$script:LockOurs = $false
function Get-EngramLock {
    try {
        # CreateNew = atomic O_EXCL-style create: two concurrent syncs can't both win.
        $fs = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("$PID $(Get-IsoNow)`n")
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Close()
        $script:LockOurs = $true
        return $true
    } catch {}
    if (-not (Test-Path $LockFile)) { return $false }
    $age = [double]::MaxValue   # unparsable content -> treated as infinitely old -> steal
    try {
        $tokens = ((Get-Content $LockFile -Raw) -split '\s+')
        if ($tokens.Length -ge 2 -and $tokens[1]) {
            $ts  = [DateTimeOffset]::Parse($tokens[1], [System.Globalization.CultureInfo]::InvariantCulture)
            $age = ([DateTimeOffset]::UtcNow - $ts.ToUniversalTime()).TotalSeconds
        }
    } catch { $age = [double]::MaxValue }
    if ($age -gt $StaleSecs) {
        Write-NoBom $LockFile "$PID $(Get-IsoNow)`n"
        $script:LockOurs = $true
        return $true
    }
    return $false
}

# --- self-heal: a previous run that crashed mid-rebase leaves one of these behind ---
function Repair-Rebase {
    if ((Test-Path '.git\rebase-merge') -or (Test-Path '.git\rebase-apply')) {
        & git rebase --abort 2>$null | Out-Null
    }
}

# --- section 6: skills refresh - real directories only, never symlinks/junctions ---
# (Claude Code's skill discovery does not follow links and silently fails to load them.)
function Update-Skills {
    if (-not $env:USERPROFILE) { return }
    $src = Join-Path $repo '.claude\skills'
    if (-not (Test-Path $src)) { return }
    $dstRoot = Join-Path $env:USERPROFILE '.claude\skills'
    New-Item -ItemType Directory -Force -Path $dstRoot 2>$null | Out-Null
    foreach ($d in @(Get-ChildItem -Path $src -Directory 2>$null)) {
        $dst = Join-Path $dstRoot $d.Name
        try {
            if (Test-Path -LiteralPath $dst) {
                $item = Get-Item -Force -LiteralPath $dst
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    # delete only the link node - recursing through a junction deletes the real source
                    [System.IO.Directory]::Delete($dst, $false)
                } else {
                    Remove-Item -LiteralPath $dst -Recurse -Force
                }
            }
            Copy-Item -LiteralPath $d.FullName -Destination $dst -Recurse -Force
        } catch {}
    }
}

# --- section 5: escalation - this node holds commit(s) it cannot get to origin/main ---
function Invoke-Escalate([string]$Reason) {
    $branch = "conflict/$NodeName"
    $out = (Invoke-GitRemote push --force origin "HEAD:$branch" 2>&1 | Out-String)
    $rc = $LASTEXITCODE
    $lines = @('# Engram sync ALERT', '')
    if ($rc -eq 0) {
        $lines += @(
            "**Your memory could not sync - but nothing is lost.** This machine's"
            'changes are parked safely on the hub. To fix it, open Claude Code and'
            'say: "consolidate memory".'
            ''
        )
    } else {
        $lines += @(
            '**Your memory could not sync, and parking the changes on the hub also'
            'failed - they exist only on this machine right now.** Nothing is'
            'deleted. Check your internet connection / git login, then re-run sync.'
            ''
        )
    }
    $lines += @(
        'Details (for the fix):'
        ''
        "- node: $NodeName"
        "- time: $(Get-IsoNow)"
        "- reason: $Reason"
        ''
    )
    if ($rc -eq 0) {
        $lines += @(
            'This node has commit(s) that could not be merged into origin/main.'
            ('They are safe: force-pushed to the scratch branch `{0}` on origin.' -f $branch)
            ''
            ('Action required: run the consolidate skill to merge `{0}` into main, then delete the branch.' -f $branch)
        )
    } else {
        $lines += @(
            'This node has commit(s) that could not be merged into origin/main, AND'
            ('the fallback push to `{0}` also failed:' -f $branch)
            ''
            '```'
            $out.TrimEnd()
            '```'
            ''
            'These commits currently exist ONLY on this node. Check connectivity/auth and re-run sync.'
        )
    }
    Write-NoBom $AlertFile (($lines -join "`n") + "`n")
    Set-StateErr $Reason
}

# --- shared pull-rebase step. Returns 0 ok, 1 conflict (aborted), 2 other failure ---
$script:PullOutput = ''
function Invoke-PullRebase {
    $script:PullOutput = (Invoke-GitRemote pull --rebase --autostash 2>&1 | Out-String)
    $rc = $LASTEXITCODE
    if ($rc -eq 0) { return 0 }
    if ((Test-Path '.git\rebase-merge') -or (Test-Path '.git\rebase-apply')) {
        & git rebase --abort 2>$null | Out-Null
        return 1
    }
    return 2
}

# --- section 7: secret scan - scans ADDED lines of the staged diff only ---
function Get-SecretHits {
    $diff  = & git diff --cached -U0 --text 2>$null
    # section 7 false-positive escape hatch: a line tagged 'engram:not-a-secret'
    # is excluded from the scan. The sanctioned path for already-redacted text -
    # the alternative is people learning to bypass the scan entirely.
    $added = @($diff | Where-Object { $_ -match '^\+' -and $_ -notmatch '^\+\+\+' -and $_ -notmatch 'engram:not-a-secret' })
    $hits  = New-Object System.Collections.Generic.List[string]
    if ($added.Count -eq 0) { return $hits }
    $blob = $added -join "`n"
    # structural patterns are case-SENSITIVE per the contract: -cmatch, not -match
    $patterns = @(
        @{ Rx = 'AKIA[0-9A-Z]{16}';                                Label = 'AWS access key' }
        @{ Rx = 'gh[pousr]_[A-Za-z0-9]{36}';                       Label = 'GitHub token' }
        @{ Rx = 'xox[baprs]-[A-Za-z0-9-]{10,}';                    Label = 'Slack token' }
        @{ Rx = 'sk-[A-Za-z0-9]{20,}';                             Label = 'OpenAI-style key' }
        @{ Rx = 'sk-ant-[A-Za-z0-9_-]{20,}';                       Label = 'Anthropic key' }
        @{ Rx = 'AIza[0-9A-Za-z_-]{35}';                           Label = 'Google API key' }
        @{ Rx = '-----BEGIN [A-Z ]*PRIVATE KEY-----';              Label = 'private key block' }
        @{ Rx = 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.';     Label = 'JWT' }
    )
    foreach ($p in $patterns) { if ($blob -cmatch $p.Rx) { [void]$hits.Add($p.Label) } }
    # generic pattern is case-insensitive per the spec's (?i)
    if ($blob -imatch '(password|passwd|secret|token|api[_-]?key)\s*[:=]\s*\S{12,}') {
        [void]$hits.Add('generic credential-like string')
    }
    return $hits
}

# labels only - never write the matched secret text itself into the alert
function Write-SecretAlert($Labels) {
    $lines = @(
        '# Engram sync ALERT'
        ''
        '**Upload stopped: something that looks like a password or key was found'
        'in your changes.** Nothing was uploaded and nothing is lost - the change'
        'is still in your files, just not synced yet.'
        ''
        'Details (for the fix):'
        ''
        "- node: $NodeName"
        "- time: $(Get-IsoNow)"
        '- reason: secret scan matched staged changes; commit refused'
        ''
        'Patterns matched:'
    )
    foreach ($l in $Labels) { $lines += "- $l" }
    $lines += @(
        ''
        'The change was NOT committed and remains unstaged in your working tree.'
        'To fix, open the file and either:'
        ''
        '- remove the secret (real secrets never belong in memory), or'
        '- if the line is a false alarm (e.g. already-redacted text), append'
        '  `<!-- engram:not-a-secret -->` to that exact line.'
        ''
        'Then re-run: scripts\sync.ps1 push (Linux: scripts/sync.sh push).'
        'Never work around this scan by committing manually.'
    )
    Write-NoBom $AlertFile (($lines -join "`n") + "`n")
}

# Maintenance nudge: the consolidate skill appends "- YYYY-MM-DD <host>" to
# archive/consolidate-log.md on every run (synced - the newest date is
# cluster-wide). Printed on successful pull only: that stdout reaches the
# session context. No log file = never consolidated = stay quiet (fresh setup).
function Show-ConsolidateNudge {
    $log = Join-Path $repo 'archive\consolidate-log.md'
    if (-not (Test-Path $log)) { return }
    $last = $null
    foreach ($line in @(Get-Content $log 2>$null)) {
        if (([string]$line) -match '^- (\d{4}-\d{2}-\d{2})') { $last = $Matches[1] }
    }
    if (-not $last) { return }
    try {
        $ts = [DateTimeOffset]::Parse(($last + 'T00:00:00Z'), [System.Globalization.CultureInfo]::InvariantCulture)
        $days = [int][Math]::Floor(([DateTimeOffset]::UtcNow - $ts.ToUniversalTime()).TotalDays)
        if ($days -ge $NudgeDays) {
            Write-Output ('[engram] Last memory consolidation was {0} days ago - say "consolidate memory" when convenient.' -f $days)
        }
    } catch {}
}

# --- section 4: modes ---
# read-only node: push degrades to pull (checked before the lock, contract push step 0)
if ($Mode -eq 'push' -and (Test-Path $ReadOnlyMarker)) { $Mode = 'pull' }

try {
    if (-not (Get-EngramLock)) { exit 0 }
    Repair-Rebase

    # section 4 step 0 (both modes) - a node with no 'origin' remote cannot sync
    # at all. That is a standing configuration failure, not a transient one:
    # warn loudly (stdout lands in the session context via the SessionStart
    # hook), record err, and stop. Silence here would be exactly the "silently
    # diverges" failure the contract forbids.
    & git remote get-url origin 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Output @'
[engram] NOT CONNECTED: this memory repo has no 'origin' remote, so nothing
syncs to or from your other machines. Facts saved here stay on this machine
only. Fix it once: create a private GitHub repo, then run
    git remote add origin <your-private-repo-url>
from the repo root and re-run sync - or run scripts\setup.ps1 for a guided setup.
'@
        Set-StateErr 'no origin remote configured'
    }
    elseif ($Mode -eq 'pull') {
        $r = Invoke-PullRebase
        if ($r -eq 0) {
            Update-Skills
            if (Test-Path $AlertFile) { Remove-Item $AlertFile -Force 2>$null }
            Set-StateOk
            Show-ConsolidateNudge
        } elseif ($r -eq 1) {
            Invoke-Escalate 'pull: rebase onto origin/main conflicted'
        } else {
            Set-StateErr ("pull failed: {0}" -f (Get-Snip $script:PullOutput))
        }
    } else {
        # push
        foreach ($p in $Allowlist) {
            if (Test-Path $p) { & git add -- $p 2>$null | Out-Null }
        }
        $hits = Get-SecretHits
        if ($hits.Count -gt 0) {
            & git reset 2>$null | Out-Null
            Write-SecretAlert $hits
            Set-StateErr 'secret scan hit'
        } else {
            $proceed = $true
            & git diff --cached --quiet 2>$null
            if ($LASTEXITCODE -ne 0) {
                $commitOut = (& git commit -q -m "sync(${NodeName}): $(Get-IsoNow)" 2>&1 | Out-String)
                $rc = $LASTEXITCODE
                if ($rc -ne 0) {
                    $proceed = $false
                    Set-StateErr ("push: commit failed: {0}" -f (Get-Snip $commitOut))
                }
            }
            if ($proceed) {
                $r = Invoke-PullRebase
                if ($r -eq 0) {
                    $pushOut = (Invoke-GitRemote push 2>&1 | Out-String)
                    $rc = $LASTEXITCODE
                    if ($rc -eq 0) {
                        if (Test-Path $AlertFile) { Remove-Item $AlertFile -Force 2>$null }
                        Set-StateOk
                    } else {
                        Invoke-Escalate ("push failed: {0}" -f (Get-Snip $pushOut))
                    }
                } elseif ($r -eq 1) {
                    Invoke-Escalate 'push: pre-push rebase onto origin/main conflicted'
                } else {
                    Set-StateErr ("push: pre-push pull failed: {0}" -f (Get-Snip $script:PullOutput))
                }
            }
        }
    }
} catch {
    Set-StateErr ("unexpected: {0}" -f $_.Exception.Message)
} finally {
    if ($script:LockOurs -and (Test-Path $LockFile)) { Remove-Item $LockFile -Force 2>$null }
}

# Surface any outstanding alert to stdout. SessionStart hook stdout is injected into the
# session context - this is how the model itself learns the node is broken.
if (Test-Path $AlertFile) {
    $alert = Get-Content $AlertFile -Raw 2>$null
    if ($alert) { Write-Output $alert }
}

exit 0
