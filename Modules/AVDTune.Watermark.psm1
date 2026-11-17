<#
    AVDTune watermark (docs\plans\avdtune.md, section 5): a label such as "PILOTUMGEBUNG" on every monitor of the session, shown only when the
    computer name matches a pattern (the trigger stays the machine name).

    Settings: C:\ProgramData\AVDTune\config\watermark.json (state root, administrators only), checked by ConvertTo-AVDTuneWatermarkSettings
    (Watermark\AVDTune-WatermarkCore.ps1, the same code the overlay uses). Saving settings changes only AVDTune's own state, not the master.

    On the master (steps of the section UserExperience, Test/Apply/Undo, behind the write gate):
      userexperience.watermark-program   Show-AVDTuneWatermark.ps1 + core in C:\Program Files\AVDTune\Watermark (admin-only folder)
      userexperience.watermark-settings  read-only copy for users: C:\ProgramData\AVDTune-Public\watermark.json (ACL: Users read, Administrators/SYSTEM write)
      userexperience.watermark-task      scheduled task "AVDTune Watermark": at logon, group BUILTIN\Users (S-1-5-32-545), powershell.exe -WindowStyle Hidden
      userexperience.watermark-microsoft optional: the Microsoft QR code watermark policy (fEnableWatermarking and its values)
      userexperience.watermark-legacy    the old overlay: task "PilotOverlay" and C:\ProgramData\PilotOverlayLauncher.vbs, removed on request (backup, undo)
    All access goes through the machine adapter, so the checks run against Tests\Fakes\FakeMachine.ps1.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
$script:CorePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Watermark\AVDTune-WatermarkCore.ps1'
. $script:CorePath

$script:TaskName = 'AVDTune Watermark'
$script:LegacyTask = 'PilotOverlay'
$script:LegacyVbs = 'PilotOverlayLauncher.vbs'
$script:MsKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$script:MsLearn = 'https://learn.microsoft.com/en-us/azure/virtual-desktop/watermarking'
$script:UsersSid = 'S-1-5-32-545'

#region paths, settings

function Get-AVDTuneWatermarkPaths {
    param([Parameter(Mandatory)]$Machine)
    $pf = & $Machine.KnownFolder 'ProgramFiles'
    $pd = & $Machine.KnownFolder 'CommonAppData'
    $sys = & $Machine.KnownFolder 'System'
    # IO.Path.Combine takes a relative or empty folder as it is (the task would start a relative powershell.exe): only full paths with a drive (#83)
    foreach ($kf in @(@('ProgramFiles', $pf), @('CommonAppData', $pd), @('System', $sys))) {
        if (-not ([string]$kf[1] -match '\A[A-Za-z]:\\' -and [IO.Path]::IsPathRooted([string]$kf[1]))) { throw "The known folder $($kf[0]) is not a full path ('$($kf[1])')." }
    }
    # plain string joins: Join-Path of Windows PowerShell 5.1 needs the drive to exist, the paths of a fake machine (X:\Fake) only exist as text
    $j = { param($a, $b) [IO.Path]::Combine([string]$a, [string]$b) }
    $dir = & $j (& $j $pf 'AVDTune') 'Watermark'
    $pub = & $j $pd 'AVDTune-Public'
    [pscustomobject]@{
        AppDir = (& $j $pf 'AVDTune'); PowerShell = (& $j $sys 'WindowsPowerShell\v1.0\powershell.exe'); Conhost = (& $j $sys 'conhost.exe')
        ProgramDir = $dir; Script = (& $j $dir 'Show-AVDTuneWatermark.ps1'); Core = (& $j $dir 'AVDTune-WatermarkCore.ps1')
        PublicDir = $pub; PublicJson = (& $j $pub 'watermark.json'); LegacyVbs = (& $j $pd $script:LegacyVbs)
    }
}

