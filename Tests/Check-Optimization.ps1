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

    # the allow lists are exactly what is shipped: every shipped entry passes (the file is valid), and no list holds more than the file ships
    $opt = Get-Module AVDTune.Optimization
    $listed = & $opt { @{ Reg = @($script:RegAllow.Keys).Count; Task = @($script:TaskAllow.Keys).Count; Appx = @($script:AppxAllow).Count; Svc = @($script:ServiceAllow).Count } }
    Test-Check 'allow list: the lists hold exactly the registry values, tasks, AppX packages and services that the data ships (nothing more)' (($listed.Reg -eq @($entries | Where-Object Kind -eq 'Registry').Count) -and ($listed.Task -eq @($entries | Where-Object Kind -eq 'TaskDisabled').Count) -and ($listed.Appx -eq @($entries | Where-Object Kind -eq 'AppxRemove').Count) -and ($listed.Svc -eq @($entries | Where-Object Kind -eq 'ServiceStartup').Count)) ($listed | ConvertTo-Json -Compress)
    $threat = @($entries | Where-Object { $_.Parameter -like '*ThreatDefaultAction' })
    Test-Check 'data: the four threat default actions are off by default' ($threat.Count -eq 4 -and @($threat | Where-Object Default).Count -eq 0) $null
    # the entries of the behaviour checks are not shipped: they are put on the allow lists of the module here (test only; the production code has no way to do this)
    & $opt {
        foreach ($k in 'HKLM:\SOFTWARE\Policies\AVDTuneTest|Val', 'HKLM:\SOFTWARE\Policies\AVDTuneTest|ValA', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer|Val', 'HKLM:\SOFTWARE\Policies\AVDTuneNew\Sub|Fresh', 'HKLM:\SOFTWARE\Policies\AVDTuneTest|Big') { $script:RegAllow[$k] = 'DWord' }
        $script:RegAllow['HKLM:\SOFTWARE\Policies\AVDTuneTest|ValS'] = 'String'
        foreach ($k in '\Microsoft\Test\|TestTask', '\Microsoft\Test\|NoSuchTask') { $script:TaskAllow[$k] = $true }
        $script:AppxAllow = @($script:AppxAllow) + @('Test.App', 'Test.AppA', 'Test.AppB')
    }
    # ---------------------------------------------------------------- type checks of the data file (counter-tests)
    $src = @([ordered]@{ Id = 'own'; Name = 'Test'; Url = 'https://learn.microsoft.com/en-us/x'; License = 'MIT'; Copyright = 'c'; Checked = '2026-11-15' })
    $base = @{
        Registry = [ordered]@{ Id = 'optimization.t-reg'; Category = 'Registry'; Kind = 'Registry'; Title = 'Test registry'; Why = 'A reason that is long enough.'; Source = 'https://learn.microsoft.com/en-us/x'; Origin = 'own'; Risk = 'Low'; Default = $true; Reboot = $false; Irreversible = $false; Path = 'HKLM:\SOFTWARE\Policies\AVDTuneTest'; Name = 'Val'; Type = 'DWord'; Value = 1 }
        Service = [ordered]@{ Id = 'optimization.t-svc'; Category = 'Service'; Kind = 'ServiceStartup'; Title = 'Test service'; Why = 'A reason that is long enough.'; Source = 'https://learn.microsoft.com/en-us/x'; Origin = 'own'; Risk = 'Low'; Default = $true; Reboot = $false; Irreversible = $false; Name = 'SysMain'; Startup = 'Disabled' }
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
    Test-Bad 'a source with credentials in the URL' Registry { param($e) $e.Source = ('https://user:pw' + [char]64 + 'learn.microsoft.com/x') } 'https URL'
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
    Test-Bad 'a Defender number out of range' Defender { param($e) $e.Value = 7 } 'one of 1, 2'
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
    $B.al = Get-Mut Registry { param($e) $e.Id = 'optimization.al-x'; $e.Category = 'Autologger'; $e.OnlyIfKeyExists = $true; $e.Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\ReadyBoot'; $e.Name = 'Start'; $e.Value = 0; $e.Reboot = $true }
    $B.svc = Get-Mut Service { param($e) $e.Id = 'optimization.svc-a'; $e.Name = 'SysMain' }
    $B.svcx = Get-Mut Service { param($e) $e.Id = 'optimization.svc-missing'; $e.Name = 'MapsBroker' }
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
            Services = @(@{ Name = 'SysMain'; Status = 'Running'; StartType = 'Automatic' })
            Tasks = @(@{ Path = '\Microsoft\Test\'; Name = 'TestTask'; Enabled = $true })
        }
        [void](Add-AVDTuneOptimizationFakeMembers $m -Appx @('Test.AppA', 'Test.AppB') -Defender @{ PUAProtection = [byte]0; UILockdown = $false })
        $m.Store.MpUnreported = @('CloudBlockLevel')
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
    Test-Check 'failure: one failed registry write does not stop the next entry, the saved earlier value stays' ((Get-R $r 'optimization.reg-a').Status -eq 'Failed' -and (Get-R $r 'optimization.reg-s').Status -eq 'Changed' -and $r.Failed -eq 1 -and (Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.reg-a')) $null
    Test-Check 'failure: a failed attempt is a note in the change log' (@(Get-AVDTuneChangeLog -Root $state | Where-Object { $_.ChangeType -eq 'Note' -and $_.Text -like 'Failed (Apply)*' }).Count -ge 1) $null
    Clear-Backups

    # ---------------------------------------------------------------- autologger (only when the logger exists)
    $m = New-TestMachine
    $r = Invoke-Opt $m 'optimization.al-x'
    Test-Check 'autologger: no logger on this machine = Skipped, no key is created' ((Get-R $r 'optimization.al-x').Status -eq 'Skipped' -and -not (@($m.Log) -match 'RegSet')) $null
    $m = New-TestMachine; $m.Store.Registry['hklm:\system\currentcontrolset\control\wmi\autologger\readyboot|start'] = 1
    $r = Invoke-Opt $m 'optimization.al-x'
    Test-Check 'autologger: an existing logger is switched off (Start 0) and the run reports a restart' ($r.Changed -eq 1 -and $r.Reboot -and (& $m.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\ReadyBoot' 'Start') -eq 0) $null
    $u = Invoke-Opt $m 'optimization.al-x' 'Undo'
    Test-Check 'autologger: Undo sets Start back to 1' ($u.Changed -eq 1 -and (& $m.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\ReadyBoot' 'Start') -eq 1) $null

    # ---------------------------------------------------------------- services and tasks
    $m = New-TestMachine
    $r = Invoke-Opt $m 'optimization.svc-a', 'optimization.svc-missing'
    Test-Check 'service: Apply disables it; a service that is not there is Skipped' ((& $m.ServiceGet 'SysMain').StartType -eq 'Disabled' -and (Get-R $r 'optimization.svc-missing').Status -eq 'Skipped' -and (Get-R $r 'optimization.svc-a').Status -eq 'Changed') $null
    $u = Invoke-Opt $m 'optimization.svc-a' 'Undo'
    Test-Check 'service: Undo restores the earlier start type (Automatic)' ((& $m.ServiceGet 'SysMain').StartType -eq 'Automatic' -and $u.Changed -eq 1) $null
    $m = New-TestMachine; $m.Store.Services['sysmain'].StartType = 'Manual'
    [void](Invoke-Opt $m 'optimization.svc-a'); [void](Invoke-Opt $m 'optimization.svc-a' 'Undo')
    Test-Check 'service: a service that was Manual is Manual again after Undo (not forced to Automatic)' ((& $m.ServiceGet 'SysMain').StartType -eq 'Manual') $null
    $m = New-TestMachine; $m.Store.Services['sysmain'].StartType = 'Disabled'
    $r = Invoke-Opt $m 'optimization.svc-a'; $u = Invoke-Opt $m 'optimization.svc-a' 'Undo'
    Test-Check 'service: a service that was Disabled before is Unchanged and Undo does not enable it' ($r.Unchanged -eq 1 -and (Get-R $u 'optimization.svc-a').Status -eq 'Failed' -and (& $m.ServiceGet 'SysMain').StartType -eq 'Disabled') $null
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
    Test-Check 'defender: a refused Set-MpPreference (for example tamper protection) is a failure with the reason, the saved earlier value stays' ((Get-R $r 'optimization.defender-ui').Status -eq 'Failed' -and (Get-R $r 'optimization.defender-ui').Message -like '*refused*' -and (Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.defender-ui')) $null
    Clear-Backups

    # ---------------------------------------------------------------- limits of the engine (security review of #33): the data file and the steps refuse what must never be touched
    function Test-Refused([string]$Name, [string]$Kind, [string]$Category, [hashtable]$Fields, [string]$Pattern = '.') {
        $e = [ordered]@{}; foreach ($k in $base[$Kind].Keys) { $e[$k] = $base[$Kind][$k] }; $e.Category = $Category
        foreach ($k in $Fields.Keys) { $e[$k] = $Fields[$k] }
        $r = Read-Doc @($e)
        Test-Check "limits: $Name is refused by the data check" ((-not $r.Valid) -and $r.Entries.Count -eq 0 -and (($r.Errors -join ' ') -match $Pattern)) ($r.Errors -join '; ')
    }
    function Test-Accepted([string]$Name, [string]$Kind, [string]$Category, [hashtable]$Fields) {
        $e = [ordered]@{}; foreach ($k in $base[$Kind].Keys) { $e[$k] = $base[$Kind][$k] }; $e.Category = $Category
        foreach ($k in $Fields.Keys) { $e[$k] = $Fields[$k] }
        $r = Read-Doc @($e)
        Test-Check "limits: $Name is accepted" ($r.Valid -and $r.Entries.Count -eq 1) ($r.Errors -join '; ')
    }
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
    foreach ($c in @(
            @('Image File Execution Options (Debugger)', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sethc.exe', 'Debugger', 'String', 'C:\Windows\System32\cmd.exe'),
            @('the Run key', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'x', 'String', 'C:\Users\Public\x.exe'),
            @('the Run key in other letter case', 'hklm:\software\microsoft\windows\currentversion\RUN', 'x', 'String', 'C:\x.exe'),
            @('Run below a policy prefix', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run', 'x', 'String', 'C:\x.exe'),
            @('a service key (WinDefend Start)', 'HKLM:\SYSTEM\CurrentControlSet\Services\WinDefend', 'Start', 'DWord', 4),
            @('the Defender policy key', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender', 'DisableAntiSpyware', 'DWord', 1),
            @('the Defender policy key in other letter case', 'HKLM:\SOFTWARE\Policies\Microsoft\WINDOWS DEFENDER\Real-Time Protection', 'DisableRealtimeMonitoring', 'DWord', 1),
            @('the Antimalware policy key', 'HKLM:\SOFTWARE\Policies\Microsoft\Microsoft Antimalware', 'x', 'DWord', 1),
            @('Lsa', 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa', 'RunAsPPL', 'DWord', 0),
            @('a Lsa key below a policy prefix', 'HKLM:\SOFTWARE\Policies\Microsoft\Lsa', 'x', 'DWord', 0),
            @('Windows Update policy', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', 'NoAutoUpdate', 'DWord', 1),
            @('SmartScreen by value name', "$pol\System", 'EnableSmartScreen', 'DWord', 0),
            @('SmartScreen by key', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\SmartScreenSettings', 'x', 'DWord', 0),
            @('Winlogon', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon', 'Shell', 'String', 'x'),
            @('the EventLog key', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\Security', 'MaxSize', 'DWord', 1),
            @('a key outside the policy prefixes', 'HKLM:\SOFTWARE\Contoso\Test', 'x', 'DWord', 1),
            @('the prefix itself', 'HKLM:\SOFTWARE\Policies', 'x', 'DWord', 1),
            @('a path with .. in it', 'HKLM:\SOFTWARE\Policies\..\Microsoft\Test', 'x', 'DWord', 1),
            @('the value name PSPath', 'HKLM:\SOFTWARE\Policies\AVDTuneTest', 'PSPath', 'String', 'x'),
            @('the value name pschildname (other letter case)', 'HKLM:\SOFTWARE\Policies\AVDTuneTest', 'pschildname', 'String', 'x'),
            @('a value name with a trailing line break', 'HKLM:\SOFTWARE\Policies\AVDTuneTest', "Val`n", 'String', 'x'),
            @('a path with a trailing line break', "HKLM:\SOFTWARE\Policies\AVDTuneTest`n", 'Val', 'String', 'x'))) {
        Test-Refused "registry $($c[0])" Registry Registry @{ Path = $c[1]; Name = $c[2]; Type = $c[3]; Value = $c[4] }
    }
    Test-Accepted 'a policy value below SOFTWARE\Policies' Registry Registry @{}
    Test-Accepted 'a policy value below CurrentVersion\Policies' Registry Registry @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' }
    Test-Accepted 'the single FirewallPolicy value' Registry Registry @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy'; Name = 'DeleteUserAppContainersOnLogoff' }
    Test-Refused 'another value in FirewallPolicy' Registry Registry @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy'; Name = 'EnableFirewall' } 'FirewallPolicy'
    Test-Accepted 'a known autologger Start value' Registry Autologger @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\ReadyBoot'; Name = 'Start'; OnlyIfKeyExists = $true }
    Test-Refused 'the EventLog-Security autologger' Registry Autologger @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\EventLog-Security'; Name = 'Start'; OnlyIfKeyExists = $true } 'autologger'
    Test-Refused 'an autologger entry that sets another value' Registry Autologger @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\ReadyBoot'; Name = 'Enabled'; OnlyIfKeyExists = $true } 'autologger'
    Test-Refused 'an autologger entry with a service key path' Registry Autologger @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\WinDefend'; Name = 'Start'; Value = 4; OnlyIfKeyExists = $true } 'autologger'
    Test-Refused 'an autologger path used by the category Registry' Registry Registry @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\ReadyBoot'; Name = 'Start'; Value = 0 } 'not below'
    foreach ($nm in 'WinDefend', 'mpssvc', 'EventLog', 'wuauserv', 'Sense', 'BITS', 'WINDEFEND', 'TermService', 'frxsvc', 'Spooler', 'TrustedInstaller') { Test-Refused "service $nm" Service Service @{ Name = $nm } 'service' }
    Test-Refused 'a service that is not on the list of allowed names' Service Service @{ Name = 'SomeOtherService' } 'not on the list'
    Test-Accepted 'a service of the list (SysMain)' Service Service @{ Name = 'SysMain' }
    foreach ($p in '\Microsoft\Windows\WindowsUpdate\', '\Microsoft\Windows\UpdateOrchestrator\', '\Microsoft\Windows\Windows Defender\', '\Microsoft\Windows\WaaSMedic\', '\MICROSOFT\WINDOWS\WINDOWSUPDATE\') { Test-Refused "task path $p" Task Task @{ TaskPath = $p } 'never changed' }
    Test-Accepted 'a task outside the protected places' Task Task @{}
    foreach ($nm in 'Microsoft.WindowsStore', 'Microsoft.SecHealthUI', 'Microsoft.DesktopAppInstaller', 'Microsoft.AAD.BrokerPlugin', 'Microsoft.Windows.ShellExperienceHost', 'Microsoft.Windows.StartMenuExperienceHost', 'Microsoft.VCLibs.140.00', 'Microsoft.UI.Xaml.2.8', 'Microsoft.NET.Native.Runtime.2.2', 'MSTeams', 'microsoft.windowsstore') { Test-Refused "AppX $nm" Appx Appx @{ PackageName = $nm } 'protected' }
    Test-Accepted 'an AppX package that may go (Microsoft.BingNews)' Appx Appx @{ PackageName = 'Microsoft.BingNews' }
    foreach ($c in @(@('SevereThreatDefaultAction', 6), @('HighThreatDefaultAction', 9), @('LowThreatDefaultAction', 1), @('ModerateThreatDefaultAction', 8), @('MAPSReporting', 0), @('PUAProtection', 0), @('CloudBlockLevel', 0), @('SignatureUpdateInterval', 0), @('SignatureUpdateInterval', 25), @('DisableCatchupQuickScan', $true), @('DisableLocalAdminMerge', $false), @('UILockdown', $false), @('CheckForSignaturesBeforeRunningScan', $false), @('RandomizeScheduleTaskTimes', $false))) {
        Test-Refused "Defender $($c[0]) = $($c[1])" Defender Defender @{ Parameter = $c[0]; Value = $c[1] }
    }
    foreach ($c in @(@('SevereThreatDefaultAction', 2), @('HighThreatDefaultAction', 3), @('MAPSReporting', 2), @('PUAProtection', 1), @('CloudBlockLevel', 6), @('SignatureUpdateInterval', 24), @('DisableCatchupQuickScan', $false))) {
        Test-Accepted "Defender $($c[0]) = $($c[1])" Defender Defender @{ Parameter = $c[0]; Value = $c[1] }
    }
    # a step cannot be built from a hand-made entry that breaks the limits (the data check is not the only gate)
    $forged = [pscustomobject]@{ Id = 'optimization.forged'; Category = 'Appx'; Kind = 'AppxRemove'; Title = 'x'; Why = 'x'; Source = 'https://learn.microsoft.com/x'; Origin = 'own'; Risk = 'Low'; Default = $true; Reboot = $false; Irreversible = $true; PackageName = 'Microsoft.WindowsStore' }
    Test-Check 'limits: a step is not built for a forged AppX entry (Store)' (Test-Throws { New-AVDTuneOptimizationStep -Entry $forged -Root $state }) $null
    $forged2 = [pscustomobject]@{ Id = 'optimization.forged2'; Category = 'Registry'; Kind = 'Registry'; Title = 'x'; Why = 'x'; Source = 'https://learn.microsoft.com/x'; Origin = 'own'; Risk = 'Low'; Default = $true; Reboot = $false; Irreversible = $false; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Name = 'x'; Type = 'String'; Value = 'x'; OnlyIfKeyExists = $false }
    Test-Check 'limits: a step is not built for a forged registry entry (Run key)' (Test-Throws { New-AVDTuneOptimizationStep -Entry $forged2 -Root $state }) $null
    $forged3 = [pscustomobject]@{ Id = 'optimization.forged3'; Category = 'Defender'; Kind = 'DefenderPref'; Title = 'x'; Why = 'x'; Source = 'https://learn.microsoft.com/x'; Origin = 'own'; Risk = 'Low'; Default = $true; Reboot = $false; Irreversible = $false; Parameter = 'PUAProtection'; Value = 0 }
    Test-Check 'limits: a step is not built for a forged Defender entry (PUAProtection 0)' (Test-Throws { New-AVDTuneOptimizationStep -Entry $forged3 -Root $state }) $null
    # the members of the real machine check again before any cmdlet or registry access (these calls refuse first, so nothing is touched)
    $rm = New-AVDTuneMachine; [void](Add-AVDTuneOptimizationMachineMembers -Machine $rm)
    Test-Check 'limits: the real AppX member refuses protected packages and wildcards before it calls a cmdlet' ((Test-Throws { & $rm.AppxRemove 'Microsoft.WindowsStore' }) -and (Test-Throws { & $rm.AppxRemove 'Microsoft.VCLibs.140.00' }) -and (Test-Throws { & $rm.AppxRemove 'Microsoft.*' }) -and (Test-Throws { & $rm.AppxRemove "Microsoft.BingNews`n" }) -and (Test-Throws { & $rm.AppxState "Microsoft.BingNews`n" })) $null
    Test-Check 'limits: the real Defender member refuses weakening values and unknown names' ((Test-Throws { & $rm.MpSet 'PUAProtection' 0 }) -and (Test-Throws { & $rm.MpSet 'SevereThreatDefaultAction' 6 }) -and (Test-Throws { & $rm.MpSet 'DisableRealtimeMonitoring' $true }) -and (Test-Throws { & $rm.MpSet 'UILockdown' 'true' $true }) -and (Test-Throws { & $rm.MpGet 'DisableRealtimeMonitoring' })) $null
    Test-Check 'limits: the real registry members refuse protected keys, other hives and bad value names before they open anything' ((Test-Throws { & $rm.RegInfo 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'x' }) -and (Test-Throws { & $rm.RegInfo 'HKCU:\SOFTWARE\Policies\x' 'x' }) -and (Test-Throws { & $rm.RegInfo 'HKLM:\SOFTWARE\Policies\Test' 'PSPath' }) -and (Test-Throws { & $rm.RegInfo "HKLM:\SOFTWARE\Policies\Test`n" 'x' }) -and (Test-Throws { & $rm.RegKeyRemoveEmpty 'HKLM:\SYSTEM\CurrentControlSet\Services\WinDefend' }) -and (Test-Throws { & $rm.RegKeyRemoveEmpty 'HKLM:\SOFTWARE\Policies' })) $null
    Test-Check 'limits: the real Defender member accepts a restore of the earlier type (the check passes, no call is made here)' ((Get-OptDefenderProblem -Parameter 'PUAProtection' -Value 0 -Restore) -eq $null -and (Get-OptDefenderProblem -Parameter 'PUAProtection' -Value 'x' -Restore)) $null

    # ---------------------------------------------------------------- the saved earlier values stay on any failure, status does not depend on message text
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'
    Clear-Backups
    $m = New-TestMachine
    $store = $m.Store
    $mg = { param($Name) if ($store.Mp['PUAProtection'] -eq 1) { throw 'transient WMI error' }; $store.Mp[$Name] }.GetNewClosure()
    $m.MpGet = $mg
    $r = Invoke-Opt $m 'optimization.defender-pua'
    Test-Check 'backup: when the test after Apply throws, the entry fails but its saved earlier value (0) stays and the change is reported' ((Get-R $r 'optimization.defender-pua').Status -eq 'Failed' -and $store.Mp['PUAProtection'] -eq 1 -and ((Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.defender-pua').Value -eq 0)) (Get-R $r 'optimization.defender-pua').Message
    $m = New-TestMachine; $m.Store.FailWrites = @('vala')
    $r = Invoke-Opt $m 'optimization.reg-a'
    Test-Check 'backup: a failed write keeps the saved value (the earlier 5), and Undo then has something to work with' ((Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.reg-a').Value -eq 5) $null
    Clear-Backups
    $bf = Join-Path $state 'config\optimization-backup.json'
    New-Item -ItemType Directory -Path (Split-Path $bf) -Force | Out-Null
    foreach ($content in @('   ', 'null', '{"Schema":1}', '{"Schema":2,"Items":{}}', '{"Schema":"1","Items":{}}', '{"Schema":1,"Items":[]}', '[1,2]')) {
        [IO.File]::WriteAllText($bf, $content)
        $threw = Test-Throws { Save-AVDTuneOptimizationBackup -Root $state -Id 'optimization.x' -Record @{ Kind = 'Registry'; Exists = $true; Value = 7 } }
        Test-Check "backup: a backup file with the content '$content' is refused and left as it is" ($threw -and ([IO.File]::ReadAllText($bf) -eq $content)) $null
    }
    $m = New-TestMachine
    $r = Invoke-Opt $m 'optimization.reg-a'
    Test-Check 'backup: Apply with a damaged backup file fails before the change' ((Get-R $r 'optimization.reg-a').Status -eq 'Failed' -and (& $m.RegGet 'HKLM:\SOFTWARE\Policies\AVDTuneTest' 'ValA') -eq 5) $null
    Clear-Backups

    # ---------------------------------------------------------------- LastChange before the first change and after a run that is cut short
    $stateFile = Join-Path $state 'state.json'
    $m = New-TestMachine
    [void](Set-AVDTuneState -Root $state -Values @{ LastChange = $null })
    $seen = New-Object System.Collections.ArrayList
    $regSet = $m.RegSet; $storeLc = $state
    $m.RegSet = { param($Path, $Name, $Value, $Type) [void]$seen.Add([string](Get-AVDTuneLastChange -Root $storeLc)); & $regSet $Path $Name $Value $Type }.GetNewClosure()
    $r = Invoke-Opt $m 'optimization.reg-a'
    Test-Check 'lastchange: it is set BEFORE the first write of the run' ($seen.Count -eq 1 -and $seen[0] -ne '') ($seen -join ',')
    Clear-Backups
    [void](Set-AVDTuneState -Root $state -Values @{ LastChange = $null })
    $m = New-TestMachine
    $m.Store.FailWrites = @('vals')
    $r = Invoke-Opt $m 'optimization.reg-a', 'optimization.reg-s'
    Test-Check 'lastchange: a run with one change and one failure sets it' ([bool](Get-AVDTuneProp (Get-AVDTuneState $state) 'LastChange')) $null
    Clear-Backups
    [void](Set-AVDTuneState -Root $state -Values @{ LastChange = $null })
    $m = New-TestMachine
    $r = Invoke-Opt $m 'optimization.reg-a' -WhatIf
    Test-Check 'lastchange: WhatIf never sets it' (-not (Get-AVDTuneProp (Get-AVDTuneState $state) 'LastChange')) $null
    [void](Set-AVDTuneState -Root $state -Values @{ LastChange = $null })
    $m = New-TestMachine; [void](Invoke-Opt $m 'optimization.reg-a'); [void](Set-AVDTuneState -Root $state -Values @{ LastChange = $null })
    [void](Invoke-Opt $m 'optimization.reg-a')
    Test-Check 'lastchange: a run that changes nothing (all in place) does not set it' (-not (Get-AVDTuneProp (Get-AVDTuneState $state) 'LastChange')) $null
    $u = Invoke-Opt $m 'optimization.reg-a' 'Undo'
    Test-Check 'lastchange: Undo sets it' ([bool](Get-AVDTuneProp (Get-AVDTuneState $state) 'LastChange')) $null
    Clear-Backups

    # ---------------------------------------------------------------- the registry type, keys that were created, delayed start, Defender values
    $m = New-TestMachine
    $m.Store.Registry['hklm:\software\policies\avdtunetest|vala'] = '7'    # a String where the entry wants a DWord
    [void](Invoke-Opt $m 'optimization.reg-a')
    $bk = Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.reg-a'
    Test-Check 'registry: the type of the earlier value is saved (String 7)' ($bk.ValueKind -eq 'String' -and $bk.Value -eq '7') ($bk | ConvertTo-Json -Compress)
    $u = Invoke-Opt $m 'optimization.reg-a' 'Undo'
    Test-Check 'registry: Undo restores the earlier value with its own type (String)' ($u.Changed -eq 1 -and @($m.Log | Where-Object { $_ -like 'RegSet HKLM:\SOFTWARE\Policies\AVDTuneTest|ValA=7 (String)' }).Count -eq 1) (@($m.Log) -join ' | ')
    Clear-Backups
    $m = New-TestMachine
    $m.Store.Registry['hklm:\software\policies\avdtunetest|vala'] = 5; $m.Store.RegKinds['hklm:\software\policies\avdtunetest|vala'] = 'Binary'
    $r = Invoke-Opt $m 'optimization.reg-a'
    Test-Check 'registry: a value of a type that cannot be saved and restored (Binary) is not touched' ((Get-R $r 'optimization.reg-a').Status -eq 'Failed' -and (Get-R $r 'optimization.reg-a').Message -like '*cannot save and restore*' -and -not (Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.reg-a')) (Get-R $r 'optimization.reg-a').Message
    Clear-Backups
    $newKeyEntry = Get-Mut Registry { param($e) $e.Id = 'optimization.reg-new'; $e.Path = 'HKLM:\SOFTWARE\Policies\AVDTuneNew\Sub'; $e.Name = 'Fresh'; $e.Value = 1 }
    $newDoc = Join-Path $tmp 'newkey.json'
    [IO.File]::WriteAllText($newDoc, ([ordered]@{ SchemaVersion = 1; Sources = $src; Entries = @($newKeyEntry) } | ConvertTo-Json -Depth 6))
    $m = New-TestMachine
    [void](Invoke-AVDTuneOptimization -Machine $m -Root $state -DataPath $newDoc -Ids 'optimization.reg-new' -User 'admin1')
    $bk = Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.reg-new'
    Test-Check 'registry: the keys that this run created are noted (AVDTuneNew and AVDTuneNew\Sub)' (@($bk.KeyCreated).Count -eq 2 -and $bk.Exists -eq $false) ($bk | ConvertTo-Json -Compress)
    $u = Invoke-AVDTuneOptimization -Machine $m -Root $state -DataPath $newDoc -Ids 'optimization.reg-new' -Mode Undo -User 'admin1'
    $removed = @($m.Log | Where-Object { $_ -like 'RegKeyRemoveEmpty*' })
    Test-Check 'registry: Undo removes the value and then the created keys, deepest first, and no other key' ($u.Changed -eq 1 -and $removed.Count -eq 2 -and $removed[0] -like '*AVDTuneNew\Sub' -and $removed[1] -like '*AVDTuneNew') ($removed -join ' | ')
    Clear-Backups
    # delayed start
    $m = New-TestMachine
    $m.Store.Registry['hklm:\system\currentcontrolset\services\sysmain|delayedautostart'] = 1
    [void](Invoke-Opt $m 'optimization.svc-a')
    Test-Check 'service: the delayed start flag is saved with the start type' ((Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.svc-a').DelayedAutostart -eq 1) $null
    $m.Store.Registry.Remove('hklm:\system\currentcontrolset\services\sysmain|delayedautostart')    # Windows may clear the flag when the start type changes
    [void](Invoke-Opt $m 'optimization.svc-a' 'Undo')
    Test-Check 'service: Undo brings back Automatic and the delayed start flag' ((& $m.ServiceGet 'SysMain').StartType -eq 'Automatic' -and (& $m.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Services\SysMain' 'DelayedAutostart') -eq 1) $null
    Clear-Backups
    # Defender: a value that Windows reports as 0 when it was never set is saved as 0 (like the real system) and restored by Undo with the restore flag
    $m = New-TestMachine
    [void](Invoke-Opt $m 'optimization.defender-pua'); [void](Invoke-Opt $m 'optimization.defender-pua' 'Undo')
    Test-Check 'defender: Undo restores the 0 that Windows reported and uses the restore path (the type is checked, not the protecting values)' ($m.Store.Mp['PUAProtection'] -eq 0 -and @($m.Log | Where-Object { $_ -eq 'MpSet PUAProtection=0 restore=True' }).Count -eq 1) (@($m.Log) -join ' | ')
    [void](Invoke-Opt $m 'optimization.defender-pua')
    [IO.File]::WriteAllText($bf, ((Get-Content $bf -Raw) -replace '"Value":\s*0', '"Value": "x"'))
    $u = Invoke-Opt $m 'optimization.defender-pua' 'Undo'
    Test-Check 'defender: a damaged saved value (text for a number) is refused at Undo and the setting stays' ((Get-R $u 'optimization.defender-pua').Status -eq 'Failed' -and $m.Store.Mp['PUAProtection'] -eq 1) (Get-R $u 'optimization.defender-pua').Message
    Clear-Backups
    $dt = @($entries | Where-Object { $_.Name -eq 'DiagTrack' -or $_.TaskName -eq 'Microsoft Compatibility Appraiser' })
    Test-Check 'data: DiagTrack and the Compatibility Appraiser are Medium risk and off by default, with the reason that names Defender for Endpoint and the reports' ($dt.Count -eq 2 -and @($dt | Where-Object { $_.Default -or $_.Risk -ne 'Medium' }).Count -eq 0 -and ($dt[0].Why -like '*Defender for Endpoint*' -or $dt[1].Why -like '*Defender for Endpoint*') -and ($dt | Where-Object Why -like '*Windows Update for Business*').Count -eq 2) $null

    # ---------------------------------------------------------------- follow-up of the security re-check (#33): closures, ThreatDefaultAction unset, allow lists, syntax, value ranges
    function Invoke-OptGate { Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'; Invoke-AVDTuneOptimization @args }
    function Invoke-Opt($Machine, [string[]]$Ids, [string]$Mode = 'Apply', [switch]$Confirm, [switch]$WhatIf) { Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'; Invoke-AVDTuneOptimization -Machine $Machine -Root $state -DataPath $small -Ids $Ids -Mode $Mode -ConfirmIrreversible:$Confirm -User 'admin1' -SnapshotId 'snap-1' -WhatIf:$WhatIf }
    function New-OpenMachine { Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'; New-TestMachine }
    # N1: the check of the real registry members must work on a real machine (it ran in a closure where the $script: lists were empty and refused every path)
    function Test-NotRefused([scriptblock]$Block) { try { & $Block | Out-Null; $true } catch { -not ($_.Exception.Message -match 'Refused|Invalid registry|not on the list') } }
    Test-Check 'closures: the real RegInfo member reads an allowed policy path (read only) and does not answer Refused' (Test-NotRefused { & $rm.RegInfo 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'DisableAcrylicBackgroundOnLogon' }) $null
    Test-Check 'closures: the real RegInfo member reads an allowed autologger Start and the FirewallPolicy value (read only) without Refused' ((Test-NotRefused { & $rm.RegInfo 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\ReadyBoot' 'Start' }) -and (Test-NotRefused { & $rm.RegInfo 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy' 'DeleteUserAppContainersOnLogoff' })) $null
    Test-Check 'closures: the key check of RegKeyRemoveEmpty accepts a key of the list and its parents, and refuses others (no key is removed here)' (-not (Test-Throws { Assert-OptRegistryAccess -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name $null }) -and -not (Test-Throws { Assert-OptRegistryAccess -Path 'HKLM:\SOFTWARE\Policies\Microsoft' -Name $null }) -and (Test-Throws { Assert-OptRegistryAccess -Path 'HKLM:\SOFTWARE\Policies\Contoso' -Name $null }) -and (Test-Throws { Assert-OptRegistryAccess -Path 'HKLM:\SOFTWARE\Policies' -Name $null })) $null
    Test-Check 'closures: the real MpGet member answers for a setting of the list (read only) without the list error' (Test-NotRefused { & $rm.MpGet 'PUAProtection' }) $null
    $modAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Modules\AVDTune.Optimization.psm1'), [ref]$null, [ref]$null)
    $closures = @($modAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $a.Member.Value -eq 'GetNewClosure' }, $true))
    $scriptVars = @($closures | ForEach-Object { $_.Expression.FindAll({ param($v) $v -is [System.Management.Automation.Language.VariableExpressionAst] -and $v.VariablePath.IsScript }, $true) })
    Test-Check 'closures: no GetNewClosure block of the module uses a $script: variable (they are empty in a closure)' ($closures.Count -gt 10 -and $scriptVars.Count -eq 0) "closures=$($closures.Count) scriptvars=$($scriptVars.Count)"

    # N2: ThreatDefaultAction has no 0 (Clean=1 ... None=11): unset is noted in the backup, Undo gives nothing to Set-MpPreference
    $thrEntry = Get-Mut Defender { param($e) $e.Id = 'optimization.defender-low'; $e.Parameter = 'LowThreatDefaultAction'; $e.Value = 2; $e.Default = $false }
    $thrDoc = Join-Path $tmp 'threat.json'
    [IO.File]::WriteAllText($thrDoc, ([ordered]@{ SchemaVersion = 1; Sources = $src; Entries = @($thrEntry) } | ConvertTo-Json -Depth 6))
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'
    Clear-Backups
    $m = New-OpenMachine; $m.Store.Mp['LowThreatDefaultAction'] = 0
    Test-Check 'threat action: the fake enforces the real enum (0 and 5 are refused, 2 and 11 are accepted)' ((Test-Throws { & $m.MpSet 'LowThreatDefaultAction' 0 $true }) -and (Test-Throws { & $m.MpSet 'SevereThreatDefaultAction' 5 $true }) -and -not (Test-Throws { & $m.MpSet 'HighThreatDefaultAction' 11 $true }) -and -not (Test-Throws { & $m.MpSet 'ModerateThreatDefaultAction' 2 })) $null
    $m = New-OpenMachine; $m.Store.Mp['LowThreatDefaultAction'] = 0
    $r = Invoke-OptGate -Machine $m -Root $state -DataPath $thrDoc -Ids 'optimization.defender-low' -User 'admin1'
    $bk = Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.defender-low'
    Test-Check 'threat action: Apply sets 2, and the backup of the earlier 0 says unset (no value, no restore later)' ($r.Changed -eq 1 -and $m.Store.Mp['LowThreatDefaultAction'] -eq 2 -and $bk.Unset -eq $true -and $null -eq $bk.Value) ($bk | ConvertTo-Json -Compress)
    $lc = (Get-AVDTuneState $state).LastChange; $logN = @($m.Log).Count
    $u = Invoke-OptGate -Machine $m -Root $state -DataPath $thrDoc -Ids 'optimization.defender-low' -Mode Undo -User 'admin1'
    $ur = Get-R $u 'optimization.defender-low'
    Test-Check 'threat action: Undo of an unset value gives nothing to Set-MpPreference, the setting stays, status Reverted with the hint' ($ur.Status -eq 'Reverted' -and $ur.Message -like '*no previous value*' -and $ur.Message -like '*Defender policy*' -and $m.Store.Mp['LowThreatDefaultAction'] -eq 2 -and @($m.Log).Count -eq $logN) ($ur | ConvertTo-Json -Compress)
    Test-Check 'threat action: Undo releases the backup, and an Undo that changes no machine value does not move LastChange' (-not (Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.defender-low') -and (Get-AVDTuneState $state).LastChange -eq $lc) $null
    $m = New-OpenMachine; $m.Store.Mp['LowThreatDefaultAction'] = 3
    [void](Invoke-OptGate -Machine $m -Root $state -DataPath $thrDoc -Ids 'optimization.defender-low' -User 'admin1')
    $bk = Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.defender-low'
    $u = Invoke-OptGate -Machine $m -Root $state -DataPath $thrDoc -Ids 'optimization.defender-low' -Mode Undo -User 'admin1'
    Test-Check 'threat action: an earlier real value (3 = Remove) is not unset and is given back by the restore path' ($bk.Unset -eq $false -and $bk.Value -eq 3 -and $m.Store.Mp['LowThreatDefaultAction'] -eq 3 -and @($m.Log | Where-Object { $_ -eq 'MpSet LowThreatDefaultAction=3 restore=True' }).Count -eq 1) (@($m.Log) -join ' | ')
    $m = New-OpenMachine; $m.Store.Mp['LowThreatDefaultAction'] = 3
    [void](Invoke-OptGate -Machine $m -Root $state -DataPath $thrDoc -Ids 'optimization.defender-low' -User 'admin1')
    $bf = Join-Path $state 'config\optimization-backup.json'
    function Edit-Backup([string]$Id, [scriptblock]$Change) { $d = Get-Content $bf -Raw | ConvertFrom-Json; & $Change $d.Items.$Id; [IO.File]::WriteAllText($bf, ($d | ConvertTo-Json -Depth 6)) }
    Edit-Backup 'optimization.defender-low' { param($i) $i.Value = 0; $i.Unset = $false }
    $u = Invoke-OptGate -Machine $m -Root $state -DataPath $thrDoc -Ids 'optimization.defender-low' -Mode Undo -User 'admin1'
    Test-Check 'threat action: a backup with the value 0 that is not marked unset is refused at Undo (not in the enum), the setting stays' ((Get-R $u 'optimization.defender-low').Status -eq 'Failed' -and $m.Store.Mp['LowThreatDefaultAction'] -eq 2) (Get-R $u 'optimization.defender-low').Message
    Clear-Backups

    # N3: allow lists (instead of prefix plus deny list), syntax of '.', '..', '*', PSPath in every gate
    Test-Refused 'a registry value that is not shipped (new name in a known key)' Registry Registry @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'SomethingElse' } 'allow list'
    Test-Refused 'a registry key that is not shipped (below the policy prefix)' Registry Registry @{ Path = 'HKLM:\SOFTWARE\Policies\Contoso\Thing'; Name = 'x' } 'allow list'
    Test-Refused 'a known value with the type String instead of DWord' Registry Registry @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'DisableAcrylicBackgroundOnLogon'; Type = 'String'; Value = '1' } 'type'
    Test-Refused 'a task that is not shipped' Task Task @{ TaskName = 'NotShipped' } 'allow list'
    Test-Refused 'an AppX package that is not shipped' Appx Appx @{ PackageName = 'Microsoft.SomethingNew' } 'allow list'
    Test-Refused 'a path segment . ' Registry Registry @{ Path = 'HKLM:\SOFTWARE\Policies\.\AVDTuneTest' } 'below HKLM'
    Test-Refused 'a path segment .. at the end' Registry Registry @{ Path = 'HKLM:\SOFTWARE\Policies\AVDTuneTest\..' } 'below HKLM'
    Test-Check 'syntax: Get-OptRegistryProblem itself refuses . and .. segments, PSPath, and an empty segment' ((@('HKLM:\SOFTWARE\Policies\.\AVDTuneTest', 'HKLM:\SOFTWARE\Policies\..\Microsoft', 'HKLM:\SOFTWARE\Policies\\AVDTuneTest') | Where-Object { -not (Get-OptRegistryProblem -Category Registry -Path $_ -Name 'Val') }).Count -eq 0 -and (Get-OptRegistryProblem -Category Registry -Path 'HKLM:\SOFTWARE\Policies\AVDTuneTest' -Name 'PSPath')) $null
    $mk = { param($kind, $over) $e = [ordered]@{}; foreach ($k in $base[$kind].Keys) { $e[$k] = $base[$kind][$k] }; foreach ($k in $over.Keys) { $e[$k] = $over[$k] }; if ($kind -eq 'Registry' -and -not $e.Contains('OnlyIfKeyExists')) { $e.OnlyIfKeyExists = $false }; [pscustomobject]$e }
    $hand = @(
        @('a registry name with *', (& $mk Registry @{ Name = '*' })), @('a registry name PSPath', (& $mk Registry @{ Name = 'PSPath' })), @('a registry path with *', (& $mk Registry @{ Path = 'HKLM:\SOFTWARE\Policies\*' })),
        @('a registry path with ..', (& $mk Registry @{ Path = 'HKLM:\SOFTWARE\Policies\..\Run' })), @('a service with *', (& $mk Service @{ Name = 'SysM*' })), @('a task name with *', (& $mk Task @{ TaskName = '*' })),
        @('a task path with ..', (& $mk Task @{ TaskPath = '\Microsoft\..\Test\' })), @('an AppX name with *', (& $mk Appx @{ PackageName = 'Test.*' })), @('a DWord that is text', (& $mk Registry @{ Value = '1' }))
    )
    foreach ($h in $hand) { Test-Check "syntax: a hand-made entry with $($h[0]) gets no step (same check as the data check)" (Test-Throws { New-AVDTuneOptimizationStep -Entry $h[1] -Root $state }) $null }
    Test-Check 'syntax: a hand-made entry that is on the lists still builds a step' (-not (Test-Throws { New-AVDTuneOptimizationStep -Entry (& $mk Registry @{ Name = 'ValA' }) -Root $state })) (Get-OptEntryProblem (& $mk Registry @{ Name = 'ValA' }))

    # DWord with bit 31 (read as unsigned, restore takes the full DWord range) and the range of restore values
    Clear-Backups
    $m = New-OpenMachine; $m.Store.Registry['hklm:\software\policies\avdtunetest|vala'] = [int]-1
    [void](Invoke-Opt $m 'optimization.reg-a')
    $bk = Get-AVDTuneOptimizationBackup -Root $state -Id 'optimization.reg-a'
    Test-Check 'dword: a value with bit 31 (stored as -1) is saved as the unsigned 4294967295' ($bk.Value -eq 4294967295 -and $bk.ValueKind -eq 'DWord') ($bk | ConvertTo-Json -Compress)
    $u = Invoke-Opt $m 'optimization.reg-a' 'Undo'
    Test-Check 'dword: Undo restores it (given to the registry with the same bits) and accepts the full DWord range' ($u.Changed -eq 1 -and $m.Store.Registry['hklm:\software\policies\avdtunetest|vala'] -eq -1) ((@($m.Log) -join ' | ') + ' ' + (@($u.Results.Message) -join ' '))
    Test-Check 'dword: the unsigned range is checked (0..4294967295; 4294967296, -1 and text are not DWord values; String up to 4096 characters)' (-not (Get-OptRestoreProblem -Kind DWord -Value 4294967295) -and (Get-OptRestoreProblem -Kind DWord -Value 4294967296) -and (Get-OptRestoreProblem -Kind DWord -Value -1) -and (Get-OptRestoreProblem -Kind DWord -Value '5') -and (Get-OptRestoreProblem -Kind String -Value ('x' * 4097)) -and -not (Get-OptRestoreProblem -Kind String -Value 'abc') -and (Get-OptRestoreProblem -Kind Binary -Value 1)) $null
    Clear-Backups
    foreach ($c in @(@('a DWord above 4294967295', { param($i) $i.Value = 4294967296 }), @('a negative DWord', { param($i) $i.Value = -5 }), @('a kind that is not a registry kind', { param($i) $i.ValueKind = 'Binary' }), @('a backup of another kind', { param($i) $i.Kind = 'ServiceStartup' }), @('a backup for another value name', { param($i) $i.Name = 'Other' }), @('a backup for another key', { param($i) $i.Path = 'HKLM:\SOFTWARE\Policies\Other' }))) {
        $m = New-OpenMachine
        [void](Invoke-Opt $m 'optimization.reg-a')
        Edit-Backup 'optimization.reg-a' $c[1]
        $u = Invoke-Opt $m 'optimization.reg-a' 'Undo'
        Test-Check "restore range: $($c[0]) in the backup is refused at Undo and the value stays" ((Get-R $u 'optimization.reg-a').Status -eq 'Failed' -and (& $m.RegGet 'HKLM:\SOFTWARE\Policies\AVDTuneTest' 'ValA') -eq 1) (Get-R $u 'optimization.reg-a').Message
        Clear-Backups
    }
    foreach ($c in @(@('a value above the range of PUAProtection', { param($i) $i.Value = 9 }), @('a backup for another setting', { param($i) $i.Parameter = 'UILockdown' }), @('a backup of another kind', { param($i) $i.Kind = 'Registry' }))) {
        $m = New-OpenMachine
        [void](Invoke-Opt $m 'optimization.defender-pua')
        Edit-Backup 'optimization.defender-pua' $c[1]
        $u = Invoke-Opt $m 'optimization.defender-pua' 'Undo'
        Test-Check "restore range: Defender, $($c[0]), is refused at Undo and the setting stays" ((Get-R $u 'optimization.defender-pua').Status -eq 'Failed' -and $m.Store.Mp['PUAProtection'] -eq 1) (Get-R $u 'optimization.defender-pua').Message
        Clear-Backups
    }
    Test-Check 'restore range: Defender restore limits (PUAProtection 0..2, threat actions only the enum, booleans any boolean)' (-not (Get-OptDefenderProblem -Parameter PUAProtection -Value 2 -Restore) -and (Get-OptDefenderProblem -Parameter PUAProtection -Value 3 -Restore) -and (Get-OptDefenderProblem -Parameter PUAProtection -Value -1 -Restore) -and (Get-OptDefenderProblem -Parameter LowThreatDefaultAction -Value 0 -Restore) -and -not (Get-OptDefenderProblem -Parameter LowThreatDefaultAction -Value 11 -Restore) -and (Get-OptDefenderProblem -Parameter LowThreatDefaultAction -Value 4 -Restore) -and -not (Get-OptDefenderProblem -Parameter UILockdown -Value $false -Restore)) $null

    # fake RegKeyRemoveEmpty: only when the key is empty (like the real member)
    $m = New-OpenMachine
    $m.Store.Keys['hklm:\software\policies\avdtunekeep'] = $true; $m.Store.Registry['hklm:\software\policies\avdtunekeep|x'] = 1
    $m.Store.Keys['hklm:\software\policies\avdtuneparent'] = $true; $m.Store.Keys['hklm:\software\policies\avdtuneparent\child'] = $true
    $m.Store.Keys['hklm:\software\policies\avdtuneempty'] = $true
    foreach ($k in 'AVDTuneKeep', 'AVDTuneParent', 'AVDTuneEmpty') { & $m.RegKeyRemoveEmpty "HKLM:\SOFTWARE\Policies\$k" }
    Test-Check 'fake RegKeyRemoveEmpty: a key with a value or a sub key stays, an empty key goes' ((& $m.RegKeyExists 'HKLM:\SOFTWARE\Policies\AVDTuneKeep') -and (& $m.RegKeyExists 'HKLM:\SOFTWARE\Policies\AVDTuneParent') -and -not (& $m.RegKeyExists 'HKLM:\SOFTWARE\Policies\AVDTuneEmpty') -and @($m.Log | Where-Object { $_ -like 'RegKeyRemoveEmpty*' }).Count -eq 1 -and @($m.Log | Where-Object { $_ -like 'RegKeyKept*' }).Count -eq 2) (@($m.Log) -join ' | ')
    $m = New-OpenMachine
    [void](Invoke-OptGate -Machine $m -Root $state -DataPath $newDoc -Ids 'optimization.reg-new' -User 'admin1')
    $m.Store.Registry['hklm:\software\policies\avdtunenew\sub|other'] = 1     # somebody else put a value into the key after Apply
    $u = Invoke-OptGate -Machine $m -Root $state -DataPath $newDoc -Ids 'optimization.reg-new' -Mode Undo -User 'admin1'
    Test-Check 'registry: Undo does not remove a created key that has a foreign value in the meantime (key and its parent stay)' ($u.Changed -eq 1 -and @($m.Log | Where-Object { $_ -like 'RegKeyRemoveEmpty*' }).Count -eq 0 -and @($m.Log | Where-Object { $_ -like 'RegKeyKept*' }).Count -eq 2 -and $m.Store.Registry.ContainsKey('hklm:\software\policies\avdtunenew\sub|other')) (@($m.Log) -join ' | ')
    Clear-Backups
    Close-AVDTuneWriteGate

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
    Test-Check 'default profile (#40): the status loads the hive once, reads the UserHive rows from it and unloads it again' ($m.Store.Hive.Loads -eq 1 -and $m.Store.Hive.Unloads -eq 1 -and -not $m.Store.Hive.Loaded -and @($st.Rows | Where-Object { $_.Kind -eq 'UserHive' -and $_.State -eq 'not set' }).Count -eq 4) (@($m.Log) -join ' | ')
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- default user profile (#40): UserHive entries in NTUSER.DAT of the default profile
    function Invoke-Hive($Machine, [string[]]$Ids, [string]$Mode = 'Apply') { Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'; Invoke-AVDTuneOptimization -Machine $Machine -Root $state -Ids $Ids -Mode $Mode -User 'admin1' -SnapshotId 'snap-1' }
    $ctx = 'optimization.user-classic-context-menu'; $sbx = 'optimization.user-search-box-suggestions'; $msd = 'optimization.user-menu-show-delay'
    $clsid = 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
    $byId = @{}; foreach ($e in $entries) { $byId[$e.Id] = $e }
    Test-Check 'default profile: the three wanted entries are shipped with path, name, type and value, in Recommended (default on, risk Low)' (
        $byId[$ctx] -and $byId[$ctx].Path -eq "$clsid\InprocServer32" -and $byId[$ctx].Name -eq '' -and $byId[$ctx].Type -eq 'String' -and $byId[$ctx].Value -eq '' -and
        $byId[$sbx] -and $byId[$sbx].Path -eq 'Software\Policies\Microsoft\Windows\Explorer' -and $byId[$sbx].Type -eq 'DWord' -and $byId[$sbx].Value -eq 1 -and
        $byId[$msd] -and $byId[$msd].Path -eq 'Control Panel\Desktop' -and $byId[$msd].Name -eq 'MenuShowDelay' -and $byId[$msd].Type -eq 'String' -and $byId[$msd].Value -eq '100' -and
        @($ctx, $sbx, $msd | Where-Object { $_ -notin $rec -or $byId[$_].Risk -ne 'Low' -or $byId[$_].Category -ne 'UserHive' }).Count -eq 0) $null
    $hiveListed = & $opt { @($script:HiveAllow.Keys).Count }
    Test-Check 'default profile: the allow list holds exactly the shipped UserHive values' ($hiveListed -eq @($entries | Where-Object Kind -eq 'UserHive').Count) "$hiveListed"
    $hb = [ordered]@{ Id = 'optimization.t-hive'; Category = 'UserHive'; Kind = 'UserHive'; Title = 'Test hive'; Why = 'A reason that is long enough.'; Source = 'https://learn.microsoft.com/en-us/x'; Origin = 'own'; Risk = 'Low'; Default = $true; Reboot = $false; Irreversible = $false; Path = 'Control Panel\Desktop'; Name = 'MenuShowDelay'; Type = 'String'; Value = '100' }
    $r = Read-Doc @($hb); Test-Check 'types: a correct UserHive entry is accepted' ($r.Valid -and $r.Entries.Count -eq 1) ($r.Errors -join '; ')
    foreach ($bad in @(
            @{ N = 'an HKCU: path'; C = { param($e) $e.Path = 'HKCU:\Control Panel\Desktop' }; P = 'Path must be' }
            @{ N = 'a .. segment'; C = { param($e) $e.Path = 'Software\..\Control Panel\Desktop' }; P = 'Path must be|not valid' }
            @{ N = 'a key outside Software and Control Panel'; C = { param($e) $e.Path = 'Environment' }; P = 'Path must be' }
            @{ N = 'a value not on the allow list'; C = { param($e) $e.Name = 'Wallpaper' }; P = 'allow list' }
            @{ N = 'the type DWord for a REG_SZ value'; C = { param($e) $e.Type = 'DWord'; $e.Value = 100 }; P = 'type of this value must be String' }
            @{ N = 'a String value as a number'; C = { param($e) $e.Value = 100 }; P = 'String Value must be text' }
            @{ N = 'Name PSPath'; C = { param($e) $e.Name = 'PSPath' }; P = 'Name is not a valid' }
            @{ N = 'Category Registry with Kind UserHive'; C = { param($e) $e.Category = 'Registry' }; P = 'does not match Kind' }
        )) {
        $e = [ordered]@{}; foreach ($k in $hb.Keys) { $e[$k] = $hb[$k] }; & $bad.C $e
        $r = Read-Doc @($e)
        Test-Check "types: a UserHive entry with $($bad.N) is refused" ((-not $r.Valid) -and $r.Entries.Count -eq 0 -and (($r.Errors -join ' ') -match $bad.P)) ($r.Errors -join '; ')
    }
    Test-Check 'default profile: the real members refuse keys and values outside the list (also a parent key at the top level)' ((Test-Throws { Assert-OptHiveAccess -Path 'Software\Microsoft\Windows\CurrentVersion\Run' -Name 'x' }) -and (Test-Throws { Assert-OptHiveAccess -Path 'Software\Classes' -Name $null }) -and (Test-Throws { Assert-OptHiveAccess -Path 'Control Panel\Desktop' -Name $null }) -and -not (Test-Throws { Assert-OptHiveAccess -Path $clsid -Name $null })) $null

    # Apply writes into the loaded default profile, never into HKCU or HKLM of the machine; the hive is unloaded afterwards
    $m = New-TestMachine
    Close-AVDTuneWriteGate
    $refused = Test-Throws { Invoke-AVDTuneOptimization -Machine $m -Root $state -Ids @($sbx) }
    Test-Check 'default profile: without the open write gate nothing is written (and the fake member refuses on its own)' ($refused -and $m.Store.Hive.Registry.Count -eq 0 -and (Test-Throws { & $m.HiveSet 'Control Panel\Desktop' 'MenuShowDelay' '100' 'String' })) $null
    $m = New-TestMachine
    $sum = Invoke-Hive $m @($ctx, $sbx, $msd)
    $hv = $m.Store.Hive
    Test-Check 'default profile: Apply writes the three values into the loaded hive (the (Default) of InprocServer32 as an empty REG_SZ, MenuShowDelay as REG_SZ)' (
        $sum.Changed -eq 3 -and $sum.Failed -eq 0 -and $hv.Registry[("$clsid\InprocServer32|").ToLowerInvariant()] -eq '' -and $hv.Kinds[("$clsid\InprocServer32|").ToLowerInvariant()] -eq 'String' -and
        $hv.Registry['software\policies\microsoft\windows\explorer|disablesearchboxsuggestions'] -eq 1 -and $hv.Registry['control panel\desktop|menushowdelay'] -eq '100' -and $hv.Kinds['control panel\desktop|menushowdelay'] -eq 'String') (@($m.Log) -join ' | ')
    Test-Check 'default profile: nothing lands in HKCU or HKLM of the machine, the hive is loaded once and unloaded at the end' ((@($m.Store.Registry.Keys | Where-Object { $_ -like '*menushowdelay*' -or $_ -like '*86ca1aa0*' -or $_ -like '*disablesearchboxsuggestions*' }).Count -eq 0) -and $hv.Loads -eq 1 -and $hv.Unloads -eq 1 -and -not $hv.Loaded -and -not $sum.HiveError) (@($m.Log) -join ' | ')
    $b = Get-AVDTuneOptimizationBackup -Root $state -Id $ctx
    Test-Check 'default profile: the undo record is typed (Kind UserHive, key, name, no earlier value, the CLSID keys AVDTune created)' ($b.Kind -ceq 'UserHive' -and $b.Path -eq "$clsid\InprocServer32" -and $b.Name -eq '' -and $b.Exists -eq $false -and @($b.KeyCreated) -contains $clsid -and @($b.KeyCreated) -contains "$clsid\InprocServer32") ($b | ConvertTo-Json -Compress)
    $st = Get-AVDTuneOptimizationStatus -Machine $m -Root $state
    Test-Check 'default profile: the status reads the values back from the hive (compliant, Undo offered)' (@($st.Rows | Where-Object { $_.Id -in $ctx, $sbx, $msd -and $_.Compliant -and $_.HasBackup }).Count -eq 3) $null
    # a second Apply after a change by hand keeps the first record
    $hv.Registry['control panel\desktop|menushowdelay'] = '50'
    [void](Invoke-Hive $m @($msd))
    Test-Check 'default profile: a second Apply never overwrites the first undo record' ((Get-AVDTuneOptimizationBackup -Root $state -Id $msd).Exists -eq $false) $null
    $u = Invoke-Hive $m @($ctx, $sbx, $msd) -Mode Undo
    Test-Check 'default profile: Undo removes the values and the CLSID key AVDTune created' ($u.Changed -eq 3 -and $hv.Registry.Count -eq 0 -and @($m.Log | Where-Object { $_ -eq "HiveKeyRemoveEmpty $clsid" }).Count -eq 1 -and -not $hv.Loaded) (@($m.Log) -join ' | ')
    # an earlier value is restored with its kind; a CLSID key that was there before stays
    $m = New-TestMachine
    $m.Store.Hive.Registry['control panel\desktop|menushowdelay'] = '400'; $m.Store.Hive.Kinds['control panel\desktop|menushowdelay'] = 'String'
    $m.Store.Hive.Keys[$clsid.ToLowerInvariant()] = $true
    [void](Invoke-Hive $m @($ctx, $msd)); $u = Invoke-Hive $m @($ctx, $msd) -Mode Undo
    Test-Check 'default profile: Undo restores the earlier MenuShowDelay 400 as REG_SZ and keeps a CLSID key that existed before' ($u.Changed -eq 2 -and $m.Store.Hive.Registry['control panel\desktop|menushowdelay'] -eq '400' -and $m.Store.Hive.Kinds['control panel\desktop|menushowdelay'] -eq 'String' -and @($m.Log | Where-Object { $_ -eq "HiveKeyRemoveEmpty $clsid" }).Count -eq 0) (@($m.Log) -join ' | ')
    Clear-Backups
    # crash protection: a hive left loaded is unloaded first; a failing load changes nothing; an unload that needs a second try
    $m = New-TestMachine; $m.Store.Hive.Loaded = $true
    $sum = Invoke-Hive $m @($sbx)
    $regLog = @($m.Store.Hive.Log)
    Test-Check 'default profile: a hive left loaded by a crash is unloaded before it is loaded again' ($sum.Changed -eq 1 -and $regLog.Count -ge 3 -and $regLog[0] -eq 'reg unload HKU\AVDTune_DefaultUser' -and $regLog[1] -like 'reg load HKU\AVDTune_DefaultUser *' -and -not $m.Store.Hive.Loaded) ($regLog -join ' | ')
    Clear-Backups
    $m = New-TestMachine; $m.Store.Hive.FailLoad = $true
    $sum = Invoke-Hive $m @($sbx, $msd)
    Test-Check 'default profile: when the hive cannot be loaded the entries fail and nothing is written or saved' ($sum.Failed -eq 2 -and $sum.Changed -eq 0 -and $m.Store.Hive.Registry.Count -eq 0 -and $null -eq (Get-AVDTuneOptimizationBackup -Root $state -Id $sbx)) (@($sum.Results | ForEach-Object { $_.Message }) -join ' | ')
    $m = New-TestMachine; $m.Store.Hive.PathError = 'C:\Users\Default is a link'
    $sum = Invoke-Hive $m @($sbx)
    Test-Check 'default profile: a refused profile path (link, ACL) loads nothing' ($sum.Failed -eq 1 -and $m.Store.Hive.Loads -eq 0) $null
    $m = New-TestMachine; $m.Store.Hive.StuckUnloads = 2
    $sum = Invoke-Hive $m @($sbx)
    Test-Check 'default profile: the unload is tried again (open handles released) and succeeds' ($sum.Changed -eq 1 -and -not $m.Store.Hive.Loaded -and -not $sum.HiveError) $null
    Clear-Backups
    $m = New-TestMachine; $m.Store.Hive.StuckUnloads = 99
    $sum = Invoke-Hive $m @($sbx)
    Test-Check 'default profile: an unload that keeps failing is reported with the run (HiveError) and LastChange is still set' ($sum.Changed -eq 1 -and $sum.HiveError -like '*could not be unloaded*' -and $m.Store.Hive.Loaded) $sum.HiveError
    Clear-Backups
    Close-AVDTuneWriteGate

    # the profile path: only %SystemDrive%, no links, admin-only folder and file
    $okRep = { param($p) [pscustomobject]@{ Exists = $true; Link = $false; Owner = 'S-1-5-18'; Protected = $false; Rules = @([pscustomobject]@{ Sid = 'S-1-5-32-545'; Write = $false; Inherited = $true; InheritOnly = $false }) } }
    Test-Check 'profile path: %SystemDrive%\Users\Default gives the NTUSER.DAT of that folder' ((Get-AVDTuneDefaultHivePath -Raw '%SystemDrive%\Users\Default' -SystemDrive 'C:' -ReadAcl $okRep) -eq 'C:\Users\Default\NTUSER.DAT') $null
    $linkAt = { param($p) $r = & $okRep $p; if ($p -eq 'C:\Users') { $r.Link = $true }; $r }.GetNewClosure()
    $userWrite = { param($p) $r = & $okRep $p; if ($p -eq 'C:\Users\Default\NTUSER.DAT') { $r.Rules = @([pscustomobject]@{ Sid = 'S-1-5-32-545'; Write = $true; Inherited = $true; InheritOnly = $false }) }; $r }.GetNewClosure()
    $foreignOwner = { param($p) $r = & $okRep $p; if ($p -eq 'C:\Users\Default') { $r.Owner = 'S-1-5-21-1-2-3-1001' }; $r }.GetNewClosure()
    $missing = { param($p) $r = & $okRep $p; if ($p -like '*NTUSER.DAT') { $r.Exists = $false }; $r }.GetNewClosure()
    foreach ($c in @(
            @{ N = 'a link in a parent folder'; Raw = '%SystemDrive%\Users\Default'; A = $linkAt; P = 'is a link' }
            @{ N = 'NTUSER.DAT writable by Users'; Raw = '%SystemDrive%\Users\Default'; A = $userWrite; P = 'not admin-only' }
            @{ N = 'a profile folder owned by a user'; Raw = '%SystemDrive%\Users\Default'; A = $foreignOwner; P = 'not admin-only' }
            @{ N = 'a missing NTUSER.DAT'; Raw = '%SystemDrive%\Users\Default'; A = $missing; P = 'does not exist' }
            @{ N = 'a parent folder (C:\Users) writable by Users'; Raw = '%SystemDrive%\Users\Default'; A = { param($p) $r = & $okRep $p; if ($p -eq 'C:\Users') { $r.Rules = @([pscustomobject]@{ Sid = 'S-1-5-32-545'; Write = $true; Inherited = $false; InheritOnly = $false }) }; $r }.GetNewClosure(); P = 'C:\\Users is not admin-only' }
            @{ N = 'a parent folder (C:\Users) owned by a user'; Raw = '%SystemDrive%\Users\Default'; A = { param($p) $r = & $okRep $p; if ($p -eq 'C:\Users') { $r.Owner = 'S-1-5-21-1-2-3-1001' }; $r }.GetNewClosure(); P = 'C:\\Users is not admin-only' }
            @{ N = 'another environment variable'; Raw = '%USERPROFILE%\..\Default'; A = $okRep; P = 'not a plain local path' }
            @{ N = 'a .. segment'; Raw = 'C:\Users\x\..\Default'; A = $okRep; P = '\.\. segment' }
            @{ N = 'a UNC path'; Raw = '\\server\share\Default'; A = $okRep; P = 'not a plain local path' }
        )) {
        $msg = ''; try { [void](Get-AVDTuneDefaultHivePath -Raw $c.Raw -SystemDrive 'C:' -ReadAcl $c.A); $msg = 'accepted' } catch { $msg = $_.Exception.Message }
        Test-Check "profile path: $($c.N) is refused" ($msg -match $c.P) $msg
    }
    # the real machine members: the right set is added, reg.exe by full path through the adapter (Run), loading only through the module functions
    $optSrc = Get-Content -Raw (Join-Path $repo 'Modules\AVDTune.Optimization.psm1')
    Test-Check 'default profile: reg.exe is started by its full path from the system folder through the adapter, the hive name is fixed' ($optSrc -match "Join-Path \(Get-AVDTuneSystemFolder System\) 'reg\.exe'" -and $optSrc -match '& \$Machine\.Run \$regExe' -and $optSrc -match "HiveName = 'AVDTune_DefaultUser'") $null
    Test-Check 'default profile: a real machine gets all Hive members' (@('HiveInfo', 'HiveKeyExists', 'HiveSet', 'HiveRemove', 'HiveKeyRemoveEmpty', 'HiveUnmount' | Where-Object { $optSrc -notmatch "'$_'" }).Count -eq 0) $null
    # reading needs the open write gate too: loading the hive writes log files into the profile (security review of #40)
    Close-AVDTuneWriteGate
    $m = New-TestMachine
    $st = Get-AVDTuneOptimizationStatus -Machine $m -Root $state
    $hr = @($st.Rows | Where-Object Kind -eq 'UserHive')
    Test-Check 'default profile: with the write gate closed the status does not load the hive, the rows say "not checkable" with the reason' ($hr.Count -eq 4 -and @($hr | Where-Object { -not $_.Failed -or $_.Message -notlike '*write gate is closed*' }).Count -eq 0 -and $m.Store.Hive.Loads -eq 0 -and @($m.Store.Hive.Log).Count -eq 0 -and @($st.Rows | Where-Object { $_.Kind -ne 'UserHive' -and $_.Failed }).Count -eq 0) (@($hr | ForEach-Object Message) -join ' | ')
    $wi = Invoke-AVDTuneOptimization -Machine $m -Root $state -Ids @($sbx) -WhatIf
    Test-Check 'default profile: a dry run with the gate closed does not load the hive either (skipped, cannot be read)' ((Get-R $wi $sbx).Status -eq 'Skipped' -and $m.Store.Hive.Loads -eq 0) (Get-R $wi $sbx | ConvertTo-Json -Compress)
    # the unload helper of the start and of the readiness fix (AVDTune.psm1): bounded tries, no wait in the checks
    $um = New-AVDTuneFakeMachine -Seed @{ HiveLoaded = $true }; $um.Store.Hive.StuckUnloads = 1
    $ur = Invoke-AVDTuneDefaultHiveUnload -Machine $um -DelayMs 0
    $um2 = New-AVDTuneFakeMachine -Seed @{ HiveLoaded = $true }; $um2.Store.Hive.StuckUnloads = 99
    $sw = [Diagnostics.Stopwatch]::StartNew(); $ur2 = Invoke-AVDTuneDefaultHiveUnload -Machine $um2 -DelayMs 0; $sw.Stop()
    Test-Check 'unload helper: a left hive is unloaded (second try), one that stays loaded gives up after 5 tries without hanging, an unloaded one is left alone' ($ur.WasLoaded -and $ur.Unloaded -and $ur2.WasLoaded -and -not $ur2.Unloaded -and @($um2.Store.Hive.Log).Count -eq 5 -and $sw.ElapsedMilliseconds -lt 10000 -and -not (Invoke-AVDTuneDefaultHiveUnload -Machine (New-AVDTuneFakeMachine)).WasLoaded) "$($sw.ElapsedMilliseconds) ms"

    # ---------------------------------------------------------------- the runspaces of the page (#66, like #67): exactly the imports of the page, the REAL machine, read only
    $pageSrc = Get-Content -Raw (Join-Path $repo 'AVDTune-Optimization.ps1')
    $pageImports = @([regex]::Matches($pageSrc, "Import-Module \(Join-Path \`$AppRoot '([^']+)'\)") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $oneReg = Join-Path $tmp 'one-reg.json'
    $oneEntry = [ordered]@{}; foreach ($pr in @($real.Entries | Where-Object { $_.Kind -eq 'Registry' } | Select-Object -First 1)[0].PSObject.Properties) { if ($null -ne $pr.Value) { $oneEntry[$pr.Name] = $pr.Value } }   # the first shipped registry entry
    [IO.File]::WriteAllText($oneReg, ([ordered]@{ SchemaVersion = 1; Sources = @($real.Sources); Entries = @($oneEntry) } | ConvertTo-Json -Depth 6))
    $rs = [powershell]::Create()
    try {
        [void]$rs.AddScript({
                param($Repo, $Imports, $State, $Data)
                $ErrorActionPreference = 'Stop'
                foreach ($i in $Imports) { Import-Module (Join-Path $Repo $i) -Force }
                $st = Get-AVDTuneOptimizationStatus -Machine (New-AVDTuneMachine) -Root $State -DataPath $Data   # the read of Start-OptRead, one registry entry, nothing written
                $cmds = @('Invoke-AVDTuneOptimization', 'Open-AVDTuneWriteGate', 'New-AVDTuneMachine', 'Get-AVDTuneOptimizationStatus' | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })   # what the run of Start-OptRun calls
                Open-AVDTuneWriteGate -SnapshotId 'check' -ConfirmedBy 'check'   # as the run does; the engine of the Optimization module must see the gate the page opened (one instance of the AVDTune module)
                $gateSeen = & (Get-Module AVDTune.Optimization) { Test-AVDTuneWriteAllowed }
                [pscustomobject]@{ Status = $st; Missing = @($cmds); GateSeen = $gateSeen }
            }).AddArgument($repo).AddArgument($pageImports).AddArgument($state).AddArgument($oneReg)
        $res = $rs.Invoke() | Select-Object -Last 1
        $rsErr = @($rs.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
    }
    catch { $res = $null; $rsErr = $_.Exception.Message }
    finally { $rs.Dispose() }
    Test-Check 'page runspaces (#66): with exactly the imports of the page the real machine reads a registry entry and the commands of the run are known (no unknown command, no error)' ($res -and $pageImports.Count -ge 2 -and $res.Status.DataValid -and @($res.Status.Rows).Count -eq 1 -and -not $res.Status.Rows[0].Failed -and @($res.Missing).Count -eq 0 -and $res.GateSeen -eq $true -and $rsErr -notmatch 'is not recognized|nicht erkannt' -and -not $rsErr) "imports=$($pageImports -join ","); missing=$(@($res.Missing) -join ","); err=$rsErr; valid=$($res.Status.DataValid) rows=$(@($res.Status.Rows).Count) failed=$(@($res.Status.Rows)[0].Failed) msg=$(@($res.Status.Rows)[0].Message) errs=$($res.Status.DataErrors -join ";")"

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
    function Show-Error([string]$Text) { [void]$script:Errors.Add($Text) }
    $script:ShutBlocks = New-Object System.Collections.ArrayList; function Set-ShutdownBlock([bool]$On) { [void]$script:ShutBlocks.Add($On) }
    $tasksText = Get-Content -Raw (Join-Path $repo 'AVDTune-Tasks.ps1'); Invoke-Expression $tasksText.Substring($tasksText.IndexOf('$script:WriterJobVariables'))   # Assert-NoOtherWriter, the one function every writer calls (#66)
    $script:Errors = New-Object System.Collections.ArrayList; $script:Tasks = New-Object System.Collections.ArrayList
    function Start-AVDTuneUiTask { param($Kind, $Title, $Step, $Percent, $Retry) $t = @{ Kind = $Kind; Title = $Title; Status = 'running'; Retry = $Retry }; [void]$script:Tasks.Add($t); $t }
    function Complete-AVDTuneUiTask { param($Task, [switch]$Failed, $Summary) $Task.Status = $(if ($Failed) { 'failed' } else { 'succeeded' }); $Task.Summary = $Summary }
    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer; $script:CurrentPage = 'Optimization'; $script:OverviewJob = $null
    function Invoke-UiTaskInline { param($Kind, $Title, [scriptblock]$Block, $Step, $Done, $Retry) & $Block }
    . (Join-Path $repo 'AVDTune-Optimization.ps1'); $script:TestMode = $true   # after loading: the page script would load the fakes of the window test mode
    Test-Check 'page: it is added next to the other pages and starts hidden' ($ui.PageOptimization -and $root.Children.Contains($ui.PageOptimization) -and $ui.PageOptimization.Visibility -eq 'Collapsed') $null
    $script:Machine = New-AVDTuneFakeMachine -Seed @{ Now = [datetime]'2026-11-15T12:00:00'; Services = @(@{ Name = 'MapsBroker'; Status = 'Running'; StartType = 'Automatic' }) }
    [void](Add-AVDTuneOptimizationFakeMembers $script:Machine -Appx @('Microsoft.BingNews') -Defender @{ PUAProtection = [byte]0 })
    Update-OptView
    # the page does not read the master on the window thread (#66): it is there at once, the read runs as a task and the rows follow
    Test-Check 'page load: Update-OptView returns at once with a running read, a task with Retry, no rows yet and the text "Reading the state of the master"' ($script:OptJob -and $script:Tasks.Count -eq 1 -and $script:Tasks[0].Status -eq 'running' -and $script:Tasks[0].Retry.Command -eq 'Start-OptRead' -and $null -eq $script:OptStatus -and $ui.PanelOptList.Children.Count -eq 0 -and $ui.TxtOptSummary.Text -like 'Reading the state of the master*') "tasks=$($script:Tasks.Count)"
    Test-Check 'page load: Apply, Undo and Refresh are locked while the read runs' (-not $ui.BtnOptApply.IsEnabled -and -not $ui.BtnOptUndo.IsEnabled -and -not $ui.BtnOptRefresh.IsEnabled) $null
    Update-OptView; Start-OptRead
    Test-Check 'page load: opening the page again or pressing read again starts no second read' ($script:Tasks.Count -eq 1) "tasks=$($script:Tasks.Count)"
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'
    Test-Check 'page load: Apply and Undo refuse while the read runs, even with the write gate open, and ask nothing' ((Test-Throws { Start-OptChange 'Apply' }) -and (Test-Throws { Start-OptChange 'Undo' }) -and $script:Asked.Count -eq 0 -and @($script:Machine.Log).Count -eq 0) $null
    Close-AVDTuneWriteGate
    Complete-OptRead
    Test-Check 'page load: after the read the task is succeeded, the status is there and Apply, Undo and Refresh are open' (-not $script:OptJob -and $script:Tasks[0].Status -eq 'succeeded' -and $script:OptStatus.DataValid -and $ui.BtnOptApply.IsEnabled -and $ui.BtnOptUndo.IsEnabled -and $ui.BtnOptRefresh.IsEnabled) $null
    # the presets say whether their set is in place (#66)
    $keepSt = $script:OptStatus
    $presetIds = @{}; foreach ($pn in 'recommended', 'conservative', 'all') { $presetIds[$pn] = @(Get-AVDTuneOptimizationPresetIds -Entries $keepSt.Rows -Preset $pn) }
    $mk = { param([scriptblock]$Mod) $rs = @($keepSt.Rows | ForEach-Object { $c = $_.PSObject.Copy(); $c.Present = $true; $c.Compliant = $true; $c.Failed = $false; $c }); & $Mod $rs; [pscustomobject]@{ DataValid = $true; DataErrors = @(); Sources = $keepSt.Sources; Rows = $rs; BackupError = $null } }
    $script:OptStatus = & $mk { param($rs) }
    Show-OptList
    Test-Check 'presets: every entry in place gives each of the three sets a check and "in place", Nothing has no status' ((@('recommended', 'conservative', 'all' | Where-Object { $ui.OptPresets[$_].Content -like "*$([char]0x2713) in place" }).Count -eq 3) -and $ui.OptPresets['none'].Content -eq 'Nothing') (($ui.OptPresets.Values | ForEach-Object { $_.Content }) -join ' | ')
    $victim = $presetIds['conservative'][0]
    $script:OptStatus = & $mk { param($rs) $v = @($rs | Where-Object Id -eq $victim)[0]; $v.Compliant = $false }
    Show-OptList
    $nRec = $presetIds['recommended'].Count
    Test-Check 'presets: one entry not in place gives "x of y in place" (neutral, no check) for the sets that contain it and the tooltip says the same' ($ui.OptPresets['conservative'].Content -like "*($($presetIds['conservative'].Count - 1) of $($presetIds['conservative'].Count) in place)" -and $ui.OptPresets['conservative'].Content -notlike "*$([char]0x2713)*" -and $ui.OptPresets['recommended'].Content -like "*($($nRec - 1) of $nRec in place)" -and $ui.OptPresets['conservative'].ToolTip -like "*of*in place*") $ui.OptPresets['conservative'].Content
    $naId = $presetIds['all'][0]
    $script:OptStatus = & $mk { param($rs) $v = @($rs | Where-Object Id -eq $naId)[0]; $v.Present = $false; $v.Compliant = $false }
    Show-OptList
    Test-Check 'presets: an entry that is not on this host counts as in place' ($ui.OptPresets['all'].Content -like "*$([char]0x2713) in place") $ui.OptPresets['all'].Content
    $script:OptStatus = & $mk { param($rs) $v = @($rs | Where-Object Id -eq $victim)[0]; $v.Failed = $true; $v.Compliant = $false }
    Show-OptList
    Test-Check 'presets: an entry that cannot be read does not count as in place' ($ui.OptPresets['all'].Content -like '*(*of*in place)') $ui.OptPresets['all'].Content
    $script:OptStatus = & $mk { param($rs) }
    Start-OptRead
    Test-Check 'presets: while the state is read there is no status' (@('recommended', 'conservative', 'all' | Where-Object { $ui.OptPresets[$_].Content -match 'in place' }).Count -eq 0) $ui.OptPresets['recommended'].Content
    Complete-OptRead
    Test-Check 'presets: after the read the status is back' ($ui.OptPresets['recommended'].Content -match 'in place') $null
    # ---- review M2: a Defender read error that is not "no Defender here" is a problem row, never "not on this host" or "in place"
    $script:Machine.Store.MpError = 'policy blocks Get-MpPreference'
    Start-OptRead; Complete-OptRead
    $defRows = @($script:OptStatus.Rows | Where-Object { $_.Kind -eq 'DefenderPref' })
    Test-Check 'defender (#66): another read error than "no Defender" gives a failed row (Present, not in place, with the message), not "not on this host"' ($defRows.Count -gt 0 -and @($defRows | Where-Object { -not $_.Present -or -not $_.Failed -or $_.Compliant -or $_.Message -notlike '*policy blocks*' }).Count -eq 0) "rows=$($defRows.Count)"
    Test-Check 'defender (#66): with such failed rows the set "everything" is not green' ($ui.OptPresets['all'].Content -notlike "*$([char]0x2713)*") $ui.OptPresets['all'].Content
    $script:Machine.Store.MpError = $null; $script:Machine.Store.MpAbsent = $true
    Start-OptRead; Complete-OptRead
    $defRows = @($script:OptStatus.Rows | Where-Object { $_.Kind -eq 'DefenderPref' })
    Test-Check 'defender (#66): "no Defender on this host" (command or WMI namespace missing) is not present and not a failure' ($defRows.Count -gt 0 -and @($defRows | Where-Object { $_.Present -or $_.Failed }).Count -eq 0) "rows=$($defRows.Count)"
    $script:Machine.Store.MpAbsent = $false
    Test-Check 'defender (#66): the check for "no Defender" accepts the missing cmdlet and nothing else' ((Test-OptDefenderAbsent (& { try { & 'Get-MpPreference-does-not-exist' } catch { $_ } })) -and -not (Test-OptDefenderAbsent (& { try { throw 'access denied' } catch { $_ } }))) $null
    $script:OptStatus = & $mk { param($rs) foreach ($r in $rs) { $r.Present = $false; $r.Compliant = $false } }
    Show-OptList
    Test-Check 'presets (#66): a set whose entries are all not on this host is not green, the tooltip says so' (@('recommended', 'conservative', 'all' | Where-Object { $ui.OptPresets[$_].Content -like "*$([char]0x2713)*" }).Count -eq 0 -and $ui.OptPresets['all'].ToolTip -like '*not on this host*') $ui.OptPresets['all'].Content
    $script:OptStatus = & $mk { param($rs) $v = @($rs | Where-Object Id -eq $naId)[0]; $v.Present = $false; $v.Compliant = $false }
    Show-OptList
    Test-Check 'presets (#66): the tooltip counts the entries that are not on this host' ($ui.OptPresets['all'].ToolTip -like '*1 of them is not on this host*') $ui.OptPresets['all'].ToolTip
    # ---- review N1: after a failed read the list is marked old; nothing can be applied from it until a read succeeds
    $script:OptStatus = & $mk { param($rs) }
    $script:OptStale = $false; Show-OptList
    $keepM = $script:Machine; $script:Machine = $null
    Start-OptRead; Complete-OptRead
    Test-Check 'stale (#66): after a failed read the old list stays but Apply, Undo and the preset status are locked, Apply throws and the page says so' ($script:OptStale -and $script:OptStatus -and -not $ui.BtnOptApply.IsEnabled -and -not $ui.BtnOptUndo.IsEnabled -and $ui.BtnOptRefresh.IsEnabled -and @('recommended', 'conservative', 'all' | Where-Object { $ui.OptPresets[$_].Content -match 'in place' }).Count -eq 0 -and (Test-Throws { Start-OptChange 'Apply' }) -and $ui.TxtOptSummary.Text -like '*earlier state*') $ui.TxtOptSummary.Text
    $script:Machine = $keepM
    Start-OptRead; Complete-OptRead
    Test-Check 'stale (#66): the next successful read opens everything again' (-not $script:OptStale -and $ui.BtnOptApply.IsEnabled -and $ui.OptPresets['recommended'].Content -match 'in place') $null
    # ---- re-review N-C: the code of "Defender service not running" is 0x800106BA = -2147416390 (as int or uint), found in HResult of a CimException; another code is not "absent"
    Import-Module CimCmdlets
    $mkCim = { param([int]$H) $ex = [Microsoft.Management.Infrastructure.CimException]::new('Operation failed'); [Exception].GetField('_HResult', 'NonPublic,Instance').SetValue($ex, $H); [Management.Automation.ErrorRecord]::new($ex, 'x', [Management.Automation.ErrorCategory]::NotSpecified, $null) }
    Test-Check 'defender (#66): a CimException with HResult 0x800106BA (service not running) means absent, another code (0x803380BA) does not' ((Test-OptDefenderAbsent (& $mkCim -2147416390)) -and -not (Test-OptDefenderAbsent (& $mkCim -2144108358))) $null
    Test-Check 'defender (#66): an error code as uint is read as the signed number' ((ConvertTo-OptInt32 2147550906) -eq -2147416390 -and (ConvertTo-OptInt32 5) -eq 5 -and (ConvertTo-OptInt32 'x') -eq 0) $null
    # ---- review M1: one writer at a time
    $script:OptRun = @{ Mode = 'Apply' }
    $seen = ((Get-AVDTuneRunningWriter) -eq 'OptRun') -and (Test-Throws { Assert-NoOtherWriter }) -and (Test-Throws { Start-OptChange 'Apply' })
    $script:OptRun = $null
    Test-Check 'writers (#66): a running optimization run is seen by the central check and Start-OptChange refuses' $seen $null
    foreach ($w in 'UpdJob', 'BenchJob', 'SealJob', 'SwJob', 'FslJob', 'OffJob') {
        Set-Variable -Scope Script -Name $w -Value @{ Kind = 'Run' }
        $blocked = (Test-Throws { Assert-NoOtherWriter }) -and (Test-Throws { Start-OptChange 'Apply' })
        Remove-Variable -Scope Script -Name $w
        Test-Check "writers (#66): a running $w stops Apply and Undo of the optimization" $blocked $null
    }
    $script:ReadyJob = @{ Kind = 'Fix' }; $fixBlocks = Test-Throws { Assert-NoOtherWriter }; $script:ReadyJob = @{ Kind = 'Manual' }; $anaFree = -not (Test-Throws { Assert-NoOtherWriter }); $script:ReadyJob = $null
    $script:UpdJob = @{ Kind = 'Scan' }; $scanFree = -not (Test-Throws { Assert-NoOtherWriter }); $script:UpdJob = $null
    Test-Check 'writers (#66): a readiness fix counts as a writer, the readiness analysis and an update search do not' ($fixBlocks -and $anaFree -and $scanFree) $null
    # ---- review N2/N3: shutdown block while the run goes; a result that is there is evaluated even when the stream also has an error
    $script:ShutBlocks.Clear()
    $keepM2 = $script:Machine; $keepChecked = $script:OptChecked.Clone()   # the run below changes a machine of its own, not the one of the page tests that follow
    $script:Machine = New-AVDTuneFakeMachine -Seed @{ Now = [datetime]'2026-11-15T12:00:00' }; [void](Add-AVDTuneOptimizationFakeMembers $script:Machine -Appx @() -Defender @{})
    $script:Asked.Clear(); $script:Answers.Enqueue($true); $script:Answers.Enqueue($true)
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'
    Set-OptPreset 'conservative'
    Start-OptChange 'Apply'
    $blockOn = ($script:ShutBlocks.Count -eq 1 -and $script:ShutBlocks[0] -eq $true)
    Complete-OptRun
    Test-Check 'run (#66): log off and shut down are held back while the run goes and released at its end' ($blockOn -and $script:ShutBlocks.Count -eq 2 -and $script:ShutBlocks[1] -eq $false) ($script:ShutBlocks -join ',')
    Complete-OptRead
    Close-AVDTuneWriteGate
    $script:Machine = $keepM2; $script:OptChecked = $keepChecked; $script:Asked.Clear(); $script:Answers.Clear()
    $rsN = [powershell]::Create(); [void]$rsN.AddScript({ $ErrorActionPreference = 'Continue'; Write-Error 'late problem'; [pscustomobject]@{ Results = @(); Changed = 2; Failed = 0; Skipped = 0; Reboot = $false } })
    $tN = Start-AVDTuneUiTask -Kind 'optimization' -Title 'x' -Step 'y'
    $script:Errors.Clear(); $hN = $rsN.BeginInvoke(); while (-not $hN.IsCompleted) { Start-Sleep -Milliseconds 20 }
    $script:OptRun = @{ PS = $rsN; Handle = $hN; Task = $tN; Mode = 'Apply' }
    Complete-OptRun; Complete-OptRead
    Test-Check 'run (#66): a result that is there is evaluated (task succeeded, 2 changes) and the error of the stream is reported in addition' ($tN.Status -eq 'succeeded' -and $tN.Summary -like '*2 change*' -and @($script:Errors | Where-Object { $_ -like '*also reported*late problem*' }).Count -eq 1) "$($tN.Status) $($tN.Summary) errors=$($script:Errors -join '|')"
    $script:OptStatus = $keepSt; $script:OptStale = $false; Show-OptList
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
    Test-Check 'run: the click returns at once with a running task and without a change; Apply, Undo and a second run are locked' ($script:OptRun -and $script:Tasks[-1].Kind -eq 'optimization' -and $script:Tasks[-1].Status -eq 'running' -and -not $script:Tasks[-1].Retry -and $script:Machine.Store.Appx.ContainsKey('microsoft.bingnews') -and -not $ui.BtnOptApply.IsEnabled -and -not $ui.BtnOptUndo.IsEnabled -and (Test-Throws { Start-OptChange 'Apply' }) -and (Test-Throws { Start-OptRead }) -eq $false -and $script:OptJob -eq $null) $null
    $script:CloseWhenDone = $false
    Complete-OptRun
    Test-Check 'run: the task ends as succeeded with the summary' (@($script:Tasks | Where-Object { $_.Kind -eq 'optimization' })[-1].Status -eq 'succeeded' -and @($script:Tasks | Where-Object { $_.Kind -eq 'optimization' })[-1].Summary -like 'Optimization apply*') $null
    Test-Check 'page: after both confirmations the entries are applied, the AppX is gone and the toast reports it' (-not $script:Machine.Store.Appx.ContainsKey('microsoft.bingnews') -and (& $script:Machine.ServiceGet 'MapsBroker').StartType -eq 'Disabled' -and $script:Toasts[-1] -like 'Optimization apply: *change(s)*') $script:Toasts[-1]
    Test-Check 'page load: after Apply the state is read again in the background and Apply stays locked until it is done' ($script:OptJob -and -not $ui.BtnOptApply.IsEnabled) $null
    Complete-OptRead
    $script:Asked.Clear(); $script:Answers.Enqueue($true)
    Start-OptChange 'Undo'
    Complete-OptRun
    Test-Check 'page: Undo asks once (the AppX is left out and named as such), restores the service and does not bring the AppX back' ($script:Asked.Count -eq 1 -and $script:Asked[0] -like '*cannot be undone and are left out*' -and (& $script:Machine.ServiceGet 'MapsBroker').StartType -eq 'Automatic' -and -not $script:Machine.Store.Appx.ContainsKey('microsoft.bingnews')) ($script:Asked -join ' | ')
    Complete-OptRead
    # a failing read: the task fails with the cause and Retry, the page says so, nothing can be applied, and the next read can start
    $keepMachine = $script:Machine; $keepStatus = $script:OptStatus; $script:OptStatus = $null; $script:Machine = $null; $script:Errors.Clear(); $nTasks = $script:Tasks.Count
    Start-OptRead; Complete-OptRead
    Test-Check 'page load: a failing read ends the task as failed with the cause and Retry, shows the problem and keeps Apply and Undo locked' (-not $script:OptJob -and $script:Tasks.Count -eq $nTasks + 1 -and $script:Tasks[-1].Status -eq 'failed' -and $script:Tasks[-1].Summary -like 'The state could not be read*' -and $script:Tasks[-1].Retry -and $ui.TxtOptSummary.Text -like 'The state could not be read*' -and $script:Errors.Count -eq 1 -and -not $ui.BtnOptApply.IsEnabled -and -not $ui.BtnOptUndo.IsEnabled -and $ui.BtnOptRefresh.IsEnabled) $script:Tasks[-1].Summary
    $script:Machine = $keepMachine; $script:OptStatus = $keepStatus
    $script:OptStatus = [pscustomobject]@{ DataValid = $false; DataErrors = @('broken'); Sources = @(); Rows = @(); BackupError = $null }
    Show-OptList
    Test-Check 'page: invalid data shows the error and disables Apply and Undo' ($ui.BoxOptErrors.Visibility -eq 'Visible' -and -not $ui.BtnOptApply.IsEnabled -and -not $ui.BtnOptUndo.IsEnabled) $null
    Test-Check 'page: Apply with invalid data throws' (Test-Throws { Start-OptChange 'Apply' }) $null
    Close-AVDTuneWriteGate

    # the members of a real machine (only names are checked here, no cmdlet is called)
    $real = New-AVDTuneMachine; [void](Add-AVDTuneOptimizationMachineMembers -Machine $real)
    Test-Check 'real machine: gets the four members, refuses a Defender setting that is not on the list and an AppX name with a wildcard before any cmdlet runs' ((@('AppxState', 'AppxRemove', 'MpGet', 'MpSet') | Where-Object { $null -eq $real.PSObject.Properties[$_] }).Count -eq 0 -and (Test-Throws { & $real.MpGet 'DisableRealtimeMonitoring' }) -and (Test-Throws { & $real.MpSet 'DisableRealtimeMonitoring' $true }) -and (Test-Throws { & $real.AppxState '*' }) -and (Test-Throws { & $real.AppxRemove 'Microsoft.*' })) $null

    # ---------------------------------------------------------------- #41: Defender SharedSignaturesPath with an input and the readability check
    $ssId = 'optimization.defender-shared-signatures'
    $ssE = @((Read-AVDTuneOptimizationData).Entries | Where-Object Id -eq $ssId)[0]
    Test-Check '#41 data: the entry is shipped off by default, with the path as input (never a stored value) and the Learn source' ($ssE -and -not $ssE.Default -and $ssE.Input -eq 'UncPath' -and $ssE.Value -eq '' -and $ssE.Source -like '*deployment-vdi-microsoft-defender-antivirus' -and $ssE.Why -like '*no longer uses its other update sources*' -and $ssE.Why -like '*management machine*') $null
    $goodUnc = @('\\fileserver\mdatp$\wdav-update', '\\fs01.corp.example\share', '\\10.0.0.5\share\a b\{00000000-0000-0000-0000-000000000000}')
    $badUnc = @('', 'C:\updates', '\\?\UNC\fs\share', '\\.\pipe\x', '\\fs\share\..\x', '\\user:pw@fs\share', '\\fs@SSL\share', '\\fs\sh*re', "\\fs\share`n", '\\fs', '\\fs\', 'https://fs/share', '\\fs\share\.', ('\\fs\' + ('a' * 300)), '\\-fs\share', 7)
    Test-Check '#41 UNC: valid paths pass, credentials, device paths, wildcards, dot segments, newlines and non-strings are refused (counter-test)' ((@($goodUnc | Where-Object { -not (Test-AVDTuneUncPath $_) }).Count -eq 0) -and (@($badUnc | Where-Object { Test-AVDTuneUncPath $_ }).Count -eq 0)) (@($badUnc | Where-Object { Test-AVDTuneUncPath $_ }) -join ' | ')
    $ms = New-AVDTuneFakeMachine; [void](Add-AVDTuneOptimizationFakeMembers $ms)
    $share = '\\fileserver\mdatp$\wdav-update'
    Open-AVDTuneWriteGate -SnapshotId 'snap-41' -ConfirmedBy 'admin1'
    $st41 = Get-AVDTuneOptimizationStatus -Machine $ms -Root $state
    $row41 = @($st41.Rows | Where-Object Id -eq $ssId)[0]
    Test-Check '#41 status: without a path set the row is present, not in place, says so and carries the input kind' ($row41.Present -and -not $row41.Compliant -and $row41.State -eq 'no path set' -and $row41.Input -eq 'UncPath') $row41.State
    Test-Check '#41 apply without the path: refused before anything changes' ((Test-Throws { Invoke-AVDTuneOptimization -Machine $ms -Root $state -Ids @($ssId) -User 'admin1' -SnapshotId 's' }) -and $ms.Store.Mp['SharedSignaturesPath'] -eq '') $null
    Test-Check '#41 apply with a path that is not a UNC path or for an entry without input: refused, nothing set (counter-test)' ((Test-Throws { Invoke-AVDTuneOptimization -Machine $ms -Root $state -Ids @($ssId) -Inputs @{ $ssId = '\\user:pw@fs\share' } -User 'admin1' -SnapshotId 's' }) -and (Test-Throws { Invoke-AVDTuneOptimization -Machine $ms -Root $state -Ids @($ssId) -Inputs @{ 'optimization.defender-pua-block' = $share } -User 'admin1' -SnapshotId 's' }) -and $ms.Store.Mp['SharedSignaturesPath'] -eq '') $null
    $r41 = Invoke-AVDTuneOptimization -Machine $ms -Root $state -Ids @($ssId) -Inputs @{ $ssId = $share } -User 'admin1' -SnapshotId 's'
    Test-Check '#41 the share cannot be read: Failed with the reason, the path is not set (counter-test)' ((Get-R $r41 $ssId).Status -eq 'Failed' -and (Get-R $r41 $ssId).Message -like '*cannot be read*' -and $ms.Store.Mp['SharedSignaturesPath'] -eq '' -and @($ms.Store.Log | Where-Object { $_ -like 'UncReadable*' }).Count -ge 1) (Get-R $r41 $ssId).Message
    $ms.Store.Unc[$share.ToLowerInvariant()] = @{ Ok = $true; GuidFolders = 0; Error = '' }
    $r41b = Invoke-AVDTuneOptimization -Machine $ms -Root $state -Ids @($ssId) -Inputs @{ $ssId = $share } -User 'admin1' -SnapshotId 's'
    Test-Check '#41 a readable share without an unpacked {GUID} update folder: Failed, the path is not set (Defender would get no updates)' ((Get-R $r41b $ssId).Status -eq 'Failed' -and (Get-R $r41b $ssId).Message -like '*GUID*' -and $ms.Store.Mp['SharedSignaturesPath'] -eq '') (Get-R $r41b $ssId).Message
    $ms.Store.Unc[$share.ToLowerInvariant()] = @{ Ok = $true; GuidFolders = 2; Error = '' }
    $r41c = Invoke-AVDTuneOptimization -Machine $ms -Root $state -Ids @($ssId) -Inputs @{ $ssId = $share } -User 'admin1' -SnapshotId 's'
    $log41 = @(Get-AVDTuneChangeLog -Root $state | Where-Object Component -eq $ssId)
    Test-Check '#41 a readable share with an update folder: the path is set, the earlier value (none) is saved, the change log names the path' ((Get-R $r41c $ssId).Status -eq 'Changed' -and $ms.Store.Mp['SharedSignaturesPath'] -eq $share -and (Get-AVDTuneOptimizationBackup -Root $state -Id $ssId).Value -eq '' -and $log41.Count -ge 1 -and $log41[-1].Text -like "*$share") (Get-R $r41c $ssId).Message
    $st41b = Get-AVDTuneOptimizationStatus -Machine $ms -Root $state
    Test-Check '#41 status after Apply: in place, the state shows the path, Undo is possible' ((@($st41b.Rows | Where-Object Id -eq $ssId)[0]).Compliant -and (@($st41b.Rows | Where-Object Id -eq $ssId)[0]).State -eq $share -and (@($st41b.Rows | Where-Object Id -eq $ssId)[0]).HasBackup) $null
    $u41 = Invoke-AVDTuneOptimization -Machine $ms -Root $state -Ids @($ssId) -Mode Undo -User 'admin1' -SnapshotId 's'
    Test-Check '#41 Undo gives back "no path" through the restore path (Remove-MpPreference in the real member) and releases the backup' ((Get-R $u41 $ssId).Status -eq 'Reverted' -and $ms.Store.Mp['SharedSignaturesPath'] -eq '' -and @($ms.Store.Log | Where-Object { $_ -eq 'MpSet SharedSignaturesPath= restore=True' }).Count -eq 1 -and $null -eq (Get-AVDTuneOptimizationBackup -Root $state -Id $ssId)) (@($ms.Store.Log) -join ' | ')
    Test-Check '#41 Defender check: a path is refused on set unless it is a UNC path, "" only as a restore' ((Get-OptDefenderProblem -Parameter 'SharedSignaturesPath' -Value '') -and $null -eq (Get-OptDefenderProblem -Parameter 'SharedSignaturesPath' -Value '' -Restore) -and (Get-OptDefenderProblem -Parameter 'SharedSignaturesPath' -Value 5 -Restore) -and $null -eq (Get-OptDefenderProblem -Parameter 'SharedSignaturesPath' -Value $share)) $null
    $realU = New-AVDTuneMachine; [void](Add-AVDTuneOptimizationMachineMembers -Machine $realU)
    Test-Check '#41 the real members refuse a path that is not a UNC path before any cmdlet or network access' ((Test-Throws { & $realU.UncReadable 'C:\Windows' }) -and (Test-Throws { & $realU.UncReadable '\\user:pw@fs\share' }) -and (Test-Throws { & $realU.MpSet 'SharedSignaturesPath' 'C:\x' })) $null
    $modOpt = Get-Content (Join-Path $repo 'Modules\AVDTune.Optimization.psm1') -Raw
    Test-Check '#41 the real readability check uses the current logon only (no credentials, no net use, no New-PSDrive)' ($modOpt -notmatch 'net\.exe|net use|New-PSDrive|New-SmbMapping|-Credential|PSCredential|NetworkCredential') $null

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
