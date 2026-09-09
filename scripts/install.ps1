<#
Engram 2.0: Windows One-Command Installer
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 [-Remote <url>] [-ReadOnly]
  irm https://raw.githubusercontent.com/<you>/engram-memory/main/scripts/install.ps1 | iex
#>
param(
    [string]$Remote = "https://github.com/shanewas/engram-memory.git",
    [switch]$ReadOnly,
    [switch]$NoTask
)
$ErrorActionPreference = 'Stop'

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "       Engram 2.0: Personal Memory & Harness Installer       " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# 1. Resolve Target Directory
$engramDir = if ($env:ENGRAM_HOME) { $env:ENGRAM_HOME } else { Join-Path $env:USERPROFILE 'engram' }
Write-Host "[engram] Target directory: $engramDir"

# 2. Check Git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "[engram] Error: git is not installed or not in PATH." -ForegroundColor Red
    Write-Host "Please install Git for Windows (https://git-scm.com/) and rerun." -ForegroundColor Yellow
    exit 1
}

# 3. Check Python
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "[engram] Error: python is not installed or not in PATH." -ForegroundColor Red
    Write-Host "Please install Python 3.8+ and ensure 'Add to PATH' is checked." -ForegroundColor Yellow
    exit 1
}

# 4. Clone or update repository
if (-not (Test-Path (Join-Path $engramDir '.git'))) {
    Write-Host "[engram] Cloning repository from $Remote..."
    $env:GIT_TERMINAL_PROMPT = '1'
    git clone $Remote $engramDir
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[engram] Error: git clone failed." -ForegroundColor Red
        Write-Host "If this is a private repo, ensure you are authenticated (gh auth login / Git Credential Manager)." -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "[engram] Repository already exists at $engramDir"
}

# 5. Add bin to User PATH
$binPath = Join-Path $engramDir 'bin'
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -split ';' -notcontains $binPath) {
    Write-Host "[engram] Adding $binPath to User PATH..."
    $newPath = "$userPath;$binPath"
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    $env:Path = "$env:Path;$binPath"
    Write-Host "[engram] PATH updated. The 'engram' command is now available." -ForegroundColor Green
} else {
    Write-Host "[engram] $binPath is already in User PATH."
}

# 6. Secrets onboarding
$cfgDir = Join-Path $env:USERPROFILE '.config\dotfiles'
$secretsFile = Join-Path $cfgDir 'secrets.env'
if (-not (Test-Path $cfgDir)) {
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
}
if (-not (Test-Path $secretsFile)) {
    Write-Host "[engram] Creating template secrets file at $secretsFile..."
    $tmpl = @"
# Engram per-machine secrets (chmod 600, never committed)
GITHUB_TOKEN=  # engram:not-a-secret
MINIMAX_API_KEY=  # engram:not-a-secret
AGY_MCP_AUTH=  # engram:not-a-secret
"@
    Set-Content -Path $secretsFile -Value $tmpl -Encoding UTF8
    Write-Host "[engram] Note: Edit $secretsFile with your API keys as needed." -ForegroundColor Yellow
}

# 7. Dotfiles marker & Read-only flag
$marker = Join-Path $engramDir '.git\engram-apply-dotfiles'
if (-not (Test-Path $marker)) {
    New-Item -ItemType File -Path $marker -Force | Out-Null
}
if ($ReadOnly) {
    $roMarker = Join-Path $engramDir '.git\engram-readonly'
    New-Item -ItemType File -Path $roMarker -Force | Out-Null
    & git -C $engramDir remote set-url --push origin DISABLED
    Write-Host "[engram] Node marked as Read-Only."
}

# 8. Wire Agent Harnesses
Write-Host "`n[engram] Connecting agent harnesses..."
$cliPy = Join-Path $engramDir 'scripts\engram_cli.py'
& python -X utf8 $cliPy connect --all

# 9. Register 30-minute scheduled background task
if (-not $NoTask) {
    $taskName = "EngramSync"
    $vbsLauncher = Join-Path $engramDir 'scripts\sync-hidden.vbs'
    if (Test-Path $vbsLauncher) {
        $action = "wscript.exe `"$vbsLauncher`""
        schtasks.exe /create /tn $taskName /tr $action /sc minute /mo 30 /f 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[engram] Scheduled task 'EngramSync' registered (30-min background sync)." -ForegroundColor Green
        }
    }
}

# 10. Run Doctor
Write-Host "`n[engram] Running health check..."
& python -X utf8 $cliPy doctor

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "       Engram 2.0 Installation Complete!                    " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Run 'engram status' to inspect sync state and harnesses."
Write-Host "Restart any open terminals or agent sessions to refresh PATH."
