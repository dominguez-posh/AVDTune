#requires -Version 5.1
<#
.SYNOPSIS
    Checks the AVDTune engine (Modules\AVDTune.psm1) against a fake machine and a temporary state folder: state, atomic writes,
    image versions, append-only runs, the step contract (Test/Apply/Undo, WhatIf, idempotency), declarative steps, plans,
    change log and export, Overview data and health checks. Nothing touches the registry, services or C:\ProgramData of this computer.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Test-Throws([scriptblock]$Block) { try { & $Block | Out-Null; $false } catch { $true } }
function Remove-AVDTuneTestTree([string]$Path) {
    # deletes a test folder; links are removed as links (their targets stay)
    $d = New-Object IO.DirectoryInfo $Path
    if (-not $d.Exists) { if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }; return }
    if (($d.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $d.Delete(); return }
    foreach ($c in $d.GetFileSystemInfos()) { if ($c -is [IO.DirectoryInfo]) { Remove-AVDTuneTestTree $c.FullName } else { $c.Delete() } }
    $d.Delete()
}
function Join-Pairs($Table) { (($Table.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ') }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-check-' + [guid]::NewGuid().ToString('N'))
try {
    # ---------------------------------------------------------------- helpers
    Test-Check 'arguments are quoted per argument' ((ConvertTo-AVDTuneArgument 'a b') -eq '"a b"' -and (ConvertTo-AVDTuneArgument 'x') -eq 'x' -and (ConvertTo-AVDTuneArgument 'say "hi"') -eq '"say \"hi\""' -and (ConvertTo-AVDTuneArgument '') -eq '""' -and (ConvertTo-AVDTuneArgument 'C:\a b\') -eq '"C:\a b\\"')
    Test-Check 'elevation test returns a bool' ((Test-AVDTuneElevated) -is [bool]) $null
    $env:AVDTUNE_ROOT = $null
    $realRoot = Get-AVDTuneRoot
    Test-Check 'default root is ProgramData\AVDTune and counts as the real one' ($realRoot -like '*\AVDTune' -and (Test-AVDTuneDefaultRoot $realRoot) -and -not (Test-AVDTuneDefaultRoot $tmp)) $realRoot
    $env:AVDTUNE_ROOT = $tmp
    $rootAlone = Get-AVDTuneRoot -WarningVariable rootWarn -WarningAction SilentlyContinue
    Test-Check 'attack: AVDTUNE_ROOT without AVDTUNE_FAKE is ignored with a warning (state stays in ProgramData)' ($rootAlone -eq $realRoot -and (@($rootWarn) -join ' ') -like '*ignored without AVDTUNE_FAKE*') "$rootAlone / $(@($rootWarn) -join ' ')"
    $env:AVDTUNE_FAKE = Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1'
    Test-Check 'AVDTUNE_ROOT overrides the root' ((Get-AVDTuneRoot) -eq $tmp) $null

    # ---------------------------------------------------------------- test mode gate (issue 23)
    $emptyEnv = { param($n, $s) $null }
    $tm = Test-AVDTuneTestMode -AppRoot $repo -EnvReader $emptyEnv
    Test-Check 'test mode: process variables in a checkout enable it, fake script resolved below Tests' ($tm.Enabled -and $tm.FakeScript -like (Join-Path $repo 'Tests\*') -and $tm.FakeDir -eq (Join-Path $repo 'Tests\Fakes')) ($tm | Out-String)
    $userEnv = { param($n, $s) if ($s -eq 'User') { 'x' } else { $null } }
    $tm = Test-AVDTuneTestMode -AppRoot $repo -EnvReader $userEnv -WarningAction SilentlyContinue
    Test-Check 'attack: variable also in the User environment (HKCU) gives no test mode and no fake script' (-not $tm.Enabled -and -not $tm.FakeScript) $tm.Reason
    $machEnv = { param($n, $s) if ($s -eq 'Machine') { 'x' } else { $null } }
    $tm = Test-AVDTuneTestMode -AppRoot $repo -EnvReader $machEnv -WarningAction SilentlyContinue
    Test-Check 'attack: variable also in the Machine environment gives no test mode' (-not $tm.Enabled -and -not $tm.FakeScript) $tm.Reason
    $instRoot = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'AVDTune\0.9.0'
    $tm = Test-AVDTuneTestMode -AppRoot $instRoot -EnvReader $emptyEnv -WarningAction SilentlyContinue
    Test-Check 'attack: installed path (Program Files) with the variables gives no test mode and no fake script' (-not $tm.Enabled -and -not $tm.FakeScript) $tm.Reason
    $savedFake = $env:AVDTUNE_FAKE
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $env:AVDTUNE_FAKE = Join-Path $tmp 'FakeMachine.ps1'; Set-Content -LiteralPath $env:AVDTUNE_FAKE -Value '# evil'
    $tm = Test-AVDTuneTestMode -AppRoot $repo -EnvReader $emptyEnv -WarningAction SilentlyContinue
    Test-Check 'attack: fake script outside Tests\ is refused (no dot-source)' (-not $tm.Enabled -and -not $tm.FakeScript -and (Get-AVDTuneRoot -WarningAction SilentlyContinue) -eq $realRoot) $tm.Reason
    $env:AVDTUNE_FAKE = Join-Path $repo 'Tests\..\Start-AVDTune.ps1'
    $tm = Test-AVDTuneTestMode -AppRoot $repo -EnvReader $emptyEnv -WarningAction SilentlyContinue
    Test-Check 'attack: a dot-dot path out of Tests\ is refused' (-not $tm.Enabled) $tm.Reason
    $env:AVDTUNE_FAKE = $savedFake
    # a link inside the copy (below Tests) and above it (the chain from AppRoot): the junction check reports visibly when no junction can be made
    $real = Join-Path $tmp 'real'
    New-Item -ItemType Directory -Path (Join-Path $real 'Tests\Fakes') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $real 'Tests\Fakes\FakeMachine.ps1') -Value '# x'
    $linkTests = Join-Path $tmp 'linkedtests'
    New-Item -ItemType Directory -Path $linkTests -Force | Out-Null
    $jTests = Join-Path $real 'Tests\Fakes\inner'; $jApp = Join-Path $tmp 'jrepo'
    $linkOk = $false
    try { New-Item -ItemType Junction -Path $jTests -Target $linkTests | Out-Null; New-Item -ItemType Junction -Path $jApp -Target $real | Out-Null; $linkOk = $true } catch { }
    if ($linkOk) {
        Set-Content -LiteralPath (Join-Path $linkTests 'f.ps1') -Value '# x'
        Test-Check 'control: a plain copy resolves its fake script' ($null -ne (Resolve-AVDTuneTestScript -Path (Join-Path $real 'Tests\Fakes\FakeMachine.ps1') -AppRoot $real)) $null
        Test-Check 'attack: a link below Tests\ is refused' ($null -eq (Resolve-AVDTuneTestScript -Path (Join-Path $jTests 'f.ps1') -AppRoot $real)) $null
        Test-Check 'attack: a link in the chain at or above AppRoot is refused' ($null -eq (Resolve-AVDTuneTestScript -Path (Join-Path $jApp 'Tests\Fakes\FakeMachine.ps1') -AppRoot $jApp)) $null
        [IO.Directory]::Delete($jTests); [IO.Directory]::Delete($jApp)
    }
    else { Write-Warning 'SKIPPED: the link checks of the test mode gate (no junction could be created here)'; 'SKIPPED link checks of the test mode gate: no junction could be created' }

    # 8.3 names and the install layout
    $short = 'C:\PROGRA~1'
    if (Test-Path -LiteralPath $short) {
        $tm = Test-AVDTuneTestMode -AppRoot "$short\AVDTune\0.9.0" -EnvReader $emptyEnv -WarningAction SilentlyContinue
        Test-Check 'attack: an 8.3 path below Program Files counts as installed (no test mode)' (-not $tm.Enabled -and $tm.Reason -like '*installed copy*') $tm.Reason
    }
    else { Write-Warning 'SKIPPED: no C:\PROGRA~1 (8.3 names off)'; 'SKIPPED 8.3 check: no C:\PROGRA~1' }
    Test-Check 'long path expands 8.3 names' ((Get-AVDTuneLongPath 'C:\PROGRA~1') -eq (Get-AVDTuneLongPath ([Environment]::GetFolderPath('ProgramFiles')))) (Get-AVDTuneLongPath 'C:\PROGRA~1')
    $instOther = Join-Path $tmp 'inst'
    $tm = Test-AVDTuneTestMode -AppRoot (Join-Path $instOther '0.9.0') -InstallRoot $instOther -EnvReader $emptyEnv -WarningAction SilentlyContinue
    Test-Check 'attack: installed by the install layout but not below Program Files gives no test mode' (-not $tm.Enabled -and $tm.Reason -like '*installed copy*') $tm.Reason

    # AVDTUNE_SMOKE counts only inside the test mode
    $savedSmoke = $env:AVDTUNE_SMOKE
    $env:AVDTUNE_SMOKE = Join-Path $repo 'Tests\GuiSmokeDriver.ps1'
    $tm = Test-AVDTuneTestMode -AppRoot $repo -EnvReader $emptyEnv
    Test-Check 'smoke: process variables in a checkout give the smoke mode with the driver below Tests' ($tm.Enabled -and $tm.Smoke -and $tm.SmokeScript -like (Join-Path $repo 'Tests\*')) ($tm | Out-String)
    $asked = @(); $dialog = { param($t, $ti) $script:dialogShown++; $false }; $script:dialogShown = 0
    Test-Check 'smoke: Confirm answers yes without a dialog only in the smoke mode' ((Confirm-AVDTuneAction -Text 'q' -Auto $tm.Smoke -Dialog $dialog) -and $script:dialogShown -eq 0) $null
    $tm = Test-AVDTuneTestMode -AppRoot $repo -EnvReader $userEnv -WarningAction SilentlyContinue
    Test-Check 'attack: SMOKE set in the user environment gives no smoke mode and the dialog is shown' (-not $tm.Smoke -and -not (Confirm-AVDTuneAction -Text 'q' -Auto $tm.Smoke -Dialog $dialog) -and $script:dialogShown -eq 1) $tm.Reason
    $env:AVDTUNE_SMOKE = Join-Path $tmp 'FakeMachine.ps1'
    $tm = Test-AVDTuneTestMode -AppRoot $repo -EnvReader $emptyEnv -WarningAction SilentlyContinue
    Test-Check 'attack: a smoke script outside Tests\ is refused' (-not $tm.Smoke -and -not $tm.Enabled) $tm.Reason
    $env:AVDTUNE_SMOKE = Join-Path $repo 'Tests\GuiSmokeDriver.ps1'
    $savedFake2 = $env:AVDTUNE_FAKE; $savedRoot2 = $env:AVDTUNE_ROOT; $env:AVDTUNE_FAKE = $null; $env:AVDTUNE_ROOT = $null
    $tm = Test-AVDTuneTestMode -AppRoot $repo -EnvReader $emptyEnv -WarningAction SilentlyContinue
    Test-Check 'attack: SMOKE alone gives no smoke mode and a dialog' (-not $tm.Smoke -and -not $tm.Enabled -and -not (Confirm-AVDTuneAction -Text 'q' -Auto $tm.Smoke -Dialog $dialog) -and $script:dialogShown -eq 2) $tm.Reason
    $env:AVDTUNE_FAKE = $savedFake2; $env:AVDTUNE_ROOT = $savedRoot2; $env:AVDTUNE_SMOKE = $savedSmoke

    # a refused request is remembered for the protocol: time and reason, never a value
    $ref = @(Get-AVDTuneTestModeRefusal)
    Test-Check 'refused requests are remembered with time and reason (no values)' ($ref.Count -ge 5 -and -not ($ref | Where-Object { -not $_.Time -or -not $_.Reason -or $_.Reason -like "*$tmp*" })) ($ref | Out-String)

    # ---------------------------------------------------------------- state
    [void](Initialize-AVDTuneState -Root $tmp)
    Test-Check 'state folders exist' ((@('runs', 'protocols', 'config', 'benchmark', 'logs') | Where-Object { -not (Test-Path (Join-Path $tmp $_)) }).Count -eq 0) $null
    $state = Get-AVDTuneState $tmp
    Test-Check 'state.json starts empty with schema 1' ($state.Schema -eq 1 -and -not $state.ImageVersion -and $state.Sealed -eq $false) $null
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastUpdate = '2026-11-01'; Extra = 'x' })
    [void](Initialize-AVDTuneState -Root $tmp)
    $state = Get-AVDTuneState $tmp
    Test-Check 'Initialize keeps existing state; Set-AVDTuneState adds unknown keys' ($state.LastUpdate -eq '2026-11-01' -and $state.Extra -eq 'x') $null
    Test-Check 'atomic write leaves no temp file' (@(Get-ChildItem $tmp -Recurse -Filter '*.tmp').Count -eq 0) $null
    $acl = New-AVDTuneStateSecurity
    $rules = @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
    Test-Check 'state ACL: Administrators and SYSTEM only, inheritance off' ($acl.AreAccessRulesProtected -and $rules.Count -eq 2 -and (@($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object) -join ',') -eq 'S-1-5-18,S-1-5-32-544' -and -not (@($rules | Where-Object { $_.FileSystemRights -ne 'FullControl' }).Count)) (@($rules | ForEach-Object { $_.IdentityReference.Value }) -join ',')

    # ---------------------------------------------------------------- state folder prepared by someone else (finding 2 b)
    $sec = Join-Path $tmp 'sec-root'
    New-Item -ItemType Directory -Path (Join-Path $sec 'WebView2') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $sec 'WebView2\Microsoft.Web.WebView2.Core.dll'), 'MZ planted')
    $foreignSid = 'S-1-5-21-1000000000-2000000000-3000000000-1001'
    # fake ACL reader: a table path -> @{ Owner; Protected; Rules }; everything not in the table is trusted
    $aclTable = @{}
    $okAcl = { [pscustomobject]@{ Owner = 'S-1-5-32-544'; Protected = $false; Rules = @([pscustomobject]@{ Sid = 'S-1-5-18'; Inherited = $true }) } }
    $readFake = { param($Path, $IsDirectory) if ($aclTable.ContainsKey($Path)) { $aclTable[$Path] } else { & $okAcl } }.GetNewClosure()
    Test-Check 'state folder of Administrators/SYSTEM: no problem' (@(Get-AVDTuneStateSecurityProblems -Root $sec -ReadAcl $readFake).Count -eq 0) $null
    $aclTable[(Join-Path $sec 'WebView2')] = [pscustomobject]@{ Owner = $foreignSid; Protected = $true; Rules = @([pscustomobject]@{ Sid = $foreignSid; Inherited = $false }) }
    $aclTable[(Join-Path $sec 'WebView2\Microsoft.Web.WebView2.Core.dll')] = [pscustomobject]@{ Owner = 'S-1-5-32-544'; Protected = $false; Rules = @([pscustomobject]@{ Sid = 'S-1-5-32-545'; Inherited = $false }) }
    $pr = @(Get-AVDTuneStateSecurityProblems -Root $sec -ReadAcl $readFake)
    Test-Check 'attack: a sub folder owned by a user and a file with an explicit rule for Users are found' ($pr.Count -eq 3 -and ($pr | Where-Object { $_.Path -like '*WebView2' -and $_.Problem -like "owner $foreignSid" }) -and ($pr | Where-Object { $_.Path -like '*Core.dll' -and $_.Problem -like '*S-1-5-32-545*' })) (($pr | ForEach-Object { "$($_.Path)=$($_.Problem)" }) -join '; ')
    $keepWv = $aclTable[(Join-Path $sec 'WebView2')]
    $aclTable[(Join-Path $sec 'WebView2')] = [pscustomobject]@{ Owner = 'S-1-5-32-544'; Protected = $true; Rules = @([pscustomobject]@{ Sid = 'S-1-5-32-545'; Inherited = $false; InheritOnly = $true; Write = $true }) }
    $prIo = @(Get-AVDTuneStateSecurityProblems -Root $sec -ReadAcl $readFake)
    Test-Check 'attack: a state sub folder with an explicit inherit-only rule for Users (OI)(CI)(IO)(W) is refused by the general check' (@($prIo | Where-Object { $_.Path -like '*WebView2' -and $_.Problem -like '*S-1-5-32-545*' }).Count -ge 1) (($prIo | ForEach-Object { "$($_.Path): $($_.Problem)" }) -join ' | ')
    $aclTable[(Join-Path $sec 'WebView2')] = $keepWv
    $aclTable[$sec] = [pscustomobject]@{ Owner = 'S-1-5-32-544'; Protected = $false; Rules = @([pscustomobject]@{ Sid = 'S-1-5-32-545'; Inherited = $true }) }
    Test-Check 'inherited rules of the root count only in the final check (root must be protected, Administrators/SYSTEM only)' (@(Get-AVDTuneStateSecurityProblems -Root $sec -ReadAcl $readFake | Where-Object { $_.Path -eq $sec }).Count -eq 0 -and @(Get-AVDTuneStateSecurityProblems -Root $sec -ReadAcl $readFake -Final | Where-Object { $_.Path -eq $sec }).Count -eq 2) $null
    $aclTable.Clear()

    # prepared state folder: set aside as a whole (quarantine), never repaired recursively (N1), nothing of it trusted (N2)
    $qParent = Join-Path $tmp 'q-parent'; $qRoot = Join-Path $qParent 'AVDTune'
    $qTarget = Join-Path $tmp 'q-target'; New-Item -ItemType Directory -Path $qTarget -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $qTarget 'system-file.txt'), 'must stay as it is')
    $targetAcl = (Get-Acl -LiteralPath $qTarget).Sddl
    # fake ACL reader: a folder with a file FOREIGN in it belongs to someone else; everything else is AVDTune's own (the real reader can only
    # see this unelevated user as owner); links are found by the walker itself
    $readQ = { param($Path, $IsDirectory)
        if ($IsDirectory -and (Test-Path -LiteralPath (Join-Path $Path 'FOREIGN'))) { return [pscustomobject]@{ Owner = 'S-1-5-21-1000000000-2000000000-3000000000-1001'; Protected = $false; Rules = @() } }
        [pscustomobject]@{ Owner = 'S-1-5-32-544'; Protected = $true; Rules = @([pscustomobject]@{ Sid = 'S-1-5-18'; Inherited = $false }) } }
    $createPlain = { param($Root) New-Item -ItemType Directory -Path $Root -Force | Out-Null }
    New-Item -ItemType Directory -Path (Join-Path $qRoot 'config') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $qRoot 'FOREIGN'), 'x')
    [IO.File]::WriteAllText((Join-Path $qRoot 'environment.json'), '{"Schema":1,"SignIn":{"TenantId":"attacker.example","ClientId":"00000000-0000-0000-0000-000000000001"},"Dc":{"Server":"10.0.0.66","Pins":{}}}')
    [IO.File]::WriteAllText((Join-Path $qRoot 'state.json'), '{"Schema":1,"LastChange":"2020-01-01T00:00:00Z"}')
    [IO.File]::WriteAllText((Join-Path $qRoot 'config\planted.json'), '{"Files":[]}')
    New-Item -ItemType Junction -Path (Join-Path $qRoot 'logs') -Value $qTarget | Out-Null
    $rep = $null; $e = $null
    try { [void](Initialize-AVDTuneState -Root $qRoot -Protect -ReadAcl $readQ -CreateRoot $createPlain); $rep = Get-AVDTuneStateSecurityReport } catch { $e = $_.Exception.Message }
    $aside = @(Get-ChildItem -LiteralPath $qParent -Directory | Where-Object { $_.Name -like 'AVDTune.untrusted-*' })
    Test-Check 'attack: a prepared state folder is set aside as AVDTune.untrusted-<time> and a new one is created' (-not $e -and $aside.Count -eq 1 -and $aside[0].Name -match '^AVDTune\.untrusted-\d{8}-\d{6}$' -and (Test-Path (Join-Path $qRoot 'state.json')) -and @($rep.Quarantined).Count -eq 1) "$e / $(@($aside | ForEach-Object Name) -join ',')"
    Test-Check 'N2: nothing of the prepared folder is taken over (no environment.json, no LastChange, no planted config file)' (-not (Test-Path (Join-Path $qRoot 'environment.json')) -and -not (Test-Path (Join-Path $qRoot 'config\planted.json')) -and $null -eq (Get-AVDTuneState $qRoot).PSObject.Properties['LastChange'] -and (Test-Path (Join-Path $aside[0].FullName 'environment.json'))) $null
    Test-Check 'the quarantine is in logs\security.log of the new folder and in the report for the protocol and the warning' ((Test-Path (Join-Path $qRoot 'logs\security.log')) -and ([IO.File]::ReadAllText((Join-Path $qRoot 'logs\security.log')) -like '*prepared by someone else*set aside as*AVDTune.untrusted-*nothing taken over*') -and -not ((Get-Item -LiteralPath (Join-Path $qRoot 'logs')).Attributes -band [IO.FileAttributes]::ReparsePoint)) $null
    Test-Check 'the junction in the prepared folder was not followed: its target is unchanged' ((Get-Content -LiteralPath (Join-Path $qTarget 'system-file.txt') -Raw).Trim() -eq 'must stay as it is' -and @(Get-ChildItem -LiteralPath $qTarget -Force).Count -eq 1 -and (Get-Acl -LiteralPath $qTarget).Sddl -eq $targetAcl) (@(Get-ChildItem -LiteralPath $qTarget -Force -Name) -join ',')
    Get-ChildItem -LiteralPath $qParent -Force | ForEach-Object { Remove-AVDTuneTestTree $_.FullName }

    # race: the attacker puts a junction in place of the root while AVDTune sets it aside / creates it again
    $calls = New-Object System.Collections.ArrayList
    $createRace = { param($Root) [void]$calls.Add('create'); New-Item -ItemType Junction -Path $Root -Value $qTarget | Out-Null }.GetNewClosure()
    $e = $null; try { [void](Initialize-AVDTuneState -Root $qRoot -Protect -ReadAcl $readQ -CreateRoot $createRace) } catch { $e = $_.Exception.Message }
    Test-Check 'attack: a junction that appears again at every create is removed as a link each time; after 3 tries the start is refused' ($e -like '*could not be set aside safely*does not start*' -and $calls.Count -eq 3 -and -not (Test-Path -LiteralPath $qRoot)) $e
    $quarantineRace = { param($Root, $Problems) $r = Move-AVDTuneStateToQuarantine -Root $Root -Problems $Problems; New-Item -ItemType Junction -Path $Root -Value $qTarget | Out-Null; $r }.GetNewClosure()
    New-Item -ItemType Directory -Path $qRoot -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $qRoot 'FOREIGN'), 'x')
    $e = $null; try { [void](Initialize-AVDTuneState -Root $qRoot -Protect -ReadAcl $readQ -CreateRoot $createPlain -Quarantine $quarantineRace) } catch { $e = $_.Exception.Message }
    Test-Check 'attack: a junction that reappears during the quarantine never gets an owner or ACL change through it; the start is refused' ($e -like '*does not start*' -and (Get-Content -LiteralPath (Join-Path $qTarget 'system-file.txt') -Raw).Trim() -eq 'must stay as it is' -and @(Get-ChildItem -LiteralPath $qTarget -Force).Count -eq 1 -and (Get-Acl -LiteralPath $qTarget).Sddl -eq $targetAcl) $e
    Remove-AVDTuneTestTree $qRoot
    Get-ChildItem -LiteralPath $qParent -Force | ForEach-Object { Remove-AVDTuneTestTree $_.FullName }
    # the SID of the administrator himself counts as owner below the root only (an unelevated process of his could have made the root)
    $adminSid = 'S-1-5-21-1000000000-2000000000-3000000000-500'
    $aRoot = Join-Path $tmp 'admin-root'; New-Item -ItemType Directory -Path (Join-Path $aRoot 'runs') -Force | Out-Null
    $readAdmin = { param($Path, $IsDirectory) [pscustomobject]@{ Owner = $adminSid; Protected = $true; Rules = @([pscustomobject]@{ Sid = 'S-1-5-32-544'; Inherited = $false }) } }.GetNewClosure()
    $pa = @(Get-AVDTuneStateSecurityProblems -Root $aRoot -Final -ReadAcl $readAdmin -AdminSid $adminSid)
    Test-Check 'root owned by the administrator''s own SID is a problem; the same owner below the root is fine' ($pa.Count -eq 1 -and $pa[0].Path -eq $aRoot -and $pa[0].Problem -eq "owner $adminSid") (($pa | ForEach-Object { "$($_.Path)=$($_.Problem)" }) -join '; ')
    Remove-AVDTuneTestTree $aRoot
    # a FILE named like the state folder: a problem, set aside like a foreign folder, then the folder is created
    $fParent = Join-Path $tmp 'file-parent'; New-Item -ItemType Directory -Path $fParent -Force | Out-Null
    $fRoot = Join-Path $fParent 'AVDTune'; [IO.File]::WriteAllText($fRoot, 'planted file')
    Test-Check 'a file in place of the state folder is a problem' (@(Get-AVDTuneStateSecurityProblems -Root $fRoot -Final -ReadAcl $readQ | Where-Object { $_.Problem -eq 'a file, not a folder' }).Count -eq 1) $null
    $e = $null; try { [void](Initialize-AVDTuneState -Root $fRoot -Protect -ReadAcl $readQ -CreateRoot $createPlain) } catch { $e = $_.Exception.Message }
    $asideF = @(Get-ChildItem -LiteralPath $fParent -File | Where-Object { $_.Name -like 'AVDTune.untrusted-*' })
    Test-Check 'attack: a file named AVDTune is set aside (renamed) and the state folder is created; no unclear abort' (-not $e -and $asideF.Count -eq 1 -and (Test-Path -LiteralPath $fRoot -PathType Container) -and (Test-Path (Join-Path $fRoot 'state.json')) -and @((Get-AVDTuneStateSecurityReport).Quarantined).Count -eq 1) $e
    Remove-AVDTuneTestTree $fParent
    $modCode = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.psm1'))
    Test-Check 'N1: no recursive icacls (/T, /reset) anywhere in the engine; the folder is created in one step with its ACL' ($modCode -notmatch "'/T'" -and $modCode -notmatch "'/reset'" -and $modCode -match '\.Create\(\(New-AVDTuneStateSecurity -WithOwner\)\)') $null
    $sd = New-AVDTuneStateSecurity -WithOwner
    Test-Check 'the security for creating the folder carries owner Administrators and the protected rules' ($sd.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544' -and $sd.AreAccessRulesProtected) $null
    $created = New-Object System.Collections.ArrayList
    $createRec = { param($Root) [void]$created.Add($Root); New-Item -ItemType Directory -Path $Root -Force | Out-Null }.GetNewClosure()
    [void](Initialize-AVDTuneState -Root (Join-Path $tmp 'fresh\AVDTune') -Protect -ReadAcl $readQ -CreateRoot $createRec)
    Test-Check 'first start: the protected folder is created by the one-step create, not by New-Item and a later ACL' ($created.Count -eq 1 -and (Test-Path (Join-Path $tmp 'fresh\AVDTune\state.json'))) $null

    # the real reader on this computer: files of a user who is not elevated belong to that user, a link is reported and not followed
    $target = Join-Path $tmp 'sec-target'; New-Item -ItemType Directory -Path $target -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $target 'outside.txt'), 'x')
    New-Item -ItemType Junction -Path (Join-Path $sec 'config') -Value $target | Out-Null
    $real = @(Get-AVDTuneStateSecurityProblems -Root $sec)
    Test-Check 'real ACL reader: a junction in the state folder is a problem and is not followed' (@($real | Where-Object { $_.Path -like '*\config' -and $_.Problem -like 'link*' }).Count -eq 1 -and @($real | Where-Object { $_.Path -like '*outside.txt' }).Count -eq 0) (($real | ForEach-Object { "$($_.Path)=$($_.Problem)" }) -join '; ')
    if (-not (Test-AVDTuneElevated)) {
        Test-Check 'real ACL reader: files owned by a user who is not an administrator are found (this check runs unelevated)' (@($real | Where-Object { $_.Problem -like 'owner S-1-5-21-*' }).Count -ge 2) (($real | ForEach-Object { $_.Problem }) -join '; ')
    }
    (New-Object IO.DirectoryInfo (Join-Path $sec 'config')).Delete()

    Write-AVDTuneFile (Join-Path $tmp 'state.json') '{"Schema":99}'
    Test-Check 'a newer state schema is refused' (Test-Throws { Get-AVDTuneState $tmp }) $null
    $aclFile = Join-Path $tmp 'acl-state.json'
    Write-AVDTuneFile $aclFile '{"a":1}'
    $open = (New-Object IO.FileInfo $aclFile).GetAccessControl()
    $open.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier 'S-1-1-0'), 'Read', 'Allow')))
    (New-Object IO.FileInfo $aclFile).SetAccessControl($open)
    Write-AVDTuneFile $aclFile '{"a":2}'
    $aclInfo = Read-AVDTuneAclInfo -Path $aclFile -IsDirectory $false
    $aclSids = @($aclInfo.Rules | ForEach-Object { $_.Sid })
    Test-Check 'Write-AVDTuneFile over an existing file: the old ACL is gone (no Everyone), protected, only Administrators/SYSTEM, content new, no temp left' ($aclInfo.Protected -and @($aclSids | Where-Object { $_ -notin 'S-1-5-32-544', 'S-1-5-18', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }).Count -eq 0 -and ([IO.File]::ReadAllText($aclFile) -eq '{"a":2}') -and -not @(Get-ChildItem $tmp -Filter 'acl-state.json.*.tmp').Count) ($aclSids -join ',')
    $lockFile = Join-Path $tmp 'locked.json'
    Write-AVDTuneFile $lockFile 'old'
    $held = [IO.File]::Open($lockFile, 'Open', 'Read', 'None')
    $lockThrew = $false
    try { Write-AVDTuneFile $lockFile 'new' } catch { $lockThrew = $true } finally { $held.Dispose() }
    Test-Check 'Write-AVDTuneFile: a target that is held open makes it throw, the old content stays, no temp file is left' ($lockThrew -and [IO.File]::ReadAllText($lockFile) -eq 'old' -and -not @(Get-ChildItem $tmp -Filter 'locked.json.*.tmp' -Force).Count) $null
    # A virus scanner holds the file only briefly (#58/#65): the replace is tried again and succeeds
    $held2 = [IO.File]::Open($lockFile, 'Open', 'Read', 'None')
    $releaser = [powershell]::Create(); [void]$releaser.AddScript({ param($h) Start-Sleep -Milliseconds 250; $h.Dispose() }).AddArgument($held2); $relRun = $releaser.BeginInvoke()
    $briefThrew = $false
    try { Write-AVDTuneFile $lockFile 'after-retry' } catch { $briefThrew = $true } finally { [void]$releaser.EndInvoke($relRun); $releaser.Dispose(); $held2.Dispose() }
    Test-Check 'Write-AVDTuneFile: a target held only briefly (scanner) is replaced after a retry, no temp file is left' (-not $briefThrew -and [IO.File]::ReadAllText($lockFile) -eq 'after-retry' -and -not @(Get-ChildItem $tmp -Filter 'locked.json.*.tmp' -Force).Count) $null
    $wfSrc = ((Get-Command Write-AVDTuneFile).ScriptBlock.ToString()) + ((Get-Command Write-AVDTuneAccessFile).ScriptBlock.ToString())
    Test-Check 'Write-AVDTuneFile and Write-AVDTuneAccessFile replace atomically (MoveFileEx), never delete the target before the move, never File.Replace' ($wfSrc -notmatch 'File\]::Delete\(\$Path\)\s*\}?\s*;?\s*\r?\n?\s*\[IO\.File\]::Move' -and $wfSrc -notmatch 'File\]::Replace' -and ([IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.psm1')) -match 'DllImport\("kernel32.dll".*MoveFileEx')) $null
    Write-AVDTuneFile (Join-Path $tmp 'state.json') ([ordered]@{ Schema = 1; ImageVersion = $null; Versions = @(); LastUpdate = $null; LastBenchmark = $null; UpdateBlock = $null; Sealed = $false; Identity = $null; LastRunId = $null } | ConvertTo-Json)

    # ---------------------------------------------------------------- image version
    Test-Check 'image version pattern' ((Test-AVDTuneImageVersion '2026.11.001') -and -not (Test-AVDTuneImageVersion '2026.13.001') -and -not (Test-AVDTuneImageVersion '2026.11.1') -and -not (Test-AVDTuneImageVersion 'x')) $null
    $v1 = Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-15') -User 'admin1'
    $v2 = Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-20') -User 'admin1'
    $v3 = Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-12-02') -User 'admin1'
    Test-Check 'versions count per month: 2026.11.001, 2026.11.002, 2026.12.001' ($v1 -eq '2026.11.001' -and $v2 -eq '2026.11.002' -and $v3 -eq '2026.12.001') "$v1 $v2 $v3"
    $state = Get-AVDTuneState $tmp
    Test-Check 'current version and the list are in the state' ($state.ImageVersion -eq '2026.12.001' -and @($state.Versions).Count -eq 3) $null
    $startedAgain = Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-25')
    Test-Check 'a version started late for an earlier month continues its count' ($startedAgain -eq '2026.11.003') $startedAgain

    # ---------------------------------------------------------------- runs (append only)
    $runPath = Add-AVDTuneRun -Root $tmp -Run ([pscustomobject]@{ Id = 'r-1'; Started = 'x'; Results = @() })
    Test-Check 'a run is written as runs\<id>.json and noted in the state' ((Test-Path $runPath) -and (Get-AVDTuneState $tmp).LastRunId -eq 'r-1') $runPath
    Test-Check 'a run record is never replaced' (Test-Throws { Add-AVDTuneRun -Root $tmp -Run ([pscustomobject]@{ Id = 'r-1'; Results = @() }) }) $null
    Test-Check 'a run id with a path in it is refused' (Test-Throws { Add-AVDTuneRun -Root $tmp -Run ([pscustomobject]@{ Id = '..\x'; Results = @() }) }) $null
    $auto = [pscustomobject]@{ Id = $null; Results = @() }
    [void](Add-AVDTuneRun -Root $tmp -Run $auto)
    Test-Check 'a missing run id is made' ($auto.Id -match '^\d{8}-\d{6}-[0-9a-f]{4}$' -and @(Get-AVDTuneRun -Root $tmp).Count -eq 2) $auto.Id

    # ---------------------------------------------------------------- step contract
    $m = New-AVDTuneFakeMachine
    $reg = 'HKLM:\SOFTWARE\AVDTuneTest'
    $step = New-AVDTuneStep -Id 'optimization.flag' -Section Optimization -Title 'Flag is 1' -Reboot $true `
        -Test { param($m) $v = & $m.RegGet 'HKLM:\SOFTWARE\AVDTuneTest' 'Flag'; @{ Compliant = ($v -eq 1); State = $v } } `
        -Apply { param($m) & $m.RegSet 'HKLM:\SOFTWARE\AVDTuneTest' 'Flag' 1 'DWord' } `
        -Undo { param($m) & $m.RegRemove 'HKLM:\SOFTWARE\AVDTuneTest' 'Flag' }
    $t = Invoke-AVDTuneStep -Step $step -Machine $m -Mode Test
    Test-Check 'Test: NonCompliant, nothing written' ($t.Status -eq 'NonCompliant' -and $m.Log.Count -eq 0) $t.Status
    $w = Invoke-AVDTuneStep -Step $step -Machine $m -Mode Apply -WhatIf
    Test-Check 'Apply -WhatIf: WhatIf, nothing written' ($w.Status -eq 'WhatIf' -and $m.Log.Count -eq 0 -and $w.WhatIf) $w.Status
    Test-Check 'Apply without the snapshot gate is refused, nothing written (read only)' (-not (Test-AVDTuneWriteAllowed) -and (Test-Throws { Invoke-AVDTuneStep -Step $step -Machine $m -Mode Apply }) -and (Test-Throws { Invoke-AVDTuneStep -Step $step -Machine $m -Mode Undo }) -and $m.Log.Count -eq 0) $null
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
    $a = Invoke-AVDTuneStep -Step $step -Machine $m -Mode Apply
    Test-Check 'Apply: Changed with before and after, reboot flag from the step' ($a.Status -eq 'Changed' -and $null -eq $a.Before -and $a.After -eq 1 -and $a.Reboot -and $m.Log.Count -eq 1) "$($a.Status) $($a.After)"
    $a2 = Invoke-AVDTuneStep -Step $step -Machine $m -Mode Apply
    Test-Check 'Apply again: Unchanged and nothing written (idempotent)' ($a2.Status -eq 'Unchanged' -and $m.Log.Count -eq 1 -and -not $a2.Reboot) $a2.Status
    $uw = Invoke-AVDTuneStep -Step $step -Machine $m -Mode Undo -WhatIf
    $u = Invoke-AVDTuneStep -Step $step -Machine $m -Mode Undo
    $u2 = Invoke-AVDTuneStep -Step $step -Machine $m -Mode Undo
    Test-Check 'Undo: WhatIf, Reverted, then Unchanged' ($uw.Status -eq 'WhatIf' -and $u.Status -eq 'Reverted' -and $u2.Status -eq 'Unchanged') "$($uw.Status) $($u.Status) $($u2.Status)"
    $noUndo = New-AVDTuneStep -Id 'optimization.noundo' -Section Optimization -Title 'x' -Test { $true } -Apply { }
    Test-Check 'a step without Undo says NoUndo' ((Invoke-AVDTuneStep -Step $noUndo -Machine $m -Mode Undo).Status -eq 'NoUndo') $null
    $lazy = New-AVDTuneStep -Id 'optimization.lazy' -Section Optimization -Title 'Apply does nothing' -Test { $false } -Apply { }
    $lz = Invoke-AVDTuneStep -Step $lazy -Machine $m -Mode Apply
    Test-Check 'Failed when the test still fails after Apply' ($lz.Status -eq 'Failed' -and $lz.Message -like '*still fails*') $lz.Message
    $boom = New-AVDTuneStep -Id 'optimization.boom' -Section Optimization -Title 'Throws' -Test { $false } -Apply { throw 'nope' }
    $bm = Invoke-AVDTuneStep -Step $boom -Machine $m -Mode Apply
    Test-Check 'an exception becomes Failed with the message' ($bm.Status -eq 'Failed' -and $bm.Message -eq 'nope') $bm.Message
    $badTest = New-AVDTuneStep -Id 'optimization.badtest' -Section Optimization -Title 'x' -Test { 'text' } -Apply { }
    Test-Check 'a test that returns something else is Failed' ((Invoke-AVDTuneStep -Step $badTest -Machine $m -Mode Test).Status -eq 'Failed') $null
    Test-Check 'step contract validation (id, section, https source)' ((Test-Throws { New-AVDTuneStep -Id 'Bad Id' -Section Optimization -Title 'x' -Test { $true } -Apply { } }) -and (Test-Throws { New-AVDTuneStep -Id 'a.b' -Section Nope -Title 'x' -Test { $true } -Apply { } }) -and (Test-Throws { New-AVDTuneStep -Id 'a.b' -Section Setup -Title 'x' -SourceUrl 'http://x' -Test { $true } -Apply { } })) $null

    # ---------------------------------------------------------------- declarative steps
    $catalog = @(Get-AVDTuneStepCatalog -Path (Join-Path $PSScriptRoot 'Fixtures\steps'))
    Test-Check 'catalog reads the json steps' ($catalog.Count -eq 3 -and $catalog[0].Id -eq 'optimization.test-registry' -and $catalog[0].Reboot -eq $true) $catalog.Count
    Test-Check 'duplicate step ids are an error' (Test-Throws { Get-AVDTuneStepCatalog -Path (Join-Path $PSScriptRoot 'Fixtures\steps-duplicate') }) $null
    Test-Check 'an unknown kind and a bad registry path are refused' ((Test-Throws { New-AVDTuneStepFromData ([pscustomobject]@{ Id = 'a.b'; Section = 'Setup'; Title = 't'; Kind = 'Nope' }) }) -and (Test-Throws { New-AVDTuneStepFromData ([pscustomobject]@{ Id = 'a.b'; Section = 'Setup'; Title = 't'; Kind = 'Registry'; Path = 'C:\x'; Name = 'n'; Value = 1 }) })) $null
    $fm = New-AVDTuneFakeMachine -Seed @{ Services = @(@{ Name = 'AvdTuneTestSvc'; StartType = 'Automatic' }); Tasks = @(@{ Path = '\AVDTuneTest\'; Name = 'Nightly'; Enabled = $true }) }
    $res = @($catalog | ForEach-Object { Invoke-AVDTuneStep -Step $_ -Machine $fm -Mode Apply })
    Test-Check 'registry, service and task steps change the fake machine' ((($res | ForEach-Object { $_.Status }) -join ',') -eq 'Changed,Changed,Changed' -and (& $fm.RegGet $reg 'Flag') -eq 1 -and (& $fm.ServiceGet 'AvdTuneTestSvc').StartType -eq 'Disabled' -and -not (& $fm.TaskGet '\AVDTuneTest\' 'Nightly').Enabled) (($res | ForEach-Object { $_.Status }) -join ',')
    $res2 = @($catalog | ForEach-Object { Invoke-AVDTuneStep -Step $_ -Machine $fm -Mode Apply })
    Test-Check 'declarative steps are idempotent' ((($res2 | ForEach-Object { $_.Status }) -join ',') -eq 'Unchanged,Unchanged,Unchanged') (($res2 | ForEach-Object { $_.Status }) -join ',')
    $und = @($catalog | ForEach-Object { Invoke-AVDTuneStep -Step $_ -Machine $fm -Mode Undo })
    Test-Check 'declarative undo restores service and task and removes the value' ((($und | ForEach-Object { $_.Status }) -join ',') -eq 'Reverted,Reverted,Reverted' -and $null -eq (& $fm.RegGet $reg 'Flag') -and (& $fm.ServiceGet 'AvdTuneTestSvc').StartType -eq 'Automatic' -and (& $fm.TaskGet '\AVDTuneTest\' 'Nightly').Enabled) (($und | ForEach-Object { $_.Status }) -join ',')
    $absent = New-AVDTuneFakeMachine
    Test-Check 'a service or task that is not there counts as compliant' ((Invoke-AVDTuneStep -Step $catalog[1] -Machine $absent -Mode Apply).Status -eq 'Unchanged' -and (Invoke-AVDTuneStep -Step $catalog[2] -Machine $absent -Mode Apply).Status -eq 'Unchanged') $null

    # ---------------------------------------------------------------- plans
    $pm = New-AVDTuneFakeMachine -Seed @{ Services = @(@{ Name = 'AvdTuneTestSvc'; StartType = 'Automatic' }); Tasks = @(@{ Path = '\AVDTuneTest\'; Name = 'Nightly'; Enabled = $true }); Now = [datetime]'2026-11-20T10:00:00' }
    $plan = [pscustomobject]@{ Name = 'check plan'; Steps = @('optimization.test-registry', 'optimization.test-service') }
    $runsBefore = @(Get-AVDTuneRun -Root $tmp).Count
    $dry = Invoke-AVDTune -Plan $plan -Catalog $catalog -Machine $pm -Root $tmp -WhatIf
    Test-Check 'plan -WhatIf: nothing changed, no run, no change log entry' ((($dry.Results | ForEach-Object { $_.Status }) -join ',') -eq 'WhatIf,WhatIf' -and $pm.Log.Count -eq 0 -and @(Get-AVDTuneRun -Root $tmp).Count -eq $runsBefore -and @(Get-AVDTuneChangeLog -Root $tmp).Count -eq 0) (($dry.Results | ForEach-Object { $_.Status }) -join ',')
    $run = Invoke-AVDTune -Plan $plan -Catalog $catalog -Machine $pm -Root $tmp -User 'admin1' -SnapshotId 'snap-1'
    $log = @(Get-AVDTuneChangeLog -Root $tmp)
    Test-Check 'plan: both steps changed, one run record, reboot noted' ((($run.Results | ForEach-Object { $_.Status }) -join ',') -eq 'Changed,Changed' -and $run.Reboot -and @(Get-AVDTuneRun -Root $tmp).Count -eq $runsBefore + 1 -and (Get-AVDTuneState $tmp).LastRunId -eq $run.Id) (($run.Results | ForEach-Object { $_.Status }) -join ',')
    Test-Check 'plan: an automatic change log entry per change, with version, run, user and snapshot' ($log.Count -eq 2 -and $log[0].Source -eq 'Step' -and $log[0].Version -eq '2026.11.003' -and $log[0].RunId -eq $run.Id -and $log[0].User -eq 'admin1' -and $log[0].SnapshotId -eq 'snap-1' -and $log[0].Category -eq 'Optimization') ($log.Count)
    $run2 = Invoke-AVDTune -Plan $plan -Catalog $catalog -Machine $pm -Root $tmp -User 'admin1'
    Test-Check 'plan again: all unchanged, no new change log entry' ((($run2.Results | ForEach-Object { $_.Status }) -join ',') -eq 'Unchanged,Unchanged' -and @(Get-AVDTuneChangeLog -Root $tmp).Count -eq 2) (($run2.Results | ForEach-Object { $_.Status }) -join ',')
    $failCatalog = @($lazy, $step, $catalog[0])
    $stopRun = Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'stop'; Steps = @('optimization.lazy', 'optimization.flag') }) -Catalog $failCatalog -Machine (New-AVDTuneFakeMachine) -Root $tmp
    Test-Check 'plan stops at the first failed step, the rest is Skipped' ((($stopRun.Results | ForEach-Object { $_.Status }) -join ',') -eq 'Failed,Skipped') (($stopRun.Results | ForEach-Object { $_.Status }) -join ',')
    Test-Check 'a plan with an unknown step is refused before anything runs' (Test-Throws { Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'x'; Steps = @('nope.nope') }) -Catalog $catalog -Machine $pm -Root $tmp }) $null
    $planFile = Join-Path $tmp 'plan.json'
    [IO.File]::WriteAllText($planFile, '{ "Name": "from file", "Steps": ["optimization.test-task"] }')
    $fileRun = Invoke-AVDTune -Plan $planFile -Catalog $catalog -Machine $pm -Root $tmp -WhatIf
    Test-Check 'a plan can be a json file' ($fileRun.Plan -eq 'from file' -and @($fileRun.Results).Count -eq 1) $null

    # ---------------------------------------------------------------- change log
    $note = Add-AVDTuneChangeLogEntry -Root $tmp -Version '2026.11.003' -Category 'Software' -Component "Edge`r`n" -ChangeType Updated -Text "Edge updated`tto 141`nsecond line" -User 'admin1'
    Test-Check 'a free note is one line without control characters' ($note.Source -eq 'Note' -and $note.Text -eq 'Edge updated to 141 second line' -and $note.Component -eq 'Edge') $note.Text
    Test-Check 'unknown change type and invalid version are refused' ((Test-Throws { Add-AVDTuneChangeLogEntry -Root $tmp -Version '2026.11.003' -Category 'x' -ChangeType Nope -Text 'x' }) -and (Test-Throws { Add-AVDTuneChangeLogEntry -Root $tmp -Version 'v1' -Category 'x' -ChangeType Note -Text 'x' })) $null
    $long = Add-AVDTuneChangeLogEntry -Root $tmp -Version '2026.12.001' -Category 'Other' -ChangeType Note -Text ('y' * 900)
    Test-Check 'a long text is cut at 500 characters' ($long.Text.Length -eq 500 -and $long.Text.EndsWith('...')) $long.Text.Length
    Test-Check 'entries are filtered per version' (@(Get-AVDTuneChangeLog -Root $tmp -Version '2026.11.003').Count -eq 3 -and @(Get-AVDTuneChangeLog -Root $tmp -Version '2026.12.001').Count -eq 1) $null
    Test-Check 'versions list: newest first, with started versions' ((@(Get-AVDTuneChangeLogVersions -Root $tmp) -join ',') -eq '2026.12.001,2026.11.003,2026.11.002,2026.11.001') (@(Get-AVDTuneChangeLogVersions -Root $tmp) -join ',')
    [void](Add-AVDTuneChangeLogEntry -Root $tmp -Version '2026.12.001' -Category 'Other' -Component '<script>alert(1)</script>' -ChangeType Note -Text 'a | b & c')
    $md = ConvertTo-AVDTuneChangeLogDocument -Root $tmp -Version '2026.12.001' -Format Markdown -ImageName 'GM-TEST01'
    Test-Check 'markdown export: title, header, escaped pipe' ($md -like '# Change log GM-TEST01 2026.12.001*' -and $md -like '*| Date | Category | Component | Change | Text | User |*' -and $md -like '*a \| b & c*') $null
    $html = ConvertTo-AVDTuneChangeLogDocument -Root $tmp -Version '2026.12.001' -Format Html
    Test-Check 'html export encodes all text' ($html -like '*&lt;script&gt;alert(1)&lt;/script&gt;*' -and $html -notlike '*<script>*' -and $html -like '*a | b &amp; c*') $null
    Test-Check 'an empty version exports "No entries."' ((ConvertTo-AVDTuneChangeLogDocument -Root $tmp -Version '2030.01.001') -like '*No entries.*') $null
    $exp = Export-AVDTuneChangeLog -Root $tmp -Version '2026.11.003' -Path (Join-Path $tmp 'out\log.html')
    $expMd = Export-AVDTuneChangeLog -Root $tmp -Version '2026.11.003' -Path (Join-Path $tmp 'out\log.md')
    Test-Check 'export picks the format from the extension and writes files' ((Get-Content $exp -Raw) -like '<!DOCTYPE html>*' -and (Get-Content $expMd -Raw) -like '# Change log*') $null

    # ---------------------------------------------------------------- overview and health
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastUpdate = '2026-11-14 22:10'; UpdateBlock = 'On' })
    $ov = Get-AVDTuneOverview -Machine (New-AVDTuneFakeMachine) -Root $tmp
    Test-Check 'overview: identity from the state and the machine' ($ov.ComputerName -eq 'GM-TEST01' -and $ov.ImageVersion -eq '2026.11.003' -and $ov.LastUpdate -eq '2026-11-14 22:10' -and $ov.LastBenchmark -eq '') $ov.ImageVersion
    Test-Check 'overview: source image from the instance metadata' ($ov.SourceImage.Available -and $ov.SourceImage.Text -eq 'microsoftwindowsdesktop:office-365:win11-25h2-avd-m365:latest' -and $ov.SourceImage.ResourceGroup -eq 'rg-example' -and $ov.SourceImage.OsDisk -eq 'gm-test01_osdisk') $ov.SourceImage.Text
    Test-Check 'overview: Windows 11 multi-session build with UBR (ProductName says Windows 10)' ($ov.Windows.Name -eq 'Windows 11 Enterprise multi-session' -and $ov.Windows.FullBuild -eq '26100.4652' -and $ov.Windows.DisplayVersion -eq '25H2' -and $ov.Windows.MultiSession) $ov.Windows.Name
    Test-Check 'overview: Office build, channel from the CDN, shared licensing, updates off' ($ov.Office.Installed -and $ov.Office.Build -eq '16.0.19231.20138' -and $ov.Office.Channel -eq 'Monthly Enterprise Channel' -and $ov.Office.SharedLicensing -and $ov.Office.UpdatesEnabled -eq $false -and $ov.Office.Platform -eq 'x64') $ov.Office.Channel
    $health = @{}; foreach ($h in $ov.Health) { $health[$h.Id] = $h.Status }
    Test-Check 'health: clean master is ok (no restart, block on, no agent, no join)' ($health.reboot -eq 'ok' -and $health.updateblock -eq 'ok' -and $health.avdagent -eq 'ok' -and $health.join -eq 'ok' -and $health.sealed -eq 'info') (Join-Pairs $health)
    $dirty = New-AVDTuneFakeMachine -Seed @{
        Keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'); Services = @(@{ Name = 'RDAgentBootLoader' })
        Native = @{ 'dsregcmd.exe /status' = @{ ExitCode = 0; Output = "    AzureAdJoined : YES`r`n    DomainJoined : YES`r`n" } }
    }
    $ovd = Get-AVDTuneOverview -Machine $dirty -Root $tmp
    $hd = @{}; foreach ($h in $ovd.Health) { $hd[$h.Id] = $h }
    Test-Check 'health: pending restart is a warning' ($hd.reboot.Status -eq 'warn' -and $hd.reboot.Detail -like '*servicing*') $hd.reboot.Detail
    Test-Check 'health: AVD agent and joins are bad' ($hd.avdagent.Status -eq 'bad' -and $hd.join.Status -eq 'bad' -and $hd.join.Detail -like '*Microsoft Entra ID and a domain*') $hd.join.Detail
    $rename = New-AVDTuneFakeMachine -Seed @{ Registry = @{ 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager|PendingFileRenameOperations' = @('a', 'b') }; Keys = @('HKLM:\SOFTWARE\Microsoft\RDInfraAgent'); Native = @{ 'dsregcmd.exe /status' = @{ ExitCode = 1; Output = '' } } }
    $hr = @{}; foreach ($h in (Get-AVDTuneOverview -Machine $rename -Root $tmp).Health) { $hr[$h.Id] = $h.Status }
    Test-Check 'health: pending file operations, agent key only, unreadable join state' ($hr.reboot -eq 'warn' -and $hr.avdagent -eq 'bad' -and $hr.join -eq 'warn') (Join-Pairs $hr)
    [void](Set-AVDTuneState -Root $tmp -Values @{ UpdateBlock = 'Off'; Sealed = $true })
    $hs = @{}; foreach ($h in (Get-AVDTuneOverview -Machine (New-AVDTuneFakeMachine) -Root $tmp).Health) { $hs[$h.Id] = $h }
    Test-Check 'health: block off is a warning, finished is shown' ($hs.updateblock.Status -eq 'warn' -and $hs.sealed.Detail -like 'Finished*') $null
    $gallery = New-AVDTuneFakeMachine -Seed @{ Imds = [pscustomobject]@{ compute = [pscustomobject]@{ name = 'vm1'; storageProfile = [pscustomobject]@{ imageReference = [pscustomobject]@{ id = '/subscriptions/s/resourceGroups/g/providers/Microsoft.Compute/galleries/gal/images/win11-avd/versions/2026.11.1' } } } } }
    Test-Check 'source image: a gallery image shows its version name' ((Get-AVDTuneSourceImage $gallery).Text -eq '2026.11.1') (Get-AVDTuneSourceImage $gallery).Text
    $noAzure = New-AVDTuneFakeMachine -Seed @{ Imds = $null; Registry = @{ 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration|VersionToReport' = $null } }
    $ovn = Get-AVDTuneOverview -Machine $noAzure -Root $tmp
    Test-Check 'outside Azure and without Office the overview still works' (-not $ovn.SourceImage.Available -and -not $ovn.Office.Installed) $null

    # ---------------------------------------------------------------- HTTP error answers are responses, not "no connection" (#28)
    # A local TCP server answers 400 with an ARM-style error body; the HttpWebRequest error reaches PowerShell wrapped like in the adapters
    $listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, 0); $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $errJson = '{"error":{"code":"InvalidParameter","message":"Test reason from Azure"}}'
    $srv = [PowerShell]::Create()
    [void]$srv.AddScript({
        param($L, $Json)
        $c = $L.AcceptTcpClient(); $s = $c.GetStream(); $buf = New-Object byte[] 4096; $seen = ''
        while ($seen -notmatch "`r`n`r`n") { $n = $s.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $seen += [Text.Encoding]::ASCII.GetString($buf, 0, $n) }
        $body = [Text.Encoding]::UTF8.GetBytes($Json)
        $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 400 Bad Request`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
        $s.Write($head, 0, $head.Length); $s.Write($body, 0, $body.Length); $s.Flush(); $c.Close()
    }).AddArgument($listener).AddArgument($errJson)
    $srvRun = $srv.BeginInvoke()
    $wrapped = $null
    try { $rq = [Net.HttpWebRequest]::Create("http://127.0.0.1:$port/subscriptions/x"); $rq.Timeout = 10000; $rq.GetResponse().Close() } catch { $wrapped = $_.Exception }
    [void]$srv.EndInvoke($srvRun); $srv.Dispose(); $listener.Stop()
    $wr = Get-AVDTuneWebResponse $wrapped
    $wrText = $null; if ($wr) { try { $wrText = (New-Object IO.StreamReader($wr.GetResponseStream())).ReadToEnd() } finally { $wr.Close() } }
    Test-Check 'a 400 answer is found behind the wrapping exception (status and Azure error body), the outer exception has no Response' ($null -ne $wrapped -and $null -eq (Get-AVDTuneProp $wrapped 'Response') -and $wr -and [int]$wr.StatusCode -eq 400 -and $wrText -eq $errJson) $(if ($wrapped) { $wrapped.GetType().FullName })
    $closed = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, 0); $closed.Start(); $closedPort = ([Net.IPEndPoint]$closed.LocalEndpoint).Port; $closed.Stop()
    $noConn = $null
    try { $rq = [Net.HttpWebRequest]::Create("http://127.0.0.1:$closedPort/"); $rq.Timeout = 5000; $rq.GetResponse().Close() } catch { $noConn = $_.Exception }
    Test-Check 'no answer at all stays "no connection" (no response found)' ($null -ne $noConn -and $null -eq (Get-AVDTuneWebResponse $noConn)) $null
    $adapterSources = (Get-Content -Raw (Join-Path $repo 'Modules\AVDTune.Snapshot.psm1')) + (Get-Content -Raw (Join-Path $repo 'Modules\AVDTune.Storage.psm1'))
    Test-Check 'the ARM and the Files adapter read error answers through Get-AVDTuneWebResponse, not from the outer exception' (([regex]::Matches($adapterSources, 'Get-AVDTuneWebResponse \$_\.Exception')).Count -eq 2 -and $adapterSources -notmatch "Get-AVDTuneProp \`$_\.Exception 'Response'") $null

    # ---------------------------------------------------------------- no lone CR in any script (#35)
    # PowerShell ends a line at a lone CR that editors and git do not show: a method chain split there runs as two statements
    # (AVDTune-Readiness.ps1 lost the last two AddArgument calls; the real start failed, the test mode runs that path inline)
    $loneCr = @(Get-ChildItem -LiteralPath $repo -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' | Where-Object { $_.FullName -notmatch '\\\.git\\' } |
        Where-Object { [regex]::IsMatch([IO.File]::ReadAllText($_.FullName), "`r(?!`n)") } | ForEach-Object { $_.FullName.Substring($repo.Length + 1) })
    Test-Check 'no script contains a lone CR (it splits a statement for PowerShell but not in the editor)' ($loneCr.Count -eq 0) ($loneCr -join ', ')

    # ---------------------------------------------------------------- what a GetNewClosure block cannot see (#78)
    # GetNewClosure binds the block to a new dynamic module: $script:X there is that module's (empty) variable, not the one of the file, and the functions
    # a module does not export are not found at all. The winget/choco lock read $script:LockNames that way and took no mutex. Rules per closure block
    # (direct {...}.GetNewClosure() and $b = {...}; $b.GetNewClosure()): no $script: variable, no $using:, no *-Variable -Scope Script, no call of a
    # function the module defines but does not export. Values go into a local variable before GetNewClosure; private functions are exported or inlined.
    function Get-ClosureFinding {
        param([System.Management.Automation.Language.Ast]$Ast, [bool]$IsModule)
        $A = 'System.Management.Automation.Language'
        $private = @()
        if ($IsModule) {
            $defined = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name } | Select-Object -Unique)
            $exports = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Export-ModuleMember' }, $true))
            if ($exports.Count -eq 0) { $exported = $defined }
            else {
                $exported = @()
                foreach ($e in $exports) {
                    $el = @($e.CommandElements)
                    for ($i = 1; $i -lt $el.Count; $i++) {
                        if ($el[$i] -is "$A.CommandParameterAst" -and 'Function' -like ($el[$i].ParameterName + '*')) {
                            $arg = $el[$i].Argument; if (-not $arg -and $i + 1 -lt $el.Count) { $arg = $el[$i + 1] }
                            if ($arg) { $exported += @($arg.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value }) }
                        }
                    }
                }
            }
            $private = @($defined | Where-Object { $d = $_; -not @($exported | Where-Object { $d -like $_ }).Count })
        }
        $out = @(); $count = 0
        foreach ($call in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Extent.Text -eq 'GetNewClosure' }, $true)) {
            $count++
            $blocks = @()
            if ($call.Expression -is "$A.ScriptBlockExpressionAst") { $blocks = @($call.Expression) }
            elseif ($call.Expression -is "$A.VariableExpressionAst" -and -not $call.Expression.VariablePath.IsScript) {
                # $b = {...}; $b.GetNewClosure(): every block assigned to $b in the same function (or file)
                $name = $call.Expression.VariablePath.UserPath
                $scope = $call.Parent; while ($scope -and $scope -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $scope = $scope.Parent }; if (-not $scope) { $scope = $Ast }
                foreach ($as in $scope.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -eq $name }, $true)) {
                    $r = $as.Right; if ($r -is "$A.PipelineAst" -and @($r.PipelineElements).Count -eq 1) { $r = $r.PipelineElements[0] }
                    if ($r -is "$A.CommandExpressionAst" -and $r.Expression -is "$A.ScriptBlockExpressionAst") { $blocks += $r.Expression }
                }
            }
            if ($blocks.Count -eq 0) { $out += [pscustomobject]@{ Rule = 'unresolved'; Line = $call.Extent.StartLineNumber; Text = $call.Expression.Extent.Text }; continue }
            foreach ($b in $blocks) {
                $inner = @($b.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
                foreach ($n in $b.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] -and $x.VariablePath.IsScript }, $true)) { $out += [pscustomobject]@{ Rule = 'script'; Line = $n.Extent.StartLineNumber; Text = $n.Extent.Text } }
                foreach ($n in $b.FindAll({ param($x) $x -is [System.Management.Automation.Language.UsingExpressionAst] }, $true)) { $out += [pscustomobject]@{ Rule = 'using'; Line = $n.Extent.StartLineNumber; Text = $n.Extent.Text } }
                foreach ($c in $b.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                    $cn = [string]$c.GetCommandName()
                    if ($cn -in 'Get-Variable', 'Set-Variable', 'New-Variable', 'Remove-Variable', 'Clear-Variable', 'gv', 'sv', 'nv', 'rv', 'clv') {
                        $el = @($c.CommandElements)
                        for ($i = 1; $i -lt $el.Count; $i++) {
                            if ($el[$i] -is "$A.CommandParameterAst" -and $el[$i].ParameterName.Length -ge 2 -and 'Scope' -like ($el[$i].ParameterName + '*')) {
                                $arg = $el[$i].Argument; if (-not $arg -and $i + 1 -lt $el.Count) { $arg = $el[$i + 1] }
                                if ($arg -and $arg.Extent.Text.Trim('''', '"') -eq 'Script') { $out += [pscustomobject]@{ Rule = 'scope'; Line = $c.Extent.StartLineNumber; Text = $c.Extent.Text } }
                            }
                        }
                    }
                    elseif ($cn -and $cn -in $private -and $cn -notin $inner) { $out += [pscustomobject]@{ Rule = 'private'; Line = $c.Extent.StartLineNumber; Text = $cn } }
                }
            }
        }
        [pscustomobject]@{ Count = $count; Findings = $out }
    }
    $closureFindings = @(); $closureCount = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $repo -Recurse -File -Include '*.ps1', '*.psm1' | Where-Object { $_.FullName -notmatch '\\\.git\\' })) {
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$parseErrors)
        $res = Get-ClosureFinding -Ast $ast -IsModule ($f.Extension -eq '.psm1')
        $closureCount += $res.Count
        foreach ($x in $res.Findings) { $closureFindings += '{0}:{1} {2} {3}' -f $f.FullName.Substring($repo.Length + 1), $x.Line, $x.Rule, $x.Text }
    }
    Test-Check 'no GetNewClosure block reads $script:/$using: variables, uses -Scope Script or calls a function its module does not export (#78)' ($closureFindings.Count -eq 0 -and $closureCount -gt 50) "closures found: $closureCount; $($closureFindings -join ' | ')"
    # each rule turns red on a small example (and a clean example stays green)
    $sample = {
        param([string]$Source, [bool]$IsModule)
        $tk = $null; $pe = $null
        @((Get-ClosureFinding -Ast ([System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tk, [ref]$pe)) -IsModule $IsModule).Findings | ForEach-Object { $_.Rule })
    }
    $ruleCases = @(
        @{ N = 'script'; S = 'function F { { $script:LockNames }.GetNewClosure() }'; M = $false; E = 'script' }
        @{ N = 'using'; S = 'function F { { $using:x }.GetNewClosure() }'; M = $false; E = 'using' }
        @{ N = 'Get-Variable -Scope Script'; S = 'function F { { Get-Variable LockNames -Scope Script -ValueOnly }.GetNewClosure() }'; M = $false; E = 'scope' }
        @{ N = 'Set-Variable -Scope:Script'; S = 'function F { { Set-Variable -Name x -Value 1 -Scope:Script }.GetNewClosure() }'; M = $false; E = 'scope' }
        @{ N = 'closure over a variable'; S = 'function F { $b = { $script:x }; $b.GetNewClosure() }'; M = $false; E = 'script' }
        @{ N = 'private function with digits'; S = "function Get-AVDTuneBytesSha256 { 1 }`nfunction Get-Pub { { Get-AVDTuneBytesSha256 }.GetNewClosure() }`nExport-ModuleMember -Function Get-Pub"; M = $true; E = 'private' }
        @{ N = 'private function in a closure over a variable'; S = "function Get-Priv2 { 1 }`nfunction Get-Pub { `$b = { Get-Priv2 }; `$b.GetNewClosure() }`nExport-ModuleMember -Function Get-Pub, Get-Other"; M = $true; E = 'private' }
        @{ N = 'clean: exported function, local value, -Scope Local'; S = "function Get-Pub2 { 1 }`nfunction Get-Pub { `$n = `$script:x; { Get-Pub2; `$n; Get-Variable n -Scope Local }.GetNewClosure() }`nExport-ModuleMember -Function Get-Pub, Get-Pub2"; M = $true; E = '' }
        @{ N = 'clean: no Export-ModuleMember exports everything'; S = "function Get-A1 { 1 }`nfunction Get-B { { Get-A1 }.GetNewClosure() }"; M = $true; E = '' }
    )
    $wrongRule = @($ruleCases | Where-Object { ((& $sample $_.S $_.M) -join ',') -ne $_.E } | ForEach-Object { "$($_.N): got '$((& $sample $_.S $_.M) -join ',')'" })
    Test-Check 'closure rules (#78): each rule finds its example ($script:, $using:, -Scope Script, closure over a variable, private function also with digits), clean examples stay green' ($wrongRule.Count -eq 0) ($wrongRule -join ' | ')
    # the transitional lock name is PackTune's (Global\IntuneChocoDeployment); the old wrong spelling must not come back anywhere
    $wrongLock = 'Global\IntuneChoco' + 'latey' + 'Deployment'
    $wrongLockHits = @(Get-ChildItem -LiteralPath $repo -Recurse -File -Include '*.ps1', '*.psm1', '*.md', '*.json', '*.xaml' | Where-Object { $_.FullName -notmatch '\\\.git\\' } | Where-Object { ([IO.File]::ReadAllText($_.FullName)).IndexOf($wrongLock, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | ForEach-Object { $_.FullName.Substring($repo.Length + 1) })
    Test-Check 'lock (#78): no file names the transitional mutex wrongly (PackTune uses Global\IntuneChocoDeployment)' ($wrongLockHits.Count -eq 0) ($wrongLockHits -join ', ')

    # ---------------------------------------------------------------- module path only from the system folders (#73)
    $winDir = [Environment]::GetFolderPath('Windows'); $pfDir = [Environment]::GetFolderPath('ProgramFiles')
    $sysModules = (Join-Path $winDir 'System32\WindowsPowerShell\v1.0\Modules') + ';' + (Join-Path $pfDir 'WindowsPowerShell\Modules')
    $keepPf = $env:ProgramFiles
    try { $env:ProgramFiles = 'C:\evil-programfiles'; $modPath = Get-AVDTuneSystemModulePath } finally { $env:ProgramFiles = $keepPf }
    Test-Check 'module path (#73): System32 first, then Program Files, from the Windows folders (an evil $env:ProgramFiles is not used), no Documents folder' ($modPath -eq $sysModules -and $modPath -notlike '*evil*' -and $modPath.IndexOf([Environment]::GetFolderPath('MyDocuments'), [StringComparison]::OrdinalIgnoreCase) -lt 0) $modPath
    Test-Check 'module path (#73): the child environment of every tool has exactly this module path' (@('base', 'winget', 'choco', 'msiexec', 'bench', 'office', 'apps' | Where-Object { (Get-AVDTuneChildEnvironment -Tool $_ -TempDir 'C:\x')['PSModulePath'] -ne $sysModules }).Count -eq 0) $null
    # the folders of the path: real ones are admin-only; a prepared folder (write for Users, link) is found; the walk stops at the Windows / Program Files folder
    $realModProblems = @(Get-AVDTuneModulePathProblems)
    Test-Check 'module path (#73): the real module folders and the folders above them are admin-only on this computer' ($realModProblems.Count -eq 0) ($realModProblems -join ' | ')
    $readPaths = New-Object System.Collections.ArrayList
    $okReport = { param($Path) [void]$readPaths.Add($Path); [pscustomobject]@{ Exists = $true; Link = $false; Owner = 'S-1-5-32-544'; Protected = $true; Rules = @([pscustomobject]@{ Sid = 'S-1-5-32-545'; Write = $false; Inherited = $false; InheritOnly = $false }) } }.GetNewClosure()
    $cleanProblems = @(Get-AVDTuneModulePathProblems -ReadAcl $okReport)
    $pfPs = Join-Path $pfDir 'WindowsPowerShell'
    $usersWrite = { param($Path) $w = ($Path -eq $pfPs); [pscustomobject]@{ Exists = $true; Link = $false; Owner = 'S-1-5-32-544'; Protected = $true; Rules = @([pscustomobject]@{ Sid = 'S-1-5-32-545'; Write = $w; Inherited = $false; InheritOnly = $false }) } }.GetNewClosure()
    $s32Mod = Join-Path $winDir 'System32\WindowsPowerShell\v1.0\Modules'
    $linked = { param($Path) [pscustomobject]@{ Exists = $true; Link = ($Path -eq $s32Mod); Owner = 'S-1-5-32-544'; Protected = $true; Rules = @() } }.GetNewClosure()
    $writeProblems = @(Get-AVDTuneModulePathProblems -ReadAcl $usersWrite); $linkProblems = @(Get-AVDTuneModulePathProblems -ReadAcl $linked)
    Test-Check 'module path (#73): a parent folder with write for Users and a module folder that is a link are problems; the walk reads up to the Windows and Program Files folder, not the drive root' ($cleanProblems.Count -eq 0 -and $writeProblems.Count -eq 1 -and $writeProblems[0] -like "${pfPs}: write access for S-1-5-32-545" -and $linkProblems.Count -eq 1 -and $linkProblems[0] -like "${s32Mod}: is a link" -and @($readPaths).Count -eq 8 -and $readPaths -contains $winDir -and $readPaths -contains $pfDir -and -not ($readPaths -contains [IO.Path]::GetPathRoot($winDir))) "$($writeProblems -join ' | ') / $($linkProblems -join ' | ') / $($readPaths -join ', ')"
    $startSrc = [IO.File]::ReadAllText((Join-Path $repo 'Start-AVDTune.ps1'))
    Test-Check 'module path (#73): Start-AVDTune.ps1 stops with shell.err.modulepath when a module folder is not admin-only' ($startSrc -match '\$modulePathProblems = @\(Get-AVDTuneModulePathProblems\)\r?\nif \(\$modulePathProblems\.Count -gt 0\) \{ Stop-WithMessage \(T ''shell\.err\.modulepath''') $null

    # source: the first two commands of Start-AVDTune.ps1 load AVDTune.psm1 and set the path; every runspace is created by the two functions of AVDTune.psm1
    $tk = $null; $pe = $null
    $startAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Start-AVDTune.ps1'), [ref]$tk, [ref]$pe)
    $firstCmds = @($startAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 2)
    Test-Check 'module path (#73): Start-AVDTune.ps1 runs Import-Module AVDTune.psm1 and then Set-AVDTuneSafeModulePath before any other command' ($firstCmds.Count -eq 2 -and $firstCmds[0].GetCommandName() -eq 'Import-Module' -and $firstCmds[0].Extent.Text -like '*AVDTune.psm1*' -and $firstCmds[1].GetCommandName() -eq 'Set-AVDTuneSafeModulePath') (($firstCmds | ForEach-Object { $_.Extent.Text }) -join ' | ')
    function Get-RunspaceCreation {
        # [powershell]::Create*, [runspacefactory]::* (any spelling of the type) outside New-AVDTunePowerShell / New-AVDTuneRunspacePool of AVDTune.psm1
        param([System.Management.Automation.Language.Ast]$Ast, [bool]$IsCore)
        $out = @(); $ok = 0
        foreach ($m in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Static -and $n.Expression -is [System.Management.Automation.Language.TypeExpressionAst] }, $true)) {
            $t = $m.Expression.TypeName.FullName -as [type]
            $member = [string]$m.Member.Extent.Text
            $hit = ($t -eq [System.Management.Automation.PowerShell] -and $member -like 'Create*') -or ($t -eq [System.Management.Automation.Runspaces.RunspaceFactory])
            if (-not $hit) { continue }
            $fn = $m.Parent; while ($fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
            if ($IsCore -and $fn -and $fn.Name -in 'New-AVDTunePowerShell', 'New-AVDTuneRunspacePool') { $ok++; continue }
            $out += '{0} {1}' -f $m.Extent.StartLineNumber, $m.Extent.Text
        }
        [pscustomobject]@{ Findings = $out; Central = $ok }
    }
    $rsFindings = @(); $rsCentral = 0; $rsUses = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $repo -Recurse -File -Include '*.ps1', '*.psm1' | Where-Object { $_.FullName -notmatch '\\(\.git|Tests)\\' })) {
        $tk = $null; $pe = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tk, [ref]$pe)
        $res = Get-RunspaceCreation -Ast $ast -IsCore ($f.FullName -eq (Join-Path $repo 'Modules\AVDTune.psm1'))
        $rsCentral += $res.Central
        foreach ($x in $res.Findings) { $rsFindings += '{0}:{1}' -f $f.FullName.Substring($repo.Length + 1), $x }
        $rsUses += @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'New-AVDTunePowerShell', 'New-AVDTuneRunspacePool' }, $true)).Count
    }
    Test-Check 'module path (#73): no script creates a runspace itself; workers come from New-AVDTunePowerShell / New-AVDTuneRunspacePool (source, Tests excluded)' ($rsFindings.Count -eq 0 -and $rsCentral -eq 2 -and $rsUses -ge 18) "central $rsCentral, uses $rsUses; $($rsFindings -join ' | ')"
    $rsSample = { param([string]$Source, [bool]$IsCore) $tk = $null; $pe = $null; @((Get-RunspaceCreation -Ast ([System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tk, [ref]$pe)) -IsCore $IsCore).Findings).Count }
    $rsCases = @(
        @{ S = 'function F { [powershell]::Create() }'; C = $false; E = 1 }
        @{ S = 'function F { [System.Management.Automation.PowerShell]::Create([System.Management.Automation.RunspaceMode]::NewRunspace) }'; C = $false; E = 1 }
        @{ S = '$p = [runspacefactory]::CreateRunspacePool(1, 4)'; C = $false; E = 1 }
        @{ S = '[System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()'; C = $false; E = 1 }
        @{ S = 'function New-AVDTunePowerShell { [powershell]::Create() }'; C = $false; E = 1 }
        @{ S = 'function New-AVDTunePowerShell { [powershell]::Create() }'; C = $true; E = 0 }
        @{ S = '[Security.Cryptography.SHA256]::Create(); New-AVDTunePowerShell'; C = $false; E = 0 }
    )
    $rsWrong = @($rsCases | Where-Object { (& $rsSample $_.S $_.C) -ne $_.E } | ForEach-Object { $_.S })
    Test-Check 'module path (#73): the runspace rule finds each spelling ([powershell], full type name, [runspacefactory], pool) and allows only the two functions of AVDTune.psm1' ($rsWrong.Count -eq 0) ($rsWrong -join ' | ')

    # counter-test in fresh processes: a module named ScheduledTasks in a user module folder (temp, never the real Documents) in front of the system folders
    $modTmp = Join-Path $tmp 'modpath'
    $fakeMods = Join-Path $modTmp 'UserModules'
    [void](New-Item -ItemType Directory -Path (Join-Path $fakeMods 'ScheduledTasks') -Force)
    [IO.File]::WriteAllText((Join-Path $fakeMods 'ScheduledTasks\ScheduledTasks.psm1'), 'function Get-ScheduledTask { [IO.File]::AppendAllText($env:AVDTUNE_TEST_MARKER, "loaded`r`n"); @() }' + "`r`n")
    # and the built-in cmdlets AVDTune.psm1 uses while it loads (Join-Path, Add-Type): Windows PowerShell takes them from its own folder, never from the module path
    foreach ($core in 'Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Utility') {
        [void](New-Item -ItemType Directory -Path (Join-Path $fakeMods $core) -Force)
        [IO.File]::WriteAllText((Join-Path $fakeMods "$core\$core.psm1"), '[IO.File]::AppendAllText($env:AVDTUNE_TEST_MARKER, "core`r`n")' + "`r`n")
    }
    $childScript = Join-Path $modTmp 'child.ps1'
    [IO.File]::WriteAllText($childScript, @'
param([string]$Mode, [string]$Module)
$ErrorActionPreference = 'Stop'
$probe = { [void](Get-ScheduledTask -TaskPath '\AVDTune-no-such-path\' -ErrorAction SilentlyContinue) }
if ($Mode -eq 'load') { Import-Module $Module -Force; 'MODULES=' + ((Get-Module | Where-Object { $_.Name -ne 'AVDTune' -and -not ($_.Name -like 'Microsoft.PowerShell.*' -and $_.ModuleBase -eq $PSHOME) } | ForEach-Object { $_.Name + '@' + $_.ModuleBase } | Sort-Object) -join ','); return }
if ($Mode -eq 'red') { & $probe; $ps = [powershell]::Create(); [void]$ps.AddScript($probe.ToString()); [void]$ps.Invoke(); $ps.Dispose(); 'PATH=' + $env:PSModulePath; return }
Import-Module $Module -Force
[void](Set-AVDTuneSafeModulePath)
& $probe
$ps = New-AVDTunePowerShell; [void]$ps.AddScript($probe.ToString()); [void]$ps.Invoke(); $ps.Dispose()
$pool = New-AVDTuneRunspacePool -Min 1 -Max 2; $pool.Open()
try { $ps = [powershell]::Create(); $ps.RunspacePool = $pool; [void]$ps.AddScript($probe.ToString()); [void]$ps.Invoke(); $ps.Dispose() } finally { $pool.Dispose() }
$iss = [initialsessionstate]::CreateDefault(); $rs = [runspacefactory]::CreateRunspace($iss); $rs.Open()
try { $ps = [powershell]::Create(); $ps.Runspace = $rs; [void]$ps.AddScript($probe.ToString()); [void]$ps.Invoke(); $ps.Dispose() } finally { $rs.Dispose() }
'PATH=' + $env:PSModulePath
'@)
    $psExe = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $runChild = {
        param([string]$Mode, [string]$Marker, $Environment)
        $psi = New-Object System.Diagnostics.ProcessStartInfo $psExe
        $psi.Arguments = (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $childScript, $Mode, (Join-Path $repo 'Modules\AVDTune.psm1')) | ForEach-Object { ConvertTo-AVDTuneArgument $_ }) -join ' '
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        if ($Environment) { $psi.EnvironmentVariables.Clear(); foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[$k] = [string]$Environment[$k] } }
        else { $psi.EnvironmentVariables['PSModulePath'] = "$fakeMods;$pfDir\WindowsPowerShell\Modules;$winDir\System32\WindowsPowerShell\v1.0\Modules"; $psi.EnvironmentVariables['AVDTUNE_TEST_MARKER'] = $Marker }
        $p = [System.Diagnostics.Process]::Start($psi)
        $errTask = $p.StandardError.ReadToEndAsync(); $out = $p.StandardOutput.ReadToEnd()
        if (-not $p.WaitForExit(120000)) { $p.Kill(); throw "child $Mode did not end" }
        [pscustomobject]@{ Exit = $p.ExitCode; Out = $out; Err = $errTask.Result; Loaded = (Test-Path -LiteralPath $Marker) }
    }.GetNewClosure()
    $red = & $runChild 'red' (Join-Path $modTmp 'red.marker') $null
    Test-Check 'module path (#73) red: without the cleanup a fresh process and a fresh runspace load the fake ScheduledTasks from the user module folder' ($red.Exit -eq 0 -and $red.Loaded -and @([IO.File]::ReadAllLines((Join-Path $modTmp 'red.marker'))).Count -eq 2) "exit $($red.Exit) loaded $($red.Loaded) $($red.Err)"
    $green = & $runChild 'green' (Join-Path $modTmp 'green.marker') $null
    Test-Check 'module path (#73): after Set-AVDTuneSafeModulePath neither the process, a worker (New-AVDTunePowerShell), a pool nor a runspace of its own loads the fake, and the path stays the system path after these opens' ($green.Exit -eq 0 -and -not $green.Loaded -and $green.Out -match ('(?m)^PATH=' + [regex]::Escape($sysModules) + '\r?$')) "exit $($green.Exit) loaded $($green.Loaded) $($green.Out) $($green.Err)"
    $load = & $runChild 'load' (Join-Path $modTmp 'load.marker') $null
    Test-Check 'module path (#73): loading AVDTune.psm1 before the path is set loads only built-in modules from $PSHOME, even with fake Microsoft.PowerShell.Management/Utility in front (Start-AVDTune.ps1 loads it first)' ($load.Exit -eq 0 -and $load.Out -match '(?m)^MODULES=\r?$' -and -not $load.Loaded) "$($load.Out) $($load.Err)"
    # a Windows PowerShell child started with the child environment (#47) gets the system path; without the variable it would start with the Documents folder
    $childEnv = Get-AVDTuneChildEnvironment -Tool base -TempDir $modTmp
    $childEnv['AVDTUNE_TEST_MARKER'] = Join-Path $modTmp 'child.marker'
    $withPath = & $runChild 'red' (Join-Path $modTmp 'child.marker') $childEnv
    $noPathEnv = [ordered]@{}; foreach ($k in $childEnv.Keys) { if ($k -ne 'PSModulePath') { $noPathEnv[$k] = $childEnv[$k] } }
    $withoutPath = & $runChild 'red' (Join-Path $modTmp 'child2.marker') $noPathEnv
    $docs = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
    Test-Check 'module path (#73): a powershell.exe child with the child environment keeps the system path; without PSModulePath Windows would put the Documents folder first (red)' ($withPath.Out -match ('(?m)^PATH=' + [regex]::Escape($sysModules) + '\r?$') -and $withoutPath.Out -match ('(?m)^PATH=' + [regex]::Escape($docs) + ';')) "$($withPath.Out) / $($withoutPath.Out) $($withPath.Err)"

    # ---------------------------------------------------------------- the real machine, read only
    $real = New-AVDTuneMachine
    $rw = Get-AVDTuneWindowsInfo $real
    Test-Check 'real adapter (read only): Windows build is readable' ($rw.Build -match '^\d+$' -and $rw.Name) $rw.Name
    Test-Check 'real adapter: a missing key and a missing service are null' ($null -eq (& $real.RegGet 'HKLM:\SOFTWARE\AVDTune-does-not-exist' 'x') -and $null -eq (& $real.ServiceGet 'AVDTune-no-such-service') -and -not (& $real.RegKeyExists 'HKLM:\SOFTWARE\AVDTune-does-not-exist')) $null
}
finally {
    $env:AVDTUNE_ROOT = $null; $env:AVDTUNE_FAKE = $null
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-AVDTune: all checks passed.'
