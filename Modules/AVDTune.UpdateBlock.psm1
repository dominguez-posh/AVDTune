<#
    AVDTune update block for users (docs\plans\avdtune.md, section 4) and maintenance mode.

    The block is a list of steps (Test/Apply/Undo of the step contract in AVDTune.psm1, section UpdateBlock), grouped by product. All access
    goes through the machine adapter, so the checks run against Tests\Fakes\FakeMachine.ps1. Apply and Undo need the open write gate (snapshot
    confirmed); status and dry runs are always possible.

    Windows services are NOT disabled: the Update Orchestrator and WaaSMedic switch a disabled Windows Update service back on, and other
    components (Store, Defender definitions, DISM sources) depend on them. The policies are the lever; a disabled service is reported as a finding.

    Maintenance mode lifts the block for AVDTune's own update run and sets it back in a finally block. Before the first change a record is
    written to state.json (Maintenance: Active, Phase, BlockBefore = ids that were on), after the restore the result. A record that is still
    Active at the next start means AVDTune was closed or crashed in the middle: Get-AVDTuneMaintenanceCrash finds it, Repair-AVDTuneMaintenanceCrash
    puts the block back and writes a change log entry.

    Sources: each step names its documentation. Verified against Microsoft Learn on 2026-11-15: Windows policies (waas-wu-settings, policy-csp-update),
    Edge update policies, Teams disableAutoUpdate (teams-client-vdi-requirements-deploy), Store AutoDownload value name. NOT verifiable on Learn
    (reported): the Office policy registry path (policy names are on Learn), Chrome/Google Update and Adobe policy values (vendor documentation).
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')

$script:WuPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$script:OfficePolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'

#region catalog

function New-BlockRegistryStep {
    param([string]$Id, [string]$Group, [string]$Title, [string]$Why, [string]$Source, [string]$Path, [string]$Name, $Value, [scriptblock]$Applies, [string]$Risk = 'Low')
    $test = {
        param($m)
        if ($Applies -and -not (& $Applies $m)) { return @{ Compliant = $true; State = 'not installed' } }
        $v = & $m.RegGet $Path $Name
        @{ Compliant = ($null -ne $v -and [string]$v -eq [string]$Value); State = $v }
    }.GetNewClosure()
    $apply = { param($m) & $m.RegSet $Path $Name $Value 'DWord' }.GetNewClosure()
    $undo = { param($m) & $m.RegRemove $Path $Name }.GetNewClosure()
    $step = New-AVDTuneStep -Id $Id -Section UpdateBlock -Title $Title -Why $Why -Risk $Risk -SourceUrl $Source -Test $test -Apply $apply -Undo $undo
    [pscustomobject]@{ Id = $Id; Group = $Group; Step = $step; Applies = $Applies; Registry = "$Path\$Name = $Value" }
}

