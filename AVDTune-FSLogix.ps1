# The FSLogix page (dot-sourced by Start-AVDTune.ps1). Logic is in Modules\AVDTune.FSLogix.psm1 and AVDTune.Storage.psm1; this file builds the form, starts the long
# work (install, function test, storage check) in a background runspace and polls it with the window timer. Settings, groups, redirections.xml and the Defender
# exclusions are quick and run on the UI thread. Everything that changes the master is behind the write gate (snapshot confirmed).
# Test mode: the fake machine, the fake FSLogix adapter and the fake Azure, file share and LDAP services run inline on the UI thread (their closures belong to this
# runspace); no network, no tenant, no share, no Defender of this computer.
# The Azure storage token is the Storage audience of the sign-in (issue 18, optional: a registration without its consent signs in without it): without it the ACL rows say why.

$script:FslFake = $null
if ($script:TestMode) {
    . (Get-TestScript 'FakeFSLogix.ps1'); . (Get-TestScript 'FakeStorage.ps1')
    $script:FslFake = @{ F = (New-AVDTuneFakeFSLogix); Arm = (New-AVDTuneFakeStorageArm); Files = (New-AVDTuneFakeFiles); Ldap = (New-AVDTuneFakeStorageLdap) }
}
$script:FslJob = $null
$script:FslInputs = @{}
$script:FslDefOff = @{}   # Defender exclusions the administrator switched off (lower case value), kept while the list is drawn again
$script:FslTest = $null
$script:FslStorage = $null
$script:FslTemplateBoxes = @{}
$script:FslLatest = $null
$script:FslStopping = @()   # lookups that BeginStop was called for, disposed when they have stopped
$script:FslLatestLookup = $null   # the running read-only lookup of the newest release (issue 63)
$script:FslLatestResult = $null   # @{ Result (Get-AVDTuneFSLogixLatest); At }: cached, 60 minutes when it worked, 5 minutes when it did not
$script:FslSharedGate = $null

function Get-FslAdapter { if ($script:TestMode) { $script:FslFake.F } else { if (-not $script:RealFsl) { $script:RealFsl = New-AVDTuneFSLogixAdapter }; $script:RealFsl } }
function Get-FslAnswers { $e = $null; try { $e = Get-AVDTuneEnvironment $script:StateRoot } catch { }; if ($e) { Get-AVDTuneEnvironmentAnswers $e } else { $null } }
function Test-FslApplies { $a = Get-FslAnswers; [bool]($a -and [string](Get-AVDTuneProp $a 'Profiles') -ne 'None') }
function Get-FslUser { [string]$env:USERNAME }
function Format-FslValue($v) { if ($null -eq $v) { '' } else { (@($v) | ForEach-Object { [string]$_ }) -join '; ' } }
function Test-FslBusy { [bool]$script:FslJob }
function Assert-FslWrite { if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot of today on the Overview first.' } }
function Get-FslGateSnapshot { $g = Get-AVDTuneWriteGate; if ($g) { [string]$g.SnapshotId } else { '' } }

function Set-FslPill($Border, $Text, [string]$Status) {
    $pair = $script:ReadyPill[$Status]
    Set-Brush $Border ([System.Windows.Controls.Border]::BackgroundProperty) $pair[0]
    Set-Brush $Text ([System.Windows.Controls.TextBlock]::ForegroundProperty) $pair[1]
}
function New-FslPillBlock([string]$Status, [string]$Label, [int]$Width = 0) {
    $pair = $script:ReadyPill[$Status]
    $pill = New-Object System.Windows.Controls.Border
    Set-Brush $pill ([System.Windows.Controls.Border]::StyleProperty) 'Pill'; $pill.Padding = '10,2'; $pill.VerticalAlignment = 'Center'; $pill.HorizontalAlignment = 'Left'
    Set-Brush $pill ([System.Windows.Controls.Border]::BackgroundProperty) $pair[0]
    $pt = New-Object System.Windows.Controls.TextBlock; $pt.Text = $(if ($Label) { $Label } else { $pair[2] }); $pt.FontSize = 12; $pt.FontWeight = 'SemiBold'
    Set-Brush $pt ([System.Windows.Controls.TextBlock]::ForegroundProperty) $pair[1]
    $pill.Child = $pt
    $pill
}
function New-FslResultRow($Row) {
    # A row of the function test or the storage check: pill, title, reason and the fix; the tooltip names the Learn source and whether Learn states it
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '0,5,0,5'
    foreach ($w in 120, 250, '*') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$grid.ColumnDefinitions.Add($c) }
    $pill = New-FslPillBlock ([string]$Row.Status) ''
    $title = New-Object System.Windows.Controls.TextBlock; $title.Text = [string]$Row.Title; $title.TextWrapping = 'Wrap'; $title.FontWeight = 'SemiBold'; $title.VerticalAlignment = 'Center'; $title.Margin = '0,0,10,0'; $title.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
    $text = [string]$Row.Reason + $(if ($Row.Fix -and $Row.Status -notin 'green', 'info') { "`r`nFix: $($Row.Fix)" } else { '' })
    $reason = New-Object System.Windows.Controls.TextBlock; $reason.Text = $text; $reason.TextWrapping = 'Wrap'; $reason.VerticalAlignment = 'Center'; $reason.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2)
    Set-Brush $reason ([System.Windows.Controls.TextBlock]::ForegroundProperty) $(if ($Row.Status -in 'red') { 'Danger' } else { 'MutedText' })
    $tip = "Source: $($Row.Source)`r`nStated on Microsoft Learn: $(if ($Row.Verified) { 'yes' } else { 'no' })$(if ($Row.Note) { "`r`n" + $Row.Note })"
    foreach ($e in $pill, $title, $reason) { $e.ToolTip = $tip; [void]$grid.Children.Add($e) }
    $grid
}

