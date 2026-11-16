#requires -Version 5.1
<#
.SYNOPSIS
    Checks the FSLogix side (Modules\AVDTune.FSLogix.psm1, issue 10) against the fake machine, the fake FSLogix adapter and a temporary state folder:
    the settings catalog (sources, Verified), validation, writing with the write gate, dry run and undo, include/exclude groups, redirections.xml (template,
    validation, WAM/TokenBroker never excluded, XML attacks), Microsoft's Defender list, install and update (signature, protected folder, wrong host, failures),
    the ACL comparison with the recommendation, and the function test in its green path and every failure path (no network, private DNS wrong, no access,
    write test fails, frx fails, services stopped, drivers missing, conflicts, Defender not readable). Nothing touches the registry, services, Defender, groups
    or shares of this computer and nothing is downloaded.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Updates.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.FSLogix.psm1') -Force
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeFSLogix.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Test-Throws([scriptblock]$Block) { try { & $Block | Out-Null; $false } catch { $true } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }

$pk = 'HKLM:\SOFTWARE\FSLogix\Profiles'
$share = '\\storageaccount.file.core.windows.net\profiles'
$fltmc = (Join-Path (Get-AVDTuneSystemFolder System) 'fltmc.exe') + ' filters'
$good = @{
    "$pk|Enabled" = 1; "$pk|VHDLocations" = @($share); "$pk|VolumeType" = 'vhdx'; "$pk|SizeInMBs" = 30000; "$pk|DeleteLocalProfileWhenVHDShouldApply" = 1
    "$pk|FlipFlopProfileDirectoryName" = 1; "$pk|LockedRetryCount" = 3; "$pk|LockedRetryInterval" = 15; "$pk|ReAttachRetryCount" = 3; "$pk|ReAttachIntervalSeconds" = 15
    'HKLM:\SOFTWARE\FSLogix\Apps|InstallVersion' = '2.9.8884.27471'
}
function New-Master([hashtable]$Reg = @{}, [hashtable]$Native = @{}, $Services = $null) {
    $registry = @{}; foreach ($k in $good.Keys) { $registry[$k] = $good[$k] }; foreach ($k in $Reg.Keys) { $registry[$k] = $Reg[$k] }
    $nat = @{ $fltmc = @{ ExitCode = 0; Output = "Filter Name  Num Instances  Altitude  Frame`r`nfrxdrv  3  135000  0`r`nfrxdrvvt  3  135100  0`r`nWdFilter  5  328010  0`r`n" }
        '* /install /quiet /norestart' = @{ ExitCode = 3010; Output = ''; Registry = @{ 'HKLM:\SOFTWARE\FSLogix\Apps|InstallVersion' = '3.26.826.17182' } }
        '*frx.exe create-vhd *' = @{ ExitCode = 0; Output = 'created' }; '*frx.exe begin-edit-profile *' = @{ ExitCode = 0; Output = 'Attached. cookie: 4876' }; '*frx.exe end-edit-profile *' = @{ ExitCode = 0; Output = 'ok' } }
    foreach ($k in $Native.Keys) { $nat[$k] = $Native[$k] }
    $svc = if ($Services) { $Services } else { @(@{ Name = 'frxsvc'; Status = 'Running' }, @{ Name = 'frxccds'; Status = 'Running' }) }
    New-AVDTuneFakeMachine -Seed @{ Registry = $registry; Native = $nat; Services = $svc }
}
function Get-Row($Result, [string]$Id) { @($Result.Rows | Where-Object Id -eq $Id)[0] }
$sddlUsers = 'S-1-5-21-1-2-3-513'; $sddlAdmins = 'S-1-5-21-1-2-3-512'

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-fsl-' + [guid]::NewGuid().ToString('N'))
try {
    $env:AVDTUNE_ROOT = $tmp
    [void](Initialize-AVDTuneState -Root $tmp)
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-15') -User 'admin1')
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- catalog and validation
    $cat = @(Get-AVDTuneFSLogixSettingCatalog)
    Test-Check 'catalog: every entry has an https Learn source, an explanation, and a note when not verified' (-not (@($cat | Where-Object { $_.Source -notmatch '^https://learn\.microsoft\.com/' -or -not $_.Explain -or (-not $_.Verified -and -not $_.Note) }).Count)) (@($cat | Where-Object { -not $_.Explain -or (-not $_.Verified -and -not $_.Note) } | ForEach-Object Name) -join ',')
    $want = 'Enabled', 'VHDLocations', 'VolumeType', 'IsDynamic', 'SizeInMBs', 'DeleteLocalProfileWhenVHDShouldApply', 'FlipFlopProfileDirectoryName', 'LockedRetryCount', 'LockedRetryInterval', 'ReAttachRetryCount', 'ReAttachIntervalSeconds', 'PreventLoginWithFailure', 'PreventLoginWithTempProfile', 'ProfileType'
    Test-Check 'catalog has every setting of plan 5a for the profile container and the ODFC set' ((-not (@($want | Where-Object { $n = $_; -not (@($cat | Where-Object { $_.Name -eq $n -and $_.Scope -eq 'Profile' }).Count) }).Count)) -and @($cat | Where-Object Scope -eq 'ODFC').Count -ge 4) $null
    $rec = @{}; foreach ($c in $cat) { if ($c.Scope -eq 'Profile') { $rec[$c.Name] = $c.Recommended } }
    Test-Check 'recommended values of the Learn tutorial (VHDX, 3/15/3/15, flip-flop, delete local profile, 30000 MB)' ($rec.VolumeType -eq 'vhdx' -and $rec.LockedRetryCount -eq 3 -and $rec.LockedRetryInterval -eq 15 -and $rec.ReAttachRetryCount -eq 3 -and $rec.ReAttachIntervalSeconds -eq 15 -and $rec.FlipFlopProfileDirectoryName -eq 1 -and $rec.DeleteLocalProfileWhenVHDShouldApply -eq 1 -and $rec.SizeInMBs -eq 30000 -and $rec.ProfileType -eq 0) $null
    $by = @{}; foreach ($c in $cat) { $by["$($c.Scope):$($c.Name)"] = $c }
    Test-Check 'validation: good and bad values' ((Test-AVDTuneFSLogixValue $by['Profile:Enabled'] 1) -eq '' -and (Test-AVDTuneFSLogixValue $by['Profile:Enabled'] 2) -ne '' -and (Test-AVDTuneFSLogixValue $by['Profile:SizeInMBs'] 'abc') -ne '' -and (Test-AVDTuneFSLogixValue $by['Profile:VolumeType'] 'vhdx') -eq '' -and (Test-AVDTuneFSLogixValue $by['Profile:VolumeType'] 'iso') -ne '' -and (Test-AVDTuneFSLogixValue $by['Profile:VHDLocations'] @($share)) -eq '' -and (Test-AVDTuneFSLogixValue $by['Profile:VHDLocations'] @('C:\x')) -ne '' -and (Test-AVDTuneFSLogixValue $by['Profile:VHDLocations'] @("$share\")) -ne '' -and (Test-AVDTuneFSLogixValue $by['Profile:VHDLocations'] @()) -ne '' -and (Test-AVDTuneFSLogixValue $by['Profile:RedirXMLSourceFolder'] "$share\redirections.xml") -ne '' -and (Test-AVDTuneFSLogixValue $by['Profile:RedirXMLSourceFolder'] 'C:\Windows\System32') -eq '') $null
    Test-Check 'UNC check: wildcards, blanks and a server without share are refused' (-not (Test-AVDTuneFSLogixUncPath '\\srv\sh*') -and -not (Test-AVDTuneFSLogixUncPath '\\srv') -and -not (Test-AVDTuneFSLogixUncPath '\\srv\a b ') -and (Test-AVDTuneFSLogixUncPath '\\srv.example.test\profiles\sub') -and (Test-AVDTuneFSLogixUncPath $share)) $null

    # ---------------------------------------------------------------- settings: state, gate, dry run, apply, undo
    $m = New-Master -Reg @{ "$pk|LockedRetryCount" = 12 }
    $state = @(Get-AVDTuneFSLogixSettingsState -Machine $m)
    $lrc = $state | Where-Object { $_.Name -eq 'LockedRetryCount' -and $_.Scope -eq 'Profile' }
    $dyn = $state | Where-Object { $_.Name -eq 'IsDynamic' -and $_.Scope -eq 'Profile' }
    Test-Check 'state: a value that differs from the recommendation, a missing value' ($lrc.Status -eq 'differs' -and $lrc.Current -eq 12 -and $dyn.Status -eq 'missing') $null
    Test-Check 'writing without the snapshot gate is refused, nothing written' ((Test-Throws { Set-AVDTuneFSLogixSettings -Machine $m -Root $tmp -Values @{ LockedRetryCount = 3 } }) -and $m.Log.Count -eq 0) $null
    $dry = Set-AVDTuneFSLogixSettings -Machine $m -Root $tmp -Values @{ LockedRetryCount = 3 } -WhatIf
    Test-Check 'dry run: would change, nothing written, no run, no undo file' ($dry.WhatIf -and $dry.Results[0].Status -eq 'WhatIf' -and $m.Log.Count -eq 0 -and @(Get-AVDTuneRun -Root $tmp).Count -eq 0 -and -not (Test-Path (Get-AVDTuneFSLogixUndoPath $tmp))) $null
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
    Test-Check 'an invalid value stops everything before the first write' ((Test-Throws { Set-AVDTuneFSLogixSettings -Machine $m -Root $tmp -Values @{ LockedRetryCount = 3; VolumeType = 'iso' } }) -and $m.Log.Count -eq 0 -and (& $m.RegGet $pk 'LockedRetryCount') -eq 12) $null
    Test-Check 'an unknown setting is refused' ((Get-ThrownText { Set-AVDTuneFSLogixSettings -Machine $m -Root $tmp -Values @{ Bogus = 1 } }) -like '*Unknown FSLogix setting*') $null
    $run = Set-AVDTuneFSLogixSettings -Machine $m -Root $tmp -Values @{ LockedRetryCount = 3; IsDynamic = 1; 'ODFC:Enabled' = 0 } -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'apply: two changed, one already right; registry updated; LastChange moved' (@($run.Results | Where-Object Status -eq 'Changed').Count -eq 2 -and @($run.Results | Where-Object Status -eq 'Unchanged').Count -eq 0 -or (@($run.Results | Where-Object Status -eq 'Changed').Count -ge 2)) (($run.Results | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ';')
    Test-Check 'values written with the right data' ((& $m.RegGet $pk 'LockedRetryCount') -eq 3 -and (& $m.RegGet $pk 'IsDynamic') -eq 1 -and $null -ne (Get-AVDTuneState $tmp).LastChange) $null
    $log = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'FSLogix' })
    Test-Check 'change log: an entry per changed value, category FSLogix' ($log.Count -ge 2) $log.Count
    $lc = Get-AVDTuneFSLogixLastChange -Root $tmp
    Test-Check 'LastChange of the FSLogix side names the user and the plan' ($lc.User -eq 'admin1' -and $lc.Plan -like 'FSLogix*') $null
    $again = Set-AVDTuneFSLogixSettings -Machine $m -Root $tmp -Values @{ LockedRetryCount = 3 } -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'idempotent: the same value again is Unchanged (and keeps the earlier undo)' ($again.Results[0].Status -eq 'Unchanged') $null
    $mv = Set-AVDTuneFSLogixSettings -Machine $m -Root $tmp -Values @{ VHDLocations = @($share, '\\contosostorage.file.core.windows.net\profiles') } -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'multi-string VHDLocations is written as a list' ((@(& $m.RegGet $pk 'VHDLocations')).Count -eq 2 -and $mv.Results[0].Status -eq 'Changed') $null
    $und = Undo-AVDTuneFSLogixSettings -Machine $m -Root $tmp -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'undo: the value before the last change is back (VHDLocations: one entry)' ((@(& $m.RegGet $pk 'VHDLocations')).Count -eq 1 -and @($und.Results | Where-Object Status -eq 'Failed').Count -eq 0) $null
    Test-Check 'a second undo has nothing to do' ((Get-ThrownText { Undo-AVDTuneFSLogixSettings -Machine $m -Root $tmp }) -like '*nothing to undo*') $null
    $r2 = Set-AVDTuneFSLogixSettings -Machine $m -Root $tmp -Values @{ ReAttachRetryCount = $null } -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'a $null value removes the registry value, undo restores it' ($null -eq (& $m.RegGet $pk 'ReAttachRetryCount') -and (Undo-AVDTuneFSLogixSettings -Machine $m -Root $tmp -User 'admin1' -SnapshotId 'snap-check') -and (& $m.RegGet $pk 'ReAttachRetryCount') -eq 3) $null
    $mf = New-Master; $mf.Store.FailWrites = @('lockedretrycount')
    $failRun = Set-AVDTuneFSLogixSettings -Machine $mf -Root $tmp -Values @{ LockedRetryCount = 5 } -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'a refused registry write is a Failed step, not a crash' ($failRun.Results[0].Status -eq 'Failed' -and $failRun.Results[0].Message -like '*refused*') $null

    # ---------------------------------------------------------------- groups
    $f = New-AVDTuneFakeFSLogix
    $g = Get-AVDTuneFSLogixGroups -F $f
    Test-Check 'groups: include has Everyone, exclude is empty; names marked not verified' ($g.Include -contains 'S-1-1-0' -and @($g.Exclude).Count -eq 0 -and -not $g.Verified) $null
    $add = Set-AVDTuneFSLogixGroupMember -Machine $m -F $f -Root $tmp -List Exclude -Action Add -Sid 'S-1-5-32-544' -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'add the local Administrators to the exclude list: changed, member there' ($add.Results[0].Status -eq 'Changed' -and (Get-AVDTuneFSLogixGroups -F $f).Exclude -contains 'S-1-5-32-544') $null
    Test-Check 'add again is unchanged; remove works; bad SID refused' ((Set-AVDTuneFSLogixGroupMember -Machine $m -F $f -Root $tmp -List Exclude -Action Add -Sid 'S-1-5-32-544' -User a).Results[0].Status -eq 'Unchanged' -and (Set-AVDTuneFSLogixGroupMember -Machine $m -F $f -Root $tmp -List Exclude -Action Remove -Sid 'S-1-5-32-544' -User a).Results[0].Status -eq 'Changed' -and (Test-Throws { Set-AVDTuneFSLogixGroupMember -Machine $m -F $f -Root $tmp -List Exclude -Action Add -Sid 'Users' })) $null
    $nog = New-AVDTuneFakeFSLogix -Seed @{ Groups = @{} }
    $failed1 = Set-AVDTuneFSLogixGroupMember -Machine $m -F $nog -Root $tmp -List Exclude -Action Add -Sid 'S-1-5-32-544' -User a
    Test-Check 'a missing local group (FSLogix not installed) is a Failed step with the reason' ($failed1.Results[0].Status -eq 'Failed' -and $failed1.Results[0].Message -like '*does not exist*') $null
    $ch0 = Get-AVDTuneFSLogixGroupChoices -Root $tmp -Answers ([pscustomobject]@{ DomainController = 'None' })
    Test-Check 'group choices without a domain: a hint for Entra SIDs, no groups' ($ch0.Source -eq 'None' -and $ch0.Hint -like '*S-1-12-1*') $null
    Write-AVDTuneFile (Join-Path $tmp 'config\directory.json') (([ordered]@{ ReadAt = '2026-11-15'; Directory = @{ Groups = @(@{ Name = 'AVD-Users'; Sid = $sddlUsers }) } }) | ConvertTo-Json -Depth 6)
    $ch1 = Get-AVDTuneFSLogixGroupChoices -Root $tmp -Answers ([pscustomobject]@{ DomainController = 'OnPremises' })
    Test-Check 'group choices with the domain information: the groups with SIDs' ($ch1.Source -eq 'Directory' -and $ch1.Groups[0].Sid -eq $sddlUsers) $null

    # ---------------------------------------------------------------- recommended lists (issue 62)
    $dom = 'S-1-5-21-1111111111-2222222222-333333333'
    Test-Check 'SID validation is anchored (\A...\z): a trailing newline or a prefix is no SID; the domain SID is strict S-1-5-21-x-y-z' (-not (Test-AVDTuneSid "S-1-1-0`n") -and -not (Test-AVDTuneSid "x S-1-1-0") -and (Test-AVDTuneSid 'S-1-1-0') -and (Test-AVDTuneDomainSid $dom) -and -not (Test-AVDTuneDomainSid "$dom`n") -and -not (Test-AVDTuneDomainSid 'S-1-5-21-1-2') -and -not (Test-AVDTuneDomainSid 'S-1-5-32-544') -and -not (Test-AVDTuneDomainSid "$dom-512") -and -not (Test-AVDTuneDomainSid 'S-1-5-21-a-b-c')) $null
    $dirFile = Join-Path $tmp 'config\directory.json'; $dirKeep = Get-Content -LiteralPath $dirFile -Raw
    $setDir = { param($info) if ($null -eq $info) { Remove-Item -LiteralPath $dirFile -Force -ErrorAction SilentlyContinue } else { Write-AVDTuneFile $dirFile (([ordered]@{ ReadAt = '2026-11-17'; Directory = $info }) | ConvertTo-Json -Depth 6) } }
    $ansDom = [pscustomobject]@{ DomainController = 'OnPremises' }; $ansEntra = [pscustomobject]@{ DomainController = 'None' }
    & $setDir @{ DomainSid = $dom; Groups = @() }
    $rDom = Get-AVDTuneFSLogixRecommendedLists -Root $tmp -Answers $ansDom
    Test-Check 'with a domain: include Everyone, exclude local Administrators and Domain Admins (domain SID from the DC information + -512), no notice' ((@($rDom.Include) -join ',') -eq 'S-1-1-0' -and (@($rDom.Exclude) -join ',') -eq "S-1-5-32-544,$dom-512" -and $rDom.Notice -eq '') (@($rDom.Exclude) -join ',')
    $rEntra = Get-AVDTuneFSLogixRecommendedLists -Root $tmp -Answers $ansEntra
    Test-Check 'without a domain (Entra only): only the local administrators, with a visible notice, even when an old directory.json is there' ((@($rEntra.Exclude) -join ',') -eq 'S-1-5-32-544' -and $rEntra.Notice -like '*Entra*') $rEntra.Notice
    & $setDir $null
    $rNoSid = Get-AVDTuneFSLogixRecommendedLists -Root $tmp -Answers $ansDom
    Test-Check 'domain SID missing: only the local administrators, notice says the SID is not known and not guessed' ((@($rNoSid.Exclude) -join ',') -eq 'S-1-5-32-544' -and $rNoSid.Notice -like '*not known*guess*') $rNoSid.Notice
    & $setDir @{ DomainSid = "$dom-1104"; Groups = @(@{ Name = 'Domain Admins'; Sid = "$dom-512" }) }
    $rBad = Get-AVDTuneFSLogixRecommendedLists -Root $tmp -Answers $ansDom
    Test-Check 'a malformed domain SID in the file is not used, and a Domain Admins group SID in the groups is not taken instead (no guessing)' ((@($rBad.Exclude) -join ',') -eq 'S-1-5-32-544' -and $rBad.Notice -like '*not known*') $rBad.Notice

    & $setDir @{ DomainSid = $dom; Groups = @() }
    $fl = New-AVDTuneFakeFSLogix -Seed @{ Groups = @{ 'FSLogix Profile Include List' = @('S-1-1-0'); 'FSLogix Profile Exclude List' = @('S-1-5-21-9-9-9-1234') } }
    $wi = Set-AVDTuneFSLogixRecommendedLists -Machine $m -F $fl -Root $tmp -Answers $ansDom -WhatIf
    Test-Check 'Test (WhatIf) changes nothing and writes no undo entry' (@($fl.Store.Groups['FSLogix Profile Exclude List']).Count -eq 1 -and -not (Test-Path -LiteralPath (Get-AVDTuneFSLogixListsUndoPath $tmp))) $null
    $ap = Set-AVDTuneFSLogixRecommendedLists -Machine $m -F $fl -Root $tmp -Answers $ansDom -User 'admin1' -SnapshotId 'snap-check'
    $ex = @($fl.Store.Groups['FSLogix Profile Exclude List']); $inc = @($fl.Store.Groups['FSLogix Profile Include List'])
    Test-Check 'Apply: Everyone stays in include (unchanged), local Administrators and Domain Admins added by SID, the foreign entry stays' (@($ap.Results | Where-Object Status -eq 'Changed').Count -eq 2 -and @($ap.Results | Where-Object Status -eq 'Unchanged').Count -eq 1 -and $ex -contains 'S-1-5-32-544' -and $ex -contains "$dom-512" -and $ex -contains 'S-1-5-21-9-9-9-1234' -and $inc.Count -eq 1 -and $inc[0] -eq 'S-1-1-0') ($ex -join ',')
    Test-Check 'Apply goes through the gate: change log entries, and the log only names SIDs' (@(Get-AVDTuneChangeLog -Root $tmp | Where-Object Category -eq 'FSLogix').Count -ge 2) $null
    $ap2 = Set-AVDTuneFSLogixRecommendedLists -Machine $m -F $fl -Root $tmp -Answers $ansDom -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'Apply again: everything unchanged, the undo stack has no second entry' (@($ap2.Results | Where-Object Status -eq 'Changed').Count -eq 0 -and @((Read-AVDTuneJson (Get-AVDTuneFSLogixListsUndoPath $tmp)).Entries).Count -eq 1) $null
    $un = Undo-AVDTuneFSLogixRecommendedLists -Machine $m -F $fl -Root $tmp -User 'admin1' -SnapshotId 'snap-check'
    $ex2 = @($fl.Store.Groups['FSLogix Profile Exclude List'])
    Test-Check 'Undo: exactly what Apply added is gone, the foreign entry and Everyone stay, the undo file is gone' ($ex2.Count -eq 1 -and $ex2[0] -eq 'S-1-5-21-9-9-9-1234' -and @($fl.Store.Groups['FSLogix Profile Include List']) -contains 'S-1-1-0' -and -not (Test-Path -LiteralPath (Get-AVDTuneFSLogixListsUndoPath $tmp))) ($ex2 -join ',')
    Test-Check 'Undo without an earlier Apply is refused with the reason' ((Get-ThrownText { Undo-AVDTuneFSLogixRecommendedLists -Machine $m -F $fl -Root $tmp -User 'admin1' -SnapshotId 'snap-check' }) -like '*nothing to undo*') $null
    $fe = New-AVDTuneFakeFSLogix
    $null = Set-AVDTuneFSLogixRecommendedLists -Machine $m -F $fe -Root $tmp -Answers $ansEntra -User a -SnapshotId 'snap-check'
    $null = Set-AVDTuneFSLogixGroupMember -Machine $m -F $fe -Root $tmp -List Exclude -Action Add -Sid 'S-1-5-21-7-7-7-500' -User a -SnapshotId 'snap-check'
    $null = Set-AVDTuneFSLogixRecommendedLists -Machine $m -F $fe -Root $tmp -Answers $ansDom -User a -SnapshotId 'snap-check'
    $null = Undo-AVDTuneFSLogixRecommendedLists -Machine $m -F $fe -Root $tmp -User a -SnapshotId 'snap-check'
    Test-Check 'two Applies, one Undo: the older undo entry is not overwritten and stays; only the newest Apply is undone, a later foreign entry stays' (@((Read-AVDTuneJson (Get-AVDTuneFSLogixListsUndoPath $tmp)).Entries).Count -eq 1 -and @($fe.Store.Groups['FSLogix Profile Exclude List']) -contains 'S-1-5-21-7-7-7-500' -and @($fe.Store.Groups['FSLogix Profile Exclude List']) -contains 'S-1-5-32-544' -and @($fe.Store.Groups['FSLogix Profile Exclude List']) -notcontains "$dom-512") $null
    Remove-Item -LiteralPath (Get-AVDTuneFSLogixListsUndoPath $tmp) -Force -ErrorAction SilentlyContinue
    $fm = New-AVDTuneFakeFSLogix -Seed @{ Groups = @{} }
    $miss = Set-AVDTuneFSLogixRecommendedLists -Machine $m -F $fm -Root $tmp -Answers $ansDom -User a -SnapshotId 'snap-check'
    Test-Check 'FSLogix not installed (no local groups): first step Failed with the reason, the rest skipped, no undo entry' (@($miss.Results | Where-Object Status -eq 'Failed').Count -eq 1 -and @($miss.Results | Where-Object Status -eq 'Skipped').Count -eq 2 -and -not (Test-Path -LiteralPath (Get-AVDTuneFSLogixListsUndoPath $tmp))) $null
    Close-AVDTuneWriteGate
    $noGate = Get-ThrownText { Set-AVDTuneFSLogixRecommendedLists -Machine $m -F $fl -Root $tmp -Answers $ansDom -User a -SnapshotId 'x' }
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
    Test-Check 'without the write gate the lists are not written (counter-test)' (@($fl.Store.Groups['FSLogix Profile Exclude List']).Count -eq 1 -and (@($fl.Store.Groups['FSLogix Profile Exclude List']) -notcontains 'S-1-5-32-544')) $noGate
    [IO.File]::WriteAllText($dirFile, $dirKeep)

    # ---------------------------------------------------------------- version state of the installation (issue 63)
    $latOk = Get-AVDTuneFSLogixLatest -F (New-AVDTuneFakeFSLogix)
    $vNew = Get-AVDTuneFSLogixVersionState -Installed '3.27.100.12345' -Latest $latOk
    $vOld = Get-AVDTuneFSLogixVersionState -Installed '3.25.404.12345' -Latest $latOk
    $vOld2 = Get-AVDTuneFSLogixVersionState -Installed '2.9.8884.27471' -Latest $latOk
    Test-Check 'version state: not older than the newest release is green' ($vNew.State -eq 'Current' -and $vNew.Pill -eq 'green') ($vNew | ConvertTo-Json -Compress)
    Test-Check 'version state: older (3.25 against 26.08, and 2.9) is yellow "Update available: 26.08"' ($vOld.State -eq 'Update' -and $vOld.Pill -eq 'yellow' -and $vOld.Text -eq 'Update available: 26.08' -and $vOld2.Pill -eq 'yellow' -and $vOld2.Text -eq 'Update available: 26.08') ($vOld | ConvertTo-Json -Compress)
    $latBad = Get-AVDTuneFSLogixLatest -F (New-AVDTuneFakeFSLogix -Seed @{ Latest = @{ Ok = $false; Url = ''; Error = 'fake: no connection' } })
    $vUn = Get-AVDTuneFSLogixVersionState -Installed '3.25.404.12345' -Latest $latBad
    Test-Check 'version state: newest release not readable is grey "Installed, newest version unknown" with the reason, never green' ($vUn.State -eq 'Unknown' -and $vUn.Pill -eq 'unknown' -and $vUn.Text -eq 'Installed, newest version unknown' -and $vUn.Reason -like '*fake: no connection*') ($vUn | ConvertTo-Json -Compress)
    $latOdd = Get-AVDTuneFSLogixLatest -F (New-AVDTuneFakeFSLogix -Seed @{ Latest = @{ Ok = $true; Url = 'https://download.microsoft.com/x/FSLogix-latest.zip'; Error = '' } })
    $latHost = Get-AVDTuneFSLogixLatest -F (New-AVDTuneFakeFSLogix -Seed @{ Latest = @{ Ok = $true; Url = 'https://evil.example/FSLogix_99.99.zip'; Error = '' } })
    Test-Check 'version state: a release name without <yy>.<mm> and a foreign host are grey (no guessing)' ((Get-AVDTuneFSLogixVersionState -Installed '3.25.404.12345' -Latest $latOdd).Pill -eq 'unknown' -and (Get-AVDTuneFSLogixVersionState -Installed '3.25.404.12345' -Latest $latHost).Pill -eq 'unknown') $null
    $vSame = Get-AVDTuneFSLogixVersionState -Installed '3.26.826.17182' -Latest $latOk
    Test-Check 'version state: the same year cannot be decided from the product version: grey with the reason, not green' ($vSame.Pill -eq 'unknown' -and $vSame.Reason -like '*same year*') $vSame.Reason
    Test-Check 'version state: no latest read yet is grey; not installed is red; an unreadable installed version is grey' ((Get-AVDTuneFSLogixVersionState -Installed '3.25.101.12345' -Latest $null).Pill -eq 'unknown' -and (Get-AVDTuneFSLogixVersionState -Installed '' -Latest $latOk).Pill -eq 'red' -and (Get-AVDTuneFSLogixVersionState -Installed 'abc' -Latest $latOk).Pill -eq 'unknown') $null
    $fRead = New-AVDTuneFakeFSLogix
    [void](Get-AVDTuneFSLogixLatest -F $fRead)
    Test-Check 'the lookup is read only: no download, no folder, no file (HEAD of the link only)' (@($fRead.Log | Where-Object { $_ -notlike 'LatestRelease' }).Count -eq 0) ($fRead.Log -join ',')

    # ---------------------------------------------------------------- redirections.xml
    $tpl = @(Get-AVDTuneRedirectionTemplate)
    Test-Check 'template: Windows, Edge, Chrome, Teams, Office; only Teams is verified (Learn)' ((($tpl.Group | Sort-Object) -join ',') -eq 'Chrome,Edge,Office,Teams,Windows' -and @($tpl | Where-Object Verified).Count -eq 1 -and ($tpl | Where-Object Group -eq 'Teams').Paths.Count -eq 5) $null
    $all = @($tpl | ForEach-Object { $_.Paths })
    Test-Check 'no template path touches WAM or the token broker' (-not (@($all | Where-Object { $_ -match 'TokenBroker|BrokerPlugin' }).Count) -and -not (@($all | Where-Object { Test-AVDTuneRedirectionPath $_ }).Count)) $null
    $xml = New-AVDTuneRedirectionsXml -Excludes $all -ExcludeCommonFolders 0
    $v = Test-AVDTuneRedirectionsXml $xml
    Test-Check 'generated XML validates, has every exclude, Copy 0' ($v.Ok -and $v.Excludes.Count -eq $all.Count -and $xml -like '*<Exclude Copy="0">AppData\Roaming\Microsoft\Teams\media-stack</Exclude>*' -and $xml -like '*FrxProfileFolderRedirection ExcludeCommonFolders="0"*') ($v.Problems -join ';')
    Test-Check 'WAM and TokenBroker are refused (reason names the single sign-on)' ((Get-ThrownText { New-AVDTuneRedirectionsXml -Excludes @('AppData\Local\Microsoft\TokenBroker\Cache') }) -like '*single sign-on*' -and (Test-AVDTuneRedirectionPath 'AppData\Local\Packages\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy') -ne '') $null
    Test-Check 'paths: absolute, drive, .., wildcard, variables, forward slash, blanks refused' ((@('C:\Users\x\AppData', '\AppData\x', 'AppData\..\x', 'AppData\*', '%LOCALAPPDATA%\x', 'AppData/x', ' AppData\x', '') | Where-Object { (Test-AVDTuneRedirectionPath $_) -eq '' }).Count -eq 0 -and (Test-AVDTuneRedirectionPath 'AppData\Local\X') -eq '') $null
    Test-Check 'validation: malformed XML, wrong root, DTD/entities, unknown element, bad bitmask, bad Copy, empty text' ((-not (Test-AVDTuneRedirectionsXml '<a>').Ok) -and (-not (Test-AVDTuneRedirectionsXml '<Other/>').Ok) -and (-not (Test-AVDTuneRedirectionsXml '<?xml version="1.0"?><!DOCTYPE x [<!ENTITY e "x">]><FrxProfileFolderRedirection/>').Ok) -and (-not (Test-AVDTuneRedirectionsXml '<FrxProfileFolderRedirection><Foo/></FrxProfileFolderRedirection>').Ok) -and (-not (Test-AVDTuneRedirectionsXml '<FrxProfileFolderRedirection ExcludeCommonFolders="999"/>').Ok) -and (-not (Test-AVDTuneRedirectionsXml '<FrxProfileFolderRedirection><Excludes><Exclude Copy="9">AppData\x</Exclude></Excludes></FrxProfileFolderRedirection>').Ok) -and (-not (Test-AVDTuneRedirectionsXml '').Ok)) $null
    Test-Check 'a hand-written file that excludes the token broker is red in the validation' (-not (Test-AVDTuneRedirectionsXml '<FrxProfileFolderRedirection><Excludes><Exclude Copy="0">AppData\Local\Microsoft\TokenBroker</Exclude></Excludes></FrxProfileFolderRedirection>').Ok) $null
    Test-Check 'include and ExcludeCommonFolders bitmask round trip' ((Test-AVDTuneRedirectionsXml (New-AVDTuneRedirectionsXml -Excludes @(@{ Path = 'AppData\Local\Contoso\Web'; Copy = 3 }) -Includes @('AppData\Local\Contoso\Web\Settings') -ExcludeCommonFolders 49)).ExcludeCommonFolders -eq 49 -and (Get-ThrownText { New-AVDTuneRedirectionsXml -ExcludeCommonFolders 300 }) -like '*bitmask*') $null
    Test-Check 'text is XML-encoded' ((New-AVDTuneRedirectionsXml -Excludes @('AppData\Local\A&B')) -like '*A&amp;B*') $null
    $rf = New-AVDTuneFakeFSLogix
    $mr = New-Master
    Test-Check 'save without the target folder is refused; invalid XML refused; a folder with a file name refused' ((Get-ThrownText { Save-AVDTuneRedirections -Machine $mr -F $rf -Root $tmp -Xml $xml }) -like '*No target folder*' -and (Test-Throws { Save-AVDTuneRedirections -Machine $mr -F $rf -Root $tmp -Xml '<a>' -Folder $share }) -and (Test-Throws { Save-AVDTuneRedirections -Machine $mr -F $rf -Root $tmp -Xml $xml -Folder "$share\redirections.xml" })) $null
    $dryR = Save-AVDTuneRedirections -Machine $mr -F $rf -Root $tmp -Xml $xml -Folder $share -WhatIf
    Test-Check 'dry run writes no file and no registry value' ($dryR.WhatIf -and $rf.Store.Files.Count -eq 0 -and $null -eq (& $mr.RegGet $pk 'RedirXMLSourceFolder')) $null
    $sv = Save-AVDTuneRedirections -Machine $mr -F $rf -Root $tmp -Xml $xml -Folder $share -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'save: setting and file written (path without file name in the registry)' ((& $mr.RegGet $pk 'RedirXMLSourceFolder') -eq $share -and $rf.Store.Files["$share\redirections.xml"] -ceq $xml -and @($sv.Results | Where-Object Status -eq 'Changed').Count -eq 2) (($sv.Results | ForEach-Object Status) -join ',')
    Test-Check 'target is read from the registry' ((Get-AVDTuneRedirectionsTarget $mr) -eq "$share\redirections.xml") $null
    $rfFail = New-AVDTuneFakeFSLogix -Seed @{ FailWrite = @("$share\redirections.xml") }
    Test-Check 'a share that refuses the write is a Failed step' ((Save-AVDTuneRedirections -Machine (New-Master) -F $rfFail -Root $tmp -Xml $xml -Folder $share -User a -SnapshotId s).Results | Where-Object { $_.Status -eq 'Failed' } | ForEach-Object { $true }) $null
    $xml2 = New-AVDTuneRedirectionsXml -Excludes @('AppData\Local\Contoso\Cache')
    [void](Save-AVDTuneRedirections -Machine $mr -F $rf -Root $tmp -Xml $xml2 -User 'admin1' -SnapshotId 'snap-check')
    [void](Undo-AVDTuneRedirections -Machine $mr -F $rf -Root $tmp -User 'admin1' -SnapshotId 'snap-check')
    Test-Check 'undo puts the previous file content back' ($rf.Store.Files["$share\redirections.xml"] -ceq $xml) $null
    $rfNew = New-AVDTuneFakeFSLogix; $mrNew = New-Master
    [void](Save-AVDTuneRedirections -Machine $mrNew -F $rfNew -Root $tmp -Xml $xml -Folder $share -User 'admin1' -SnapshotId 'snap-check')
    [void](Undo-AVDTuneRedirections -Machine $mrNew -F $rfNew -Root $tmp -User 'admin1' -SnapshotId 'snap-check')
    Test-Check 'undo of a first save deletes the file instead of leaving an empty one (counter-test L5)' (-not $rfNew.Store.Files.ContainsKey("$share\redirections.xml") -and @($rfNew.Log | Where-Object { $_ -like "DeleteFile $share\redirections.xml" }).Count -eq 1) ($rfNew.Log -join '|')
    $rUndo = Join-Path $tmp 'config\redirections-undo.json'
    [void](Save-AVDTuneRedirections -Machine $mrNew -F $rfNew -Root $tmp -Xml $xml -Folder $share -User 'admin1' -SnapshotId 'snap-check')
    $firstR = [IO.File]::ReadAllText($rUndo)
    [void](Save-AVDTuneRedirections -Machine $mrNew -F $rfNew -Root $tmp -Xml ($xml -replace 'Contoso', 'Fabrikam') -Folder $share -User 'admin1' -SnapshotId 'snap-check')
    Test-Check 'a second save keeps the first redirections undo record under a versioned name (counter-test L5)' (@(Get-ChildItem (Join-Path $tmp 'config') -Filter 'redirections-undo.*.json' | Where-Object { [IO.File]::ReadAllText($_.FullName) -ceq $firstR }).Count -ge 1) $null
    # L4: '..' and local folders that users can change
    $real = New-AVDTuneFSLogixAdapter
    $userDir = Join-Path $tmp 'userdir'; [void](New-Item -ItemType Directory -Path $userDir -Force)
    Test-Check 'RedirXMLSourceFolder with .. is refused by the validation (counter-test L4)' ((Test-AVDTuneFSLogixValue $by['Profile:RedirXMLSourceFolder'] 'C:\Windows\..\Users\x') -like '*..*' -and (Test-AVDTuneFSLogixValue $by['Profile:RedirXMLSourceFolder'] "$share\..\other") -like '*..*')
    Test-Check 'the real adapter refuses .. and a local folder that users can change, for read, write and delete (counter-test L4)' ((Get-ThrownText { & $real.WriteText 'C:\Windows\..\Users\x\redirections.xml' 'x' }) -like "*'..'*" -and (Get-ThrownText { & $real.WriteText (Join-Path $userDir 'redirections.xml') 'x' }) -like '*users*' -and (Get-ThrownText { & $real.ReadText (Join-Path $userDir 'redirections.xml') }) -like '*users*' -and (Get-ThrownText { & $real.DeleteFile (Join-Path $userDir 'redirections.xml') }) -like '*users*' -and -not (Test-Path -LiteralPath (Join-Path $userDir 'redirections.xml'))) $null
    Test-Check 'a UNC target is not blocked by that check (the share is the administrator''s choice)' ($null -eq (Get-ThrownText { Assert-AVDTuneRedirectionsPath "$share\redirections.xml" })) $null
    # M3: DOMAIN\user with the real parser
    $ln1 = Split-AVDTuneLogonName 'EXAMPLE\alice'; $ln2 = Split-AVDTuneLogonName 'alice@example.test'; $ln3 = Split-AVDTuneLogonName 'alice'
    Test-Check 'DOMAIN\user, user@domain and a plain name are split by the real parser (counter-test M3)' ($ln1.Domain -eq 'EXAMPLE' -and $ln1.Name -eq 'alice' -and $ln2.Domain -eq 'example.test' -and $ln2.Name -eq 'alice' -and $ln3.Domain -eq '' -and $ln3.Name -eq 'alice') "$($ln1.Domain)|$($ln1.Name)"
    $srcFsl = Get-Content -LiteralPath (Join-Path $repo 'Modules\AVDTune.FSLogix.psm1') -Raw
    Test-Check 'the adapter uses that parser; the user is disposed (counter-test L2/M3)' ($srcFsl -match 'Split-AVDTuneLogonName \$User' -and $srcFsl -match '\$id\.Dispose\(\)') $null
    # L2/L3 in the page: password and key confirmation cleared after an error too; the share of the diff is set, behind the gate
    $srcPage = Get-Content -LiteralPath (Join-Path $repo 'AVDTune-FSLogix.ps1') -Raw
    Test-Check 'page: the password field is cleared before the error return (counter-test L2)' ($srcPage -match "(?s)if \(\`$job\.Kind -eq 'Storage'\) \{ \`$ui\.PwdFslPassword\.Clear\(\).{0,200}if \(\`$err -or -not \`$result\)") $null
    Test-Check 'page: the ACL is set on the share of the diff, after the write gate check, before the confirmation (counter-test L3)' ($srcPage -match '(?s)BtnFslAclSet \{.{0,900}Assert-FslWrite.{0,900}Confirm-Action' -and $srcPage -match 'Account = \[string\]\$d\.Account; Share = \[string\]\$d\.Share' -and $srcPage -notmatch 'Split-AVDTuneUncShare \(@\(Get-AVDTuneFSLogixLocations') $null

    # ---------------------------------------------------------------- Defender
    $dl = Get-AVDTuneFSLogixDefenderList -VhdLocations @($share)
    $paths = @($dl.Items | Where-Object Kind -eq 'Path' | ForEach-Object Value); $procs = @($dl.Items | Where-Object Kind -eq 'Process' | ForEach-Object Value)
    $apps = 'C:\Program Files\FSLogix\Apps'
    Test-Check 'Defender list: the two processes of Microsoft Learn, only with the full path, no frxccd.exe, no bare name (counter-test M1)' (($procs -join ',') -eq "$apps\frxsvc.exe,$apps\frxccds.exe" -and -not (@($dl.Items | Where-Object { $_.Kind -eq 'Process' -and $_.Value -notlike 'C:\Program Files\FSLogix\Apps\*' }).Count) -and -not (@($dl.Items | Where-Object { $_.Value -like '*frxccd.exe' }).Count)) ($procs -join ',')
    Test-Check 'Defender list: nothing beyond Learn''s list (folders: Apps, ProgramData\FSLogix with Cache and Proxy, Users, both Temp; drivers; shares); what Learn names with %username% or %TEMP% is Verified=false (counter-test M2)' (-not (@($dl.Items | Where-Object { $_.Kind -eq 'Path' -and $_.Value -notlike '\\*' -and $_.Value -notlike 'C:\Program Files\FSLogix\Apps\*' -and $_.Value -notlike 'C:\ProgramData\FSLogix\*' -and $_.Value -notlike 'C:\Users\*\AppData\Local\FSLogix\' -and $_.Value -notlike 'C:\Users\*\AppData\Local\Temp\*\*.VHD*' -and $_.Value -notlike 'C:\Windows\Temp\*\*.VHD*' }).Count) -and -not (@($dl.Items | Where-Object { $_.Value -like 'C:\Users\*' -and $_.Verified }).Count)) $dl.Items.Count
    Test-Check 'Defender list: every folder users can write to carries a visible risk text (Risk and Note), the install folder none (counter-test M2)' (-not (@($dl.Items | Where-Object { ($_.Value -like 'C:\ProgramData\FSLogix*' -or $_.Value -like 'C:\Users\*' -or $_.Value -like 'C:\Windows\Temp\*' -or $_.Value -like "$share*") -and (-not $_.Risk -or $_.Note -notlike 'RISK:*') }).Count) -and -not (@($dl.Items | Where-Object { $_.Value -like 'C:\Program Files\*' -and $_.Risk }).Count)) $null
    Test-Check 'Defender list: the three drivers, the folders, Cloud Cache cache and proxy' (-not (@('frxdrv.sys', 'frxdrvvt.sys', 'frxccd.sys' | Where-Object { $d = $_; -not (@($paths | Where-Object { $_ -like "*\$d" }).Count) }).Count) -and $paths -contains 'C:\Program Files\FSLogix\Apps\' -and $paths -contains 'C:\ProgramData\FSLogix\' -and $paths -contains 'C:\ProgramData\FSLogix\Cache\*' -and $paths -contains 'C:\ProgramData\FSLogix\Proxy\*' -and $paths -contains 'C:\Windows\Temp\*\*.VHDX') $null
    Test-Check 'Defender list: share patterns for VHD and VHDX with lock, meta, metadata' (-not (@('VHD', 'VHDX' | ForEach-Object { $e = $_; '', '.lock', '.meta', '.metadata' | ForEach-Object { "$share\*\*.$e$_" } } | Where-Object { $_ -notin $paths }).Count)) $null
    Test-Check 'Defender list: registry keys and mount points are named as not Defender types; every item has the Learn page as source' ($dl.NotDefender.Count -eq 3 -and -not (@($dl.Items | Where-Object { $_.Source -ne 'https://learn.microsoft.com/en-us/fslogix/overview-prerequisites' }).Count)) $null
    Test-Check 'the entries mapped by AVDTune (%TEMP%, %username%) are Verified=false with a note' (@($dl.Items | Where-Object { -not $_.Verified -and $_.Note }).Count -ge 3 -and -not (@($dl.Items | Where-Object { -not $_.Verified -and -not $_.Note }).Count)) $null
    $fd = New-AVDTuneFakeFSLogix
    $ds = Get-AVDTuneFSLogixDefenderState -F $fd -VhdLocations @($share)
    Test-Check 'state: readable, nothing present' ($ds.Readable -and @($ds.Items | Where-Object Present).Count -eq 0) $null
    Test-Check 'Defender writes without the gate are refused (gate is open in this run: close it for the check)' ((& { Close-AVDTuneWriteGate; $r = Test-Throws { Set-AVDTuneFSLogixDefender -Machine $m -F $fd -Root $tmp -VhdLocations @($share) }; Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'; $r }) -and $fd.Store.Defender.Paths.Count -eq 0) $null
    $sd = Set-AVDTuneFSLogixDefender -Machine $m -F $fd -Root $tmp -VhdLocations @($share) -User 'admin1' -SnapshotId 'snap-check'
    $ds2 = Get-AVDTuneFSLogixDefenderState -F $fd -VhdLocations @($share)
    Test-Check 'apply: every exclusion present afterwards, the run is Changed' ($sd.Results[0].Status -eq 'Changed' -and @($ds2.Items | Where-Object { -not $_.Present }).Count -eq 0 -and $fd.Store.Defender.Processes -contains 'C:\Program Files\FSLogix\Apps\frxsvc.exe' -and $fd.Store.Defender.Processes -notcontains 'frxsvc.exe') $null
    Test-Check 'idempotent: a second apply adds nothing' ((Set-AVDTuneFSLogixDefender -Machine $m -F $fd -Root $tmp -VhdLocations @($share) -User a -SnapshotId s).Results[0].Status -eq 'Unchanged') $null
    [void](Undo-AVDTuneFSLogixDefender -Machine $m -F $fd -Root $tmp -User 'admin1' -SnapshotId 'snap-check')
    Test-Check 'undo removes exactly what was added' (@($fd.Store.Defender.Paths).Count -eq 0 -and @($fd.Store.Defender.Processes).Count -eq 0) $null
    $dUndo = Join-Path $tmp 'config\fslogix-defender-undo.json'
    $fdTwo = New-AVDTuneFakeFSLogix
    [void](Set-AVDTuneFSLogixDefender -Machine $m -F $fdTwo -Root $tmp -User a -SnapshotId s)
    $firstUndo = [IO.File]::ReadAllText($dUndo)
    [void](Set-AVDTuneFSLogixDefender -Machine $m -F $fdTwo -Root $tmp -VhdLocations @($share) -User a -SnapshotId s)
    $archived = @(Get-ChildItem (Join-Path $tmp 'config') -Filter 'fslogix-defender-undo.*.json' | Where-Object { [IO.File]::ReadAllText($_.FullName) -ceq $firstUndo })
    Test-Check 'a second Defender change keeps the first undo record under a versioned name instead of overwriting it (counter-test L5)' ($archived.Count -eq 1 -and [IO.File]::ReadAllText($dUndo) -cne $firstUndo) $null
    [void](Undo-AVDTuneFSLogixDefender -Machine $m -F $fdTwo -Root $tmp -User a -SnapshotId s)
    $fdPre = New-AVDTuneFakeFSLogix -Seed @{ Defender = @{ Paths = @('D:\own'); Processes = @() } }
    [void](Set-AVDTuneFSLogixDefender -Machine $m -F $fdPre -Root $tmp -User a -SnapshotId s); [void](Undo-AVDTuneFSLogixDefender -Machine $m -F $fdPre -Root $tmp -User a -SnapshotId s)
    Test-Check 'an exclusion the administrator had before stays after undo' ($fdPre.Store.Defender.Paths -contains 'D:\own') $null
    $fdSk = New-AVDTuneFakeFSLogix
    $skipOne = 'C:\ProgramData\FSLogix\'
    $sdSk = Set-AVDTuneFSLogixDefender -Machine $m -F $fdSk -Root $tmp -VhdLocations @($share) -User 'admin1' -SnapshotId 'snap-check' -Skip @($skipOne.ToUpperInvariant())
    $skUndo = Read-AVDTuneJson (Join-Path $tmp 'config\fslogix-defender-undo.json')
    $skLog = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq 'fslogix.defender.exclusions' } | Select-Object -Last 1)
    Test-Check 'a deselected Defender exclusion is not set, not in the undo list, and the change log names it; the rest is set and the run is Changed, not Failed (counter-test)' ($sdSk.Results[0].Status -eq 'Changed' -and $fdSk.Store.Defender.Paths -notcontains $skipOne -and @($fdSk.Store.Defender.Paths).Count -gt 0 -and @($skUndo.Added | Where-Object { $_.Value -eq $skipOne }).Count -eq 0 -and @($skUndo.Added).Count -eq (@($fdSk.Store.Defender.Paths).Count + @($fdSk.Store.Defender.Processes).Count) -and $skLog.Count -eq 1 -and $skLog[0].Text -like "*deselected and not set*$skipOne*") (($sdSk.Results | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ' | ')
    Test-Check 'all missing exclusions deselected: nothing is set, the run is Unchanged' ((Set-AVDTuneFSLogixDefender -Machine $m -F (New-AVDTuneFakeFSLogix) -Root $tmp -VhdLocations @($share) -User a -SnapshotId s -Skip @((Get-AVDTuneFSLogixDefenderList -VhdLocations @($share)).Items | ForEach-Object { $_.Value })).Results[0].Status -eq 'Unchanged') $null
    [void](Undo-AVDTuneFSLogixDefender -Machine $m -F $fdSk -Root $tmp -User 'admin1' -SnapshotId 'snap-check')
    $fdNo = New-AVDTuneFakeFSLogix -Seed @{ Defender = $null }
    Test-Check 'Defender not readable (policy, other AV): state says so, apply refuses and changes nothing' (-not (Get-AVDTuneFSLogixDefenderState -F $fdNo).Readable -and (Get-ThrownText { Set-AVDTuneFSLogixDefender -Machine $m -F $fdNo -Root $tmp }) -like '*cannot be read*') $null

    # ---------------------------------------------------------------- install and update
    $lt = Get-AVDTuneFSLogixLatest -F (New-AVDTuneFakeFSLogix)
    Test-Check 'latest release: file name and version from the Microsoft link, no download' ($lt.Ok -and $lt.Version -eq '26.08' -and $lt.FileName -eq 'FSLogix_26.08.zip') $null
    $bad = Get-AVDTuneFSLogixLatest -F (New-AVDTuneFakeFSLogix -Seed @{ Latest = @{ Ok = $true; Url = 'https://evil.example/FSLogix_26.08.zip'; Error = '' } })
    $bad2 = Get-AVDTuneFSLogixLatest -F (New-AVDTuneFakeFSLogix -Seed @{ Latest = @{ Ok = $true; Url = 'http://download.microsoft.com/x/FSLogix_26.08.zip'; Error = '' } })
    Test-Check 'a link to another host or over http is not used' (-not $bad.Ok -and -not $bad2.Ok -and $bad.Error -like '*download.microsoft.com*') $null
    $mi = New-Master
    $fi = New-AVDTuneFakeFSLogix
    $inst = Invoke-AVDTuneFSLogixInstall -Machine $mi -F $fi -Root $tmp
    Test-Check 'update: downloaded, signature checked twice, installed, version read, reboot flagged' ($inst.Status -eq 'Changed' -and $inst.After -eq '3.26.826.17182' -and $inst.Before -eq '2.9.8884.27471' -and $inst.Reboot -and @($fi.Log | Where-Object { $_ -like 'VerifySignature FSLogixAppsSetup.exe' }).Count -eq 2) $inst.Message
    Test-Check 'the installer ran with the Learn switches, from the protected folder' (@($mi.Log | Where-Object { $_ -like 'Run C:\fake\temp\fslogix-0\x\x64\Release\FSLogixAppsSetup.exe /install /quiet /norestart' }).Count -eq 1) ($mi.Log -join '|')
    Test-Check 'the download folder is removed at the end' (@($fi.Log | Where-Object { $_ -like 'RemoveFolder C:\fake\temp\fslogix-0' }).Count -eq 1) $null
    $fresh = New-Master -Reg @{ 'HKLM:\SOFTWARE\FSLogix\Apps|InstallVersion' = '3.26.826.17182' }
    $un = Invoke-AVDTuneFSLogixInstall -Machine $fresh -F (New-AVDTuneFakeFSLogix) -Root $tmp
    Test-Check 'already current: Unchanged and the installer is not started' ($un.Status -eq 'Unchanged' -and -not (@($fresh.Log | Where-Object { $_ -like '*FSLogixAppsSetup*' }).Count)) $un.Message
    $nw = New-Master -Reg @{ 'HKLM:\SOFTWARE\FSLogix\Apps|InstallVersion' = $null }
    $first = Invoke-AVDTuneFSLogixInstall -Machine $nw -F (New-AVDTuneFakeFSLogix) -Root $tmp
    Test-Check 'first install (nothing installed): Changed' ($first.Status -eq 'Changed' -and $first.Message -like 'Installed*') $first.Message
    $e1 = Invoke-AVDTuneFSLogixInstall -Machine (New-Master) -F (New-AVDTuneFakeFSLogix -Seed @{ Signatures = @{ 'FSLogixAppsSetup.exe' = @{ Valid = $true; Subject = 'CN=Contoso Software, O=Contoso Software'; Issuer = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US' } } }) -Root $tmp
    $mE = New-Master; $e2 = Invoke-AVDTuneFSLogixInstall -Machine $mE -F (New-AVDTuneFakeFSLogix -Seed @{ Signatures = @{ 'FSLogixAppsSetup.exe' = @{ Valid = $false; Subject = ''; Issuer = '' } } }) -Root $tmp
    $e3 = Invoke-AVDTuneFSLogixInstall -Machine (New-Master) -F (New-AVDTuneFakeFSLogix -Seed @{ Signatures = @{ 'FSLogixAppsSetup.exe' = @{ Valid = $true; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation'; Issuer = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US'; OriginalFilename = 'other.exe' } } }) -Root $tmp
    Test-Check 'wrong publisher, no signature, wrong original file name: Failed BadSignature, installer never started' ($e1.Code -eq 'BadSignature' -and $e2.Code -eq 'BadSignature' -and $e3.Code -eq 'BadSignature' -and -not (@($mE.Log | Where-Object { $_ -like '*/install*' }).Count)) "$($e1.Code) $($e2.Code) $($e3.Code)"
    $mP = New-Master; $e4 = Invoke-AVDTuneFSLogixInstall -Machine $mP -F (New-AVDTuneFakeFSLogix -Seed @{ Protected = $false }) -Root $tmp
    Test-Check 'a download folder that is not admin-only: nothing is downloaded' ($e4.Code -eq 'NotProtected') $null
    $fN = New-AVDTuneFakeFSLogix -Seed @{ DownloadFails = $true }
    $e5 = Invoke-AVDTuneFSLogixInstall -Machine (New-Master) -F $fN -Root $tmp
    Test-Check 'no network: the download fails, Failed Download, folder removed' ($e5.Code -eq 'Download' -and @($fN.Log | Where-Object { $_ -like 'RemoveFolder*' }).Count -eq 1) $null
    $e6 = Invoke-AVDTuneFSLogixInstall -Machine (New-Master) -F (New-AVDTuneFakeFSLogix -Seed @{ Latest = @{ Ok = $false; Url = ''; Error = 'offline' } }) -Root $tmp
    $e7 = Invoke-AVDTuneFSLogixInstall -Machine (New-Master) -F (New-AVDTuneFakeFSLogix -Seed @{ ExpandFails = $true }) -Root $tmp
    $e8 = Invoke-AVDTuneFSLogixInstall -Machine (New-Master) -F (New-AVDTuneFakeFSLogix -Seed @{ NoInstaller = $true }) -Root $tmp
    $e9 = Invoke-AVDTuneFSLogixInstall -Machine (New-Master -Native @{ '* /install /quiet /norestart' = @{ ExitCode = 1603; Output = 'fatal error' } }) -F (New-AVDTuneFakeFSLogix) -Root $tmp
    $e10 = Invoke-AVDTuneFSLogixInstall -Machine (New-Master -Native @{ '* /install /quiet /norestart' = @{ ExitCode = 0; Output = '' } } -Reg @{ 'HKLM:\SOFTWARE\FSLogix\Apps|InstallVersion' = $null }) -F (New-AVDTuneFakeFSLogix) -Root $tmp
    Test-Check 'no release, bad zip, no installer in it, installer exit 1603, not registered afterwards: all Failed with a code' ($e6.Code -eq 'NoRelease' -and $e7.Code -eq 'Unpack' -and $e8.Code -eq 'NoInstaller' -and $e9.Code -eq 'Exit1603' -and $e10.Code -eq 'NotRegistered') "$($e6.Code) $($e7.Code) $($e8.Code) $($e9.Code) $($e10.Code)"
    Test-Check 'the real adapter is built without touching anything (members present)' ((New-AVDTuneFSLogixAdapter).PSObject.Properties.Name -contains 'Download' -and (New-AVDTuneFSLogixAdapter).Kind -eq 'Real') $null

    Close-AVDTuneWriteGate
    Test-Check 'recorded install without the gate is refused, nothing downloaded' ((Test-Throws { Invoke-AVDTuneFSLogixInstallRecorded -Machine (New-Master) -F (New-AVDTuneFakeFSLogix) -Root $tmp }) -and $true) $null
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
    $fr = New-AVDTuneFakeFSLogix
    $ri = Invoke-AVDTuneFSLogixInstallRecorded -Machine (New-Master) -F $fr -Root $tmp -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'recorded install: run record, LastChange, change log entry (Updated, FSLogix), restart flag' ($ri.Result.Status -eq 'Changed' -and $ri.Result.Reboot -and @(Get-AVDTuneRun -Root $tmp | Where-Object Plan -eq 'FSLogix install').Count -eq 1 -and @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq 'FSLogix' -and $_.ChangeType -eq 'Updated' }).Count -eq 1) $ri.Install.Message
    $rbad = Invoke-AVDTuneFSLogixInstallRecorded -Machine (New-Master) -F (New-AVDTuneFakeFSLogix -Seed @{ DownloadFails = $true }) -Root $tmp -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'a failed install is recorded too (note in the change log, LastChange set)' ($rbad.Result.Status -eq 'Failed' -and @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Text -like '*install FAILED*' }).Count -eq 1) $null

    # ---------------------------------------------------------------- ACL
    $rs = New-AVDTuneFSLogixRecommendedSddl -UsersSid $sddlUsers -AdminsSid $sddlAdmins
    $cmpOk = Compare-AVDTuneFSLogixAcl -Sddl $rs -UsersSids @($sddlUsers) -AdminsSids @($sddlAdmins)
    Test-Check 'the recommended SDDL matches the recommendation (CREATOR OWNER, admins, users this folder only)' ($cmpOk.Compliant -and $cmpOk.Findings.Count -eq 0) (($cmpOk.Findings | ForEach-Object Text) -join ';')
    $everyone = Compare-AVDTuneFSLogixAcl -Sddl 'O:BAG:DUD:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;BA)' -UsersSids @($sddlUsers) -AdminsSids @($sddlAdmins)
    Test-Check 'Everyone with full control down the tree: red (users could see other containers), CREATOR OWNER missing: red' (-not $everyone.Compliant -and @($everyone.Findings | Where-Object { $_.Status -eq 'red' -and $_.Id -like 'broad*' }).Count -eq 1 -and @($everyone.Findings | Where-Object Id -eq 'creator-owner').Count -eq 1) (($everyone.Findings | ForEach-Object Id) -join ',')
    $usersInherit = Compare-AVDTuneFSLogixAcl -Sddl "O:BAG:DUD:PAI(A;OICIIO;0x1301bf;;;CO)(A;OICI;FA;;;$sddlAdmins)(A;OICI;0x1301bf;;;$sddlUsers)(A;OICI;FA;;;SY)" -UsersSids @($sddlUsers) -AdminsSids @($sddlAdmins)
    Test-Check 'the users group with modify on the subfolders as well: red (must be this folder only)' (@($usersInherit.Findings | Where-Object { $_.Status -eq 'red' }).Count -ge 1) (($usersInherit.Findings | ForEach-Object Id) -join ',')
    $unknown = Compare-AVDTuneFSLogixAcl -Sddl $rs
    Test-Check 'without the group SIDs (Entra only, no domain): yellow, check by hand, never green' (-not $unknown.Compliant -and @($unknown.Findings | Where-Object Status -eq 'yellow').Count -eq 2 -and @($unknown.Findings | Where-Object Status -eq 'red').Count -eq 0) $null
    Test-Check 'a bad SID in the builder, an unparsable SDDL' ((Test-Throws { New-AVDTuneFSLogixRecommendedSddl -UsersSid 'Users' -AdminsSid $sddlAdmins }) -and (Test-Throws { Compare-AVDTuneFSLogixAcl -Sddl 'not sddl' })) $null

    # ---------------------------------------------------------------- function test
    $goodF = { New-AVDTuneFakeFSLogix -Seed @{ Acl = @{ $share = $rs }; Probe = @{}; Defender = @{ Paths = @(); Processes = @() } } }
    $f0 = & $goodF
    [void](Set-AVDTuneFSLogixDefender -Machine (New-Master) -F $f0 -Root $tmp -VhdLocations @($share) -User a -SnapshotId s)
    [void]($f0.Store.Groups['FSLogix Profile Exclude List'] = @('S-1-5-32-544'))
    $mt = New-Master -Reg @{ "$pk|RedirXMLSourceFolder" = $share }
    $f0.Store.Files["$share\redirections.xml"] = $xml
    $t0 = Invoke-AVDTuneFSLogixTest -Machine $mt -F $f0 -RunWriteTests -UsersSids @($sddlUsers) -AdminsSids @($sddlAdmins)
    $nonGreen = @($t0.Rows | Where-Object { $_.Status -notin 'green', 'info' })
    Test-Check 'all green: version, services, drivers, registry, DNS, 445, SMB, write test, ACL, VHDX, redirections, Defender, admins' ($t0.Overall -eq 'green' -and $t0.Passed -and $nonGreen.Count -eq 0) (($nonGreen | ForEach-Object { "$($_.Id)=$($_.Status): $($_.Reason)" }) -join ' | ')
    Test-Check 'every row has a source and says whether Learn states it (Verified)' (-not (@($t0.Rows | Where-Object { $_.Source -notmatch '^https://learn\.microsoft\.com/' -or ($_.Verified -isnot [bool]) -or (-not $_.Verified -and -not $_.Note) }).Count)) $null
    Test-Check 'the test steps 1 to 7 appear; step 7 (a real sign-in) is info, never green' ((@($t0.Rows | ForEach-Object Step | Sort-Object -Unique) -join ',') -eq '1,2,3,4,5,6,7' -and (Get-Row $t0 'fs.logon').Status -eq 'info') $null
    Test-Check 'the write tests ran on the share (folder test and frx create/attach/detach)' (@($f0.Log | Where-Object { $_ -like 'ShareWriteTest*' }).Count -eq 1 -and @($mt.Log | Where-Object { $_ -like '*frx.exe create-vhd *' }).Count -eq 1 -and @($mt.Log | Where-Object { $_ -like '*frx.exe end-edit-profile -cookie 4876 *' }).Count -eq 1) $null
    $ro = Invoke-AVDTuneFSLogixTest -Machine (New-Master) -F (& $goodF)
    Test-Check 'without -RunWriteTests nothing is written to the share: write test and VHDX are info' ((Get-Row $ro 'fs.loc1.rw').Status -eq 'info' -and (Get-Row $ro 'fs.loc1.vhdx').Status -eq 'info') $null
    $nf = New-AVDTuneFakeFSLogix
    Test-Check 'a read only test touches no share and no frx' (@($nf.Log | Where-Object { $_ -like 'ShareWriteTest*' -or $_ -like 'DeleteFile*' }).Count -eq 0 -and -not (Invoke-AVDTuneFSLogixTest -Machine (New-Master) -F $nf | Out-Null)) $null

    $tn = Invoke-AVDTuneFSLogixTest -Machine (New-Master -Reg @{ 'HKLM:\SOFTWARE\FSLogix\Apps|InstallVersion' = $null }) -F (& $goodF)
    Test-Check 'FSLogix not installed: red with the fix' ((Get-Row $tn 'fs.version').Status -eq 'red' -and (Get-Row $tn 'fs.version').Fix -like '*Install*' -and $tn.Overall -eq 'red') $null
    $ts = Invoke-AVDTuneFSLogixTest -Machine (New-Master -Services @(@{ Name = 'frxsvc'; Status = 'Stopped' })) -F (& $goodF)
    Test-Check 'frxsvc stopped: red' ((Get-Row $ts 'fs.services').Status -eq 'red' -and (Get-Row $ts 'fs.services').Reason -like '*Stopped*') $null
    $tsc = Invoke-AVDTuneFSLogixTest -Machine (New-Master -Reg @{ "$pk|CCDLocations" = 'type=smb,connectionString=x'; "$pk|VHDLocations" = $null } -Services @(@{ Name = 'frxsvc'; Status = 'Running' })) -F (& $goodF)
    Test-Check 'Cloud Cache set but frxccds missing: red' ((Get-Row $tsc 'fs.services').Status -eq 'red' -and (Get-Row $tsc 'fs.services').Reason -like '*frxccds*') $null
    $td = Invoke-AVDTuneFSLogixTest -Machine (New-Master -Native @{ $fltmc = @{ ExitCode = 0; Output = "Filter Name`r`nWdFilter  5  328010  0`r`n" } }) -F (& $goodF)
    $td2 = Invoke-AVDTuneFSLogixTest -Machine (New-Master -Native @{ $fltmc = @{ ExitCode = 5; Output = 'denied' } }) -F (& $goodF)
    Test-Check 'drivers not loaded: red; fltmc unreadable: yellow' ((Get-Row $td 'fs.driver').Status -eq 'red' -and (Get-Row $td2 'fs.driver').Status -eq 'yellow') $null
    $tr = Invoke-AVDTuneFSLogixTest -Machine (New-Master -Reg @{ "$pk|Enabled" = 0; "$pk|VHDLocations" = @("$share\"); "$pk|VolumeType" = 'iso'; "$pk|LockedRetryCount" = 'x' }) -F (& $goodF)
    Test-Check 'registry: Enabled 0, trailing backslash in the path, bad VolumeType, non-numeric value: red, all named' ((Get-Row $tr 'fs.registry').Status -eq 'red' -and (Get-Row $tr 'fs.registry').Reason -like '*Enabled*' -and (Get-Row $tr 'fs.registry').Reason -like '*UNC*' -and (Get-Row $tr 'fs.registry').Reason -like '*VolumeType*') (Get-Row $tr 'fs.registry').Reason
    $tty = Invoke-AVDTuneFSLogixTest -Machine (New-Master -Reg @{ "$pk|LockedRetyCount" = 3 }) -F (& $goodF)
    Test-Check 'a misspelled value name is a yellow typo hint' ((Get-Row $tty 'fs.registry').Status -eq 'yellow' -and (Get-Row $tty 'fs.registry').Reason -like '*LockedRetyCount*') (Get-Row $tty 'fs.registry').Reason
    $tc = Invoke-AVDTuneFSLogixTest -Machine (New-Master -Reg @{ "$pk|CCDLocations" = 'type=smb' }) -F (& $goodF)
    Test-Check 'Cloud Cache together with VHDLocations: red conflict' ((Get-Row $tc 'fs.conflict').Status -eq 'red') $null
    $tdns = Invoke-AVDTuneFSLogixTest -Machine (New-Master) -F (New-AVDTuneFakeFSLogix -Seed @{ Dns = @{ 'storageaccount.file.core.windows.net' = @{ Ok = $false; Addresses = @(); Error = 'No such host is known' } } })
    Test-Check 'DNS does not resolve (private zone missing): red with the private DNS fix, port and SMB are info (not tested)' ((Get-Row $tdns 'fs.loc1.dns').Status -eq 'red' -and (Get-Row $tdns 'fs.loc1.dns').Fix -like '*privatelink*' -and (Get-Row $tdns 'fs.loc1.tcp').Status -eq 'info' -and (Get-Row $tdns 'fs.loc1.smb').Status -eq 'info') $null
    $tpub = Invoke-AVDTuneFSLogixTest -Machine (New-Master) -F (New-AVDTuneFakeFSLogix -Seed @{ Dns = @{ 'storageaccount.file.core.windows.net' = @{ Ok = $true; Addresses = @('203.0.113.7'); Error = '' } } })
    Test-Check 'DNS answers (the reading of the IP is shown to the administrator, who decides whether it is the private one)' ((Get-Row $tpub 'fs.loc1.dns').Reason -like '*203.0.113.7*') $null
    $t445 = Invoke-AVDTuneFSLogixTest -Machine (New-Master) -F (New-AVDTuneFakeFSLogix -Seed @{ Tcp = @{ 'storageaccount.file.core.windows.net' = $false } })
    Test-Check 'port 445 blocked: red with the firewall hint' ((Get-Row $t445 'fs.loc1.tcp').Status -eq 'red' -and (Get-Row $t445 'fs.loc1.tcp').Fix -like '*445*') $null
    $tden = Invoke-AVDTuneFSLogixTest -Machine (New-Master) -F (New-AVDTuneFakeFSLogix -Seed @{ Probe = @{ $share = 'Denied' } }) -RunWriteTests
    Test-Check 'the share refuses the master (not joined): yellow, expected, write tests not run and say why' ((Get-Row $tden 'fs.loc1.smb').Status -eq 'yellow' -and (Get-Row $tden 'fs.loc1.rw').Status -eq 'yellow' -and (Get-Row $tden 'fs.loc1.vhdx').Status -eq 'yellow' -and $tden.Overall -eq 'yellow') $null
    $tnotfound = Invoke-AVDTuneFSLogixTest -Machine (New-Master) -F (New-AVDTuneFakeFSLogix -Seed @{ Probe = @{ $share = 'Failed' } })
    Test-Check 'share not found: red' ((Get-Row $tnotfound 'fs.loc1.smb').Status -eq 'red') $null
    $twf = Invoke-AVDTuneFSLogixTest -Machine (New-Master) -F (New-AVDTuneFakeFSLogix -Seed @{ WriteFail = 'create folder' }) -RunWriteTests
    Test-Check 'write test fails at create folder: red, names the step' ((Get-Row $twf 'fs.loc1.rw').Status -eq 'red' -and (Get-Row $twf 'fs.loc1.rw').Reason -like '*create folder*') $null
    $tacl = Invoke-AVDTuneFSLogixTest -Machine (New-Master) -F (New-AVDTuneFakeFSLogix -Seed @{ Acl = @{ $share = 'O:BAG:DUD:PAI(A;OICI;FA;;;WD)' } }) -UsersSids @($sddlUsers) -AdminsSids @($sddlAdmins)
    Test-Check 'ACL deviates (Everyone full control): red with the fix pointing at the storage check' ((Get-Row $tacl 'fs.loc1.acl').Status -eq 'red' -and (Get-Row $tacl 'fs.loc1.acl').Fix -like '*storage check*') $null
    $tfx = Invoke-AVDTuneFSLogixTest -Machine (New-Master -Native @{ '*frx.exe create-vhd *' = @{ ExitCode = 1; Output = 'Error 0x80070005 access denied' } }) -F (& $goodF) -RunWriteTests
    Test-Check 'frx create-vhd fails: red with the output' ((Get-Row $tfx 'fs.loc1.vhdx').Status -eq 'red' -and (Get-Row $tfx 'fs.loc1.vhdx').Reason -like '*0x80070005*') $null
    $mfx = New-Master -Native @{ '*frx.exe end-edit-profile *' = @{ ExitCode = 1; Output = 'busy' } }
    $tfx2 = Invoke-AVDTuneFSLogixTest -Machine $mfx -F (& $goodF) -RunWriteTests
    Test-Check 'detach fails: red; the detach is tried once more in the finally block' ((Get-Row $tfx2 'fs.loc1.vhdx').Status -eq 'red' -and @($mfx.Log | Where-Object { $_ -like '*end-edit-profile*' }).Count -eq 2) @($mfx.Log | Where-Object { $_ -like '*end-edit*' }).Count
    $mfx3 = New-Master -Native @{ '*frx.exe begin-edit-profile *' = @{ ExitCode = 0; Output = 'attached' } }
    $tfx3 = Invoke-AVDTuneFSLogixTest -Machine $mfx3 -F (& $goodF) -RunWriteTests
    Test-Check 'frx prints no cookie: red, tells the administrator to detach by hand' ((Get-Row $tfx3 'fs.loc1.vhdx').Status -eq 'red' -and (Get-Row $tfx3 'fs.loc1.vhdx').Reason -like '*by hand*') $null
    $tfx4 = Invoke-AVDTuneFSLogixTest -Machine (New-Master) -F (New-AVDTuneFakeFSLogix -Seed @{ FrxMissing = $true }) -RunWriteTests
    $tfx5 = Invoke-AVDTuneFSLogixTest -Machine (New-Master) -F (New-AVDTuneFakeFSLogix -Seed @{ Signatures = @{ 'frx.exe' = @{ Valid = $false; Subject = ''; Issuer = '' } } }) -RunWriteTests
    Test-Check 'frx missing or not signed by Microsoft: red, frx is not started' ((Get-Row $tfx4 'fs.loc1.vhdx').Status -eq 'red' -and (Get-Row $tfx5 'fs.loc1.vhdx').Status -eq 'red') $null
    $tred = Invoke-AVDTuneFSLogixTest -Machine (New-Master) -F (New-AVDTuneFakeFSLogix -Seed @{ Files = @{ "$share\redirections.xml" = '<FrxProfileFolderRedirection><Excludes><Exclude Copy="0">AppData\Local\Microsoft\TokenBroker</Exclude></Excludes></FrxProfileFolderRedirection>' } })
    $mred = New-Master -Reg @{ "$pk|RedirXMLSourceFolder" = $share }
    $tred = Invoke-AVDTuneFSLogixTest -Machine $mred -F (New-AVDTuneFakeFSLogix -Seed @{ Files = @{ "$share\redirections.xml" = '<FrxProfileFolderRedirection><Excludes><Exclude Copy="0">AppData\Local\Microsoft\TokenBroker</Exclude></Excludes></FrxProfileFolderRedirection>' } })
    $tred2 = Invoke-AVDTuneFSLogixTest -Machine $mred -F (New-AVDTuneFakeFSLogix)
    Test-Check 'redirections.xml that excludes the token broker: red; setting set but file unreadable: yellow; no setting: info' ((Get-Row $tred 'fs.redir').Status -eq 'red' -and (Get-Row $tred2 'fs.redir').Status -eq 'yellow' -and (Get-Row $ro 'fs.redir').Status -eq 'info') $null
    Test-Check 'Defender exclusions missing: yellow with the count; not readable: yellow' ((Get-Row $ro 'fs.defender').Status -eq 'yellow' -and (Get-Row $ro 'fs.defender').Reason -like '*missing*' -and (Get-Row (Invoke-AVDTuneFSLogixTest -Machine (New-Master) -F (New-AVDTuneFakeFSLogix -Seed @{ Defender = $null })) 'fs.defender').Reason -like '*cannot be read*') $null
    Test-Check 'local Administrators not in the exclude list: yellow; group missing: red' ((Get-Row $ro 'fs.admins').Status -eq 'yellow' -and (Get-Row (Invoke-AVDTuneFSLogixTest -Machine (New-Master) -F (New-AVDTuneFakeFSLogix -Seed @{ Groups = @{} })) 'fs.admins').Status -eq 'red') $null
    $tex = Invoke-AVDTuneFSLogixTest -Machine (New-Master) -F ([pscustomobject]@{ Kind = 'Broken' } | Add-Member -PassThru -NotePropertyName Dns -NotePropertyValue { throw 'adapter down' })
    Test-Check 'an adapter that throws turns a check red, the test itself does not throw' ((Get-Row $tex 'fs.loc1.dns').Status -eq 'red' -and $tex.Overall -eq 'red') $null
    Test-Check 'no VHDLocations at all: registry red, no share checks' ((Get-Row (Invoke-AVDTuneFSLogixTest -Machine (New-Master -Reg @{ "$pk|VHDLocations" = $null }) -F (& $goodF)) 'fs.registry').Status -eq 'red') $null

    # ---------------------------------------------------------------- storing the result
    $saved = Save-AVDTuneFSLogixTestRun -Root $tmp -Result $tr -User 'admin1' -SnapshotId 'snap-check' -Machine $mt
    $before = (Get-AVDTuneState $tmp).LastChange
    $rec = Get-AVDTuneFSLogixTestRecord -Root $tmp
    Test-Check 'a test result is stored: state record, run record (FSLogix-Test), change log note, no change of LastChange' ($rec.Overall -eq 'red' -and $rec.Red -ge 1 -and @(Get-AVDTuneRun -Root $tmp | Where-Object Plan -eq 'FSLogix-Test').Count -eq 1 -and @(Get-AVDTuneChangeLog -Root $tmp | Where-Object Component -eq 'FSLogix-Test').Count -eq 1 -and (Get-AVDTuneState $tmp).LastChange -eq $before) $null
    $savedGreen = Save-AVDTuneFSLogixTestRun -Root $tmp -Result $t0 -User 'admin1' -SnapshotId 'snap-check' -Machine $mt
    Test-Check 'a newer green result replaces the record' ((Get-AVDTuneFSLogixTestRecord -Root $tmp).Overall -eq 'green' -and (Get-AVDTuneFSLogixTestRecord -Root $tmp).Red -eq 0) $null
    $leak = (Get-Content -LiteralPath (Join-Path $tmp 'state.json') -Raw) + (Get-Content -LiteralPath (Join-Path $tmp 'changelog.json') -Raw)
    Test-Check 'no key, token or password text in the stored records' ($leak -notmatch '(?i)accountkey|bearer|password|sig=') $null
}
finally {
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
