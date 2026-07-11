<#
engram doctor (Windows) — health check for one node. Read-only: makes no changes.
Parity target: doctor.sh (10 checks). usage: powershell -NoProfile -ExecutionPolicy Bypass -File doctor.ps1
exit 0 = all checks passed. exit 1 = at least one FAIL.
#>
# Deliberately NOT 'Stop': a diagnostic script must run every check and reach the summary
# even when one check's own command errors — 'Continue' plus explicit try/catch /
# -ErrorAction SilentlyContinue on the handful of calls that can throw gets that.
$ErrorActionPreference = 'Continue'

$repo      = Split-Path -Parent $PSScriptRoot
$claudeDir = Join-Path $env:USERPROFILE '.claude'
Set-Location -Path $repo

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
    } else {
        Test-Fail "origin NOT reachable (git ls-remote failed or timed out)"
    }
} else {
    Test-Fail "origin: no remote named 'origin' configured"
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
$skillsSrc = Join-Path $repo '.claude\skills'
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
    Test-Warn "no .claude/skills directory in repo - nothing to check"
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