# ---------------------------------------------------------------- the form: installation
function Start-FslLatestLookup {
    # Reads the newest release (HEAD on the Microsoft link, no download, 15 s limit) with the same function as the Updates page, in the background; cached.
    if ($script:FslLatestLookup) { return }
    $r = $script:FslLatestResult
    if ($r -and ((Get-Date) - $r.At).TotalMinutes -lt $(if ($r.Result.Ok) { 60 } else { 5 })) { return }
    if ($script:TestMode) { $script:FslLatestResult = @{ Result = (Get-AVDTuneFSLogixLatest -F $script:FslFake.F); At = (Get-Date) }; return }
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param($AppRoot)
            $ErrorActionPreference = 'Stop'
            Import-Module (Join-Path $AppRoot 'Modules\AVDTune.psm1') -Force
            Import-Module (Join-Path $AppRoot 'Modules\AVDTune.FSLogix.psm1') -Force
            Get-AVDTuneFSLogixLatest -F (New-AVDTuneFSLogixAdapter)
        }).AddArgument($script:AppRoot)
    $script:FslLatestLookup = @{ PS = $ps; Handle = $ps.BeginInvoke(); Started = (Get-Date) }
}
function Stop-FslLookupAsync($Job) {
    # never Stop() on the window thread (it waits for the runspace): BeginStop, and the tick that follows disposes it when it has stopped (the UI never blocks)
    try { $script:FslStopping += @(@{ PS = $Job.PS; Handle = $Job.PS.BeginStop($null, $null) }) } catch { try { $Job.PS.Dispose() } catch { } }
}
function Clear-FslStopped {
    $keep = @()
    foreach ($j in @($script:FslStopping)) {
        if (-not $j) { continue }
        if ($j.Handle.IsCompleted) { try { $j.PS.EndStop($j.Handle) } catch { }; try { $j.PS.Dispose() } catch { } } else { $keep += $j }
    }
    $script:FslStopping = @($keep)
}
function Close-FslLatestLookup {
    # the window is closing: a lookup that still runs is stopped without waiting (the process ends right after); its runspace is discarded
    $job = $script:FslLatestLookup; $script:FslLatestLookup = $null
    if ($job) { try { [void]$job.PS.BeginStop($null, $null) } catch { } }
    foreach ($j in @($script:FslStopping)) { if ($j) { try { $j.PS.Dispose() } catch { } } }
    $script:FslStopping = @()
}
function Complete-FslLatestLookup {
    Clear-FslStopped
    $job = $script:FslLatestLookup
    if (-not $job) { return }
    $late = ((Get-Date) - $job.Started).TotalSeconds -gt 45
    if (-not $job.Handle.IsCompleted -and -not $late) { return }
    $script:FslLatestLookup = $null
    $res = $null
    if ($job.Handle.IsCompleted) {
        try { $res = @($job.PS.EndInvoke($job.Handle)) | Select-Object -Last 1; if ($job.PS.Streams.Error.Count -gt 0) { $res = [pscustomobject]@{ Ok = $false; Error = $job.PS.Streams.Error[0].Exception.Message } } }
        catch { $res = [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message } }
        finally { $job.PS.Dispose() }
    }
    else { Stop-FslLookupAsync $job; $res = [pscustomobject]@{ Ok = $false; Error = 'The lookup took longer than 45 seconds.' } }
    if (-not $res) { $res = [pscustomobject]@{ Ok = $false; Error = 'The lookup returned nothing.' } }
    $script:FslLatestResult = @{ Result = $res; At = (Get-Date) }
    if ($script:CurrentPage -eq 'FSLogix') { Update-FslInstall }
}
function Update-FslInstall {
    $info = Get-AVDTuneFSLogixInfo -Machine $script:Machine
    $vs = $null
    if ($info.Installed) {
        Start-FslLatestLookup
        $vs = Get-AVDTuneFSLogixVersionState -Installed $info.Version -Latest $(if ($script:FslLatestResult) { $script:FslLatestResult.Result })
        if ($script:FslLatestLookup -and -not $script:FslLatestResult) { Set-FslPill $ui.PillFslInstall $ui.TxtFslInstallPill 'info'; $ui.TxtFslInstallPill.Text = 'Installed, checking for updates ...' }
        else { Set-FslPill $ui.PillFslInstall $ui.TxtFslInstallPill $vs.Pill; $ui.TxtFslInstallPill.Text = $vs.Text }
        $ui.PillFslInstall.ToolTip = $(if ($vs.Reason) { $vs.Reason } else { $null })
        $svc = if ($info.Frxsvc.Present) { "frxsvc $($info.Frxsvc.Status)" } else { 'frxsvc missing' }
        $drv = if (-not $info.DriversRead) { 'drivers not read' } elseif ($info.Drivers.Count -gt 0) { "drivers: $($info.Drivers -join ', ')" } else { 'no filter driver loaded' }
        $ui.TxtFslVersion.Text = "FSLogix $($info.Version); $svc; $drv"
    }
    else { Set-FslPill $ui.PillFslInstall $ui.TxtFslInstallPill 'red'; $ui.TxtFslInstallPill.Text = 'Not installed'; $ui.TxtFslVersion.Text = 'FSLogix is not installed on this master.' }
    $ui.TxtFslLatest.Text = $(if ($vs -and $vs.State -in 'Update', 'Unknown' -and $vs.Reason -and -not $script:FslLatest) { $vs.Reason } elseif ($script:FslLatest) { $script:FslLatest } else { 'The newest release is looked up when you press Install or update (Microsoft download page; the file is checked for the Microsoft signature before it runs, in a folder only administrators can write to).' })
}

