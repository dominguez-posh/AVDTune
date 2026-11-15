#requires -Version 5.1
<#
.SYNOPSIS
    Checks App Masking and the Public Desktop (Modules\AVDTune.Masking.psm1, issue 29) against the fake machine, the fake masking adapter, the fake LDAP and a temporary state
    folder: byte format of .fxr/.fxa (golden text, BOM, CRLF, unknown lines kept), assignments and what they mean, validation of names, OUs and paths, writing behind the write
    gate with change log and undo (older backups kept), groups in AD only after confirmation and only in an OU of the domain controller, local groups, unsafe folders, the
    Public Desktop list with coverage, comfort shortcuts, and source checks of the real adapter. Nothing touches FSLogix, a domain controller or this computer.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Updates.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.FSLogix.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Directory.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Masking.psm1') -Force
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeMasking.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Test-Throws([scriptblock]$Block) { try { & $Block | Out-Null; $false } catch { $true } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }
function Get-Text([byte[]]$Bytes) { ConvertFrom-AVDTuneRuleBytes $Bytes }
function Test-Same($A, $B) { ([Convert]::ToBase64String($A)) -ceq ([Convert]::ToBase64String($B)) }

$rules = 'C:\Program Files\FSLogix\Apps\Rules'
$pd = '%SystemDriveFolder%\Users\Public\Desktop'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-mask-' + [guid]::NewGuid().ToString('N'))
$dn = 'DC=example,DC=test'
$ouDn = "OU=Groups,OU=AVD,OU=Corp,$dn"
$dirInfo = [pscustomobject]@{ DefaultNamingContext = $dn; NetBiosName = 'EXAMPLE'; OuTree = @([pscustomobject]@{ Name = 'Corp'; Dn = "OU=Corp,$dn"; Children = @([pscustomobject]@{ Name = 'AVD'; Dn = "OU=AVD,OU=Corp,$dn"; Children = @([pscustomobject]@{ Name = 'Groups'; Dn = $ouDn; Children = @() }) }) }) }
function New-Env([hashtable]$Seed = @{}, [hashtable]$LdapSeed = @{}) {
    [pscustomobject]@{ Machine = (New-AVDTuneFakeMachine -Seed @{ Now = [datetime]'2026-11-15T10:00:00' }); M = (New-AVDTuneFakeMasking -Seed $Seed); Ldap = (New-AVDTuneFakeMaskingLdap -Seed $LdapSeed) }
}
function Get-Written($Env, [string]$Name, [string]$Ext) { $p = "$rules\$Name.$Ext"; if ($Env.M.Store.Files.ContainsKey($p)) { Get-Text $Env.M.Store.Files[$p] } else { $null } }

