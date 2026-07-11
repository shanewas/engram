<#
Engram one-command install (Windows). Thin wrapper — no reimplementation of setup or
health-check logic, both of which live in setup-windows.ps1 / doctor.ps1.

  1. requires $repo (parent of scripts/) to be a git repo
  2. wires -Remote as 'origin' if not already configured (never overwrites a differing one)
  3. ensures the local branch is named main
  4. pushes to origin (skipped for -ReadOnly / when no origin is configured) — this is the
     one manual step that needs credentials; PLAN.md phase 1/3
  5. runs setup-windows.ps1, passing through -ReadOnly / -NoTask
  6. runs doctor.ps1 and propagates its exit code

usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File bootstrap.ps1 -Remote https://github.com/<you>/engram.git
  powershell -NoProfile -ExecutionPolicy Bypass -File bootstrap.ps1 -ReadOnly
#>
param(
    [string]$Remote,
    [switch]$ReadOnly,
    [switch]$NoTask
)
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1, under $ErrorActionPreference = 'Stop', turns a native command's
# stderr output into a *terminating* exception even when the caller redirects it with
# 2>$null (verified empirically). git routinely writes to stderr for perfectly expected,
# handled outcomes (e.g. "no such remote 'origin'"), so every git call that might
# legitimately fail as part of normal control flow goes through this wrapper instead of
# being called bare - it locally relaxes to 'Continue' just for the native call, then
# restores 'Stop'. $LASTEXITCODE still reflects git's real exit code afterward.
function Invoke-GitAllowFail {
    param([string[]]$GitArgs)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git @GitArgs
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

# --- 1. locate + require repo -------------------------------------------------
$repo = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $repo '.git'))) {
    Write-Host "[engram] $repo is not a git repository - aborting" -ForegroundColor Red
    exit 1
}
Set-Location -Path $repo

# --- 2. origin remote ----------------------------------------------------------
$currentOrigin = Invoke-GitAllowFail -GitArgs @('remote', 'get-url', 'origin') 2>$null
$hasOrigin = ($LASTEXITCODE -eq 0 -and $currentOrigin)
if ($Remote) {
    if (-not $hasOrigin) {
        Invoke-GitAllowFail -GitArgs @('remote', 'add', 'origin', $Remote) 2>$null | Out-Null
        Write-Host "[engram] origin added -> $Remote"
        $hasOrigin = $true
        $currentOrigin = $Remote
    } elseif ($currentOrigin -ne $Remote) {
        Write-Host "[engram] origin is already '$currentOrigin' (differs from -Remote '$Remote') - not changing; fix manually with 'git remote set-url origin <url>' if this is wrong" -ForegroundColor Yellow
    }
}

# --- 3. ensure branch main -------------------------------------------------------
$currentBranch = Invoke-GitAllowFail -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD') 2>$null
if ($LASTEXITCODE -eq 0 -and $currentBranch -and $currentBranch -ne 'main') {
    Invoke-GitAllowFail -GitArgs @('branch', '-M', 'main') 2>$null | Out-Null
    Write-Host "[engram] branch renamed to main (was '$currentBranch')"
}

# --- 4. push: the one manual step needing credentials -----------------------------
if (-not $ReadOnly -and $hasOrigin) {
    $env:GIT_TERMINAL_PROMPT = '0'
    Invoke-GitAllowFail -GitArgs @('-c', 'credential.interactive=false', 'push', '-u', 'origin', 'main')
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[engram] push to origin failed - this is the one manual step needing credentials; authenticate (e.g. Git Credential Manager / gh auth login) and rerun" -ForegroundColor Red
        exit 1
    }
    Write-Host "[engram] pushed -> origin main"
} elseif (-not $hasOrigin) {
    Write-Host "[engram] no origin remote configured (pass -Remote <url> on first run) - skipping push"
}

# --- 5. setup-windows.ps1 (pass through -ReadOnly / -NoTask) ---------------------
# Must splat a HASHTABLE, not a string array: @('-ReadOnly') splatted to a switch
# parameter does NOT bind (verified empirically - the callee sees $false regardless).
# Only named/hashtable splatting reliably forwards switches.
$flags = @{}
if ($ReadOnly) { $flags['ReadOnly'] = $true }
if ($NoTask)   { $flags['NoTask'] = $true }
& "$PSScriptRoot\setup-windows.ps1" @flags
if ($LASTEXITCODE -ne 0) {
    Write-Host "[engram] setup-windows.ps1 failed (exit $LASTEXITCODE)" -ForegroundColor Red
    exit $LASTEXITCODE
}

# --- 6. doctor.ps1 (propagate exit code — bootstrap is a setup tool, not a hook) --
& "$PSScriptRoot\doctor.ps1"
exit $LASTEXITCODE