# ---------------------------------------------------------------- the form: settings
function Update-FslSettings {
    $keep = @{}; foreach ($k in $script:FslInputs.Keys) { $e = $script:FslInputs[$k]; if ($e.Box.Text -ne $e.Shown) { $keep[$k] = $e.Box.Text } }   # only what the administrator typed
    $had = $script:FslInputs.Count -gt 0
    $ui.PanelFslSettings.Children.Clear(); $script:FslInputs = @{}
    $state = @(Get-AVDTuneFSLogixSettingsState -Machine $script:Machine)
    $odfcHead = $false
    foreach ($s in $state) {
        if ($s.Scope -eq 'ODFC' -and -not $odfcHead) { $odfcHead = $true; [void]$ui.PanelFslSettings.Children.Add((New-UpdGroupHead 'Office container (ODFC), optional')) }
        elseif ($s.Scope -eq 'Profile' -and $s.Name -eq 'Enabled') { [void]$ui.PanelFslSettings.Children.Add((New-UpdGroupHead 'Profile container')) }
        $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,5,0,5'
        foreach ($w in 220, 240, 140, 90, '*') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
        $name = New-Object System.Windows.Controls.TextBlock; $name.Text = $s.Name; $name.FontWeight = 'SemiBold'; $name.VerticalAlignment = 'Center'
        $box = New-Object System.Windows.Controls.TextBox; $box.Padding = '6,4'; $box.Margin = '0,0,10,0'; $box.VerticalAlignment = 'Center'; $box.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
        $shown = Format-FslValue $s.Current
        $key = "$($s.Scope):$($s.Name)"
        $box.Text = $(if ($keep.ContainsKey($key)) { $keep[$key] } else { $shown })
        [System.Windows.Automation.AutomationProperties]::SetName($box, "$($s.Scope) setting $($s.Name)")
        $rec = New-Object System.Windows.Controls.TextBlock; $rec.Text = $(if ($null -ne $s.Recommended) { "recommended $($s.Recommended)" } else { '' }); $rec.VerticalAlignment = 'Center'; $rec.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2)
        Set-Brush $rec ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
        $pillStatus = switch ($s.Status) { 'ok' { 'green' } 'differs' { 'yellow' } default { 'info' } }
        $pill = New-FslPillBlock $pillStatus $(switch ($s.Status) { 'ok' { 'Set' } 'differs' { 'Differs' } default { 'Not set' } }); $pill.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 3)
        $why = New-Object System.Windows.Controls.TextBlock; $why.Text = $s.Explain + $(if (-not $s.Verified -and $s.Note) { " (Learn: $($s.Note))" }); $why.TextWrapping = 'Wrap'; $why.FontSize = 12; $why.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 4)
        Set-Brush $why ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
        $tip = "Source: $($s.Source)`r`nA recommendation stated on Microsoft Learn: $(if ($s.Verified) { 'yes' } else { 'no' })$(if ($s.Note) { "`r`n" + $s.Note })"
        foreach ($e in $name, $box, $rec, $pill, $why) { $e.ToolTip = $tip; [void]$g.Children.Add($e) }
        [void]$ui.PanelFslSettings.Children.Add($g)
        $script:FslInputs[$key] = @{ Box = $box; Scope = $s.Scope; Name = $s.Name; Type = $s.Type; Shown = $shown; Recommended = $s.Recommended }
    }
    $lc = Get-AVDTuneFSLogixLastChange -Root $script:StateRoot
    $ui.TxtFslSettingsState.Text = if ($lc) { "LastChange: $(([datetime]$lc.At).ToString('yyyy-MM-dd HH:mm')) by $($lc.User) ($($lc.Plan))." } else { 'No FSLogix change recorded yet.' }
}
function Get-FslFormValues {
    $vals = @{}
    foreach ($k in @($script:FslInputs.Keys)) {
        $e = $script:FslInputs[$k]; $text = $e.Box.Text.Trim()
        if (-not $text -or $text -eq $e.Shown) { continue }
        $vals[$k] = if ($e.Type -eq 'MultiString') { @($text -split '[;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { $text }
    }
    $vals
}
function Invoke-FslChange {
    # A change of the master that runs on the window thread (registry, redirections.xml, Defender, ACL): the task shows in the bar first, then the call blocks the thread.
    # The task ends as failed when the call throws or a step of the run failed. No Retry: every one of these changes the master or the share and starts from its own confirmation.
    param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Step, [Parameter(Mandatory)][scriptblock]$Block)
    $fslTask = Start-AVDTuneUiTask -Kind $Kind -Title $Title -Step $Step
    try { Update-TaskBar; $window.Dispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Render) } catch { }
    $fslOut = $null
    try { $fslOut = & $Block }
    catch { Complete-AVDTuneUiTask $fslTask -Failed -Summary $_.Exception.Message; throw }
    $fslResults = @(); if ($fslOut -and $fslOut.PSObject.Properties['Results']) { $fslResults = @($fslOut.Results | Where-Object { $_ }) }
    $fslFailed = @($fslResults | Where-Object { $_.Status -eq 'Failed' })
    if ($fslOut -and -not $fslOut.PSObject.Properties['Results'] -and $fslOut.PSObject.Properties['Status'] -and $fslOut.Status -eq 'Failed') { Complete-AVDTuneUiTask $fslTask -Failed -Summary ([string]$fslOut.Message) }
    elseif ($fslFailed.Count -gt 0) { Complete-AVDTuneUiTask $fslTask -Failed -Summary "$($fslFailed.Count) step(s) failed: $($fslFailed[0].Message)" }
    else { Complete-AVDTuneUiTask $fslTask -Summary "$(@($fslResults | Where-Object { $_.Status -eq 'Changed' }).Count) changed" }
    $fslOut
}
function Show-FslRun($Run, [string]$What) {
    foreach ($r in @($Run.Results)) { Register-StepResult $r }
    $changed = @($Run.Results | Where-Object { $_.Status -eq 'Changed' }).Count; $failed = @($Run.Results | Where-Object { $_.Status -eq 'Failed' })
    $text = "${What}: $changed changed$(if ($failed.Count -gt 0) { ", $($failed.Count) failed ($($failed[0].Message))" })."
    Show-Toast $text
    $ui.TxtFslState.Text = $text
    Start-OverviewRefresh
}
Add-Click $ui.BtnFslFill {
    foreach ($e in $script:FslInputs.Values) { if ($e.Scope -eq 'Profile' -and $null -ne $e.Recommended) { $e.Box.Text = [string]$e.Recommended } }
    $ui.TxtFslSettingsState.Text = 'Microsoft''s recommended values are filled in (VHDLocations is yours). Press Test to see what would change.'
}
Add-Click $ui.BtnFslSettingsTest {
    $vals = Get-FslFormValues
    if ($vals.Count -eq 0) { $ui.TxtFslSettingsState.Text = 'Nothing to change: every filled value equals the current one.'; return }
    $run = Set-AVDTuneFSLogixSettings -Machine $script:Machine -Root $script:StateRoot -Values $vals -WhatIf
    $lines = @($run.Results | ForEach-Object { "$($_.Id -replace '^fslogix\.', ''): $($_.Status)$(if ($_.Status -eq 'WhatIf') { " (now $(Format-FslValue $_.Before))" })" })
    $ui.TxtFslSettingsState.Text = "Test (nothing written): " + ($lines -join '; ')
}
Add-Click $ui.BtnFslSettingsApply {
    Assert-FslWrite
    $vals = Get-FslFormValues
    if ($vals.Count -eq 0) { throw 'Nothing to change: every filled value equals the current one.' }
    # the same Apply also sets the recommended lists: what it would change there is worked out first and named in this one confirmation (nothing is said when the lists stay as they are)
    $listPlan = Get-AVDTuneFSLogixListPlan -F (Get-FslAdapter) -Root $script:StateRoot -Answers (Get-FslAnswers)
    $listText = Format-AVDTuneFSLogixListChanges $listPlan
    $askText = "Write $($vals.Count) FSLogix setting(s) to the registry of this master?$(if ($listText) { " Also: $listText.$(if ($listPlan.Notice) { ' ' + $listPlan.Notice })" })"
    if (-not (Confirm-Action $askText 'FSLogix settings')) { return }
    $run = Invoke-FslChange -Kind 'fslogix-settings' -Title 'Applying FSLogix settings' -Step "Writing $($vals.Count) setting(s) to the registry" -Block { Set-AVDTuneFSLogixSettings -Machine $script:Machine -Root $script:StateRoot -Values $vals -User (Get-FslUser) -SnapshotId (Get-FslGateSnapshot) }
    Show-FslRun $run 'FSLogix settings'
    if (@($run.Results | Where-Object { $_.Status -eq 'Failed' }).Count -eq 0) { Invoke-FslRecommendedLists -Confirmed }
    Update-FslView
}
Add-Click $ui.BtnFslSettingsUndo {
    Assert-FslWrite
    if (-not (Confirm-Action 'Put back the FSLogix settings that were found before the last change?' 'Undo')) { return }
    $run = Undo-AVDTuneFSLogixSettings -Machine $script:Machine -Root $script:StateRoot -User (Get-FslUser) -SnapshotId (Get-FslGateSnapshot)
    Show-FslRun $run 'Undo of the FSLogix settings'; Update-FslView
}

