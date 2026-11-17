# The Office page (dot-sourced by Start-AVDTune.ps1). Logic is in Modules\AVDTune.Office.psm1 (docs\office.md). Install, reconfigure, remove and undo run in a background
# runspace (download and setup take minutes) and are polled by the window timer; the quick things (test, save, policies) run on the UI thread. Everything that changes the
# master is behind the write gate. Test mode: the fake machine and the fake Office adapter run inline; no download, no install.
# Helpers of the FSLogix page (pills, result rows, gate snapshot, user) are used; they are resolved when a button is pressed.

$script:OffFake = $null
if ($script:TestMode) { . (Get-TestScript 'FakeOffice.ps1'); $script:OffFake = New-AVDTuneFakeOffice -Machine $script:Machine }
$script:OffJob = $null
$script:OffChecks = [ordered]@{}
$script:OffLangChecks = [ordered]@{}
$script:OffLoaded = $false

function Get-OffAdapter { if ($script:TestMode) { $script:OffFake } else { New-AVDTuneOfficeAdapter } }
function Get-OffChoiceKey($Combo) { if ($Combo.SelectedItem) { [string]$Combo.SelectedItem.Key } else { '' } }
function Set-OffChoice($Combo, [string]$Key) { $Combo.SelectedItem = @($Combo.ItemsSource | Where-Object { $_.Key -ceq $Key })[0] }   # by item: SelectedValue does not find a pscustomobject reliably
function Get-OffFormConfig {
    [pscustomobject]@{
        Channel = [string]$ui.CmbOffChannel.SelectedItem; Edition = [string]$ui.CmbOffEdition.SelectedItem; Product = (Get-OffChoiceKey $ui.CmbOffLicense)
        Languages = @(ConvertTo-AVDTuneOfficeLanguageList @($script:OffLangChecks.Keys | Where-Object { $script:OffLangChecks[$_].IsChecked }))
        Outlook = (Get-OffChoiceKey $ui.CmbOffOutlook)
        ExcludeApps = @(ConvertTo-AVDTuneOfficeExcludes @($script:OffChecks.Keys | Where-Object { $script:OffChecks[$_].IsChecked })); RemoveMSI = [bool]$ui.ChkOffMsi.IsChecked
    }
}
function Add-OffLanguageCheck([string]$Id) {
    $cb = New-Object System.Windows.Controls.CheckBox; $cb.Content = $(if ($Id -eq 'MatchOS') { 'MatchOS (language of Windows)' } else { $Id }); $cb.Margin = '0,0,14,4'
    [System.Windows.Automation.AutomationProperties]::SetName($cb, "Language $Id")
    $cb.Add_Click({ try { Update-OffPreview } catch { } })
    $script:OffLangChecks[$Id] = $cb; [void]$ui.PanelOffLanguages.Children.Add($cb)
}
function Update-OffHints {
    $l = @(Get-AVDTuneOfficeLicenses | Where-Object Key -ceq (Get-OffChoiceKey $ui.CmbOffLicense))
    $ui.TxtOffLicenseHint.Text = $(if ($l.Count) { $l[0].Text } else { '' })
    $ui.TxtOffOutlookHint.Text = Get-AVDTuneOfficeOutlookHint
    $ui.TxtOffAppsHint.Text = Get-AVDTuneOfficeAppsHint
}
function Set-OffForm($Config) {
    $ui.CmbOffChannel.SelectedItem = [string]$Config.Channel; $ui.CmbOffEdition.SelectedItem = [string]$Config.Edition; Set-OffChoice $ui.CmbOffLicense ([string]$Config.Product)
    Set-OffChoice $ui.CmbOffOutlook ([string]$Config.Outlook); $ui.ChkOffMsi.IsChecked = [bool]$Config.RemoveMSI
    foreach ($l in @($Config.Languages)) { if ($l -and -not $script:OffLangChecks.Contains([string]$l)) { Add-OffLanguageCheck ([string]$l) } }   # a language of a saved file that the list does not offer stays visible
    foreach ($k in @($script:OffLangChecks.Keys)) { $script:OffLangChecks[$k].IsChecked = ($k -cin @($Config.Languages)) }
    foreach ($k in @($script:OffChecks.Keys)) { $script:OffChecks[$k].IsChecked = ($k -cnotin @($Config.ExcludeApps)) }
    Update-OffHints
}
function Update-OffPreview {
    try { $ui.TxtOffPreview.Text = New-AVDTuneOfficeXml -Config (Get-OffFormConfig) -Mode Install -LogPath (Join-Path $script:StateRoot 'logs\office') }
    catch { $ui.TxtOffPreview.Text = "Not valid yet: $($_.Exception.Message)" }
}
function New-OffResultRow($Row) {
    # The row of the FSLogix page plus, on a red row that has a one-click fix, a Fix button (DataContext = the fix: the style of the buttons draws Tag as an icon)
    $grid = New-FslResultRow $Row
    if ($Row.FixAction) {
        $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = 'Auto'; [void]$grid.ColumnDefinitions.Add($c)
        $b = New-Object System.Windows.Controls.Button; $b.Content = 'Fix'; $b.DataContext = [string]$Row.FixAction; $b.Margin = '10,0,0,0'; $b.Padding = '14,4,14,4'; $b.VerticalAlignment = 'Center'
        $b.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 3)
        [System.Windows.Automation.AutomationProperties]::SetName($b, "Fix: $($Row.Title)")
        $b.ToolTip = "Sets only this setting; asks first. Source: $($Row.Source)"
        $b.Add_Click({ param($src) try { Invoke-OffFix ([string]$src.DataContext) } catch { Show-Error $_.Exception.Message } })
        [void]$grid.Children.Add($b)
    }
    $grid
}
function Update-OffRows {
    $ui.PanelOffRows.Children.Clear()
    $cfg = Get-OffFormConfig
    if (@(Test-AVDTuneOfficeConfig $cfg).Count -gt 0) { $cfg = Get-AVDTuneOfficeDefaults }
    foreach ($r in @(Get-AVDTuneOfficeRows -Machine $script:Machine -Config $cfg)) { [void]$ui.PanelOffRows.Children.Add((New-OffResultRow $r)) }
}
function Update-OffView {
    if (-not $script:OffLoaded) {
        $ui.CmbOffChannel.ItemsSource = @(Get-AVDTuneOfficeChannels | ForEach-Object Key); $ui.CmbOffEdition.ItemsSource = @('64', '32')
        $ui.CmbOffLicense.ItemsSource = @(Get-AVDTuneOfficeLicenses); $ui.CmbOffOutlook.ItemsSource = @(Get-AVDTuneOfficeOutlookChoices)
        foreach ($l in Get-AVDTuneOfficeLanguages) { Add-OffLanguageCheck $l }
        foreach ($a in Get-AVDTuneOfficeInstallApps) { $cb = New-Object System.Windows.Controls.CheckBox; $cb.Content = $a; $cb.Margin = '0,0,14,4'; [System.Windows.Automation.AutomationProperties]::SetName($cb, "Install $a"); $script:OffChecks[$a] = $cb; [void]$ui.PanelOffInstall.Children.Add($cb) }
        try { Set-OffForm (Get-AVDTuneOfficeConfig -Root $script:StateRoot) } catch { Set-OffForm (Get-AVDTuneOfficeDefaults); $ui.TxtOffState.Text = $_.Exception.Message }
        foreach ($c in $ui.CmbOffChannel, $ui.CmbOffEdition, $ui.CmbOffLicense, $ui.CmbOffOutlook) { $c.Add_SelectionChanged({ try { Update-OffHints; Update-OffPreview } catch { } }) }
        foreach ($c in @($script:OffChecks.Values) + $ui.ChkOffMsi) { $c.Add_Click({ try { Update-OffPreview } catch { } }) }
        $script:OffLoaded = $true
    }
    Update-OffPreview; Update-OffRows
}
function Invoke-OffFix([string]$Name) {
    # One setting only, no ODT run: dry run first, confirmation, then the step behind the write gate
    Assert-FslWrite
    $dry = Set-AVDTuneOfficeFix -Machine $script:Machine -Name $Name -Root $script:StateRoot -WhatIf
    if (@($dry.Results | Where-Object { $_.Status -eq 'WhatIf' }).Count -eq 0) { $ui.TxtOffState.Text = 'This setting is already right.'; Update-OffView; return }
    if (-not (Confirm-Action (Get-AVDTuneOfficeFixText $Name) 'Office')) { return }
    $run = Set-AVDTuneOfficeFix -Machine $script:Machine -Name $Name -Root $script:StateRoot -User (Get-FslUser) -SnapshotId (Get-FslGateSnapshot)
    foreach ($r in @($run.Results)) { Register-StepResult $r }
    $failed = @($run.Results | Where-Object Status -eq 'Failed')
    $ui.TxtOffState.Text = $(if ($failed.Count) { "Fix failed: $($failed[0].Message)" } else { "Fix done: $(@($run.Results | Where-Object Status -eq 'Changed').Count) value changed.$(if (@($run.Results | Where-Object { $_.Reboot -and $_.Status -eq 'Changed' }).Count) { ' Restart the master before you go on.' })" })
    Show-Toast $ui.TxtOffState.Text; Start-OverviewRefresh; Update-OffView
}
function Set-OffBusy([bool]$Busy) {
    foreach ($b in $ui.BtnOffTest, $ui.BtnOffInstall, $ui.BtnOffUndo, $ui.BtnOffRemove, $ui.BtnOffSave, $ui.BtnOffPolicies, $ui.BtnOffPoliciesUndo, $ui.BtnOffFixUndo) { $b.IsEnabled = -not $Busy }
    $window.Cursor = $(if ($Busy -and $script:CurrentPage -eq 'Office') { [System.Windows.Input.Cursors]::AppStarting } else { $null })
}
$script:OffWorkerText = @'
param($Kind, $C)
switch ($Kind) {
    'Install' { Invoke-AVDTuneOfficeRecorded -Machine $C.Machine -O $C.O -Root $C.Root -Mode Install -Config $C.Config -User $C.User -SnapshotId $C.SnapshotId -Progress $C.Progress }
    'Remove' { Invoke-AVDTuneOfficeRecorded -Machine $C.Machine -O $C.O -Root $C.Root -Mode Remove -User $C.User -SnapshotId $C.SnapshotId -Progress $C.Progress }
    'UndoAccept' { Invoke-AVDTuneOfficeUndo -AcceptDrift -Machine $C.Machine -O $C.O -Root $C.Root -User $C.User -SnapshotId $C.SnapshotId -Progress $C.Progress }
    'Undo' { Invoke-AVDTuneOfficeUndo -Machine $C.Machine -O $C.O -Root $C.Root -User $C.User -SnapshotId $C.SnapshotId -Progress $C.Progress }
}
'@
function Start-OffJob([string]$Kind, $Config) {
    if ($script:OffJob) { throw 'Another Office operation is still running.' }
    Assert-NoOtherWriter
    $gate = Get-AVDTuneWriteGate
    $common = @{ Root = $script:StateRoot; User = (Get-FslUser); SnapshotId = (Get-FslGateSnapshot); Config = $Config }
    $title = switch ($Kind) { 'Install' { 'Installing or reconfiguring Microsoft 365 Apps' } 'Remove' { 'Removing Microsoft 365 Apps' } default { 'Undoing the Office change' } }
    $task = Start-AVDTuneUiTask -Kind "office-$($Kind.ToLower())" -Title $title -Step 'Looking up the Office Deployment Tool'
    if ($script:TestMode) {
        $c = $common.Clone(); $c.Machine = $script:Machine; $c.O = $script:OffFake; $c.Progress = $null
        $res = $null; $err = ''
        try { $res = & ([scriptblock]::Create($script:OffWorkerText)) $Kind $c } catch { $err = $_.Exception.Message }
        $script:OffJob = @{ Inline = $true; Result = $res; Err = $err; Kind = $Kind; Task = $task }
    }
    else {
        $sync = [hashtable]::Synchronized(@{ Text = '' })
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
                param($AppRoot, $Kind, $Common, $Gate, $Sync, $WorkerText)
                $ErrorActionPreference = 'Stop'
                Import-Module (Join-Path $AppRoot 'Modules\AVDTune.psm1') -Force
                foreach ($part in 'Updates', 'Office') { Import-Module (Join-Path $AppRoot "Modules\AVDTune.$part.psm1") -Force }
                $c = $Common.Clone(); $c.Machine = New-AVDTuneMachine; $c.O = New-AVDTuneOfficeAdapter; $c.Progress = { param($t) $Sync.Text = $t }
                if ($Gate) { Open-AVDTuneWriteGate -SnapshotId $Gate.SnapshotId -ConfirmedBy $Gate.ConfirmedBy }
                & ([scriptblock]::Create($WorkerText)) $Kind $c
            }).AddArgument($script:AppRoot).AddArgument($Kind).AddArgument($common).AddArgument($gate).AddArgument($sync).AddArgument($script:OffWorkerText)
        $script:OffJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Kind = $Kind; Sync = $sync; Task = $task }
    }
    Set-ShutdownBlock $true
    Set-OffBusy $true
}
function Complete-OffJob {
    $job = $script:OffJob
    if (-not $job) { return }
    if (-not $job.Inline -and -not $job.Handle.IsCompleted) { if ($job.Sync.Text) { Update-AVDTuneUiTask $job.Task -Step ([string]$job.Sync.Text); if ($script:CurrentPage -eq 'Office') { $ui.TxtOffState.Text = $job.Sync.Text } }; return }
    $script:OffJob = $null
    Set-ShutdownBlock $false
    $result = $null; $err = ''
    if ($job.Inline) { $result = $job.Result; $err = [string]$job.Err }
    else {
        try { $out = @($job.PS.EndInvoke($job.Handle)); if ($job.PS.Streams.Error.Count -gt 0) { $err = $job.PS.Streams.Error[0].Exception.Message }; $result = $out | Select-Object -Last 1 }
        catch { $err = $_.Exception.Message }
        finally { $job.PS.Dispose() }
    }
    Set-OffBusy $false
    if ($err -or -not $result) { Complete-AVDTuneUiTask $job.Task -Failed -Summary "Office failed: $err"; $ui.TxtOffState.Text = "Office failed: $err"; Show-Error $ui.TxtOffState.Text; Update-OffView; return }
    Register-StepResult $result.Result
    $ui.TxtOffState.Text = "Office: $($result.Setup.Status). $($result.Setup.Message)$(if ($result.Result.Reboot) { ' Restart the master before you go on.' })"
    Complete-AVDTuneUiTask $job.Task -Failed:([bool]($result.Setup.Status -eq 'Failed')) -Summary $ui.TxtOffState.Text
    Show-Toast $ui.TxtOffState.Text
    Start-OverviewRefresh
    Update-OffView
}
$script:Timer.Add_Tick({ try { Complete-OffJob } catch { Show-Error $_.Exception.Message } })

