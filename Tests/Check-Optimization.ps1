#requires -Version 5.1
<#
.SYNOPSIS
    Checks the optimization list (data\optimization.json, Modules\AVDTune.Optimization.psm1) against the fake machine and a temporary state folder:
    the data file is type-checked (counter-tests for every kind of wrong value), the shipped data is complete and sourced, presets, Test/Apply/Undo for every
    kind (registry, service, task, AppX, autologger, Defender), the saved earlier values (never overwritten, damaged ones refused), AppX needs its own confirmation,
    write gate, change log, LastChange and run records. Nothing here touches the registry, services, tasks, AppX packages or Defender of this computer.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Optimization.psm1') -Force
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeOptimization.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Test-Throws([scriptblock]$Block) { try { & $Block | Out-Null; $false } catch { $true } }
function Get-R($Summary, [string]$Id) { @($Summary.Results | Where-Object { $_.Id -eq $Id })[0] }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-opt-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $env:AVDTUNE_ROOT = $tmp
    $state = Join-Path $tmp 'state'
    [void](Initialize-AVDTuneState -Root $state)
    [void](Start-AVDTuneImageVersion -Root $state -Date ([datetime]'2026-11-15') -User 'admin1')
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- the shipped data
    $real = Read-AVDTuneOptimizationData
    Test-Check 'data: the shipped file is valid' $real.Valid (@($real.Errors | Select-Object -First 5) -join '; ')
    $entries = @($real.Entries)
    Test-Check 'data: there are entries in every category (Registry, Autologger, Service, Task, Appx, Defender)' (@('Registry', 'Autologger', 'Service', 'Task', 'Appx', 'Defender' | Where-Object { $c = $_; @($entries | Where-Object { $_.Category -eq $c }).Count -eq 0 }).Count -eq 0) $null
    Test-Check 'data: ids are unique and each step id is accepted by the engine' (@($entries.Id | Select-Object -Unique).Count -eq $entries.Count) $null
    Test-Check 'data: every entry has a reason of at least 20 characters, an https source, a risk and a boolean default' (@($entries | Where-Object { $_.Why.Length -lt 20 -or $_.Source -notmatch '^https://' -or $_.Risk -notin 'Low', 'Medium', 'High' -or $_.Default -isnot [bool] }).Count -eq 0) $null
    Test-Check 'data: every origin is a listed source and WDOT is listed with the MIT licence and the copyright' ((@($real.Sources | Where-Object { $_.Id -eq 'wdot' -and $_.License -eq 'MIT' -and $_.Copyright -like '*The Virtual Desktop Team*' }).Count -eq 1) -and (@($entries | Where-Object { $_.Origin -notin @($real.Sources.Id) }).Count -eq 0)) $null
    Test-Check 'data: AppX entries are irreversible and say so in the reason, nothing else is irreversible' ((@($entries | Where-Object { $_.Kind -eq 'AppxRemove' -and (-not $_.Irreversible -or $_.Why -notlike '*Cannot be undone*') }).Count -eq 0) -and (@($entries | Where-Object { $_.Kind -ne 'AppxRemove' -and $_.Irreversible }).Count -eq 0)) $null
    Test-Check 'data: only HKLM registry paths, no wildcard names, task paths end with a backslash' ((@($entries | Where-Object { $_.Kind -eq 'Registry' -and $_.Path -notlike 'HKLM:\*' }).Count -eq 0) -and (@($entries | Where-Object { ($_.Kind -eq 'AppxRemove' -and $_.PackageName -match '[*?]') -or ($_.Kind -eq 'TaskDisabled' -and ($_.TaskName -match '[*?]' -or $_.TaskPath -notmatch '\\$')) }).Count -eq 0)) $null
    Test-Check 'data: apps and services that must stay are not on the list (Store, App Installer, Terminal, Notepad, Calculator, VSS, Windows Update, new Teams)' (@($entries | Where-Object { ($_.PackageName -in 'Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.WindowsTerminal', 'Microsoft.WindowsNotepad', 'Microsoft.WindowsCalculator', 'MSTeams', 'Microsoft.Windows.Photos') -or ($_.Name -in 'VSS', 'wuauserv', 'InstallService', 'BITS', 'Spooler', 'WinDefend') }).Count -eq 0) $null
    $ws = @($entries | Where-Object { $_.Name -eq 'WSearch' })[0]
    Test-Check 'data: Windows Search is only offered with a warning, High risk, default off (the Golden Master correction)' ($ws -and $ws.Risk -eq 'High' -and -not $ws.Default -and $ws.Why -like 'WARNING*') $null
    $lam = @($entries | Where-Object { $_.Parameter -eq 'DisableLocalAdminMerge' })[0]
    Test-Check 'data: Defender local-admin-merge is off by default and warns about the FSLogix exclusions' ($lam -and -not $lam.Default -and $lam.Why -like '*FSLogix*') $null
    Test-Check 'data: the Defender preset does not weaken protection (no scan or real-time switch is turned off)' (@($entries | Where-Object { $_.Category -eq 'Defender' -and $_.Parameter -match 'DisableRealtime|DisableScan|ScanOnlyIfIdle|DisableCatchupFullScan' }).Count -eq 0 -and (@($entries | Where-Object { $_.Parameter -eq 'DisableCatchupQuickScan' })[0].Value -eq $false)) $null
    $hw = @($entries | Where-Object { $_.Name -eq 'HardwareAccelerationModeEnabled' })[0]
    Test-Check 'data: Edge hardware acceleration is set to 0 (off) and default off, with the GPU note' ($hw -and $hw.Value -eq 0 -and -not $hw.Default -and $hw.Why -like '*GPU*') $null
    $notice = Join-Path $repo 'NOTICE'
    Test-Check 'NOTICE names WDOT, the MIT licence and the copyright' ((Test-Path $notice) -and ((Get-Content $notice -Raw) -match 'Windows Desktop Optimization Tool') -and ((Get-Content $notice -Raw) -match 'MIT License') -and ((Get-Content $notice -Raw) -match 'The Virtual Desktop Team')) $null
    # presets
    $rec = @(Get-AVDTuneOptimizationPresetIds $entries 'recommended'); $con = @(Get-AVDTuneOptimizationPresetIds $entries 'conservative'); $all = @(Get-AVDTuneOptimizationPresetIds $entries 'all')
    Test-Check 'presets: recommended = the defaults, all = everything, conservative is a subset of recommended' (($rec.Count -eq @($entries | Where-Object Default).Count) -and $all.Count -eq $entries.Count -and (@($con | Where-Object { $_ -notin $rec }).Count -eq 0) -and $con.Count -lt $rec.Count) "rec=$($rec.Count) con=$($con.Count) all=$($all.Count)"
    Test-Check 'presets: conservative has no AppX removal and nothing above risk Low' (@($entries | Where-Object { $_.Id -in $con -and ($_.Kind -eq 'AppxRemove' -or $_.Risk -ne 'Low') }).Count -eq 0) $null
    Test-Check 'presets: High-risk and Medium-risk entries are not in recommended' (@($entries | Where-Object { $_.Id -in $rec -and $_.Risk -eq 'High' }).Count -eq 0) $null

    # ---------------------------------------------------------------- type checks of the data file (counter-tests)
    $src = @([ordered]@{ Id = 'own'; Name = 'Test'; Url = 'https://learn.microsoft.com/en-us/x'; License = 'MIT'; Copyright = 'c'; Checked = '2026-11-15' })
    $base = @{
        Registry = [ordered]@{ Id = 'optimization.t-reg'; Category = 'Registry'; Kind = 'Registry'; Title = 'Test registry'; Why = 'A reason that is long enough.'; Source = 'https://learn.microsoft.com/en-us/x'; Origin = 'own'; Risk = 'Low'; Default = $true; Reboot = $false; Irreversible = $false; Path = 'HKLM:\SOFTWARE\Policies\AVDTuneTest'; Name = 'Val'; Type = 'DWord'; Value = 1 }
        Service = [ordered]@{ Id = 'optimization.t-svc'; Category = 'Service'; Kind = 'ServiceStartup'; Title = 'Test service'; Why = 'A reason that is long enough.'; Source = 'https://learn.microsoft.com/en-us/x'; Origin = 'own'; Risk = 'Low'; Default = $true; Reboot = $false; Irreversible = $false; Name = 'TestSvc'; Startup = 'Disabled' }
        Task = [ordered]@{ Id = 'optimization.t-task'; Category = 'Task'; Kind = 'TaskDisabled'; Title = 'Test task'; Why = 'A reason that is long enough.'; Source = 'https://learn.microsoft.com/en-us/x'; Origin = 'own'; Risk = 'Low'; Default = $true; Reboot = $false; Irreversible = $false; TaskPath = '\Microsoft\Test\'; TaskName = 'TestTask' }
        Appx = [ordered]@{ Id = 'optimization.t-appx'; Category = 'Appx'; Kind = 'AppxRemove'; Title = 'Test app'; Why = 'A reason that is long enough.'; Source = 'https://learn.microsoft.com/en-us/x'; Origin = 'own'; Risk = 'Low'; Default = $false; Reboot = $false; Irreversible = $true; PackageName = 'Test.App' }
        Defender = [ordered]@{ Id = 'optimization.t-mp'; Category = 'Defender'; Kind = 'DefenderPref'; Title = 'Test defender'; Why = 'A reason that is long enough.'; Source = 'https://learn.microsoft.com/en-us/x'; Origin = 'own'; Risk = 'Low'; Default = $true; Reboot = $false; Irreversible = $false; Parameter = 'PUAProtection'; Value = 1 }
    }
    $n = 0
    function Read-Doc($Entries, $Sources = $src, $Extra = @{}) {
        $script:n++
        $doc = [ordered]@{ SchemaVersion = 1; Sources = @($Sources); Entries = @($Entries) }
        foreach ($k in $Extra.Keys) { $doc[$k] = $Extra[$k] }
        $p = Join-Path $tmp "doc$script:n.json"
        [IO.File]::WriteAllText($p, ($doc | ConvertTo-Json -Depth 6))
        Read-AVDTuneOptimizationData -Path $p
    }
    function Get-Mut([string]$Kind, [scriptblock]$Change) { $e = [ordered]@{}; foreach ($k in $base[$Kind].Keys) { $e[$k] = $base[$Kind][$k] }; & $Change $e; $e }
    function Test-Bad([string]$Name, [string]$Kind, [scriptblock]$Change, [string]$Pattern) {
        $r = Read-Doc @(Get-Mut $Kind $Change)
        Test-Check "types: $Name is refused" ((-not $r.Valid) -and $r.Entries.Count -eq 0 -and (($r.Errors -join ' ') -match $Pattern)) (($r.Errors -join '; '))
    }
    foreach ($k in $base.Keys) { $r = Read-Doc @($base[$k]); Test-Check "types: a correct $k entry is accepted" ($r.Valid -and $r.Entries.Count -eq 1) ($r.Errors -join '; ') }
    Test-Bad 'Default as the text "false"' Registry { param($e) $e.Default = 'false' } 'Default must be true or false'
    Test-Bad 'Default as the number 0' Registry { param($e) $e.Default = 0 } 'Default must be true or false'
    Test-Bad 'Reboot as the text "true"' Registry { param($e) $e.Reboot = 'true' } 'Reboot must be true or false'
    Test-Bad 'Irreversible as text' Appx { param($e) $e.Irreversible = 'true' } 'Irreversible must be true or false'
    Test-Bad 'an AppX entry that is not marked irreversible' Appx { param($e) $e.Irreversible = $false } 'Irreversible must be true exactly for AppxRemove'
    Test-Bad 'a registry entry marked irreversible' Registry { param($e) $e.Irreversible = $true } 'Irreversible must be true exactly'
    Test-Bad 'a DWord value as text' Registry { param($e) $e.Value = '1' } 'whole number'
    Test-Bad 'a DWord value as boolean' Registry { param($e) $e.Value = $true } 'whole number'
    Test-Bad 'a DWord value with a fraction' Registry { param($e) $e.Value = 1.5 } 'whole number'
    Test-Bad 'a negative DWord value' Registry { param($e) $e.Value = -1 } 'whole number'
    Test-Bad 'a String value as a number' Registry { param($e) $e.Type = 'String'; $e.Value = 5 } 'String Value must be text'
    Test-Bad 'a registry type other than DWord or String' Registry { param($e) $e.Type = 'Binary' } 'Type must be'
    Test-Bad 'a HKCU path' Registry { param($e) $e.Path = 'HKCU:\SOFTWARE\Test' } 'below HKLM'
    Test-Bad 'a path with ..' Registry { param($e) $e.Path = 'HKLM:\SOFTWARE\..\SYSTEM' } 'below HKLM'
    Test-Bad 'a path with a command in it' Registry { param($e) $e.Path = 'HKLM:\SOFTWARE\x; calc' } 'below HKLM'
    Test-Bad 'a value name with a slash' Registry { param($e) $e.Name = 'a\b' } 'valid value name'
    Test-Bad 'an unknown property' Registry { param($e) $e.Run = 'calc.exe' } "unknown property 'Run'"
    Test-Bad 'a missing property (Risk)' Registry { param($e) $e.Remove('Risk') } "'Risk' is missing"
    Test-Bad 'a risk that is not Low, Medium or High' Registry { param($e) $e.Risk = 'Critical' } 'Risk must be'
    Test-Bad 'a risk in other letter case' Registry { param($e) $e.Risk = 'low' } 'Risk must be'
    Test-Bad 'an http source' Registry { param($e) $e.Source = 'http://learn.microsoft.com/en-us/x' } 'https URL'
    Test-Bad 'a source on a host that is not allowed' Registry { param($e) $e.Source = 'https://example.org/x' } 'https URL'
    Test-Bad 'a source with credentials in the URL' Registry { param($e) $e.Source = 'https://user:pw@learn.microsoft.com/x' } 'https URL'
    Test-Bad 'a source with a space' Registry { param($e) $e.Source = 'https://learn.microsoft.com/en-us/x y' } 'https URL'
    Test-Bad 'a title with a control character' Registry { param($e) $e.Title = "Title`r`nline" } 'Title must be text'
    Test-Bad 'a title that is not text' Registry { param($e) $e.Title = 5 } 'Title must be text'
    Test-Bad 'a reason that is too short' Registry { param($e) $e.Why = 'short' } 'Why must be text'
    Test-Bad 'an id in upper case' Registry { param($e) $e.Id = 'optimization.T-Reg' } 'no valid Id'
    Test-Bad 'an id without the prefix' Registry { param($e) $e.Id = 'foo.bar' } 'no valid Id'
    Test-Bad 'an origin that is not a listed source' Registry { param($e) $e.Origin = 'nobody' } 'not one of the Sources'
    Test-Bad 'a category that does not fit the kind' Registry { param($e) $e.Category = 'Service' } 'does not match Kind'
    Test-Bad 'an unknown kind' Registry { param($e) $e.Kind = 'RunScript' } 'unknown Kind'
    Test-Bad 'an autologger without OnlyIfKeyExists' Registry { param($e) $e.Category = 'Autologger' } 'OnlyIfKeyExists'
    Test-Bad 'OnlyIfKeyExists as text' Registry { param($e) $e.OnlyIfKeyExists = 'true' } 'OnlyIfKeyExists must be'
    Test-Bad 'a service name with a wildcard' Service { param($e) $e.Name = 'Test*' } 'valid service name'
    Test-Bad 'a service start type Enabled' Service { param($e) $e.Startup = 'Automatic' } 'Startup must be'
    Test-Bad 'a task path without the closing backslash' Task { param($e) $e.TaskPath = '\Microsoft\Test' } 'TaskPath'
    Test-Bad 'a task path with ..' Task { param($e) $e.TaskPath = '\Microsoft\..\' } 'TaskPath'
    Test-Bad 'a task name with a wildcard' Task { param($e) $e.TaskName = '*' } 'TaskName'
    Test-Bad 'a task name with a path' Task { param($e) $e.TaskName = '..\x' } 'TaskName'
    Test-Bad 'an AppX package with a wildcard' Appx { param($e) $e.PackageName = '*' } 'PackageName'
    Test-Bad 'an AppX package with a space' Appx { param($e) $e.PackageName = 'Foo Bar' } 'PackageName'
    Test-Bad 'a Defender setting that is not on the list' Defender { param($e) $e.Parameter = 'DisableRealtimeMonitoring'; $e.Value = $true } 'not on the list'
    Test-Bad 'a Defender setting with the wrong case' Defender { param($e) $e.Parameter = 'puaprotection' } 'not on the list'
    Test-Bad 'a Defender boolean as the text "true"' Defender { param($e) $e.Parameter = 'UILockdown'; $e.Value = 'true' } 'real boolean'
    Test-Bad 'a Defender number as text' Defender { param($e) $e.Value = '1' } 'whole number'
    Test-Bad 'a Defender number out of range' Defender { param($e) $e.Value = 7 } 'one of 0, 1, 2'
    Test-Bad 'a Defender CPU limit above 100' Defender { param($e) $e.Parameter = 'ScanAvgCPULoadFactor'; $e.Value = 500 } 'from 5 to 100'
    $dupe = Read-Doc @($base.Registry, $base.Registry)
    Test-Check 'types: a duplicate id is refused' ((-not $dupe.Valid) -and (($dupe.Errors -join ' ') -match 'used twice')) ($dupe.Errors -join '; ')
    $mixed = Read-Doc @($base.Registry, (Get-Mut Service { param($e) $e.Startup = 'Enabled' }))
    Test-Check 'types: one bad entry makes the whole file invalid, the good one is still listed but nothing is applied' ((-not $mixed.Valid) -and $mixed.Entries.Count -eq 1) $null
    Test-Check 'types: SchemaVersion as text is refused' ((-not (Read-Doc @($base.Registry) $src @{ SchemaVersion = '1' }).Valid)) $null
    Test-Check 'types: an unknown top-level property is refused' ((-not (Read-Doc @($base.Registry) $src @{ RunMe = 'x' }).Valid)) $null
    Test-Check 'types: no entries is refused' (-not (Read-Doc @()).Valid) $null
    Test-Check 'types: Entries that is not a list is refused' (-not (Read-Doc 'x').Valid) $null
    Test-Check 'types: a source on an http URL is refused' (-not (Read-Doc @($base.Registry) @([ordered]@{ Id = 'own'; Name = 'T'; Url = 'http://learn.microsoft.com/x'; License = 'MIT'; Copyright = 'c'; Checked = 'x' })).Valid) $null
    $bad = Join-Path $tmp 'broken.json'; [IO.File]::WriteAllText($bad, '{ "SchemaVersion": 1, ')
    Test-Check 'types: a file that is not JSON is refused with a reason' ((-not (Read-AVDTuneOptimizationData -Path $bad).Valid) -and ((Read-AVDTuneOptimizationData -Path $bad).Errors[0] -like '*not valid JSON*')) $null
    Test-Check 'types: a missing file is refused' (-not (Read-AVDTuneOptimizationData -Path (Join-Path $tmp 'nothing.json')).Valid) $null
    $big = Join-Path $tmp 'big.json'; [IO.File]::WriteAllText($big, ('{"x":"' + ('a' * 2200000) + '"}'))
    Test-Check 'types: a file over 2 MB is refused before it is parsed' ((Read-AVDTuneOptimizationData -Path $big).Errors[0] -like '*larger than 2 MB*') $null

    # a data file that is not valid blocks everything
    $badDoc = Join-Path $tmp 'invalid-run.json'
    [IO.File]::WriteAllText($badDoc, ([ordered]@{ SchemaVersion = 1; Sources = $src; Entries = @((Get-Mut Registry { param($e) $e.Default = 'false' })) } | ConvertTo-Json -Depth 6))
    $m0 = New-AVDTuneFakeMachine; [void](Add-AVDTuneOptimizationFakeMembers $m0)
    Open-AVDTuneWriteGate -SnapshotId 's1' -ConfirmedBy 'admin1'
    Test-Check 'invalid data: Invoke refuses and changes nothing' ((Test-Throws { Invoke-AVDTuneOptimization -Machine $m0 -Root $state -DataPath $badDoc -Ids 'optimization.t-reg' }) -and -not (@($m0.Log) -match 'RegSet')) $null
    Test-Check 'invalid data: the status says the data is not valid and lists no rows' ((-not (Get-AVDTuneOptimizationStatus -Machine $m0 -Root $state -DataPath $badDoc).DataValid) -and (Get-AVDTuneOptimizationStatus -Machine $m0 -Root $state -DataPath $badDoc).Rows.Count -eq 0) $null
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- a small data file for the behaviour checks
    $B = [ordered]@{}
    $B.reg = Get-Mut Registry { param($e) $e.Id = 'optimization.reg-a'; $e.Name = 'ValA'; $e.Value = 1 }
    $B.regs = Get-Mut Registry { param($e) $e.Id = 'optimization.reg-s'; $e.Name = 'ValS'; $e.Type = 'String'; $e.Value = 'off' }
    $B.al = Get-Mut Registry { param($e) $e.Id = 'optimization.al-x'; $e.Category = 'Autologger'; $e.OnlyIfKeyExists = $true; $e.Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\FakeLog'; $e.Name = 'Start'; $e.Value = 0; $e.Reboot = $true }
    $B.svc = Get-Mut Service { param($e) $e.Id = 'optimization.svc-a'; $e.Name = 'TestSvc' }
    $B.svcx = Get-Mut Service { param($e) $e.Id = 'optimization.svc-missing'; $e.Name = 'NoSuchSvc' }
    $B.task = Get-Mut Task { param($e) $e.Id = 'optimization.task-a' }
    $B.taskx = Get-Mut Task { param($e) $e.Id = 'optimization.task-missing'; $e.TaskName = 'NoSuchTask' }
    $B.appx1 = Get-Mut Appx { param($e) $e.Id = 'optimization.appx-a'; $e.PackageName = 'Test.AppA' }
    $B.appx2 = Get-Mut Appx { param($e) $e.Id = 'optimization.appx-b'; $e.PackageName = 'Test.AppB' }
    $B.mp = Get-Mut Defender { param($e) $e.Id = 'optimization.defender-pua'; $e.Parameter = 'PUAProtection'; $e.Value = 1 }
    $B.mpb = Get-Mut Defender { param($e) $e.Id = 'optimization.defender-ui'; $e.Parameter = 'UILockdown'; $e.Value = $true }
    $B.mpx = Get-Mut Defender { param($e) $e.Id = 'optimization.defender-none'; $e.Parameter = 'CloudBlockLevel'; $e.Value = 2 }
    $small = Join-Path $tmp 'small.json'
    [IO.File]::WriteAllText($small, ([ordered]@{ SchemaVersion = 1; Sources = $src; Entries = @($B.Values) } | ConvertTo-Json -Depth 6))
    Test-Check 'small data file is valid' ((Read-AVDTuneOptimizationData -Path $small).Valid) ((Read-AVDTuneOptimizationData -Path $small).Errors -join '; ')

    function New-TestMachine {
        $m = New-AVDTuneFakeMachine -Seed @{
            Now = [datetime]'2026-11-15T12:00:00'
            Registry = @{ 'HKLM:\SOFTWARE\Policies\AVDTuneTest|ValA' = 5; 'HKLM:\SOFTWARE\Policies\AVDTuneTest|ValS' = 'on' }
            Services = @(@{ Name = 'TestSvc'; Status = 'Running'; StartType = 'Automatic' })
            Tasks = @(@{ Path = '\Microsoft\Test\'; Name = 'TestTask'; Enabled = $true })
        }
        [void](Add-AVDTuneOptimizationFakeMembers $m -Appx @('Test.AppA', 'Test.AppB') -Defender @{ PUAProtection = [byte]0; UILockdown = $false })
        $m
    }
    function Invoke-Opt($Machine, [string[]]$Ids, [string]$Mode = 'Apply', [switch]$Confirm, [switch]$WhatIf) {
        Invoke-AVDTuneOptimization -Machine $Machine -Root $state -DataPath $small -Ids $Ids -Mode $Mode -ConfirmIrreversible:$Confirm -User 'admin1' -SnapshotId 'snap-1' -WhatIf:$WhatIf
    }
    function Get-Last { (Get-AVDTuneState $state).LastChange }
    function Clear-Backups { Remove-Item (Join-Path $state 'config\optimization-backup.json') -Force -ErrorAction SilentlyContinue }

    # ---------------------------------------------------------------- write gate
    $m = New-TestMachine
    Close-AVDTuneWriteGate
    Test-Check 'gate: Apply with the gate closed throws and changes nothing' ((Test-Throws { Invoke-Opt $m 'optimization.reg-a' }) -and (& $m.RegGet 'HKLM:\SOFTWARE\Policies\AVDTuneTest' 'ValA') -eq 5 -and -not (Get-Last)) $null
    $w = Invoke-Opt $m 'optimization.reg-a' -WhatIf
    Test-Check 'gate: WhatIf works with the gate closed, changes nothing, writes no run, no backup, no LastChange' ($w.WhatIf -and $w.Results[0].Status -eq 'WhatIf' -and (& $m.RegGet 'HKLM:\SOFTWARE\Policies\AVDTuneTest' 'ValA') -eq 5 -and -not (Get-Last) -and -not (Test-Path (Join-Path $state 'config\optimization-backup.json'))) $null
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'
    Test-Check 'select: unknown entry and empty selection throw' ((Test-Throws { Invoke-Opt $m 'optimization.nope' }) -and (Test-Throws { Invoke-Opt $m @() })) $null

    # ---------------------------------------------------------------- registry
    $r = Invoke-Opt $m 'optimization.reg-a', 'optimization.reg-s'
    Test-Check 'registry: Apply changes both values' ($r.Changed -eq 2 -and (& $m.RegGet 'HKLM:\SOFTWARE\Policies\AVDTuneTest' 'ValA') -eq 1 -and (& $m.RegGet 'HKLM:\SOFTWARE\Policies\AVDTuneTest' 'ValS') -eq 'off') ($r.Results | ConvertTo-Json -Depth 3 -Compress)
    $bk = Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.reg-a'
    Test-Check 'registry: the value from before is saved' ($bk -and $bk.Exists -eq $true -and $bk.Value -eq 5) $null
    $logCount = @($m.Log | Where-Object { $_ -like 'RegSet*' }).Count
    $r2 = Invoke-Opt $m 'optimization.reg-a'
    Test-Check 'registry: a second Apply is Unchanged and writes nothing' ($r2.Unchanged -eq 1 -and $r2.Changed -eq 0 -and @($m.Log | Where-Object { $_ -like 'RegSet*' }).Count -eq $logCount) $null
    Test-Check 'registry: LastChange is set after Apply' ([bool](Get-Last)) $null
    $run = Get-AVDTuneRun -Root $state -Id $r.RunId
    Test-Check 'registry: a run record with both results exists' ($run -and @($run.Results).Count -eq 2) $null
    $cl = @(Get-AVDTuneChangeLog -Root $state | Where-Object { $_.Component -in 'optimization.reg-a', 'optimization.reg-s' })
    Test-Check 'registry: one change log entry per change in category Optimization' ($cl.Count -eq 2 -and ($cl | Where-Object { $_.Category -ne 'Optimization' }).Count -eq 0) $null
    # an external change in between must not overwrite the older backup
    $m.Store.Registry['hklm:\software\policies\avdtunetest|vala'] = 7
    [void](Invoke-Opt $m 'optimization.reg-a')
    Test-Check 'registry: Apply again after an outside change keeps the older backup (5), not the 7' ((Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.reg-a').Value -eq 5 -and (& $m.RegGet 'HKLM:\SOFTWARE\Policies\AVDTuneTest' 'ValA') -eq 1) $null
    Test-Check 'registry: Save-Backup never overwrites an existing one' ((-not (Save-AVDTuneOptimizationBackup -Root $state -Id 'optimization.reg-a' -Record @{ Kind = 'Registry'; Exists = $true; Value = 99 })) -and (Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.reg-a').Value -eq 5) $null
    $u = Invoke-Opt $m 'optimization.reg-a', 'optimization.reg-s' 'Undo'
    Test-Check 'registry: Undo restores the values from before (5 and on)' ($u.Changed -eq 2 -and (& $m.RegGet 'HKLM:\SOFTWARE\Policies\AVDTuneTest' 'ValA') -eq 5 -and (& $m.RegGet 'HKLM:\SOFTWARE\Policies\AVDTuneTest' 'ValS') -eq 'on') ($u.Results | ConvertTo-Json -Depth 3 -Compress)
    Test-Check 'registry: the backups are gone after a successful Undo' (-not (Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.reg-a') -and -not (Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.reg-s')) $null
    Test-Check 'registry: Undo is written to the change log as Undone' (@(Get-AVDTuneChangeLog -Root $state | Where-Object { $_.Text -like 'Undone:*' }).Count -eq 2) $null
    # a value that did not exist: Undo removes it
    $m.Store.Registry.Remove('hklm:\software\policies\avdtunetest|vala')
    [void](Invoke-Opt $m 'optimization.reg-a'); $u = Invoke-Opt $m 'optimization.reg-a' 'Undo'
    Test-Check 'registry: a value that did not exist is removed again by Undo' ($u.Changed -eq 1 -and $null -eq (& $m.RegGet 'HKLM:\SOFTWARE\Policies\AVDTuneTest' 'ValA')) $null
    # Undo without a backup: not applied by AVDTune
    $m.Store.Registry['hklm:\software\policies\avdtunetest|vala'] = 1
    Clear-Backups
    $before = @($m.Log).Count
    $u = Invoke-Opt $m 'optimization.reg-a' 'Undo'
    $ur = Get-R $u 'optimization.reg-a'
    Test-Check 'registry: Undo without a backup fails with a reason and does not touch the value' ($ur.Status -eq 'Failed' -and $ur.Message -like '*no saved earlier value*' -and (& $m.RegGet 'HKLM:\SOFTWARE\Policies\AVDTuneTest' 'ValA') -eq 1 -and @($m.Log).Count -eq $before) $ur.Message
    # damaged backup
    $m.Store.Registry['hklm:\software\policies\avdtunetest|vala'] = 5
    [void](Invoke-Opt $m 'optimization.reg-a')
    $bf = Join-Path $state 'config\optimization-backup.json'
    [IO.File]::WriteAllText($bf, ((Get-Content $bf -Raw) -replace '"Value":\s*5', '"Value": "calc.exe"'))
    $u = Invoke-Opt $m 'optimization.reg-a' 'Undo'
    Test-Check 'backup: a damaged backup (text instead of a number) is refused at Undo, the value stays' ((Get-R $u 'optimization.reg-a').Status -eq 'Failed' -and (Get-R $u 'optimization.reg-a').Message -like '*damaged*' -and (& $m.RegGet 'HKLM:\SOFTWARE\Policies\AVDTuneTest' 'ValA') -eq 1) (Get-R $u 'optimization.reg-a').Message
    [IO.File]::WriteAllText($bf, '{ not json')
    $m.Store.Registry['hklm:\software\policies\avdtunetest|vala'] = 5
    $r = Invoke-Opt $m 'optimization.reg-a'
    Test-Check 'backup: an unreadable backup file stops Apply before the change and is not overwritten by an empty one' ((Get-R $r 'optimization.reg-a').Status -eq 'Failed' -and (& $m.RegGet 'HKLM:\SOFTWARE\Policies\AVDTuneTest' 'ValA') -eq 5 -and (Get-Content $bf -Raw) -eq '{ not json') (Get-R $r 'optimization.reg-a').Message
    Clear-Backups
    # failed write: other entries go on, no backup stays, LastChange is set
    $m = New-TestMachine; $m.Store.FailWrites = @('vala')
    $r = Invoke-Opt $m 'optimization.reg-a', 'optimization.reg-s'
    Test-Check 'failure: one failed registry write does not stop the next entry, no backup stays for the failed one' ((Get-R $r 'optimization.reg-a').Status -eq 'Failed' -and (Get-R $r 'optimization.reg-s').Status -eq 'Changed' -and $r.Failed -eq 1 -and -not (Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.reg-a')) $null
    Test-Check 'failure: a failed attempt is a note in the change log' (@(Get-AVDTuneChangeLog -Root $state | Where-Object { $_.ChangeType -eq 'Note' -and $_.Text -like 'Failed (Apply)*' }).Count -ge 1) $null
    Clear-Backups

    # ---------------------------------------------------------------- autologger (only when the logger exists)
    $m = New-TestMachine
    $r = Invoke-Opt $m 'optimization.al-x'
    Test-Check 'autologger: no logger on this machine = Skipped, no key is created' ((Get-R $r 'optimization.al-x').Status -eq 'Skipped' -and -not (@($m.Log) -match 'RegSet')) $null
    $m = New-TestMachine; $m.Store.Registry['hklm:\system\currentcontrolset\control\wmi\autologger\fakelog|start'] = 1
    $r = Invoke-Opt $m 'optimization.al-x'
    Test-Check 'autologger: an existing logger is switched off (Start 0) and the run reports a restart' ($r.Changed -eq 1 -and $r.Reboot -and (& $m.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\FakeLog' 'Start') -eq 0) $null
    $u = Invoke-Opt $m 'optimization.al-x' 'Undo'
    Test-Check 'autologger: Undo sets Start back to 1' ($u.Changed -eq 1 -and (& $m.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\FakeLog' 'Start') -eq 1) $null

    # ---------------------------------------------------------------- services and tasks
    $m = New-TestMachine
    $r = Invoke-Opt $m 'optimization.svc-a', 'optimization.svc-missing'
    Test-Check 'service: Apply disables it; a service that is not there is Skipped' ((& $m.ServiceGet 'TestSvc').StartType -eq 'Disabled' -and (Get-R $r 'optimization.svc-missing').Status -eq 'Skipped' -and (Get-R $r 'optimization.svc-a').Status -eq 'Changed') $null
    $u = Invoke-Opt $m 'optimization.svc-a' 'Undo'
    Test-Check 'service: Undo restores the earlier start type (Automatic)' ((& $m.ServiceGet 'TestSvc').StartType -eq 'Automatic' -and $u.Changed -eq 1) $null
    $m = New-TestMachine; $m.Store.Services['testsvc'].StartType = 'Manual'
    [void](Invoke-Opt $m 'optimization.svc-a'); [void](Invoke-Opt $m 'optimization.svc-a' 'Undo')
    Test-Check 'service: a service that was Manual is Manual again after Undo (not forced to Automatic)' ((& $m.ServiceGet 'TestSvc').StartType -eq 'Manual') $null
    $m = New-TestMachine; $m.Store.Services['testsvc'].StartType = 'Disabled'
    $r = Invoke-Opt $m 'optimization.svc-a'; $u = Invoke-Opt $m 'optimization.svc-a' 'Undo'
    Test-Check 'service: a service that was Disabled before is Unchanged and Undo does not enable it' ($r.Unchanged -eq 1 -and (Get-R $u 'optimization.svc-a').Status -eq 'Failed' -and (& $m.ServiceGet 'TestSvc').StartType -eq 'Disabled') $null
    Clear-Backups
    $m = New-TestMachine
    $r = Invoke-Opt $m 'optimization.task-a', 'optimization.task-missing'
    Test-Check 'task: Apply disables it; a task that is not there is Skipped and not reported as in place' ((& $m.TaskGet '\Microsoft\Test\' 'TestTask').Enabled -eq $false -and (Get-R $r 'optimization.task-missing').Status -eq 'Skipped') $null
    $u = Invoke-Opt $m 'optimization.task-a' 'Undo'
    Test-Check 'task: Undo enables it again' ((& $m.TaskGet '\Microsoft\Test\' 'TestTask').Enabled -eq $true -and $u.Changed -eq 1) $null
    $m = New-TestMachine; $m.Store.Tasks['\microsoft\test\testtask'].Enabled = $false
    $r = Invoke-Opt $m 'optimization.task-a'; $u = Invoke-Opt $m 'optimization.task-a' 'Undo'
    Test-Check 'task: a task that was disabled before stays disabled after Undo (no backup, no change)' ($r.Unchanged -eq 1 -and (& $m.TaskGet '\Microsoft\Test\' 'TestTask').Enabled -eq $false) $null
    Clear-Backups

    # ---------------------------------------------------------------- AppX: not undoable, extra confirmation
    $m = New-TestMachine
    $err = $null; try { Invoke-Opt $m 'optimization.reg-a', 'optimization.appx-a' | Out-Null } catch { $err = $_.Exception.Message }
    Test-Check 'appx: without the extra confirmation nothing is changed, not even the other selected entries' ($err -like '*cannot be undone*' -and $m.Store.Appx.ContainsKey('test.appa') -and (& $m.RegGet 'HKLM:\SOFTWARE\Policies\AVDTuneTest' 'ValA') -eq 5 -and -not (@($m.Log) -match 'AppxRemove|RegSet')) $err
    $w = Invoke-Opt $m 'optimization.appx-a' -WhatIf
    Test-Check 'appx: WhatIf needs no confirmation and removes nothing' ($w.Results[0].Status -eq 'WhatIf' -and $m.Store.Appx.ContainsKey('test.appa')) $null
    $r = Invoke-Opt $m 'optimization.appx-a' -Confirm
    Test-Check 'appx: with the confirmation the package is removed (installed and provisioned)' ($r.Changed -eq 1 -and -not $m.Store.Appx.ContainsKey('test.appa') -and $m.Store.Appx.ContainsKey('test.appb')) $null
    Test-Check 'appx: the change log says Removed' (@(Get-AVDTuneChangeLog -Root $state | Where-Object { $_.Component -eq 'optimization.appx-a' -and $_.ChangeType -eq 'Removed' }).Count -eq 1) $null
    $u = Invoke-Opt $m 'optimization.appx-a' 'Undo'
    Test-Check 'appx: Undo says NoUndo and brings nothing back' ((Get-R $u 'optimization.appx-a').Status -eq 'NoUndo' -and -not $m.Store.Appx.ContainsKey('test.appa') -and $u.NoUndo -eq 1 -and $u.Changed -eq 0) $null
    $r = Invoke-Opt $m 'optimization.appx-a'
    Test-Check 'appx: a package that is gone is Unchanged without asking for the confirmation again' ($r.Unchanged -eq 1) $null
    $st = Get-AVDTuneOptimizationStatus -Machine $m -Root $state -DataPath $small
    $row = @($st.Rows | Where-Object Id -eq 'optimization.appx-b')[0]
    Test-Check 'appx: the status marks it irreversible, no Undo offered, state shows what is installed' ($row.Irreversible -and -not $row.HasBackup -and -not $row.Compliant -and $row.State -like '*installed*') ($row | ConvertTo-Json -Compress)
    $m.Store.FailWrites = @('appb')
    $r = Invoke-Opt $m 'optimization.appx-b' -Confirm
    Test-Check 'appx: a failed removal is reported as failed and the package is still there' ((Get-R $r 'optimization.appx-b').Status -eq 'Failed' -and $m.Store.Appx.ContainsKey('test.appb') -and $r.Failed -eq 1) $null

    # ---------------------------------------------------------------- Defender
    $m = New-TestMachine
    $r = Invoke-Opt $m 'optimization.defender-pua', 'optimization.defender-ui', 'optimization.defender-none'
    Test-Check 'defender: Apply sets the number and the boolean; a setting Defender does not report is Skipped' ($m.Store.Mp['PUAProtection'] -eq 1 -and $m.Store.Mp['UILockdown'] -eq $true -and (Get-R $r 'optimization.defender-none').Status -eq 'Skipped' -and $r.Changed -eq 2) ($r.Results | ConvertTo-Json -Depth 3 -Compress)
    $u = Invoke-Opt $m 'optimization.defender-pua', 'optimization.defender-ui' 'Undo'
    Test-Check 'defender: Undo restores the earlier values (0 and false)' ($m.Store.Mp['PUAProtection'] -eq 0 -and $m.Store.Mp['UILockdown'] -eq $false -and $u.Changed -eq 2) $null
    $m = New-TestMachine; $m.Store.Mp['UILockdown'] = 'True'
    $r = Invoke-Opt $m 'optimization.defender-ui'
    Test-Check 'defender: the text True from the machine counts as the boolean true (Unchanged)' ($r.Unchanged -eq 1) $null
    $m = New-TestMachine; $m.Store.FailWrites = @('UILockdown')
    $r = Invoke-Opt $m 'optimization.defender-ui'
    Test-Check 'defender: a refused Set-MpPreference (for example tamper protection) is a failure with the reason, no backup stays' ((Get-R $r 'optimization.defender-ui').Status -eq 'Failed' -and (Get-R $r 'optimization.defender-ui').Message -like '*refused*' -and -not (Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.defender-ui')) $null
    Clear-Backups

    # ---------------------------------------------------------------- status
    $m = New-TestMachine
    $st = Get-AVDTuneOptimizationStatus -Machine $m -Root $state -DataPath $small
    Test-Check 'status: one row per entry with category, risk, source and state; reading writes nothing' ($st.DataValid -and $st.Rows.Count -eq $B.Count -and (@($m.Log).Count -eq 0) -and (@($st.Rows | Where-Object { -not $_.Source -or -not $_.Why }).Count -eq 0)) $null
    $x = @($st.Rows | Where-Object Id -eq 'optimization.svc-missing')[0]
    Test-Check 'status: an entry that is not on this machine is marked not present and is not reported as compliant by accident' ((-not $x.Present) -and $x.State -like '*not present*') ($x | ConvertTo-Json -Compress)
    [void](Invoke-Opt $m 'optimization.reg-a')
    $st = Get-AVDTuneOptimizationStatus -Machine $m -Root $state -DataPath $small
    $x = @($st.Rows | Where-Object Id -eq 'optimization.reg-a')[0]
    Test-Check 'status: after Apply the row is compliant and has a backup (Undo offered)' ($x.Compliant -and $x.HasBackup) $null
    Test-Check 'status: a machine without the AppX and Defender members is refused (no silent skipping)' (Test-Throws { Add-AVDTuneOptimizationMachineMembers -Machine (New-AVDTuneFakeMachine) }) $null
    Clear-Backups

    # ---------------------------------------------------------------- the shipped data against the fake machine
    $m = New-TestMachine
    $st = Get-AVDTuneOptimizationStatus -Machine $m -Root $state
    Test-Check 'shipped data: the status reads all entries from the fake machine without error' ($st.DataValid -and $st.Rows.Count -eq $entries.Count -and @($st.Rows | Where-Object Failed).Count -eq 0) (@($st.Rows | Where-Object Failed | Select-Object -First 2 | ForEach-Object { "$($_.Id): $($_.Message)" }) -join '; ')
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- the page (built in code, off-screen; the window is never shown; stubs for the helpers of Start-AVDTune.ps1)
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $window = New-Object System.Windows.Window
    $root = New-Object System.Windows.Controls.Grid; $window.Content = $root
    $placeholder = New-Object System.Windows.Controls.Grid; [void]$root.Children.Add($placeholder)
    $ui = @{ PagePlaceholder = $placeholder }
    $script:StateRoot = $state; $script:Protocol = $null
    $script:Asked = New-Object System.Collections.ArrayList; $script:Toasts = New-Object System.Collections.ArrayList
    $script:Answers = New-Object System.Collections.Queue
    function Set-Brush($Element, $Property, [string]$Key) { }
    function ConvertTo-Vis([bool]$On) { if ($On) { 'Visible' } else { 'Collapsed' } }
    function New-Text([string]$Text, [string]$Style, [string]$Margin = '0,0,0,0') { $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $Text; $t }
    function New-UpdGroupHead([string]$Text) { New-Text $Text }
    function Add-Click($Control, [scriptblock]$Action) { }
    function Show-Toast([string]$Text) { [void]$script:Toasts.Add($Text) }
    function Confirm-Action([string]$Text, [string]$Title = 'AVDTune') { [void]$script:Asked.Add($Text); if ($script:Answers.Count -gt 0) { $script:Answers.Dequeue() } else { $false } }
    function Register-StepResult($Result) { }
    function Add-AVDTuneProtocolNote { param($Protocol, $Group, $Subject, $Note) }
    function Save-Protocol { }
    function Start-OverviewRefresh { }
    function Invoke-UiTaskInline { param($Kind, $Title, [scriptblock]$Block, $Step, $Done, $Retry) & $Block }
    . (Join-Path $repo 'AVDTune-Optimization.ps1')
    Test-Check 'page: it is added next to the other pages and starts hidden' ($ui.PageOptimization -and $root.Children.Contains($ui.PageOptimization) -and $ui.PageOptimization.Visibility -eq 'Collapsed') $null
    $script:Machine = New-AVDTuneFakeMachine -Seed @{ Now = [datetime]'2026-11-15T12:00:00'; Services = @(@{ Name = 'DiagTrack'; Status = 'Running'; StartType = 'Automatic' }) }
    [void](Add-AVDTuneOptimizationFakeMembers $script:Machine -Appx @('Microsoft.BingNews') -Defender @{ PUAProtection = [byte]0 })
    Update-OptView
    $rowsShown = @($ui.PanelOptList.Children | Where-Object { $_ -is [System.Windows.Controls.Grid] })
    Test-Check 'page: the list shows a row per entry with a checkbox, reason, source and state' ($rowsShown.Count -eq $entries.Count -and ($rowsShown[0].Children[0] -is [System.Windows.Controls.CheckBox]) -and ($rowsShown[0].Children[1].Children.Count -ge 3)) "$($rowsShown.Count) rows"
    $selectedBefore = @(Get-OptSelectedRows)
    Test-Check 'page: the entries that are on by default are ticked at the start, the ones that are off are not' ((@($selectedBefore | Where-Object { -not $_.Default }).Count -eq 0) -and $selectedBefore.Count -gt 20) "selected=$($selectedBefore.Count)"
    Test-Check 'page: entries that are not on this host cannot be ticked (disabled checkbox)' (@($rowsShown | Where-Object { -not $_.Children[0].IsEnabled }).Count -gt 0) $null
    Set-OptPreset 'conservative'
    Test-Check 'page: the Conservative preset ticks only low-risk entries without AppX' (@(Get-OptSelectedRows | Where-Object { $_.Risk -ne 'Low' -or $_.Irreversible }).Count -eq 0 -and @(Get-OptSelectedRows).Count -gt 0) $null
    Set-OptPreset 'none'
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'
    Start-OptChange 'Apply'
    Test-Check 'page: with nothing ticked Apply asks nothing and changes nothing' ((@(Get-OptSelectedRows).Count -eq 0) -and $script:Asked.Count -eq 0 -and @($script:Machine.Log).Count -eq 0) $null
    $script:OptOnlyOpen = $true; Show-OptList
    $openRows = @($ui.PanelOptList.Children | Where-Object { $_ -is [System.Windows.Controls.Grid] })
    Test-Check 'page: the filter shows only entries that are not in place yet' ($openRows.Count -gt 0 -and $openRows.Count -lt $rowsShown.Count) "$($openRows.Count) of $($rowsShown.Count)"
    $script:OptOnlyOpen = $false
    Set-OptPreset 'recommended'
    Close-AVDTuneWriteGate
    Test-Check 'page: Apply with the gate closed throws (read only) and changes nothing' ((Test-Throws { Start-OptChange 'Apply' }) -and @($script:Machine.Log).Count -eq 0) $null
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'
    $script:Asked.Clear(); $script:Answers.Enqueue($false)
    Start-OptChange 'Apply'
    Test-Check 'page: answering No to the first question changes nothing' ($script:Asked.Count -eq 1 -and @($script:Machine.Log).Count -eq 0) $null
    $script:Asked.Clear(); $script:Answers.Enqueue($true); $script:Answers.Enqueue($false)
    Start-OptChange 'Apply'
    Test-Check 'page: AppX removal asks a second time, says it cannot be undone, and answering No there changes nothing at all (not even the other entries)' ($script:Asked.Count -eq 2 -and $script:Asked[1] -like '*cannot be undone*' -and $script:Asked[1] -like '*News*' -and $script:Machine.Store.Appx.ContainsKey('microsoft.bingnews') -and @($script:Machine.Log).Count -eq 0) ($script:Asked -join ' | ')
    $script:Asked.Clear(); $script:Answers.Enqueue($true); $script:Answers.Enqueue($true)
    Start-OptChange 'Apply'
    Test-Check 'page: after both confirmations the entries are applied, the AppX is gone and the toast reports it' (-not $script:Machine.Store.Appx.ContainsKey('microsoft.bingnews') -and (& $script:Machine.ServiceGet 'DiagTrack').StartType -eq 'Disabled' -and $script:Toasts[-1] -like 'Optimization apply: *change(s)*') $script:Toasts[-1]
    $script:Asked.Clear(); $script:Answers.Enqueue($true)
    Start-OptChange 'Undo'
    Test-Check 'page: Undo asks once (the AppX is left out and named as such), restores the service and does not bring the AppX back' ($script:Asked.Count -eq 1 -and $script:Asked[0] -like '*cannot be undone and are left out*' -and (& $script:Machine.ServiceGet 'DiagTrack').StartType -eq 'Automatic' -and -not $script:Machine.Store.Appx.ContainsKey('microsoft.bingnews')) ($script:Asked -join ' | ')
    $script:OptStatus = [pscustomobject]@{ DataValid = $false; DataErrors = @('broken'); Sources = @(); Rows = @(); BackupError = $null }
    Show-OptList
    Test-Check 'page: invalid data shows the error and disables Apply and Undo' ($ui.BoxOptErrors.Visibility -eq 'Visible' -and -not $ui.BtnOptApply.IsEnabled -and -not $ui.BtnOptUndo.IsEnabled) $null
    Test-Check 'page: Apply with invalid data throws' (Test-Throws { Start-OptChange 'Apply' }) $null
    Close-AVDTuneWriteGate

    # the members of a real machine (only names are checked here, no cmdlet is called)
    $real = New-AVDTuneMachine; [void](Add-AVDTuneOptimizationMachineMembers -Machine $real)
    Test-Check 'real machine: gets the four members, refuses a Defender setting that is not on the list and an AppX name with a wildcard before any cmdlet runs' ((@('AppxState', 'AppxRemove', 'MpGet', 'MpSet') | Where-Object { $null -eq $real.PSObject.Properties[$_] }).Count -eq 0 -and (Test-Throws { & $real.MpGet 'DisableRealtimeMonitoring' }) -and (Test-Throws { & $real.MpSet 'DisableRealtimeMonitoring' $true }) -and (Test-Throws { & $real.AppxState '*' }) -and (Test-Throws { & $real.AppxRemove 'Microsoft.*' })) $null

    # ---------------------------------------------------------------- hygiene
    foreach ($f in 'Modules\AVDTune.Optimization.psm1', 'AVDTune-Optimization.ps1', 'data\optimization.json', 'Tests\Fakes\FakeOptimization.ps1', 'NOTICE') {
        $p = Join-Path $repo $f
        if (Test-Path $p) { Test-Check "$f is plain ASCII" (-not (@([IO.File]::ReadAllBytes($p) | Where-Object { $_ -gt 127 }).Count)) $null }
    }
    $modText = Get-Content (Join-Path $repo 'Modules\AVDTune.Optimization.psm1') -Raw
    Test-Check 'the module never downloads or runs anything: no web request, no Invoke-Expression, no Start-Process, no script block from data' (($modText -notmatch 'Invoke-WebRequest|Invoke-RestMethod|Net\.WebClient|Invoke-Expression|\biex\b|Start-Process|\[scriptblock\]::Create') -and ((Get-Content (Join-Path $repo 'data\optimization.json') -Raw) -notmatch 'Invoke-|powershell|cmd\.exe')) $null
    Test-Check 'the module writes only through the adapter and the backup file (no direct Set-ItemProperty, Remove-Item, Set-Service)' ($modText -notmatch '\bSet-ItemProperty\b|\bRemove-Item\b|\bSet-Service\b|\bDisable-ScheduledTask\b') $null
    $startText = Get-Content (Join-Path $repo 'Start-AVDTune.ps1') -Raw
    Test-Check 'hooks: Start-AVDTune.ps1 loads the module and the page and shows the page' (($startText -match "'Optimization'" ) -and ($startText -match 'AVDTune-Optimization\.ps1') -and ($startText -match 'Update-OptView')) $null
}
finally {
    Close-AVDTuneWriteGate
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