function Get-AVDTuneWatermarkSettings {
    <#
        The saved settings (config\watermark.json of the state root); the defaults when nothing is saved. Errors lists what is wrong with a saved
        file (the defaults are used then). Saved says whether a file exists.
    #>
    param([string]$Root = (Get-AVDTuneRoot))
    $path = Join-Path $Root 'config\watermark.json'
    $raw = $null; $errors = @()
    try { $raw = Read-AVDTuneJson $path } catch { $errors = @("The saved settings cannot be read: $($_.Exception.Message)") }
    if ($null -eq $raw) { return [pscustomobject]@{ Settings = (ConvertTo-AVDTuneWatermarkSettings $null).Settings; Errors = $errors; Saved = $false } }
    $r = ConvertTo-AVDTuneWatermarkSettings $raw
    if ($r.Valid) { return [pscustomobject]@{ Settings = $r.Settings; Errors = @(); Saved = $true } }
    [pscustomobject]@{ Settings = (ConvertTo-AVDTuneWatermarkSettings $null).Settings; Errors = @($r.Errors); Saved = $true }
}

function Save-AVDTuneWatermarkSettings {
    # Validates and saves to config\watermark.json. Invalid settings are refused with the reasons; nothing on the master changes.
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Settings)
    $r = ConvertTo-AVDTuneWatermarkSettings $Settings
    if (-not $r.Valid) { throw ('The settings are not valid: ' + ($r.Errors -join ' ')) }
    Write-AVDTuneFile (Join-Path $Root 'config\watermark.json') ($r.Settings | ConvertTo-Json -Depth 5)
    $r.Settings
}

function ConvertTo-WmCompactJson($Object) { ($Object | ConvertTo-Json -Depth 5 -Compress) }

#endregion

function Get-AVDTuneWatermarkAclProblems {
    # What is not safe about the places the overlay runs from: C:\Program Files\AVDTune, the program folder and both script files (as far as they exist). Empty = fine.
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$Paths)
    $out = New-Object System.Collections.ArrayList
    foreach ($p in $Paths.AppDir, $Paths.ProgramDir, $Paths.Script, $Paths.Core) {
        foreach ($x in @(Get-AVDTuneAclProblems (& $Machine.AclReport $p))) { [void]$out.Add("${p}: $x") }
    }
    @($out)
}

#region task definition

