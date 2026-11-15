#requires -Version 5.1
<#
.SYNOPSIS
    Copies the shared code from a PackTune clone into Shared\ and records where it came from.
.DESCRIPTION
    Shared code (theme, sign-in, package store, protocol) is changed in PackTune first, then copied here. The copies are
    never edited by hand: Shared\SOURCE.json records the PackTune commit and the SHA256 of every file, and
    Tests\Check-Shared.ps1 fails when a file differs from its recorded hash.
    The list of files is the one table below; AVDTune specific changes go into own files (AVDTune-*.ps1, UI\AVDTune*.xaml).
.PARAMETER PackTuneRoot
    The PackTune clone. Default: C:\git\IntuneChocolateyDeployment.
.PARAMETER AllowDirty
    Copy although a shared file in the clone has uncommitted changes (recorded in SOURCE.json as Dirty = true).
#>
[CmdletBinding()]
param(
    [string]$PackTuneRoot = 'C:\git\IntuneChocolateyDeployment',
    [switch]$AllowDirty
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$target = Join-Path $repo 'Shared'

# Relative path in PackTune = relative path in Shared\
$files = @(
    'UI/Theme.xaml'
    'Modules/PackTune.SignIn.psm1'
    'PackTune-Store.ps1'
    'PackTune-Protocol.ps1'
)

if (-not (Test-Path -LiteralPath $PackTuneRoot)) { throw "PackTune clone not found: $PackTuneRoot" }
$commit = (& git -C $PackTuneRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw "$PackTuneRoot is not a git clone." }
$dirty = @(& git -C $PackTuneRoot status --porcelain -- $files)
if ($dirty.Count -gt 0 -and -not $AllowDirty) {
    throw "Shared files in $PackTuneRoot have uncommitted changes (commit them in PackTune first, or use -AllowDirty):`n$($dirty -join "`n")"
}

$entries = New-Object System.Collections.ArrayList
foreach ($file in $files) {
    $from = Join-Path $PackTuneRoot ($file -replace '/', '\')
    if (-not (Test-Path -LiteralPath $from)) { throw "Missing in PackTune: $file" }
    $to = Join-Path $target ($file -replace '/', '\')
    New-Item -ItemType Directory -Path (Split-Path $to -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $from -Destination $to -Force
    $hash = (Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash.ToLowerInvariant()
    [void]$entries.Add([ordered]@{ Path = $file; Sha256 = $hash })
}

$source = [ordered]@{
    Source   = 'dominguez-posh/PackTune'
    Commit   = $commit
    Dirty    = [bool]($dirty.Count -gt 0)
    SyncedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Files    = @($entries)
}
$json = $source | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText((Join-Path $target 'SOURCE.json'), $json, (New-Object Text.UTF8Encoding $false))
"Copied $($entries.Count) files from PackTune $($commit.Substring(0, 7)) to $target"
