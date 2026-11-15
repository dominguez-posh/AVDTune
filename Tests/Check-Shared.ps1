#requires -Version 5.1
<#
.SYNOPSIS
    Checks that every file in Shared\ is exactly what Tools\Sync-FromPackTune.ps1 recorded in Shared\SOURCE.json.
.DESCRIPTION
    Fails when a copy was edited by hand, a recorded file is missing, or a file is in Shared\ that is not recorded.
    With -PackTuneRoot (a clone that exists) it also reports, without failing, which shared files changed in PackTune since the sync.
#>
[CmdletBinding()]
param([string]$PackTuneRoot = 'C:\git\IntuneChocolateyDeployment')

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$shared = Join-Path $repo 'Shared'
$failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) {
    if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) }
}

$sourcePath = Join-Path $shared 'SOURCE.json'
Test-Check 'Shared\SOURCE.json exists' (Test-Path -LiteralPath $sourcePath) $sourcePath
if (Test-Path -LiteralPath $sourcePath) {
    $source = [IO.File]::ReadAllText($sourcePath) | ConvertFrom-Json
    Test-Check 'SOURCE.json names the PackTune commit' ($source.Commit -match '^[0-9a-f]{40}$') $source.Commit
    Test-Check 'SOURCE.json lists files' (@($source.Files).Count -gt 0) $null
    $recorded = @{}
    foreach ($entry in @($source.Files)) {
        $recorded[([string]$entry.Path)] = $true
        $path = Join-Path $shared (([string]$entry.Path) -replace '/', '\')
        if (-not (Test-Path -LiteralPath $path)) { Test-Check "$($entry.Path) is present" $false 'missing'; continue }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        Test-Check "$($entry.Path) matches its recorded hash" ($hash -eq ([string]$entry.Sha256).ToLowerInvariant()) 'edited by hand? change it in PackTune and run Tools\Sync-FromPackTune.ps1'
    }
    $extra = @(Get-ChildItem -LiteralPath $shared -Recurse -File | Where-Object { $_.Name -ne 'SOURCE.json' } |
            ForEach-Object { $_.FullName.Substring($shared.Length + 1).Replace('\', '/') } | Where-Object { -not $recorded.ContainsKey($_) })
    Test-Check 'no file in Shared\ outside SOURCE.json' ($extra.Count -eq 0) ($extra -join ', ')

    if ($PackTuneRoot -and (Test-Path -LiteralPath $PackTuneRoot)) {
        $drift = @(foreach ($entry in @($source.Files)) {
                $from = Join-Path $PackTuneRoot (([string]$entry.Path) -replace '/', '\')
                if ((Test-Path -LiteralPath $from) -and (Get-FileHash -LiteralPath $from -Algorithm SHA256).Hash.ToLowerInvariant() -ne ([string]$entry.Sha256).ToLowerInvariant()) { $entry.Path }
            })
        if ($drift.Count -gt 0) { "INFO PackTune changed since the sync: $($drift -join ', ') (run Tools\Sync-FromPackTune.ps1 when it should come over)" }
    }
}
if ($failed -gt 0) { throw "$failed check(s) failed." }
'Check-Shared: all checks passed.'
