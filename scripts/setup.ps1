<#
engram guided setup (Windows) — asks a few plain questions, then wires this
machine. Wraps bootstrap.ps1 / setup-windows.ps1; no sync or setup logic is
reimplemented here.

Run it from inside a clone of your engram repo:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup.ps1

Interactive by design. For scripted/headless setup use bootstrap.ps1 directly.
#>
$ErrorActionPreference = 'Stop'

function Invoke-GitAllowFail {
    param([string[]]$GitArgs)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & git @GitArgs } finally { $ErrorActionPreference = $prevEap }
}

$repo = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $repo '.git'))) {
    Write-Host "[engram] $repo is not a git repository - clone your engram repo first, then run this from inside it" -ForegroundColor Red
    exit 1
}
Set-Location -Path $repo

if (-not [Environment]::UserInteractive -or ([Console]::IsInputRedirected)) {
    Write-Host '[engram] setup.ps1 is interactive and needs a console.'
    Write-Host '         For scripted setup use: bootstrap.ps1 -Remote <url> [-ReadOnly]'
    exit 1
}

function Read-YesNo([string]$Prompt, [string]$Default = 'y') {
    $hint = if ($Default -eq 'n') { '[y/N]' } else { '[Y/n]' }
    $r = Read-Host "$Prompt $hint"
    if (-not $r) { $r = $Default }
    return ($r -match '^(y|yes)$')
}

$rawHost  = (& hostname 2>$null | Select-Object -First 1)
$NodeName = if ($rawHost) { [regex]::Replace(([string]$rawHost).Trim().ToLower(), '[^a-z0-9-]', '-') } else { 'unknown-host' }
$Today    = [DateTime]::UtcNow.ToString('yyyy-MM-dd')

Write-Host ''
Write-Host '-- Engram setup ----------------------------------------------'
Write-Host 'This connects the memory folder at:'
Write-Host "    $repo"
Write-Host 'to your private hub on GitHub, so every machine shares one brain.'
Write-Host 'Three questions, then it wires itself. Nothing here needs git knowledge.'
Write-Host ''

# -- 0. cloud-sync folder check (OneDrive/Dropbox fight git for file locks) --
if ($repo -match 'OneDrive|Dropbox|Google Drive|GoogleDrive') {
    Write-Host '[!] This folder appears to be inside a cloud-sync folder (OneDrive/'
    Write-Host '    Dropbox/Google Drive). Two sync systems on the same folder fight'
    Write-Host '    each other: expect file locks and duplicated work. Recommended:'
    Write-Host '    move the clone outside the cloud-synced area, or exclude it there.'
    if (-not (Read-YesNo '    Continue here anyway?' 'n')) {
        Write-Host 'Stopped. Re-clone somewhere else and rerun.'
        exit 1
    }
}

# -- 1. the hub ---------------------------------------------------------------
$originUrl = Invoke-GitAllowFail -GitArgs @('remote', 'get-url', 'origin') 2>$null
if ($LASTEXITCODE -ne 0) { $originUrl = $null }
if ($originUrl) {
    Write-Host 'Q1. Hub: this machine is already pointed at:'
    Write-Host "    $originUrl"
    if (-not (Read-YesNo '    Keep using it?')) {
        $u = Read-Host '    Paste the correct repo URL'
        if ($u) { Invoke-GitAllowFail -GitArgs @('remote', 'set-url', 'origin', $u) | Out-Null; $originUrl = $u }
    }
} else {
    Write-Host 'Q1. Hub: your memory needs one private GitHub repo that all machines share.'
    if (Read-YesNo '    Do you already have one?' 'n') {
        $u = Read-Host '    Paste its URL (https://github.com/<you>/<repo>.git)'
        if (-not $u) { Write-Host 'No URL given - stopped.'; exit 1 }
        Invoke-GitAllowFail -GitArgs @('remote', 'add', 'origin', $u) 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Invoke-GitAllowFail -GitArgs @('remote', 'set-url', 'origin', $u) | Out-Null }
        $originUrl = $u
    } else {
        $ghOk = $false
        if (Get-Command gh -ErrorAction SilentlyContinue) {
            & gh auth status *> $null
            if ($LASTEXITCODE -eq 0) { $ghOk = $true }
        }
        if ($ghOk) {
            $name = Read-Host '    I can create one for you. Name it [engram-memory]'
            if (-not $name) { $name = 'engram-memory' }
            & gh repo create $name --private *> $null
            if ($LASTEXITCODE -eq 0) {
                $owner = (& gh api user -q .login 2>$null)
                $originUrl = "https://github.com/$owner/$name.git"
                Invoke-GitAllowFail -GitArgs @('remote', 'add', 'origin', $originUrl) 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) { Invoke-GitAllowFail -GitArgs @('remote', 'set-url', 'origin', $originUrl) | Out-Null }
                Write-Host "    Created private repo: $originUrl"
            } else {
                Write-Host '    Could not create it (name taken, or no permission). Create a'
                Write-Host '    PRIVATE repo at https://github.com/new then rerun this setup.'
                exit 1
            }
        } else {
            Write-Host '    Create one first: go to https://github.com/new, name it (e.g.'
            Write-Host '    engram-memory), set visibility to PRIVATE, click Create. Then:'
            $u = Read-Host '    Paste its URL here'
            if (-not $u) { Write-Host 'No URL given - stopped.'; exit 1 }
            Invoke-GitAllowFail -GitArgs @('remote', 'add', 'origin', $u) 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { Invoke-GitAllowFail -GitArgs @('remote', 'set-url', 'origin', $u) | Out-Null }
            $originUrl = $u
        }
    }
}

