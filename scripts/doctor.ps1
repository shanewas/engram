<#
engram doctor (Windows) — health check for one node. Read-only: makes no changes.
Parity target: doctor.sh. usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File doctor.ps1            full checks
  powershell -NoProfile -ExecutionPolicy Bypass -File doctor.ps1 -Status    plain-language summary
exit 0 = all checks passed (or -Status). exit 1 = at least one FAIL.
#>
param([switch]$Status)
# Deliberately NOT 'Stop': a diagnostic script must run every check and reach the summary
# even when one check's own command errors — 'Continue' plus explicit try/catch /
# -ErrorAction SilentlyContinue on the handful of calls that can throw gets that.
$ErrorActionPreference = 'Continue'

$repo      = Split-Path -Parent $PSScriptRoot
$claudeDir = Join-Path $env:USERPROFILE '.claude'
Set-Location -Path $repo

# --- -Status: the non-technical view. Plain sentences, no check IDs. ----------
function Get-HumanAge([int]$Seconds) {
    if     ($Seconds -lt 120)    { 'moments' }
    elseif ($Seconds -lt 7200)   { '{0} minutes' -f [int][Math]::Floor($Seconds / 60) }
    elseif ($Seconds -lt 172800) { '{0} hours'   -f [int][Math]::Floor($Seconds / 3600) }
    else                         { '{0} days'    -f [int][Math]::Floor($Seconds / 86400) }
}

if ($Status) {
    Write-Host "Engram memory status - $repo"
    Write-Host ''
    $stateFile = Join-Path $repo '.git\engram-state'
    if (Test-Path (Join-Path $repo 'ALERT.md')) {
        Write-Host '[!] Needs attention: a sync problem is flagged on this machine.'
        Write-Host '    Nothing is lost. Open Claude Code and say "consolidate memory".'
    } elseif (Test-Path $stateFile) {
        $parts = ((Get-Content $stateFile -Raw -ErrorAction SilentlyContinue) + '').Trim() -split '\s+', 3
        $kind = if ($parts.Length -ge 1) { $parts[0] } else { '' }
        $ts   = if ($parts.Length -ge 2) { $parts[1] } else { '' }
        $age = -1
        try { $age = [int]([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($ts).ToUniversalTime()).TotalSeconds } catch {}
        if ($kind -eq 'ok' -and $age -ge 0 -and $age -le 5400) {
            Write-Host ('[OK] Healthy. This machine last synced {0} ago.' -f (Get-HumanAge $age))
        } elseif ($kind -eq 'ok') {
            Write-Host ('[!] This machine last synced {0} ago - longer than expected.' -f (Get-HumanAge $age))
            Write-Host '    Try: scripts\sync.ps1 push   (then run doctor again)'
        } else {
            Write-Host '[!] The last sync attempt failed. Run doctor.ps1 without -Status for details.'
        }
    } else {
        Write-Host '[!] Sync has never run on this machine - it is not connected yet.'
        Write-Host '    Run: scripts\setup.ps1   for a guided setup.'
    }
    Write-Host ''
    Write-Host 'Machines seen in recent sync history:'
    $seen = @{}
    foreach ($l in @(& git log --format='%s|%ct' -200 2>$null)) {
        if (([string]$l) -match '^sync\(([^)]+)\)[^|]*\|(\d+)$') {
            $hostName = $Matches[1]
            if (-not $seen.ContainsKey($hostName)) {
                $seen[$hostName] = $true
                $ageSec = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$Matches[2])
                Write-Host ('  - {0} last synced {1} ago' -f $hostName, (Get-HumanAge $ageSec))
            }
        }
    }
    exit 0
}

$failures = 0
function Test-Pass([string]$Msg) { Write-Host "[PASS] $Msg" }
function Test-Fail([string]$Msg) { Write-Host "[FAIL] $Msg"; $script:failures++ }
function Test-Warn([string]$Msg) { Write-Host "[WARN] $Msg" }
function Test-Info([string]$Msg) { Write-Host "[INFO] $Msg" }

Write-Host "engram doctor - $repo"
Write-Host ""

# 1. repo is a git repository -------------------------------------------------
if (Test-Path (Join-Path $repo '.git')) {
    Test-Pass "repo: $repo is a git repository"
} else {
    Test-Fail "repo: $repo is NOT a git repository"
}