# ---------------------------------------------------------------- groups
function Get-FslGroupChoices { Get-AVDTuneFSLogixGroupChoices -Root $script:StateRoot -Answers (Get-FslAnswers) }
function Resolve-FslSid([string]$Text, $Choices) {
    $t = $Text.Trim()
    if (Test-AVDTuneSid $t) { return $t }
    $hit = @($Choices.Groups | Where-Object { $_.Name -ieq $t })
    if ($hit.Count -gt 0) { return [string]$hit[0].Sid }
    $null
}
function Update-FslGroups {
    $g = Get-AVDTuneFSLogixGroups -F (Get-FslAdapter)
    $fmt = { param($l) if ($null -eq $l) { 'the group does not exist' } elseif (@($l).Count -eq 0) { '(empty)' } else { @($l) -join ', ' } }
    $ui.TxtFslGroups.Text = "Include list ($($g.IncludeName)):`r`n  $(& $fmt $g.Include)`r`nExclude list ($($g.ExcludeName)):`r`n  $(& $fmt $g.Exclude)"
    $ch = Get-FslGroupChoices
    foreach ($cmb in $ui.CmbFslGroup, $ui.CmbFslUsersGroup, $ui.CmbFslAdminsGroup) { $keepText = $cmb.Text; $cmb.ItemsSource = @($ch.Groups | ForEach-Object { $_.Name }); $cmb.Text = $keepText }
    $plan = Get-AVDTuneFSLogixListPlan -F (Get-FslAdapter) -Root $script:StateRoot -Answers (Get-FslAnswers)
    $want = @(foreach ($l in 'Include', 'Exclude') { $x = @($plan.Entries | Where-Object { $_.List -eq $l }); if ($x.Count -gt 0) { "$($l.ToLowerInvariant()) $((@($x | ForEach-Object { $_.Label })) -join ', ')" } }) -join '; '
    $ui.TxtFslListsNotice.Text = "Recommended: $want.$(if ($plan.Notice) { ' ' + $plan.Notice })"
    $ui.TxtFslGroupHint.Text = $(if ($ch.Source -eq 'Directory') { "$(@($ch.Groups).Count) groups from the domain controller. Pick one or type a SID." } else { $ch.Hint })
}
function Invoke-FslGroupChange([string]$Action, [string]$Text) {
    Assert-FslWrite
    $list = [string]$ui.CmbFslList.SelectedItem
    $sid = Resolve-FslSid $Text (Get-FslGroupChoices)
    if (-not $sid) { throw "'$Text' is neither a group of the domain nor a SID (S-1-...)." }
    if (-not (Confirm-Action "$Action $sid in the FSLogix $list list?" 'FSLogix lists')) { return }
    $run = Set-AVDTuneFSLogixGroupMember -Machine $script:Machine -F (Get-FslAdapter) -Root $script:StateRoot -List $list -Action $Action -Sid $sid -User (Get-FslUser) -SnapshotId (Get-FslGateSnapshot)
    Show-FslRun $run "FSLogix $list list"; Update-FslGroups
}
function Invoke-FslRecommendedLists([switch]$Confirmed) {
    # Include = Everyone (only while the list is empty), Exclude = local Administrators (+ Domain Admins of a domain SID that was checked); the settings Apply asks for this in its own
    # confirmation and calls this with -Confirmed. Nothing to change = nothing asked, nothing written.
    $plan = Get-AVDTuneFSLogixListPlan -F (Get-FslAdapter) -Root $script:StateRoot -Answers (Get-FslAnswers)
    $text = Format-AVDTuneFSLogixListChanges $plan
    if (-not $Confirmed) {
        if (-not $text) { $ui.TxtFslState.Text = "The recommended lists are already set.$(if ($plan.Notice) { ' ' + $plan.Notice })"; Show-Toast $ui.TxtFslState.Text; return }
        if (-not (Confirm-Action "Set the recommended lists? $text.$(if ($plan.Notice) { ' ' + $plan.Notice })" 'FSLogix lists')) { return }
    }
    elseif (-not $text) { return }
    $run = Invoke-FslChange -Kind 'fslogix-lists' -Title 'Applying the recommended FSLogix lists' -Step 'Setting the include and exclude lists' -Block { Set-AVDTuneFSLogixRecommendedLists -Machine $script:Machine -F (Get-FslAdapter) -Root $script:StateRoot -Answers (Get-FslAnswers) -User (Get-FslUser) -SnapshotId (Get-FslGateSnapshot) }
    Show-FslRun $run 'FSLogix lists'
    if ($run.Notice) { $ui.TxtFslState.Text = "$($ui.TxtFslState.Text) $($run.Notice)" }
    Update-FslGroups
}
Add-Click $ui.BtnFslListsApply { Assert-FslWrite; Invoke-FslRecommendedLists }
Add-Click $ui.BtnFslListsUndo {
    Assert-FslWrite
    if (-not (Confirm-Action 'Remove the members that the last Apply recommended lists added? Entries that were there before stay.' 'Undo')) { return }
    $run = Invoke-FslChange -Kind 'fslogix-lists' -Title 'Undo of the recommended FSLogix lists' -Step 'Removing the members that were added' -Block { Undo-AVDTuneFSLogixRecommendedLists -Machine $script:Machine -F (Get-FslAdapter) -Root $script:StateRoot -User (Get-FslUser) -SnapshotId (Get-FslGateSnapshot) }
    Show-FslRun $run 'Undo of the FSLogix lists'
    if ($run.Notice) { $ui.TxtFslState.Text = "$($ui.TxtFslState.Text) $($run.Notice)"; Show-Toast $ui.TxtFslState.Text }
    Update-FslGroups
}
$ui.CmbFslList.ItemsSource = @('Exclude', 'Include'); $ui.CmbFslList.SelectedIndex = 0
Add-Click $ui.BtnFslGroupAdd { Invoke-FslGroupChange 'Add' ([string]$ui.CmbFslGroup.Text) }
Add-Click $ui.BtnFslGroupRemove { Invoke-FslGroupChange 'Remove' ([string]$ui.CmbFslGroup.Text) }
Add-Click $ui.BtnFslExcludeAdmins { $ui.CmbFslList.SelectedItem = 'Exclude'; Invoke-FslGroupChange 'Add' 'S-1-5-32-544' }

# ---------------------------------------------------------------- redirections.xml
function Build-FslTemplate {
    $ui.PanelFslTemplate.Children.Clear(); $script:FslTemplateBoxes = @{}
    foreach ($t in (Get-AVDTuneRedirectionTemplate)) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($t.Group): $(@($t.Paths).Count) folder(s)" + $(if (-not $t.Verified) { ' (usual cache folders, not on Microsoft Learn)' } else { ' (Microsoft Learn)' })
        $cb.IsChecked = [bool]$t.Verified; $cb.Margin = '0,2,0,2'; $cb.ToolTip = "$($t.Note)`r`n$(@($t.Paths) -join "`r`n")"
        [System.Windows.Automation.AutomationProperties]::SetName($cb, "Template group $($t.Group)")
        [void]$ui.PanelFslTemplate.Children.Add($cb)
        $script:FslTemplateBoxes[$t.Group] = $cb
    }
}
function Update-FslRedirections {
    # prefilled: the folder set in the registry, otherwise <ProgramData>\FSLogix\Redirections; only the groups are left to pick (the folder is created protected on save)
    if (-not $ui.TxtFslRedirFolder.IsKeyboardFocused -and -not $ui.TxtFslRedirFolder.Text) { $ui.TxtFslRedirFolder.Text = Get-AVDTuneRedirectionsDefaultFolder $script:Machine }
    if (-not $ui.TxtFslRedirXml.Text) {
        $target = Get-AVDTuneRedirectionsTarget $script:Machine
        if ($target) { $text = & (Get-FslAdapter).ReadText $target; if ($null -ne $text) { $ui.TxtFslRedirXml.Text = $text; $ui.TxtFslRedirState.Text = "Read from $target." } }
    }
}
Add-Click $ui.BtnFslRedirGenerate {
    $paths = @(foreach ($t in (Get-AVDTuneRedirectionTemplate)) { if ($script:FslTemplateBoxes[$t.Group].IsChecked) { $t.Paths } })
    if ($paths.Count -eq 0) { throw 'Tick at least one template group.' }
    $ui.TxtFslRedirXml.Text = New-AVDTuneRedirectionsXml -Excludes $paths -ExcludeCommonFolders 0
    $ui.TxtFslRedirState.Text = "Generated: $($paths.Count) exclude(s), Copy 0 (empty local folder, nothing copied)."
}
Add-Click $ui.BtnFslRedirValidate {
    $v = Test-AVDTuneRedirectionsXml $ui.TxtFslRedirXml.Text
    $ui.TxtFslRedirState.Text = if ($v.Ok) { "Valid: $($v.Excludes.Count) excludes, $($v.Includes.Count) includes, ExcludeCommonFolders $($v.ExcludeCommonFolders)." } else { 'Not valid: ' + ($v.Problems -join ' ') }
}
Add-Click $ui.BtnFslRedirSave {
    Assert-FslWrite
    $folder = $ui.TxtFslRedirFolder.Text.Trim()
    if (-not $folder) { throw 'Enter the folder (RedirXMLSourceFolder), a share or a local folder. Users need read access to it.' }
    if (-not (Confirm-Action "Write redirections.xml to $folder and set RedirXMLSourceFolder?" 'redirections.xml')) { return }
    $redirXml = $ui.TxtFslRedirXml.Text
    $run = Invoke-FslChange -Kind 'fslogix-redirections' -Title 'Writing redirections.xml' -Step 'Checking the text and writing the file to the folder' -Block { Save-AVDTuneRedirections -Machine $script:Machine -F (Get-FslAdapter) -Root $script:StateRoot -Xml $redirXml -Folder $folder -User (Get-FslUser) -SnapshotId (Get-FslGateSnapshot) }
    Show-FslRun $run 'redirections.xml'; $ui.TxtFslRedirState.Text = $ui.TxtFslState.Text; Update-FslView
}
Add-Click $ui.BtnFslRedirUndo {
    Assert-FslWrite
    if (-not (Confirm-Action 'Put back the redirections.xml that was there before the last save?' 'Undo')) { return }
    $run = Undo-AVDTuneRedirections -Machine $script:Machine -F (Get-FslAdapter) -Root $script:StateRoot -User (Get-FslUser) -SnapshotId (Get-FslGateSnapshot)
    Show-FslRun $run 'Undo of redirections.xml'
}