Add-Click $ui.BtnOffTest { Update-OffView; $ui.TxtOffState.Text = 'Tested: nothing was changed.' }
Add-Click $ui.BtnOffSave { [void](Set-AVDTuneOfficeConfig -Root $script:StateRoot -Config (Get-OffFormConfig)); $ui.TxtOffState.Text = 'Settings saved (no change of the master).'; Update-OffView }
Add-Click $ui.BtnOffInstall {
    Assert-FslWrite
    $cfg = Get-OffFormConfig
    $problems = @(Test-AVDTuneOfficeConfig $cfg); if ($problems.Count -gt 0) { throw ($problems -join ' ') }
    if (-not (Confirm-Action 'Download the Office Deployment Tool from Microsoft, check its signature and install or reconfigure Microsoft 365 Apps with the shown configuration? This takes several minutes and a restart may follow.' 'Office')) { return }
    [void](Set-AVDTuneOfficeConfig -Root $script:StateRoot -Config $cfg)
    Start-OffJob 'Install' $cfg; $ui.TxtOffState.Text = 'Looking up the Office Deployment Tool ...'
}
Add-Click $ui.BtnOffRemove {
    Assert-FslWrite
    if (-not (Confirm-Action (Get-AVDTuneOfficeRemoveText -Machine $script:Machine) 'Office')) { return }
    Start-OffJob 'Remove' $null; $ui.TxtOffState.Text = 'Removing Microsoft 365 Apps ...'
}
Add-Click $ui.BtnOffUndo {
    Assert-FslWrite
    if (-not (Confirm-Action (Get-AVDTuneOfficeUndoText -Root $script:StateRoot) 'Office')) { return }
    $drift = Get-AVDTuneOfficeUndoDrift -Machine $script:Machine -Root $script:StateRoot
    $kind = 'Undo'
    if ($drift) { if (-not (Confirm-Action (($drift) + ' Go on anyway?') 'Office')) { return }; $kind = 'UndoAccept' }
    Start-OffJob $kind $null; $ui.TxtOffState.Text = 'Undoing the Office change ...'
}
Add-Click $ui.BtnOffPolicies {
    Assert-FslWrite
    $dry = Set-AVDTuneOfficePolicies -Machine $script:Machine -Root $script:StateRoot -WhatIf
    $n = @($dry.Results | Where-Object { $_.Status -eq 'WhatIf' }).Count
    if ($n -eq 0) { $ui.TxtOffState.Text = 'The update policies are already set.'; return }
    if (-not (Confirm-Action "Set $n Office update policy value(s) in the registry of this master?" 'Office')) { return }
    $run = Set-AVDTuneOfficePolicies -Machine $script:Machine -Root $script:StateRoot -User (Get-FslUser) -SnapshotId (Get-FslGateSnapshot)
    foreach ($r in @($run.Results)) { Register-StepResult $r }
    $ui.TxtOffState.Text = "Office update policies: $(@($run.Results | Where-Object Status -eq 'Changed').Count) changed."; Show-Toast $ui.TxtOffState.Text; Start-OverviewRefresh; Update-OffView
}
Add-Click $ui.BtnOffPoliciesUndo {
    Assert-FslWrite
    if (-not (Confirm-Action 'Put back the Office update policy values found before the change?' 'Office')) { return }
    $run = Undo-AVDTuneOfficePolicies -Machine $script:Machine -Root $script:StateRoot -User (Get-FslUser) -SnapshotId (Get-FslGateSnapshot)
    foreach ($r in @($run.Results)) { Register-StepResult $r }
    $ui.TxtOffState.Text = 'Office update policies: undone.'; Show-Toast $ui.TxtOffState.Text; Start-OverviewRefresh; Update-OffView
}
Add-Click $ui.BtnOffFixUndo {
    Assert-FslWrite
    $names = @(Get-AVDTuneOfficeFixRecorded -Root $script:StateRoot)
    if ($names.Count -eq 0) { $ui.TxtOffState.Text = 'No one-click fix of this page is recorded: nothing to undo.'; return }
    if (-not (Confirm-Action "Put back the values found before the one-click fix(es) ($($names -join ', '))? Undo does not restart the master and does not restore reset activations." 'Office')) { return }
    $lines = @()
    foreach ($n in $names) {
        try {
            $run = Undo-AVDTuneOfficeFix -Machine $script:Machine -Name $n -Root $script:StateRoot -User (Get-FslUser) -SnapshotId (Get-FslGateSnapshot)
            foreach ($r in @($run.Results)) { Register-StepResult $r }
            $st = @($run.Results | ForEach-Object { [string]$_.Status }) -join '/'
            $note = @($run.Results | Where-Object { $_.Message } | ForEach-Object { [string]$_.Message }) -join ' '
            $lines += "$n $st" + $(if ($note) { " ($note)" } else { '' })
        }
        catch { $lines += "$n Failed ($($_.Exception.Message))" }
    }
    $ui.TxtOffState.Text = "Office one-click fix undo: $($lines -join '; ')"; Show-Toast $ui.TxtOffState.Text; Start-OverviewRefresh; Update-OffView
}