function New-BlockTaskStep {
    # Tasks in the root folder whose name matches a pattern (the Edge and Chrome update tasks carry a GUID in the name)
    param([string]$Id, [string]$Group, [string]$Title, [string]$Why, [string]$Source, [string]$Pattern)
    $find = {
        param($m)
        $found = @()
        foreach ($name in @(& $m.TaskList '\')) { if ($name -match $Pattern) { $t = & $m.TaskGet '\' $name; if ($t) { $found += $t } } }
        $found
    }.GetNewClosure()
    $test = {
        param($m)
        $tasks = @(& $find $m)
        if ($tasks.Count -eq 0) { return @{ Compliant = $true; State = 'no task' } }
        $on = @($tasks | Where-Object { $_.Enabled })
        @{ Compliant = ($on.Count -eq 0); State = $(if ($on.Count -eq 0) { 'disabled' } else { "$($on.Count) enabled" }) }
    }.GetNewClosure()
    $apply = { param($m) foreach ($t in @(& $find $m)) { & $m.TaskSetEnabled $t.Path $t.Name $false } }.GetNewClosure()
    $undo = { param($m) foreach ($t in @(& $find $m)) { & $m.TaskSetEnabled $t.Path $t.Name $true } }.GetNewClosure()
    $step = New-AVDTuneStep -Id $Id -Section UpdateBlock -Title $Title -Why $Why -SourceUrl $Source -Test $test -Apply $apply -Undo $undo
    $applies = { param($m) @(& $find $m).Count -gt 0 }.GetNewClosure()
    [pscustomobject]@{ Id = $Id; Group = $Group; Step = $step; Applies = $applies; Registry = "tasks \$Pattern" }
}

function New-BlockServiceStep {
    param([string]$Id, [string]$Group, [string]$Title, [string]$Why, [string]$Source, [string]$Service)
    $test = {
        param($m)
        $s = & $m.ServiceGet $Service
        if (-not $s) { return @{ Compliant = $true; State = 'not installed' } }
        @{ Compliant = ($s.StartType -eq 'Disabled' -and $s.Status -ne 'Running'); State = "$($s.StartType), $($s.Status)" }
    }.GetNewClosure()
    $apply = { param($m) & $m.ServiceSetStartup $Service 'Disabled'; $s = & $m.ServiceGet $Service; if ($s.Status -eq 'Running') { & $m.ServiceStop $Service } }.GetNewClosure()
    $undo = { param($m) & $m.ServiceSetStartup $Service 'Manual' }.GetNewClosure()
    $step = New-AVDTuneStep -Id $Id -Section UpdateBlock -Title $Title -Why $Why -SourceUrl $Source -Test $test -Apply $apply -Undo $undo
    $applies = { param($m) [bool](& $m.ServiceGet $Service) }.GetNewClosure()
    [pscustomobject]@{ Id = $Id; Group = $Group; Step = $step; Applies = $applies; Registry = "service $Service" }
}

function Get-AVDTuneUpdateBlockCatalog {
    # All steps of the block, in the order they are applied. Group is shown on the Update block page.
    $learnWu = 'https://learn.microsoft.com/en-us/windows/deployment/update/waas-wu-settings'
    $learnCsp = 'https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-update'
    $learnEdge = 'https://learn.microsoft.com/en-us/deployedge/microsoft-edge-update-policies'
    $learnOffice = 'https://learn.microsoft.com/en-us/microsoft-365-apps/updates/configure-update-settings-microsoft-365-apps'
    $learnTeams = 'https://learn.microsoft.com/en-us/microsoftteams/teams-client-vdi-requirements-deploy'
    $learnStore = 'https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-applicationmanagement'
    $chrome = { param($m) (& $m.RegKeyExists 'HKLM:\SOFTWARE\Google\Update') -or (& $m.RegKeyExists 'HKLM:\SOFTWARE\WOW6432Node\Google\Update') }
    $adobe = { param($m) (& $m.ServiceGet 'AdobeARMservice') -or (& $m.RegKeyExists 'HKLM:\SOFTWARE\WOW6432Node\Adobe\Adobe ARM') -or (& $m.RegKeyExists 'HKLM:\SOFTWARE\Adobe\Adobe ARM') }
    $teams = { param($m) (& $m.RegKeyExists 'HKLM:\SOFTWARE\Microsoft\Teams') -or (& $m.RegKeyExists 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Teams') }
    $ux = 'Services stay as Windows wants them: the Update Orchestrator and WaaSMedic switch a disabled service back on and Store, Defender and DISM depend on it. The policy is the lever.'
    $items = @(
        (New-BlockRegistryStep -Id 'updateblock.win-ux' -Group 'Windows' -Title 'Windows Update: remove access for users (SetDisableUXWUAccess=1)' -Why "Users get no Check for updates button; background scans and installs keep working as configured. $ux" -Source $learnCsp -Path $script:WuPolicy -Name 'SetDisableUXWUAccess' -Value 1)
        (New-BlockRegistryStep -Id 'updateblock.win-noauto' -Group 'Windows' -Title 'Windows Update: no automatic updates (NoAutoUpdate=1)' -Why "The master is updated by AVDTune only, never in the background. $ux" -Source $learnWu -Path "$script:WuPolicy\AU" -Name 'NoAutoUpdate' -Value 1)
        (New-BlockRegistryStep -Id 'updateblock.win-norestart' -Group 'Windows' -Title 'Windows Update: no automatic restart with users signed in (NoAutoRebootWithLoggedOnUsers=1)' -Why 'A restart of the master never comes from Windows Update by itself.' -Source $learnWu -Path "$script:WuPolicy\AU" -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1)
        (New-BlockRegistryStep -Id 'updateblock.office-auto' -Group 'Microsoft 365 Apps' -Title 'Office: automatic updates off (EnableAutomaticUpdates=0)' -Why 'The Click-to-Run configuration keeps Updates Enabled=FALSE (set by the Office page); this policy makes sure nobody switches it on.' -Source $learnOffice -Path $script:OfficePolicy -Name 'enableautomaticupdates' -Value 0)
        (New-BlockRegistryStep -Id 'updateblock.office-hide' -Group 'Microsoft 365 Apps' -Title 'Office: hide the update options from users (HideEnableDisableUpdates=1)' -Why 'Users do not see Update options in the Office account page.' -Source $learnOffice -Path $script:OfficePolicy -Name 'hideenabledisableupdates' -Value 1)
        (New-BlockRegistryStep -Id 'updateblock.edge-default' -Group 'Edge' -Title 'Edge Update: updates disabled (UpdateDefault=0)' -Why 'Edge is updated by AVDTune in maintenance mode. Note: Microsoft documents these policies for domain-joined or MDM-managed devices; on an unjoined master they may be ignored, the update tasks below are the second lever.' -Source $learnEdge -Path 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' -Name 'UpdateDefault' -Value 0)
        (New-BlockRegistryStep -Id 'updateblock.edge-period' -Group 'Edge' -Title 'Edge Update: no periodic update check (AutoUpdateCheckPeriodMinutes=0)' -Why 'Stops the periodic traffic of Edge Update. Microsoft does not recommend 0 because Edge Update itself then gets no updates; AVDTune updates it in maintenance mode, so the block lifts this value for the run.' -Source $learnEdge -Path 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' -Name 'AutoUpdateCheckPeriodMinutes' -Value 0 -Risk Medium)
        (New-BlockTaskStep -Id 'updateblock.edge-tasks' -Group 'Edge' -Title 'Edge Update: scheduled update tasks off' -Why 'MicrosoftEdgeUpdateTaskMachineCore and ...UA would update Edge in the background.' -Source $learnEdge -Pattern '^MicrosoftEdgeUpdateTaskMachine(Core|UA)')
        (New-BlockRegistryStep -Id 'updateblock.chrome-default' -Group 'Chrome' -Title 'Google Update: updates disabled (UpdateDefault=0)' -Why 'Only when Chrome is installed. Vendor documentation, not Microsoft Learn.' -Source 'https://support.google.com/chrome/a/' -Path 'HKLM:\SOFTWARE\Policies\Google\Update' -Name 'UpdateDefault' -Value 0 -Applies $chrome)
        (New-BlockRegistryStep -Id 'updateblock.chrome-period' -Group 'Chrome' -Title 'Google Update: no periodic update check (AutoUpdateCheckPeriodMinutes=0)' -Why 'Only when Chrome is installed.' -Source 'https://support.google.com/chrome/a/' -Path 'HKLM:\SOFTWARE\Policies\Google\Update' -Name 'AutoUpdateCheckPeriodMinutes' -Value 0 -Applies $chrome)
        (New-BlockTaskStep -Id 'updateblock.chrome-tasks' -Group 'Chrome' -Title 'Google Update: scheduled update tasks off' -Why 'GoogleUpdateTaskMachineCore and ...UA.' -Source 'https://support.google.com/chrome/a/' -Pattern '^GoogleUpdateTaskMachine(Core|UA)')
        (New-BlockRegistryStep -Id 'updateblock.teams' -Group 'Teams' -Title 'New Teams: automatic update off (disableAutoUpdate=1)' -Why 'Documented for VDI: the Teams MSIX installer then does not update by itself; AVDTune updates it with teamsbootstrapper in maintenance mode. Only builds above 23306.3314.2555.9628 read this value.' -Source $learnTeams -Path 'HKLM:\SOFTWARE\Microsoft\Teams' -Name 'disableAutoUpdate' -Value 1)
        (New-BlockRegistryStep -Id 'updateblock.adobe-acrobat' -Group 'Adobe' -Title 'Adobe Acrobat: updater off (bUpdater=0)' -Why 'Only when an Adobe product is installed. Vendor documentation (Preference Reference), not Microsoft Learn.' -Source 'https://www.adobe.com/devnet-docs/acrobatetk/tools/PrefRef/Windows/Updater.html' -Path 'HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown' -Name 'bUpdater' -Value 0 -Applies $adobe)
        (New-BlockRegistryStep -Id 'updateblock.adobe-reader' -Group 'Adobe' -Title 'Adobe Reader: updater off (bUpdater=0)' -Why 'Same for the Reader product key.' -Source 'https://www.adobe.com/devnet-docs/acrobatetk/tools/PrefRef/Windows/Updater.html' -Path 'HKLM:\SOFTWARE\Policies\Adobe\Acrobat Reader\DC\FeatureLockDown' -Name 'bUpdater' -Value 0 -Applies $adobe)
        (New-BlockServiceStep -Id 'updateblock.adobe-service' -Group 'Adobe' -Title 'Adobe Acrobat Update Service off' -Why 'Only when the service exists. Vendor documentation. Undo sets it to Manual.' -Source 'https://www.adobe.com/devnet-docs/acrobatetk/tools/PrefRef/Windows/Updater.html' -Service 'AdobeARMservice')
        (New-BlockRegistryStep -Id 'updateblock.store' -Group 'Store' -Title 'Microsoft Store: no automatic download of app updates (AutoDownload=2)' -Why 'Learn names the value (Software\Policies\Microsoft\WindowsStore\AutoDownload); the meaning of 2 (always off) is from the ADMX template, not from the page.' -Source $learnStore -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name 'AutoDownload' -Value 2)
    )
    $items
}

#endregion

#region status

function Get-AVDTuneUpdateBlockStatus {
    <#
        Live status from the machine. State: On (every applicable setting in place), Partial, Off (none). Items: Id, Group, Title, Applicable,
        Compliant, State. Findings: things that are not part of the block but matter (a disabled Windows Update service, Office Updates Enabled).
    #>
    param([Parameter(Mandatory)]$Machine)
    $items = New-Object System.Collections.ArrayList
    foreach ($entry in Get-AVDTuneUpdateBlockCatalog) {
        $applicable = $true
        if ($entry.Applies) { $applicable = [bool](& $entry.Applies $Machine) }
        $state = 'not installed'; $ok = $true
        if ($applicable) { $t = ConvertTo-AVDTuneTestResult (& $entry.Step.Test $Machine); $ok = $t.Compliant; $state = $t.State }
        [void]$items.Add([pscustomobject]@{ Id = $entry.Id; Group = $entry.Group; Title = $entry.Step.Title; Applicable = $applicable; Compliant = $ok; State = [string]$state; Source = $entry.Step.SourceUrl; Why = $entry.Step.Why })
    }
    $app = @($items | Where-Object { $_.Applicable })
    $good = @($app | Where-Object { $_.Compliant })
    $bad = @($app | Where-Object { -not $_.Compliant })
    $overall = if ($bad.Count -eq 0) { 'On' } elseif ($good.Count -eq 0) { 'Off' } else { 'Partial' }
    $findings = New-Object System.Collections.ArrayList
    foreach ($svc in 'wuauserv', 'UsoSvc', 'WaaSMedicSvc') {
        $s = & $Machine.ServiceGet $svc
        if ($s -and $s.StartType -eq 'Disabled') { [void]$findings.Add("The service $svc is disabled. Windows switches it back on (WaaSMedic) and Windows Update needs it for AVDTune's own run: leave it as Windows wants it, the policies block the users.") }
    }
    $upd = & $Machine.RegGet 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' 'UpdatesEnabled'
    if ($null -ne $upd -and ([string]$upd).ToUpperInvariant() -eq 'TRUE') { [void]$findings.Add('Office: Updates Enabled is TRUE in the Click-to-Run configuration. In the image it must be FALSE (Office page, Updates Enabled=FALSE).') }
    [pscustomobject]@{
        State = $overall; Items = @($items); Applicable = $app.Count; Compliant = $good.Count
        Missing = (@($bad | ForEach-Object { $_.Group } | Select-Object -Unique) -join ', '); Findings = @($findings)
    }
}

#endregion

#region switch on / off

function Set-AVDTuneUpdateBlock {
    <#
        Switches the whole block On (Apply of every applicable step that is not in place) or Off (Undo). Needs the open write gate unless -WhatIf.
        Writes a run record, one change log entry and the state (UpdateBlock = On/Off by the live status afterwards). Returns the summary.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][ValidateSet('On', 'Off')][string]$Mode,
        [string]$User, [string]$SnapshotId, [switch]$WhatIf
    )
    if (-not $WhatIf -and -not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot of today is confirmed on the Overview.' }
    $stepMode = if ($Mode -eq 'On') { 'Apply' } else { 'Undo' }
    $results = New-Object System.Collections.ArrayList
    foreach ($entry in Get-AVDTuneUpdateBlockCatalog) {
        if ($entry.Applies -and -not (& $entry.Applies $Machine)) { continue }
        [void]$results.Add((Invoke-AVDTuneStep -Step $entry.Step -Machine $Machine -Mode $stepMode -WhatIf:$WhatIf))
    }
    $changed = @($results | Where-Object { $_.Status -in 'Changed', 'Reverted' })
    $failed = @($results | Where-Object { $_.Status -eq 'Failed' })
    $status = Get-AVDTuneUpdateBlockStatus $Machine
    $summary = [pscustomobject]@{ Mode = $Mode; Changed = $changed.Count; Failed = $failed.Count; Results = @($results); State = $status.State; WhatIf = [bool]$WhatIf }
    if ($WhatIf) { return $summary }
    $state = Get-AVDTuneState $Root
    $run = [pscustomobject][ordered]@{
        Id = $null; Plan = "Update block $($Mode.ToLower())"; Started = (& $Machine.Now).ToString('o'); Ended = (& $Machine.Now).ToString('o'); User = $User; SnapshotId = $SnapshotId
        WhatIf = $false; ImageVersion = $state.ImageVersion; Reboot = $false; Results = @($results)
    }
    [void](Add-AVDTuneRun -Root $Root -Run $run)
    # LastChange (snapshot gate): every switch that changed or tried to change a setting
    $values = @{ UpdateBlock = $status.State }; if ($changed.Count -gt 0 -or $failed.Count -gt 0) { $values.LastChange = (& $Machine.Now).ToString('o') }
    [void](Set-AVDTuneState -Root $Root -Values $values)
    if ($state.ImageVersion -and ($changed.Count -gt 0 -or $failed.Count -gt 0)) {
        $text = if ($failed.Count -gt 0) { "Update block $($Mode.ToLower()): $($changed.Count) setting(s) changed, $($failed.Count) failed" } else { "Update block switched $($Mode.ToLower()): $($changed.Count) setting(s) changed" }
        [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'Update block' -Component 'Update block' -ChangeType Changed -Text $text -User $User -SnapshotId $SnapshotId -RunId $run.Id -Source Step)
    }
    $summary
}

#endregion

#region maintenance mode

function Get-AVDTuneMaintenanceRecord([string]$Root) {
    $state = Get-AVDTuneState $Root
    Get-AVDTuneProp $state 'Maintenance'
}

function Get-AVDTuneMaintenanceCrash {
    # The record of a maintenance mode that never ended (closed or crashed in the middle), or $null
    param([string]$Root = (Get-AVDTuneRoot))
    $r = Get-AVDTuneMaintenanceRecord $Root
    if ($r -and (Get-AVDTuneProp $r 'Active')) { $r } else { $null }
}

function Start-AVDTuneMaintenance {
    <#
        Writes the record (before state), then lifts every setting of the block that is in place. Returns the context for Stop-AVDTuneMaintenance.
        Refuses while an earlier record is still Active: repair that first.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId)
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot of today is confirmed on the Overview.' }
    if (Get-AVDTuneMaintenanceCrash -Root $Root) { throw 'An earlier maintenance mode did not end properly. Repair it on the Update block page first.' }
    $status = Get-AVDTuneUpdateBlockStatus $Machine
    $before = @($status.Items | Where-Object { $_.Applicable -and $_.Compliant } | ForEach-Object { $_.Id })
    $id = (& $Machine.Now).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    $record = [pscustomobject][ordered]@{
        Active = $true; Id = $id; Phase = 'lifting'; Started = (& $Machine.Now).ToString('o'); Ended = $null; User = $User; SnapshotId = $SnapshotId
        BlockBefore = $before; BlockAfter = @(); Result = ''
    }
    # LastChange (snapshot gate) is written before the first setting is lifted, so a crash in the middle still counts as a change
    $values = @{ Maintenance = $record; UpdateBlock = 'Maintenance' }; if ($before.Count -gt 0) { $values.LastChange = (& $Machine.Now).ToString('o') }
    [void](Set-AVDTuneState -Root $Root -Values $values)
    $lift = New-Object System.Collections.ArrayList
    # From here the block may be lifted: an error before the caller's try/finally would leave it lifted, so it is put back here at once
    try {
        $catalog = @(Get-AVDTuneUpdateBlockCatalog)
        foreach ($entry in $catalog) {
            if ($entry.Id -notin $before) { continue }
            [void]$lift.Add((Invoke-AVDTuneStep -Step $entry.Step -Machine $Machine -Mode Undo))
        }
        $failed = @($lift | Where-Object { $_.Status -eq 'Failed' })
        $record.Phase = if ($failed.Count -gt 0) { 'lift-failed' } else { 'lifted' }
        $values = @{ Maintenance = $record }; if ($before.Count -gt 0) { $values.LastChange = (& $Machine.Now).ToString('o') }
        [void](Set-AVDTuneState -Root $Root -Values $values)
    }
    catch {
        $cause = $_.Exception.Message
        $r = Restore-AVDTuneBlockSettings -Machine $Machine -Ids $before
        $ok = ($r.Failed.Count -eq 0)
        # close the record when the block is back; when that write fails too the record stays Active and the next start offers the repair
        if ($ok) { $record.Active = $false; $record.Phase = 'start-failed'; $record.Result = "Maintenance mode did not start ($cause); block restored." }
        else { $record.Phase = 'restore-failed'; $record.Result = 'Not back in place: ' + ($r.Failed -join ', ') }
        $record.Ended = (& $Machine.Now).ToString('o')
        try { [void](Set-AVDTuneState -Root $Root -Values @{ Maintenance = $record; UpdateBlock = $(if ($ok) { (Get-AVDTuneUpdateBlockStatus $Machine).State } else { 'Maintenance' }); LastChange = $record.Ended }) } catch { }
        if ($ok) { throw "The maintenance mode did not start: $cause The update block was put back." }
        throw "The maintenance mode did not start: $cause The update block is not fully back ($($r.Failed -join ', ')). Repair it on the Update block page."
    }
    [pscustomobject]@{ Id = $id; BlockBefore = $before; Lift = @($lift); LiftFailed = $failed.Count; User = $User; SnapshotId = $SnapshotId }
}

function Restore-AVDTuneBlockSettings {
    # Apply of the listed ids; returns @{ Failed = ids that are not in place afterwards; Restored = count }
    param($Machine, [string[]]$Ids)
    $failed = New-Object System.Collections.ArrayList; $restored = 0
    foreach ($entry in Get-AVDTuneUpdateBlockCatalog) {
        if ($entry.Id -notin $Ids) { continue }
        $r = Invoke-AVDTuneStep -Step $entry.Step -Machine $Machine -Mode Apply
        if ($r.Status -eq 'Changed') { $restored++ }
        if ($r.Status -eq 'Failed') { [void]$failed.Add($entry.Id) }
    }
    # whatever the steps say: the live status decides
    $live = Get-AVDTuneUpdateBlockStatus $Machine
    foreach ($i in $live.Items) { if ($i.Id -in $Ids -and -not $i.Compliant -and $i.Id -notin $failed) { [void]$failed.Add($i.Id) } }
    @{ Failed = @($failed); Restored = $restored }
}

function Stop-AVDTuneMaintenance {
    <#
        Sets the block back to what it was before (BlockBefore) and writes the after state. When something is not back, the record stays Active
        (Phase restore-failed), so the next start finds it. Always writes a change log entry.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Context)
    $record = Get-AVDTuneMaintenanceRecord $Root
    $r = Restore-AVDTuneBlockSettings -Machine $Machine -Ids @($Context.BlockBefore)
    $live = Get-AVDTuneUpdateBlockStatus $Machine
    $ok = ($r.Failed.Count -eq 0)
    $record.BlockAfter = @($live.Items | Where-Object { $_.Applicable -and $_.Compliant } | ForEach-Object { $_.Id })
    $record.Ended = (& $Machine.Now).ToString('o')
    if ($ok) { $record.Active = $false; $record.Phase = 'restored'; $record.Result = "Block restored: $($r.Restored) setting(s) set back." }
    else { $record.Phase = 'restore-failed'; $record.Result = 'Not back in place: ' + ($r.Failed -join ', ') }
    $values = @{ Maintenance = $record; UpdateBlock = $(if ($ok) { $live.State } else { 'Maintenance' }) }
    if ($r.Restored -gt 0 -or $r.Failed.Count -gt 0) { $values.LastChange = (& $Machine.Now).ToString('o') }   # LastChange for the snapshot gate
    [void](Set-AVDTuneState -Root $Root -Values $values)
    $state = Get-AVDTuneState $Root
    if ($state.ImageVersion) {
        $text = if ($ok) { "Maintenance mode ended: update block restored ($($r.Restored) setting(s) set back, state $($live.State))" } else { "Maintenance mode ended but the update block is NOT fully back ($($r.Failed.Count) setting(s)): repair it on the Update block page" }
        [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'Update block' -Component 'Maintenance mode' -ChangeType Changed -Text $text -User ([string]$Context.User) -SnapshotId ([string]$Context.SnapshotId) -Source Step)
    }
    [pscustomobject]@{ Restored = $ok; Count = $r.Restored; Failed = @($r.Failed); State = $live.State }
}

function Invoke-AVDTuneMaintenance {
    <#
        Runs $Script($Context) with the block lifted and sets it back in the finally block, whatever the script did. Returns
        @{ Output; Restore }. An error of the script is thrown again after the restore; a failed restore is thrown as well.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][scriptblock]$Script, [string]$User, [string]$SnapshotId)
    $ctx = Start-AVDTuneMaintenance -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId
    $output = $null; $restore = $null
    try { $output = & $Script $ctx }
    finally { $restore = Stop-AVDTuneMaintenance -Machine $Machine -Root $Root -Context $ctx }
    if (-not $restore.Restored) { throw "The update block is not fully back after the maintenance mode ($($restore.Failed -join ', ')). Repair it on the Update block page." }
    [pscustomobject]@{ Output = $output; Restore = $restore; Context = $ctx }
}

function Repair-AVDTuneMaintenanceCrash {
    <#
        An earlier maintenance mode never ended: puts back what was on before (BlockBefore of the record), closes the record and writes the change
        log entry with the hint. Needs the open write gate.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot), [string]$User)
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot of today is confirmed on the Overview.' }
    $record = Get-AVDTuneMaintenanceCrash -Root $Root
    if (-not $record) { return [pscustomobject]@{ Repaired = $false; Count = 0; Failed = @(); State = (Get-AVDTuneUpdateBlockStatus $Machine).State; Message = 'No interrupted maintenance mode.' } }
    $r = Restore-AVDTuneBlockSettings -Machine $Machine -Ids @($record.BlockBefore)
    $live = Get-AVDTuneUpdateBlockStatus $Machine
    $ok = ($r.Failed.Count -eq 0)
    $record.BlockAfter = @($live.Items | Where-Object { $_.Applicable -and $_.Compliant } | ForEach-Object { $_.Id })
    $record.Ended = (& $Machine.Now).ToString('o')
    if ($ok) { $record.Active = $false; $record.Phase = 'repaired'; $record.Result = "Interrupted maintenance mode repaired: $($r.Restored) setting(s) set back." }
    else { $record.Phase = 'repair-failed'; $record.Result = 'Not back in place: ' + ($r.Failed -join ', ') }
    $values = @{ Maintenance = $record; UpdateBlock = $(if ($ok) { $live.State } else { 'Maintenance' }) }
    if ($r.Restored -gt 0 -or $r.Failed.Count -gt 0) { $values.LastChange = (& $Machine.Now).ToString('o') }   # LastChange for the snapshot gate
    [void](Set-AVDTuneState -Root $Root -Values $values)
    $state = Get-AVDTuneState $Root
    $message = "The maintenance mode of $($record.Started) (by $($record.User)) did not end properly: AVDTune was closed or stopped in the middle. " + $(if ($ok) { "The update block was repaired ($($r.Restored) setting(s) set back)." } else { 'The update block could NOT be repaired completely: ' + ($r.Failed -join ', ') })
    if ($state.ImageVersion) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'Update block' -Component 'Maintenance mode' -ChangeType Changed -Text $message -User $User -Source Step) }
    [pscustomobject]@{ Repaired = $ok; Count = $r.Restored; Failed = @($r.Failed); State = $live.State; Message = $message }
}

#endregion

Export-ModuleMember -Function Get-AVDTuneUpdateBlockCatalog, Get-AVDTuneUpdateBlockStatus, Set-AVDTuneUpdateBlock, Get-AVDTuneMaintenanceCrash, Start-AVDTuneMaintenance,
    Stop-AVDTuneMaintenance, Invoke-AVDTuneMaintenance, Repair-AVDTuneMaintenanceCrash