# ---------------------------------------------------------------- Defender
function Update-FslDefender {
    $ui.PanelFslDefender.Children.Clear()
    $s = Get-AVDTuneFSLogixDefenderState -F (Get-FslAdapter) -VhdLocations @(Get-AVDTuneFSLogixLocations -Machine $script:Machine)
    if (-not $s.Readable) { $ui.TxtFslDefState.Text = 'The Defender exclusions cannot be read here (another antivirus, or a policy hides them). Check them by hand against Microsoft''s list.'; return }
    $open = @($s.Items | Where-Object { -not $_.Present }).Count
    $ui.TxtFslDefState.Text = "$(@($s.Items).Count - $open) of $(@($s.Items).Count) exclusions are set.$(if (@($s.NotDefender).Count -gt 0) { ' Not Defender types (other tools): ' + ((@($s.NotDefender) | ForEach-Object { $_.Value }) -join '; ') + '.' })"
    foreach ($i in $s.Items) {
        $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,2,0,2'
        foreach ($w in 30, 100, 80, '*') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
        # one checkbox per exclusion (default on): what is switched off is not set and not in the undo list. A set exclusion cannot be switched off here (Undo removes the ones AVDTune added).
        $chk = New-Object System.Windows.Controls.CheckBox; $chk.VerticalAlignment = 'Center'; $chk.Tag = [string]$i.Value
        $chk.IsChecked = (-not $i.Present -and -not $script:FslDefOff.ContainsKey(([string]$i.Value).ToLowerInvariant())) -or [bool]$i.Present; $chk.IsEnabled = -not $i.Present
        [System.Windows.Automation.AutomationProperties]::SetName($chk, "Set this exclusion: $($i.Value)")
        $chk.Add_Checked({ param($src, $e) try { $script:FslDefOff.Remove(([string]$src.Tag).ToLowerInvariant()) } catch { } })
        $chk.Add_Unchecked({ param($src, $e) try { $script:FslDefOff[([string]$src.Tag).ToLowerInvariant()] = $true } catch { } })
        $pill = New-FslPillBlock $(if ($i.Present) { 'green' } else { 'yellow' }) $(if ($i.Present) { 'Set' } else { 'Missing' })
        $pill.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
        $kind = New-Object System.Windows.Controls.TextBlock; $kind.Text = $i.Kind; $kind.VerticalAlignment = 'Center'; $kind.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2); Set-Brush $kind ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
        $val = New-Object System.Windows.Controls.TextBlock; $val.Text = $i.Value + $(if ($i.Risk) { "   [risk: $($i.Risk)]" }); $val.FontFamily = 'Cascadia Mono, Consolas'; $val.FontSize = 12; $val.TextWrapping = 'Wrap'; $val.VerticalAlignment = 'Center'; $val.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 3)
        [void]$g.Children.Add($chk)
        foreach ($e in $pill, $kind, $val) { $e.ToolTip = "$($i.Reason)`r`nSource: $($i.Source)`r`nStated on Microsoft Learn: $(if ($i.Verified) { 'yes' } else { 'no' })$(if ($i.Note) { "`r`n" + $i.Note })"; [void]$g.Children.Add($e) }
        [void]$ui.PanelFslDefender.Children.Add($g)
    }
}
Add-Click $ui.BtnFslDefAdd {
    Assert-FslWrite
    $off = @($script:FslDefOff.Keys)
    if (-not (Confirm-Action "Add the checked, missing FSLogix exclusions to Microsoft Defender Antivirus on this master? Some are folders that users can write to (marked [risk] in the list): files there are not scanned. Untick an exclusion to leave it out.$(if ($off.Count -gt 0) { " $($off.Count) are unticked and will not be set." })" 'Defender exclusions')) { return }
    $run = Invoke-FslChange -Kind 'fslogix-defender' -Title 'Setting the Defender exclusions' -Step 'Adding the ticked exclusions to Microsoft Defender Antivirus' -Block { Set-AVDTuneFSLogixDefender -Machine $script:Machine -F (Get-FslAdapter) -Root $script:StateRoot -VhdLocations @(Get-AVDTuneFSLogixLocations -Machine $script:Machine) -User (Get-FslUser) -SnapshotId (Get-FslGateSnapshot) -Skip $off }
    Show-FslRun $run 'Defender exclusions'; Update-FslDefender
}
Add-Click $ui.BtnFslDefUndo {
    Assert-FslWrite
    if (-not (Confirm-Action 'Remove the Defender exclusions that AVDTune added?' 'Undo')) { return }
    $run = Undo-AVDTuneFSLogixDefender -Machine $script:Machine -F (Get-FslAdapter) -Root $script:StateRoot -User (Get-FslUser) -SnapshotId (Get-FslGateSnapshot)
    Show-FslRun $run 'Undo of the Defender exclusions'; Update-FslDefender
}