function Get-AVDTuneWatermarkTaskAction {
    # The command of the task. Hidden: powershell.exe -WindowStyle Hidden (a console window can flash for a moment, see New-AVDTuneWatermarkTaskXml).
    # Headless: conhost.exe --headless in front (no window at all, but undocumented, see the notes on the page).
    param([Parameter(Mandatory)]$Paths, [ValidateSet('Hidden', 'Headless')][string]$ConsoleMode = 'Hidden')
    $ps = '-WindowStyle Hidden -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $Paths.Script + '"'
    if ($ConsoleMode -eq 'Headless') { return [pscustomobject]@{ Execute = $Paths.Conhost; Arguments = '--headless "' + $Paths.PowerShell + '" ' + $ps } }
    [pscustomobject]@{ Execute = $Paths.PowerShell; Arguments = $ps }
}
function New-AVDTuneWatermarkTaskXml {
    <#
        The task definition: at logon of any user, principal the group BUILTIN\Users by SID (no name, so it works in every language), least
        privilege (the overlay runs with the rights of the signed-in user), no time limit (the default would end the overlay after 3 days), one
        instance per session. The console window of powershell.exe: it is created before -WindowStyle Hidden is read, so it can flash for a
        moment at logon. No documented way removes it; conhost --headless does on current Windows 10/11 but is undocumented and is flagged by some
        EDR rules, so it is a switch, off by default.
    #>
    param([Parameter(Mandatory)]$Paths, [ValidateSet('Hidden', 'Headless')][string]$ConsoleMode = 'Hidden')
    $a = Get-AVDTuneWatermarkTaskAction -Paths $Paths -ConsoleMode $ConsoleMode
    $e = { param($s) [Security.SecurityElement]::Escape($s) }
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>AVDTune watermark: shows the pilot label when the computer name matches the pattern of the settings. Managed by AVDTune.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Users">
      <GroupId>$script:UsersSid</GroupId>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Users">
    <Exec>
      <Command>$(& $e $a.Execute)</Command>
      <Arguments>$(& $e $a.Arguments)</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

#endregion

#region old overlay

function Get-AVDTuneWatermarkLegacy {
    # The old customer overlay: task "PilotOverlay" in the root folder and the VBS launcher in ProgramData
    param([Parameter(Mandatory)]$Machine)
    $paths = Get-AVDTuneWatermarkPaths $Machine
    $task = & $Machine.TaskDetail '\' $script:LegacyTask
    $vbs = [bool](& $Machine.PathExists $paths.LegacyVbs)
    [pscustomobject]@{ Present = ([bool]$task -or $vbs); Task = $task; Vbs = $vbs; VbsPath = $paths.LegacyVbs; TaskName = $script:LegacyTask }
}

function Get-WmLegacyBackupPath([string]$Root) { Join-Path $Root 'config\watermark-legacy.json' }

#endregion

#region steps

function Get-AVDTuneWatermarkCatalog {
    <#
        The steps of the watermark for the given (validated) settings. SourceRoot is the Watermark folder of the tool (the files that are copied).
        -ForRemoval loosens the tests to "is there": Off must also remove a version that differs from the current settings.
        Each entry: Id, Group, Step, Applies (scriptblock or $null).
    #>
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$SourceRoot, [string]$Root = (Get-AVDTuneRoot), [switch]$ForRemoval)
    $loose = [bool]$ForRemoval; $backupDir = Join-Path $Root 'config'
    $taskName = $script:TaskName; $usersSid = $script:UsersSid; $msKey = $script:MsKey; $legacyTask = $script:LegacyTask; $legacyVbs = $script:LegacyVbs
    $srcScript = [IO.File]::ReadAllText((Join-Path $SourceRoot 'Show-AVDTuneWatermark.ps1'))
    $srcCore = [IO.File]::ReadAllText((Join-Path $SourceRoot 'AVDTune-WatermarkCore.ps1'))
    $publicJson = ConvertTo-Json -InputObject (Get-AVDTuneWatermarkPublicSettings $Settings) -Depth 4
    $publicCompact = ConvertTo-WmCompactJson (Get-AVDTuneWatermarkPublicSettings $Settings)
    $ms = $Settings.Microsoft
    $learnTask = 'https://learn.microsoft.com/en-us/windows/win32/taskschd/task-scheduler-start-page'
    $items = New-Object System.Collections.ArrayList

    # ---- program files
    $test = {
        param($m)
        $p = Get-AVDTuneWatermarkPaths $m
        $s = & $m.FileText $p.Script; $c = & $m.FileText $p.Core
        if ($null -eq $s -and $null -eq $c -and $loose) { return @{ Compliant = $false; State = 'not installed' } }
        if ($loose) { return @{ Compliant = $true; State = 'installed' } }
        $problems = @(Get-AVDTuneWatermarkAclProblems $m $p)
        if ($problems.Count -gt 0) { return @{ Compliant = $false; State = "not safe: $($problems -join '; ')" } }
        if ($null -eq $s -and $null -eq $c) { return @{ Compliant = $false; State = 'not installed' } }
        $same = ($s -ceq $srcScript -and $c -ceq $srcCore)
        @{ Compliant = $same; State = $(if ($same) { 'installed' } elseif ($null -eq $s -or $null -eq $c) { 'incomplete' } else { 'differs from this AVDTune version' }) }
    }.GetNewClosure()
    $apply = {
        param($m)
        $p = Get-AVDTuneWatermarkPaths $m
        # nothing is written into a folder or over a file that others can change (or that someone else owns)
        $problems = @(Get-AVDTuneWatermarkAclProblems $m $p)
        if ($problems.Count -gt 0) { throw "The program folder is not safe, nothing was written: $($problems -join '; ')" }
        & $m.FileWrite $p.Core $srcCore 'Admin'; & $m.FileWrite $p.Script $srcScript 'Admin'
    }.GetNewClosure()
    $undo = { param($m) $p = Get-AVDTuneWatermarkPaths $m; & $m.FileRemove $p.Script; & $m.FileRemove $p.Core; & $m.DirRemoveEmpty $p.ProgramDir }
    $step = New-AVDTuneStep -Id 'userexperience.watermark-program' -Section UserExperience -Title 'Watermark: program files in C:\Program Files\AVDTune\Watermark' -Why 'The overlay script runs in every user session, so it must sit where users cannot change it: the program folder (administrators write, users read and run). The folder must not carry write access for anyone else; if it does, the step reports it and writes nothing it cannot protect.' -Risk Low -SourceUrl $learnTask -Test $test -Apply $apply -Undo $undo
    [void]$items.Add([pscustomobject]@{ Id = $step.Id; Group = 'Overlay'; Step = $step; Applies = $null })

    # ---- public settings copy
    $test = {
        param($m)
        $p = Get-AVDTuneWatermarkPaths $m
        $text = & $m.FileText $p.PublicJson
        if ($null -eq $text) { return @{ Compliant = $false; State = 'not installed' } }
        $problems = @(Get-AVDTuneAclProblems (& $m.AclReport $p.PublicDir)) + @(Get-AVDTuneAclProblems (& $m.AclReport $p.PublicJson))
        if ($problems.Count -gt 0) { return @{ Compliant = $false; State = "not safe: $($problems -join '; ')" } }
        if ($loose) { return @{ Compliant = $true; State = 'installed' } }
        $same = $false
        try { $r = ConvertTo-AVDTuneWatermarkSettings ($text | ConvertFrom-Json); $same = ($r.Valid -and (Get-AVDTuneWatermarkPublicSettings $r.Settings | ConvertTo-Json -Depth 5 -Compress) -ceq $publicCompact) } catch { }
        @{ Compliant = $same; State = $(if ($same) { 'matches the settings' } else { 'differs from the settings' }) }
    }.GetNewClosure()
    $apply = { param($m) $p = Get-AVDTuneWatermarkPaths $m; & $m.FileWrite $p.PublicJson $publicJson 'UsersRead' }.GetNewClosure()
    $undo = { param($m) $p = Get-AVDTuneWatermarkPaths $m; & $m.FileRemove $p.PublicJson; & $m.DirRemoveEmpty $p.PublicDir }
    $step = New-AVDTuneStep -Id 'userexperience.watermark-settings' -Section UserExperience -Title 'Watermark: settings copy for users (C:\ProgramData\AVDTune-Public\watermark.json)' -Why 'The overlay runs as the user and must read the pattern, text and colour. The state folder of AVDTune is administrators only, so a copy goes to its own folder: users read, only administrators and SYSTEM write (ProgramData itself would let users create files there). A folder that someone else prepared is not used.' -Risk Low -SourceUrl 'https://learn.microsoft.com/en-us/windows/security/identity-protection/access-control/access-control' -Test $test -Apply $apply -Undo $undo
    [void]$items.Add([pscustomobject]@{ Id = $step.Id; Group = 'Overlay'; Step = $step; Applies = $null })

    # ---- scheduled task
    $mode = [string]$Settings.ConsoleMode
    $test = {
        param($m)
        $t = & $m.TaskDetail '\' $taskName
        if (-not $t) { return @{ Compliant = $false; State = 'not installed' } }
        if ($loose) { return @{ Compliant = $true; State = 'installed' } }
        $p = Get-AVDTuneWatermarkPaths $m
        $want = Get-AVDTuneWatermarkTaskAction -Paths $p -ConsoleMode $mode
        $why = @()
        if ($t.Execute -cne $want.Execute -or $t.Arguments -cne $want.Arguments) { $why += 'other command' }
        if ($t.GroupSid -ne $usersSid -or $t.UserSid) { $why += 'not for the group Users' }
        if (-not $t.Logon) { $why += 'no logon trigger' }
        if (-not $t.Enabled) { $why += 'disabled' }
        @{ Compliant = ($why.Count -eq 0); State = $(if ($why.Count -eq 0) { "at logon, group Users, $mode" } else { $why -join ', ' }) }
    }.GetNewClosure()
    $apply = {
        param($m)
        $p = Get-AVDTuneWatermarkPaths $m
        if ($null -eq (& $m.FileText $p.Script) -or $null -eq (& $m.FileText $p.PublicJson)) { throw 'The program files and the settings copy are not in place: the task is not registered.' }
        if (@(Get-AVDTuneWatermarkAclProblems $m $p).Count -gt 0) { throw 'The program folder is not safe: the task is not registered.' }
        & $m.TaskRegisterXml '\' $taskName (New-AVDTuneWatermarkTaskXml -Paths $p -ConsoleMode $mode)
    }.GetNewClosure()
    $undo = { param($m) & $m.TaskRemove '\' $taskName }.GetNewClosure()
    $step = New-AVDTuneStep -Id 'userexperience.watermark-task' -Section UserExperience -Title 'Watermark: scheduled task "AVDTune Watermark" at logon for the group Users' -Why 'Starts the overlay in every session at logon (no VBS). Principal is the group BUILTIN\Users by SID S-1-5-32-545 with least privilege, so each user gets the label in his own session. A console window of powershell.exe can flash for a moment at logon (the window exists before -WindowStyle Hidden is read); the optional console mode Headless avoids it. Not verified on a multi-session host yet.' -Risk Low -SourceUrl $learnTask -Test $test -Apply $apply -Undo $undo
    [void]$items.Add([pscustomobject]@{ Id = $step.Id; Group = 'Overlay'; Step = $step; Applies = $null })

    # ---- Microsoft policy (optional)
    $values = [ordered]@{ fEnableWatermarking = 1; WatermarkingQrScale = [int]$ms.QrScale; WatermarkingOpacity = [int]$ms.Opacity; WatermarkingWidthFactor = [int]$ms.WidthFactor; WatermarkingHeightFactor = [int]$ms.HeightFactor }
    $test = {
        param($m)
        $on = & $m.RegGet $msKey 'fEnableWatermarking'
        if ($null -eq $on) { return @{ Compliant = $false; State = 'not set' } }
        if ($loose) { return @{ Compliant = ([string]$on -eq '1'); State = "fEnableWatermarking=$on" } }
        $bad = @($values.Keys | Where-Object { [string](& $m.RegGet $msKey $_) -ne [string]$values[$_] })
        @{ Compliant = ($bad.Count -eq 0); State = $(if ($bad.Count -eq 0) { 'on' } else { 'differs: ' + ($bad -join ', ') }) }
    }.GetNewClosure()
    $apply = { param($m) foreach ($k in $values.Keys) { & $m.RegSet $msKey $k $values[$k] 'DWord' } }.GetNewClosure()
    $undo = { param($m) foreach ($k in $values.Keys) { & $m.RegRemove $msKey $k } }.GetNewClosure()
    $step = New-AVDTuneStep -Id 'userexperience.watermark-microsoft' -Section UserExperience -Title 'Microsoft watermark: QR code with the connection ID in every remote session (fEnableWatermarking)' -Why 'Optional, for forensic needs: the Remote Desktop client draws QR codes with the connection ID over the remote desktop, so a photo of the screen can be traced to a session. Once it is on, only clients that support watermarking can connect (others fail with an unspecific error); RemoteApp is not watermarked. The values and ranges are from Microsoft Learn; the registry value names are from the ADMX template, not from the Learn page (not verified on a live host).' -Risk Medium -SourceUrl $script:MsLearn -Test $test -Apply $apply -Undo $undo
    $msApplies = { param($m) $true }.GetNewClosure()
    if (-not $loose) { $enabled = [bool]$ms.Enabled; $msApplies = { param($m) $enabled }.GetNewClosure() }
    [void]$items.Add([pscustomobject]@{ Id = $step.Id; Group = 'Microsoft watermark'; Step = $step; Applies = $msApplies })

    # ---- old overlay
    $test = {
        param($m)
        $l = Get-AVDTuneWatermarkLegacy $m
        if (-not $l.Present) { return @{ Compliant = $true; State = 'none' } }
        $found = @(); if ($l.Task) { $found += "task $legacyTask" }; if ($l.Vbs) { $found += $legacyVbs }
        @{ Compliant = $false; State = ($found -join ' + ') }
    }.GetNewClosure()
    $apply = {
        param($m)
        $l = Get-AVDTuneWatermarkLegacy $m
        # backup first: the task definition and the launcher, so Undo can put them back
        $backup = [ordered]@{ Schema = 1; At = (& $m.Now).ToString('o'); Task = $null; Vbs = $null }
        if ($l.Task) { $backup.Task = [ordered]@{ Name = $legacyTask; Xml = [string]$l.Task.Xml } }
        if ($l.Vbs) { $backup.Vbs = [ordered]@{ Path = $l.VbsPath; Text = [string](& $m.FileText $l.VbsPath) } }
        # every removal gets its own backup file: an earlier one is never overwritten
        $stamp = (& $m.Now).ToString('yyyyMMdd-HHmmss-fff', [Globalization.CultureInfo]::InvariantCulture)
        $backupPath = Join-Path $backupDir "watermark-legacy-$stamp-$([guid]::NewGuid().ToString('N').Substring(0, 4)).json"
        Write-AVDTuneFile $backupPath ($backup | ConvertTo-Json -Depth 5)
        if ($l.Task) { & $m.TaskRemove '\' $legacyTask }
        if ($l.Vbs) { & $m.FileRemove $l.VbsPath }
    }.GetNewClosure()
    $undo = {
        param($m)
        $newest = @(Get-ChildItem -LiteralPath $backupDir -Filter 'watermark-legacy-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)[-1]
        $b = if ($newest) { Read-AVDTuneJson $newest.FullName } else { $null }
        if (-not $b) { throw 'There is no backup of the old overlay to restore.' }
        $task = Get-AVDTuneProp $b 'Task'; $vbs = Get-AVDTuneProp $b 'Vbs'
        # only the fixed place and only new: the path and the name in the backup file are not used, an existing file or task is never replaced
        if ($vbs) { & $m.FileWrite (Get-AVDTuneWatermarkPaths $m).LegacyVbs ([string]$vbs.Text) 'AdminNew' }
        if ($task -and $task.Xml) {
            if (& $m.TaskDetail '\' $legacyTask) { throw "The task $legacyTask exists already. It is not replaced." }
            & $m.TaskRegisterXml '\' $legacyTask ([string]$task.Xml)
        }
    }.GetNewClosure()
    $step = New-AVDTuneStep -Id 'userexperience.watermark-legacy' -Section UserExperience -Title 'Old overlay: remove the task "PilotOverlay" and PilotOverlayLauncher.vbs' -Why 'The old customer overlay uses a VBS launcher (VBScript is being phased out by Microsoft), a global mutex (only the first user of a host got the label) and only the primary screen. The new one replaces it. A backup of the task definition and the launcher is kept in AVDTune''s state folder, so this can be undone. Overlays that are running right now are not stopped; they end when the user signs out.' -Risk Medium -SourceUrl 'https://learn.microsoft.com/en-us/windows/win32/taskschd/task-scheduler-start-page' -Test $test -Apply $apply -Undo $undo
    [void]$items.Add([pscustomobject]@{ Id = $step.Id; Group = 'Old overlay'; Step = $step; Applies = $null })
    @($items)
}

#endregion

#region status and switch

function Get-AVDTuneWatermarkStatus {
    <#
        Live status. State: Installed (program, settings copy and task in place), Partial, NotInstalled. Items (per step: Id, Group, Title,
        Applicable, Compliant, State, Why, Source), Legacy (the old overlay), HostName and HostMatch (would the label appear on this host).
    #>
    param([Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot), [string]$SourceRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'Watermark'))
    $saved = Get-AVDTuneWatermarkSettings -Root $Root
    $catalog = @(Get-AVDTuneWatermarkCatalog -Settings $saved.Settings -SourceRoot $SourceRoot -Root $Root)
    $rows = New-Object System.Collections.ArrayList
    foreach ($e in $catalog) {
        $applicable = $true; if ($e.Applies) { $applicable = [bool](& $e.Applies $Machine) }
        $t = ConvertTo-AVDTuneTestResult (& $e.Step.Test $Machine)
        # the Microsoft policy is only part of the state when it is switched on; a policy that is still set after it was switched off is reported
        $state = [string]$t.State
        if ($e.Id -eq 'userexperience.watermark-microsoft' -and -not $applicable) { $state = $(if ($t.State -eq 'not set') { 'off' } else { 'set, but switched off in the settings: Install removes it' }) }
        [void]$rows.Add([pscustomobject]@{ Id = $e.Id; Group = $e.Group; Title = $e.Step.Title; Applicable = $applicable; Compliant = $(if ($applicable) { [bool]$t.Compliant } else { $true }); State = $state; Why = $e.Step.Why; Source = $e.Step.SourceUrl })
    }
    $core = @($rows | Where-Object { $_.Group -eq 'Overlay' })
    $good = @($core | Where-Object { $_.Compliant })
    $overall = if ($good.Count -eq $core.Count) { 'Installed' } elseif ($good.Count -eq 0 -and @($core | Where-Object { $_.State -ne 'not installed' }).Count -eq 0) { 'NotInstalled' } else { 'Partial' }
    $name = [string](& $Machine.ComputerName)
    [pscustomobject]@{
        State = $overall; Items = @($rows); Settings = $saved.Settings; SettingsErrors = @($saved.Errors); SettingsSaved = $saved.Saved
        Legacy = (Get-AVDTuneWatermarkLegacy $Machine); HostName = $name; HostMatch = (Test-AVDTuneWatermarkName $saved.Settings.Pattern $name)
        Microsoft = [bool]$saved.Settings.Microsoft.Enabled
    }
}

function Set-AVDTuneWatermark {
    <#
        Mode On: program files, settings copy, task and, when switched on in the settings, the Microsoft policy (switched off: removed). Mode Off:
        everything of the watermark removed (Undo). Mode LegacyRemove / LegacyRestore: the old overlay. Needs the open write gate unless -WhatIf.
        Writes a run record, one change log entry and the state (LastChange for the snapshot gate). Returns the summary.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot), [string]$SourceRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'Watermark'),
        [Parameter(Mandatory)][ValidateSet('On', 'Off', 'LegacyRemove', 'LegacyRestore')][string]$Mode,
        [string]$User, [string]$SnapshotId, [switch]$WhatIf
    )
    if (-not $WhatIf -and -not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot of today is confirmed on the Overview.' }
    $saved = Get-AVDTuneWatermarkSettings -Root $Root
    $changeOwner = $false; if (-not $WhatIf) { $changeOwner = Start-AVDTuneChange -Root $Root }   # marker: the first change of the version starts here, no new version or snapshot counts while it runs (#27)
    try {
    if ($Mode -eq 'On' -and $saved.Errors.Count -gt 0) { throw ('The saved settings are not valid: ' + ($saved.Errors -join ' ')) }
    $catalog = @(Get-AVDTuneWatermarkCatalog -Settings $saved.Settings -SourceRoot $SourceRoot -Root $Root -ForRemoval:($Mode -eq 'Off'))
    $by = @{}; foreach ($e in $catalog) { $by[$e.Id] = $e }
    $plan = New-Object System.Collections.ArrayList   # @{ Id; Mode }
    switch ($Mode) {
        'On' {
            foreach ($id in 'userexperience.watermark-program', 'userexperience.watermark-settings', 'userexperience.watermark-task') { [void]$plan.Add(@{ Id = $id; Mode = 'Apply' }) }
            [void]$plan.Add(@{ Id = 'userexperience.watermark-microsoft'; Mode = $(if ($saved.Settings.Microsoft.Enabled) { 'Apply' } else { 'Undo' }) })
        }
        'Off' { foreach ($id in 'userexperience.watermark-microsoft', 'userexperience.watermark-task', 'userexperience.watermark-settings', 'userexperience.watermark-program') { [void]$plan.Add(@{ Id = $id; Mode = 'Undo' }) } }
        'LegacyRemove' { [void]$plan.Add(@{ Id = 'userexperience.watermark-legacy'; Mode = 'Apply' }) }
        'LegacyRestore' { [void]$plan.Add(@{ Id = 'userexperience.watermark-legacy'; Mode = 'Undo' }) }
    }
    $results = New-Object System.Collections.ArrayList
    foreach ($p in $plan) {
        $step = $by[$p.Id].Step
        # taking something away only asks "is it there": a policy set with other values than the settings must still go
        if ($p.Mode -eq 'Undo' -and $Mode -eq 'On') { $step = (Get-AVDTuneWatermarkCatalog -Settings $saved.Settings -SourceRoot $SourceRoot -Root $Root -ForRemoval | Where-Object Id -eq $p.Id).Step }
        # a policy that is off in the settings and not set is not a step of this run
        if ($p.Id -eq 'userexperience.watermark-microsoft' -and $p.Mode -eq 'Undo' -and $Mode -eq 'On') {
            if ($null -eq (& $Machine.RegGet $script:MsKey 'fEnableWatermarking')) { continue }
        }
        # the task is only registered when the program files and the settings copy are in place (compliant after this run)
        if ($p.Id -eq 'userexperience.watermark-task' -and $p.Mode -eq 'Apply') {
            $notReady = @($results | Where-Object { $_.Id -in 'userexperience.watermark-program', 'userexperience.watermark-settings' -and $_.Status -notin 'Changed', 'Unchanged', 'WhatIf' })
            if ($notReady.Count -gt 0) {
                [void]$results.Add([pscustomobject]@{ Id = $step.Id; Section = $step.Section; Title = $step.Title; Mode = 'Apply'; Status = 'Skipped'; Before = $null; After = $null; Message = 'The program files or the settings copy are not in place: the task is not registered.'; Reboot = $false; WhatIf = [bool]$WhatIf; At = $null })
                continue
            }
        }
        [void]$results.Add((Invoke-AVDTuneStep -Step $step -Machine $Machine -Mode $p.Mode -WhatIf:$WhatIf))
    }
    $changed = @($results | Where-Object { $_.Status -in 'Changed', 'Reverted' })
    $failed = @($results | Where-Object { $_.Status -eq 'Failed' })
    $status = Get-AVDTuneWatermarkStatus -Machine $Machine -Root $Root -SourceRoot $SourceRoot
    $summary = [pscustomobject]@{ Mode = $Mode; Changed = $changed.Count; Failed = $failed.Count; Results = @($results); State = $status.State; WhatIf = [bool]$WhatIf }
    if ($WhatIf) { return $summary }
    $label = @{ On = 'Watermark install'; Off = 'Watermark remove'; LegacyRemove = 'Old overlay remove'; LegacyRestore = 'Old overlay restore' }[$Mode]
    $state = Get-AVDTuneState $Root
    $run = [pscustomobject][ordered]@{
        Id = $null; Plan = $label; Started = (& $Machine.Now).ToString('o'); Ended = (& $Machine.Now).ToString('o'); User = $User; SnapshotId = $SnapshotId
        WhatIf = $false; ImageVersion = $state.ImageVersion; Reboot = $false; Results = @($results)
    }
    [void](Add-AVDTuneRun -Root $Root -Run $run)
    $values = @{ Watermark = $status.State }; if ($changed.Count -gt 0 -or $failed.Count -gt 0) { $values.LastChange = (& $Machine.Now).ToString('o') }
    [void](Set-AVDTuneState -Root $Root -Values $values)
    if ($state.ImageVersion -and ($changed.Count -gt 0 -or $failed.Count -gt 0)) {
        $type = switch ($Mode) { 'On' { 'Added' } 'Off' { 'Removed' } 'LegacyRemove' { 'Removed' } default { 'Changed' } }
        $component = if ($Mode -like 'Legacy*') { 'Watermark (old overlay)' } else { 'Watermark' }
        $what = switch ($Mode) { 'On' { 'installed or updated' } 'Off' { 'removed' } 'LegacyRemove' { 'old overlay (task PilotOverlay, VBS launcher) removed' } default { 'old overlay restored' } }
        $text = if ($failed.Count -gt 0) { "Watermark $what`: $($changed.Count) change(s), $($failed.Count) failed" } else { "Watermark $what`: $($changed.Count) change(s)" }
        [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'User experience' -Component $component -ChangeType $type -Text $text -User $User -SnapshotId $SnapshotId -RunId $run.Id -Source Step)
    }
    $summary
    }
    finally { Stop-AVDTuneChange -Root $Root -Owner $changeOwner }
}

#endregion

Export-ModuleMember -Function Get-AVDTuneWatermarkPaths, Get-AVDTuneWatermarkSettings, Save-AVDTuneWatermarkSettings, Get-AVDTuneWatermarkTaskAction, New-AVDTuneWatermarkTaskXml,
    Get-AVDTuneWatermarkLegacy, Get-AVDTuneWatermarkAclProblems, Get-AVDTuneWatermarkCatalog, Get-AVDTuneWatermarkStatus, Set-AVDTuneWatermark,
    Get-AVDTuneWatermarkDefaults, Test-AVDTuneWatermarkPattern, Test-AVDTuneWatermarkName, ConvertTo-AVDTuneWatermarkSettings, Get-AVDTuneWatermarkPublicSettings, Get-AVDTuneWatermarkPlacement, ConvertTo-WmRgb
