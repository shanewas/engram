<#
Engram node setup (Windows). Idempotent — safe to rerun.

Wires this machine's Claude Code into the shared memory repo:
  1. Imports index.md into ~/.claude/CLAUDE.md  -> memory index in every session (forward-slash
     @import path — backslash paths hit a Claude Code parsing bug, see docs/sync-contract.md §9)
  2. Merges SessionStart(pull) / SessionEnd(push) hooks into ~/.claude/settings.json
     (UTF-8, no BOM; replaces any existing engram hook rather than duplicating it)
  3. COPIES repo skills (never junctions/symlinks — Claude Code's skill discovery does not
     follow them) into ~/.claude/skills; upgrades any old junction left by a prior version
  4. Registers a 30-min scheduled task (EngramSync) that pushes in the background — on by
     default, mirrors the VPS cron; -NoTask opts out and removes an existing task
  5. -ReadOnly: marks this node read-only (push degrades to pull, push URL disabled)

Normally invoked via bootstrap.ps1, not directly. See PLAN.md / docs/sync-contract.md.

usage: powershell -NoProfile -ExecutionPolicy Bypass -File setup-windows.ps1 [-ReadOnly] [-NoTask]
#>
param(
    [switch]$ReadOnly,
    [switch]$NoTask
)
$ErrorActionPreference = 'Stop'

# Derived from $env:USERPROFILE (not $HOME) throughout: $HOME does not follow an overridden
# USERPROFILE env var on Windows PowerShell 5.1, which would break sandboxed testing (and any
# future non-default-profile invocation) if used instead.
$repo      = Split-Path -Parent $PSScriptRoot
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$syncPs1   = Join-Path $repo 'scripts\sync.ps1'
New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null

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

# --- 1. import line in user-level CLAUDE.md ---------------------------------
$userMd     = Join-Path $claudeDir 'CLAUDE.md'
$repoFwd    = $repo -replace '\\', '/'
$importLine = "@$repoFwd/index.md"
if (-not (Test-Path $userMd)) {
    New-Item -ItemType File -Path $userMd -Force | Out-Null
}
# match the exact line too, so a repo cloned under a non-"engram" dir name stays idempotent
$userMdRaw = Get-Content -Path $userMd -Raw -ErrorAction SilentlyContinue
$alreadyImported = ($userMdRaw -like "*$importLine*") -or ($userMdRaw -like '*engram/index.md*')
if (-not $alreadyImported) {
    Add-Content -Path $userMd -Value "`n# Engram shared memory (added by engram setup)`n$importLine"
    Write-Host "[engram] import added -> $userMd"
} else {
    Write-Host "[engram] import already present -> $userMd"
}

# --- 2. sync hooks in user-level settings.json (contract C2/C3) -------------
$settingsPath = Join-Path $claudeDir 'settings.json'
$settings = $null
if (Test-Path $settingsPath) {
    $raw = Get-Content -Path $settingsPath -Raw -ErrorAction SilentlyContinue
    if ($raw -and $raw.Trim()) {
        try {
            $settings = $raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Host "[engram] $settingsPath exists but is not valid JSON - fix or remove it manually, then rerun" -ForegroundColor Red
            exit 1
        }
    }
}
if ($null -eq $settings) { $settings = [pscustomobject]@{} }
if (-not $settings.PSObject.Properties['hooks']) {
    $settings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([pscustomobject]@{})
}

$pullCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$syncPs1`" pull"
# Detached via Start-Process: SessionEnd hooks can be killed before a network push
# completes, so this hook must return instantly and let the push outlive it (contract §8).
# ponytail: detached push assumes a space-free repo path; the 30-min task is the durable
# path regardless (SessionEnd is best-effort by design — see docs/sync-contract.md §8).
$pushCmd = "powershell -NoProfile -ExecutionPolicy Bypass -Command `"Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$syncPs1','push'`""

function Set-EngramHook {
    # Mutates $Settings.hooks.$EventName in place (PSCustomObject is a reference type) and
    # never returns the built array through the pipeline. A function that *returns* a
    # freshly built single-element array gets it silently unwrapped to a bare scalar by
    # PowerShell's pipeline output enumeration, which would then serialize as a JSON object
    # instead of a JSON array — mutate-in-place sidesteps that hazard entirely.
    param($Settings, [string]$EventName, [string]$Command, [int]$Timeout)

    $prop = $Settings.hooks.PSObject.Properties[$EventName]
    if ($null -eq $prop -or $null -eq $prop.Value) {
        $existingArr = @()
    } else {
        $existingArr = @($prop.Value)
    }

    # replace-don't-duplicate: strip any existing entry whose inner hooks[].command
    # contains 'sync.ps1'; preserve every other entry untouched.
    $kept = @($existingArr | Where-Object {
        $isEngram = @($_.hooks) | Where-Object { $_ -and $_.command -and ($_.command -like '*sync.ps1*') }
        -not [bool]$isEngram
    })

    $newEntry = @{
        matcher = '*'
        hooks   = @(@{ type = 'command'; command = $Command; timeout = $Timeout })
    }
    $finalArr = @(@($kept) + $newEntry)

    if ($null -eq $prop) {
        $Settings.hooks | Add-Member -NotePropertyName $EventName -NotePropertyValue $finalArr
    } else {
        $Settings.hooks.$EventName = $finalArr
    }
    Write-Host "[engram] hook set: $EventName ($($kept.Count) other entry(ies) preserved + 1 engram entry)"
}

