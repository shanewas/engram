# digest-hermes.ps1 -- surfaces new VPS Hermes activity into the PC's actual
# daily-read memory (the Obsidian vault), since raw sync into engram/vault
# lands facts nobody notices otherwise. Wired as a SECOND SessionStart hook
# entry, after the existing `sync.ps1 pull` -- never edit sync.ps1 itself,
# it has a normative contract (docs/sync-contract.md) + its own test suite.
#
# Reads git history only (no network) -- if a concurrent sync.ps1 push/pull
# leaves the repo mid-rebase, this degrades to "no new entries" and exits 0
# rather than erroring; staleness in that rare case is already covered by
# sync.ps1's own ALERT mechanism, this script doesn't duplicate it.
#
# Windowing/freshness use the CONTENT date (filename prefix or the fact
# chunk's own header date), never file mtime -- every session file in
# engram/vault currently shares one mtime (the git-checkout time), so an
# mtime-based window would flood 100+ old entries into the vault on first
# run. First run ever (no state file) seeds state to current HEAD and emits
# zero entries -- this is not a backfill, only a starting point.
#
# Output is pointers, not copies: a ~120-char snippet + a link back to the
# source vault/<bank>/sessions/*.md file. Entries age out of the digest note
# after $WindowDays; the source file in engram/vault remains the record.
#
# Non-ASCII characters (em-dash, arrow) are built from char codes rather
# than written literally in this file -- powershell.exe (Windows PowerShell
# 5.1, as opposed to pwsh) reads .ps1 files by system codepage by default,
# and literal Unicode in the source mojibake's silently without a BOM.

$ErrorActionPreference = 'Stop'
trap { exit 0 }  # never block a session start; see sync.ps1's own invariant

$Dash  = [char]0x2014   # em dash, matches this vault's existing note convention
$Arrow = [char]0x2192

$EngramRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $EngramRoot '.git'))) {
    $EngramRoot = if ($env:ENGRAM_HOME -and (Test-Path $env:ENGRAM_HOME)) { $env:ENGRAM_HOME } else { Join-Path $env:USERPROFILE 'engram' }
}
$VaultRoot  = if ($env:ENGRAM_VAULT_ROOT -and (Test-Path $env:ENGRAM_VAULT_ROOT)) { $env:ENGRAM_VAULT_ROOT } else { Join-Path $env:USERPROFILE 'Documents\Obsidian Vault' }
$StateFile  = Join-Path $EngramRoot '.git\pc-digest-state'
$Banks      = if ($env:ENGRAM_HERMES_BANKS) { $env:ENGRAM_HERMES_BANKS -split ',' } else {
    $vaultPath = Join-Path $EngramRoot 'vault'
    if (Test-Path $vaultPath) {
        $found = @(Get-ChildItem -Path $vaultPath -Directory | Select-Object -ExpandProperty Name)
        if ($found.Count -gt 0) { $found } else { @('default') }
    } else {
        @('default')
    }
}
$WindowDays = 14

function Write-NoBom([string]$Path, [string]$Text) {
    try { [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false)) } catch {}
}

$SecretPatterns = @(
    '-----BEGIN [A-Z ]*PRIVATE KEY-----',
    'AKIA[0-9A-Z]{16}',
    'gh[pousr]_[A-Za-z0-9]{20,}',
    'sk-[A-Za-z0-9]{20,}',
    'xox[baprs]-[A-Za-z0-9-]{10,}',
    'cfat_[A-Za-z0-9]{20,}',
    '(?i)password\s*[:=]\s*\S{8,}',
    '(?i)secret[_ ]?(access[_ ]?)?key\s*[:=]\s*\S{8,}',
    'Bearer [A-Za-z0-9._-]{20,}'
)

function Redact([string]$Text) {
    foreach ($pat in $SecretPatterns) {
        $Text = [regex]::Replace($Text, $pat, '[redacted]')
    }
    return $Text
}

function Get-ContentDate([string]$RelPath, [string]$FullPath) {
    $base = [System.IO.Path]::GetFileName($RelPath)
    if ($base -match '^(\d{4}-\d{2}-\d{2})_') { return $matches[1] }
    try {
        $head = Get-Content $FullPath -TotalCount 5 -ErrorAction Stop | Out-String
        $headerPattern = '##\s+\S+\s+' + [regex]::Escape($Dash) + '\s+(\d{4}-\d{2}-\d{2})'
        if ($head -match $headerPattern) { return $matches[1] }
    } catch {}
    return $null
}