# ---------------------------------------------------------------- results: function test and storage check
function Update-FslTestView {
    $ui.PanelFslTest.Children.Clear()
    $rec = Get-AVDTuneFSLogixTestRecord -Root $script:StateRoot
    $r = $script:FslTest
    if ($r) {
        Set-FslPill $ui.PillFslTest $ui.TxtFslTestPill $r.Overall; $ui.TxtFslTestPill.Text = $script:ReadyPill[$r.Overall][2]
        $ui.TxtFslTestSummary.Text = "$($r.Counts.Red) red, $($r.Counts.Yellow) yellow, $($r.Counts.Green) green$(if ($r.WriteTests) { '; with the write tests on the share' } else { '; without the write tests' }). Run at $(([datetime]$r.At).ToString('HH:mm:ss'))."
        $order = @{ red = 0; yellow = 1; green = 2; info = 3 }
        foreach ($row in ($r.Rows | Sort-Object { $order[[string]$_.Status] }, Step)) { [void]$ui.PanelFslTest.Children.Add((New-FslResultRow $row)) }
    }
    elseif ($rec) { Set-FslPill $ui.PillFslTest $ui.TxtFslTestPill $rec.Overall; $ui.TxtFslTestPill.Text = $script:ReadyPill[[string]$rec.Overall][2]; $ui.TxtFslTestSummary.Text = "Last test $(([datetime]$rec.At).ToString('yyyy-MM-dd HH:mm')) by $($rec.User): $($rec.Red) red, $($rec.Yellow) yellow. Run the test to see the rows." }
    else { Set-FslPill $ui.PillFslTest $ui.TxtFslTestPill 'unknown'; $ui.TxtFslTestPill.Text = 'Not run'; $ui.TxtFslTestSummary.Text = 'The function test has not been run on this master.' }
}
function Update-FslStorageView {
    $ui.PanelFslStorage.Children.Clear()
    $r = $script:FslStorage
    if (-not $r) { $ui.TxtFslStorageSummary.Text = 'The storage check has not been run.'; $ui.BtnFslAclSet.Visibility = 'Collapsed'; $ui.TxtFslAclDiff.Visibility = 'Collapsed'; return }
    $ui.TxtFslStorageSummary.Text = "Account $($r.Account): $($r.Overall) ($($r.Counts.Red) red, $($r.Counts.Yellow) yellow, $($r.Counts.Unknown) not checkable, $($r.Counts.Green) green)$(if ($r.KeyUsed) { '. The account key was used for this run (in memory only).' })"
    $order = @{ red = 0; yellow = 1; unknown = 2; green = 3; info = 4 }
    foreach ($row in ($r.Rows | Sort-Object { $order[[string]$_.Status] }, Step)) { [void]$ui.PanelFslStorage.Children.Add((New-FslResultRow $row)) }
    if ($r.AclDiff) {
        $d = $r.AclDiff
        $ui.TxtFslAclDiff.Text = "On the share root now:`r`n  " + ($d.Found -join "`r`n  ") + "`r`n`r`nMicrosoft's recommendation (Learn, configure storage permissions):`r`n  " + ($d.Expected -join "`r`n  ") + "`r`n`r`nFindings:`r`n  " + (($d.Findings | ForEach-Object { "$($_.Status): $($_.Text)" }) -join "`r`n  ")
        $ui.TxtFslAclDiff.Visibility = 'Visible'; $ui.BtnFslAclSet.Visibility = 'Visible'
    }
    else { $ui.TxtFslAclDiff.Visibility = 'Collapsed'; $ui.BtnFslAclSet.Visibility = 'Collapsed' }
}

# ---------------------------------------------------------------- background work
# One worker for the runspace and for the test mode (inline): a script block made from this text, so it does not belong to the UI runspace.
$script:FslWorkerText = @'
param($Kind, $C)
switch ($Kind) {
    'Install' { Invoke-AVDTuneFSLogixInstallRecorded -Machine $C.Machine -F $C.F -Root $C.Root -User $C.User -SnapshotId $C.SnapshotId -Progress $C.Progress }
    'Test' { Invoke-AVDTuneFSLogixTest -Machine $C.Machine -F $C.F -RunWriteTests:([bool]$C.Write) -UsersSids @($C.UsersSids) -AdminsSids @($C.AdminsSids) }
    'Storage' {
        $p = @{ Machine = $C.Machine; F = $C.F; Locations = @($C.Locations); SubscriptionIds = @($C.SubscriptionIds); UsersSids = @($C.UsersSids); AdminsSids = @($C.AdminsSids); AllowKeyFallback = [bool]$C.AllowKey }
        if ($C.Arm -and $C.ArmToken) { $p.Arm = $C.Arm; $p.ArmToken = $C.ArmToken } else { $p.NoArmReason = [string]$C.NoArmReason }
        if ($C.Files -and $C.StorageToken) { $p.Files = $C.Files; $p.StorageToken = $C.StorageToken } else { $p.NoStorageReason = [string]$C.NoStorageReason }
        if ($C.TestUser) { $p.TestUser = $C.TestUser }
        if ($C.TestPassword) { $p.TestPassword = $C.TestPassword }
        if ($C.Dc) { $p.DomainController = $C.Dc }
        if ($C.CallerOid) { $p.CallerOid = $C.CallerOid }
        $conn = $null; $ldap = $C.Ldap
        try {
            if ($ldap -and $C.FakeLdap) { $conn = [pscustomobject]@{ Open = $true } }
            elseif ($ldap -and $C.Dc -and $C.TestUser -and $C.TestPassword) {
                $r = Connect-AVDTuneDirectory -Ldap $ldap -Server $C.Dc -User $C.TestUser -Password $C.TestPassword -Pins $C.Pins
                if ($r.Status -eq 'Connected') { $conn = $r.Connection }
            }
            if ($conn -and $C.DefaultNc) { $p.Ldap = $ldap; $p.LdapConnection = $conn; $p.DefaultNamingContext = $C.DefaultNc }
            Invoke-AVDTuneStorageCheck @p
        }
        finally { if ($conn -and -not $C.FakeLdap) { Disconnect-AVDTuneDirectory -Ldap $ldap -Connection $conn } }
    }
}
'@

