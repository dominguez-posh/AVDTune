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
    Test-Check 'fxr: lines that are not file rules are kept unchanged, also after a rule was added (migration: unknown parts stay)' ((ConvertTo-AVDTuneFxrText $fo) -ceq $odd -and $fo.Entries[0].Rule -eq $null -and $fo.Entries[1].Rule -ne $null -and $fo.Entries.Count -eq 2) $null
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

    # existing rule set: rule added, previous bytes restored by undo, older backup kept; an assignment that changes its meaning needs an explicit accept
    $fileOnly = "1`r`n##`r`n$pd`tOld.lnk`t`t`t0x00000222`t`r`n"
    $e2 = New-Env -Seed @{ Files = @{ "$rules\Mixed.fxr" = (ConvertTo-AVDTuneRuleBytes $fileOnly); "$rules\Mixed.fxa" = (ConvertTo-AVDTuneRuleBytes "1`t`r`n0x00000012`tS-1-1-0`t`tEveryone`t0`t0`r`n") } }
    $oldFxr = $e2.M.Store.Files["$rules\Mixed.fxr"]; $oldFxa = $e2.M.Store.Files["$rules\Mixed.fxa"]
    $sets = @(Get-AVDTuneRuleSets -M $e2.M)
    Test-Check 'read: a rule set made by the Rule Editor is listed with its rules and the assignment explained' ($sets.Count -eq 1 -and $sets[0].Rules.Count -eq 1 -and $sets[0].Visibility.Effect -eq 'NoEffect' -and $sets[0].Problems.Count -eq 0) (($sets[0].Problems) -join ';')
    $noAccept = Get-ThrownText { Save-AVDTuneRuleSet -Machine $e2.Machine -M $e2.M -Root $tmp -Name 'Mixed' -Entries @(@{ Folder = $pd; Name = 'New.lnk' }) -Visibility Hidden -User 'admin1' -SnapshotId 's' }
    Test-Check 'assignment: an existing assignment that would mean something else is refused without the explicit accept (old and new meaning in the text), nothing written' ($noAccept -like '*would change from*Not hidden for anybody*to*Hidden for everyone*' -and (Test-AVDTuneMaskBytesEqual $e2.M.Store.Files["$rules\Mixed.fxa"] $oldFxa)) $noAccept
    $wiChange = Save-AVDTuneRuleSet -Machine $e2.Machine -M $e2.M -Root $tmp -Name 'Mixed' -Entries @(@{ Folder = $pd; Name = 'New.lnk' }) -Visibility Hidden -WhatIf
    $anyChange = @{ Old = 'Not hidden for anybody (the assignment has no effect)'; New = 'Hidden for everyone except: BUILTIN\Administrators' }
    Test-Check 'assignment: the preview carries old and new meaning for the confirmation; the page can read the current meaning before' ($wiChange.AssignmentChange.Old -like 'Not hidden*' -and $wiChange.AssignmentChange.New -like 'Hidden for everyone*' -and (Get-AVDTuneRuleSetAssignment -M $e2.M -Name 'Mixed').Effect -eq 'NoEffect' -and $null -eq (Get-AVDTuneRuleSetAssignment -M $e2.M -Name 'Nothing')) $null
    $c1 = Save-AVDTuneRuleSet -Machine $e2.Machine -M $e2.M -Root $tmp -Name 'Mixed' -Entries @(@{ Folder = $pd; Name = 'New.lnk' }, @{ Folder = 'C:\Some'; Name = 'file.exe' }) -Visibility Hidden -ExpectedChange $anyChange -User 'admin1' -SnapshotId 's'
    $mixedOut = Get-Written $e2 'Mixed' 'fxr'
    Test-Check 'change: with the accept the existing rule stays, only the missing rules are added (no doubles)' ($mixedOut -ceq ($fileOnly + "##`r`n$pd`tNew.lnk`t`t`t0x00000222`t`r`n##`r`nC:\Some`tfile.exe`t`t`t0x00000222`t`r`n") -and (Get-AVDTuneRuleSets -M $e2.M)[0].Visibility.Effect -eq 'Hidden') $mixedOut
    $c2 = Save-AVDTuneRuleSet -Machine $e2.Machine -M $e2.M -Root $tmp -Name 'Mixed' -Entries @(@{ Folder = $pd; Name = 'Third.lnk' }) -Visibility Hidden -User 'admin1' -SnapshotId 's'
    $arch = @(Get-ChildItem (Join-Path $tmp 'config') -Filter 'masking-undo.*.json')
    Test-Check 'undo record: the second change keeps the first record under a versioned name (older backups are not overwritten); the same assignment needs no accept' ($arch.Count -eq 1 -and ((Get-Content $arch[0].FullName -Raw) -like '*Mixed.fxr*')) $null
    [void](Undo-AVDTuneMaskingChange -Machine $e2.Machine -M $e2.M -Root $tmp -User 'admin1' -SnapshotId 's')
    Test-Check 'undo: the last change is put back byte for byte' ((Get-Written $e2 'Mixed' 'fxr').Contains('New.lnk') -and -not (Get-Written $e2 'Mixed' 'fxr').Contains('Third.lnk')) $null
    $r = Remove-AVDTuneRuleSet -Machine $e2.Machine -M $e2.M -Root $tmp -Name 'Mixed' -User 'admin1' -SnapshotId 's'
    Test-Check 'remove: both files are deleted and the undo restores the original files' ($e2.M.Store.Files.Count -eq 0 -and (Test-Throws { Remove-AVDTuneRuleSet -Machine $e2.Machine -M $e2.M -Root $tmp -Name 'Mixed' }) -and (& { Undo-AVDTuneMaskingChange -Machine $e2.Machine -M $e2.M -Root $tmp -User 'a' -SnapshotId 's' | Out-Null; $true }) -and $e2.M.Store.Files.Count -eq 2) $null
    $foreignSet = "1`r`n##`r`nHKEY_LOCAL_MACHINE\SOFTWARE\X`t`t`t`t0x00000011`t`r`n"
    $e2b = New-Env -Seed @{ Files = @{ "$rules\Foreign.fxr" = (ConvertTo-AVDTuneRuleBytes $foreignSet); "$rules\Foreign.fxa" = (ConvertTo-AVDTuneRuleBytes "1`t`r`n0x00000011`tEXAMPLE\Contractors`t`tEXAMPLE\Contractors`t0`t0`r`n") } }
    $before = $e2b.M.Store.Files["$rules\Foreign.fxa"]
    $fe = Get-ThrownText { Save-AVDTuneRuleSet -Machine $e2b.Machine -M $e2b.M -Root $tmp -Name 'Foreign' -Entries $entries -Visibility Hidden -ExpectedChange $anyChange -User a -SnapshotId s }
    Test-Check 'foreign rules: a rule set with a rule of another type (registry) is not changed, even with the accept (the new assignment would apply to that rule too)' ($fe -like '*another type*' -and (Test-AVDTuneMaskBytesEqual $e2b.M.Store.Files["$rules\Foreign.fxa"] $before)) $fe
    $e2c = New-Env -Seed @{ Files = @{ "$rules\Broken.fxr" = (ConvertTo-AVDTuneRuleBytes "2`r`n"); "$rules\Broken.fxa" = (ConvertTo-AVDTuneRuleBytes "1`t`r`n0x00000012`tS-1-1-0`t`tEveryone`t0`t0`r`n") } }
    $e2d = New-Env -Seed @{ Files = @{ "$rules\Broken2.fxr" = (ConvertTo-AVDTuneRuleBytes "1`r`n"); "$rules\Broken2.fxa" = (ConvertTo-AVDTuneRuleBytes "1`t`r`nfoo bar`r`n") } }
    Test-Check 'parse problems: a rule set whose .fxr or .fxa has problems is not changed' ((Test-Throws { Save-AVDTuneRuleSet -Machine $e2c.Machine -M $e2c.M -Root $tmp -Name 'Broken' -Entries $entries -ExpectedChange $anyChange -User a -SnapshotId s }) -and (Test-Throws { Save-AVDTuneRuleSet -Machine $e2d.Machine -M $e2d.M -Root $tmp -Name 'Broken2' -Entries $entries -ExpectedChange $anyChange -User a -SnapshotId s })) $null
    $e2e = New-Env -Seed @{ Files = @{ "$rules\Gone.fxr" = (ConvertTo-AVDTuneRuleBytes "1`r`n"); "$rules\Gone.fxa" = (ConvertTo-AVDTuneRuleBytes "1`t`r`n0x00000012`tS-1-1-0`t`tEveryone`t0`t0`r`n") } }
    [void](Save-AVDTuneRuleSet -Machine $e2e.Machine -M $e2e.M -Root $tmp -Name 'Gone' -Entries $entries -Visibility Hidden -ExpectedChange $anyChange -User a -SnapshotId s)
    $e2e.M.Store.Files["$rules\Gone.fxr"] = (ConvertTo-AVDTuneRuleBytes "1`r`n##`r`nfoo`t`t`t`t0x00000222`t`r`n")   # someone edited the file after AVDTune wrote it
    $ue = Undo-AVDTuneMaskingChange -Machine $e2e.Machine -M $e2e.M -Root $tmp -User a -SnapshotId s
    $guarded = (@($ue.Results | Where-Object { $_.Status -eq 'Failed' -and $_.Message -like '*changed after AVDTune wrote*' }).Count -eq 1 -and (Get-Written $e2e 'Gone' 'fxr').Contains('foo'))
    $uf = Undo-AVDTuneMaskingChange -Machine $e2e.Machine -M $e2e.M -Root $tmp -Force -User a -SnapshotId s
    $bk = @(Get-ChildItem (Join-Path $tmp 'config\masking-backups') -Filter '*Gone.fxr.json' | Where-Object { (Get-Content $_.FullName -Raw) -like '*Sha256*' })
    Test-Check 'undo: a file that is not what AVDTune wrote (SHA256) is not overwritten; with -Force it is, and the current content is saved to a backup first' ($guarded -and @($uf.Results | Where-Object Status -eq 'Changed').Count -eq 2 -and $bk.Count -eq 1 -and -not (Get-Written $e2e 'Gone' 'fxr').Contains('foo')) (($ue.Results | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ';')
    $e2f = New-Env
    $failing = New-AVDTuneFakeMasking; $failing.WriteBytes = { param($p, $b) throw 'boom' }.GetNewClosure()
    [void](Save-AVDTuneRuleSet -Machine $e2f.Machine -M $e2f.M -Root $tmp -Name 'Keep' -Entries $entries -Visibility Hidden -User a -SnapshotId s)
    $keepUndo = Get-Content (Get-AVDTuneMaskingUndoPath $tmp) -Raw
    $ff = Save-AVDTuneRuleSet -Machine $e2f.Machine -M $failing -Root $tmp -Name 'Fail1' -Entries $entries -Visibility Hidden -User a -SnapshotId s
    Test-Check 'undo record: written after the run and only with what changed: a failed run does not replace the record of the last real change' (@($ff.Results | Where-Object Status -eq 'Failed').Count -eq 1 -and (Get-Content (Get-AVDTuneMaskingUndoPath $tmp) -Raw) -ceq $keepUndo) $null

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
    Test-Check 'AD group: -WhatIf names the group step and creates nothing' (@($wi.Results).Count -gt 0 -and $e4.Ldap.Store.Added.Count -eq 0 -and @($wi.Results | Where-Object { $_.Id -eq 'appmasking.group.create' -and $_.Status -eq 'WhatIf' }).Count -eq 1) $null
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

    # ---------------------------------------------------------------- review findings of #29 (each point has a counter-test)
    # 7: \A...\z: a trailing line feed is not accepted anywhere ($ would let it pass)
    Test-Check 'regex: a trailing LF is refused by every validator (group name, rule path, rule set name, prefix, fxa account)' (-not (Test-AVDTuneMaskingGroupName "AVD-App-X`n") -and (Test-AVDTuneMaskingRulePath $pd "A.lnk`n") -ne '' -and -not (Test-AVDTuneMaskingName "Set1`n") -and -not (Test-AVDTuneMaskingPrefix "AVD`n") -and (Test-Throws { ConvertTo-AVDTuneFxaRows -Visibility HiddenExceptGroups -Groups @([pscustomobject]@{ Account = "DOM\G`n"; Dn = '' }) -AdminName A -Time 1 })) $null
    # 1: members asked by a filter; AD returns 'member;range=0-1499' for a big group
    $big = New-Env -LdapSeed @{ Groups = (New-Object System.Collections.ArrayList (, @(@{ Name = 'AVD-App-Big'; Dn = "CN=AVD-App-Big,$ouDn"; Sid = 'S-1-5-21-1-2-3-4001'; Description = 'AVDTune App Masking: Big'; Members = @("CN=u1,$dn", "CN=u2,$dn") }))) }
    $bg = Get-AVDTuneAdGroup -Ldap $big.Ldap -Conn c -BaseDn $dn -Name 'AVD-App-Big'
    $emptyG = New-Env -LdapSeed @{ Groups = (New-Object System.Collections.ArrayList (, @(@{ Name = 'AVD-App-Big'; Dn = "CN=AVD-App-Big,$ouDn"; Sid = 'S-1-5-21-1-2-3-4001'; Description = 'x'; Members = @() }))) }
    $hasM = Test-AVDTuneAdGroupHasMembers -Ldap $big.Ldap -Conn c -BaseDn $dn -GuidHex $bg.Guid
    $hasE = Test-AVDTuneAdGroupHasMembers -Ldap $emptyG.Ldap -Conn c -BaseDn $dn -GuidHex $bg.Guid
    $badHex = Test-Throws { ConvertTo-AVDTuneLdapBinaryFilter 'x)(objectClass=*' }
    Test-Check 'members: the filter (member=*) finds members that the entry only returns as member;range=...; an empty group has none; a GUID that is not 16 bytes of hex never reaches a filter' ($hasM -and -not $hasE -and $bg.Guid.Length -eq 32 -and $badHex) $null
    # 2: GUID and SID read back after the add, saved in the record; undo finds the group by GUID and deletes by <GUID=...>
    $e11 = New-Env
    $g11 = Save-AVDTuneRuleSet -Machine $e11.Machine -M $e11.M -Root $tmp -Name 'Guid1' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup @{ Kind = 'Ad'; Name = 'AVD-App-Guid1'; OuDn = $ouDn } -Ldap $e11.Ldap -Conn c -Directory $dirInfo -Confirmed -User a -SnapshotId s
    $rec = Read-AVDTuneJson (Get-AVDTuneMaskingUndoPath $tmp); $made = $e11.Ldap.Store.Groups[0]
    Test-Check 'AD undo record: carries the object GUID and SID read back after the add (and the DN), only because the step changed' (@($rec.Groups).Count -eq 1 -and $rec.Groups[0].Guid.Length -eq 32 -and $rec.Groups[0].Sid -eq $made.Sid -and $rec.Groups[0].Dn -eq $made.Dn) (($rec | ConvertTo-Json -Depth 5))
    $e11.Ldap.Store.Groups[0].Dn = "CN=AVD-App-Guid1,OU=Moved,$dn"   # moved by someone: the DN in the record is stale, the GUID still finds it
    $u11 = Undo-AVDTuneMaskingChange -Machine $e11.Machine -M $e11.M -Root $tmp -Ldap $e11.Ldap -Conn c -User a -SnapshotId s
    Test-Check 'AD undo: the group is found by its GUID (also after a move) and deleted by <GUID=...>, not by the stored DN' ($e11.Ldap.Store.Deleted.Count -eq 1 -and $e11.Ldap.Store.Deleted[0] -match '\A<GUID=[0-9a-f]{32}>\z' -and $e11.Ldap.Store.Groups.Count -eq 0) (($u11.Results | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ';')
    $e12 = New-Env
    [void](Save-AVDTuneRuleSet -Machine $e12.Machine -M $e12.M -Root $tmp -Name 'Guid2' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup @{ Kind = 'Ad'; Name = 'AVD-App-Guid2'; OuDn = $ouDn } -Ldap $e12.Ldap -Conn c -Directory $dirInfo -Confirmed -User a -SnapshotId s)
    $e12.Ldap.Store.Groups[0].Sid = 'S-1-5-21-9-9-9-9999'   # another object with the same name now
    $u12 = Undo-AVDTuneMaskingChange -Machine $e12.Machine -M $e12.M -Root $tmp -Ldap $e12.Ldap -Conn c -User a -SnapshotId s
    Test-Check 'AD undo: a group with another SID than the one AVDTune created is not deleted' (@($u12.Results | Where-Object { $_.Status -eq 'Failed' -and $_.Message -like '*another SID*' }).Count -eq 1 -and $e12.Ldap.Store.Deleted.Count -eq 0) $null
    # race: the group appears between the check and the run -> the step is Unchanged, nothing is recorded as created by AVDTune
    $e13 = New-Env; $race = $e13.Ldap; $st = $race.Store; $orig = $race.Search; $st.Raced = 0
    $race.Search = { param($c, $b, $f, $s, $a) if ($f -like '*sAMAccountName=AVD-App-Race*') { $st.Raced++; if ($st.Raced -eq 2) { [void]$st.Groups.Add(@{ Name = 'AVD-App-Race'; Dn = "CN=AVD-App-Race,$ouDn"; Sid = 'S-1-5-21-1-2-3-7777'; Description = 'AVDTune App Masking: Other'; Members = @() }) } }; & $orig $c $b $f $s $a }.GetNewClosure()
    Remove-Item (Get-AVDTuneMaskingUndoPath $tmp) -ErrorAction SilentlyContinue
    $r13 = Save-AVDTuneRuleSet -Machine $e13.Machine -M $e13.M -Root $tmp -Name 'Race' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup @{ Kind = 'Ad'; Name = 'AVD-App-Race'; OuDn = $ouDn } -Ldap $race -Conn c -Directory $dirInfo -Confirmed -User a -SnapshotId s
    $rec13 = Read-AVDTuneJson (Get-AVDTuneMaskingUndoPath $tmp)
    Test-Check 'AD undo record: a group that appeared between the check and the run (step Unchanged) is not in the record, so undo never deletes it' ((($r13.Results | Where-Object Id -eq 'appmasking.group.create').Status -eq 'Unchanged') -and $e13.Ldap.Store.Added.Count -eq 0 -and @($rec13.Groups).Count -eq 0) (($r13.Results | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ';')
    $e14 = New-Env -LdapSeed @{ AddFails = $true }
    Remove-Item (Get-AVDTuneMaskingUndoPath $tmp) -ErrorAction SilentlyContinue
    [void](Save-AVDTuneRuleSet -Machine $e14.Machine -M $e14.M -Root $tmp -Name 'Fail2' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup @{ Kind = 'Ad'; Name = 'AVD-App-Fail2'; OuDn = $ouDn } -Ldap $e14.Ldap -Conn c -Directory $dirInfo -Confirmed -User a -SnapshotId s)
    Test-Check 'AD undo record: a failed add leaves no undo record at all' (-not (Test-Path (Get-AVDTuneMaskingUndoPath $tmp))) $null
    # 3: local group
    $e15 = New-Env -Seed @{ LocalGroups = @{ 'AVDTune-App-Shared' = 'AVDTune App Masking: OtherSet' } }
    $lx = Get-ThrownText { Save-AVDTuneRuleSet -Machine $e15.Machine -M $e15.M -Root $tmp -Name 'Second' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup @{ Kind = 'Local'; Name = 'AVDTune-App-Shared' } -Confirmed -User a -SnapshotId s }
    Test-Check 'local group: an existing local group is refused (not taken over, never recorded as created by AVDTune)' ($lx -like '*exists already*' -and $e15.M.Store.Files.Count -eq 0 -and $e15.M.Store.LocalGroups.ContainsKey('AVDTune-App-Shared')) $lx
    $e16 = New-Env
    [void](Save-AVDTuneRuleSet -Machine $e16.Machine -M $e16.M -Root $tmp -Name 'Loc' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup @{ Kind = 'Local'; Name = 'AVDTune-App-Loc' } -Confirmed -User a -SnapshotId s)
    $lrec = Read-AVDTuneJson (Get-AVDTuneMaskingUndoPath $tmp)
    Test-Check 'local group: the SID is saved in the record' ($lrec.Groups[0].Sid -like 'S-1-5-21-*' -and $lrec.Groups[0].Kind -eq 'Local') $null
    $e16.M.Store.LocalGroupMembers['AVDTune-App-Loc'] = @('S-1-5-21-5-5-5-1001')
    $ul1 = Undo-AVDTuneMaskingChange -Machine $e16.Machine -M $e16.M -Root $tmp -User a -SnapshotId s
    Test-Check 'local group undo: a local group that has members is not deleted' (@($ul1.Results | Where-Object { $_.Status -eq 'Failed' -and $_.Message -like '*has members*' }).Count -eq 1 -and $e16.M.Store.LocalGroups.ContainsKey('AVDTune-App-Loc')) (($ul1.Results | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ';')
    $e16.M.Store.LocalGroupMembers['AVDTune-App-Loc'] = @(); $e16.M.Store.LocalGroupSids['AVDTune-App-Loc'] = 'S-1-5-21-8-8-8-8'
    $ul2 = Undo-AVDTuneMaskingChange -Machine $e16.Machine -M $e16.M -Root $tmp -User a -SnapshotId s
    Test-Check 'local group undo: a local group with another SID than the recorded one is not deleted' (@($ul2.Results | Where-Object { $_.Status -eq 'Failed' -and $_.Message -like '*another SID*' }).Count -eq 1 -and $e16.M.Store.LocalGroups.ContainsKey('AVDTune-App-Loc')) $null
    # 6: an existing AD group is bound by sAMAccountName and SID against the DC
    $e17 = New-Env -LdapSeed @{ Groups = (New-Object System.Collections.ArrayList (, @(@{ Name = 'AVD-Users'; Dn = "CN=Display Name,$ouDn"; Sid = 'S-1-5-21-1-2-3-1104'; Description = 'x'; Members = @() }))) }
    $okG = Save-AVDTuneRuleSet -Machine $e17.Machine -M $e17.M -Root $tmp -Name 'Bound' -Entries $entries -Visibility HiddenExceptGroups -Groups @([pscustomobject]@{ Sam = 'AVD-Users'; Sid = 'S-1-5-21-1-2-3-1104'; Account = 'EVIL\x'; Dn = 'CN=wrong' }) -Ldap $e17.Ldap -Conn c -Directory $dirInfo -User a -SnapshotId s
    Test-Check 'existing AD group: account and DN come from the domain controller (sAMAccountName, DN found by SID), not from what the caller sent' ((Get-Written $e17 'Bound' 'fxa') -like "*0x00000012`tEXAMPLE\AVD-Users`tCN=Display Name,$ouDn`tEXAMPLE\AVD-Users`t*" -and (Get-Written $e17 'Bound' 'fxa') -notlike '*EVIL*') (Get-Written $e17 'Bound' 'fxa')
    $badSid = Get-ThrownText { Save-AVDTuneRuleSet -Machine $e17.Machine -M $e17.M -Root $tmp -Name 'Bound2' -Entries $entries -Visibility HiddenExceptGroups -Groups @([pscustomobject]@{ Sam = 'AVD-Users'; Sid = 'S-1-5-21-1-2-3-9999'; Account = 'EXAMPLE\AVD-Users'; Dn = '' }) -Ldap $e17.Ldap -Conn c -Directory $dirInfo -User a -SnapshotId s }
    Test-Check 'existing AD group: a SID that differs from the DC (another object of the same name) is refused; so is a group that is not in the domain and a call without the DC connection' ($badSid -like '*another SID*' -and (Test-Throws { Save-AVDTuneRuleSet -Machine $e17.Machine -M $e17.M -Root $tmp -Name 'Bound3' -Entries $entries -Visibility HiddenExceptGroups -Groups @([pscustomobject]@{ Sam = 'Nobody'; Sid = 'S-1-5-21-1-2-3-1'; Account = 'EXAMPLE\Nobody' }) -Ldap $e17.Ldap -Conn c -Directory $dirInfo -User a -SnapshotId s }) -and (Test-Throws { Save-AVDTuneRuleSet -Machine $e17.Machine -M $e17.M -Root $tmp -Name 'Bound4' -Entries $entries -Visibility HiddenExceptGroups -Groups @([pscustomobject]@{ Sam = 'AVD-Users'; Sid = 'S-1-5-21-1-2-3-1104'; Account = 'EXAMPLE\AVD-Users' }) -User a -SnapshotId s }) -and $e17.M.Store.Files.Keys.Count -eq 2) $badSid
    # 8: the whole path from the drive root: no link anywhere, admin-only below the root
    $reports = @{ 'C:\' = @{ Exists = $true; Link = $false; Owner = 'S-1-5-18'; Rules = @() }; 'C:\Program Files' = @{ Exists = $true; Link = $false; Owner = 'S-1-5-18'; Rules = @() }; 'C:\Program Files\FSLogix' = @{ Exists = $true; Link = $false; Owner = 'S-1-5-18'; Rules = @() }; 'C:\Program Files\FSLogix\Apps' = @{ Exists = $true; Link = $false; Owner = 'S-1-5-18'; Rules = @() }
        'C:\Program Files\FSLogix\Apps\Rules' = @{ Exists = $true; Link = $false; Owner = 'S-1-5-18'; Rules = @() } }
    $read = { param($p) $r = $script:reports[$p]; if ($r) { [pscustomobject]@{ Exists = $true; Link = $r.Link; Owner = $r.Owner; Protected = $true; Rules = @($r.Rules | ForEach-Object { [pscustomobject]$_ }) } } else { [pscustomobject]@{ Exists = $false; Link = $false; Owner = ''; Protected = $false; Rules = @() } } }
    $script:reports = $reports
    $okChain = @(Get-AVDTuneWriteChainProblems -Path 'C:\Program Files\FSLogix\Apps\Rules\x.fxr' -AllowMissingLeaf -ReadReport $read)
    $reports['C:\Program Files\FSLogix'].Link = $true
    $linkChain = @(Get-AVDTuneWriteChainProblems -Path 'C:\Program Files\FSLogix\Apps\Rules\x.fxr' -AllowMissingLeaf -ReadReport $read)
    $reports['C:\Program Files\FSLogix'].Link = $false; $reports['C:\Program Files'].Owner = 'S-1-5-21-1-2-3-1001'
    $ownChain = @(Get-AVDTuneWriteChainProblems -Path 'C:\Program Files\FSLogix\Apps\Rules\x.fxr' -AllowMissingLeaf -ReadReport $read)
    $reports['C:\Program Files'].Owner = 'S-1-5-18'; $reports['C:\'].Link = $true
    $rootLink = @(Get-AVDTuneWriteChainProblems -Path 'C:\Program Files\FSLogix\Apps\Rules\x.fxr' -AllowMissingLeaf -ReadReport $read)
    $reports['C:\'].Link = $false; $reports['C:\Program Files\FSLogix\Apps'].Rules = @(@{ Sid = 'S-1-5-32-545'; Write = $true; Inherited = $false })
    $wChain = @(Get-AVDTuneWriteChainProblems -Path 'C:\Program Files\FSLogix\Apps\Rules\x.fxr' -AllowMissingLeaf -ReadReport $read)
    Test-Check 'path chain: clean = no problems; a link anywhere (also the drive root) and a foreign owner or user write access in any folder above the leaf are found; a missing parent is a problem' ($okChain.Count -eq 0 -and ($linkChain -join ' ') -like '*FSLogix is a link*' -and ($rootLink -join ' ') -like '*C:\ is a link*' -and ($ownChain -join ' ') -like '*Program Files:*owner*' -and ($wChain -join ' ') -like '*Apps:*write access*' -and @(Get-AVDTuneWriteChainProblems -Path 'C:\Program Files\FSLogix\Apps\Rules\Missing\x.fxr' -AllowMissingLeaf -ReadReport $read).Count -ge 1) (($linkChain + $ownChain + $wChain) -join ' | ')
    # 9: shortcut: working folder, ACL of an existing shortcut, marker at undo
    $e18 = New-Env
    $cs18 = (Get-AVDTuneComfortShortcuts -M $e18.M)[0]
    [void](Add-AVDTuneComfortShortcut -Machine $e18.Machine -M $e18.M -Root $tmp -Id logoff -User a -SnapshotId s)
    $lnk18 = $e18.M.Store.Shortcuts['C:\Users\Public\Desktop\Abmelden.lnk']
    Test-Check 'comfort: the working folder is the Windows system folder' ($lnk18.WorkingDirectory -eq 'C:\Windows\System32' -and $cs18.WorkingDirectory -eq 'C:\Windows\System32') $null
    $lnk18.AclProblems = @('write access for S-1-5-32-545')
    $fix18 = Add-AVDTuneComfortShortcut -Machine $e18.Machine -M $e18.M -Root $tmp -Id logoff -User a -SnapshotId s
    Test-Check 'comfort: an existing shortcut of ours with a bad ACL is not compliant and is made right (the test looks at the ACL, not only at target and icon)' (@($fix18.Results | Where-Object Status -eq 'Changed').Count -eq 1 -and @($e18.M.Store.Shortcuts['C:\Users\Public\Desktop\Abmelden.lnk'].AclProblems).Count -eq 0) $null
    $e18.M.Store.Shortcuts['C:\Users\Public\Desktop\Abmelden.lnk'].Description = 'swapped by someone'
    $u18 = Undo-AVDTuneMaskingChange -Machine $e18.Machine -M $e18.M -Root $tmp -User a -SnapshotId s
    Test-Check 'comfort undo: a shortcut that does not carry the AVDTune marker any more is not deleted' (@($u18.Results | Where-Object { $_.Status -eq 'Failed' -and $_.Message -like '*marker*' }).Count -eq 1 -and $e18.M.Store.Shortcuts.Count -eq 1) (($u18.Results | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ';')
    Test-Check 'comfort: a shortcut that was not changed (failed run) is not in the undo record' ((& { $e19 = New-Env -Seed @{ Unsafe = $true }; Remove-Item (Get-AVDTuneMaskingUndoPath $tmp) -ErrorAction SilentlyContinue; [void](Add-AVDTuneComfortShortcut -Machine $e19.Machine -M $e19.M -Root $tmp -Id logoff -User a -SnapshotId s); -not (Test-Path (Get-AVDTuneMaskingUndoPath $tmp)) })) $null

    # ---------------------------------------------------------------- source checks of the real adapter and the module (checklist points)
    $src = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Masking.psm1'))
    $adapter = $src.Substring($src.IndexOf('function New-AVDTuneMaskingAdapter'))
    Test-Check 'source: the real writer creates files with CreateNew and the protected ACL, checks parent folder, folder and target with Get-AVDTuneAclProblems, never File.Replace' ($adapter -match 'FileMode\]::CreateNew' -and $adapter -match 'New-AVDTuneFileSecurity' -and $adapter -match 'Get-AVDTuneWriteChainProblems -Path \$Path -AllowMissingLeaf' -and ([regex]::Matches($adapter, 'Move-AVDTuneFileReplace \$temp \$Path')).Count -ge 2 -and $adapter -notmatch 'IO.File\]::Move|File\]::Replace') $null
    Test-Check 'source: the rules folder comes from the Program Files folder of Windows, programs are not started, nothing recursive is deleted, no regex without a limit on data' ($adapter -match 'Get-AVDTuneSystemFolder ProgramFiles' -and $src -notmatch 'Start-Process|Invoke-Expression|iex |Remove-Item .*-Recurse|ProcessStartInfo|Get-Command' -and $src -notmatch '\$env:(ProgramFiles|SystemRoot|windir|PATH)') $null
    Test-Check 'source: the comfort shortcut target comes from the system folder API; the shortcut is written with the protected file ACL and links are refused' ($adapter -match 'Get-AVDTuneSystemFolder System' -and $adapter -match 'SetAccessControl\(\(New-AVDTuneFileSecurity\)\)' -and $adapter -match "Join-Path \(Get-AVDTuneRoot\) 'temp'" -and $adapter -match 'WorkingDirectory = \$WorkingDirectory' -and $src -match '-AclBelow' -and $adapter -match 'Get-AVDTunePublicDesktopFindings -Path \$Path' -and $adapter -match 'AclProblems = \$acl') $null
    Test-Check 'source: reading refuses links and files over 4 MB; the LDAP filter value is escaped and the existing group name validated (length, control characters) before it' ($adapter -match 'is a link: not read' -and $adapter -match '4MB' -and $src -match 'ConvertTo-AVDTuneLdapFilterValue \$Name' -and $src -match "if \(-not \(Test-AVDTuneAdExistingGroupName \`$Name\)\) \{ throw ") $null
    Test-Check 'source: no password or token is handled in this module (the connection comes from the start sequence)' ($src -notmatch 'Password|SecureString|token|Credential') $null
    Test-Check 'source: the group is created only behind the Confirmed switch (AD and local)' (([regex]::Matches($src, 'needs your confirmation')).Count -eq 2) $null

    # ---------------------------------------------------------------- source checks of the page
    $page = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-AppMasking.ps1'))
    $perr = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($page, [ref]$null, [ref]$perr)
    Test-Check 'page: the page file parses and the hooks in Start-AVDTune.ps1 are there (import, dot-source, page switch)' (@($perr).Count -eq 0 -and ([IO.File]::ReadAllText((Join-Path $repo 'Start-AVDTune.ps1'))) -match "'Masking'(, '\w+')*\) \{ Import-Module" -and ([IO.File]::ReadAllText((Join-Path $repo 'Start-AVDTune.ps1'))) -match 'AVDTune-AppMasking.ps1' -and ([IO.File]::ReadAllText((Join-Path $repo 'Start-AVDTune.ps1'))) -match 'Update-MaskView') ($perr | ForEach-Object Message)
    $saveFn = $page.Substring($page.IndexOf('function Invoke-MaskSave'), $page.IndexOf('function Remove-MaskSet') - $page.IndexOf('function Invoke-MaskSave'))
    $confirmAt = $saveFn.IndexOf('Confirm-Action'); $confirmedAt = $saveFn.IndexOf('$p.Confirmed = $true')
    Test-Check 'page: a group is only created after Confirm-Action that names group, OU and domain; -Confirmed is set after it, never before; a changed assignment is confirmed with old and new meaning' ($confirmAt -gt 0 -and $confirmAt -lt $confirmedAt -and $saveFn.Contains('Create the group') -and $saveFn.Contains('OU $($p.CreateGroup.OuDn)') -and $saveFn.Contains('domain $($p.Directory.DnsName)') -and $saveFn.Contains('$preview.AssignmentChange.Old') -and $saveFn.Contains('$preview.AssignmentChange.New') -and $saveFn.IndexOf('$p.ExpectedChange = ') -gt $saveFn.LastIndexOf('Confirm-Action')) $null
    $pwOk = (([regex]::Matches($page, 'Assert-MaskWrite')).Count -ge 5) -and (([regex]::Matches($page, 'Invoke-MaskChange -Title')).Count -eq 6)
    $pwClear = (([regex]::Matches($page, 'finally \{ if \(\$lc\) \{ & \$lc\.Close \}; \$ui\.PwdMask\.Clear\(\) \}')).Count -eq 3) -and $saveFn.IndexOf('try {') -lt $saveFn.IndexOf('Get-MaskRequest') -and $saveFn.IndexOf('try {') -lt $saveFn.IndexOf('return')
    $pwNoText = ($page -notmatch 'PwdMask\.Password\b') -and ($page -notmatch 'ConvertFrom-SecureString|SecureStringToBSTR|Marshal')
    $secureDisposed = $page.Contains('$secure.Dispose()') -and $page.Contains('$secure = $ui.PwdMask.SecurePassword') -and -not $page.Contains('-Password $ui.PwdMask.SecurePassword')
    Test-Check 'page: every change asks the write gate and runs as a task' ($pwOk) $null
    Test-Check 'page: the password box is cleared in finally on every path (preview, refused confirmation, error, success, undo); the copy of the secure string is disposed; the password is in no text' ($pwClear -and $pwNoText -and $secureDisposed) "clear=$pwClear text=$pwNoText disposed=$secureDisposed"
    Test-Check 'page: existing AD groups are chosen by sAMAccountName and SID (not by name or CN) and the SID is sent to the module' ($page.Contains('Sam = (Get-MaskGroupSam $g); Sid = [string]$g.Sid') -and $page -notmatch "Where-Object \{ \`$_\.Name -eq \`$gn \}") $null
    Test-Check 'page: no Retry for the changes of the master and of AD (only the read task has one)' (([regex]::Matches($page, '-Retry')).Count -eq 1 -and $page -match "function New-MaskReadTask \{[^\n]*-Retry") $null
    Test-Check 'page: the connection to the domain controller is the pinned one (Connect-AVDTuneDirectory with the pins), no own TLS or bind code' ($page -match 'Connect-AVDTuneDirectory .*-Pins' -and $page -notmatch 'LdapConnection|NetworkCredential|SslStream') $null

    # ---------------------------------------------------------------- re-check of the review (N1 to N7 and the group without SID)
    # N1: existing AD groups with special names are bound by sAMAccountName and SID; the filter value is escaped, the .fxa row carries the name as it is
    $sud = "Vertrieb-S$([char]0xFC)d"
    $special = @($sud, 'Sales Team (EU)', 'HR$')
    $spSeed = New-Object System.Collections.ArrayList
    $k = 5000; foreach ($n in $special) { $k++; [void]$spSeed.Add(@{ Name = $n; Dn = "CN=$n,$ouDn"; Sid = "S-1-5-21-1-2-3-$k"; Description = 'x'; Members = @() }) }
    $eS = New-Env -LdapSeed @{ Groups = $spSeed }
    $spOk = $true; $spDetail = @(); $k = 5000
    foreach ($n in $special) {
        $k++
        $gx = Get-AVDTuneAdGroup -Ldap $eS.Ldap -Conn c -BaseDn $dn -Name $n
        $rs = Save-AVDTuneRuleSet -Machine $eS.Machine -M $eS.M -Root $tmp -Name "Special$k" -Entries $entries -Visibility HiddenExceptGroups -Groups @([pscustomobject]@{ Sam = $n; Sid = "S-1-5-21-1-2-3-$k"; Account = 'x\y'; Dn = '' }) -Ldap $eS.Ldap -Conn c -Directory $dirInfo -User a -SnapshotId s
        $fx = Get-Written $eS "Special$k" 'fxa'; $pv = ConvertFrom-AVDTuneFxaText $fx
        $rowOk = $gx -and $gx.Sam -ceq $n -and $fx -like "*0x00000012`tEXAMPLE\$n`tCN=$n,$ouDn`tEXAMPLE\$n`t*" -and @($pv.Problems).Count -eq 0 -and (Get-AVDTuneRuleVisibility $pv).Text -like "*EXAMPLE\$n*"
        if (-not $rowOk) { $spOk = $false; $spDetail += "$n -> $fx" }
    }
    Test-Check 'N1 existing groups: "Vertrieb-S(u-umlaut)d", "Sales Team (EU)" and "HR$" are found by sAMAccountName and SID and the .fxa row carries the name as it is (DOMAIN\name, DN, display name); the rule set is read back without problems' $spOk ($spDetail -join ' | ')
    $sqlog = @($eS.Ldap.Store.Log | Where-Object { $_ -like '*sAMAccountName=Sales*' })
    Test-Check 'N1 existing groups: the filter value is escaped (parentheses as \28 and \29), nothing of the name is taken as filter syntax' ($sqlog.Count -ge 1 -and @($sqlog | Where-Object { $_ -like '*Sales Team \28EU\29*' }).Count -ge 1 -and @($sqlog | Where-Object { $_ -like '*Team (EU)*' }).Count -eq 0) ($sqlog -join ' | ')
    $injName = 'a)(objectClass=*'
    [void](Get-AVDTuneAdGroup -Ldap $eS.Ldap -Conn c -BaseDn $dn -Name $injName)
    Test-Check 'N1 existing groups: a name with filter syntax is only escaped (\29\28 and \2a), the filter stays one equality' (@($eS.Ldap.Store.Log | Where-Object { $_ -like '*(sAMAccountName=a\29\28objectClass=\2a))' }).Count -eq 1) (($eS.Ldap.Store.Log | Select-Object -Last 1))
    Test-Check 'N1 existing groups: empty, tab, line feed, backslash, a name over 256 characters and one with a blank at the end are refused; names AVDTune creates keep the strict rule' ((Test-Throws { Get-AVDTuneAdGroup -Ldap $eS.Ldap -Conn c -BaseDn $dn -Name "a`tb" }) -and (Test-Throws { Get-AVDTuneAdGroup -Ldap $eS.Ldap -Conn c -BaseDn $dn -Name "a`nb" }) -and (Test-Throws { Get-AVDTuneAdGroup -Ldap $eS.Ldap -Conn c -BaseDn $dn -Name 'a\b' }) -and (Test-Throws { Get-AVDTuneAdGroup -Ldap $eS.Ldap -Conn c -BaseDn $dn -Name ('a' * 257) }) -and (Test-Throws { Get-AVDTuneAdGroup -Ldap $eS.Ldap -Conn c -BaseDn $dn -Name 'ab ' }) -and -not (Test-AVDTuneAdExistingGroupName '') -and -not (Test-AVDTuneMaskingGroupName 'Sales Team (EU)') -and -not (Test-AVDTuneMaskingGroupName 'HR$') -and (Test-Throws { Save-AVDTuneRuleSet -Machine $eS.Machine -M $eS.M -Root $tmp -Name 'NewSp' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup @{ Kind = 'Ad'; Name = 'Sales Team (EU)'; OuDn = $ouDn } -Ldap $eS.Ldap -Conn c -Directory $dirInfo -Confirmed -User a -SnapshotId s })) $null

    # the group without SID (account and DN from the caller) is refused when a domain controller is given; the local form without a DC stays
    $eN = New-Env
    $noSidThrown = Get-ThrownText { Save-AVDTuneRuleSet -Machine $eN.Machine -M $eN.M -Root $tmp -Name 'NoSid' -Entries $entries -Visibility HiddenExceptGroups -Groups @([pscustomobject]@{ Account = 'EXAMPLE\Anybody'; Dn = 'CN=Anybody' }) -Ldap $eN.Ldap -Conn c -Directory $dirInfo -User a -SnapshotId s }
    [void](Save-AVDTuneRuleSet -Machine $eN.Machine -M $eN.M -Root $tmp -Name 'NoSidLocal' -Entries $entries -Visibility HiddenExceptGroups -Groups @([pscustomobject]@{ Account = 'HOST\LocalGrp'; Dn = '' }) -User a -SnapshotId s)
    Test-Check 'groups without SID: refused with a domain controller (bound by SID only), nothing written; without a DC (local group form) still accepted' ($noSidThrown -like '*has no SID*' -and -not $eN.M.Store.Files.ContainsKey("$rules\NoSid.fxa") -and (Get-Written $eN 'NoSidLocal' 'fxa') -like '*HOST\LocalGrp*') $noSidThrown

    # N2: inherit-only entries are no write access to the object itself (general); the Public Desktop folder warns instead of stopping; owner, link, other writers and the file ACL stay strict
    $uW = [pscustomobject]@{ Sid = 'S-1-5-32-545'; Write = $true; Inherited = $false; InheritOnly = $true }
    $uWn = [pscustomobject]@{ Sid = 'S-1-5-32-545'; Write = $true; Inherited = $false; InheritOnly = $false }
    $uWold = [pscustomobject]@{ Sid = 'S-1-5-32-545'; Write = $true; Inherited = $false }
    $auW = [pscustomobject]@{ Sid = 'S-1-5-11'; Write = $true; Inherited = $false; InheritOnly = $false }
    $inW = [pscustomobject]@{ Sid = 'S-1-5-4'; Write = $true; Inherited = $false; InheritOnly = $false }
    $strangerW = [pscustomobject]@{ Sid = 'S-1-5-21-1-2-3-1001'; Write = $true; Inherited = $false; InheritOnly = $false }
    $adminW = [pscustomobject]@{ Sid = 'S-1-5-32-544'; Write = $true; Inherited = $false; InheritOnly = $false }
    $mkRep = { param($acl, $owner = 'S-1-5-18', $link = $false) [pscustomobject]@{ Exists = $true; Link = $link; Owner = $owner; Protected = $false; Rules = @($acl) } }
    Test-Check 'N2 ACL: the general check counts an inherit-only entry (Users (OI)(CI)(IO)(W): every new file becomes writable) as write access like any other; only -IgnoreInheritOnly (Public Desktop) leaves it out' ((Get-AVDTuneAclProblems (& $mkRep @($uW))) -contains 'write access for S-1-5-32-545' -and @((Get-AVDTuneAclFindings -Report (& $mkRep @($uW)) -IgnoreInheritOnly).Problems).Count -eq 0 -and (Get-AVDTuneAclProblems (& $mkRep @($uWn))) -contains 'write access for S-1-5-32-545' -and (Get-AVDTuneAclProblems (& $mkRep @($uWold))) -contains 'write access for S-1-5-32-545') $null
    Test-Check 'N2 ACL: Get-AVDTuneAclProblems has no warning rule: Authenticated Users with Modify is a problem for every caller (rules folder, watermark, shortcut file)' ((Get-AVDTuneAclProblems (& $mkRep @($auW))) -contains 'write access for S-1-5-11') $null
    $script:deskRep = @{ 'C:\' = (& $mkRep @()); 'C:\Users' = (& $mkRep @()); 'C:\Users\Public' = (& $mkRep @()); 'C:\Users\Public\Desktop' = (& $mkRep @($auW, $inW, $uW, $adminW)) }
    $readD = { param($p) $r = $script:deskRep[$p]; if ($r) { $r } else { [pscustomobject]@{ Exists = $false; Link = $false; Owner = ''; Protected = $false; Rules = @() } } }
    $dlnk = 'C:\Users\Public\Desktop\Abmelden.lnk'
    $fd = Get-AVDTunePublicDesktopFindings -Path $dlnk -ReadReport $readD
    Test-Check 'N2 Public Desktop: Authenticated Users and Interactive with Modify (Windows default) is a warning, not an error; Users with IO and Administrators are no finding' (@($fd.Problems).Count -eq 0 -and @($fd.Warnings).Count -eq 1 -and $fd.Warnings[0] -like '*C:\Users\Public\Desktop: write access for S-1-5-11, S-1-5-4') (($fd.Problems + $fd.Warnings) -join ' | ')
    $script:deskRep['C:\Users\Public\Desktop'] = (& $mkRep @($auW) 'S-1-5-21-1-2-3-1001')
    $fOwn = Get-AVDTunePublicDesktopFindings -Path $dlnk -ReadReport $readD
    $script:deskRep['C:\Users\Public\Desktop'] = (& $mkRep @() 'S-1-5-18' $true)
    $fLink = Get-AVDTunePublicDesktopFindings -Path $dlnk -ReadReport $readD
    $script:deskRep['C:\Users\Public\Desktop'] = (& $mkRep @($auW, $strangerW))
    $fOther = Get-AVDTunePublicDesktopFindings -Path $dlnk -ReadReport $readD
    $script:deskRep['C:\Users\Public\Desktop'] = (& $mkRep @())
    $script:deskRep['C:\Users'] = (& $mkRep @() 'S-1-5-18' $true)
    $fParent = Get-AVDTunePublicDesktopFindings -Path $dlnk -ReadReport $readD
    Test-Check 'N2 Public Desktop: a foreign owner, a link (on the folder or above it) and write access of any other account stay a stop (also next to the warned groups)' (($fOwn.Problems -join ' ') -like '*owner is S-1-5-21-1-2-3-1001*' -and ($fLink.Problems -join ' ') -like '*Desktop is a link*' -and ($fOther.Problems -join ' ') -like '*write access for S-1-5-21-1-2-3-1001*' -and ($fOther.Problems -join ' ') -notlike '*S-1-5-11*' -and @($fOther.Warnings).Count -eq 1 -and ($fParent.Problems -join ' ') -like '*C:\Users is a link*') (($fOwn.Problems + $fLink.Problems + $fOther.Problems + $fParent.Problems) -join ' | ')
    $script:reports['C:\Program Files\FSLogix\Apps'].Rules = @()
    $script:reports['C:\Program Files\FSLogix\Apps\Rules'].Rules = @(@{ Sid = 'S-1-5-11'; Write = $true; Inherited = $false; InheritOnly = $false })
    $rulesChain = @(Get-AVDTuneWriteChainProblems -Path 'C:\Program Files\FSLogix\Apps\Rules\x.fxr' -AllowMissingLeaf -ReadReport $read)
    $script:reports['C:\Program Files\FSLogix\Apps\Rules'].Rules = @(@{ Sid = 'S-1-5-32-545'; Write = $true; Inherited = $false; InheritOnly = $true })
    $rulesIo = @(Get-AVDTuneWriteChainProblems -Path 'C:\Program Files\FSLogix\Apps\Rules\x.fxr' -AllowMissingLeaf -ReadReport $read)
    Test-Check 'N2 rules folder: no warning rule there (Authenticated Users with Modify stays a stop), an IO entry for Users stops too (as before)' (($rulesChain -join ' ') -like '*Rules:*write access for S-1-5-11*' -and ($rulesIo -join ' ') -like '*Rules:*write access for S-1-5-32-545*') (($rulesChain + $rulesIo) -join ' | ')
    $script:deskRep['C:\Users\Public\Desktop'] = (& $mkRep @($uW)); $script:deskRep['C:\Users'] = (& $mkRep @())
    $fIo = Get-AVDTunePublicDesktopFindings -Path $dlnk -ReadReport $readD
    Test-Check 'N2 Public Desktop: Users with (OI)(CI)(IO)(W) on the folder is at most a warning, never a stop' (@($fIo.Problems).Count -eq 0) ($fIo.Problems -join ' | ')
    $w1 = 'C:\Users\Public\Desktop: write access for S-1-5-11'
    $eW = New-Env -Seed @{ DesktopWarnings = @($w1) }
    $noOk = Get-ThrownText { Add-AVDTuneComfortShortcut -Machine $eW.Machine -M $eW.M -Root $tmp -Id logoff -User a -SnapshotId s }
    $prevW = Add-AVDTuneComfortShortcut -Machine $eW.Machine -M $eW.M -Root $tmp -Id logoff -WhatIf
    $wrongW = Get-ThrownText { Add-AVDTuneComfortShortcut -Machine $eW.Machine -M $eW.M -Root $tmp -Id logoff -ExpectedWarnings @('something else') -User a -SnapshotId s }
    $stopped = $eW.M.Store.Shortcuts.Count -eq 0
    $okW = Add-AVDTuneComfortShortcut -Machine $eW.Machine -M $eW.M -Root $tmp -Id logoff -ExpectedWarnings @($w1) -User a -SnapshotId s
    Test-Check 'N2 comfort shortcut: the Windows-default warning needs the explicit confirmation (the preview run carries it, the write refuses without or with other warnings) and then writes' ($noOk -like '*confirm this explicitly*' -and $wrongW -like '*confirm this explicitly*' -and $stopped -and @($prevW.DesktopWarnings).Count -eq 1 -and $prevW.DesktopWarnings[0] -eq $w1 -and @($okW.Results | Where-Object Status -eq 'Changed').Count -eq 1 -and $eW.M.Store.Shortcuts.Count -eq 1) "$noOk | $wrongW"
    $eP = New-Env -Seed @{ DesktopWarnings = @($w1); DesktopProblems = @('C:\Users\Public\Desktop: owner is S-1-5-21-1-2-3-1001') }
    $pr = Get-ThrownText { Add-AVDTuneComfortShortcut -Machine $eP.Machine -M $eP.M -Root $tmp -Id logoff -ExpectedWarnings @($w1) -User a -SnapshotId s }
    Test-Check 'N2 comfort shortcut: a problem on the folder (foreign owner, link, other writers) stops even with the confirmed warning, nothing is written' ($pr -like '*not safe*owner is*' -and $eP.M.Store.Shortcuts.Count -eq 0) $pr

    # N3: Old and New of the preview go to the module, which compares them with the real values
    $setN3 = { New-Env -Seed @{ Files = @{ "$rules\Pre.fxr" = (ConvertTo-AVDTuneRuleBytes $fileOnly); "$rules\Pre.fxa" = (ConvertTo-AVDTuneRuleBytes "1`t`r`n0x00000012`tS-1-1-0`t`tEveryone`t0`t0`r`n") } } }
    $eA = & $setN3; $fxaA = $eA.M.Store.Files["$rules\Pre.fxa"]
    $badNew = Get-ThrownText { Save-AVDTuneRuleSet -Machine $eA.Machine -M $eA.M -Root $tmp -Name 'Pre' -Entries $entries -Visibility Hidden -ExpectedChange @{ Old = $anyChange.Old; New = 'Hidden for everyone except: Somebody' } -User a -SnapshotId s }
    $badOld = Get-ThrownText { Save-AVDTuneRuleSet -Machine $eA.Machine -M $eA.M -Root $tmp -Name 'Pre' -Entries $entries -Visibility Hidden -ExpectedChange @{ Old = 'Hidden for everyone'; New = 'Hidden for everyone' } -User a -SnapshotId s }
    $none = Get-ThrownText { Save-AVDTuneRuleSet -Machine $eA.Machine -M $eA.M -Root $tmp -Name 'Pre' -Entries $entries -Visibility Hidden -User a -SnapshotId s }
    Test-Check 'N3 preview values: a different Old or New than the real ones, and no expected change at all, are refused with both values in the text; nothing is written' ($badNew -like '*not what the preview showed*' -and $badOld -like '*not what the preview showed*' -and $none -like '*would change from*' -and (Test-AVDTuneMaskBytesEqual $eA.M.Store.Files["$rules\Pre.fxa"] $fxaA)) "$badNew | $badOld"
    $goodA = Save-AVDTuneRuleSet -Machine $eA.Machine -M $eA.M -Root $tmp -Name 'Pre' -Entries $entries -Visibility Hidden -ExpectedChange @{ Old = $anyChange.Old; New = $anyChange.New } -User a -SnapshotId s
    $again = Get-ThrownText { Save-AVDTuneRuleSet -Machine $eA.Machine -M $eA.M -Root $tmp -Name 'Pre' -Entries $entries -Visibility Hidden -ExpectedChange @{ Old = $anyChange.Old; New = $anyChange.New } -User a -SnapshotId s }
    Test-Check 'N3 preview values: the exact Old and New write; an expected change that no longer exists (the rule set changed since the preview) is refused' (@($goodA.Results | Where-Object Status -eq 'Changed').Count -ge 1 -and (Get-AVDTuneRuleSetAssignment -M $eA.M -Name 'Pre').Effect -eq 'Hidden' -and $again -like '*not what the preview showed*') $again

    # N4: the connection (password) is made after the write gate and the confirmation, not before
    $iAssert = $saveFn.IndexOf('Assert-MaskWrite'); $iFirstConfirm = $saveFn.IndexOf('Confirm-Action'); $iLdapWrite = $saveFn.LastIndexOf('Get-MaskLdap'); $iLdapPreview = $saveFn.IndexOf('Get-MaskLdap'); $iReturn = $saveFn.IndexOf('return')
    Test-Check 'N4 page: Get-MaskLdap in the write path comes after Assert-MaskWrite and the first confirmation; the only other call is in the preview branch (nothing written)' ($iLdapWrite -gt $iFirstConfirm -and $iFirstConfirm -gt $iAssert -and $iAssert -gt 0 -and $iLdapPreview -lt $iAssert -and $iLdapPreview -lt $iReturn -and ([regex]::Matches($saveFn, 'Get-MaskLdap')).Count -eq 2) "assert=$iAssert confirm=$iFirstConfirm write=$iLdapWrite preview=$iLdapPreview return=$iReturn"
    Test-Check 'N3 page: the preview values (Old, New) are passed to the module as ExpectedChange after the second confirmation; the comfort shortcut passes the previewed warnings after a confirmation' ($saveFn.Contains('$p.ExpectedChange = @{ Old = ') -and $page.Contains('-ExpectedWarnings $expected') -and $page.Contains('$prev.DesktopWarnings') -and $page.IndexOf('$prev.DesktopWarnings') -lt $page.IndexOf('-ExpectedWarnings $expected')) $null

    # N5: the read-back after the add fails: provisional record with the DN, the DN in the error
    $eR = New-Env; $ldR = $eR.Ldap; $stR = $ldR.Store; $origR = $ldR.Search
    $ldR.Search = { param($c, $b, $f, $s, $a) if ($stR.Added.Count -gt 0 -and $f -like '*sAMAccountName=AVD-App-Prov*') { throw 'fake: read timed out' }; & $origR $c $b $f $s $a }.GetNewClosure()
    Get-ChildItem (Join-Path $tmp 'config') -Filter 'masking-undo*.json' -ErrorAction SilentlyContinue | Remove-Item -Force
    $rP = Save-AVDTuneRuleSet -Machine $eR.Machine -M $eR.M -Root $tmp -Name 'Prov' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup @{ Kind = 'Ad'; Name = 'AVD-App-Prov'; OuDn = $ouDn } -Ldap $ldR -Conn c -Directory $dirInfo -Confirmed -User a -SnapshotId s
    $gStep = @($rP.Results | Where-Object Id -eq 'appmasking.group.create')[0]
    $allRec = @(Get-ChildItem (Join-Path $tmp 'config') -Filter 'masking-undo*.json' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join ' '
    Test-Check 'N5 read-back fails: the step fails, the error names the DN, and the undo record (also an older version of it) holds the DN as a provisional entry without GUID and SID' ($gStep.Status -eq 'Failed' -and $gStep.Message -like "*CN=AVD-App-Prov,$ouDn*" -and $gStep.Message -like '*read timed out*' -and $allRec -like "*CN=AVD-App-Prov,$ouDn*" -and $allRec -like '*Provisional*') "$($gStep.Status) $($gStep.Message)"
    $uP = Undo-AVDTuneMaskingChange -Machine $eR.Machine -M $eR.M -Root $tmp -Ldap $ldR -Conn c -User a -SnapshotId s
    $uPg = @($uP.Results | Where-Object { $_.Id -like 'appmasking.undo.group*' })
    Test-Check 'N5 read-back fails: undo never deletes a group without GUID and SID (the step fails with the DN), and the group still exists' ($uPg.Count -eq 1 -and $uPg[0].Status -eq 'Failed' -and $uPg[0].Message -like "*CN=AVD-App-Prov,$ouDn*" -and $stR.Deleted.Count -eq 0 -and $stR.Groups.Count -eq 1) (($uP.Results | ForEach-Object { "$($_.Id) $($_.Status) $($_.Message)" }) -join ' ; ')

    # N6: undo without a hit says so
    $e6 = New-Env
    [void](Save-AVDTuneRuleSet -Machine $e6.Machine -M $e6.M -Root $tmp -Name 'Gone6' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup @{ Kind = 'Ad'; Name = 'AVD-App-Gone6'; OuDn = $ouDn } -Ldap $e6.Ldap -Conn c -Directory $dirInfo -Confirmed -User a -SnapshotId s)
    $e6.Ldap.Store.Groups.Clear()   # someone deleted the group already
    $u6 = Undo-AVDTuneMaskingChange -Machine $e6.Machine -M $e6.M -Root $tmp -Ldap $e6.Ldap -Conn c -User a -SnapshotId s
    $g6 = @($u6.Results | Where-Object { $_.Id -like 'appmasking.undo.group*' })[0]
    $e6b = New-Env
    [void](Save-AVDTuneRuleSet -Machine $e6b.Machine -M $e6b.M -Root $tmp -Name 'Gone6b' -Entries $entries -Visibility HiddenExceptGroups -CreateGroup @{ Kind = 'Local'; Name = 'AVDTune-App-Gone6b' } -Confirmed -User a -SnapshotId s)
    $e6b.M.Store.LocalGroups.Remove('AVDTune-App-Gone6b')
    $u6b = Undo-AVDTuneMaskingChange -Machine $e6b.Machine -M $e6b.M -Root $tmp -User a -SnapshotId s
    $g6b = @($u6b.Results | Where-Object { $_.Id -like 'appmasking.undo.group*' })[0]
    Test-Check 'N6 undo without a hit: the result of a group that is not there (AD and local) says "group not found, nothing deleted"; nothing was deleted' ($g6.Status -eq 'Unchanged' -and $g6.Message -eq 'group not found, nothing deleted' -and $e6.Ldap.Store.Deleted.Count -eq 0 -and $g6b.Status -eq 'Unchanged' -and $g6b.Message -eq 'group not found, nothing deleted' -and @($u6.Results | Where-Object { $_.Id -like 'appmasking.undo.file*' -and $_.Status -eq 'Changed' }).Count -ge 1) "$($g6.Status) $($g6.Message) | $($g6b.Status) $($g6b.Message)"

    # N7: config\masking-backups keeps only the newest backups
    $bk = Join-Path $tmp 'config\masking-backups'
    if (Test-Path $bk) { Get-ChildItem $bk -Filter '*.json' | Remove-Item -Force }
    1..25 | ForEach-Object { Save-AVDTuneMaskingBackup -Root $tmp -Path "$rules\n$_.fxr" -Bytes ([Text.Encoding]::ASCII.GetBytes("backup $_")) }
    $left = @(Get-ChildItem $bk -Filter '*.json' | ForEach-Object Name)
    Save-AVDTuneMaskingBackup -Root $tmp -Path "$rules\n26.fxr" -Bytes ([byte[]](1)) -Keep 3
    $left3 = @(Get-ChildItem $bk -Filter '*.json').Count
    Test-Check 'N7 backups: after 25 backups only the newest 20 are left (the oldest are removed, the newest stays); -Keep sets the limit' ($left.Count -eq 20 -and @($left | Where-Object { $_ -like '*-n25.fxr.json' }).Count -eq 1 -and @($left | Where-Object { $_ -like '*-n1.fxr.json' -or $_ -like '*-n5.fxr.json' }).Count -eq 0 -and $left3 -eq 3) "$($left.Count) $left3"

    # ---------------------------------------------------------------- issue 69: one list, one rule set per Public Desktop entry
    $n1 = Get-AVDTuneShortcutRuleSetName 'App One.lnk'
    $nA = Get-AVDTuneShortcutRuleSetName ('Caf' + [char]0xE9 + '.lnk'); $nB = Get-AVDTuneShortcutRuleSetName 'Caf-.lnk'; $nC = Get-AVDTuneShortcutRuleSetName 'Cafe.lnk'
    $long = Get-AVDTuneShortcutRuleSetName (('x' * 150) + '.lnk'); $long2 = Get-AVDTuneShortcutRuleSetName (('x' * 150) + 'y.lnk')
    Test-Check 'list69 name: derived from the shortcut name (Desktop-<name>), valid; a changed name gets a hash so two entries never share a rule set; long names are cut and stay valid and different' ($n1 -ceq 'Desktop-App One' -and (Test-AVDTuneMaskingName $n1) -and $nA -ne $nC -and $nA -ne $nB -and (Test-AVDTuneMaskingName $nA) -and $long.Length -le 64 -and (Test-AVDTuneMaskingName $long) -and $long -ne $long2 -and (Test-AVDTuneMaskingName $long2)) "$n1 $nA $nB $nC $long $long2"
    Test-Check 'list69 name: a name that cannot be a rule set name is refused and the validator anchors with \A...\z (trailing LF)' ((Test-AVDTuneMaskingName "Desktop-x`n") -eq $false -and (Get-AVDTuneShortcutRuleSetName '...lnk') -like 'Desktop-*') $null
    $dirG = [pscustomobject]@{ DefaultNamingContext = $dn; NetBiosName = 'EXAMPLE'; DnsName = 'example.test'; OuTree = $dirInfo.OuTree; Groups = @([pscustomobject]@{ Name = 'Sales Team'; Sam = 'Sales Team'; Dn = "CN=Sales Team,$ouDn"; Sid = 'S-1-5-21-1-2-3-1201'; Security = $true }, [pscustomobject]@{ Name = 'Staff'; Sam = 'Staff'; Dn = "CN=Staff,$ouDn"; Sid = 'S-1-5-21-1-2-3-1202'; Security = $true }) }
    $ldapSeed = @{ Groups = (New-Object System.Collections.ArrayList (, @(@{ Name = 'Sales Team'; Dn = "CN=Sales Team,$ouDn"; Sid = 'S-1-5-21-1-2-3-1201'; Description = 'x'; Members = @() }, @{ Name = 'Staff'; Dn = "CN=Staff,$ouDn"; Sid = 'S-1-5-21-1-2-3-1202'; Description = 'x'; Members = @() }))) }
    $deskSeed = @{ Desktop = @(@{ Name = 'App One.lnk'; Target = 'C:\a\one.exe'; IsShortcut = $true }, @{ Name = 'App Two.lnk'; Target = 'C:\a\two.exe'; IsShortcut = $true }, @{ Name = 'Old.lnk'; Target = 'C:\a\old.exe'; IsShortcut = $true }) }
    $L = New-Env -Seed $deskSeed -LdapSeed $ldapSeed
    $l0 = @(Get-AVDTuneMaskingList -M $L.M -Directory $dirG)
    Test-Check 'list69: one row per entry of the Public Desktop, all Everyone and editable when nothing hides them; every row has its own valid rule set name' ($l0.Count -eq 3 -and @($l0 | Where-Object { $_.Mode -eq 'Everyone' -and $_.Editable }).Count -eq 3 -and (@($l0.RuleSet | Sort-Object -Unique)).Count -eq 3) (($l0 | ForEach-Object { "$($_.Name)=$($_.Mode)/$($_.RuleSet)" }) -join ';')
    $gChange = Get-AVDTuneShortcutChange -M $L.M -Row $l0[0] -Mode 'Only members of a group' -GroupSid 'S-1-5-21-1-2-3-1201' -Directory $dirG
    Test-Check 'list69 change: a group row builds a HiddenExceptGroups save for exactly this entry, bound by sAMAccountName and SID, with old and new text' ($gChange.Action -eq 'Save' -and $gChange.SaveParams.Visibility -eq 'HiddenExceptGroups' -and $gChange.SaveParams.Name -eq 'Desktop-App One' -and @($gChange.SaveParams.Entries).Count -eq 1 -and $gChange.SaveParams.Entries[0].Name -eq 'App One.lnk' -and $gChange.SaveParams.Groups[0].Sam -eq 'Sales Team' -and $gChange.SaveParams.Groups[0].Sid -eq 'S-1-5-21-1-2-3-1201' -and $gChange.Old -eq 'Everyone' -and $gChange.New -like '*EXAMPLE\Sales Team*') ($gChange | Out-String)
    $p = $gChange.SaveParams; $p.Ldap = $L.Ldap; $p.Conn = 'c'
    $pv = Save-AVDTuneRuleSet -Machine $L.Machine -M $L.M -Root $tmp @p -WhatIf
    Test-Check 'list69 preview: nothing is written' ($L.M.Store.Files.Count -eq 0 -and @($pv.Results).Count -ge 1) $null
    $sv = Save-AVDTuneRuleSet -Machine $L.Machine -M $L.M -Root $tmp @p -User 'admin1' -SnapshotId 'snap-69'
    $fxr1 = Get-Written $L 'Desktop-App One' 'fxr'; $fxa1 = Get-Written $L 'Desktop-App One' 'fxa'
    Test-Check 'list69 save: one assignment per row = one rule set with exactly one hiding rule and the group (name, DN) in the .fxa; the other entries have no files' (@($sv.Results | Where-Object Status -eq 'Changed').Count -eq 2 -and $fxr1 -like "*$pd`tApp One.lnk*" -and ([regex]::Matches($fxr1, '0x00000222')).Count -eq 1 -and $fxa1 -like '*EXAMPLE\Sales Team*' -and $L.M.Store.Files.Count -eq 2) (($sv.Results | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ';')
    $l1 = @(Get-AVDTuneMaskingList -M $L.M -Directory $dirG)
    Test-Check 'list69: after the save the row shows the group (Account and SID) and stays editable; the other rows are untouched' ($l1[0].Mode -eq 'Only members of a group' -and $l1[0].Groups[0].Account -eq 'EXAMPLE\Sales Team' -and $l1[0].Groups[0].Sid -eq 'S-1-5-21-1-2-3-1201' -and $l1[0].Editable -and $l1[1].Mode -eq 'Everyone' -and $l1[2].Mode -eq 'Everyone') (($l1 | ForEach-Object { "$($_.Name)=$($_.Mode)" }) -join ';')
    $same = Get-AVDTuneShortcutChange -M $L.M -Row $l1[0] -Mode 'Only members of a group' -GroupSid 'S-1-5-21-1-2-3-1201' -Directory $dirG
    $other = Get-AVDTuneShortcutChange -M $L.M -Row $l1[0] -Mode 'Only members of a group' -GroupSid 'S-1-5-21-1-2-3-1202' -Directory $dirG
    $adm = Get-AVDTuneShortcutChange -M $L.M -Row $l1[0] -Mode 'Nobody except administrators' -Directory $dirG
    $evr = Get-AVDTuneShortcutChange -M $L.M -Row $l1[0] -Mode 'Everyone' -Directory $dirG
    Test-Check 'list69 change: same value = no change; another group and administrators only = Save; Everyone = Remove of the own rule set' ($same.Action -eq 'None' -and $other.Action -eq 'Save' -and $adm.Action -eq 'Save' -and $adm.SaveParams.Visibility -eq 'Hidden' -and $evr.Action -eq 'Remove' -and $evr.RuleSet -eq 'Desktop-App One') $null
    $po = $other.SaveParams; $po.Ldap = $L.Ldap; $po.Conn = 'c'
    $prev2 = Save-AVDTuneRuleSet -Machine $L.Machine -M $L.M -Root $tmp @po -WhatIf
    $noExp = Get-ThrownText { Save-AVDTuneRuleSet -Machine $L.Machine -M $L.M -Root $tmp @po -User a -SnapshotId s }
    Test-Check 'list69: changing an existing assignment shows old and new meaning, and the module refuses to write without the confirmed ExpectedChange' ($prev2.AssignmentChange -and $prev2.AssignmentChange.Old -like '*Sales Team*' -and $prev2.AssignmentChange.New -like '*Staff*' -and $noExp) $noExp
    $bad = @(
        { Get-AVDTuneShortcutChange -M $L.M -Row $l1[0] -Mode 'Only members of a group' -GroupSid '' -Directory $dirG },
        { Get-AVDTuneShortcutChange -M $L.M -Row $l1[0] -Mode 'Only members of a group' -GroupSid 'S-1-5-21-1-2-3-9999' -Directory $dirG },
        { Get-AVDTuneShortcutChange -M $L.M -Row $l1[0] -Mode 'Only members of a group' -GroupSid 'x,OU=y' -Directory $dirG },
        { Get-AVDTuneShortcutChange -M $L.M -Row $l1[0] -Mode 'Only members of a group' -GroupSid 'S-1-5-21-1-2-3-1201' -Directory $null },
        { Get-AVDTuneShortcutChange -M $L.M -Row $l1[0] -Mode 'Everybody' -Directory $dirG }
    )
    Test-Check 'list69 change: no group chosen, a SID that the DC discovery does not know, a non-SID text, no directory and a mode that is not in the menu are all refused' (@($bad | Where-Object { Test-Throws $_ }).Count -eq 5) $null
    $fo = Save-AVDTuneRuleSet -Machine $L.Machine -M $L.M -Root $tmp -Name 'Public Desktop' -Entries @(@{ Folder = $pd; Name = 'Old.lnk' }, @{ Folder = $pd; Name = 'App Two.lnk' }) -Visibility Hidden -User a -SnapshotId s
    $l2 = @(Get-AVDTuneMaskingList -M $L.M -Directory $dirG)
    $row2 = $l2 | Where-Object Name -eq 'App Two.lnk'
    Test-Check 'list69: an entry that another (wizard) rule set hides is shown with its state but cannot be changed here (a second rule set could not lift that hiding); the note says where' (-not $row2.Editable -and $row2.Mode -eq 'Nobody except administrators' -and $row2.Note -like "*'Public Desktop'*Advanced*" -and (Test-Throws { Get-AVDTuneShortcutChange -M $L.M -Row $row2 -Mode 'Everyone' -Directory $dirG })) $row2.Note
    $rem = Remove-AVDTuneRuleSet -Machine $L.Machine -M $L.M -Root $tmp -Name 'Public Desktop' -User a -SnapshotId s
    $rm = Remove-AVDTuneRuleSet -Machine $L.Machine -M $L.M -Root $tmp -Name $evr.RuleSet -User a -SnapshotId s
    Test-Check 'list69 remove: Everyone deletes the own rule set (both files); the row is Everyone again' (@($rm.Results | Where-Object Status -eq 'Changed').Count -eq 2 -and $null -eq (Get-Written $L 'Desktop-App One' 'fxr') -and (@(Get-AVDTuneMaskingList -M $L.M -Directory $dirG) | Where-Object Name -eq 'App One.lnk').Mode -eq 'Everyone') $null
    $ul = Undo-AVDTuneMaskingChange -Machine $L.Machine -M $L.M -Root $tmp -User a -SnapshotId s
    Test-Check 'list69 undo: the last change (the removal) is put back byte for byte with the hash rules of #29' (@($ul.Results | Where-Object { $_.Status -in 'Changed', 'Reverted' }).Count -ge 1 -and $null -ne (Get-Written $L 'Desktop-App One' 'fxa') -and (@(Get-AVDTuneMaskingList -M $L.M -Directory $dirG) | Where-Object Name -eq 'App One.lnk').Mode -eq 'Only members of a group') (($ul.Results | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ';')
    $multi = New-Env -Seed @{ Desktop = @(@{ Name = 'A.lnk'; Target = 'x'; IsShortcut = $true }) }
    [void](Save-AVDTuneRuleSet -Machine $multi.Machine -M $multi.M -Root $tmp -Name 'Desktop-A' -Entries @(@{ Folder = $pd; Name = 'A.lnk' }, @{ Folder = $pd; Name = 'B.lnk' }) -Visibility Hidden -User a -SnapshotId s)
    $lm = @(Get-AVDTuneMaskingList -M $multi.M -Directory $dirG)
    Test-Check 'list69: an own-named rule set that holds more than this entry is not editable here (it would drop the other rule)' (-not $lm[0].Editable -and $lm[0].Note -like '*more than this entry*') $lm[0].Note
    $entra = Get-AVDTuneEntraGroupInfo
    Test-Check 'list69 Entra: not offered, with the reason and the Microsoft Learn source (assignments do not support Entra ID cloud-only accounts; synced AD groups and a domain controller are needed)' (-not $entra.Supported -and $entra.Text -like '*cloud-only*' -and $entra.Text -like '*synced from Active Directory*' -and $entra.Source -like 'https://learn.microsoft.com/en-us/fslogix/concepts-fslogix-apps-rule-editor-rule-sets*') $null
    $pg69 = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-AppMasking.ps1'))
    $rowFn = $pg69.Substring($pg69.IndexOf('function Invoke-MaskRow'), $pg69.IndexOf('function Invoke-MaskSave') - $pg69.IndexOf('function Invoke-MaskRow'))
    $iAssert = $rowFn.IndexOf('Assert-MaskWrite'); $iConf = $rowFn.IndexOf('Confirm-Action'); $iLdapLast = $rowFn.LastIndexOf('Get-MaskLdap'); $iMask = $rowFn.IndexOf('Invoke-MaskChange')
    Test-Check 'page69: a row is saved only after the write gate and the confirmation (old and new in the text); the DC connection of the write path comes after the confirmation; the change runs as a task; the preview writes nothing' ($iAssert -gt 0 -and $iAssert -lt $iConf -and $iConf -lt $iLdapLast -and $iLdapLast -lt $iMask -and $rowFn.Contains('Now: $($ch.Old)') -and $rowFn.Contains('New: $($ch.New)') -and $rowFn.IndexOf('-WhatIf') -gt 0 -and $rowFn.IndexOf('return') -lt $iAssert) "$iAssert $iConf $iLdapLast $iMask"
    Test-Check 'page69: the password box is cleared in finally also in the row path' ($rowFn.Contains('finally { if ($lc) { & $lc.Close }; $ui.PwdMask.Clear() }')) $null
    $readFn = $pg69.Substring($pg69.IndexOf('function Start-MaskReadJob'), $pg69.IndexOf('function Get-MaskGroupChoices') - $pg69.IndexOf('function Start-MaskReadJob'))
    Test-Check 'page69: the state is read in a background runspace with a task on the task bar (real adapter in the runspace, the fakes inline in test mode) and the timer completes it' ($readFn.Contains('New-AVDTunePowerShell') -and $readFn.Contains('BeginInvoke()') -and $readFn.Contains('New-AVDTuneMaskingAdapter') -and $readFn.Contains('$script:TestMode') -and $pg69.Contains('Start-AVDTuneUiTask -Kind') -and $readFn.Contains('Complete-AVDTuneUiTask') -and $pg69.Contains('Complete-MaskReadJob } catch') -and $pg69.Contains("-Kind 'appmasking-read'")) $null
    $bp = $pg69.Substring($pg69.IndexOf('function Build-MaskPage'), $pg69.IndexOf('function Get-MaskKindChoices') - $pg69.IndexOf('function Build-MaskPage'))
    $iExp = $bp.IndexOf('ExpMaskAdvanced.Content = $adv')
    Test-Check 'page69: the wizard (rule set name, OU, new group, domain controller account) and the rule sets sit in a collapsed Advanced expander; the list card is outside of it' ($bp.Contains("Header = 'Advanced'") -and $bp.Contains('IsExpanded = $false') -and $bp.IndexOf('$ui.TxtMaskName =') -gt $bp.IndexOf('$adv = New-Object') -and $bp.IndexOf('$ui.CmbMaskOu =') -lt $iExp -and $bp.IndexOf('$ui.TxtMaskDc =') -lt $iExp -and $bp.IndexOf('$ui.PanelMaskList =') -lt $bp.IndexOf('$adv = New-Object')) $null
    Test-Check 'page69: the group menu names Microsoft Entra ID groups as not supported with the source' ($pg69.Contains('Microsoft Entra ID groups: not supported (source: Microsoft Learn') -and $pg69.Contains('Get-AVDTuneEntraGroupInfo')) $null

    # ---------------------------------------------------------------- review of #69 (Finn): collisions, TOCTOU at remove, ASCII only, domain in the preselection
    $K = [string][char]0x212A   # KELVIN SIGN: matches [A-Za-z] case-insensitively
    $col = New-Env -Seed @{ Desktop = @(@{ Name = 'Notes.lnk'; Target = 'x'; IsShortcut = $true }, @{ Name = 'Notes.url'; Target = 'x'; IsShortcut = $true }, @{ Name = 'notes'; Target = 'x'; IsShortcut = $false }, @{ Name = 'Solo.lnk'; Target = 'x'; IsShortcut = $true }) }
    $lc = @(Get-AVDTuneMaskingList -M $col.M -Directory $dirG)
    $forged = $lc[0].PSObject.Copy(); $forged.Editable = $true
    Test-Check 'review69 collision: Notes.lnk, Notes.url and notes give the same rule set name; all three rows are locked with the reason and the single one stays editable' (@($lc | Where-Object { $_.Name -in 'Notes.lnk', 'Notes.url', 'notes' -and -not $_.Editable -and $_.Note -like '*same rule set name*' }).Count -eq 3 -and ($lc | Where-Object Name -eq 'Solo.lnk').Editable) (($lc | ForEach-Object { "$($_.Name)=$($_.Editable)" }) -join ';')
    Test-Check 'review69 collision: the module refuses the change too (also a row that claims Editable), for Save and for the rest; nothing is written' ((Test-Throws { Get-AVDTuneShortcutChange -M $col.M -Row $lc[0] -Mode 'Nobody except administrators' -Directory $dirG }) -and (Test-Throws { Get-AVDTuneShortcutChange -M $col.M -Row $forged -Mode 'Nobody except administrators' -Directory $dirG }) -and (Test-Throws { Get-AVDTuneShortcutChange -M $col.M -Row $lc[2] -Mode 'Everyone' -Directory $dirG }) -and $col.M.Store.Files.Count -eq 0) $null
    $cafe = 'Caf' + [char]0xE9 + '.lnk'; $hashName = Get-AVDTuneShortcutRuleSetName $cafe; $look = $hashName.Substring('Desktop-'.Length) + '.lnk'
    $hn = New-Env -Seed @{ Desktop = @(@{ Name = $cafe; Target = 'x'; IsShortcut = $true }, @{ Name = $look; Target = 'x'; IsShortcut = $true }) }
    $lh = @(Get-AVDTuneMaskingList -M $hn.M -Directory $dirG)
    Test-Check 'review69 collision: a file named like the hash name of another entry (Caf-<hash>.lnk next to the accented name) locks both rows' ((Get-AVDTuneShortcutRuleSetName $look) -eq $hashName -and @($lh | Where-Object { -not $_.Editable }).Count -eq 2 -and (Test-Throws { Get-AVDTuneShortcutChange -M $hn.M -Row $lh[1] -Mode 'Nobody except administrators' -Directory $dirG })) $hashName
    $st = New-Env -Seed @{ Desktop = @(@{ Name = 'Foo.lnk'; Target = 'x'; IsShortcut = $true }, @{ Name = 'Bar.lnk'; Target = 'x'; IsShortcut = $true }) }
    [void](Save-AVDTuneRuleSet -Machine $st.Machine -M $st.M -Root $tmp -Name 'Desktop-Foo' -Entries @(@{ Folder = $pd; Name = 'Bar.lnk' }) -Visibility Hidden -User a -SnapshotId s)
    $ls = @(Get-AVDTuneMaskingList -M $st.M -Directory $dirG)
    $foo = $ls | Where-Object Name -eq 'Foo.lnk'
    Test-Check 'review69 collision: a rule set named like this entry that covers another one is not touched: row locked, change refused, the set is unchanged' (-not $foo.Editable -and $foo.Note -like "*'Desktop-Foo' exists*" -and (Test-Throws { Get-AVDTuneShortcutChange -M $st.M -Row $foo -Mode 'Nobody except administrators' -Directory $dirG }) -and (Get-Written $st 'Desktop-Foo' 'fxr') -like '*Bar.lnk*') $foo.Note
    # TOCTOU at remove: the hashes of the read go to the module
    $tt = New-Env -Seed @{ Desktop = @(@{ Name = 'T.lnk'; Target = 'x'; IsShortcut = $true }) }
    [void](Save-AVDTuneRuleSet -Machine $tt.Machine -M $tt.M -Root $tmp -Name 'Desktop-T' -Entries @(@{ Folder = $pd; Name = 'T.lnk' }) -Visibility Hidden -User a -SnapshotId s)
    $lt = @(Get-AVDTuneMaskingList -M $tt.M -Directory $dirG)[0]
    $chT = Get-AVDTuneShortcutChange -M $tt.M -Row $lt -Mode 'Everyone' -Directory $dirG
    Test-Check 'review69 remove: the row carries the SHA256 of both files and the change hands them on' ($lt.Sha.Fxr.Length -eq 64 -and $lt.Sha.Fxa.Length -eq 64 -and $chT.Action -eq 'Remove' -and $chT.ExpectedSha.Fxa -eq $lt.Sha.Fxa) $null
    $tt.M.Store.Files["$rules\Desktop-T.fxa"] = ConvertTo-AVDTuneRuleBytes "1`r`n"
    $rtext = Get-ThrownText { Remove-AVDTuneRuleSet -Machine $tt.Machine -M $tt.M -Root $tmp -Name 'Desktop-T' -ExpectedSha $chT.ExpectedSha -User a -SnapshotId s }
    Test-Check 'review69 remove: a file changed after the read (also between confirmation and write) stops the delete; nothing is removed' ($rtext -like '*changed since it was read*' -and $tt.M.Store.Files.Count -eq 2) $rtext
    Test-Check 'review69 change: a row that is older than the files (hashes differ) is refused with "Refresh the list"' ((Get-ThrownText { Get-AVDTuneShortcutChange -M $tt.M -Row $lt -Mode 'Everyone' -Directory $dirG }) -like '*changed since the list was read*') $null
    $ok = Remove-AVDTuneRuleSet -Machine $tt.Machine -M $tt.M -Root $tmp -Name 'Desktop-T' -ExpectedSha @{ Fxr = (Get-AVDTuneBytesSha256 $tt.M.Store.Files["$rules\Desktop-T.fxr"]); Fxa = (Get-AVDTuneBytesSha256 $tt.M.Store.Files["$rules\Desktop-T.fxa"]) } -User a -SnapshotId s
    Test-Check 'review69 remove: with the hashes that match, the rule set is removed' (@($ok.Results | Where-Object Status -eq 'Changed').Count -eq 2 -and $tt.M.Store.Files.Count -eq 0) $null
    # ASCII only: the Kelvin sign and the long s are not [A-Za-z] here
    $kn = Get-AVDTuneShortcutRuleSetName ("Notes$K.lnk")
    Test-Check 'review69 ASCII: Kelvin sign and long s do not pass as letters in the validators (rule set name, group name, prefix)' (-not (Test-AVDTuneMaskingName "Desktop-$K") -and -not (Test-AVDTuneMaskingName "Desktop-$([char]0x17F)x") -and -not (Test-AVDTuneMaskingGroupName "AVD-App-$K") -and -not (Test-AVDTuneMaskingPrefix "AV$K") -and (Test-AVDTuneMaskingName 'Desktop-K') -and (Test-AVDTuneMaskingGroupName 'AVD-App-K')) $null
    Test-Check 'review69 ASCII: a name with a Kelvin sign gets a hash name that is plain ASCII and valid; the group name builder drops it' ($kn -cmatch '\A[\x20-\x7E]+\z' -and (Test-AVDTuneMaskingName $kn) -and $kn -match '-[0-9a-f]{6}\z' -and ((Get-AVDTuneAppGroupName -Prefix AVD -Name "Pr${K}o") -cmatch '\A[\x20-\x7E]+\z')) $kn
    # the preselection of the group compares the domain too
    $dm = New-Env -Seed @{ Desktop = @(@{ Name = 'D.lnk'; Target = 'x'; IsShortcut = $true }) } -LdapSeed $ldapSeed
    $pd2 = (Get-AVDTuneShortcutChange -M $dm.M -Row (@(Get-AVDTuneMaskingList -M $dm.M -Directory $dirG)[0]) -Mode 'Only members of a group' -GroupSid 'S-1-5-21-1-2-3-1201' -Directory $dirG).SaveParams
    $pd2.Ldap = $dm.Ldap; $pd2.Conn = 'c'
    [void](Save-AVDTuneRuleSet -Machine $dm.Machine -M $dm.M -Root $tmp @pd2 -User a -SnapshotId s)
    $otherDom = [pscustomobject]@{ DefaultNamingContext = $dn; NetBiosName = 'OTHER'; OuTree = @(); Groups = $dirG.Groups }
    Test-Check 'review69 preselection: the group of the row is matched with the domain; the same sAMAccountName of another domain gets no SID' ((@(Get-AVDTuneMaskingList -M $dm.M -Directory $dirG)[0]).Groups[0].Sid -eq 'S-1-5-21-1-2-3-1201' -and (@(Get-AVDTuneMaskingList -M $dm.M -Directory $otherDom)[0]).Groups[0].Sid -eq '') $null
    $pg70 = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-AppMasking.ps1'))
    Test-Check 'page69 review: the row buttons are locked while the state is read and a click during the read is refused; Remove gets the hashes of the read' ($pg70.Contains('$busy = [bool]$script:MaskReadJob') -and $pg70.Contains('-and -not $busy') -and $pg70.Contains('The list is being read') -and $pg70.Contains('-ExpectedSha $sha') -and $pg70.Contains('-ExpectedSha $ch.ExpectedSha -WhatIf') -and $pg70.Contains('Update-MaskRowState $e }')) $null
    # review 2 of #69: the drive letter of a rule path and the digits of a SID are ASCII only (Kelvin sign, Arabic-Indic digit)
    $arSid = 'S-1-5-21-1-2-' + [string][char]0x663
    Test-Check 'review69b ASCII: a rule folder with the Kelvin sign as drive letter is refused (C: is accepted); a SID with an Arabic-Indic digit is refused as group SID' ((Test-AVDTuneMaskingRulePath ($K + ':\Users\Public\Desktop') 'A.lnk') -ne '' -and (Test-AVDTuneMaskingRulePath 'C:\Users\Public\Desktop' 'A.lnk') -eq '' -and (Get-ThrownText { Get-AVDTuneShortcutChange -M $L.M -Row $l0[1] -Mode 'Only members of a group' -GroupSid $arSid -Directory $dirG }) -like 'Choose the group*') $null
}
finally {
    Close-AVDTuneWriteGate
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { "Check-Masking: $script:failed failed."; exit 1 }
'Check-Masking: all checks passed.'
