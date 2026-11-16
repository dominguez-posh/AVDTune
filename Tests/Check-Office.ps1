#requires -Version 5.1
<#
.SYNOPSIS
    Checks the Office side (Modules\AVDTune.Office.psm1, issue 35) against the fake machine, the fake Office adapter and a temporary state folder: configuration (validation,
    strict types, fail closed on a bad file), the configuration.xml (Learn sample, escaping, remove, XML attacks), the ODT link from the download page (fixed host, one
    link), the signature checks before every start (package, setup.exe by full path, again right before the start, a swap after the first check), install, reconfigure,
    remove and undo behind the write gate with run record, LastChange and change log, every failure path, detection of the state, the update policies. Nothing is
    downloaded, installed or changed on this computer.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Updates.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Office.psm1') -Force
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeOffice.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Test-Throws([scriptblock]$Block) { try { & $Block | Out-Null; $false } catch { $true } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }

$ctr = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
function New-Master([switch]$NoOffice) {
    $m = New-AVDTuneFakeMachine
    if ($NoOffice) { foreach ($n in 'VersionToReport', 'CDNBaseUrl', 'Platform', 'SharedComputerLicensing', 'UpdatesEnabled') { & $m.RegRemove $ctr $n } }
    $m
}
function Get-Row($Rows, [string]$Id) { @($Rows | Where-Object Id -eq $Id)[0] }
function Reset-OfficeFiles { foreach ($f in 'office-undo.json', 'office-applied.json', 'office-policies-undo.json') { Remove-Item -LiteralPath (Join-Path $tmp "config\$f") -Force -ErrorAction SilentlyContinue } }
function Get-RunLog($O, [string]$Pattern) { @($O.Log | Where-Object { $_ -like $Pattern }) }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-office-' + [guid]::NewGuid().ToString('N'))
try {
    $env:AVDTUNE_ROOT = $tmp
    [void](Initialize-AVDTuneState -Root $tmp)
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-15') -User 'admin1')
    Close-AVDTuneWriteGate
    $log = 'C:\ProgramData\AVDTune\logs\office'

    # ---------------------------------------------------------------- defaults and validation
    $d = Get-AVDTuneOfficeDefaults
    Test-Check 'defaults are the sample of the AVD article and valid' ((@(Test-AVDTuneOfficeConfig $d).Count -eq 0) -and $d.Channel -eq 'MonthlyEnterprise' -and $d.Edition -eq '64' -and $d.Product -eq 'O365ProPlusRetail' -and $d.RemoveMSI -and 'MatchOS' -in $d.Languages -and 'Teams' -in $d.ExcludeApps) $null
    function With([hashtable]$Over) { $c = [ordered]@{ Channel = 'MonthlyEnterprise'; Edition = '64'; Product = 'O365ProPlusRetail'; Languages = @('de-DE'); ExcludeApps = @(); RemoveMSI = $true }; foreach ($k in $Over.Keys) { $c[$k] = $Over[$k] }; [pscustomobject]$c }
    Test-Check 'validation refuses: unknown channel, edition 128, product Visio, no language, language injection, 21 languages, duplicate language, unknown app' (
        (@(Test-AVDTuneOfficeConfig (With @{ Channel = 'Insider' })).Count -ge 1) -and (@(Test-AVDTuneOfficeConfig (With @{ Edition = '128' })).Count -ge 1) -and (@(Test-AVDTuneOfficeConfig (With @{ Product = 'VisioProRetail' })).Count -ge 1) -and
        (@(Test-AVDTuneOfficeConfig (With @{ Languages = @() })).Count -ge 1) -and (@(Test-AVDTuneOfficeConfig (With @{ Languages = @('de-DE"/><Evil') })).Count -ge 1) -and (@(Test-AVDTuneOfficeConfig (With @{ Languages = @(1..21 | ForEach-Object { "xx-A$_" }) })).Count -ge 1) -and
        (@(Test-AVDTuneOfficeConfig (With @{ Languages = @('de-DE', 'DE-de') })).Count -ge 1) -and (@(Test-AVDTuneOfficeConfig (With @{ ExcludeApps = @('Evil') })).Count -ge 1)) $null
    Test-Check 'validation is exact: another case of channel, product or app ID, and a language with a trailing line break are refused' (
        (@(Test-AVDTuneOfficeConfig (With @{ Channel = 'monthlyenterprise' })).Count -ge 1) -and (@(Test-AVDTuneOfficeConfig (With @{ Product = 'o365proplusretail' })).Count -ge 1) -and
        (@(Test-AVDTuneOfficeConfig (With @{ ExcludeApps = @('word') })).Count -ge 1) -and (@(Test-AVDTuneOfficeConfig (With @{ Languages = @("de-DE`n") })).Count -ge 1) -and (@(Test-AVDTuneOfficeConfig (With @{ Languages = @('matchos') })).Count -ge 1)) $null
    Test-Check 'strict types: the text "false" is not $false, a number is not an edition text' ((@(Test-AVDTuneOfficeConfig (With @{ RemoveMSI = 'false' })).Count -ge 1) -and (@(Test-AVDTuneOfficeConfig (With @{ Edition = 64 })).Count -ge 1) -and (@(Test-AVDTuneOfficeConfig $null).Count -ge 1)) $null
    Test-Check 'MatchOS and ll-CC-script language IDs are valid' ((@(Test-AVDTuneOfficeConfig (With @{ Languages = @('MatchOS', 'de-DE', 'sr-Latn-RS', 'fil-PH') })).Count -eq 0)) $null

    # ---------------------------------------------------------------- saved configuration
    Test-Check 'no saved file: the defaults' ((Get-AVDTuneOfficeConfig -Root $tmp).Channel -eq 'MonthlyEnterprise') $null
    $saved = Set-AVDTuneOfficeConfig -Root $tmp -Config (With @{ Channel = 'SemiAnnual'; Languages = @('de-DE', 'en-US'); ExcludeApps = @('Teams', 'Access', 'Teams') })
    $back = Get-AVDTuneOfficeConfig -Root $tmp
    Test-Check 'saved configuration comes back typed, apps sorted and unique, no gate needed' ($back.Channel -eq 'SemiAnnual' -and $back.RemoveMSI -eq $true -and (@($back.ExcludeApps) -join ',') -eq 'Access,Teams' -and (@($back.Languages) -join ',') -eq 'de-DE,en-US') ($back | ConvertTo-Json -Compress)
    Test-Check 'an invalid configuration is not saved' ((Test-Throws { Set-AVDTuneOfficeConfig -Root $tmp -Config (With @{ Channel = 'x' }) }) -and (Get-AVDTuneOfficeConfig -Root $tmp).Channel -eq 'SemiAnnual') $null
    [IO.File]::WriteAllText((Join-Path $tmp 'config\office.json'), '{"Channel":"Current","Edition":"64","Product":"O365ProPlusRetail","Languages":["de-DE"],"ExcludeApps":[],"RemoveMSI":"false"}')
    Test-Check 'a saved file with "false" as text is refused (fail closed, nothing built from it)' ((Get-ThrownText { Get-AVDTuneOfficeConfig -Root $tmp }) -like '*not usable*') $null
    Remove-Item (Join-Path $tmp 'config\office.json') -Force

    # ---------------------------------------------------------------- configuration.xml
    $xml = New-AVDTuneOfficeXml -Config $d -Mode Install -LogPath $log
    $c = Test-AVDTuneOfficeXml $xml
    Test-Check 'xml: Learn sample (monthly enterprise, 64, product, languages, excludes, shared licensing 1, updates FALSE, no UI)' ($c.Ok -and $c.Channel -eq 'MonthlyEnterprise' -and $c.Edition -eq '64' -and $c.Product -eq 'O365ProPlusRetail' -and (@($c.Languages) -join ',') -eq 'en-US,MatchOS' -and (@($c.ExcludeApps) -join ',') -eq 'Groove,Lync,OneDrive,Teams' -and $c.Shared -eq '1' -and $c.UpdatesEnabled -eq 'FALSE') $xml
    Test-Check 'xml: RemoveMSI, FORCEAPPSHUTDOWN, Display None and AcceptEULA, logging into the log folder' ($xml -match '<RemoveMSI />' -and $xml -match 'FORCEAPPSHUTDOWN' -and $xml -match 'Level="None" AcceptEULA="TRUE"' -and $xml -match [regex]::Escape($log)) $xml
    Test-Check 'xml: without RemoveMSI no element' ((New-AVDTuneOfficeXml -Config (With @{ RemoveMSI = $false }) -LogPath $log) -notmatch 'RemoveMSI') $null
    $rx = New-AVDTuneOfficeXml -Config $d -Mode Remove -LogPath $log
    $rc = Test-AVDTuneOfficeXml $rx
    Test-Check 'xml: remove has Remove All and no Add, no shared licensing' ($rc.Ok -and $rc.Remove -and $rx -notmatch '<Add' -and $rx -match 'Remove All="TRUE"') $rx
    Test-Check 'xml: a log path with an ampersand is escaped, one with a quote or ".." is refused' ((Test-AVDTuneOfficeXml (New-AVDTuneOfficeXml -Config $d -LogPath 'C:\a&b\logs')).Ok -and (Test-Throws { New-AVDTuneOfficeXml -Config $d -LogPath 'C:\a"b' }) -and (Test-Throws { New-AVDTuneOfficeXml -Config $d -LogPath 'C:\a\..\b' }) -and (Test-Throws { New-AVDTuneOfficeXml -Config $d -LogPath '\\srv\share\x' })) $null
    Test-Check 'xml: an invalid configuration builds nothing' (Test-Throws { New-AVDTuneOfficeXml -Config (With @{ Languages = @('x"y') }) -LogPath $log }) $null
    $dtd = '<?xml version="1.0"?><!DOCTYPE c [<!ENTITY x SYSTEM "file:///c:/windows/win.ini">]><Configuration>&x;</Configuration>'
    Test-Check 'xml reader: a DTD is refused' (-not (Test-AVDTuneOfficeXml $dtd).Ok) $null

    # ---------------------------------------------------------------- ODT link
    $good = 'https://download.microsoft.com/download/11111111-1111-1111-1111-111111111111/officedeploymenttool_20430-20146.exe'
    $l = Get-AVDTuneOdtLink -PageText "<a href=`"$good`">x</a> and again $good"
    Test-Check 'link: one package link (repeated is one), name and host' ($l.Ok -and $l.Url -eq $good -and $l.FileName -eq 'officedeploymenttool_20430-20146.exe') $l.Error
    $bad = @{
        'another host' = 'https://download.microsoft.com.evil.example/download/11111111-1111-1111-1111-111111111111/officedeploymenttool_20430-20146.exe'
        'http' = 'http://download.microsoft.com/download/11111111-1111-1111-1111-111111111111/officedeploymenttool_20430-20146.exe'
        'user info' = ('https://user:pw' + [char]64 + 'download.microsoft.com/download/11111111-1111-1111-1111-111111111111/officedeploymenttool_20430-20146.exe')
        'other file' = 'https://download.microsoft.com/download/11111111-1111-1111-1111-111111111111/evil.exe'
        'nothing' = '<html>no link</html>'
        'two links' = "$good https://download.microsoft.com/download/00000000-0000-0000-0000-000000000000/officedeploymenttool_10000-10000.exe"
        'empty' = ''
    }
    foreach ($k in $bad.Keys) { Test-Check "link refused: $k" (-not (Get-AVDTuneOdtLink -PageText $bad[$k]).Ok) $null }
    Test-Check 'link refused: a page larger than the limit' (-not (Get-AVDTuneOdtLink -PageText ('x' * (4MB))).Ok) $null
    foreach ($k in 'query', 'suffix', 'escaped query', 'escaped other host') {
        $t = switch ($k) { 'query' { "${good}?x=1" } 'suffix' { "$good.zip" } 'escaped query' { ($good + '?x=1') -replace '/', '\/' } 'escaped other host' { 'https://evil.example/download/11111111-1111-1111-1111-111111111111/officedeploymenttool_20430-20146.exe' -replace '/', '\/' } }
        Test-Check "link refused (strict rules also after unescaping): $k" (-not (Get-AVDTuneOdtLink -PageText $t).Ok) $t
    }
    $esc = Get-AVDTuneOdtLink -PageText ('{"url":"' + ($good -replace '/', '\/') + '","size":1}')
    Test-Check 'link: escaped slashes in the JSON of the page (https:\/\/...) are found, same result as the plain link' ($esc.Ok -and $esc.Url -eq $good -and $esc.FileName -eq 'officedeploymenttool_20430-20146.exe') $esc.Error
    $esc2 = Get-AVDTuneOdtLink -PageText ('{"url":"' + ($good -replace '/', '/') + '"}')
    Test-Check 'link: / is unescaped too, and an escaped and a plain copy of the same link are one link' ($esc2.Ok -and (Get-AVDTuneOdtLink -PageText ("$good " + ($good -replace '/', '\/'))).Ok) $esc2.Error
    Test-Check 'link: an escaped link and a different plain one are two links (refused)' (-not (Get-AVDTuneOdtLink -PageText (($good -replace '/', '\/') + ' https://download.microsoft.com/download/00000000-0000-0000-0000-000000000000/officedeploymenttool_10000-10000.exe')).Ok) $null

    # ---------------------------------------------------------------- signature trust
    function Sig([hashtable]$Over) { $c = $ms.Clone(); foreach ($k in $Over.Keys) { $c[$k] = $Over[$k] }; [pscustomobject]$c }
    $ms = @{ Valid = $true; Status = 'Valid'; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Issuer = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US'; OriginalFilename = 'officedeploymenttool_20430-20146.exe' }
    Test-Check 'package trust: Microsoft signature and a versioned original name' ((Test-AVDTuneOdtPackageTrust ([pscustomobject]$ms)).Ok) $null
    Test-Check 'package trust refuses: other signer, other issuer, unsigned, other original name' (
        -not (Test-AVDTuneOdtPackageTrust (Sig @{ Subject = 'CN=Evil Corp, O=Evil Corp, C=US' })).Ok -and
        -not (Test-AVDTuneOdtPackageTrust (Sig @{ Issuer = 'CN=Evil CA, O=Evil, C=US' })).Ok -and
        -not (Test-AVDTuneOdtPackageTrust (Sig @{ Valid = $false; Status = 'NotSigned' })).Ok -and
        -not (Test-AVDTuneOdtPackageTrust (Sig @{ OriginalFilename = 'evil.exe' })).Ok) $null
    $odtSig = @{ OriginalFilename = 'setup.exe'; FileMajor = 16; ProductName = 'Microsoft Office'; FileDescription = 'Microsoft Office Deployment Tool' }
    Test-Check 'odt-setup trust: Microsoft signature, original file name setup.exe, product and description of the ODT' ((Test-AVDTuneToolTrust -Signature (Sig $odtSig) -Name 'odt-setup').Ok) $null
    Test-Check 'a generic setup.exe is not in the shared trust list any more: refused by name, and another Microsoft-signed setup.exe (other product, other description, other original name, other signer) is refused as odt-setup' (
        -not (Test-AVDTuneToolTrust -Signature (Sig $odtSig) -Name 'setup.exe').Ok -and
        -not (Test-AVDTuneToolTrust -Signature (Sig @{ OriginalFilename = 'setup.exe'; ProductName = 'Windows Installer'; FileDescription = 'Windows Installer Setup' }) -Name 'odt-setup').Ok -and
        -not (Test-AVDTuneToolTrust -Signature (Sig @{ OriginalFilename = 'setup.exe'; ProductName = 'Microsoft Office'; FileDescription = 'Installer' }) -Name 'odt-setup').Ok -and
        -not (Test-AVDTuneToolTrust -Signature (Sig @{ OriginalFilename = 'setup.exe' }) -Name 'odt-setup').Ok -and
        -not (Test-AVDTuneToolTrust -Signature (Sig @{ OriginalFilename = 'SETUP.EXE'; ProductName = 'Microsoft Office'; FileDescription = 'Microsoft Office Deployment Tool' }) -Name 'odt-setup').Ok -and
        -not (Test-AVDTuneToolTrust -Signature (Sig @{ OriginalFilename = 'cmd.exe'; ProductName = 'Microsoft Office'; FileDescription = 'Microsoft Office Deployment Tool' }) -Name 'odt-setup').Ok -and
        -not (Test-AVDTuneToolTrust -Signature (Sig @{ Subject = 'CN=Evil Corp, O=Evil Corp, C=US'; OriginalFilename = 'setup.exe'; ProductName = 'Microsoft Office'; FileDescription = 'Microsoft Office Deployment Tool' }) -Name 'odt-setup').Ok) $null
    Test-Check 'odt-setup identity: the Office prefix separates nothing (other Office components, a suffix, a line break, another case), file version major must be 16' (
        -not (Test-AVDTuneToolTrust -Signature (Sig @{ OriginalFilename = 'setup.exe'; FileMajor = 16; ProductName = 'Microsoft Office'; FileDescription = 'Microsoft Office Excel' }) -Name 'odt-setup').Ok -and
        -not (Test-AVDTuneToolTrust -Signature (Sig @{ OriginalFilename = 'setup.exe'; FileMajor = 16; ProductName = 'Microsoft Office Professional'; FileDescription = 'Microsoft Office Deployment Tool' }) -Name 'odt-setup').Ok -and
        -not (Test-AVDTuneToolTrust -Signature (Sig @{ OriginalFilename = 'setup.exe'; FileMajor = 16; ProductName = 'Microsoft Office'; FileDescription = "Microsoft Office Deployment Tool`n" }) -Name 'odt-setup').Ok -and
        -not (Test-AVDTuneToolTrust -Signature (Sig @{ OriginalFilename = 'setup.exe'; FileMajor = 16; ProductName = 'microsoft office'; FileDescription = 'Microsoft Office Deployment Tool' }) -Name 'odt-setup').Ok -and
        -not (Test-AVDTuneToolTrust -Signature (Sig @{ OriginalFilename = 'setup.exe'; FileMajor = 15; ProductName = 'Microsoft Office'; FileDescription = 'Microsoft Office Deployment Tool' }) -Name 'odt-setup').Ok -and
        -not (Test-AVDTuneToolTrust -Signature (Sig @{ OriginalFilename = 'setup.exe'; ProductName = 'Microsoft Office'; FileDescription = 'Microsoft Office Deployment Tool' }) -Name 'odt-setup').Ok) $null
    Test-Check 'unpacked folder: exactly setup.exe plus configuration-*.xml (a DLL, a second program, a folder, another case of setup.exe, two setup.exe are refused)' (
        (Test-AVDTuneOdtFolderNames @('setup.exe', 'configuration-Office365-x64.xml')) -and (Test-AVDTuneOdtFolderNames @('setup.exe')) -and
        -not (Test-AVDTuneOdtFolderNames @('setup.exe', 'evil.dll')) -and -not (Test-AVDTuneOdtFolderNames @('setup.exe', 'sub')) -and -not (Test-AVDTuneOdtFolderNames @('SETUP.EXE')) -and
        -not (Test-AVDTuneOdtFolderNames @('configuration-x.xml')) -and -not (Test-AVDTuneOdtFolderNames @('setup.exe', 'setup.exe')) -and -not (Test-AVDTuneOdtFolderNames @('setup.exe', 'configuration-x.xml.exe')) -and -not (Test-AVDTuneOdtFolderNames @('setup.exe', "configuration-x.xml`n"))) $null
    Test-Check 'package original name: the pattern is anchored at the end (a line break, a suffix, a wrong build format are refused)' (
        (Test-AVDTuneOdtPackageTrust (Sig @{ OriginalFilename = 'officedeploymenttool.exe' })).Ok -and
        -not (Test-AVDTuneOdtPackageTrust (Sig @{ OriginalFilename = "officedeploymenttool_20430-20146.exe`n" })).Ok -and
        -not (Test-AVDTuneOdtPackageTrust (Sig @{ OriginalFilename = 'officedeploymenttool_20430-20146.exe.bat' })).Ok -and
        -not (Test-AVDTuneOdtPackageTrust (Sig @{ OriginalFilename = 'officedeploymenttool_1-2.exe' })).Ok -and
        -not (Test-AVDTuneOdtPackageTrust (Sig @{ OriginalFilename = 'officedeploymenttoolx.exe' })).Ok) $null

    # ---------------------------------------------------------------- detection of the state and the rows
    $m = New-Master
    $rows = @(Get-AVDTuneOfficeRows -Machine $m -Config $d)
    Test-Check 'rows: the default master (monthly, x64, shared 1, updates FALSE) is green where it is configured, update policies missing' ((Get-Row $rows 'office.channel').Status -eq 'green' -and (Get-Row $rows 'office.platform').Status -eq 'green' -and (Get-Row $rows 'office.shared').Status -eq 'green' -and (Get-Row $rows 'office.updates').Status -eq 'green' -and (Get-Row $rows 'office.updateui').Status -eq 'yellow' -and (Get-Row $rows 'office.multisession').Reason -like '*multi-session*') (($rows | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ' ')
    Test-Check 'rows: not installed is red and the only row' ((@(Get-AVDTuneOfficeRows -Machine (New-Master -NoOffice) -Config $d)).Count -eq 1 -and (Get-AVDTuneOfficeRows -Machine (New-Master -NoOffice) -Config $d)[0].Status -eq 'red') $null
    $m2 = New-Master; & $m2.RegSet $ctr 'SharedComputerLicensing' '0' 'String'; & $m2.RegSet $ctr 'UpdatesEnabled' 'TRUE' 'String'
    $r2 = @(Get-AVDTuneOfficeRows -Machine $m2 -Config $d)
    Test-Check 'rows: shared licensing off and updates enabled are red with the fix' ((Get-Row $r2 'office.shared').Status -eq 'red' -and (Get-Row $r2 'office.shared').Fix -like '*SharedComputerLicensing*' -and (Get-Row $r2 'office.updates').Status -eq 'red') $null
    $r3 = @(Get-AVDTuneOfficeRows -Machine $m -Config (With @{ Channel = 'Current'; Edition = '32' }))
    Test-Check 'rows: another configured channel or edition is yellow and says what is installed' ((Get-Row $r3 'office.channel').Status -eq 'yellow' -and (Get-Row $r3 'office.channel').Reason -like '*Monthly Enterprise*' -and (Get-Row $r3 'office.platform').Status -eq 'yellow') $null
    & $m.RegSet "$ctr" 'ProductReleaseIds' 'O365ProPlusRetail' 'String'; & $m.RegSet 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\ProductReleaseIDs\O365ProPlusRetail\en-us' 'x' 1 'DWord'
    $r4 = @(Get-AVDTuneOfficeRows -Machine $m -Config (With @{ Languages = @('de-DE', 'MatchOS') }))
    Test-Check 'rows: a missing language is yellow (not verified against Learn), MatchOS is not counted' ((Get-Row $r4 'office.languages').Status -eq 'yellow' -and (Get-Row $r4 'office.languages').Reason -like '*de-DE*' -and -not (Get-Row $r4 'office.languages').Verified -and (Get-Row $r4 'office.product').Status -eq 'green') (Get-Row $r4 'office.languages').Reason
    $m5 = New-Master; & $m5.RegSet $ctr 'ProductReleaseIds' 'ProPlus2021Volume' 'String'
    Test-Check 'rows: a product that multi-session does not support is red' ((Get-Row @(Get-AVDTuneOfficeRows -Machine $m5 -Config $d) 'office.product').Status -eq 'red') $null
    Test-Check 'every row has a Learn source, a reason or a fix' (-not (@($rows + $r2 + $r3 + $r4 | Where-Object { $_.Source -notmatch '^https://learn\.microsoft\.com/' -or ((-not $_.Reason) -and (-not $_.Fix)) }).Count)) $null
    Test-Check 'rows: every row that Learn does not state is marked not verified with a note' (-not (@($rows + $r4 | Where-Object { -not $_.Verified -and -not $_.Note }).Count)) $null

    # ---------------------------------------------------------------- install behind the gate
    $m = New-Master -NoOffice; $o = New-AVDTuneFakeOffice -Machine $m
    Test-Check 'install without the open gate is refused, nothing asked, no state' ((Test-Throws { Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Install -Config $d }) -and $o.Log.Count -eq 0 -and -not (Test-Path (Join-Path $tmp 'config\office-undo.json'))) $null
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
    Reset-OfficeFiles
    $ri = Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Install -Config $d -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'install: Changed, registered, shared licensing on, updates off' ($ri.Setup.Status -eq 'Changed' -and $ri.Setup.After.Installed -and $ri.Setup.After.SharedLicensing -and $ri.Setup.After.UpdatesEnabled -eq $false -and $ri.Setup.After.Channel -eq 'Monthly Enterprise Channel') $ri.Setup.Message
    $dl = @(Get-RunLog $o 'Download *'); $runs = @(Get-RunLog $o 'Run *')
    Test-Check 'install: one download from download.microsoft.com, package run before setup.exe, setup.exe /configure with the configuration in the same folder' ($dl.Count -eq 1 -and $dl[0] -like 'Download https://download.microsoft.com/*' -and $runs.Count -eq 2 -and $runs[0] -like '*odt-package.exe /quiet /extract:*' -and $runs[1] -like 'Run C:\fake\temp\office-0\odt\setup.exe /configure C:\fake\temp\office-0\configuration.xml') ($runs -join ' | ')
    $order = @($o.Log | Where-Object { $_ -like 'VerifySignature*' -or $_ -like 'Run *' })
    $iSetupRun = [array]::IndexOf($order, ($order | Where-Object { $_ -like 'Run *setup.exe*' } | Select-Object -First 1))
    Test-Check 'install: signature of the package before its run, of setup.exe twice and the last one directly before the start' ($order[0] -eq 'VerifySignature odt-package.exe' -and $order[1] -like 'Run *odt-package.exe*' -and $order[$iSetupRun - 1] -eq 'VerifySignature setup.exe' -and $order[$iSetupRun - 2] -eq 'VerifySignature setup.exe') ($order -join ' | ')
    $lg = @($o.Log)
    $iProt = [array]::IndexOf($lg, ($lg | Where-Object { $_ -like 'IsProtectedFolder *\odt' } | Select-Object -First 1))
    $iHold = [array]::IndexOf($lg, ($lg | Where-Object { $_ -like 'HoldFile *setup.exe' } | Select-Object -First 1))
    $iV1 = [array]::IndexOf($lg, 'VerifySignature setup.exe'); $iRunS = [array]::IndexOf($lg, ($lg | Where-Object { $_ -like 'Run *setup.exe*' } | Select-Object -First 1))
    $iRel = [array]::IndexOf($lg, ($lg | Where-Object { $_ -like 'ReleaseFile *setup.exe' } | Select-Object -First 1)); $iRm = [array]::IndexOf($lg, ($lg | Where-Object { $_ -like 'RemoveFolder *' } | Select-Object -First 1))
    Test-Check 'install: the unpacked folder is checked, setup.exe is held before its first check and released only after its process ended and before the folder is removed' ($iProt -ge 0 -and $iProt -lt $iHold -and $iHold -lt $iV1 -and $iV1 -lt $iRunS -and $iRunS -lt $iRel -and $iRel -lt $iRm) ($lg -join ' | ')
    Test-Check 'install: the work folder is removed at the end' (@(Get-RunLog $o 'RemoveFolder *').Count -eq 1) $null
    Test-Check 'install: the configuration handed to setup.exe is the built one (shared licensing, log folder below the state root)' ($o.Store.Texts['C:\fake\temp\office-0\configuration.xml'] -match 'SharedComputerLicensing' -and $o.Store.Texts['C:\fake\temp\office-0\configuration.xml'] -match [regex]::Escape((Join-Path $tmp 'logs\office'))) $null
    $cl = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Office' })
    Test-Check 'install: run record, LastChange, change log entry Added with the settings' (@(Get-AVDTuneRun -Root $tmp | Where-Object Plan -eq 'Office install').Count -eq 1 -and $null -ne (Get-AVDTuneState $tmp).LastChange -and $cl.Count -eq 1 -and $cl[0].ChangeType -eq 'Added' -and $cl[0].Text -like '*MonthlyEnterprise*' -and $cl[0].Text -like '*excluded Groove/Lync/OneDrive/Teams*') ($cl | ConvertTo-Json -Compress)
    Test-Check 'install: undo record says Office was not there; applied configuration kept' ((Read-AVDTuneJson (Join-Path $tmp 'config\office-undo.json')).BeforeInstalled -eq $false -and (Read-AVDTuneJson (Join-Path $tmp 'config\office-applied.json')).Channel -eq 'MonthlyEnterprise') $null
    Test-Check 'install: the state of the machine now reads green in the rows' (@(Get-AVDTuneOfficeRows -Machine $m -Config $d | Where-Object { $_.Status -eq 'red' }).Count -eq 0) $null

    # ---------------------------------------------------------------- reconfigure, undo does not overwrite the older record
    $o.Log.Clear()
    $cfg2 = With @{ Channel = 'SemiAnnual'; Languages = @('de-DE', 'en-US'); ExcludeApps = @('Teams') }
    $rr = Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Install -Config $cfg2 -User 'admin1' -SnapshotId 'snap-check'
    $cl = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Office' } | Select-Object -Last 1)
    Test-Check 'reconfigure: Changed to the new channel, change log type Changed' ($rr.Setup.Status -eq 'Changed' -and $rr.Setup.After.Channel -eq 'Semi-Annual Enterprise Channel' -and $cl[0].ChangeType -eq 'Changed' -and $rr.Setup.Message -like 'Reconfigured*') $rr.Setup.Message
    Test-Check 'reconfigure: the undo record of the first change is not overwritten' ((Read-AVDTuneJson (Join-Path $tmp 'config\office-undo.json')).BeforeInstalled -eq $false) $null
    $ru = Invoke-AVDTuneOfficeUndo -Machine $m -O $o -Root $tmp -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'undo after the first install: Office is removed, records cleaned, change log Removed' ($ru.Setup.Status -eq 'Changed' -and -not (Get-AVDTuneOfficeInfo $m).Installed -and -not (Test-Path (Join-Path $tmp 'config\office-undo.json')) -and -not (Test-Path (Join-Path $tmp 'config\office-applied.json')) -and @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Office' -and $_.ChangeType -eq 'Removed' }).Count -eq 1) $ru.Setup.Message
    Test-Check 'undo with no record: refused' ((Get-ThrownText { Invoke-AVDTuneOfficeUndo -Machine $m -O $o -Root $tmp }) -like '*nothing to undo*') $null

    # undo when Office was there before: without an earlier configuration there is no undo, with one the earlier configuration comes back
    $m = New-Master; $o = New-AVDTuneFakeOffice -Machine $m; Reset-OfficeFiles
    [void](Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Install -Config $cfg2 -User 'admin1' -SnapshotId 'snap-check')
    Test-Check 'undo, Office was there before and the earlier configuration is not known: no undo, says what to do, nothing run' ((Get-ThrownText { $o.Log.Clear(); Invoke-AVDTuneOfficeUndo -Machine $m -O $o -Root $tmp }) -like '*earlier configuration is not known*' -and $o.Log.Count -eq 0) $null
    Reset-OfficeFiles
    Write-AVDTuneFile (Join-Path $tmp 'config\office-applied.json') ($d | ConvertTo-Json -Depth 4)
    [void](Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Install -Config $cfg2 -User 'admin1' -SnapshotId 'snap-check')
    $ru = Invoke-AVDTuneOfficeUndo -Machine $m -O $o -Root $tmp -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'undo with a known earlier configuration: reinstalled with it (monthly channel again)' ($ru.Setup.Status -eq 'Changed' -and (Get-AVDTuneOfficeInfo $m).Channel -eq 'Monthly Enterprise Channel') $ru.Setup.Message

    # Reconfigure -> Remove -> Remove -> Undo must still bring back the state before the first change (the second Remove, Unchanged, must not delete the record)
    $m = New-Master; $o = New-AVDTuneFakeOffice -Machine $m; Reset-OfficeFiles
    Write-AVDTuneFile (Join-Path $tmp 'config\office-applied.json') ($d | ConvertTo-Json -Depth 4)
    [void](Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Install -Config $cfg2 -User 'admin1' -SnapshotId 'snap-check')
    [void](Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Remove -User 'admin1' -SnapshotId 'snap-check')
    $undoFile = Join-Path $tmp 'config\office-undo.json'
    $rm2 = Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Remove -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'undo record: a second Remove (Unchanged) does not delete the record the first change wrote' ($rm2.Setup.Status -eq 'Unchanged' -and (Test-Path $undoFile) -and (Read-AVDTuneJson $undoFile).BeforeInstalled -eq $true) $null
    $ru = Invoke-AVDTuneOfficeUndo -Machine $m -O $o -Root $tmp -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'reconfigure, remove, remove, undo: the state before the first change is back (monthly channel), the record is gone after the successful undo' ($ru.Setup.Status -eq 'Changed' -and (Get-AVDTuneOfficeInfo $m).Channel -eq 'Monthly Enterprise Channel' -and -not (Test-Path $undoFile)) $ru.Setup.Message

    # LastChange only when something is about to change; the early analysis exits (nothing to remove, invalid configuration) leave it and the undo record alone
    $mark = '2000-01-01T00:00:00.0000000Z'
    $m = New-Master -NoOffice; $o = New-AVDTuneFakeOffice -Machine $m; Reset-OfficeFiles
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastChange = $mark })
    $rn = Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Remove -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'LastChange: Remove with nothing installed (Unchanged) does not set it and writes no undo record' ($rn.Setup.Status -eq 'Unchanged' -and (Get-AVDTuneState $tmp).LastChange -eq $mark -and -not (Test-Path $undoFile)) (Get-AVDTuneState $tmp).LastChange
    $rb2 = Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Install -Config (With @{ Languages = @('x"y') }) -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'LastChange: an invalid configuration (nothing touched) does not set it and writes no undo record' ($rb2.Setup.Code -eq 'BadConfig' -and (Get-AVDTuneState $tmp).LastChange -eq $mark -and -not (Test-Path $undoFile)) (Get-AVDTuneState $tmp).LastChange
    $ri2 = Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Install -Config $d -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'LastChange: a real install sets it' ($ri2.Setup.Status -eq 'Changed' -and (Get-AVDTuneState $tmp).LastChange -ne $mark) $null

    # the undo record is read typed: "false" is not $false
    foreach ($bi in '"false"', '"true"', '0', '1', 'null') {
        $m = New-Master; $o = New-AVDTuneFakeOffice -Machine $m; Reset-OfficeFiles
        Write-AVDTuneFile $undoFile ('{"At":"2026-11-15T10:00:00.0000000Z","BeforeInstalled":' + $bi + ',"BeforeBuild":"","PreviousConfig":null}')
        Test-Check "undo record is typed: BeforeInstalled $bi is refused, nothing is run" ((Get-ThrownText { Invoke-AVDTuneOfficeUndo -Machine $m -O $o -Root $tmp }) -like '*not usable*' -and $o.Log.Count -eq 0 -and (Get-AVDTuneOfficeInfo $m).Installed) $null
    }
    Reset-OfficeFiles

    # what the user is told before Remove and Undo
    $m = New-Master; & $m.RegSet $ctr 'ProductReleaseIds' 'O365ProPlusRetail,VisioProRetail' 'String'
    $rt = Get-AVDTuneOfficeRemoveText -Machine $m
    Test-Check 'remove text: names every product that Remove All takes off, and the limits of Undo (build, languages, RemoveMSI)' ($rt -like '*O365ProPlusRetail*' -and $rt -like '*VisioProRetail*' -and $rt -like '*ALL*' -and $rt -like '*not the earlier build*' -and $rt -like '*RemoveMSI*' -and $rt -like '*languages*') $rt
    Write-AVDTuneFile $undoFile '{"At":"2026-11-15T10:00:00.0000000Z","BeforeInstalled":false,"BeforeBuild":"","PreviousConfig":null}'
    $ut = Get-AVDTuneOfficeUndoText -Root $tmp
    Test-Check 'undo text: says what happens and what it cannot bring back' ($ut -like '*removed again*' -and $ut -like '*not the earlier build*' -and $ut -like '*RemoveMSI*') $ut
    Reset-OfficeFiles

    # ---------------------------------------------------------------- remove
    $m = New-Master; $o = New-AVDTuneFakeOffice -Machine $m; Reset-OfficeFiles
    $rm = Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Remove -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'remove: Changed, no longer registered, the configuration of the remove is Remove All and has no Add' ($rm.Setup.Status -eq 'Changed' -and -not (Get-AVDTuneOfficeInfo $m).Installed -and ($o.Store.Texts.Values | Select-Object -First 1) -match 'Remove All' -and ($o.Store.Texts.Values | Select-Object -First 1) -notmatch '<Add') $rm.Setup.Message
    $o.Log.Clear(); Reset-OfficeFiles
    $rm2 = Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Remove -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'remove when nothing is installed: Unchanged, nothing downloaded, no undo record left behind' ($rm2.Setup.Status -eq 'Unchanged' -and @(Get-RunLog $o 'Download*').Count -eq 0 -and -not (Test-Path (Join-Path $tmp 'config\office-undo.json'))) $null

    # ---------------------------------------------------------------- failure paths (each also sets LastChange and writes a Note, nothing half done)
    function Fail-Case([string]$Name, [hashtable]$Seed, [string]$Code, [scriptblock]$Extra) {
        $m = New-Master -NoOffice; $o = New-AVDTuneFakeOffice -Machine $m -Seed $Seed; Reset-OfficeFiles
        $n0 = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Office' -and $_.ChangeType -eq 'Note' }).Count
        $r = Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Install -Config $d -User 'admin1' -SnapshotId 'snap-check'
        $n1 = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Office' -and $_.ChangeType -eq 'Note' }).Count
        $ok = ($r.Setup.Status -eq 'Failed' -and $r.Setup.Code -eq $Code -and $n1 -eq $n0 + 1 -and $r.Result.Status -eq 'Failed')
        if ($Extra) { $ok = $ok -and [bool](& $Extra $o $m) }
        Test-Check "failure: $Name" $ok "$($r.Setup.Code): $($r.Setup.Message)"
    }
    Fail-Case 'the download page cannot be read' @{ Page = @{ Ok = $false; Text = ''; Error = 'fake: no connection' } } 'NoPage' { param($o) @(Get-RunLog $o 'Download*').Count -eq 0 }
    Fail-Case 'the page names no package' @{ Page = @{ Ok = $true; Text = '<html></html>'; Error = '' } } 'NoLink' { param($o) @(Get-RunLog $o 'Download*').Count -eq 0 }
    Fail-Case 'the page names a package on another host' @{ Page = @{ Ok = $true; Text = 'https://evil.example/download/00000000-1111-2222-3333-444444444444/officedeploymenttool_19999-20000.exe'; Error = '' } } 'NoLink' { param($o) @(Get-RunLog $o 'Download*').Count -eq 0 }
    Fail-Case 'the download folder is not protected: nothing is downloaded' @{ Protected = $false } 'NotProtected' { param($o) @(Get-RunLog $o 'Download*').Count -eq 0 }
    Fail-Case 'the download fails' @{ DownloadFails = $true } 'Download' { param($o) @(Get-RunLog $o 'Run *').Count -eq 0 -and @(Get-RunLog $o 'RemoveFolder*').Count -eq 1 }
    Fail-Case 'the package is signed by someone else: it is not started' @{ Signatures = @{ 'odt-package.exe' = @{ Valid = $true; Subject = 'CN=Evil Corp, O=Evil Corp, C=US'; Issuer = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US' } } } 'BadSignature' { param($o) @(Get-RunLog $o 'Run *').Count -eq 0 }
    Fail-Case 'the package is not signed: it is not started' @{ Signatures = @{ 'odt-package.exe' = @{ Valid = $false; Subject = ''; Issuer = '' } } } 'BadSignature' { param($o) @(Get-RunLog $o 'Run *').Count -eq 0 }
    Fail-Case 'the package does not unpack' @{ PackageExit = 5 } 'Unpack' { param($o) @(Get-RunLog $o 'Run *setup.exe*').Count -eq 0 }
    Fail-Case 'setup.exe is not in the package' @{ NoSetup = $true } 'NoSetup' { param($o) @(Get-RunLog $o 'Run *setup.exe*').Count -eq 0 }
    Fail-Case 'the unpacked folder is not protected: setup.exe is neither held nor started' @{ ProtectedOdt = $false } 'NotProtected' { param($o) @(Get-RunLog $o 'Run *setup.exe*').Count -eq 0 -and @(Get-RunLog $o 'HoldFile*').Count -eq 0 }
    Fail-Case 'the unpacked folder holds a second file: setup.exe is not started' @{ OdtFiles = @('setup.exe', 'evil.dll') } 'BadContents' { param($o) @(Get-RunLog $o 'Run *setup.exe*').Count -eq 0 }
    Fail-Case 'setup.exe cannot be held: it is not started' @{ HoldFails = $true } 'NoSetup' { param($o) @(Get-RunLog $o 'Run *setup.exe*').Count -eq 0 -and @(Get-RunLog $o 'VerifySignature setup.exe').Count -eq 0 }
    Fail-Case 'setup.exe is a Microsoft-signed setup.exe of another product: it is not started, and the hold is released' @{ Signatures = @{ 'setup.exe' = @{ Valid = $true; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US'; Issuer = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US'; ProductName = 'Windows Installer'; FileDescription = 'Windows Installer Setup' } } } 'BadSignature' { param($o) @(Get-RunLog $o 'Run *setup.exe*').Count -eq 0 -and @(Get-RunLog $o 'ReleaseFile*').Count -eq 1 }
    Fail-Case 'setup.exe is signed by someone else: it is not started' @{ Signatures = @{ 'setup.exe' = @{ Valid = $true; Subject = 'CN=Evil Corp, O=Evil Corp, C=US'; Issuer = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US' } } } 'BadSignature' { param($o) @(Get-RunLog $o 'Run *setup.exe*').Count -eq 0 }
    Fail-Case 'setup.exe carries another original file name: it is not started' @{ Signatures = @{ 'setup.exe' = @{ Valid = $true; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US'; Issuer = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US'; OriginalFilename = 'cmd.exe' } } } 'BadSignature' { param($o) @(Get-RunLog $o 'Run *setup.exe*').Count -eq 0 }
    Fail-Case 'setup.exe is swapped after the first check: the check right before the start catches it' @{ SwapSetupAfterCheck = $true } 'BadSignature' { param($o) @(Get-RunLog $o 'Run *setup.exe*').Count -eq 0 -and $o.Store.SetupChecks -eq 2 }
    Fail-Case 'setup.exe returns an error code' @{ SetupExit = 1603 } 'Exit1603' { param($o) @(Get-RunLog $o 'RemoveFolder*').Count -eq 1 }
    Fail-Case 'setup.exe says 0 but nothing is registered' @{ ConfigureNoEffect = $true } 'NotRegistered' $null
    Test-Check 'failures set LastChange (also a failed attempt may have changed the master)' ($null -ne (Get-AVDTuneState $tmp).LastChange) $null
    $m = New-Master -NoOffice; $o = New-AVDTuneFakeOffice -Machine $m; Reset-OfficeFiles
    $bad = Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Install -Config (With @{ Languages = @('x"y') })
    Test-Check 'failure: an invalid configuration reaches neither the network nor setup.exe' ($bad.Setup.Code -eq 'BadConfig' -and $o.Log.Count -eq 0) $null
    $m = New-Master -NoOffice; $o = New-AVDTuneFakeOffice -Machine $m -Seed @{ SetupExit = 3010 }; Reset-OfficeFiles
    $rb = Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Install -Config $d -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'exit code 3010 is a success that asks for a restart' ($rb.Setup.Status -eq 'Changed' -and $rb.Result.Reboot -and $rb.Run.Reboot) $null
    # a failing run whose output carries secret-looking text: nothing of it may reach any file of the state folder (run record, change log, state, undo and applied records) or the messages
    $m = New-Master -NoOffice; $o = New-AVDTuneFakeOffice -Machine $m -Seed @{ SetupExit = 1603; SetupOutput = 'AccountKey=LEAKCANARY1 Bearer LEAKCANARY2 password=LEAKCANARY3 sig=LEAKCANARY4' }; Reset-OfficeFiles
    $rl = Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Install -Config $d -User 'admin1' -SnapshotId 'snap-check'
    $leak = (@(Get-ChildItem -LiteralPath $tmp -Recurse -File -Force | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n") + ($rl | ConvertTo-Json -Depth 6)
    Test-Check 'no token, key or password text in any stored file or message (the failing setup.exe had such output)' ($rl.Setup.Status -eq 'Failed' -and $rl.Setup.Code -eq 'Exit1603' -and $leak -notmatch '(?i)accountkey|bearer|password|sig=|LEAKCANARY') $null

    # ---------------------------------------------------------------- update policies (registry steps)
    $m = New-Master; $pk = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'; Reset-OfficeFiles
    & $m.RegSet $pk 'hideupdatenotifications' 0 'DWord'
    $m.Log.Clear()
    $dry = Set-AVDTuneOfficePolicies -Machine $m -Root $tmp -WhatIf
    Test-Check 'policies: dry run changes nothing, writes no record' ($dry.WhatIf -and @($dry.Results | Where-Object Status -eq 'WhatIf').Count -eq 2 -and @($m.Log | Where-Object { $_ -like 'RegSet*' }).Count -eq 0 -and -not (Test-Path (Join-Path $tmp 'config\office-policies-undo.json'))) $null
    Close-AVDTuneWriteGate
    Test-Check 'policies: refused without the open gate' (Test-Throws { Set-AVDTuneOfficePolicies -Machine $m -Root $tmp }) $null
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
    $ap = Set-AVDTuneOfficePolicies -Machine $m -Root $tmp -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'policies: both values 1, change log entries, the earlier value 0 kept for undo' ((& $m.RegGet $pk 'hideupdatenotifications') -eq 1 -and (& $m.RegGet $pk 'hideenabledisableupdates') -eq 1 -and @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -like 'office.policy.*' }).Count -eq 2 -and (Read-AVDTuneJson (Join-Path $tmp 'config\office-policies-undo.json')).Previous.hideupdatenotifications.Value -eq 0 -and (Read-AVDTuneJson (Join-Path $tmp 'config\office-policies-undo.json')).Previous.hideupdatenotifications.Type -ceq 'DWord') ("{0} {1} {2}" -f (& $m.RegGet $pk 'hideupdatenotifications'), @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -like 'office.policy.*' }).Count, (Get-Content (Join-Path $tmp 'config\office-policies-undo.json') -Raw))
    [void](Set-AVDTuneOfficePolicies -Machine $m -Root $tmp -User 'admin1' -SnapshotId 'snap-check')
    Test-Check 'policies: a second apply is Unchanged and does not overwrite the undo record' ((Read-AVDTuneJson (Join-Path $tmp 'config\office-policies-undo.json')).Previous.hideupdatenotifications.Value -eq 0) $null
    $up = Undo-AVDTuneOfficePolicies -Machine $m -Root $tmp -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'policies: undo puts back 0 and removes the value that was absent, writes LastChange and the change log' ((& $m.RegGet $pk 'hideupdatenotifications') -eq 0 -and $null -eq (& $m.RegGet $pk 'hideenabledisableupdates') -and -not (Test-Path (Join-Path $tmp 'config\office-policies-undo.json')) -and @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Text -like 'Undo: Office policy*' }).Count -eq 2) (($up.Results | ForEach-Object Status) -join ',')
    Test-Check 'policies: undo with no record is refused' ((Get-ThrownText { Undo-AVDTuneOfficePolicies -Machine $m -Root $tmp }) -like '*nothing to undo*') $null

    # the registry type of the earlier value is kept and put back
    $m = New-Master; Reset-OfficeFiles
    & $m.RegSet $pk 'hideupdatenotifications' '0' 'String'
    [void](Set-AVDTuneOfficePolicies -Machine $m -Root $tmp -User 'admin1' -SnapshotId 'snap-check')
    $pr = (Read-AVDTuneJson (Join-Path $tmp 'config\office-policies-undo.json')).Previous.hideupdatenotifications
    Test-Check 'policies: the registry type of the earlier value is stored (a String stays a String)' ($pr.Type -ceq 'String' -and $pr.Value -ceq '0') ($pr | ConvertTo-Json -Compress)
    $m.Log.Clear()
    [void](Undo-AVDTuneOfficePolicies -Machine $m -Root $tmp -User 'admin1' -SnapshotId 'snap-check')
    Test-Check 'policies: undo puts the earlier value back with its type' (@($m.Log | Where-Object { $_ -like 'RegSet*|hideupdatenotifications=0 (String)' }).Count -eq 1 -and (& $m.RegGet $pk 'hideupdatenotifications') -ceq '0') ($m.Log -join ' | ')

    # a record that is not exactly what Set wrote changes nothing
    $polUndo = Join-Path $tmp 'config\office-policies-undo.json'
    $badRecords = [ordered]@{
        'old format without type' = '{"Previous":{"hideupdatenotifications":1}}'
        'text for a DWord' = '{"Previous":{"hideupdatenotifications":{"Value":"1","Type":"DWord"}}}'
        'unknown type' = '{"Previous":{"hideupdatenotifications":{"Value":1,"Type":"Binary"}}}'
        'type in another case' = '{"Previous":{"hideupdatenotifications":{"Value":1,"Type":"dword"}}}'
        'unknown value name' = '{"Previous":{"evil":{"Value":1,"Type":"DWord"}}}'
        'Previous is text' = '{"Previous":"x"}'
    }
    foreach ($k in $badRecords.Keys) {
        $m = New-Master; Write-AVDTuneFile $polUndo $badRecords[$k]; $m.Log.Clear()
        Test-Check "policies undo record is typed: $k is refused, nothing written" ((Get-ThrownText { Undo-AVDTuneOfficePolicies -Machine $m -Root $tmp }) -like '*not usable*' -and @($m.Log | Where-Object { $_ -like 'Reg*' }).Count -eq 0) $null
    }

    # LastChange is set before the attempt and also when a step fails; the record stays
    $mark = '2000-01-01T00:00:00.0000000Z'
    $m = New-Master; & $m.RegSet $pk 'hideupdatenotifications' 1 'DWord'
    Write-AVDTuneFile $polUndo '{"At":"2026-11-15T10:00:00.0000000Z","Previous":{"hideupdatenotifications":{"Value":0,"Type":"DWord"}}}'
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastChange = $mark }); $m.Store.FailWrites = @('hideupdatenotifications')
    $upf = Undo-AVDTuneOfficePolicies -Machine $m -Root $tmp -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'policies undo: a failing step still sets LastChange and keeps the record' (@($upf.Results | Where-Object Status -eq 'Failed').Count -ge 1 -and (Get-AVDTuneState $tmp).LastChange -ne $mark -and (Test-Path $polUndo)) (($upf.Results | ForEach-Object Status) -join ',')
    $m.Store.FailWrites = @()
    Close-AVDTuneWriteGate
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastChange = $mark })
    Test-Check 'policies undo: without the open gate it is refused and does not touch LastChange' ((Test-Throws { Undo-AVDTuneOfficePolicies -Machine $m -Root $tmp }) -and (Get-AVDTuneState $tmp).LastChange -eq $mark) $null
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
    Remove-Item -LiteralPath $polUndo -Force -ErrorAction SilentlyContinue

    # ---------------------------------------------------------------- undo record after a run without effect, drift
    foreach ($case in @(@{ N = 'NoPage'; S = @{ Page = @{ Ok = $false; Text = ''; Error = 'fake' } } }, @{ N = 'NoLink'; S = @{ Page = @{ Ok = $true; Text = '<html></html>'; Error = '' } } }, @{ N = 'Download'; S = @{ DownloadFails = $true } }, @{ N = 'BadSignature'; S = @{ Signatures = @{ 'odt-package.exe' = @{ Valid = $false; Subject = ''; Issuer = '' } } } }, @{ N = 'NotProtected'; S = @{ Protected = $false } })) {
        $m = New-Master -NoOffice; $o = New-AVDTuneFakeOffice -Machine $m -Seed $case.S; Reset-OfficeFiles
        $rx = Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Install -Config $d -User 'admin1' -SnapshotId 'snap-check'
        Test-Check "undo record: a first run that fails without effect ($($case.N)) leaves no record behind" ($rx.Setup.Code -eq $case.N -and -not (Test-Path $undoFile)) $rx.Setup.Code
    }
    $m = New-Master; $o = New-AVDTuneFakeOffice -Machine $m -Seed @{ DownloadFails = $true }; Reset-OfficeFiles
    Write-AVDTuneFile $undoFile '{"At":"2026-11-15T10:00:00.0000000Z","BeforeInstalled":true,"BeforeBuild":"1","PreviousConfig":null}'
    [void](Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Install -Config $d -User 'admin1' -SnapshotId 'snap-check')
    Test-Check 'undo record: a failing run does not delete an older record' ((Test-Path $undoFile) -and (Read-AVDTuneJson $undoFile).BeforeBuild -eq '1') $null
    $m = New-Master -NoOffice; $o = New-AVDTuneFakeOffice -Machine $m -Seed @{ SetupExit = 1603 }; Reset-OfficeFiles
    [void](Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Install -Config $d -User 'admin1' -SnapshotId 'snap-check')
    Test-Check 'undo record: a failure after setup.exe ran (exit code) keeps the record (the master may have changed)' (Test-Path $undoFile) $null

    $m = New-Master -NoOffice; $o = New-AVDTuneFakeOffice -Machine $m; Reset-OfficeFiles
    [void](Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Install -Config $d -User 'admin1' -SnapshotId 'snap-check')
    Test-Check 'drift: Office as AVDTune left it is no drift' ($null -eq (Get-AVDTuneOfficeUndoDrift -Machine $m -Root $tmp)) $null
    & $m.RegSet $ctr 'CDNBaseUrl' 'http://officecdn.microsoft.com/pr/7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' 'String'   # somebody switched it to Semi-Annual
    $o.Log.Clear()
    $msg = Get-ThrownText { Invoke-AVDTuneOfficeUndo -Machine $m -O $o -Root $tmp -User 'admin1' -SnapshotId 'snap-check' }
    Test-Check 'drift: Undo asks first when Office is installed differently now, nothing is run' ($msg -like 'OFFICE-DRIFT*' -and $o.Log.Count -eq 0 -and (Get-AVDTuneOfficeInfo $m).Installed -and (Test-Path $undoFile)) $msg
    $ru = Invoke-AVDTuneOfficeUndo -Machine $m -O $o -Root $tmp -User 'admin1' -SnapshotId 'snap-check' -AcceptDrift
    Test-Check 'drift: confirmed, Undo goes on and removes' ($ru.Setup.Status -eq 'Changed' -and -not (Get-AVDTuneOfficeInfo $m).Installed) $ru.Setup.Message
    $m = New-Master -NoOffice; $o = New-AVDTuneFakeOffice -Machine $m; Reset-OfficeFiles
    [void](Invoke-AVDTuneOfficeRecorded -Machine $m -O $o -Root $tmp -Mode Install -Config $d -User 'admin1' -SnapshotId 'snap-check')
    Remove-Item (Join-Path $tmp 'config\office-applied.json') -Force
    Test-Check 'drift: an installation that AVDTune has no record of applying counts as different' ((Get-ThrownText { Invoke-AVDTuneOfficeUndo -Machine $m -O $o -Root $tmp }) -like 'OFFICE-DRIFT*') $null
    Reset-OfficeFiles

    # ---------------------------------------------------------------- policies: registry kinds
    $pk = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'; $polUndo = Join-Path $tmp 'config\office-policies-undo.json'
    $m = New-Master; & $m.RegSet $pk 'hideupdatenotifications' ([uint32]4294967295) 'DWord'
    [void](Set-AVDTuneOfficePolicies -Machine $m -Root $tmp -User 'admin1' -SnapshotId 'snap-check')
    $pr = (Read-AVDTuneJson $polUndo).Previous.hideupdatenotifications
    Test-Check 'policies: a UInt32 earlier value is a DWord stored as the Int32 with the same bits' ($pr.Type -ceq 'DWord' -and $pr.Value -eq -1) ($pr | ConvertTo-Json -Compress)
    [void](Undo-AVDTuneOfficePolicies -Machine $m -Root $tmp -User 'admin1' -SnapshotId 'snap-check')
    Test-Check 'policies: undo of it writes the DWord back' ((& $m.RegGet $pk 'hideupdatenotifications') -eq -1) $null
    Reset-OfficeFiles
    $m = New-Master; & $m.RegSet $pk 'hideupdatenotifications' '%SystemRoot%\avdtune-check' 'ExpandString'
    [void](Set-AVDTuneOfficePolicies -Machine $m -Root $tmp -User 'admin1' -SnapshotId 'snap-check')
    $pr = (Read-AVDTuneJson $polUndo).Previous.hideupdatenotifications
    Test-Check 'policies: REG_EXPAND_SZ keeps its kind and its raw text (not expanded)' ($pr.Type -ceq 'ExpandString' -and $pr.Value -ceq '%SystemRoot%\avdtune-check') ($pr | ConvertTo-Json -Compress)
    $m.Log.Clear(); [void](Undo-AVDTuneOfficePolicies -Machine $m -Root $tmp -User 'admin1' -SnapshotId 'snap-check')
    Test-Check 'policies: undo puts the ExpandString back with raw text and kind' (@($m.Log | Where-Object { $_ -like 'RegSet*hideupdatenotifications=%SystemRoot%\avdtune-check (ExpandString)' }).Count -eq 1) ($m.Log -join ' | ')
    Reset-OfficeFiles
    $m = New-Master; & $m.RegSet $pk 'hideupdatenotifications' 5 'DWord'; $m.Store.Kinds[($pk + '|hideupdatenotifications').ToLowerInvariant()] = 'Binary'
    Test-Check 'policies: a kind that cannot be put back (Binary) refuses before anything is written' ((Get-ThrownText { Set-AVDTuneOfficePolicies -Machine $m -Root $tmp -User 'admin1' -SnapshotId 'snap-check' }) -like '*cannot put back*' -and -not (Test-Path $polUndo)) $null

    # the real machine adapter reads kind and raw text (a throw-away key in HKCU, removed at the end)
    $rk = 'HKCU:\Software\AVDTuneCheck-' + [guid]::NewGuid().ToString('N')
    try {
        $rm = New-AVDTuneMachine
        New-Item -Path $rk -Force | Out-Null
        New-ItemProperty -LiteralPath $rk -Name 'E' -Value '%SystemRoot%\x' -PropertyType ExpandString | Out-Null
        New-ItemProperty -LiteralPath $rk -Name 'D' -Value 7 -PropertyType DWord | Out-Null
        $e = & $rm.RegGetRaw $rk 'E'; $dd = & $rm.RegGetRaw $rk 'D'
        Test-Check 'real adapter: RegGetRaw gives the kind and the unexpanded text, a DWord as Int32, an absent value or key as null' ($e.Kind -ceq 'ExpandString' -and $e.Value -ceq '%SystemRoot%\x' -and $dd.Kind -ceq 'DWord' -and $dd.Value -eq 7 -and $null -eq (& $rm.RegGetRaw $rk 'nope') -and $null -eq (& $rm.RegGetRaw ($rk + 'x') 'E')) ("$($e.Kind) $($e.Value)")
    }
    finally { Remove-Item -LiteralPath $rk -Recurse -Force -ErrorAction SilentlyContinue }

    # the real HoldFile: while it is held nobody can write, delete or rename the file; afterwards everything works again
    $hd = Join-Path $tmp 'hold-check'; [void][IO.Directory]::CreateDirectory($hd); $hf = Join-Path $hd 'setup.exe'; [IO.File]::WriteAllText($hf, 'x')
    $h = & (New-AVDTuneOfficeAdapter).HoldFile $hf
    $canWrite = try { [IO.File]::AppendAllText($hf, 'y'); $true } catch { $false }
    $canDelete = try { [IO.File]::Delete($hf); -not (Test-Path $hf) } catch { $false }
    $canRename = try { [IO.File]::Move($hf, "$hf.old"); $true } catch { $false }
    $canRead = try { [void][IO.File]::ReadAllText($hf); $true } catch { $false }
    $h.Dispose()
    $canWriteAfter = try { [IO.File]::AppendAllText($hf, 'y'); $true } catch { $false }
    Test-Check 'real adapter: a held setup.exe cannot be written, deleted or renamed, can be read, and is free after the release' (-not $canWrite -and -not $canDelete -and -not $canRename -and $canRead -and $canWriteAfter) "$canWrite $canDelete $canRename $canRead $canWriteAfter"

    # ---------------------------------------------------------------- source of the real adapter (not run here)
    $src = Get-Content -LiteralPath (Join-Path $repo 'Modules\AVDTune.Office.psm1') -Raw
    Test-Check 'real adapter: no redirects, https only, fixed hosts, no PATH lookup, no shell start, no Invoke-WebRequest' (([regex]::Matches($src, 'AllowAutoRedirect = \$false')).Count -ge 2 -and $src -match 'download\.microsoft\.com' -and $src -match 'www\.microsoft\.com' -and $src -notmatch 'Get-Command|Invoke-WebRequest|Invoke-Expression|Start-Process|cmd\.exe|UseShellExecute = \$true') $null
    Test-Check 'real adapter: Run goes through Invoke-AVDTuneChildProcess with the clean allowlist environment' ($src -match 'Invoke-AVDTuneChildProcess -FileName \$File[^
]*-CleanEnvironment -Tool office -TempDir') $null
    Test-Check 'real adapter: constructs and has every member the flow uses' ((@('OdtPage', 'NewTempFolder', 'IsProtectedFolder', 'Download', 'VerifySignature', 'Run', 'FindSetup', 'HoldFile', 'ListFolder', 'WriteText', 'RemoveFolder') | Where-Object { $null -eq (New-AVDTuneOfficeAdapter).$_ }).Count -eq 0) $null
    Test-Check 'the fake has every member of the real adapter (the fake stays in step)' ((@((New-AVDTuneOfficeAdapter).PSObject.Properties.Name | Where-Object { $_ -ne 'Kind' }) | Where-Object { $null -eq (New-AVDTuneFakeOffice -Machine (New-Master)).$_ }).Count -eq 0) $null
}
finally {
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