# -- 2. role --------------------------------------------------------------------
Write-Host ''
Write-Host 'Q2. Should this machine be able to SAVE new memories, or only READ them?'
Write-Host '    (Choose read-only for e.g. a work computer that must never upload.)'
$readOnly = -not (Read-YesNo '    Allow saving from this machine?')

# -- 3. what to keep on this machine ---------------------------------------------
Write-Host ''
Write-Host 'Q3. Normally every machine keeps a full copy of the memory. You can skip'
Write-Host '    some top-level folders on THIS machine (they stay on the hub and other'
Write-Host "    machines - e.g. skip a large 'vault' archive on a work computer)."
$skips = (Read-Host '    Folders to skip, comma-separated (blank = keep everything)').Trim()
if ($skips) {
    $folders = @($skips -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $patterns = @('/*') + @($folders | ForEach-Object { "!$_" })
    Invoke-GitAllowFail -GitArgs (@('sparse-checkout', 'set', '--no-cone') + $patterns) 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    OK - this machine will not keep: $($folders -join ', ')"
    } else {
        Write-Host '    [!] Could not apply the skip list (old git version?) - keeping everything.'
        $folders = @()
    }
} else {
    $folders = @()
}

# -- 4+5. publish if hub empty, wire the node - both via bootstrap.ps1 -----------
# bootstrap handles: origin sanity, branch -> main, the initial push (the one
# step that may need a login), setup-windows.ps1 (hooks/import/skills/task),
# and a doctor run.
Write-Host ''
Write-Host '(If git asks you to log in during this step, that is normal - one time only.)'
$flags = @{}
if ($readOnly) { $flags['ReadOnly'] = $true }
& "$PSScriptRoot\bootstrap.ps1" @flags
if ($LASTEXITCODE -ne 0) {
    Write-Host '[engram] setup did not finish cleanly - fix the failure above (usually git'
    Write-Host '         login) and rerun scripts\setup.ps1. Rerunning is safe.' -ForegroundColor Yellow
    exit $LASTEXITCODE
}

# -- 6. register this machine in global/machines.md (memory - auto-syncs) --------
$mach = Join-Path $repo 'global\machines.md'
New-Item -ItemType Directory -Force -Path (Join-Path $repo 'global') | Out-Null
if (-not (Test-Path $mach)) {
    [System.IO.File]::WriteAllText($mach, "# Machines`n`nUpdated: $Today`n", (New-Object System.Text.UTF8Encoding $false))
}
$machRaw = Get-Content -Path $mach -Raw -ErrorAction SilentlyContinue
if ($machRaw -match "(?m)^## $([regex]::Escape($NodeName)) ") {
    Write-Host "[engram] machines.md already has a section for $NodeName - left as is"
} else {
    $role = if ($readOnly) { 'READ-ONLY' } else { 'read/write' }
    $skipLine = if ($folders.Count -gt 0) { "- skips (sparse checkout): $($folders -join ', ')" } else { '- skips: none (full copy)' }
    $section = "`n## $NodeName (Windows) - $role - registered by setup $Today`n`n- engram: $repo`n$skipLine`n"
    [System.IO.File]::AppendAllText($mach, $section, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "[engram] machine registered in $mach (will sync to all machines)"
}

# -- 7. sync + plain outro ---------------------------------------------------------
& powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\sync.ps1" push *> $null
Write-Host ''
& powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\doctor.ps1" -Status
Write-Host ''
Write-Host '-- Done ------------------------------------------------------'
Write-Host 'Restart Claude Code to activate the memory. From then on:'
Write-Host '  - say "remember this: <fact>" to save something everywhere'
Write-Host '  - say "consolidate memory" about once a week to tidy up'
Write-Host 'Health check any time:  scripts\doctor.ps1 -Status'
exit 0
