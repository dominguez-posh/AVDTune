#requires -Version 5.1
<#
.SYNOPSIS
    Checks the Software side (Modules\AVDTune.Software.psm1, issue 31) against the fake machine, the fake update adapter (tools, lock) and the fake package store
    with fake Intune notes (Tests\Fakes\FakeSoftware.ps1): input checks, the parsers, the installed list, search/install/update/remove through winget and
    Chocolatey, the lock, full tool paths, signature and file hold before every start, the write gate, change log and run record, the library (anchor from
    Intune, hashes, zip slip, read only, token audiences, redirect rules) and the page wiring. No real install, no process, no network, nothing of this
    computer is changed.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.UpdateBlock.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Updates.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Software.psm1') -Force
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeUpdates.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeSoftware.ps1')
$module = Get-Module AVDTune.Software

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }
function Get-RunLog($U) { , @($U.Log | Where-Object { $_ -like 'Run *' }) }
function Test-Refused([scriptblock]$Block) { try { & $Block | Out-Null; 'no' } catch { 'refused' } }

$wingetSearch = @"
Name        Id                 Version  Match      Source
-----------------------------------------------------------
7-Zip       7zip.7zip          24.08    Tag: 7zip  winget
Git         Git.Git            2.47.1              winget
"@
$wingetList = @"
Name           Id                   Version  Available  Source
----------------------------------------------------------------
7-Zip          7zip.7zip            23.01    24.08      winget
Notepad++      Notepad++.Notepad++  8.6                 winget
"@
$native = @{
    '*winget.exe search --query *' = @{ ExitCode = 0; Output = $wingetSearch }
    '*choco.exe search *' = @{ ExitCode = 0; Output = "git|2.45.0`r`nvlc|3.0.1`r`nChocolatey v2.0`r`n" }
    '*winget.exe list *' = @{ ExitCode = 0; Output = $wingetList }
    '*winget.exe upgrade --source *' = @{ ExitCode = 0; Output = "Name   Id         Version Available Source`r`n------------------------------------------`r`n7-Zip  7zip.7zip  23.01   24.08     winget`r`n" }
    '*choco.exe list *' = @{ ExitCode = 0; Output = "git|2.40.0`r`n7zip|23.01`r`n" }
    '*choco.exe outdated *' = @{ ExitCode = 0; Output = 'git|2.40.0|2.45.0|false' }
    '*winget.exe install *' = @{ ExitCode = 0; Output = 'ok' }
    '*winget.exe upgrade --id *' = @{ ExitCode = 0; Output = 'ok' }
    '*winget.exe uninstall *' = @{ ExitCode = 0; Output = 'ok' }
    '*choco.exe install *' = @{ ExitCode = 0; Output = 'ok' }
    '*choco.exe upgrade *' = @{ ExitCode = 0; Output = 'ok' }
    '*choco.exe uninstall *' = @{ ExitCode = 0; Output = 'ok' }
    '*msiexec.exe /i *' = @{ ExitCode = 0; Output = '' }
    '*msiexec.exe /x *' = @{ ExitCode = 0; Output = '' }
}
$uninstall = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
$uninstall32 = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
function New-Env([hashtable]$UExtra = @{}, [hashtable]$Registry = @{}) {
    $reg = @{
        "$uninstall\7-Zip|DisplayName" = '7-Zip 23.01 (x64)'; "$uninstall\7-Zip|DisplayVersion" = '23.01'; "$uninstall\7-Zip|Publisher" = 'Igor Pavlov'
        "$uninstall\{AAAAAAAA-0000-1111-2222-333333333333}|DisplayName" = 'Contoso Tool'; "$uninstall\{AAAAAAAA-0000-1111-2222-333333333333}|DisplayVersion" = '1.0.0'; "$uninstall\{AAAAAAAA-0000-1111-2222-333333333333}|WindowsInstaller" = 1
        "$uninstall\HiddenComponent|DisplayName" = 'Hidden component'; "$uninstall\HiddenComponent|SystemComponent" = 1
        "$uninstall\KB5050001|DisplayName" = 'Security Update for X'; "$uninstall\KB5050001|ParentKeyName" = 'OperatingSystem'
        "$uninstall\NoName|DisplayVersion" = '9.9'
        "$uninstall32\OldTool|DisplayName" = 'Old Tool (32 bit)'; "$uninstall32\OldTool|DisplayVersion" = '3.2'
    }
    foreach ($k in $Registry.Keys) { $reg[$k] = $Registry[$k] }
    $us = @{ Native = $native }
    foreach ($e in $UExtra.GetEnumerator()) { $us[$e.Key] = $e.Value }
    @{ M = (New-AVDTuneFakeMachine -Seed @{ Registry = $reg }); U = (New-AVDTuneFakeUpdates -Seed $us) }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-sw-' + [guid]::NewGuid().ToString('N'))
try {
    $env:AVDTUNE_ROOT = $tmp
    [void](Initialize-AVDTuneState -Root $tmp)
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-15') -User 'admin1')
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- input checks (pure)
    Test-Check 'package id: normal ids pass' ((Test-AVDTunePackageId '7zip.7zip') -and (Test-AVDTunePackageId 'Notepad++.Notepad++') -and (Test-AVDTunePackageId 'git')) $null
    $badIds = '', ' git', 'git;calc', 'git & calc', '--source evil', '-y', 'a b', 'git"', "git`r`n", 'a..b', ('a' * 129), '$(calc)', [string][char]0xE4
    Test-Check 'package id: option, space, separators, quotes, control characters, dots-dots and too long are refused' (@($badIds | Where-Object { Test-AVDTunePackageId $_ }).Count -eq 0) (@($badIds | Where-Object { Test-AVDTunePackageId $_ }) -join '|')
    Test-Check 'version: 2.47.1 and 1.0.0-beta pass; spaces, options, separators do not' ((Test-AVDTunePackageVersion '2.47.1') -and (Test-AVDTunePackageVersion '1.0.0-beta') -and -not (Test-AVDTunePackageVersion '1 --force') -and -not (Test-AVDTunePackageVersion '-1') -and -not (Test-AVDTunePackageVersion '1;2') -and -not (Test-AVDTunePackageVersion '')) $null
    Test-Check 'search text: words pass; a leading dash (an option), separators, quotes and 65 characters do not' ((Test-AVDTuneSearchText '7-zip') -and (Test-AVDTuneSearchText 'visual studio code') -and -not (Test-AVDTuneSearchText '--help') -and -not (Test-AVDTuneSearchText 'a;b') -and -not (Test-AVDTuneSearchText 'a"b') -and -not (Test-AVDTuneSearchText ('a' * 65)) -and -not (Test-AVDTuneSearchText '')) $null
    Test-Check 'version compare: numbers as numbers (1.10 > 1.9), v prefix, missing parts, a tail is older' ((Compare-AVDTuneVersion '1.10' '1.9') -eq 1 -and (Compare-AVDTuneVersion 'v2.0' '2.0.0') -eq 0 -and (Compare-AVDTuneVersion '1.0' '1.0.1') -eq -1 -and (Compare-AVDTuneVersion '2.0-beta' '2.0') -eq -1) $null

    # ---------------------------------------------------------------- parsers
    $w = ConvertFrom-AVDTuneWingetTable $wingetSearch
    Test-Check 'winget search table: name, id, version, match column does not shift the rest' ($w.Count -eq 2 -and $w[0].Id -eq '7zip.7zip' -and $w[0].Name -eq '7-Zip' -and $w[0].Version -eq '24.08' -and $w[0].Source -eq 'winget' -and $w[1].Id -eq 'Git.Git') ($w | ConvertTo-Json -Compress)
    $wl = ConvertFrom-AVDTuneWingetTable $wingetList
    Test-Check 'winget list table: installed and available version' ($wl.Count -eq 2 -and $wl[0].Version -eq '23.01' -and $wl[0].Available -eq '24.08' -and $wl[1].Id -eq 'Notepad++.Notepad++' -and $wl[1].Available -eq '') ($wl | ConvertTo-Json -Compress)
    Test-Check 'winget table: no match text and garbage give an empty list, a row with a bad id is dropped' ((ConvertFrom-AVDTuneWingetTable 'No package found matching input criteria.').Count -eq 0 -and (ConvertFrom-AVDTuneWingetTable '').Count -eq 0 -and (ConvertFrom-AVDTuneWingetTable "Name Id Version`r`n-----`r`nEvil `$(calc) 1.0`r`n").Count -eq 0) $null
    $cp = @(ConvertFrom-AVDTuneChocoPackages "git|2.45.0`r`nChocolatey v2.0`r`nbad id|1.0`r`nvlc|x")
    Test-Check 'choco list/search -r: id|version, noise and bad ids dropped' ($cp.Count -eq 1 -and $cp[0].Id -eq 'git') ($cp | ConvertTo-Json -Compress)
    $h = ('a' * 64)
    $n1 = ConvertFrom-AVDTuneIntuneNote "text PoweredByPackTune;kind=msi;app=contoso-tool;ver=1.0.0;product=aaaaaaaa-0000-1111-2222-333333333333;manifest=$h"
    Test-Check 'Intune note: kind, app, version, product code (braces, upper case) and the full manifest hash' ($n1 -and $n1.Kind -eq 'msi' -and $n1.AppId -eq 'contoso-tool' -and $n1.Version -eq '1.0.0' -and $n1.Product -eq '{AAAAAAAA-0000-1111-2222-333333333333}' -and $n1.Manifest -eq $h) ($n1 | ConvertTo-Json -Compress)
    $badNotes = @(
        "PoweredByPackTune;kind=msi;app=x;ver=1.0;manifest=$('a' * 16)", "PoweredByPackTune;kind=exe;app=x;ver=1.0;manifest=$h", "PoweredByPackTune;kind=msi;app=..\x;ver=1.0;manifest=$h",
        "PoweredByPackTune;kind=msi;app=x;ver=1.0;product=not-a-guid;manifest=$h", "PoweredByPackTune;kind=msi;app=x;manifest=$h", 'nothing of PackTune', '', ('PoweredByPackTune;' + ('x' * 5000)),
        "PoweredByPackTune;kind=msi;app=a b;ver=1.0;manifest=$h", "PoweredByPackTune;kind=msi;app=x;ver=1.0;manifest=$('g' * 64)"
    )
    Test-Check 'Intune note: the 16 character prefix, other kinds, paths, bad product codes, missing fields, spaces, non-hex, huge notes are not anchors' (@($badNotes | Where-Object { ConvertFrom-AVDTuneIntuneNote $_ }).Count -eq 0) (@($badNotes | Where-Object { ConvertFrom-AVDTuneIntuneNote $_ }) -join ' | ')

    # ---------------------------------------------------------------- settings
    $d0 = Get-AVDTuneSoftwareSettings $tmp
    Test-Check 'settings default: no site, library PackTune Packages' ($d0.StoreSiteUrl -eq '' -and $d0.StoreLibrary -eq 'PackTune Packages') $null
    $d1 = Set-AVDTuneSoftwareSettings -Root $tmp -StoreSiteUrl 'https://contoso.sharepoint.com/sites/PackTune/' -StoreLibrary 'My Packages'
    Test-Check 'settings are saved and read back (trailing slash dropped)' ($d1.StoreSiteUrl -eq 'https://contoso.sharepoint.com/sites/PackTune' -and (Get-AVDTuneSoftwareSettings $tmp).StoreLibrary -eq 'My Packages') $null
    Test-Check 'settings: another host, http, a path and a library with slashes are refused' ((Get-ThrownText { Set-AVDTuneSoftwareSettings -Root $tmp -StoreSiteUrl 'https://evil.example.com/sites/x' }) -and (Get-ThrownText { Set-AVDTuneSoftwareSettings -Root $tmp -StoreSiteUrl 'http://contoso.sharepoint.com/sites/x' }) -and (Get-ThrownText { Set-AVDTuneSoftwareSettings -Root $tmp -StoreSiteUrl 'https://contoso.sharepoint.com/sites/PackTune' -StoreLibrary '..\x' })) $null
    [void](Set-AVDTuneSoftwareSettings -Root $tmp)

    # ---------------------------------------------------------------- installed software
    $x = New-Env -Registry @{}
    $inst = @(Get-AVDTuneInstalledSoftware -Machine $x.M)
    Test-Check 'installed: 64 and 32 bit entries with version; components, updates and nameless keys are left out' ($inst.Count -eq 3 -and @($inst | Where-Object Name -eq '7-Zip 23.01 (x64)').Count -eq 1 -and @($inst | Where-Object { $_.Name -eq 'Old Tool (32 bit)' -and $_.Arch -eq 'x86' }).Count -eq 1 -and @($inst | Where-Object { $_.Name -like 'Hidden*' -or $_.Name -like 'Security Update*' }).Count -eq 0) (($inst | ForEach-Object Name) -join ', ')
    Test-Check 'installed: an MSI product code is recognised, a plain key is not' (@($inst | Where-Object { $_.Name -eq 'Contoso Tool' })[0].Msi -eq '{AAAAAAAA-0000-1111-2222-333333333333}' -and @($inst | Where-Object { $_.Name -like '7-Zip*' })[0].Msi -eq '') $null
    Test-Check 'installed: reading starts no program and changes nothing' ($x.M.Log.Count -eq 0 -and $x.U.Log.Count -eq 0) $null

    # ---------------------------------------------------------------- search through the lock
    $x = New-Env
    $sr = Search-AVDTuneCatalog -U $x.U -Query 'git'
    Test-Check 'search: winget and Chocolatey rows, with their source' (@($sr.Items | Where-Object Source -eq 'winget').Count -eq 2 -and @($sr.Items | Where-Object { $_.Source -eq 'chocolatey' -and $_.Id -eq 'git' }).Count -eq 1 -and $sr.Notes.Count -eq 0) ($sr | ConvertTo-Json -Compress)
    $log = @($x.U.Log)
    $runIdx = @(0..($log.Count - 1) | Where-Object { $log[$_] -like 'Run *' })
    $okLock = $true; foreach ($i in $runIdx) { $before = @($log[0..$i] | Where-Object { $_ -in 'LockEnter', 'LockExit' }); if ($before.Count -eq 0 -or $before[-1] -ne 'LockEnter') { $okLock = $false } }
    Test-Check 'search: every winget and choco call is inside the lock (enter before, exit after)' ($runIdx.Count -eq 2 -and $okLock -and $log[-1] -eq 'LockExit') ($log -join ' | ')
    Test-Check 'search: the query is one argument of its own and the source is fixed' ((Get-RunLog $x.U)[0] -like '*winget.exe search --query git --source winget --count 30*' -and (Get-RunLog $x.U)[1] -like '*choco.exe search git --limit-output') ((Get-RunLog $x.U) -join ' | ')
    $one = Search-AVDTuneCatalog -U $x.U -Query 'git' -Source chocolatey
    Test-Check 'search: only Chocolatey when asked' (@($one.Items | Where-Object Source -eq 'winget').Count -eq 0 -and $one.Items.Count -eq 2) $null
    $x2 = New-Env
    Test-Check 'search: an option as search text and a separator are refused, nothing is started' ((Get-ThrownText { Search-AVDTuneCatalog -U $x2.U -Query '--source evil' }) -and (Get-ThrownText { Search-AVDTuneCatalog -U $x2.U -Query 'a; calc' }) -and (Get-RunLog $x2.U).Count -eq 0) $null
    $x3 = New-Env -UExtra @{ LockError = 'another winget or Chocolatey operation has run for more than 30 minutes (lock Global\PackTune)' }
    $s3 = Search-AVDTuneCatalog -U $x3.U -Query 'git'
    Test-Check 'search: a held or foreign lock starts nothing and is explained' ($s3.Items.Count -eq 0 -and $s3.Notes.Count -eq 2 -and $s3.Notes[0] -like '*Not started*' -and (Get-RunLog $x3.U).Count -eq 0) ($s3.Notes -join '|')
    $managed = Get-AVDTuneManagedSoftware -U (New-Env).U
    Test-Check 'managed: winget and choco packages with the newer version they know' (@($managed.Items | Where-Object { $_.Id -eq '7zip.7zip' -and $_.Available -eq '24.08' }).Count -eq 1 -and @($managed.Items | Where-Object { $_.Id -eq 'git' -and $_.Source -eq 'chocolatey' -and $_.Available -eq '2.45.0' }).Count -eq 1 -and @($managed.Items | Where-Object { $_.Id -eq '7zip' -and $_.Available -eq '' }).Count -eq 1) ($managed | ConvertTo-Json -Compress)

    # ---------------------------------------------------------------- programs: path, signature, hold, lock
    $xs = New-Env -UExtra @{ Signatures = @{ 'winget.exe' = @{ Valid = $true; Subject = 'CN=Evil Corp, O=Evil Corp'; Issuer = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation' } } }
    $rs = Invoke-AVDTuneSoftwareTool -U $xs.U -Tool 'winget.exe' -Arguments @('list')
    Test-Check 'a winget that is not signed by Microsoft is not started (the lock is let go again)' (-not $rs.Ok -and $rs.Code -eq 'BadSignature' -and (Get-RunLog $xs.U).Count -eq 0 -and $xs.U.Log[-1] -eq 'LockExit') ($xs.U.Log -join '|')
    $xc = New-Env -UExtra @{ Signatures = @{ 'choco.exe' = @{ Valid = $true; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation'; Issuer = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation' } } }
    Test-Check 'a choco that carries the signature of the wrong publisher is not started' ((Invoke-AVDTuneSoftwareTool -U $xc.U -Tool 'choco.exe' -Arguments @('list')).Code -eq 'BadSignature' -and (Get-RunLog $xc.U).Count -eq 0) $null
    $xn = New-Env -UExtra @{ Signatures = @{ 'msiexec.exe' = @{ Valid = $false; Subject = ''; Issuer = '' } } }
    Test-Check 'a msiexec without a valid signature is not started' ((Invoke-AVDTuneSoftwareTool -U $xn.U -Tool 'msiexec.exe' -Arguments @('/i', 'x.msi')).Code -eq 'BadSignature' -and (Get-RunLog $xn.U).Count -eq 0) $null
    $xo = New-Env -UExtra @{ Signatures = @{ 'msiexec.exe' = @{ Valid = $true; Subject = 'CN=Microsoft Windows, O=Microsoft Corporation'; Issuer = 'CN=Microsoft Windows Production PCA 2011, O=Microsoft Corporation'; OriginalFilename = 'cmd.exe' } } }
    Test-Check 'a msiexec with another original file name is not started' ((Invoke-AVDTuneSoftwareTool -U $xo.U -Tool 'msiexec.exe' -Arguments @('/i', 'x.msi')).Code -eq 'BadSignature') $null
    $xm = New-Env -UExtra @{ Tools = @('choco.exe') }
    $rm = Invoke-AVDTuneSoftwareTool -U $xm.U -Tool 'winget.exe' -Arguments @('list')
    Test-Check 'a tool that is not found is not searched in PATH: ToolMissing, nothing started' ($rm.Code -eq 'ToolMissing' -and (Get-RunLog $xm.U).Count -eq 0) $null
    $oldWin = $env:windir; $oldSys = $env:SystemRoot; $oldPath = $env:PATH
    try {
        $env:windir = 'C:\evil'; $env:SystemRoot = 'C:\evil'; $env:PATH = 'C:\evil;' + $env:PATH
        $xe = New-Env
        [void](Invoke-AVDTuneSoftwareTool -U $xe.U -Tool 'msiexec.exe' -Arguments @('/i', 'x.msi'))
        $msiRun = (Get-RunLog $xe.U)[0]
    }
    finally { $env:windir = $oldWin; $env:SystemRoot = $oldSys; $env:PATH = $oldPath }
    $expected = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'msiexec.exe'
    Test-Check 'msiexec starts from the full system folder path of Windows, not from an environment variable or PATH' ($msiRun -like "Run $expected *" -and $msiRun -notlike '*evil*') $msiRun
    Test-Check 'winget and choco start from the fixed path the adapter found (full path), never as a bare name' ((Get-RunLog $xs.U).Count -eq 0 -and (Get-RunLog $x.U)[0] -like 'Run C:\fake\winget.exe *' -and (Get-RunLog $x.U)[1] -like 'Run C:\fake\choco.exe *') $null
    $holdFile = Join-Path $tmp 'held-tool.exe'; [IO.File]::WriteAllText($holdFile, 'tool')
    $hold = & $module { param($f) Open-AVDTuneToolHold -U ([pscustomobject]@{ Kind = 'Real' }) -Path $f } $holdFile
    $delFailed = $false; try { [IO.File]::Delete($holdFile) } catch { $delFailed = $true }
    $writeFailed = $false; try { [IO.File]::WriteAllText($holdFile, 'swapped') } catch { $writeFailed = $true }
    $readOk = $true; try { [void][IO.File]::ReadAllText($holdFile) } catch { $readOk = $false }
    if ($hold) { $hold.Dispose() }
    Test-Check 'the program file is held without delete and write sharing while it is checked and run (no swap), readers still work' ($delFailed -and $writeFailed -and $readOk -and (Test-Path -LiteralPath $holdFile)) "$delFailed $writeFailed $readOk"
    $src = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Updates.psm1'))
    Test-Check 'the real runner starts every process with UseShellExecute false, no window, in a job object that ends the whole tree before the lock is let go' ($src -match 'UseShellExecute = \$false; \$psi\.CreateNoWindow = \$true' -and $src -match 'ProcessTree\]::Terminate' -and $src -match 'ActiveProcesses|Active\(\$job\)') $null

    # ---------------------------------------------------------------- the run: gate, whatif, items checked first
    $x = New-Env
    $wish = @(New-AVDTuneSoftwareItem -Action Install -Source winget -Id '7zip.7zip' -Title '7-Zip')
    Test-Check 'a run without the snapshot gate is refused, nothing is started and LastChange stays empty' ((Get-ThrownText { Invoke-AVDTuneSoftwareRun -Machine $x.M -U $x.U -Root $tmp -Items $wish }) -like '*snapshot gate*' -and (Get-RunLog $x.U).Count -eq 0 -and -not (Get-AVDTuneState $tmp).LastChange) $null
    $dry = Invoke-AVDTuneSoftwareRun -Machine $x.M -U $x.U -Root $tmp -Items $wish -WhatIf
    Test-Check 'dry run: lists what would happen, starts nothing, writes nothing' ($dry.WhatIf -and $dry.Results[0].Status -eq 'WhatIf' -and (Get-RunLog $x.U).Count -eq 0 -and -not (Get-AVDTuneState $tmp).LastChange -and @(Get-AVDTuneChangeLog -Root $tmp).Count -eq 0) $null
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
    $mixed = @((New-AVDTuneSoftwareItem -Action Install -Source winget -Id '7zip.7zip'), (New-AVDTuneSoftwareItem -Action Install -Source chocolatey -Id 'git; calc'))
    Test-Check 'one bad package id in the list: the whole run is refused before the first program starts' ((Get-ThrownText { Invoke-AVDTuneSoftwareRun -Machine $x.M -U $x.U -Root $tmp -Items $mixed }) -like '*not a valid package id*' -and (Get-RunLog $x.U).Count -eq 0 -and -not (Get-AVDTuneState $tmp).LastChange) $null
    Test-Check 'a version with an option is refused' ((Get-ThrownText { Invoke-AVDTuneSoftwareRun -Machine $x.M -U $x.U -Root $tmp -Items @(New-AVDTuneSoftwareItem -Action Install -Source winget -Id 'a.b' -Version '1 --force') }) -like '*not a valid version*') $null

    # ---------------------------------------------------------------- the run: install, update, remove
    $r1 = Invoke-AVDTuneSoftwareRun -Machine $x.M -U $x.U -Root $tmp -User 'admin1' -SnapshotId 'snap-check' -Items @(
        (New-AVDTuneSoftwareItem -Action Install -Source winget -Id '7zip.7zip' -Version '24.08' -Title '7-Zip'),
        (New-AVDTuneSoftwareItem -Action Update -Source chocolatey -Id 'git' -Title 'Git'),
        (New-AVDTuneSoftwareItem -Action Remove -Source winget -Id 'Notepad++.Notepad++' -Title 'Notepad++'))
    $runs = Get-RunLog $x.U
    Test-Check 'install, update, remove: exact argument lists, one element each, fixed switches, machine scope on install' ($runs.Count -eq 3 -and $runs[0] -like '*winget.exe install --id 7zip.7zip --exact --source winget --silent --scope machine --accept-package-agreements --accept-source-agreements --disable-interactivity --version 24.08' -and $runs[1] -like '*choco.exe upgrade git -y --no-progress' -and $runs[2] -like '*winget.exe uninstall --id Notepad++.Notepad++ --exact --source winget --silent --disable-interactivity') ($runs -join ' | ')
    Test-Check 'run: all three changed, one run record of the plan Software, LastChange and LastUpdate set' (@($r1.Results | Where-Object Status -eq 'Changed').Count -eq 3 -and $r1.Run.Plan -eq 'Software' -and (Get-AVDTuneState $tmp).LastChange -and (Get-AVDTuneState $tmp).LastUpdate -and (Get-AVDTuneRun -Root $tmp -Id $r1.Run.Id).Plan -eq 'Software') ($r1.Results | ForEach-Object Status) -join ','
    $cl = @(Get-AVDTuneChangeLog -Root $tmp)
    Test-Check 'run: a change log entry per package with category Software, the change type and the source' ($cl.Count -eq 3 -and @($cl | Where-Object { $_.Category -eq 'Software' -and $_.ChangeType -eq 'Added' -and $_.Text -like '*7-Zip*winget*' }).Count -eq 1 -and @($cl | Where-Object { $_.ChangeType -eq 'Updated' -and $_.Component -eq 'Chocolatey' }).Count -eq 1 -and @($cl | Where-Object ChangeType -eq 'Removed').Count -eq 1 -and $cl[0].RunId -eq $r1.Run.Id) (($cl | ForEach-Object Text) -join ' | ')
    Test-Check 'the results have the shape of a step result (the protocol hook reads Section Software)' ($r1.Results[0].Section -eq 'Software' -and $r1.Results[0].Mode -eq 'Apply' -and $r1.Results[0].Id -eq 'winget:7zip.7zip') $null
    $hist = @(Get-AVDTuneSoftwareHistory -Root $tmp)
    Test-Check 'history: the three results, newest first' ($hist.Count -eq 3 -and $hist[0].Status -eq 'Changed') $null
    # codes
    $xcode = New-Env -UExtra @{ Native = @{
                '*winget.exe upgrade --id *' = @{ ExitCode = -1978335189; Output = '' }; '*winget.exe install *' = @{ ExitCode = -1978335135; Output = '' }; '*winget.exe uninstall *' = @{ ExitCode = -1978335212; Output = '' }
                '*choco.exe install *' = @{ ExitCode = 3010; Output = '' }; '*choco.exe upgrade *' = @{ ExitCode = 1; Output = 'Unable to connect to the remote server' }; '*choco.exe uninstall *' = @{ ExitCode = 1618; Output = '' } } }
    $rc = Invoke-AVDTuneSoftwareRun -Machine $xcode.M -U $xcode.U -Root $tmp -Items @(
        (New-AVDTuneSoftwareItem -Action Update -Source winget -Id 'a.b'), (New-AVDTuneSoftwareItem -Action Install -Source winget -Id 'c.d'), (New-AVDTuneSoftwareItem -Action Remove -Source winget -Id 'e.f'),
        (New-AVDTuneSoftwareItem -Action Install -Source chocolatey -Id 'g'), (New-AVDTuneSoftwareItem -Action Update -Source chocolatey -Id 'h'), (New-AVDTuneSoftwareItem -Action Remove -Source chocolatey -Id 'i'))
    $st = @($rc.Results | ForEach-Object Status)
    Test-Check 'exit codes: no newer version, already installed, not installed = Unchanged; 3010 = Changed with restart; network and busy = Failed with a readable text' (($st -join ',') -eq 'Unchanged,Unchanged,Unchanged,Changed,Failed,Failed' -and $rc.Results[3].Reboot -and $rc.Reboot -and $rc.Results[4].Message -like '*cannot be reached*' -and $rc.Results[5].Message -like '*Another installation*') (($rc.Results | ForEach-Object { "$($_.Status):$($_.Message)" }) -join ' | ')
    $clAfter = @(Get-AVDTuneChangeLog -Root $tmp)
    Test-Check 'a failed package is a change log note with the cause; unchanged ones write nothing' (@($clAfter | Where-Object { $_.ChangeType -eq 'Note' -and $_.Text -like '*FAILED*' }).Count -eq 2 -and @($clAfter | Where-Object { $_.Text -like '*e.f*' }).Count -eq 0) $null
    # failed attempts still set LastChange
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastChange = $null })
    $xf = New-Env -UExtra @{ Native = @{ '*winget.exe install *' = @{ ExitCode = -1978335224; Output = '' } } }
    $rf = Invoke-AVDTuneSoftwareRun -Machine $xf.M -U $xf.U -Root $tmp -Items @(New-AVDTuneSoftwareItem -Action Install -Source winget -Id 'a.b')
    Test-Check 'a failed install sets LastChange too (a failed installer can leave changes behind)' ($rf.Results[0].Status -eq 'Failed' -and $rf.Results[0].Message -like '*download*' -and (Get-AVDTuneState $tmp).LastChange) $null
    # lock held
    $xl = New-Env -UExtra @{ LockError = 'the lock Global\PackTune belongs to someone else (owner ''S-1-5-21-1'')' }
    $rl = Invoke-AVDTuneSoftwareRun -Machine $xl.M -U $xl.U -Root $tmp -Items @(New-AVDTuneSoftwareItem -Action Install -Source winget -Id 'a.b')
    Test-Check 'a foreign lock: the install is not started, the failure names the lock' ($rl.Results[0].Status -eq 'Failed' -and $rl.Results[0].Code -eq 'Lock' -and $rl.Results[0].Message -like '*belongs to someone else*' -and (Get-RunLog $xl.U).Count -eq 0) $rl.Results[0].Message
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- library: URL rules (pure)
    $ok = '/sites/contoso.sharepoint.com:/sites/PackTune?$select=id,displayName,webUrl'
    Test-Check 'library URL: Graph v1.0 paths of the store and Intune pass' ((Test-AVDTuneLibraryUrl "https://graph.microsoft.com/v1.0$ok").Ok -and (Test-AVDTuneLibraryUrl 'https://graph.microsoft.com/v1.0/drives/d1/root:/app/1.0.0:/children?$select=name,size,folder').Ok -and (Test-AVDTuneLibraryUrl 'https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps?$select=id,displayName,notes&$top=200').Ok) $null
    $badUrls = 'http://graph.microsoft.com/v1.0/sites', 'https://evil.example.com/v1.0/sites', 'https://graph.microsoft.com.evil.com/v1.0/sites', ('https://user:pw' + [char]64 + 'graph.microsoft.com/v1.0/sites'), 'https://graph.microsoft.com:8443/v1.0/sites',
    'https://graph.microsoft.com/v1.0/sites#frag', 'https://graph.microsoft.com/v1.0/sites?a=1?b=2', 'https://graph.microsoft.com/v1.0/sites/../me', 'https://graph.microsoft.com/v1.0/sites/a b', 'https://graph.microsoft.com/v1.0/sites?x=<script>', '', 'ftp://graph.microsoft.com/x'
    Test-Check 'library URL: http, other hosts, look-alike host, credentials, port, fragment, two question marks, dot-dot, spaces, script characters, ftp are refused' (@($badUrls | Where-Object { (Test-AVDTuneLibraryUrl $_).Ok }).Count -eq 0) (@($badUrls | Where-Object { (Test-AVDTuneLibraryUrl $_).Ok }) -join ' | ')
    Test-Check 'download redirect: only https on SharePoint hosts is followed; Graph itself, other hosts, http, credentials are not (and no token goes along)' ((Test-AVDTuneDownloadUrl 'https://contoso.sharepoint.com/sites/PackTune/_layouts/15/download.aspx?x=1') -and -not (Test-AVDTuneDownloadUrl 'https://evil.example.com/a') -and -not (Test-AVDTuneDownloadUrl 'http://contoso.sharepoint.com/a') -and -not (Test-AVDTuneDownloadUrl 'https://contoso.sharepoint.com.evil.com/a') -and -not (Test-AVDTuneDownloadUrl 'https://u:p@contoso.sharepoint.com/a') -and -not (Test-AVDTuneDownloadUrl 'https://contoso.sharepoint.com/a#b')) $null
    $libOff = New-AVDTuneFakeLibrary
    Test-Check 'library context: a site that is not SharePoint of a tenant and a bad library name are refused' ((Get-ThrownText { New-AVDTuneLibraryContext -SitesToken 'a' -GraphToken 'b' -SiteUrl 'https://evil.example.com/sites/x' }) -and (Get-ThrownText { New-AVDTuneLibraryContext -SitesToken 'a' -GraphToken 'b' -SiteUrl $libOff.SiteUrl -Library '../x' })) $null
    $script:httpCalls = 0
    $readOnly = & $module { param($c) function Test-Refused([scriptblock]$Block) { try { & $Block | Out-Null; 'no' } catch { if ($_.Exception.Message -like '*reads the package store only*') { 'refused' } else { 'other: ' + $_.Exception.Message } } }; $script:LibraryContext = $c; try { @(
                (Test-Refused { Invoke-PackTuneStoreGraph -Method PUT -Path '/drives/d1/root:/a/b:/content' -Bytes ([byte[]]@(1)) }),
                (Test-Refused { Invoke-PackTuneStoreGraph -Method DELETE -Path '/drives/d1/root:/a' }),
                (Test-Refused { Invoke-PackTuneStoreGraph -Method POST -Path '/sites' -Body @{ a = 1 } }),
                (Test-Refused { Invoke-PackTuneStoreGraph -Absolute 'https://evil.example.com/upload' })) } finally { $script:LibraryContext = $null } } (New-AVDTuneLibraryContext -SitesToken 'a' -GraphToken 'b' -SiteUrl $libOff.SiteUrl -Http { $script:httpCalls++; $null })
    Test-Check 'the library is read only: PUT, DELETE, POST with a body and an absolute upload address are refused before any request' (($readOnly -join ',') -eq 'refused,refused,refused,refused' -and $script:httpCalls -eq 0) ($readOnly -join ',')
    Test-Check 'the shared store file is unchanged (SOURCE.json hash)' ((Get-FileHash (Join-Path $repo 'Shared\PackTune-Store.ps1') -Algorithm SHA256).Hash.ToLower() -eq ((Get-Content (Join-Path $repo 'Shared\SOURCE.json') -Raw | ConvertFrom-Json).Files | Where-Object Path -eq 'PackTune-Store.ps1').Sha256) $null

    # ---------------------------------------------------------------- library: list, install, update, remove
    $lib = New-AVDTuneFakeLibrary
    $hashA = Add-AVDTuneFakeLibraryPackage $lib -App 'contoso-tool' -Version '1.0.0' -Product '{AAAAAAAA-0000-1111-2222-333333333333}' -Name 'Contoso Tool'
    $hashB = Add-AVDTuneFakeLibraryPackage $lib -App 'contoso-tool' -Version '1.1.0' -Product '{BBBBBBBB-0000-1111-2222-333333333333}' -Name 'Contoso Tool'
    [void](Add-AVDTuneFakeLibraryPackage $lib -App 'orphan-pkg' -Version '2.0' -NoAnchor)
    [void](Add-AVDTuneFakeLibraryPackage $lib -App 'msix-pkg' -Version '3.0' -Kind msix -Name 'An MSIX')
    [void](Add-AVDTuneFakeLibraryPackage $lib -App 'prefix-pkg' -Version '1.0' -AnchorPrefix)
    [void](Add-AVDTuneFakeLibraryPackage $lib -App 'noproduct-pkg' -Version '1.0' -NoProduct)
    [void](Add-AVDTuneFakeLibraryPackage $lib -App 'half-pkg' -Version '1.0' -NoManifest)
    $ctx = New-AVDTuneLibraryContext -SitesToken $lib.SitesToken -GraphToken $lib.GraphToken -SiteUrl $lib.SiteUrl -Http $lib.Http
    $xl = New-Env
    $li = Get-AVDTuneLibraryItems -Context $ctx -Machine $xl.M
    $by = @{}; foreach ($i in $li.Items) { $by["$($i.AppId)|$($i.Version)"] = $i }
    Test-Check 'library list: the complete versions of the store with their Intune anchor; the version without manifest is not listed' ($li.State -eq 'Ready' -and $by.Count -eq 6 -and -not $by.ContainsKey('half-pkg|1.0') -and $by['contoso-tool|1.0.0'].Installable -and $by['contoso-tool|1.0.0'].Manifest -eq $hashA -and $by['contoso-tool|1.0.0'].Name -eq 'Contoso Tool' -and $by['contoso-tool|1.0.0'].Installed -eq '1.0.0') ($li | ConvertTo-Json -Depth 4 -Compress)
    Test-Check 'library list: without Intune anchor, MSIX, the short hash prefix and a missing product code are listed but not installable, with the reason' (-not $by['orphan-pkg|2.0'].Installable -and $by['orphan-pkg|2.0'].Why -like '*no trust anchor*' -and -not $by['msix-pkg|3.0'].Installable -and $by['msix-pkg|3.0'].Why -like '*MSIX*' -and -not $by['prefix-pkg|1.0'].Installable -and $by['prefix-pkg|1.0'].Why -like '*no trust anchor*' -and -not $by['noproduct-pkg|1.0'].Installable -and $by['noproduct-pkg|1.0'].Why -like '*product code*') $null
    Test-Check 'library list: the installed version comes from the Uninstall key of the product code' ($by['contoso-tool|1.0.0'].Installed -eq '1.0.0' -and $by['contoso-tool|1.1.0'].Installed -eq '') $null
    $reqs = @($lib.Log)
    Test-Check 'tokens go only to their audience: the Sites token to the store, the Graph token to the Intune notes (the fake answers 403 otherwise)' (@($reqs | Where-Object { $_ -like 'GET graph *' }).Count -ge 1 -and @($reqs | Where-Object { $_ -like 'GET sites *' }).Count -ge 4 -and -not ($reqs -join '|').Contains($lib.SitesToken)) $null
    $libNo = New-AVDTuneFakeLibrary; $libNo.Store.Offline = $true
    $lo = Get-AVDTuneLibraryItems -Context (New-AVDTuneLibraryContext -SitesToken 'a' -GraphToken 'b' -SiteUrl $libNo.SiteUrl -Http $libNo.Http) -Machine $xl.M
    Test-Check 'library offline: State NoAccess with a readable cause, no exception' ($lo.State -eq 'NoAccess' -and $lo.Message -like '*cannot be reached*') $lo.Message
    $libI = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libI -App 'contoso-tool' -Version '1.0.0'); $libI.Store.IntuneOffline = $true
    $li2 = Get-AVDTuneLibraryItems -Context (New-AVDTuneLibraryContext -SitesToken $libI.SitesToken -GraphToken $libI.GraphToken -SiteUrl $libI.SiteUrl -Http $libI.Http) -Machine $xl.M
    Test-Check 'Intune not readable: nothing can be trusted, no package is installable, the note says why' (@($li2.Items | Where-Object Installable).Count -eq 0 -and $li2.Notes[0] -like '*no package can be trusted*') ($li2.Notes -join '|')

    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
    $xi = New-Env
    $seen = @{}
    $xi.U.Run = {
        param($File, [string[]]$Arguments, [int]$TimeoutSeconds = 600)
        $seen.Args = @($Arguments); $seen.Msi = $Arguments[1]; $seen.Exists = [bool](Test-Path -LiteralPath $Arguments[1]); $seen.Text = if ($seen.Exists) { [IO.File]::ReadAllText($Arguments[1]) } else { '' }
        [void]$xi.U.Log.Add("Run $File $($Arguments -join ' ')")
        [pscustomobject]@{ ExitCode = 0; Output = '' }
    }.GetNewClosure()
    $ri = Invoke-AVDTuneSoftwareRun -Machine $xi.M -U $xi.U -Root $tmp -LibraryContext $ctx -User 'admin1' -Items @(New-AVDTuneSoftwareItem -Action Update -Source library -Id 'contoso-tool' -Version '1.1.0' -Title 'Contoso Tool')
    Test-Check 'library update: verified against Intune, unpacked, msiexec /i with the MSI from the protected work folder and fixed switches' ($ri.Results[0].Status -eq 'Changed' -and $seen.Args[0] -eq '/i' -and $seen.Exists -and $seen.Text -eq 'MSI stand-in' -and $seen.Args[2] -eq '/qn' -and $seen.Args[3] -eq '/norestart' -and $seen.Args[4] -eq '/l*v' -and $seen.Msi -like "$tmp\software\work\*\package\installer\setup\tool.msi" -and $seen.Args[5] -like "$tmp\logs\*") ($ri.Results[0].Message + ' ' + ($seen.Args -join ' '))
    Test-Check 'library install: the work folder is gone afterwards, the log folder is the protected one' (@(Get-ChildItem (Join-Path $tmp 'software\work') -ErrorAction SilentlyContinue).Count -eq 0 -and (Test-Path (Join-Path $tmp 'software\work'))) $null
    $clx = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq 'PackTune library' })
    Test-Check 'library update: change log entry with the version, run record, LastChange' ($clx.Count -eq 1 -and $clx[0].ChangeType -eq 'Updated' -and $clx[0].Text -like '*1.1.0*' -and (Get-AVDTuneState $tmp).LastChange) ($clx | ConvertTo-Json -Compress)
    $xr = New-Env
    $rr = Invoke-AVDTuneSoftwareRun -Machine $xr.M -U $xr.U -Root $tmp -LibraryContext $ctx -Items @(New-AVDTuneSoftwareItem -Action Remove -Source library -Id 'contoso-tool' -Version '1.0.0')
    Test-Check 'library remove: msiexec /x with the product code from the Intune notes (not from the store)' ($rr.Results[0].Status -eq 'Changed' -and (Get-RunLog $xr.U)[0] -like '*msiexec.exe /x {AAAAAAAA-0000-1111-2222-333333333333} /qn /norestart /l*v *') (Get-RunLog $xr.U)[0]
    # counter-tests: not trusted, nothing runs
    foreach ($case in @(
            @{ Name = 'a package that Intune does not know'; App = 'orphan-pkg'; Ver = '2.0'; Like = '*no trust anchor*' }
            @{ Name = 'an MSIX package'; App = 'msix-pkg'; Ver = '3.0'; Like = '*MSIX*' }
            @{ Name = 'a manifest with only the hash prefix in Intune'; App = 'prefix-pkg'; Ver = '1.0'; Like = '*no trust anchor*' }
            @{ Name = 'a package that is not in the library'; App = 'missing-pkg'; Ver = '1.0'; Like = '*not in the library*' })) {
        $xz = New-Env
        $rz = Invoke-AVDTuneSoftwareRun -Machine $xz.M -U $xz.U -Root $tmp -LibraryContext $ctx -Items @(New-AVDTuneSoftwareItem -Action Install -Source library -Id $case.App -Version $case.Ver)
        Test-Check "library install refused: $($case.Name)" ($rz.Results[0].Status -eq 'Failed' -and $rz.Results[0].Message -like $case.Like -and (Get-RunLog $xz.U).Count -eq 0) $rz.Results[0].Message
    }
    # the store was changed behind Intune's back
    $libT = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libT -App 'contoso-tool' -Version '1.0.0')
    $mf = [Text.Encoding]::UTF8.GetString($libT.Store.Files['contoso-tool/1.0.0/manifest.json']).Replace('PackTune.Store', 'PackTune.Store') + ' '
    $libT.Store.Files['contoso-tool/1.0.0/manifest.json'] = [Text.Encoding]::UTF8.GetBytes($mf)
    $ctxT = New-AVDTuneLibraryContext -SitesToken $libT.SitesToken -GraphToken $libT.GraphToken -SiteUrl $libT.SiteUrl -Http $libT.Http
    $xt = New-Env
    $rt = Invoke-AVDTuneSoftwareRun -Machine $xt.M -U $xt.U -Root $tmp -LibraryContext $ctxT -Items @(New-AVDTuneSoftwareItem -Action Install -Source library -Id 'contoso-tool' -Version '1.0.0')
    Test-Check 'a manifest that differs from the one in Intune: nothing is unpacked, nothing is started' ($rt.Results[0].Status -eq 'Failed' -and $rt.Results[0].Message -like '*does not match the one recorded in Intune*' -and (Get-RunLog $xt.U).Count -eq 0 -and -not (Get-ChildItem (Join-Path $tmp 'software\work') -ErrorAction SilentlyContinue)) $rt.Results[0].Message
    $libF = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libF -App 'contoso-tool' -Version '1.0.0')
    $libF.Store.Tamper['contoso-tool/1.0.0/installer.zip'] = [byte[]]@(1, 2, 3)
    $ctxF = New-AVDTuneLibraryContext -SitesToken $libF.SitesToken -GraphToken $libF.GraphToken -SiteUrl $libF.SiteUrl -Http $libF.Http
    $xf2 = New-Env
    $rf2 = Invoke-AVDTuneSoftwareRun -Machine $xf2.M -U $xf2.U -Root $tmp -LibraryContext $ctxF -Items @(New-AVDTuneSoftwareItem -Action Install -Source library -Id 'contoso-tool' -Version '1.0.0')
    Test-Check 'a file that differs from the manifest hash: refused, not unpacked, nothing started, work folder removed' ($rf2.Results[0].Status -eq 'Failed' -and $rf2.Results[0].Message -like '*does not match the manifest*' -and (Get-RunLog $xf2.U).Count -eq 0 -and -not (Get-ChildItem (Join-Path $tmp 'software\work') -ErrorAction SilentlyContinue)) $rf2.Results[0].Message
    # zip slip and installer shapes
    $libS = New-AVDTuneFakeLibrary
    [void](Add-AVDTuneFakeLibraryPackage $libS -App 'slip-pkg' -Version '1.0' -InstallerEntries @{ '../../evil.msi' = 'x' })
    [void](Add-AVDTuneFakeLibraryPackage $libS -App 'two-pkg' -Version '1.0' -InstallerEntries @{ 'a.msi' = '1'; 'b.msi' = '2' })
    [void](Add-AVDTuneFakeLibraryPackage $libS -App 'none-pkg' -Version '1.0' -InstallerEntries @{ 'readme.txt' = 'no msi' })
    $ctxS = New-AVDTuneLibraryContext -SitesToken $libS.SitesToken -GraphToken $libS.GraphToken -SiteUrl $libS.SiteUrl -Http $libS.Http
    foreach ($case in @(@{ App = 'slip-pkg'; Like = '*not allowed*' }, @{ App = 'none-pkg'; Like = '*no single MSI*' })) {
        $xs2 = New-Env
        $rs2 = Invoke-AVDTuneSoftwareRun -Machine $xs2.M -U $xs2.U -Root $tmp -LibraryContext $ctxS -Items @(New-AVDTuneSoftwareItem -Action Install -Source library -Id $case.App -Version '1.0')
        Test-Check "installer folder $($case.App): refused, nothing started" ($rs2.Results[0].Status -eq 'Failed' -and $rs2.Results[0].Message -like $case.Like -and (Get-RunLog $xs2.U).Count -eq 0) $rs2.Results[0].Message
    }
    Test-Check 'a zip entry that climbs out of the target folder writes nothing outside it' (-not (Test-Path (Join-Path $tmp 'software\evil.msi')) -and -not (Test-Path (Join-Path $tmp 'evil.msi'))) $null
    [void](Add-AVDTuneFakeLibraryPackage $libS -App 'two-ok' -Version '1.0' -EntryPoint 'b.msi' -InstallerEntries @{ 'a.msi' = '1'; 'b.msi' = '2' })
    [void](Add-AVDTuneFakeLibraryPackage $libS -App 'two-bad' -Version '1.0' -EntryPoint '..\x.msi' -InstallerEntries @{ 'a.msi' = '1'; 'b.msi' = '2' })
    $xs3 = New-Env
    $rs3 = Invoke-AVDTuneSoftwareRun -Machine $xs3.M -U $xs3.U -Root $tmp -LibraryContext $ctxS -Items @(New-AVDTuneSoftwareItem -Action Install -Source library -Id 'two-ok' -Version '1.0')
    Test-Check 'two MSIs: the recipe names one by plain file name, exactly that one is installed (the recipe is only read as data, never run)' ($rs3.Results[0].Status -eq 'Changed' -and (Get-RunLog $xs3.U)[0] -like '*\b.msi /qn *') ($rs3.Results[0].Message + ' ' + ((Get-RunLog $xs3.U) -join '|'))
    $xs4 = New-Env
    $rs4 = Invoke-AVDTuneSoftwareRun -Machine $xs4.M -U $xs4.U -Root $tmp -LibraryContext $ctxS -Items @(New-AVDTuneSoftwareItem -Action Install -Source library -Id 'two-bad' -Version '1.0')
    Test-Check 'two MSIs and a recipe entry that is a path: refused, nothing started' ($rs4.Results[0].Status -eq 'Failed' -and $rs4.Results[0].Message -like '*no single MSI*' -and (Get-RunLog $xs4.U).Count -eq 0) $rs4.Results[0].Message
    $zipDir = Join-Path $tmp 'zip-slip-direct'
    $zipFile = Join-Path $tmp 'slip.zip'; [IO.File]::WriteAllBytes($zipFile, (New-AVDTuneFakeZip @{ 'ok.txt' = 'fine'; 'sub/..\..\escape.txt' = 'bad' }))
    Test-Check 'Expand-PackTuneZip refuses an entry outside the folder, a drive letter, an absolute name and a device name; the folder stays empty of the bad entry' ((Get-ThrownText { Expand-PackTuneZip -Path $zipFile -Destination $zipDir }) -and -not (Test-Path (Join-Path $tmp 'escape.txt'))) $null
    foreach ($bad in 'C:\evil.txt', '/abs.txt', 'CON.txt', 'a/b:stream.txt') {
        $z = Join-Path $tmp ('z-' + [guid]::NewGuid().ToString('N') + '.zip'); [IO.File]::WriteAllBytes($z, (New-AVDTuneFakeZip @{ $bad = 'x' }))
        Test-Check "Expand-PackTuneZip refuses the entry '$bad'" ([bool](Get-ThrownText { Expand-PackTuneZip -Path $z -Destination (Join-Path $tmp ('d-' + [guid]::NewGuid().ToString('N'))) })) $null
    }
    # not signed in / no library
    $xq = New-Env
    $rq = Invoke-AVDTuneSoftwareRun -Machine $xq.M -U $xq.U -Root $tmp -Items @(New-AVDTuneSoftwareItem -Action Install -Source library -Id 'contoso-tool' -Version '1.0.0')
    Test-Check 'a library package without an open library (no site or no sign-in) fails clearly, nothing started' ($rq.Results[0].Status -eq 'Failed' -and $rq.Results[0].Code -eq 'NoLibrary' -and (Get-RunLog $xq.U).Count -eq 0) $null
    $ctxN = New-AVDTuneLibraryContext -SitesToken '' -GraphToken '' -SiteUrl $lib.SiteUrl
    $rn = Invoke-AVDTuneSoftwareRun -Machine $xq.M -U $xq.U -Root $tmp -LibraryContext $ctxN -Items @(New-AVDTuneSoftwareItem -Action Install -Source library -Id 'contoso-tool' -Version '1.0.0')
    Test-Check 'no token: the library says not signed in and nothing is requested over the network' ($rn.Results[0].Status -eq 'Failed' -and $rn.Results[0].Message -like '*Not signed in*') $rn.Results[0].Message
    Close-AVDTuneLibraryContext $ctx
    Test-Check 'closing the context removes the tokens from memory' ($null -eq $ctx.SitesToken -and $null -eq $ctx.GraphToken) $null

    # ---------------------------------------------------------------- secrets and files
    Close-AVDTuneWriteGate
    $leak = @(Get-ChildItem -LiteralPath $tmp -Recurse -File | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue) -match 'fake-sites-token|fake-graph-token' })
    Test-Check 'no token reaches the run records, the change log, the state or any file under the state folder' ($leak.Count -eq 0) ($leak.FullName -join ', ')
    $strays = @(Get-ChildItem -LiteralPath (Join-Path $tmp 'software') -Recurse -File -ErrorAction SilentlyContinue)
    Test-Check 'nothing stays in the software work folder after the runs' ($strays.Count -eq 0) ($strays.FullName -join ', ')

    # ---------------------------------------------------------------- page wiring (source)
    $page = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Software.ps1'))
    $start = [IO.File]::ReadAllText((Join-Path $repo 'Start-AVDTune.ps1'))
    foreach ($file in 'AVDTune-Software.ps1', 'Modules\AVDTune.Software.psm1', 'Start-AVDTune.ps1') {
        $errors = $null; [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $file), [ref]$null, [ref]$errors)
        Test-Check "$file parses without errors" ($errors.Count -eq 0) (($errors | ForEach-Object { $_.Message }) -join '; ')
    }
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        [xml]$swXml = Get-Content (Join-Path $repo 'UI\Software.xaml') -Raw -Encoding UTF8
        $swRoot = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($swXml))
        $names = @($swXml.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object { $_.Attributes | Where-Object LocalName -eq 'Name' | Select-Object -ExpandProperty Value })
        $needed = 'PageSoftware', 'BtnSwRefresh', 'BtnSwUpdateAll', 'TxtSwState', 'TxtSwNotes', 'PanelSwManaged', 'TxtSwQuery', 'CmbSwSource', 'BtnSwSearch', 'PanelSwResults', 'TxtSwSite', 'TxtSwLibrary', 'BtnSwSaveSite', 'TxtSwLibState', 'PanelSwLibrary', 'TxtSwInstalledTitle', 'PanelSwInstalled', 'PanelSwHistory'
        $missing = @($needed | Where-Object { $_ -notin $names -or -not $swRoot.FindName($_) -and $_ -ne 'PageSoftware' })
        $pageUses = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Software.ps1'))
        $unknown = @([regex]::Matches($pageUses, '\$ui\.((?:Btn|Txt|Panel|Cmb|Chk)Sw\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique | Where-Object { $_ -notin $names })
        Test-Check 'Software.xaml loads and has every control the page script uses' ($missing.Count -eq 0 -and $unknown.Count -eq 0 -and $swRoot.Visibility -eq 'Collapsed') "missing: $($missing -join ',') unknown: $($unknown -join ',')"
    }
    catch { Test-Check 'Software.xaml loads' $false $_.Exception.Message }    Test-Check 'the page is wired in: module imported, page file dot-sourced, Software no longer a placeholder' ($start -match "'Software'" -and $start -match "AVDTune-Software\.ps1" -and $start -match 'Show-SoftwarePage') $null
    Test-Check 'the page starts long work as a task on the task bar and blocks closing the window while it runs' ($page -match 'Start-AVDTuneUiTask' -and $page -match 'Complete-AVDTuneUiTask' -and $page -match 'Set-ShutdownBlock') $null
    Test-Check 'the page changes the master only behind the write gate and a confirmation' ($page -match 'Test-AVDTuneWriteAllowed' -and $page -match 'Confirm-Action') $null
    Test-Check 'the page never builds a command line: no Start-Process, no cmd, no Invoke-Expression, no PATH lookups' ($page -notmatch 'Start-Process|Invoke-Expression|\biex\b|cmd\.exe|Get-Command' -and ([IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Software.psm1'))) -notmatch 'Start-Process|Invoke-Expression|\biex\b|cmd\.exe|Get-Command|\[Environment\]::GetEnvironmentVariable|\$env:') $null
}
finally {
    Close-AVDTuneWriteGate
    $env:AVDTUNE_ROOT = $null
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-Software: all checks passed.'
