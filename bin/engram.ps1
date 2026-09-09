[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ArgsList
)
$script = Join-Path (Split-Path -Parent $PSScriptRoot) "scripts\engram_cli.py"
& python -X utf8 $script @ArgsList
exit $LASTEXITCODE