function Set-FslBusy([bool]$Busy) {
    foreach ($b in $ui.BtnFslTest, $ui.BtnFslTestWrite, $ui.BtnFslInstall, $ui.BtnFslStorage, $ui.BtnFslAclSet) { $b.IsEnabled = -not $Busy }
    $window.Cursor = $(if ($Busy -and $script:CurrentPage -eq 'FSLogix') { [System.Windows.Input.Cursors]::AppStarting } else { $null })
}
function Get-FslSids {
    $ch = Get-FslGroupChoices
    $users = @(); $admins = @()
    if ($ui.CmbFslUsersGroup.Text.Trim()) { $s = Resolve-FslSid $ui.CmbFslUsersGroup.Text $ch; if ($s) { $users = @($s) } }
    if ($ui.CmbFslAdminsGroup.Text.Trim()) { $s = Resolve-FslSid $ui.CmbFslAdminsGroup.Text $ch; if ($s) { $admins = @($s) } }
    @{ Users = $users; Admins = $admins }
}
function New-FslTask([string]$Kind, [bool]$Write) {
    # Retry only for what reads (function test without the write tests, storage check): the install, and the write tests that create files on the share, start from their own confirmation
    $title = switch ($Kind) { 'Install' { 'Installing or updating FSLogix' } 'Test' { $(if ($Write) { 'FSLogix function test with write tests' } else { 'FSLogix function test' }) } default { 'FSLogix storage check' } }
    $step = switch ($Kind) { 'Install' { 'Looking up the newest release' } 'Test' { 'Checking the master against Microsoft''s FSLogix requirements' } default { 'Reading the storage account, the share and its settings' } }
    $retry = if ($Kind -eq 'Test' -and -not $Write) { @{ Command = 'Start-FslJob'; Arguments = @('Test', @{ Write = $false }) } } elseif ($Kind -eq 'Storage') { @{ Command = 'Start-FslJob'; Arguments = @('Storage', @{}) } }
    Start-AVDTuneUiTask -Kind "fslogix-$($Kind.ToLower())" -Title $title -Step $step -Retry $retry
}
function Get-FslStorageToken {
    # The Storage audience token for the ACL rows (memory only, goes to the Files adapter of the checked account). Without it the reason says why (not signed in, or the registration was made before issue 18: set up again).
    $s = $script:StartContext.Session
    if (-not $s -or -not $s.Connected) { return @{ Token = ''; Reason = 'no token for Azure Storage (https://storage.azure.com/): not signed in. Sign in on the Overview.' } }
    try { @{ Token = (Get-AVDTuneAccessToken -Session $s -Audience Storage); Reason = '' } } catch { @{ Token = ''; Reason = 'no token for Azure Storage (https://storage.azure.com/): ' + $_.Exception.Message } }
}
function Start-FslJob([string]$Kind, [hashtable]$Arg = @{}) {
    if ($script:FslJob) { throw 'Another FSLogix operation is still running.' }
    $sids = Get-FslSids
    $gate = Get-AVDTuneWriteGate
    $common = @{ Root = $script:StateRoot; User = (Get-FslUser); SnapshotId = $(if ($gate) { [string]$gate.SnapshotId } else { '' }); UsersSids = $sids.Users; AdminsSids = $sids.Admins; Write = [bool]$Arg.Write }
    if ($Kind -eq 'Storage') {
        $sub = @(([string]$ui.TxtFslSubs.Text -split '[,;\s]+') | Where-Object { $_ })
        $vm = Get-AVDTuneVmIdentity -Machine $script:Machine
        if ($vm.Available) { $sub = @($vm.SubscriptionId) + $sub }
        $arm = Get-ReadyToken
        $st = Get-FslStorageToken
        $dir = $null; try { $dir = Read-AVDTuneJson (Join-Path $script:StateRoot 'config\directory.json') } catch { }
        $env = $null; try { $env = Get-AVDTuneEnvironment $script:StateRoot } catch { }
        $common += @{ Locations = @(Get-AVDTuneFSLogixLocations -Machine $script:Machine); SubscriptionIds = $sub; AllowKey = [bool]$ui.ChkFslKey.IsChecked; ArmToken = $arm.Token; NoArmReason = $arm.Reason
            StorageToken = $st.Token; NoStorageReason = $st.Reason
            TestUser = $ui.TxtFslUser.Text.Trim(); TestPassword = $(if ($ui.PwdFslPassword.SecurePassword.Length -gt 0) { $ui.PwdFslPassword.SecurePassword } else { $null }); Dc = $ui.TxtFslDc.Text.Trim()
            Pins = $(if ($env) { Get-AVDTuneDcPins $env } else { @{} }); DefaultNc = $(if ($dir -and (Get-AVDTuneProp $dir 'Directory')) { [string]$dir.Directory.DefaultNamingContext } else { '' }); CallerOid = '' }
        $s = $script:StartContext.Session
        if ($s -and $s.Connected) { try { $common.CallerOid = [string](Get-AVDTuneProp (Get-AVDTuneTokenClaims (Get-AVDTuneAccessToken -Session $s -Audience Arm)) 'oid') } catch { } }
    }
    if ($script:TestMode) {
        $c = $common.Clone(); $c.Machine = $script:Machine; $c.F = $script:FslFake.F; $c.Progress = $null
        if ($Kind -eq 'Storage') { $c.Arm = $script:FslFake.Arm; $c.Files = $script:FslFake.Files; $c.Ldap = $script:FslFake.Ldap; $c.FakeLdap = $true; $c.ArmToken = 'fake-arm-token' }   # the storage token comes from the fake session through Get-FslStorageToken (in $common), like in real use
        $res = $null; $err = ''
        try { $res = & ([scriptblock]::Create($script:FslWorkerText)) $Kind $c } catch { $err = $_.Exception.Message }
        $c.StorageToken = $null; $c.ArmToken = $null; $c.TestPassword = $null
        $script:FslJob = @{ Inline = $true; Result = $res; Err = $err; Kind = $Kind; Write = [bool]$Arg.Write; Task = (New-FslTask $Kind ([bool]$Arg.Write)); Common = $common }
    }
    else {
        $sync = [hashtable]::Synchronized(@{ Text = '' })
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
                param($AppRoot, $Kind, $Common, $Gate, $Sync, $WorkerText)
                $ErrorActionPreference = 'Stop'
                Import-Module (Join-Path $AppRoot 'Modules\AVDTune.psm1') -Force
                foreach ($part in 'Updates', 'Snapshot', 'Directory', 'FSLogix', 'Storage') { Import-Module (Join-Path $AppRoot "Modules\AVDTune.$part.psm1") -Force }
                $c = $Common.Clone(); $c.Machine = New-AVDTuneMachine; $c.F = New-AVDTuneFSLogixAdapter; $c.Progress = { param($t) $Sync.Text = $t }
                if ($Kind -eq 'Storage') { $c.Arm = New-AVDTuneArmAdapter; $c.Files = New-AVDTuneFilesAdapter; $c.Ldap = New-AVDTuneLdapAdapter; $c.FakeLdap = $false }
                if ($Gate) { Open-AVDTuneWriteGate -SnapshotId $Gate.SnapshotId -ConfirmedBy $Gate.ConfirmedBy }
                & ([scriptblock]::Create($WorkerText)) $Kind $c
            }).AddArgument($script:AppRoot).AddArgument($Kind).AddArgument($common).AddArgument($gate).AddArgument($sync).AddArgument($script:FslWorkerText)
        $script:FslJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Kind = $Kind; Sync = $sync; Write = [bool]$Arg.Write; Task = (New-FslTask $Kind ([bool]$Arg.Write)); Common = $common }
    }
    Set-ShutdownBlock $true
    Set-FslBusy $true
}
function Complete-FslJob {
    $job = $script:FslJob
    if (-not $job) { return }
    if (-not $job.Inline -and -not $job.Handle.IsCompleted) { if ($job.Sync.Text) { Update-AVDTuneUiTask $job.Task -Step ([string]$job.Sync.Text); if ($script:CurrentPage -eq 'FSLogix') { $ui.TxtFslState.Text = $job.Sync.Text } }; return }
    $script:FslJob = $null
    Set-ShutdownBlock $false
    $result = $null; $err = ''
    if ($job.Inline) { $result = $job.Result; $err = [string]$job.Err }
    else {
        try {
            $out = @($job.PS.EndInvoke($job.Handle))
            if ($job.PS.Streams.Error.Count -gt 0) { $err = $job.PS.Streams.Error[0].Exception.Message }
            $result = $out | Select-Object -Last 1
        }
        catch { $err = $_.Exception.Message }
        finally { $job.PS.Dispose() }
    }
    # No token or password stays referenced after the run (the hashtable of the job, the copy of the worker was local to it)
    if ($job.Common) { foreach ($k in 'StorageToken', 'ArmToken', 'TestPassword') { if ($job.Common.ContainsKey($k)) { $job.Common[$k] = $null } }; $job.Common = $null }
    Set-FslBusy $false
    if ($job.Kind -eq 'Storage') { $ui.PwdFslPassword.Clear(); $ui.ChkFslKey.IsChecked = $false }   # the password and the key confirmation are for one run, also after an error
    if ($err -or -not $result) { Complete-AVDTuneUiTask $job.Task -Failed -Summary "The $($job.Kind.ToLower()) failed: $err"; $ui.TxtFslState.Text = "The $($job.Kind.ToLower()) failed: $err"; Show-Error $ui.TxtFslState.Text; Update-FslView; return }
    switch ($job.Kind) {
        'Install' {
            Register-StepResult $result.Result
            $ui.TxtFslState.Text = "FSLogix: $($result.Install.Status). $($result.Install.Message)$(if ($result.Result.Reboot) { ' Restart the master before you test.' })"
            Complete-AVDTuneUiTask $job.Task -Failed:([bool]($result.Install.Status -eq 'Failed')) -Summary $ui.TxtFslState.Text
            Show-Toast $ui.TxtFslState.Text
            $script:FslLatest = $result.Install.Message
            Start-OverviewRefresh
        }
        'Test' {
            $script:FslTest = $result
            $rec = Save-AVDTuneFSLogixTestRun -Root $script:StateRoot -Result $result -User (Get-FslUser) -SnapshotId (Get-FslGateSnapshot) -Machine $script:Machine
            [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'fslogix' -Subject 'FSLogix function test' -Note "$($result.Overall): $($result.Counts.Red) red, $($result.Counts.Yellow) yellow, $($result.Counts.Green) green")
            Save-Protocol
            $ui.TxtFslState.Text = "FSLogix function test: $($result.Overall) ($($result.Counts.Red) red, $($result.Counts.Yellow) yellow, $($result.Counts.Green) green)."
            Complete-AVDTuneUiTask $job.Task -Summary $ui.TxtFslState.Text
            Show-Toast $ui.TxtFslState.Text
            if (-not $script:ReadyJob) { Start-ReadyJob 'Manual' '' } else { $script:ReadyQueued = @{ Kind = 'Manual'; FixId = '' } }   # the healthcheck row follows the test
        }
        'Storage' {
            $script:FslStorage = $result
            [void](Save-AVDTuneStorageCheckRun -Root $script:StateRoot -Result $result -User (Get-FslUser) -SnapshotId (Get-FslGateSnapshot))
            [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'fslogix' -Subject 'FSLogix storage check' -Note "$($result.Overall): $($result.Counts.Red) red, $($result.Counts.Yellow) yellow, $($result.Counts.Unknown) not checkable$(if ($result.KeyUsed) { '; the account key was used for this run (in memory only)' })")
            Save-Protocol
            $ui.TxtFslState.Text = "Storage check: $($result.Overall)."
            Complete-AVDTuneUiTask $job.Task -Summary "Storage check: $($result.Overall) ($($result.Counts.Red) red, $($result.Counts.Yellow) yellow, $($result.Counts.Unknown) not checkable)"
            Show-Toast $ui.TxtFslState.Text
            $ui.PwdFslPassword.Clear(); $ui.ChkFslKey.IsChecked = $false   # the confirmation of the key fallback is for one run
        }
    }
    Update-FslView
}
$script:Timer.Add_Tick({ try { Complete-FslJob } catch { Show-Error $_.Exception.Message } })
$script:Timer.Add_Tick({ try { Complete-FslLatestLookup } catch { } })