Set-EngramHook -Settings $settings -EventName 'SessionStart' -Command $pullCmd -Timeout 20
Set-EngramHook -Settings $settings -EventName 'SessionEnd'   -Command $pushCmd -Timeout 10

# CRITICAL: ConvertTo-Json collapses a single-element array property to a bare JSON object
# unless it is genuinely typed as an array at serialization time. Re-wrap both right before
# serializing so this holds no matter how they were constructed above (verified empirically:
# direct in-place assignment above is already safe, this is belt-and-suspenders).
$settings.hooks.SessionStart = @($settings.hooks.SessionStart)
$settings.hooks.SessionEnd   = @($settings.hooks.SessionEnd)

$json = $settings | ConvertTo-Json -Depth 10
# PowerShell 5.1's Set-Content -Encoding UTF8 writes a BOM, which breaks settings.json for
# Claude Code. Write UTF-8 without BOM directly via .NET instead — this repo's own documented
# gotcha (docs/sync-contract.md §9).
[System.IO.File]::WriteAllText($settingsPath, $json, (New-Object System.Text.UTF8Encoding $false))
Write-Host "[engram] settings written -> $settingsPath"

# --- 3. skills: COPY as real directories, never symlink/junction ------------
$skillsSrc = Join-Path $repo 'plugins\engram\skills'
$skillsDst = Join-Path $claudeDir 'skills'
New-Item -ItemType Directory -Force -Path $skillsDst | Out-Null
if (Test-Path $skillsSrc) {
    Get-ChildItem -Path $skillsSrc -Directory | ForEach-Object {
        $src  = $_.FullName
        $name = $_.Name
        $dst  = Join-Path $skillsDst $name
        if (Test-Path -LiteralPath $dst) {
            $item = Get-Item -Force -LiteralPath $dst
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                # Never Remove-Item -Recurse a junction/symlink: it deletes THROUGH the link
                # into the real source directory. Delete only the link node itself.
                [System.IO.Directory]::Delete($dst, $false)
                Write-Host "[engram] skill '$name': removed stale junction/symlink"
            } else {
                Remove-Item -LiteralPath $dst -Recurse -Force
            }
        }
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
        Write-Host "[engram] skill copied: $name"
    }
} else {
    Write-Host "[engram] no plugins/engram/skills in repo -> nothing to copy"
}

# --- 4. scheduled task: on by default, mirrors VPS cron ----------------------
$taskName = 'EngramSync'
if ($NoTask) {
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "[engram] -NoTask: existing scheduled task removed"
    } else {
        Write-Host "[engram] -NoTask: no scheduled task present"
    }
} else {
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$syncPs1`" push"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 30) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    # Never [TimeSpan]::MaxValue (breaks task registration on 5.1). If the
    # -RepetitionDuration parameter binding above ever fails to stick on some build, fall
    # back to setting the trigger's underlying CIM duration properties directly.
    if (-not $trigger.Repetition.Duration) {
        $trigger.Repetition.Duration = ([System.Xml.XmlConvert]::ToString([TimeSpan](New-TimeSpan -Days 3650)))
        $trigger.Repetition.Interval = ([System.Xml.XmlConvert]::ToString([TimeSpan](New-TimeSpan -Minutes 30)))
    }
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Force | Out-Null
    Write-Host "[engram] scheduled task '$taskName' registered (every 30 min, on by default)"
}

# --- 5. read-only node --------------------------------------------------------
if ($ReadOnly) {
    $gitDir = Join-Path $repo '.git'
    if (Test-Path $gitDir) {
        $marker = Join-Path $gitDir 'engram-readonly'
        if (-not (Test-Path $marker)) {
            New-Item -ItemType File -Path $marker -Force | Out-Null
            Write-Host "[engram] read-only marker created -> $marker"
        } else {
            Write-Host "[engram] read-only marker already present -> $marker"
        }
        $originUrl = Invoke-GitAllowFail -GitArgs @('-C', $repo, 'remote', 'get-url', 'origin') 2>$null
        if ($LASTEXITCODE -eq 0 -and $originUrl) {
            Invoke-GitAllowFail -GitArgs @('-C', $repo, 'remote', 'set-url', '--push', 'origin', 'DISABLED') 2>$null | Out-Null
            Write-Host "[engram] push URL disabled for origin -> node is read-only"
        } else {
            Write-Host "[engram] no origin remote yet -> push URL not changed (run 'git remote set-url --push origin DISABLED' once origin is added)"
        }
    } else {
        Write-Host "[engram] $repo has no .git -> cannot mark read-only"
    }
}

Write-Host ''
Write-Host '[engram] node ready. Restart any open Claude Code sessions to pick up hooks + import.'
# Explicit exit 0: without it, $LASTEXITCODE would leak whatever the last internal native
# git call happened to return (e.g. the harmless "no origin yet" check above), which would
# make bootstrap.ps1's `if ($LASTEXITCODE -ne 0)` check wrongly treat a successful run as a
# failed one.
exit 0