function Get-Snippet([string]$FullPath) {
    try {
        $text = Get-Content $FullPath -Raw -ErrorAction Stop
    } catch { return '' }
    # Drop the fact-chunk header + **bold:** metadata lines, keep the body.
    $lines = $text -split "`n" | Where-Object { $_ -notmatch '^##\s' -and $_ -notmatch '^\*\*\S+:\*\*' -and $_.Trim() -ne '' }
    $body = ($lines -join ' ').Trim()
    if ($body.Length -gt 120) { $body = $body.Substring(0, 120) + '...' }
    return Redact($body)
}

function Get-ExistingEntries([string]$NotePath) {
    # Returns a hashtable keyed by source path -> full bullet line, parsed
    # back out of a previously-written digest note so still-fresh entries
    # survive a rewrite instead of only ever holding this run's new ones.
    $result = @{}
    if (-not (Test-Path $NotePath)) { return $result }
    $entryPattern = '^- (\d{4}-\d{2}-\d{2}) ' + [regex]::Escape($Dash) + ' .* ' + [regex]::Escape($Arrow) + ' `(vault/[^`]+)`'
    foreach ($line in (Get-Content $NotePath -ErrorAction SilentlyContinue)) {
        if ($line -match $entryPattern) {
            $date = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd', $null)
            if (((Get-Date) - $date).TotalDays -le $WindowDays) {
                $result[$matches[2]] = $line
            }
        }
    }
    return $result
}

try {
    Push-Location $EngramRoot

    $head = (& git rev-parse HEAD 2>$null).Trim()
    if (-not $head) { Pop-Location; exit 0 }

    if (-not (Test-Path $StateFile)) {
        Write-NoBom $StateFile $head
        Write-Output "[digest-hermes] first run - seeded state, no backfill"
        Pop-Location
        exit 0
    }

    $lastSha = (Get-Content $StateFile -Raw -ErrorAction SilentlyContinue).Trim()
    if (-not $lastSha) {
        Write-NoBom $StateFile $head
        Pop-Location
        exit 0
    }

    $inboxDir = Join-Path $VaultRoot '0 Inbox'
    if (-not (Test-Path $inboxDir)) { New-Item -ItemType Directory -Path $inboxDir | Out-Null }

    $anyNew = $false
    foreach ($bank in $Banks) {
        $pathspec = "vault/$bank/sessions/"
        $changed = & git diff --name-only --diff-filter=A "$lastSha..$head" -- $pathspec 2>$null
        if (-not $changed) { continue }

        $notePath = Join-Path $inboxDir ("Hermes Digest $Dash $bank.md")
        $entries = Get-ExistingEntries $notePath

        foreach ($relPath in $changed) {
            $base = [System.IO.Path]::GetFileName($relPath)
            if ($base.StartsWith('_')) { continue }  # meta/retention files, not conversation
            $fullPath = Join-Path $EngramRoot ($relPath -replace '/', '\')
            if (-not (Test-Path $fullPath)) { continue }

            $date = Get-ContentDate $relPath $fullPath
            if (-not $date) { continue }
            if (((Get-Date) - [datetime]::ParseExact($date, 'yyyy-MM-dd', $null)).TotalDays -gt $WindowDays) { continue }

            $snippet = Get-Snippet $fullPath
            if (-not $snippet) { continue }
            $entries[$relPath] = "- $date $Dash $snippet $Arrow ``$relPath``"
            $anyNew = $true
        }

        if ($entries.Count -eq 0) { continue }

        $sorted = $entries.Values | Sort-Object -Descending
        $title = "Hermes Digest $Dash $bank"
        $body = @"
---
name: hermes-digest-$bank
description: Auto-generated digest of new Hermes activity in the $bank bank $Dash pointers only, source of truth is engram/vault/$bank/sessions/
metadata:
  node_type: memory
  type: log
para: resources
tags: [hermes, digest, $bank, auto-generated]
---

# $title

Auto-written by ``engram/scripts/digest-hermes.ps1`` on SessionStart. Do not
hand-edit entries; promote anything durable into a real PARA note $Dash it will
age out of here after $WindowDays days. Source: ``$EngramRoot\vault\$bank\sessions\``.

## New since last digest

$($sorted -join "`n")
"@
        Write-NoBom $notePath $body
    }

    Write-NoBom $StateFile $head

    if ($anyNew) {
        Write-Output "[digest-hermes] new Hermes activity digested into 0 Inbox"
    }
} catch {
    # Swallow everything - a digest miss is not worth blocking a session start.
} finally {
    try { Pop-Location -ErrorAction SilentlyContinue } catch {}
}
exit 0