# 2. origin configured + reachable ---------------------------------------------
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE     = 'never'
$env:GIT_SSH_COMMAND     = 'ssh -o BatchMode=yes -o ConnectTimeout=10'

$originUrl = git remote get-url origin 2>$null
if ($LASTEXITCODE -eq 0 -and $originUrl) {
    Test-Pass "origin configured: $originUrl"
    git -c credential.interactive=false -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 ls-remote --exit-code origin *> $null
    if ($LASTEXITCODE -eq 0) {
        Test-Pass "origin reachable (git ls-remote)"
        # a hub with no main branch means this repo has NEVER been pushed: every
        # memory written so far exists on this machine only. Loud failure, not info.
        git -c credential.interactive=false -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 ls-remote --exit-code origin main *> $null
        if ($LASTEXITCODE -eq 0) {
            Test-Pass "hub has a main branch (repo has been pushed at least once)"
            $ahead = git rev-list --count origin/main..HEAD 2>$null
            if ($LASTEXITCODE -eq 0 -and $ahead -and [int]$ahead -gt 0) {
                Test-Warn "this node is $ahead commit(s) ahead of origin/main - a sync push should drain this; if it persists, run consolidate"
            }
        } else {
            Test-Fail "hub has NO main branch - this repo has never been pushed; memory is NOT backed up (run a sync push, or scripts\setup.ps1)"
        }
    } else {
        Test-Fail "origin NOT reachable (git ls-remote failed or timed out)"
    }
} else {
    Test-Fail "origin: no remote named 'origin' configured - memory stays on this machine only (run scripts\setup.ps1)"
}

# 3. CLAUDE.md import ------------------------------------------------------------
$userMd = Join-Path $claudeDir 'CLAUDE.md'
$importLineMatch = $null
if (Test-Path $userMd) {
    $importLineMatch = Select-String -Path $userMd -Pattern 'engram[/\\]index\.md' -ErrorAction SilentlyContinue | Select-Object -First 1
}
if ($importLineMatch) {
    Test-Pass "CLAUDE.md: import line present in $userMd"
    if ($importLineMatch.Line -match '\\') {
        Test-Warn "CLAUDE.md: import line uses backslashes (known Claude Code path-parsing bug) -> $($importLineMatch.Line.Trim())"
    }
} else {
    Test-Fail "CLAUDE.md: no engram/index.md import found in $userMd"
}
$repoIndex = Join-Path $repo 'index.md'
if (Test-Path $repoIndex) {
    Test-Pass "CLAUDE.md: import target $repoIndex exists"
} else {
    Test-Fail "CLAUDE.md: import target $repoIndex is MISSING"
}

# 4. settings.json hooks ----------------------------------------------------------
$settingsPath = Join-Path $claudeDir 'settings.json'
$settingsObj = $null
$settingsValid = $false
if (Test-Path $settingsPath) {
    try {
        $raw = Get-Content -Path $settingsPath -Raw -ErrorAction Stop
        $settingsObj = $raw | ConvertFrom-Json -ErrorAction Stop
        $settingsValid = $true
    } catch {
        $settingsValid = $false
    }
}
if ($settingsValid) {
    Test-Pass "settings.json: valid JSON ($settingsPath)"

    function Test-EngramHookPresent($EventEntries) {
        foreach ($entry in @($EventEntries)) {
            foreach ($h in @($entry.hooks)) {
                if ($h -and $h.command -and ($h.command -like '*sync.ps1*')) { return $true }
            }
        }
        return $false
    }

    $sessionStartOk = if ($settingsObj.hooks -and $settingsObj.hooks.SessionStart) { Test-EngramHookPresent $settingsObj.hooks.SessionStart } else { $false }
    $sessionEndOk   = if ($settingsObj.hooks -and $settingsObj.hooks.SessionEnd)   { Test-EngramHookPresent $settingsObj.hooks.SessionEnd }   else { $false }

    if ($sessionStartOk) { Test-Pass "settings.json: SessionStart engram hook present" } else { Test-Fail "settings.json: SessionStart engram hook MISSING" }
    if ($sessionEndOk)   { Test-Pass "settings.json: SessionEnd engram hook present" }   else { Test-Fail "settings.json: SessionEnd engram hook MISSING" }
} else {
    Test-Fail "settings.json: missing, unreadable, or not valid JSON ($settingsPath)"
}