Add-Click $ui.BtnFslTest { Start-FslJob 'Test' @{ Write = $false }; $ui.TxtFslState.Text = 'Running the function test ...' }
Add-Click $ui.BtnFslTestWrite {
    if (-not (Confirm-Action 'The write tests create a test folder and file and a small test VHDX on the share and delete them again. Run them?' 'Write tests')) { return }
    Start-FslJob 'Test' @{ Write = $true }; $ui.TxtFslState.Text = 'Running the function test with the write tests ...'
}
Add-Click $ui.BtnFslInstall {
    Assert-FslWrite
    if (-not (Confirm-Action 'Download the newest FSLogix from Microsoft, check its signature and install it (or update FSLogix)? A restart follows.' 'FSLogix')) { return }
    Start-FslJob 'Install' @{}; $ui.TxtFslState.Text = 'Looking up the newest release ...'
}
Add-Click $ui.BtnFslStorage {
    if ($ui.ChkFslKey.IsChecked -and -not (Confirm-Action 'The storage account key gives full access to the whole account. It is only used if the role for reading the ACL is missing, kept in memory for this run and removed at the end. The change log says that it was used. Allow it for this run?' 'Account key')) { $ui.ChkFslKey.IsChecked = $false; return }
    Start-FslJob 'Storage' @{}; $ui.TxtFslState.Text = 'Running the storage check ...'
}
Add-Click $ui.BtnFslAclSet {
    $r = $script:FslStorage
    if (-not $r -or -not $r.AclDiff) { throw 'Run the storage check first: it shows the diff.' }
    $sids = Get-FslSids
    if ($sids.Users.Count -eq 0 -or $sids.Admins.Count -eq 0) { throw 'Name the users group and the administrators group.' }
    Assert-FslWrite
    if ($r.KeyUsed) { throw 'The ACL was read with the account key; setting it needs the token path (role Storage File Data Privileged Contributor).' }
    if (-not (Confirm-Action "Set the recommended ACL on the root of the share $($r.AclDiff.Share) of $($r.AclDiff.Account)? The diff above is what changes (the ACL is read again first; if it changed since, nothing is set)." 'NTFS ACL')) { return }
    $d = $r.AclDiff
    $share = [pscustomobject]@{ Account = [string]$d.Account; Share = [string]$d.Share }   # the share the check looked at and the administrator saw, not the first location again
    if (-not $share.Account -or -not $share.Share) { throw 'The diff does not name the share: run the storage check again.' }
    $files = if ($script:TestMode) { $script:FslFake.Files } else { New-AVDTuneFilesAdapter }
    $token = if ($script:TestMode) { 'fake-storage-token' } else { '' }
    if (-not $token) { throw 'Setting the NTFS ACL is not built yet: it comes in its own issue (write gate, confirmed hash of the diff, intent backup on the PUT). Until then the check only reads.' }
    $res = Invoke-FslChange -Kind 'fslogix-acl' -Title 'Setting the NTFS ACL of the share root' -Step 'Reading the ACL again and setting the recommended one' -Block { Set-AVDTuneStorageRootAcl -Files $files -Account $share.Account -Share $share.Share -Token $token -UsersSid $sids.Users[0] -AdminsSid $sids.Admins[0] -ConfirmedHash $d.Hash -Root $script:StateRoot -User (Get-FslUser) -SnapshotId (Get-FslGateSnapshot) }
    $ui.TxtFslState.Text = "NTFS ACL: $($res.Status). $($res.Message)"; Show-Toast $ui.TxtFslState.Text
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'fslogix' -Subject 'NTFS ACL of the share root' -Note "$($res.Status). $($res.Message)"); Save-Protocol
}

# ---------------------------------------------------------------- the page
function Update-FslView {
    $applies = Test-FslApplies
    $ui.TxtFslSubtitle.Text = $(if ($applies) { 'Install and update FSLogix, set the profile container with Microsoft''s recommended values, edit redirections.xml, set the Defender exclusions and test that profiles will work. Everything that changes the master is behind the snapshot gate.' } else { 'The environment says: no FSLogix. The page is shown read only; change the answers on the Overview if this is wrong.' })
    Update-FslInstall; Update-FslSettings; Update-FslGroups; Update-FslRedirections; Update-FslDefender; Update-FslTestView; Update-FslStorageView
}
Build-FslTemplate