try {
    $env:AVDTUNE_ROOT = $tmp
    [void](Initialize-AVDTuneState -Root $tmp)
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-15') -User 'admin1')
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- byte format
    $b = ConvertTo-AVDTuneRuleBytes "1`r`n"
    Test-Check 'format: a rule set that hides nothing is "1" CRLF = FF FE + 6 bytes (UTF-16 LE with BOM)' ($b.Length -eq 8 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE -and $b[2] -eq 0x31 -and $b[3] -eq 0 -and $b[4] -eq 0x0D -and $b[6] -eq 0x0A) ($b -join ',')
    Test-Check 'format: UTF-8, UTF-16 without BOM and an odd length are refused when reading (the causes of the failing hand-made files)' ((Test-Throws { ConvertFrom-AVDTuneRuleBytes ([Text.Encoding]::UTF8.GetBytes("1`r`n")) }) -and (Test-Throws { ConvertFrom-AVDTuneRuleBytes ([Text.Encoding]::Unicode.GetBytes("1`r`n")) }) -and (Test-Throws { ConvertFrom-AVDTuneRuleBytes ([byte[]](0xFF, 0xFE, 0x31)) })) $null
    $fxrText = "1`r`n##`r`n$pd`tApp One.lnk`t`t`t0x00000222`t`r`n##`r`n$pd`tApp Two.lnk`t`t`t0x00000222`t`r`n"
    $fxr = ConvertFrom-AVDTuneFxrText $fxrText
    Test-Check 'fxr: golden text parses to two rules and writes back byte for byte (## before every rule, 5 tabs)' ($fxr.Entries.Count -eq 2 -and $fxr.Entries[0].Rule.Name -eq 'App One.lnk' -and $fxr.Entries[0].Rule.Flags -eq '0x00000222' -and (ConvertTo-AVDTuneFxrText $fxr) -ceq $fxrText) $null
    Test-Check 'fxr: the rule line is exactly folder TAB name TAB TAB TAB flags TAB' ((ConvertTo-AVDTuneFxrRuleLine $pd 'App One.lnk') -ceq "$pd`tApp One.lnk`t`t`t0x00000222`t") $null
    $odd = "1`r`n##`r`nHKEY_LOCAL_MACHINE\SOFTWARE\X`t`t`t`t0x00000011`t`r`n##`r`nC:\Some`tfile.exe`t`t`t0x00000222`t`r`n"
    $fo = ConvertFrom-AVDTuneFxrText $odd
    Test-Check 'fxr: lines that are not file rules are kept unchanged, also after a rule was added (migration: unknown parts stay)' ((ConvertTo-AVDTuneFxrText $fo) -ceq $odd -and $fo.Entries[0].Rule -ne $null -and $fo.Entries.Count -eq 2) $null
    Test-Check 'fxr: a header that is not 1 and LF line ends are reported' ((ConvertFrom-AVDTuneFxrText "2`r`n").Problems.Count -eq 1 -and (ConvertFrom-AVDTuneFxrText "1`n##`n").Problems.Count -eq 1) $null
    $t = '133000000000000000'
    $rows = ConvertTo-AVDTuneFxaRows -Visibility HiddenExceptGroups -Groups @([pscustomobject]@{ Account = 'EXAMPLE\AVD-App-One'; Dn = "CN=AVD-App-One,$ouDn" }) -AdminDn "CN=Administrators,CN=Builtin,$dn" -AdminName 'BUILTIN\Administrators' -Time $t
    $fxaGolden = "1`t`r`n0x00000011`tS-1-1-0`t`tEveryone`t0`t0`r`n0x00000012`tS-1-5-32-544`tCN=Administrators,CN=Builtin,$dn`tBUILTIN\Administrators`t0`t0`r`n0x00000012`tEXAMPLE\AVD-App-One`tCN=AVD-App-One,$ouDn`tEXAMPLE\AVD-App-One`t$t`t0`r`n"
    Test-Check 'fxa: golden text (header "1" TAB, Everyone applies, Administrators and the group by NAME with DN do not apply, FILETIME, 6 fields)' ((ConvertTo-AVDTuneFxaText ([pscustomobject]@{ Rows = $rows })) -ceq $fxaGolden) (ConvertTo-AVDTuneFxaText ([pscustomobject]@{ Rows = $rows }))
    $fxa = ConvertFrom-AVDTuneFxaText $fxaGolden
    $vis = Get-AVDTuneRuleVisibility $fxa
    Test-Check 'fxa: read back, hidden for everyone except Administrators and the group; the written text is the same' ($fxa.Rows.Count -eq 3 -and $vis.Effect -eq 'Hidden' -and $vis.ShownFor.Count -eq 2 -and $vis.Text -like '*EXAMPLE\AVD-App-One*' -and (ConvertTo-AVDTuneFxaText $fxa) -ceq $fxaGolden) $vis.Text
    $eNo = ConvertFrom-AVDTuneFxaText "1`t`r`n0x00000012`tS-1-1-0`t`tEveryone`t0`t0`r`n"
    Test-Check 'fxa: the Rule Editor default (Everyone, Applies No) hides nothing; Everyone applying at the bottom after a group hides everyone (Learn: order matters)' ((Get-AVDTuneRuleVisibility $eNo).Effect -eq 'NoEffect' -and (Get-AVDTuneRuleVisibility (ConvertFrom-AVDTuneFxaText "1`t`r`n0x00000011`tEXAMPLE\Domain Users`t`tx`t0`t0`r`n0x00000011`tS-1-1-0`t`tEveryone`t0`t0`r`n")).Effect -eq 'Hidden') $null
    Test-Check 'fxa: a row that is not understood is kept and reported' ((ConvertTo-AVDTuneFxaText (ConvertFrom-AVDTuneFxaText "1`t`r`nfoo bar`r`n")) -ceq "1`t`r`nfoo bar`r`n" -and (ConvertFrom-AVDTuneFxaText "1`t`r`nfoo bar`r`n").Problems.Count -eq 1) $null
    Test-Check 'fxa: HiddenExceptGroups without a group and an account without DOMAIN\ are refused' ((Test-Throws { ConvertTo-AVDTuneFxaRows -Visibility HiddenExceptGroups -Groups @() -AdminName 'A' -Time '1' }) -and (Test-Throws { ConvertTo-AVDTuneFxaRows -Visibility HiddenExceptGroups -Groups @([pscustomobject]@{ Account = "nodomain`tx"; Dn = '' }) -AdminName 'A' -Time '1' })) $null

    # ---------------------------------------------------------------- validation (counter-tests: each of these must fail)
    Test-Check 'names: rule set names accept normal names and refuse paths, device names, wildcards, trailing dots and long names' ((Test-AVDTuneMaskingName 'Public Desktop') -and (Test-AVDTuneMaskingName 'a') -and -not (Test-AVDTuneMaskingName '..\evil') -and -not (Test-AVDTuneMaskingName 'a/b') -and -not (Test-AVDTuneMaskingName 'CON') -and -not (Test-AVDTuneMaskingName 'com1.txt') -and -not (Test-AVDTuneMaskingName 'x*') -and -not (Test-AVDTuneMaskingName 'x.') -and -not (Test-AVDTuneMaskingName (' ' + 'x')) -and -not (Test-AVDTuneMaskingName ('a' * 65)) -and -not (Test-AVDTuneMaskingName '')) $null
    Test-Check 'names: group names refuse LDAP and DN special characters (injection) and blanks at the ends' ((Test-AVDTuneMaskingGroupName 'AVD-App-Chrome') -and -not (Test-AVDTuneMaskingGroupName 'a)(objectClass=*') -and -not (Test-AVDTuneMaskingGroupName 'a,OU=x') -and -not (Test-AVDTuneMaskingGroupName 'a\b') -and -not (Test-AVDTuneMaskingGroupName 'a*') -and -not (Test-AVDTuneMaskingGroupName 'a+b') -and -not (Test-AVDTuneMaskingGroupName ' a') -and -not (Test-AVDTuneMaskingGroupName "a`nb") -and -not (Test-AVDTuneMaskingGroupName ('a' * 65))) $null
    Test-Check 'names: the group name is <prefix>-App-<name>; a bad prefix or name fails' ((Get-AVDTuneAppGroupName 'AVD' 'Google Chrome') -eq 'AVD-App-Google-Chrome' -and (Test-Throws { Get-AVDTuneAppGroupName 'A,B' 'x' }) -and (Test-Throws { Get-AVDTuneAppGroupName '' 'x' })) $null
    Test-Check 'paths: folder and file name of a rule: ".." / wildcards / device names / control characters / path in the name are refused' ((Test-AVDTuneMaskingRulePath $pd 'A.lnk') -eq '' -and (Test-AVDTuneMaskingRulePath 'C:\Users\Public\Desktop' 'A.lnk') -eq '' -and (Test-AVDTuneMaskingRulePath "$pd\..\x" 'A.lnk') -ne '' -and (Test-AVDTuneMaskingRulePath $pd '*.lnk') -ne '' -and (Test-AVDTuneMaskingRulePath $pd '..\A.lnk') -ne '' -and (Test-AVDTuneMaskingRulePath $pd 'NUL') -ne '' -and (Test-AVDTuneMaskingRulePath $pd "A`t.lnk") -ne '' -and (Test-AVDTuneMaskingRulePath '\\srv\share' 'A.lnk') -ne '' -and (Test-AVDTuneMaskingRulePath 'relative\x' 'A.lnk') -ne '' -and (Test-AVDTuneMaskingRulePath $pd 'A.lnk ') -ne '' -and (Test-AVDTuneMaskingRulePath "$pd*" 'A.lnk') -ne '') $null
    Test-Check 'OU: only an OU of the domain controller (exact DN, case-insensitive) is accepted' ((Test-AVDTuneOuDn $ouDn $dirInfo.OuTree) -and (Test-AVDTuneOuDn $ouDn.ToLowerInvariant() $dirInfo.OuTree) -and -not (Test-AVDTuneOuDn "OU=Evil,$dn" $dirInfo.OuTree) -and -not (Test-AVDTuneOuDn "CN=x,$ouDn" $dirInfo.OuTree) -and -not (Test-AVDTuneOuDn '' $dirInfo.OuTree) -and -not (Test-AVDTuneOuDn "$ouDn`r`n" $dirInfo.OuTree)) $null
    Test-Check 'environment: with a domain controller AD groups are offered, Entra only gets no AD groups (Learn: no cloud-only assignments) and says why' ((Get-AVDTuneMaskingCapabilities ([pscustomobject]@{ DomainController = '10.0.0.10' })).AdGroups -and -not (Get-AVDTuneMaskingCapabilities ([pscustomobject]@{ DomainController = 'None' })).AdGroups -and (Get-AVDTuneMaskingCapabilities ([pscustomobject]@{ DomainController = 'None' })).Note -like '*Entra*') $null
    Set-AVDTuneMaskingSettings -Root $tmp -Prefix 'Corp1'
    Test-Check 'settings: the prefix is saved and validated' ((Get-AVDTuneMaskingSettings -Root $tmp).Prefix -eq 'Corp1' -and (Test-Throws { Set-AVDTuneMaskingSettings -Root $tmp -Prefix 'a b;' }) -and (Get-AVDTuneMaskingSettings -Root $tmp).Prefix -eq 'Corp1') $null

    # ---------------------------------------------------------------- write gate
    $e = New-Env
    $entries = @(@{ Folder = $pd; Name = 'App One.lnk' })
    $closed = Get-ThrownText { Save-AVDTuneRuleSet -Machine $e.Machine -M $e.M -Root $tmp -Name 'Set1' -Entries $entries -Visibility Hidden -User 'admin1' }
    Test-Check 'gate: without a confirmed snapshot nothing is written (the gate is shut)' ($closed -like '*snapshot gate*' -and $e.M.Store.Files.Count -eq 0) $closed
    $dry = Save-AVDTuneRuleSet -Machine $e.Machine -M $e.M -Root $tmp -Name 'Set1' -Entries $entries -Visibility Hidden -WhatIf
    Test-Check 'gate: -WhatIf shows the changes and writes nothing (also without the gate)' (@($dry.Results | Where-Object Status -eq 'WhatIf').Count -eq 2 -and $e.M.Store.Files.Count -eq 0 -and -not (Test-Path (Get-AVDTuneMaskingUndoPath $tmp))) (($dry.Results | ForEach-Object { $_.Status }) -join ',')
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'

    # ---------------------------------------------------------------- create, change log, undo
    $run = Save-AVDTuneRuleSet -Machine $e.Machine -M $e.M -Root $tmp -Name 'Set1' -Entries $entries -Visibility Hidden -User 'admin1' -SnapshotId 'snap-check'
    $fxrOut = Get-Written $e 'Set1' 'fxr'; $fxaOut = Get-Written $e 'Set1' 'fxa'
    Test-Check 'create: both files are written as UTF-16 LE with BOM, CRLF, golden content (hidden for everyone except Administrators, local name resolved)' (@($run.Results | Where-Object Status -eq 'Changed').Count -eq 2 -and $fxrOut -ceq "1`r`n##`r`n$pd`tApp One.lnk`t`t`t0x00000222`t`r`n" -and $fxaOut -ceq "1`t`r`n0x00000011`tS-1-1-0`t`tEveryone`t0`t0`r`n0x00000012`tS-1-5-32-544`t`tBUILTIN\Administrators`t0`t0`r`n" -and $e.M.Store.Files["$rules\Set1.fxr"][0] -eq 0xFF) (($run.Results | ForEach-Object { "$($_.Id)=$($_.Status) $($_.Message)" }) -join ';')
    $log = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'AppMasking' })
    Test-Check 'create: change log entries (category AppMasking, user, snapshot) and LastChange moved' ($log.Count -eq 2 -and $log[0].User -eq 'admin1' -and $log[0].SnapshotId -eq 'snap-check' -and $null -ne (Get-AVDTuneState $tmp).LastChange) $null
    $again = Save-AVDTuneRuleSet -Machine $e.Machine -M $e.M -Root $tmp -Name 'Set1' -Entries $entries -Visibility Hidden -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'create: the same call again changes nothing (idempotent)' (@($again.Results | Where-Object Status -eq 'Unchanged').Count -eq 2) (($again.Results | ForEach-Object Status) -join ',')
    $undoRun = Undo-AVDTuneMaskingChange -Machine $e.Machine -M $e.M -Root $tmp -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'undo: files that were not there are deleted again, the undo record is used up, the change log has the entries' ($e.M.Store.Files.Count -eq 0 -and -not (Test-Path (Get-AVDTuneMaskingUndoPath $tmp)) -and @($undoRun.Results | Where-Object Status -eq 'Changed').Count -eq 2) (($undoRun.Results | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ';')
    Test-Check 'undo: nothing recorded = refused' ((Get-ThrownText { Undo-AVDTuneMaskingChange -Machine $e.Machine -M $e.M -Root $tmp }) -like '*nothing to undo*') $null

    # existing rule set: unknown lines stay, rule added, previous bytes restored by undo, older backup kept
    $e2 = New-Env -Seed @{ Files = @{ "$rules\Mixed.fxr" = (ConvertTo-AVDTuneRuleBytes $odd); "$rules\Mixed.fxa" = (ConvertTo-AVDTuneRuleBytes "1`t`r`n0x00000012`tS-1-1-0`t`tEveryone`t0`t0`r`n") } }
    $oldFxr = $e2.M.Store.Files["$rules\Mixed.fxr"]; $oldFxa = $e2.M.Store.Files["$rules\Mixed.fxa"]
    $sets = @(Get-AVDTuneRuleSets -M $e2.M)
    Test-Check 'read: a rule set made by the Rule Editor is listed with its rules, the unknown rule counted, and the assignment explained' ($sets.Count -eq 1 -and $sets[0].Rules.Count -eq 2 -and $sets[0].Visibility.Effect -eq 'NoEffect' -and $sets[0].Problems.Count -eq 0) (($sets[0].Problems) -join ';')
    $c1 = Save-AVDTuneRuleSet -Machine $e2.Machine -M $e2.M -Root $tmp -Name 'Mixed' -Entries @(@{ Folder = $pd; Name = 'New.lnk' }, @{ Folder = 'C:\Some'; Name = 'file.exe' }) -Visibility Hidden -User 'admin1' -SnapshotId 's'
    $mixedOut = Get-Written $e2 'Mixed' 'fxr'
    Test-Check 'change: existing rules and the line that is not a file rule stay, only the missing rule is added (no doubles)' ($mixedOut.StartsWith($odd) -and $mixedOut -ceq ($odd + "##`r`n$pd`tNew.lnk`t`t`t0x00000222`t`r`n") -and (Get-AVDTuneRuleSets -M $e2.M)[0].Visibility.Effect -eq 'Hidden') $mixedOut
    $c2 = Save-AVDTuneRuleSet -Machine $e2.Machine -M $e2.M -Root $tmp -Name 'Mixed' -Entries @(@{ Folder = $pd; Name = 'Third.lnk' }) -Visibility Hidden -User 'admin1' -SnapshotId 's'
    $arch = @(Get-ChildItem (Join-Path $tmp 'config') -Filter 'masking-undo.*.json')
    Test-Check 'undo record: the second change keeps the first record under a versioned name (older backups are not overwritten)' ($arch.Count -eq 1 -and ((Get-Content $arch[0].FullName -Raw) -like '*Mixed.fxr*')) $null
    [void](Undo-AVDTuneMaskingChange -Machine $e2.Machine -M $e2.M -Root $tmp -User 'admin1' -SnapshotId 's')
    Test-Check 'undo: the last change is put back byte for byte' ((Get-Written $e2 'Mixed' 'fxr').Contains('New.lnk') -and -not (Get-Written $e2 'Mixed' 'fxr').Contains('Third.lnk')) $null
    $r = Remove-AVDTuneRuleSet -Machine $e2.Machine -M $e2.M -Root $tmp -Name 'Mixed' -User 'admin1' -SnapshotId 's'
    Test-Check 'remove: both files are deleted and the undo restores the original files' ($e2.M.Store.Files.Count -eq 0 -and (Test-Throws { Remove-AVDTuneRuleSet -Machine $e2.Machine -M $e2.M -Root $tmp -Name 'Mixed' }) -and (& { Undo-AVDTuneMaskingChange -Machine $e2.Machine -M $e2.M -Root $tmp -User "a" -SnapshotId "s" | Out-Null; $true }) -and $e2.M.Store.Files.Count -eq 2) $null

    # ---------------------------------------------------------------- unsafe folder, invalid input
    $e3 = New-Env -Seed @{ Unsafe = $true }
    $u = Save-AVDTuneRuleSet -Machine $e3.Machine -M $e3.M -Root $tmp -Name 'Bad' -Entries $entries -Visibility Hidden -User 'a' -SnapshotId 's'
    Test-Check 'folder: a rules folder that users can change stops the write (step failed, nothing in the folder, the second step skipped)' ((@($u.Results | Where-Object Status -eq 'Failed').Count -eq 1) -and (@($u.Results | Where-Object Status -eq 'Skipped').Count -eq 1) -and $e3.M.Store.Files.Count -eq 0 -and $u.Results[0].Message -like '*not safe*') (($u.Results | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ';')
    $bad = @(
        { Save-AVDTuneRuleSet -Machine $e.Machine -M $e.M -Root $tmp -Name '..\x' -Entries $entries -User a -SnapshotId s },
        { Save-AVDTuneRuleSet -Machine $e.Machine -M $e.M -Root $tmp -Name 'ok' -Entries @(@{ Folder = $pd; Name = '*.lnk' }) -User a -SnapshotId s },
        { Save-AVDTuneRuleSet -Machine $e.Machine -M $e.M -Root $tmp -Name 'ok' -Entries @(@{ Folder = "$pd\..\Windows"; Name = 'a.lnk' }) -User a -SnapshotId s },
        { Save-AVDTuneRuleSet -Machine $e.Machine -M $e.M -Root $tmp -Name 'ok' -Entries @() -User a -SnapshotId s },
        { Save-AVDTuneRuleSet -Machine $e.Machine -M $e.M -Root $tmp -Name 'ok' -Entries $entries -Visibility HiddenExceptGroups -User a -SnapshotId s },
        { Save-AVDTuneRuleSet -Machine $e.Machine -M $e.M -Root $tmp -Name 'ok' -Entries $entries -Visibility HiddenExceptGroups -Groups @([pscustomobject]@{ Account = 'nodomain'; Dn = '' }) -User a -SnapshotId s })
    Test-Check 'input: bad rule set name, wildcard, ".." in the folder, no entry, no group, a group account without a domain are all refused and nothing is written' (@($bad | Where-Object { -not (Test-Throws $_) }).Count -eq 0 -and $e.M.Store.Files.Count -eq 0) $null

    # ---------------------------------------------------------------- groups in AD
    $e4 = New-Env
    $cg = @{ Kind = 'Ad'; Name = 'Corp1-App-Chrome'; OuDn = $ouDn }
    $noConf = Get-ThrownText { Save-AVDTuneRuleSet -Machine $e4.Machine -M $e4.M -Root $tmp -Name 'Chrome' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup $cg -Ldap $e4.Ldap -Conn 'c' -Directory $dirInfo -User a -SnapshotId s }
    Test-Check 'AD group: without the confirmation nothing is created and nothing is written' ($noConf -like '*confirmation*' -and $e4.Ldap.Store.Added.Count -eq 0 -and $e4.M.Store.Files.Count -eq 0) $noConf
    $wi = Save-AVDTuneRuleSet -Machine $e4.Machine -M $e4.M -Root $tmp -Name 'Chrome' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup $cg -Ldap $e4.Ldap -Conn 'c' -Directory $dirInfo -WhatIf
    Test-Check 'AD group: -WhatIf names the group step and creates nothing' (@($dry.Results).Count -gt 0 -and $e4.Ldap.Store.Added.Count -eq 0 -and @($wi.Results | Where-Object { $_.Id -eq 'appmasking.group.create' -and $_.Status -eq 'WhatIf' }).Count -eq 1) $null
    $ev = @(
        { Save-AVDTuneRuleSet -Machine $e4.Machine -M $e4.M -Root $tmp -Name 'Chrome' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup @{ Kind = 'Ad'; Name = 'x'; OuDn = "OU=Evil,$dn" } -Ldap $e4.Ldap -Conn 'c' -Directory $dirInfo -Confirmed -User a -SnapshotId s },
        { Save-AVDTuneRuleSet -Machine $e4.Machine -M $e4.M -Root $tmp -Name 'Chrome' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup @{ Kind = 'Ad'; Name = 'a,OU=x'; OuDn = $ouDn } -Ldap $e4.Ldap -Conn 'c' -Directory $dirInfo -Confirmed -User a -SnapshotId s },
        { Save-AVDTuneRuleSet -Machine $e4.Machine -M $e4.M -Root $tmp -Name 'Chrome' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup @{ Kind = 'Ad'; Name = 'x'; OuDn = $ouDn } -Directory $dirInfo -Confirmed -User a -SnapshotId s },
        { Save-AVDTuneRuleSet -Machine $e4.Machine -M $e4.M -Root $tmp -Name 'Chrome' -Entries $entries -Visibility Hidden -CreateGroup $cg -Ldap $e4.Ldap -Conn 'c' -Directory $dirInfo -Confirmed -User a -SnapshotId s },
        { Save-AVDTuneRuleSet -Machine $e4.Machine -M $e4.M -Root $tmp -Name 'Chrome' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup $cg -Ldap $e4.Ldap -Conn 'c' -Directory ([pscustomobject]@{ DefaultNamingContext = $dn; NetBiosName = ''; OuTree = $dirInfo.OuTree }) -Confirmed -User a -SnapshotId s })
    Test-Check 'AD group: an OU the DC did not return, a group name with DN characters, no LDAP connection, a group for a visibility without groups and an unknown NetBIOS name are refused before anything is created' (@($ev | Where-Object { -not (Test-Throws $_) }).Count -eq 0 -and $e4.Ldap.Store.Added.Count -eq 0 -and $e4.M.Store.Files.Count -eq 0) (@($ev | Where-Object { -not (Test-Throws $_) }).Count)
    $g = Save-AVDTuneRuleSet -Machine $e4.Machine -M $e4.M -Root $tmp -Name 'Chrome' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup $cg -Ldap $e4.Ldap -Conn 'c' -Directory $dirInfo -Confirmed -User 'admin1' -SnapshotId 'snap-check'
    $added = $e4.Ldap.Store.Added
    $fxaG = Get-Written $e4 'Chrome' 'fxa'
    Test-Check 'AD group: created once, in the chosen OU, as a global security group with AVDTune description; objectClass group' ($added.Count -eq 1 -and $added[0].Dn -eq "CN=Corp1-App-Chrome,$ouDn" -and $added[0].Attributes['groupType'] -eq '-2147483646' -and $added[0].Attributes['description'] -eq 'AVDTune App Masking: Chrome' -and $added[0].Attributes['sAMAccountName'] -eq 'Corp1-App-Chrome') (($g.Results | ForEach-Object { "$($_.Id)=$($_.Status) $($_.Message)" }) -join ';')
    Test-Check 'AD group: the .fxa row names the group by DOMAIN\name with its DN, and the Administrators row carries the DN read from the DC by SID' ($fxaG -like "*0x00000012`tEXAMPLE\Corp1-App-Chrome`tCN=Corp1-App-Chrome,$ouDn`tEXAMPLE\Corp1-App-Chrome`t1*" -and $fxaG -like "*0x00000012`tS-1-5-32-544`tCN=Administrators,CN=Builtin,$dn`tBUILTIN\Administrators*") $fxaG
    Test-Check 'AD group: the change log names the group step' (@(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq 'appmasking.group.create' }).Count -eq 1) $null
    $dup = Get-ThrownText { Save-AVDTuneRuleSet -Machine $e4.Machine -M $e4.M -Root $tmp -Name 'Chrome2' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup $cg -Ldap $e4.Ldap -Conn 'c' -Directory $dirInfo -Confirmed -User a -SnapshotId s }
    Test-Check 'AD group: a group of that name that exists is not created again (choose it instead)' ($dup -like '*exists already*' -and $e4.Ldap.Store.Added.Count -eq 1) $dup
    # undo with a member / changed description / clean
    $e4.Ldap.Store.Groups[0].Members = @("CN=user,$dn")
    $uf = Undo-AVDTuneMaskingChange -Machine $e4.Machine -M $e4.M -Root $tmp -Ldap $e4.Ldap -Conn 'c' -User a -SnapshotId s
    Test-Check 'undo: a group that has members is not deleted (the step fails, the group stays)' (@($uf.Results | Where-Object { $_.Status -eq 'Failed' -and $_.Message -like '*member*' }).Count -eq 1 -and $e4.Ldap.Store.Deleted.Count -eq 0 -and $e4.Ldap.Store.Groups.Count -eq 1) (($uf.Results | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ';')
    $e4.Ldap.Store.Groups[0].Members = @(); $e4.Ldap.Store.Groups[0].Description = 'something else'
    $uf2 = Undo-AVDTuneMaskingChange -Machine $e4.Machine -M $e4.M -Root $tmp -Ldap $e4.Ldap -Conn 'c' -User a -SnapshotId s
    Test-Check 'undo: a group that does not carry the AVDTune description any more is not deleted' (@($uf2.Results | Where-Object { $_.Status -eq 'Failed' -and $_.Message -like '*description*' }).Count -eq 1 -and $e4.Ldap.Store.Deleted.Count -eq 0) (($uf2.Results | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ';')
    $e4.Ldap.Store.Groups[0].Description = 'AVDTune App Masking: Chrome'
    $uok = Undo-AVDTuneMaskingChange -Machine $e4.Machine -M $e4.M -Root $tmp -Ldap $e4.Ldap -Conn 'c' -User a -SnapshotId s
    Test-Check 'undo: the group AVDTune created is deleted again and the files are gone' ($e4.Ldap.Store.Deleted.Count -eq 1 -and $e4.Ldap.Store.Groups.Count -eq 0 -and $e4.M.Store.Files.Count -eq 0 -and (Test-Throws { Undo-AVDTuneMaskingChange -Machine $e4.Machine -M $e4.M -Root $tmp -Ldap $e4.Ldap -Conn 'c' })) (($uok.Results | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ';')
    $e5 = New-Env -LdapSeed @{ AddFails = $true }
    $af = Save-AVDTuneRuleSet -Machine $e5.Machine -M $e5.M -Root $tmp -Name 'Chrome' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup $cg -Ldap $e5.Ldap -Conn 'c' -Directory $dirInfo -Confirmed -User a -SnapshotId s
    Test-Check 'AD group: when AD refuses (no delegation) the step fails, no rule file is written' (@($af.Results | Where-Object Status -eq 'Failed').Count -eq 1 -and $e5.M.Store.Files.Count -eq 0) (($af.Results | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ';')
    $wr = New-AVDTuneLdapWriter -Ldap $e5.Ldap
    Test-Check 'AD group: the real adapter (Search, no Add) is extended with Add and Delete; an adapter that has them is used as it is' ((New-AVDTuneLdapWriter -Ldap ([pscustomobject]@{ Search = {}; Close = {} })).Add -is [scriptblock] -and [object]::ReferenceEquals($wr, $e5.Ldap)) $null

    # ---------------------------------------------------------------- local groups
    $e6 = New-Env
    $lg = Save-AVDTuneRuleSet -Machine $e6.Machine -M $e6.M -Root $tmp -Name 'Local1' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup @{ Kind = 'Local'; Name = 'AVDTune-App-Local1' } -Confirmed -User a -SnapshotId s
    Test-Check 'local group: created after the confirmation and written as <computer>\<group> without a DN' ($e6.M.Store.LocalGroups.ContainsKey('AVDTune-App-Local1') -and (Get-Written $e6 'Local1' 'fxa') -like "*0x00000012`tGM-TEST01\AVDTune-App-Local1`t`tGM-TEST01\AVDTune-App-Local1`t*") (($lg.Results | ForEach-Object { "$($_.Id)=$($_.Status) $($_.Message)" }) -join ';')
    Test-Check 'local group: without the confirmation nothing is created' ((Test-Throws { Save-AVDTuneRuleSet -Machine $e6.Machine -M $e6.M -Root $tmp -Name 'Local2' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup @{ Kind = 'Local'; Name = 'AVDTune-App-Local2' } -User a -SnapshotId s }) -and -not $e6.M.Store.LocalGroups.ContainsKey('AVDTune-App-Local2')) $null
    $e6.M.Store.LocalGroups['AVDTune-App-Local1'] = 'renamed by someone'
    $ul = Undo-AVDTuneMaskingChange -Machine $e6.Machine -M $e6.M -Root $tmp -User a -SnapshotId s
    Test-Check 'undo: a local group with another description is not deleted' (@($ul.Results | Where-Object Status -eq 'Failed').Count -eq 1 -and $e6.M.Store.LocalGroups.ContainsKey('AVDTune-App-Local1')) $null

    # ---------------------------------------------------------------- Public Desktop
    $desk = @(
        @{ Name = 'App One.lnk'; Target = 'C:\Apps\one.exe'; IsShortcut = $true }, @{ Name = 'App Two.lnk'; Target = 'C:\Apps\two.exe'; IsShortcut = $true },
        @{ Name = 'App Three.lnk'; Target = 'C:\Apps\three.exe'; IsShortcut = $true }, @{ Name = 'readme.txt'; Target = ''; IsShortcut = $false })
    $e7 = New-Env -Seed @{ Desktop = $desk; Files = @{
            "$rules\Hide1.fxr" = (ConvertTo-AVDTuneRuleBytes "1`r`n##`r`n$pd`tapp one.lnk`t`t`t0x00000222`t`r`n"); "$rules\Hide1.fxa" = (ConvertTo-AVDTuneRuleBytes $fxaGolden)
            "$rules\Idle.fxr" = (ConvertTo-AVDTuneRuleBytes "1`r`n##`r`nC:\Users\Public\Desktop`tApp Two.lnk`t`t`t0x00000222`t`r`n"); "$rules\Idle.fxa" = (ConvertTo-AVDTuneRuleBytes "1`t`r`n0x00000012`tS-1-1-0`t`tEveryone`t0`t0`r`n") } }
    $ov = Get-AVDTuneMaskingOverview -M $e7.M
    $byName = @{}; foreach ($x in $ov.PublicDesktop) { $byName[$x.Name] = $x }
    Test-Check 'public desktop: entries covered by a rule (case-insensitive, %SystemDriveFolder% and C:\ spelling) are Hidden with who sees them; a rule that hides nothing is NotHiding; the rest is Uncovered' ($byName['App One.lnk'].State -eq 'Hidden' -and $byName['App One.lnk'].Text -like 'Hidden for everyone except*' -and $byName['App Two.lnk'].State -eq 'NotHiding' -and $byName['App Three.lnk'].State -eq 'Uncovered' -and $byName['readme.txt'].State -eq 'Uncovered') (($ov.PublicDesktop | ForEach-Object { "$($_.Name)=$($_.State)" }) -join ';')
    Test-Check 'public desktop: the counter of entries without a working hiding rule is 3 (Two, Three, readme)' ($ov.Uncovered -eq 3 -and $ov.RuleSets.Count -eq 2) $ov.Uncovered
    $wz = Save-AVDTuneRuleSet -Machine $e7.Machine -M $e7.M -Root $tmp -Name 'Public Desktop' -Entries @(@{ Folder = $pd; Name = 'App Three.lnk' }, @{ Folder = $pd; Name = 'App Two.lnk' }) -Visibility Hidden -User a -SnapshotId s
    $ov2 = Get-AVDTuneMaskingOverview -M $e7.M
    Test-Check 'wizard: the selected entries get a hiding rule and the counter drops to the entries that were not selected' ($ov2.Uncovered -eq 1 -and ($ov2.PublicDesktop | Where-Object Name -eq 'App Three.lnk').State -eq 'Hidden') $ov2.Uncovered
    Test-Check 'wizard: with Entra only (no group) the choice is "hidden for everyone" and the Everyone row is the only applying row' ((Get-Written $e7 'Public Desktop' 'fxa') -like "*0x00000011`tS-1-1-0*" -and (Get-AVDTuneRuleSets -M $e7.M | Where-Object Name -eq 'Public Desktop').Rows.Count -eq 2) $null

    # ---------------------------------------------------------------- comfort shortcuts
    $e8 = New-Env
    $cs = @(Get-AVDTuneComfortShortcuts -M $e8.M)
    Test-Check 'comfort: "Abmelden" runs shutdown.exe /l from the Windows system folder (full path), not through PATH; it says that the icon is not verified' ($cs.Count -eq 1 -and $cs[0].Target -eq 'C:\Windows\System32\shutdown.exe' -and $cs[0].Arguments -eq '/l' -and -not $cs[0].Verified -and $cs[0].Icon -like 'C:\Windows\System32\shell32.dll,*') $null
    $cr = Add-AVDTuneComfortShortcut -Machine $e8.Machine -M $e8.M -Root $tmp -Id logoff -User a -SnapshotId s
    $lnk = $e8.M.Store.Shortcuts['C:\Users\Public\Desktop\Abmelden.lnk']
    Test-Check 'comfort: the shortcut is created on the Public Desktop with a change log entry' (@($cr.Results | Where-Object Status -eq 'Changed').Count -eq 1 -and $lnk.Target -eq $cs[0].Target -and $lnk.Description -like 'AVDTune comfort shortcut*' -and @(Get-AVDTuneChangeLog -Root $tmp | Where-Object Component -eq 'appmasking.comfort.logoff').Count -eq 1) $null
    $cr2 = Add-AVDTuneComfortShortcut -Machine $e8.Machine -M $e8.M -Root $tmp -Id logoff -User a -SnapshotId s
    Test-Check 'comfort: again = unchanged; undo removes the shortcut' (@($cr2.Results | Where-Object Status -eq 'Unchanged').Count -eq 1 -and (& { Undo-AVDTuneMaskingChange -Machine $e8.Machine -M $e8.M -Root $tmp -User a -SnapshotId s | Out-Null; $true }) -and $e8.M.Store.Shortcuts.Count -eq 0) $null
    $e9 = New-Env -Seed @{ Shortcuts = @{ 'C:\Users\Public\Desktop\Abmelden.lnk' = @{ Target = 'C:\evil.exe'; Arguments = ''; Icon = ''; Description = 'something else' } } }
    Test-Check 'comfort: a file of that name that AVDTune did not make is never replaced' ((Test-Throws { Add-AVDTuneComfortShortcut -Machine $e9.Machine -M $e9.M -Root $tmp -Id logoff -User a -SnapshotId s }) -and $e9.M.Store.Shortcuts['C:\Users\Public\Desktop\Abmelden.lnk'].Target -eq 'C:\evil.exe') $null
    $e10 = New-Env -Seed @{ Unsafe = $true }
    $cf = Add-AVDTuneComfortShortcut -Machine $e10.Machine -M $e10.M -Root $tmp -Id logoff -User a -SnapshotId s
    Test-Check 'comfort: a Public Desktop that is a link stops the write' (@($cf.Results | Where-Object Status -eq 'Failed').Count -eq 1 -and $e10.M.Store.Shortcuts.Count -eq 0) $null

    # ---------------------------------------------------------------- source checks of the real adapter and the module (checklist points)
    $src = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Masking.psm1'))
    $adapter = $src.Substring($src.IndexOf('function New-AVDTuneMaskingAdapter'))
    Test-Check 'source: the real writer creates files with CreateNew and the protected ACL, checks parent folder, folder and target with Get-AVDTuneAclProblems, never File.Replace' ($adapter -match 'FileMode\]::CreateNew' -and $adapter -match 'New-AVDTuneFileSecurity' -and $adapter -match 'Get-AVDTuneAclProblems \(Read-AVDTuneAclReport \$c\)' -and $adapter -match 'Split-Path \$folder -Parent' -and $src -notmatch 'File\]::Replace|\.Replace\(\$temp') $null
    Test-Check 'source: the rules folder comes from the Program Files folder of Windows, programs are not started, nothing recursive is deleted, no regex without a limit on data' ($adapter -match 'Get-AVDTuneSystemFolder ProgramFiles' -and $src -notmatch 'Start-Process|Invoke-Expression|iex |Remove-Item .*-Recurse|ProcessStartInfo|Get-Command' -and $src -notmatch '\$env:(ProgramFiles|SystemRoot|windir|PATH)') $null
    Test-Check 'source: the comfort shortcut target comes from the system folder API; the shortcut is written with the protected file ACL and links are refused' ($adapter -match 'Get-AVDTuneSystemFolder System' -and $adapter -match 'SetAccessControl\(\$acl\)' -and $adapter -match '\$rep.Link' -and $adapter -match "New-AVDTuneFileSecurity") $null
    Test-Check 'source: reading refuses links and files over 4 MB; the LDAP filter value is escaped and the group name validated before it' ($adapter -match 'is a link: not read' -and $adapter -match '4MB' -and $src -match 'ConvertTo-AVDTuneLdapFilterValue \$Name' -and $src -match "if \(-not \(Test-AVDTuneMaskingGroupName \`$Name\)\) \{ throw ") $null
    Test-Check 'source: no password or token is handled in this module (the connection comes from the start sequence)' ($src -notmatch 'Password|SecureString|token|Credential') $null
    Test-Check 'source: the group is created only behind the Confirmed switch (AD and local)' (([regex]::Matches($src, 'needs your confirmation')).Count -eq 2) $null
}
finally {
    Close-AVDTuneWriteGate
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { "Check-Masking: $script:failed failed."; exit 1 }
'Check-Masking: all checks passed.'
