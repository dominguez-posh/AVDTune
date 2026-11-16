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
    $env:AVDTUNE_FAKE = Join-Path $PSScriptRoot 'Fakes\FakeSoftware.ps1'   # the test mode (Test-AVDTuneTestMode): the checks may override the ACL of the work folder
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
    $msiSig = { param($issuer) [pscustomobject]@{ Valid = $true; Subject = 'CN=Microsoft Windows, O=Microsoft Corporation'; Issuer = "$issuer, O=Microsoft Corporation"; OriginalFilename = 'msiexec.exe' } }
    Test-Check 'msiexec signer: the real issuer names pass; text after the year or after PCA, or a lookalike, does not' ((Test-AVDTuneMsiexecTrust (& $msiSig 'CN=Microsoft Windows Production PCA 2011')).Ok -and (Test-AVDTuneMsiexecTrust (& $msiSig 'CN=Microsoft Code Signing PCA 2024')).Ok -and -not (Test-AVDTuneMsiexecTrust (& $msiSig 'CN=Microsoft Windows Production PCA 2011 evil')).Ok -and -not (Test-AVDTuneMsiexecTrust (& $msiSig 'CN=Microsoft Windows Production PCA evil')).Ok -and -not (Test-AVDTuneMsiexecTrust (& $msiSig 'CN=Microsoft Windows Production PCA 20111')).Ok) $null
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
    $rh = Get-AVDTuneRedirectHosts "https://contoso.sharepoint.com/sites/PackTune"
    Test-Check 'download redirect target: only https on the SharePoint host of the site and its -my variant; Graph, other tenants, look-alikes, http, credentials, fragments are not' ((Test-AVDTuneDownloadUrl 'https://contoso.sharepoint.com/sites/PackTune/_layouts/15/download.aspx?x=1' -AllowedHost $rh) -and -not (Test-AVDTuneDownloadUrl 'https://evil.example.com/a' -AllowedHost $rh) -and -not (Test-AVDTuneDownloadUrl 'http://contoso.sharepoint.com/a' -AllowedHost $rh) -and -not (Test-AVDTuneDownloadUrl 'https://contoso.sharepoint.com.evil.com/a' -AllowedHost $rh) -and -not (Test-AVDTuneDownloadUrl 'https://u:p@contoso.sharepoint.com/a' -AllowedHost $rh) -and -not (Test-AVDTuneDownloadUrl 'https://contoso.sharepoint.com/a#b' -AllowedHost $rh)) $null
    $libOff = New-AVDTuneFakeLibrary
    Test-Check 'library context: a site that is not SharePoint of a tenant and a bad library name are refused' ((Get-ThrownText { New-AVDTuneLibraryContext -SitesToken 'a' -GraphToken 'b' -SiteUrl 'https://evil.example.com/sites/x' }) -and (Get-ThrownText { New-AVDTuneLibraryContext -SitesToken 'a' -GraphToken 'b' -SiteUrl $libOff.SiteUrl -Library '../x' })) $null
    $script:httpCalls = 0
    $readOnly = & $module { param($c) function Test-Refused([scriptblock]$Block) { try { & $Block | Out-Null; 'no' } catch { if ($_.Exception.Message -like '*reads the package store only*') { 'refused' } else { 'other: ' + $_.Exception.Message } } }; $script:LibraryContext = $c; try { @(
                (Test-Refused { Invoke-PackTuneStoreGraph -Method PUT -Path '/drives/d1/root:/a/b:/content' -Bytes ([byte[]]@(1)) }),
                (Test-Refused { Invoke-PackTuneStoreGraph -Method DELETE -Path '/drives/d1/root:/a' }),
                (Test-Refused { Invoke-PackTuneStoreGraph -Method POST -Path '/sites' -Body @{ a = 1 } }),
                (Test-Refused { Invoke-PackTuneStoreGraph -Absolute 'https://evil.example.com/upload' })) } finally { $script:LibraryContext = $null } } (New-AVDTuneLibraryContext -SitesToken 'a' -GraphToken 'b' -SiteUrl $libOff.SiteUrl -Transport { $script:httpCalls++; throw "no request expected" })
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
    $ctx = New-AVDTuneLibraryContext -SitesToken $lib.SitesToken -GraphToken $lib.GraphToken -SiteUrl $lib.SiteUrl -Transport $lib.Transport
    $xl = New-Env
    $li = Get-AVDTuneLibraryItems -Context $ctx -Machine $xl.M
    $libV = New-AVDTuneFakeLibrary
    foreach ($vv in '1.0.0', '1..0', 'v 2', '2.0.0') { [void](Add-AVDTuneFakeLibraryPackage $libV -App 'contoso-tool' -Version $vv) }
    $liV = Get-AVDTuneLibraryItems -Context (New-AVDTuneLibraryContext -SitesToken $libV.SitesToken -GraphToken $libV.GraphToken -SiteUrl $libV.SiteUrl -Transport $libV.Transport) -Machine (New-Env).M
    $vers = (@($liV.Items | ForEach-Object { $_.Version } | Sort-Object) -join ',')
    Test-Check 'library list: a version folder with an invalid name is skipped on its own, the valid versions of the same app stay' ($liV.State -eq 'Ready' -and $vers -eq '1.0.0,2.0.0' -and @($liV.Notes | Where-Object { $_ -like '*invalid name*' }).Count -eq 2) ($vers + ' / ' + ($liV.Notes -join ';'))
    $by = @{}; foreach ($i in $li.Items) { $by["$($i.AppId)|$($i.Version)"] = $i }
    Test-Check 'library list: the complete versions of the store with their Intune anchor; the version without manifest is not listed' ($li.State -eq 'Ready' -and $by.Count -eq 6 -and -not $by.ContainsKey('half-pkg|1.0') -and $by['contoso-tool|1.0.0'].Installable -and $by['contoso-tool|1.0.0'].Manifest -eq $hashA -and $by['contoso-tool|1.0.0'].Name -eq 'Contoso Tool' -and $by['contoso-tool|1.0.0'].Installed -eq '1.0.0') ($li | ConvertTo-Json -Depth 4 -Compress)
    Test-Check 'library list: without Intune anchor, MSIX, the short hash prefix and a missing product code are listed but not installable, with the reason' (-not $by['orphan-pkg|2.0'].Installable -and $by['orphan-pkg|2.0'].Why -like '*no trust anchor*' -and -not $by['msix-pkg|3.0'].Installable -and $by['msix-pkg|3.0'].Why -like '*MSIX*' -and -not $by['prefix-pkg|1.0'].Installable -and $by['prefix-pkg|1.0'].Why -like '*no trust anchor*' -and -not $by['noproduct-pkg|1.0'].Installable -and $by['noproduct-pkg|1.0'].Why -like '*product code*') $null
    Test-Check 'library list: the installed version comes from the Uninstall key of the product code' ($by['contoso-tool|1.0.0'].Installed -eq '1.0.0' -and $by['contoso-tool|1.1.0'].Installed -eq '') $null
    $libNo = New-AVDTuneFakeLibrary; $libNo.Store.Offline = $true
    $lo = Get-AVDTuneLibraryItems -Context (New-AVDTuneLibraryContext -SitesToken 'a' -GraphToken 'b' -SiteUrl $libNo.SiteUrl -Transport $libNo.Transport) -Machine $xl.M
    Test-Check 'library offline: State NoAccess with a readable cause, no exception' ($lo.State -eq 'NoAccess' -and $lo.Message -like '*cannot be reached*') $lo.Message
    $libI = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libI -App 'contoso-tool' -Version '1.0.0'); $libI.Store.IntuneOffline = $true
    $li2 = Get-AVDTuneLibraryItems -Context (New-AVDTuneLibraryContext -SitesToken $libI.SitesToken -GraphToken $libI.GraphToken -SiteUrl $libI.SiteUrl -Transport $libI.Transport) -Machine $xl.M
    Test-Check 'Intune not readable: nothing can be trusted, no package is installable, the note says why' (@($li2.Items | Where-Object Installable).Count -eq 0 -and $li2.Notes[0] -like '*no package can be trusted*') ($li2.Notes -join '|')
    # ---- transport level: the real loop (redirects by hand, token only to Graph, limits, paging) runs against the fake transport
    $hostsLog = @($lib.Log)
    Test-Check 'tokens: every request to Graph carried a bearer token, none went anywhere else, and no log line holds a token (the fake answers 403 to the token of the other audience, so the list only works with the right ones)' (@($hostsLog | Where-Object { $_ -like 'GET graph.microsoft.com auth=True *' }).Count -ge 5 -and @($hostsLog | Where-Object { $_ -notlike 'GET graph.microsoft.com auth=True *' }).Count -eq 0 -and -not (($hostsLog -join '|') -match 'fake-sites-token|fake-graph-token') -and $li.State -eq 'Ready' -and $by['contoso-tool|1.0.0'].Anchored) (($hostsLog | Select-Object -First 3) -join ' | ')
    Test-Check 'download redirect target: the -my variant of the tenant is allowed, another tenant, Graph and a call without hosts are not' ((Test-AVDTuneDownloadUrl 'https://contoso-my.sharepoint.com/x' -AllowedHost $rh) -and -not (Test-AVDTuneDownloadUrl 'https://fabrikam.sharepoint.com/x' -AllowedHost $rh) -and -not (Test-AVDTuneDownloadUrl 'https://fabrikam-my.sharepoint.com/x' -AllowedHost $rh) -and -not (Test-AVDTuneDownloadUrl 'https://graph.microsoft.com/v1.0/x' -AllowedHost $rh) -and -not (Test-AVDTuneDownloadUrl 'https://contoso.sharepoint.com/x')) $null
    & $module { $script:WorkSecurity = { $sec = New-AVDTuneStateSecurity; $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule([System.Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))); $sec } }   # the check runs without elevation: the current user must be able to write into what it creates
    $swContext = { param($l) New-AVDTuneLibraryContext -SitesToken $l.SitesToken -GraphToken $l.GraphToken -SiteUrl $l.SiteUrl -Transport $l.Transport }
    $getFile = { param($ctxL, [int64]$max) $out = Join-Path $tmp ("dl-" + [guid]::NewGuid().ToString("N")); [void](& $module { param($c, $o, $m) $script:LibraryContext = $c; try { Invoke-AVDTuneLibraryGet -Url 'https://graph.microsoft.com/v1.0/drives/drive-1/root:/contoso-tool/1.0.0/installer.zip:/content' -Audience Sites -OutFile $o -MaxBytes $m } finally { $script:LibraryContext = $null } } $ctxL $out $max); $out }
    $libR = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libR -App 'contoso-tool' -Version '1.0.0'); $libR.Store.Redirect = $true
    $f1 = & $getFile (& $swContext $libR) 1MB
    $rl = @($libR.Log)
    Test-Check 'a 302 to SharePoint is followed by hand and the second request carries NO Authorization header (the file arrives, the first request had the token)' ((Test-Path $f1) -and (Get-Item $f1).Length -gt 0 -and $rl[-2] -like 'GET graph.microsoft.com auth=True *' -and $rl[-1] -like 'GET contoso.sharepoint.com auth=False /dl/*') ($rl[-2..-1] -join ' | ')
    $libE = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libE -App 'contoso-tool' -Version '1.0.0'); $libE.Store.Redirect = $true; $libE.Store.RedirectTo = 'https://evil.example.com/steal'
    $eText = Get-ThrownText { & $getFile (& $swContext $libE) 1MB }
    Test-Check 'a 302 to a foreign host is refused and nothing is requested from it' ($eText -like '*redirect to evil.example.com was refused*' -and @($libE.Log | Where-Object { $_ -like '*evil*' }).Count -eq 0) $eText
    $libT2 = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libT2 -App 'contoso-tool' -Version '1.0.0'); $libT2.Store.Redirect = $true; $libT2.Store.RedirectTo = 'https://fabrikam.sharepoint.com/dl/x'
    Test-Check 'a 302 to the SharePoint of another tenant is refused as well' ((Get-ThrownText { & $getFile (& $swContext $libT2) 1MB }) -like '*redirect to fabrikam.sharepoint.com was refused*') $null
    $libH = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libH -App 'contoso-tool' -Version '1.0.0'); $libH.Store.Redirect = $true; $libH.Store.RedirectHops = 6
    Test-Check 'six redirects in a row end the request (five are allowed)' ((Get-ThrownText { & $getFile (& $swContext $libH) 1MB }) -like '*Too many redirects*') $null
    $libH5 = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libH5 -App 'contoso-tool' -Version '1.0.0'); $libH5.Store.Redirect = $true; $libH5.Store.RedirectHops = 5
    $f5 = & $getFile (& $swContext $libH5) 1MB
    Test-Check 'a chain of five redirects still works, and the token is on the first request only' ((Get-Item $f5).Length -gt 0 -and @($libH5.Log | Where-Object { $_ -like '* auth=True *' }).Count -eq 1 -and @($libH5.Log | Where-Object { $_ -like 'GET contoso.sharepoint.com auth=True*' }).Count -eq 0) (($libH5.Log) -join ' | ')
    $libHt = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libHt -App 'contoso-tool' -Version '1.0.0'); $libHt.Store.Redirect = $true; $libHt.Store.RedirectTo = 'http://contoso.sharepoint.com/dl/x'
    $htText = Get-ThrownText { & $getFile (& $swContext $libHt) 1MB }
    Test-Check 'a 302 to http (no TLS) on the right host is refused and nothing is requested from it' ($htText -like '*redirect to contoso.sharepoint.com was refused*' -and @($libHt.Log | Where-Object { $_ -like '*/dl/x*' }).Count -eq 0) $htText
    $libRel = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libRel -App 'contoso-tool' -Version '1.0.0'); $libRel.Store.Redirect = $true; $libRel.Store.RedirectTo = '/dl/x'
    $relText = Get-ThrownText { & $getFile (& $swContext $libRel) 1MB }
    Test-Check 'a relative Location from Graph stays on graph.microsoft.com (checked as a Graph address, here a 404): nothing leaves the host' ($relText -like '*Graph answered 404*' -and @($libRel.Log | Where-Object { $_ -notlike 'GET graph.microsoft.com*' }).Count -eq 0) "$relText / $($libRel.Log -join ' | ')"
    $libRel3 = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libRel3 -App 'contoso-tool' -Version '1.0.0'); $libRel3.Store.Redirect = $true; $libRel3.Store.RedirectTo = '//evil.example.com/x'
    $rel3Text = Get-ThrownText { & $getFile (& $swContext $libRel3) 1MB }
    Test-Check 'a scheme-relative Location (//host/path) to a foreign host is refused and nothing is requested from it' ($rel3Text -like '*redirect to evil.example.com was refused*' -and @($libRel3.Log | Where-Object { $_ -like '*evil*' }).Count -eq 0) $rel3Text
    $libRel2 = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libRel2 -App 'contoso-tool' -Version '1.0.0'); $libRel2.Store.Redirect = $true; $libRel2.Store.RedirectHops = 2; $libRel2.Store.RedirectRelative = $true
    $fRel = & $getFile (& $swContext $libRel2) 1MB
    Test-Check 'a relative Location from the SharePoint host is resolved against it, followed, and carries no token' ((Get-Item $fRel).Length -gt 0 -and @($libRel2.Log | Where-Object { $_ -like 'GET contoso.sharepoint.com auth=False /hop/2' }).Count -eq 1 -and @($libRel2.Log | Where-Object { $_ -like 'GET contoso.sharepoint.com auth=True*' }).Count -eq 0) (($libRel2.Log) -join ' | ')
    $libEm = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libEm -App 'contoso-tool' -Version '1.0.0'); $libEm.Store.Redirect = $true; $libEm.Store.RedirectEmpty = $true
    $emText = Get-ThrownText { & $getFile (& $swContext $libEm) 1MB }
    Test-Check 'a 302 with an empty Location is refused at once (no loop on the same address with the token)' ($emText -like '*without an address*' -and @($libEm.Log | Where-Object { $_ -like 'GET graph.microsoft.com auth=True*installer.zip*' }).Count -eq 1) "$emText / $(@($libEm.Log | Where-Object { $_ -like '*installer.zip*' }).Count)"
    $libP = New-AVDTuneFakeLibrary; $libP.Store.PageSize = 2
    foreach ($n in 1..5) { [void](Add-AVDTuneFakeLibraryPackage $libP -App "pkg-$n" -Version '1.0') }
    $anch = & $module { param($c) $script:LibraryContext = $c; try { Get-AVDTuneIntuneAnchors } finally { $script:LibraryContext = $null } } (& $swContext $libP)
    Test-Check 'paging: the Intune list is followed over @odata.nextLink to the last page (5 apps over 3 requests)' ($anch.Count -eq 5 -and @($libP.Log | Where-Object { $_ -like '*mobileApps*' }).Count -eq 3) "$($anch.Count) $(@($libP.Log | Where-Object { $_ -like '*mobileApps*' }).Count)"
    $libW = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libW -App 'contoso-tool' -Version '1.0.0' -WrongAnchor)
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
    $xw = New-Env
    $rw = Invoke-AVDTuneSoftwareRun -Machine $xw.M -U $xw.U -Root $tmp -LibraryContext (& $swContext $libW) -Items @(New-AVDTuneSoftwareItem -Action Install -Source library -Id 'contoso-tool' -Version '1.0.0')
    Test-Check 'Intune carries another manifest hash than the store: refused, nothing but the manifest downloaded, nothing started' ($rw.Results[0].Status -eq 'Failed' -and $rw.Results[0].Message -like '*does not match the one recorded in Intune*' -and (Get-RunLog $xw.U).Count -eq 0 -and @($libW.Log | Where-Object { $_ -like '*installer.zip*' }).Count -eq 0) $rw.Results[0].Message
    # size limits
    $libZ = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libZ -App 'contoso-tool' -Version '1.0.0')
    $zText = Get-ThrownText { & $getFile (& $swContext $libZ) 10 }
    Test-Check 'a download larger than the limit is stopped and the partial file is removed' ($zText -like '*larger than the allowed 10 bytes*' -and @(Get-ChildItem $tmp -Filter 'dl-*' | Where-Object { $_.Length -gt 0 -and $_.Length -le 10 }).Count -eq 0) $zText
    $libM = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libM -App 'contoso-tool' -Version '1.0.0')
    $libM.Store.Tamper['contoso-tool/1.0.0/manifest.json'] = New-Object byte[] (1MB + 10)
    $xm2 = New-Env
    $rm2 = Invoke-AVDTuneSoftwareRun -Machine $xm2.M -U $xm2.U -Root $tmp -LibraryContext (& $swContext $libM) -Items @(New-AVDTuneSoftwareItem -Action Install -Source library -Id 'contoso-tool' -Version '1.0.0')
    Test-Check 'a manifest.json of more than 1 MB is refused before any hash is made or anything is unpacked' ($rm2.Results[0].Status -eq 'Failed' -and $rm2.Results[0].Message -like '*larger than the allowed*' -and (Get-RunLog $xm2.U).Count -eq 0) $rm2.Results[0].Message
    $libF2 = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libF2 -App 'contoso-tool' -Version '1.0.0')
    $libF2.Store.Tamper['contoso-tool/1.0.0/installer.zip'] = New-Object byte[] ($libF2.Store.Files['contoso-tool/1.0.0/installer.zip'].Length + 500)
    $xf3 = New-Env
    $rf3 = Invoke-AVDTuneSoftwareRun -Machine $xf3.M -U $xf3.U -Root $tmp -LibraryContext (& $swContext $libF2) -Items @(New-AVDTuneSoftwareItem -Action Install -Source library -Id 'contoso-tool' -Version '1.0.0')
    Test-Check 'a file that is longer than the size in the manifest is stopped while it is read (before the hash check)' ($rf3.Results[0].Status -eq 'Failed' -and $rf3.Results[0].Message -like '*larger than the allowed*' -and (Get-RunLog $xf3.U).Count -eq 0) $rf3.Results[0].Message
    $libBig = New-AVDTuneFakeLibrary
    $bigGet = & $module { param($c) $c.Sizes['installer.zip'] = 3GB; $script:LibraryContext = $c; try { Invoke-PackTuneStoreGraph -Path '/drives/drive-1/root:/contoso-tool/1.0.0/installer.zip:/content' -OutFile (Join-Path ([IO.Path]::GetTempPath()) ('big-' + [guid]::NewGuid().ToString('N'))); 'no' } catch { $_.Exception.Message } finally { $script:LibraryContext = $null } } (& $swContext $libBig)
    Test-Check 'a manifest that names a file of more than 2 GB: the download is refused before any request is made' ($bigGet -like '*more than 2 GB*' -and $libBig.Log.Count -eq 0) $bigGet
    $slow = New-Object psobject; $slow | Add-Member -MemberType ScriptMethod -Name Read -Value { param($b, $o, $c) Start-Sleep -Milliseconds 120; $b[$o] = 1; 1 }
    $slowText = & $module { param($s) try { [void](Read-AVDTuneLimited -Stream $s -MaxBytes 1MB -Deadline ([datetime]::UtcNow.AddMilliseconds(400))); 'no' } catch { $_.Exception.Message } } $slow
    Test-Check 'a download that keeps sending slowly is stopped by the overall time limit (the byte limit alone would let it run for ever)' ($slowText -like '*longer than the allowed time*') $slowText
    $libTm = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libTm -App 'contoso-tool' -Version '1.0.0')
    $ctxTm = & $swContext $libTm; $ctxTm.DownloadSeconds = 0
    $tmText = Get-ThrownText { & $getFile $ctxTm 1MB }
    Test-Check 'the time limit of a download is on the context (default 30 minutes); at 0 seconds no request is made' ($tmText -like '*longer than the allowed time*' -and $libTm.Log.Count -eq 0 -and (& $swContext $libTm).DownloadSeconds -eq 1800) $tmText
    $bigAnswer = & $module { $s = New-Object IO.MemoryStream (, ([byte[]](New-Object byte[] (5MB)))); try { [void](Read-AVDTuneLimited -Stream $s -MaxBytes 4MB); 'no' } catch { 'stopped' } }
    Test-Check 'a JSON answer of more than 4 MB is stopped' ($bigAnswer -eq 'stopped') $null
    # \A..\z: a trailing line feed is no valid value
    Test-Check 'a trailing line feed is refused by the checks of id, version, search text, library name and library package name' (-not (Test-AVDTunePackageId "git`n") -and -not (Test-AVDTunePackageVersion "1.0`n") -and -not (Test-AVDTuneSearchText "git`n") -and [bool](Get-ThrownText { New-AVDTuneLibraryContext -SitesToken 'a' -GraphToken 'b' -SiteUrl "https://contoso.sharepoint.com/sites/x`n" }) -and [bool](Get-ThrownText { New-AVDTuneLibraryContext -SitesToken 'a' -GraphToken 'b' -SiteUrl 'https://contoso.sharepoint.com/sites/x' -Library "Lib`n" }) -and [bool](Get-ThrownText { Invoke-AVDTuneSoftwareRun -Machine $xw.M -U $xw.U -Root $tmp -Items @(New-AVDTuneSoftwareItem -Action Install -Source library -Id "app`n" -Version '1.0') }) -and [bool](Get-ThrownText { Invoke-AVDTuneSoftwareRun -Machine $xw.M -U $xw.U -Root $tmp -Items @(New-AVDTuneSoftwareItem -Action Install -Source library -Id 'app' -Version "1.0`n") })) $null
    # zip bomb: real bytes are counted
    $bombZip = Join-Path $tmp 'bomb.zip'
    [IO.File]::WriteAllBytes($bombZip, (New-AVDTuneFakeZip @{ 'a.bin' = (New-Object byte[] 2000000); 'b.bin' = (New-Object byte[] 2000000) }))
    $bombText = Get-ThrownText { Expand-PackTuneZip -Path $bombZip -Destination (Join-Path $tmp 'bomb-out') -MaxBytes 3000000 }
    Test-Check 'zip: a total of the declared sizes over the limit is refused before anything is unpacked (limit 3 MB, two entries of 2 MB)' ($bombText -like '*larger than allowed when unpacked*' -and @(Get-ChildItem -LiteralPath (Join-Path $tmp 'bomb-out') -Force).Count -eq 0) $bombText
    Test-Check 'zip: the same archive within the limit unpacks completely' ((Get-ThrownText { Expand-PackTuneZip -Path $bombZip -Destination (Join-Path $tmp 'bomb-ok') -MaxBytes 5000000 }) -eq $null -and (Get-Item (Join-Path $tmp 'bomb-ok\b.bin')).Length -eq 2000000) $null
    $liar = [byte[]](New-AVDTuneFakeZip @{ 'a.bin' = (New-Object byte[] 2000000) })
    $sig = [byte[]]@(0x50, 0x4B, 0x01, 0x02)
    for ($i = 0; $i -lt $liar.Length - 4; $i++) { if ($liar[$i] -eq 0x50 -and $liar[$i + 1] -eq 0x4B -and $liar[$i + 2] -eq 0x01 -and $liar[$i + 3] -eq 0x02) { [BitConverter]::GetBytes([uint32]1000).CopyTo($liar, $i + 24) } }
    $liarZip = Join-Path $tmp 'liar.zip'; [IO.File]::WriteAllBytes($liarZip, $liar)
    $lieText = Get-ThrownText { Expand-PackTuneZip -Path $liarZip -Destination (Join-Path $tmp 'liar-out') -MaxBytes 5000000 }
    Test-Check 'zip: an entry whose header declares 1000 bytes but holds 2 MB is stopped by the byte counter (the real bytes are counted, not the declared size)' ($lieText -like '*more data than it declares*' -and (-not (Test-Path (Join-Path $tmp 'liar-out\a.bin')) -or (Get-Item (Join-Path $tmp 'liar-out\a.bin')).Length -le 1000)) $lieText
    # work folder, test mode OFF: the default ACL (Administrators and SYSTEM only, protected) on every level; an override of the checks does not count outside the test mode
    $grantMe = { param($p) $a = Get-Acl -LiteralPath $p; $a.SetAccessRuleProtection($false, $false); $a.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule([System.Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))); (New-Object IO.DirectoryInfo $p).SetAccessControl($a) }   # the creator may change the permissions: lets the check clean up after itself
    $elevated = Test-AVDTuneElevated
    $savedFake3 = $env:AVDTUNE_FAKE; $savedRoot3 = $env:AVDTUNE_ROOT; $env:AVDTUNE_FAKE = $null; $env:AVDTUNE_ROOT = $null
    try {
        & $module { $script:WorkSecurity = { $sec = New-AVDTuneStateSecurity; $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule([System.Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))); $sec } }
        $wbase = Join-Path $tmp 'wf'; [void][IO.Directory]::CreateDirectory($wbase)
        $deep = Join-Path $wbase 'software\work\x'
        $deepText = Get-ThrownText { & $module { param($p, $b) New-AVDTuneWorkFolder -Path $p -Base $b } $deep $wbase }
        $levels = @('software', 'software\work', 'software\work\x') | Where-Object { Test-Path -LiteralPath (Join-Path $wbase $_) }
        $levelOk = @($levels | ForEach-Object {
                $acl = Get-Acl -LiteralPath (Join-Path $wbase $_)
                $sids = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value })
                $acl.AreAccessRulesProtected -and @($sids | Where-Object { $_ -notin 'S-1-5-32-544', 'S-1-5-18' }).Count -eq 0 -and $sids.Count -ge 2 })
        # elevated: all three levels exist with the default ACL; not elevated: the first level is made (default ACL), the second one cannot be written into by the creator - which is also what shows the user-friendly override was NOT used
        $acceptLevels = if ($elevated) { $levels.Count -eq 3 -and -not $deepText } else { $levels.Count -eq 1 -and [bool]$deepText }
        Test-Check 'the work folder has the default protected ACL (Administrators and SYSTEM only) on every level below the state folder (software\work\x), also when a check override is set outside the test mode' ($acceptLevels -and @($levelOk | Where-Object { -not $_ }).Count -eq 0 -and $levelOk.Count -ge 1) "$($levels -join ',') / $deepText / $($levelOk -join ',')"
        foreach ($l in $levels) { & $grantMe (Join-Path $wbase $l) }
    }
    finally { $env:AVDTUNE_FAKE = $savedFake3; $env:AVDTUNE_ROOT = $savedRoot3 }
    # work folder, test mode ON with the override of the checks (the current user may write into what it creates)
    & $module { $script:WorkSecurity = { $sec = New-AVDTuneStateSecurity; $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule([System.Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))); $sec } }
    $wbase = Join-Path $tmp 'wfT'; [void][IO.Directory]::CreateDirectory($wbase)
    & $module { param($p, $b) New-AVDTuneWorkFolder -Path $p -Base $b } (Join-Path $wbase 'software\work\x') $wbase
    $acl = Get-Acl -LiteralPath (Join-Path $wbase 'software\work\x')
    Test-Check 'inside the test mode the override works (a developer run without elevation gets three levels it can write into)' ($acl.AreAccessRulesProtected -and (Test-Path (Join-Path $wbase 'software\work\x'))) $null
    Test-Check 'existing levels made by AVDTune are accepted when the work folder is made again' (-not (Get-ThrownText { & $module { param($p, $b) New-AVDTuneWorkFolder -Path $p -Base $b } (Join-Path $wbase 'software\work\y') $wbase })) $null
    $wbase = Join-Path $tmp 'wf3'; [void][IO.Directory]::CreateDirectory((Join-Path $wbase 'software'))
    $inheritText = Get-ThrownText { & $module { param($p, $b) New-AVDTuneWorkFolder -Path $p -Base $b } (Join-Path $wbase 'software\work') $wbase }
    Test-Check 'an existing level that inherits its rules (prepared by someone else) is refused, not just checked for links' ($inheritText -like '*was not prepared by AVDTune*inherits*') $inheritText
    $wbase = Join-Path $tmp 'wf4'; [void][IO.Directory]::CreateDirectory($wbase)
    $foreignSec = New-AVDTuneStateSecurity; $foreignSec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'), 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    (New-Object IO.DirectoryInfo (Join-Path $wbase 'software')).Create($foreignSec)
    $foreignText = Get-ThrownText { & $module { param($p, $b) New-AVDTuneWorkFolder -Path $p -Base $b } (Join-Path $wbase 'software\work') $wbase }
    Test-Check 'an existing level with an explicit rule for another account (Everyone) is refused' ($foreignText -like '*was not prepared by AVDTune*access for S-1-1-0*') $foreignText
    $wbase = Join-Path $tmp 'wf'
    $junction = Join-Path $wbase 'link'; [void](New-Item -ItemType Junction -Path $junction -Target $tmp)
    Test-Check 'a link on the way is refused' ([bool](Get-ThrownText { & $module { param($p, $b) New-AVDTuneWorkFolder -Path $p -Base $b } (Join-Path $junction 'work\x') $wbase })) $null
    [IO.Directory]::Delete($junction)
    $wbase = Join-Path $tmp 'wf2'
    [void][IO.Directory]::CreateDirectory((Join-Path $wbase 'software\work\left1\sub')); [IO.File]::WriteAllText((Join-Path $wbase 'software\work\left1\sub\f.txt'), 'x')
    $cleared = & $module { param($r) Clear-AVDTuneSoftwareWork -Root $r } $wbase
    Test-Check 'work folders that a crash left behind are removed at the start of a run' ($cleared -ge 1 -and @(Get-ChildItem (Join-Path $wbase 'software\work')).Count -eq 0) $cleared
    $wbase = Join-Path $tmp 'wf5'; $linkTarget = Join-Path $tmp 'wf5-target'
    [void][IO.Directory]::CreateDirectory((Join-Path $linkTarget 'work\left2')); [IO.File]::WriteAllText((Join-Path $linkTarget 'work\left2\keep.txt'), 'x'); [void][IO.Directory]::CreateDirectory($wbase)
    [void](New-Item -ItemType Junction -Path (Join-Path $wbase 'software') -Target $linkTarget)
    $clearedLink = & $module { param($r) Clear-AVDTuneSoftwareWork -Root $r } $wbase
    Test-Check "'software' as a link: only the link is removed, what it points to stays untouched" ($clearedLink -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $wbase 'software')) -and (Test-Path -LiteralPath (Join-Path $linkTarget 'work\left2\keep.txt'))) $clearedLink
    $swSource = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Software.psm1'))
    $runBody = $swSource.Substring($swSource.IndexOf('function Invoke-AVDTuneSoftwareRun'))
    Test-Check 'the work folders are cleaned inside a run after the write gate, and not by the page when it only scans' ($runBody.IndexOf('Test-AVDTuneWriteAllowed') -ge 0 -and $runBody.IndexOf('Test-AVDTuneWriteAllowed') -lt $runBody.IndexOf('Clear-AVDTuneSoftwareWork') -and ([IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Software.ps1'))) -notmatch 'Clear-AVDTuneSoftwareWork') $null
    # the MSI is hashed after unpacking, held, and compared through the held handle before msiexec
    $xh = New-Env
    $heldInfo = @{}
    $xh.U.Run = { param($File, [string[]]$Arguments, [int]$TimeoutSeconds = 600)
        if ($File -like '*msiexec*') {
            $msiPath = $Arguments[1]
            $heldInfo.DeleteFailed = $false; try { [IO.File]::Delete($msiPath) } catch { $heldInfo.DeleteFailed = $true }
            $heldInfo.WriteFailed = $false; try { [IO.File]::WriteAllText($msiPath, 'swapped') } catch { $heldInfo.WriteFailed = $true }
            $heldInfo.Text = [IO.File]::ReadAllText($msiPath)
        }
        [void]$xh.U.Log.Add("Run $File $($Arguments -join ' ')"); [pscustomobject]@{ ExitCode = 0; Output = '' } }.GetNewClosure()
    $libMsi = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libMsi -App 'contoso-tool' -Version '1.0.0')
    $rh2 = Invoke-AVDTuneSoftwareRun -Machine $xh.M -U $xh.U -Root $tmp -LibraryContext (& $swContext $libMsi) -Items @(New-AVDTuneSoftwareItem -Action Install -Source library -Id 'contoso-tool' -Version '1.0.0')
    Test-Check 'the MSI is hashed after unpacking, held without write and delete sharing and compared through the held handle: while msiexec runs it can be neither deleted nor replaced' ($rh2.Results[0].Status -eq 'Changed' -and $heldInfo.DeleteFailed -and $heldInfo.WriteFailed -and $heldInfo.Text -eq 'MSI stand-in') ($heldInfo | ConvertTo-Json -Compress)
    $xsw = New-Env
    & $module { $script:BeforeMsiHold = { param($p) [IO.File]::WriteAllText($p, 'swapped between hash and hold') } }
    try { $rsw = Invoke-AVDTuneSoftwareRun -Machine $xsw.M -U $xsw.U -Root $tmp -LibraryContext (& $swContext $libMsi) -Items @(New-AVDTuneSoftwareItem -Action Install -Source library -Id 'contoso-tool' -Version '1.0.0') }
    finally { & $module { $script:BeforeMsiHold = $null } }
    Test-Check 'an MSI that is replaced between the hash after unpacking and the hold is caught by the comparison through the held handle: msiexec is not started' ($rsw.Results[0].Status -eq 'Failed' -and $rsw.Results[0].Message -like '*changed after unpacking*' -and (Get-RunLog $xsw.U).Count -eq 0) $rsw.Results[0].Message
    Close-AVDTuneWriteGate


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
    $clx = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq 'PackTune library' -and $_.ChangeType -eq 'Updated' })
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
    $ctxT = New-AVDTuneLibraryContext -SitesToken $libT.SitesToken -GraphToken $libT.GraphToken -SiteUrl $libT.SiteUrl -Transport $libT.Transport
    $xt = New-Env
    $rt = Invoke-AVDTuneSoftwareRun -Machine $xt.M -U $xt.U -Root $tmp -LibraryContext $ctxT -Items @(New-AVDTuneSoftwareItem -Action Install -Source library -Id 'contoso-tool' -Version '1.0.0')
    Test-Check 'a manifest that differs from the one in Intune: nothing is unpacked, nothing is started' ($rt.Results[0].Status -eq 'Failed' -and $rt.Results[0].Message -like '*does not match the one recorded in Intune*' -and (Get-RunLog $xt.U).Count -eq 0 -and -not (Get-ChildItem (Join-Path $tmp 'software\work') -ErrorAction SilentlyContinue)) $rt.Results[0].Message
    $libF = New-AVDTuneFakeLibrary; [void](Add-AVDTuneFakeLibraryPackage $libF -App 'contoso-tool' -Version '1.0.0')
    $libF.Store.Tamper['contoso-tool/1.0.0/installer.zip'] = [byte[]]@(1, 2, 3)
    $ctxF = New-AVDTuneLibraryContext -SitesToken $libF.SitesToken -GraphToken $libF.GraphToken -SiteUrl $libF.SiteUrl -Transport $libF.Transport
    $xf2 = New-Env
    $rf2 = Invoke-AVDTuneSoftwareRun -Machine $xf2.M -U $xf2.U -Root $tmp -LibraryContext $ctxF -Items @(New-AVDTuneSoftwareItem -Action Install -Source library -Id 'contoso-tool' -Version '1.0.0')
    Test-Check 'a file that differs from the manifest hash: refused, not unpacked, nothing started, work folder removed' ($rf2.Results[0].Status -eq 'Failed' -and $rf2.Results[0].Message -like '*does not match the manifest*' -and (Get-RunLog $xf2.U).Count -eq 0 -and -not (Get-ChildItem (Join-Path $tmp 'software\work') -ErrorAction SilentlyContinue)) $rf2.Results[0].Message
    # zip slip and installer shapes
    $libS = New-AVDTuneFakeLibrary
    [void](Add-AVDTuneFakeLibraryPackage $libS -App 'slip-pkg' -Version '1.0' -InstallerEntries @{ '../../evil.msi' = 'x' })
    [void](Add-AVDTuneFakeLibraryPackage $libS -App 'two-pkg' -Version '1.0' -InstallerEntries @{ 'a.msi' = '1'; 'b.msi' = '2' })
    [void](Add-AVDTuneFakeLibraryPackage $libS -App 'none-pkg' -Version '1.0' -InstallerEntries @{ 'readme.txt' = 'no msi' })
    $ctxS = New-AVDTuneLibraryContext -SitesToken $libS.SitesToken -GraphToken $libS.GraphToken -SiteUrl $libS.SiteUrl -Transport $libS.Transport
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
    $env:AVDTUNE_ROOT = $null; $env:AVDTUNE_FAKE = $null
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-Software: all checks passed.'