# 5. skills are real dirs (not symlinks/junctions), each with SKILL.md -------------
$skillsSrc = Join-Path $repo 'plugins\engram\skills'
if (Test-Path $skillsSrc) {
    Get-ChildItem -Path $skillsSrc -Directory | ForEach-Object {
        $name   = $_.Name
        $target = Join-Path $claudeDir "skills\$name"
        if (Test-Path -LiteralPath $target) {
            $item = Get-Item -Force -LiteralPath $target
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                Test-Fail "skill '$name': $target is a SYMLINK/JUNCTION (Claude Code will not load it)"
            } elseif (Test-Path (Join-Path $target 'SKILL.md')) {
                Test-Pass "skill '$name': real directory with SKILL.md"
            } else {
                Test-Fail "skill '$name': missing or has no SKILL.md at $target"
            }
        } else {
            Test-Fail "skill '$name': missing or has no SKILL.md at $target"
        }
    }
} else {
    Test-Warn "no plugins/engram/skills directory in repo - nothing to check"
}

# 6. scheduled task -----------------------------------------------------------------
try {
    $task = Get-ScheduledTask -TaskName 'EngramSync' -ErrorAction Stop
    Test-Pass "scheduled task: EngramSync exists (state: $($task.State))"
} catch {
    Test-Fail "scheduled task: EngramSync does NOT exist"
}

# 7. ALERT.md -------------------------------------------------------------------------
$alertPath = Join-Path $repo 'ALERT.md'
if (Test-Path $alertPath) {
    Test-Fail "ALERT.md present - this node flagged a problem"
    Write-Host "----- ALERT.md -----"
    Get-Content -Path $alertPath | ForEach-Object { Write-Host $_ }
    Write-Host "---------------------"
} else {
    Test-Pass "no ALERT.md - no outstanding issue flagged"
}

# 8. last sync state + age -------------------------------------------------------------
$stateFile = Join-Path $repo '.git\engram-state'
if (Test-Path $stateFile) {
    $line = Get-Content -Path $stateFile -Raw -ErrorAction SilentlyContinue
    if ($null -eq $line) { $line = '' }
    $parts  = $line.Trim() -split '\s+', 3
    $kind   = if ($parts.Length -ge 1) { $parts[0] } else { '' }
    $ts     = if ($parts.Length -ge 2) { $parts[1] } else { '' }
    $reason = if ($parts.Length -ge 3) { $parts[2] } else { '' }

    if ($kind -eq 'ok') {
        try {
            $parsedTs = [DateTimeOffset]::Parse($ts)
            $ageSec = [int]([DateTimeOffset]::UtcNow - $parsedTs.ToUniversalTime()).TotalSeconds
            if ($ageSec -le 5400) {
                Test-Pass "last sync: ok at $ts (${ageSec}s ago)"
            } else {
                Test-Fail "last sync: ok at $ts but STALE (${ageSec}s ago, > 90min)"
            }
        } catch {
            Test-Fail "last sync: unreadable state file content in $stateFile"
        }
    } elseif ($kind -eq 'err') {
        Test-Fail "last sync: err at $ts - $reason"
    } else {
        Test-Fail "last sync: unreadable state file content in $stateFile"
    }
} else {
    Test-Fail "last sync: no $stateFile yet - sync has never run on this node"
}

# 9. read-only push guard -----------------------------------------------------------------
$readonlyMarker = Join-Path $repo '.git\engram-readonly'
if (Test-Path $readonlyMarker) {
    $pushUrl = git remote get-url --push origin 2>$null
    if ($LASTEXITCODE -eq 0 -and $pushUrl -eq 'DISABLED') {
        Test-Pass "read-only: push URL disabled as expected"
    } else {
        Test-Fail "read-only: marker present but push URL is '$pushUrl', not DISABLED"
    }
} else {
    Test-Info "read-only: node is not marked read-only (no .git/engram-readonly)"
}

# 10. index.md size (warn only, does not fail the run) -----------------------------------
$indexPath = Join-Path $repo 'index.md'
if (Test-Path $indexPath) {
    $lineCount = @(Get-Content -Path $indexPath).Count
    if ($lineCount -gt 100) {
        Test-Warn "index.md is $lineCount lines (> 100) - consolidate skill should trim this"
    } else {
        Test-Pass "index.md is $lineCount lines (<= 100)"
    }
}

Write-Host ""
if ($failures -gt 0) {
    Write-Host "engram doctor: $failures check(s) FAILED"
    exit 1
} else {
    Write-Host "engram doctor: all checks passed"
    exit 0
}
