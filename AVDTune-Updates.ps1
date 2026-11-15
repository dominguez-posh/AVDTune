# The Updates page and the Update block page (dot-sourced by Start-AVDTune.ps1). Logic is in Modules\AVDTune.Updates.psm1 and AVDTune.UpdateBlock.psm1;
# this file builds the lists, starts the long work in a background runspace (search, run, repair) and polls it with the window timer.
# The write gate lives in memory of the module: the runspace gets a copy of it (same confirmation) because it imports its own module instance.
# Test mode: the runspace uses the fake machine and the fake update adapter (Tests\Fakes\FakeUpdates.ps1), never a real update.

$script:UpdItems = @()
$script:UpdChecked = @{}
$script:UpdJob = $null
$script:UpdLastRun = $null
$script:UpdStatus = $null
$script:UpdFakeScript = $(if ($script:TestMode) { Join-Path (Split-Path $env:AVDTUNE_FAKE -Parent) 'FakeUpdates.ps1' } else { '' })
$script:UpdFakeSeed = $null   # test hook: hashtable for New-AVDTuneFakeUpdates
$script:UpdFakeWua = @(
    @{ Id = 'u1'; Title = '2026-11 Cumulative Update for Windows 11 (KB5050001)'; Kbs = @('5050001'); IsDriver = $false; SizeMB = 600; Reboot = $true }
    @{ Id = 'u2'; Title = '.NET 9.0 Security Update (KB5050002)'; Kbs = @('5050002'); IsDriver = $false; SizeMB = 80; Reboot = $false }
    @{ Id = 'u3'; Title = 'Contoso Display driver 1.2'; Kbs = @(); IsDriver = $true; SizeMB = 20; Reboot = $false }
)
$script:UpdFakeNative = @{
    '* upgrade --source winget *' = @{ ExitCode = 0; Output = "Name   Id         Version Available Source`r`n------------------------------------------`r`n7-Zip  7zip.7zip  23.01   24.08     winget`r`n" }
    '* outdated -r *' = @{ ExitCode = 0; Output = 'git|2.40.0|2.45.0|false' }
    '*OfficeC2RClient*' = @{ ExitCode = 0; Output = '' }
    '* upgrade --id *' = @{ ExitCode = 0; Output = 'ok' }
}

function Get-UpdateAdapter {
    if ($script:TestMode) { . $script:UpdFakeScript; if ($script:UpdFakeSeed) { return New-AVDTuneFakeUpdates -Seed $script:UpdFakeSeed }; return New-AVDTuneFakeUpdates -Seed @{ Wua = $script:UpdFakeWua; Native = $script:UpdFakeNative } }
    New-AVDTuneUpdateAdapter
}

function Start-UpdJob([string]$Kind, $Argument) {
    # Kind: Scan | Run | Repair-Dism | Repair-Sfc
    if ($script:UpdJob) { throw 'Another update operation is still running.' }
    if ($script:BenchJob) { throw 'A benchmark is running. Wait until it is done.' }
    $sync = [hashtable]::Synchronized(@{ Text = ''; Done = $false })
    $gate = Get-AVDTuneWriteGate
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param($AppRoot, $Fake, $FakeUpd, $Root, $Kind, $Argument, $Gate, $Sync, $User, $Seed, $Wua, $Native, $SharedMachine)
            $ErrorActionPreference = 'Stop'
            Import-Module (Join-Path $AppRoot 'Modules\AVDTune.psm1') -Force
            Import-Module (Join-Path $AppRoot 'Modules\AVDTune.UpdateBlock.psm1') -Force
            Import-Module (Join-Path $AppRoot 'Modules\AVDTune.Updates.psm1') -Force
            if ($Fake) {
                . $Fake; . $FakeUpd
                $m = $SharedMachine   # test mode: the one fake machine of the window, so the page sees what the job changed
                if (-not $m) { $m = New-AVDTuneFakeMachine -Seed @{ Registry = @{ 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}|pv' = '130.0.1'; 'HKLM:\SOFTWARE\FSLogix\Apps|InstallVersion' = '2.9.8884.27471' } } }
                $u = if ($Seed) { New-AVDTuneFakeUpdates -Seed $Seed } else { New-AVDTuneFakeUpdates -Seed @{ Wua = $Wua; Native = $Native } }
            }
            else { $m = New-AVDTuneMachine; $u = New-AVDTuneUpdateAdapter }
            if ($Gate) { Open-AVDTuneWriteGate -SnapshotId $Gate.SnapshotId -ConfirmedBy $Gate.ConfirmedBy }
            $progress = { param($t) $Sync.Text = $t }
            try {
                switch ($Kind) {
                    'Scan' { Get-AVDTuneUpdateList -Machine $m -U $u -Root $Root -Progress $progress }
                    'Run' { Invoke-AVDTuneUpdateRun -Machine $m -U $u -Root $Root -Items $Argument -User $User -SnapshotId $Gate.SnapshotId -Progress $progress }
                    'Repair-Dism' { Invoke-AVDTuneRepair -Machine $m -U $u -Root $Root -Kind Dism -User $User -SnapshotId $Gate.SnapshotId -Progress $progress }
                    'Repair-Sfc' { Invoke-AVDTuneRepair -Machine $m -U $u -Root $Root -Kind Sfc -User $User -SnapshotId $Gate.SnapshotId -Progress $progress }
                    'Block-On' { Set-AVDTuneUpdateBlock -Machine $m -Root $Root -Mode On -User $User -SnapshotId $Gate.SnapshotId }
                    'Block-Off' { Set-AVDTuneUpdateBlock -Machine $m -Root $Root -Mode Off -User $User -SnapshotId $Gate.SnapshotId }
                    'Block-Repair' { Repair-AVDTuneMaintenanceCrash -Machine $m -Root $Root -User $User }
                }
            }
            finally { $Sync.Done = $true }
        }).AddArgument($script:AppRoot).AddArgument($(if ($script:TestMode) { $env:AVDTUNE_FAKE } else { '' })).AddArgument($script:UpdFakeScript).AddArgument($script:StateRoot).AddArgument($Kind).AddArgument($Argument).AddArgument($gate).AddArgument($sync).AddArgument([string]$env:USERNAME).AddArgument($script:UpdFakeSeed).AddArgument($script:UpdFakeWua).AddArgument($script:UpdFakeNative).AddArgument($(if ($script:TestMode) { $script:Machine } else { $null }))
    $script:UpdJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Kind = $Kind; Sync = $sync }
    Set-ShutdownBlock $true   # Windows shows why log off or shut down should wait (Start-AVDTune.ps1)
    Set-UpdateBusy $true
}
function Set-UpdateBusy([bool]$Busy) {
    foreach ($b in $ui.BtnUpdScan, $ui.BtnUpdSelected, $ui.BtnUpdAll, $ui.BtnRepairDism, $ui.BtnRepairSfc, $ui.BtnBlockOn, $ui.BtnBlockOff, $ui.BtnBlockRepair, $ui.BtnUpdSave) { $b.IsEnabled = -not $Busy }
    $window.Cursor = $(if ($Busy) { [System.Windows.Input.Cursors]::AppStarting } else { $null })
}
function Complete-UpdJob {
    $job = $script:UpdJob
    if (-not $job) { return }
    if (-not $job.Handle.IsCompleted) { if ($job.Sync.Text -and $script:CurrentPage -eq 'Updates') { $ui.TxtUpdState.Text = $job.Sync.Text }; return }
    $script:UpdJob = $null
    Set-ShutdownBlock $false
    $result = $null; $err = ''
    try {
        $out = @($job.PS.EndInvoke($job.Handle))
        if ($job.PS.Streams.Error.Count -gt 0) { $err = $job.PS.Streams.Error[0].Exception.Message }
        $result = $out | Select-Object -Last 1
    }
    catch { $err = $_.Exception.Message }
    finally { $job.PS.Dispose() }
    Set-UpdateBusy $false
    switch -Wildcard ($job.Kind) {
        'Scan' {
            if ($err) { $ui.TxtUpdState.Text = "The search failed: $err" } else {
                $script:UpdItems = @($result.Items); $script:UpdNotes = @($result.Notes)
                $ui.TxtUpdState.Text = "Searched at $((Get-Date).ToString('HH:mm:ss')): $(@($script:UpdItems | Where-Object Selectable).Count) item(s) can be updated."
            }
            Update-UpdatesView
        }
        'Run' {
            if ($err) { $ui.TxtUpdState.Text = "The run stopped: $err"; Show-Error $err }
            if ($result) {
                $script:UpdLastRun = $result
                foreach ($r in $result.Results) { Register-StepResult $r }
                $ok = @($result.Results | Where-Object { $_.Status -eq 'Changed' }).Count; $bad = @($result.Results | Where-Object { $_.Status -eq 'Failed' }).Count
                $ui.TxtUpdState.Text = "Run finished: $ok updated, $bad failed.$(if ($result.Reboot) { ' A restart is needed.' })$(if ($err) { " $err" })"
                Show-Toast $ui.TxtUpdState.Text
            }
            Update-UpdatesView; Start-OverviewRefresh; Update-UpdateBlockView
            # the list is stale after a run: search again
            if (-not $script:UpdJob -and -not $script:CloseWhenDone) { Start-UpdJob 'Scan' $null }
        }
        'Repair-*' {
            if ($err) { Show-Error $err } elseif ($result) { Register-StepResult $result; Show-Toast "$($result.Title): $($result.Status). $($result.Message)"; $ui.TxtUpdState.Text = "$($result.Title): $($result.Status). $($result.Message)" }
            Update-UpdatesView; Start-OverviewRefresh
        }
        'Block-*' {
            if ($err) { Show-Error $err }
            elseif ($result) {
                $text = if ($job.Kind -eq 'Block-Repair') { [string]$result.Message } else { "Update block $($result.Mode.ToLower()): $($result.Changed) setting(s) changed, state $($result.State)." }
                Show-Toast $text
                [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'updateblock' -Subject $text)
                Save-Protocol
            }
            Update-UpdateBlockView; Start-OverviewRefresh
        }
    }
    # the window was closed during the operation (Add_Closing in Start-AVDTune.ps1): close it now, unless it failed and the message has to be read
    if ($script:CloseWhenDone -and -not $script:UpdJob -and -not $script:BenchJob) {
        if ($err) { $script:CloseWhenDone = $false; Show-Error "Not closed because the operation failed: $err" } else { $window.Close() }
    }
}
$script:Timer.Add_Tick({ try { Complete-UpdJob } catch { Show-Error $_.Exception.Message } })

# ---------------------------------------------------------------- Updates page
$script:UpdStatusPill = @{ Available = @('AccentSubtle', 'Primary', 'Update'); Check = @('AccentSubtle', 'Primary', 'Check'); UpToDate = @('SuccessBg', 'Success', 'Up to date'); Excluded = @('Hover', 'MutedText', 'Excluded'); DetectOnly = @('Hover', 'MutedText', 'Detected'); Missing = @('Hover', 'MutedText', 'Not installed'); Error = @('ErrorBg', 'Danger', 'Problem') }
function New-UpdRow($Item) {
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '0,5,0,5'
    foreach ($w in 28, 150, 270, 150, '*') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$grid.ColumnDefinitions.Add($c) }
    $chk = New-Object System.Windows.Controls.CheckBox
    $chk.IsEnabled = [bool]$Item.Selectable; $chk.IsChecked = [bool]($Item.Selectable -and $script:UpdChecked[$Item.Id]); $chk.VerticalAlignment = 'Center'; $chk.DataContext = [string]$Item.Id
    [System.Windows.Automation.AutomationProperties]::SetName($chk, "Select $($Item.Title)")
    $chk.Add_Click({ param($s) $script:UpdChecked[[string]$s.DataContext] = [bool]$s.IsChecked })
    $pair = $script:UpdStatusPill[[string]$Item.Status]
    $pill = New-Object System.Windows.Controls.Border
    Set-Brush $pill ([System.Windows.Controls.Border]::StyleProperty) 'Pill'; $pill.Padding = '10,2'; $pill.VerticalAlignment = 'Center'; $pill.HorizontalAlignment = 'Left'; $pill.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
    Set-Brush $pill ([System.Windows.Controls.Border]::BackgroundProperty) $pair[0]
    $pt = New-Object System.Windows.Controls.TextBlock; $pt.Text = $pair[2]; $pt.FontSize = 12; $pt.FontWeight = 'SemiBold'; Set-Brush $pt ([System.Windows.Controls.TextBlock]::ForegroundProperty) $pair[1]; $pill.Child = $pt
    $title = New-Object System.Windows.Controls.TextBlock; $title.Text = [string]$Item.Title; $title.TextWrapping = 'Wrap'; $title.FontWeight = 'SemiBold'; $title.VerticalAlignment = 'Center'; $title.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2); $title.Margin = '0,0,10,0'
    $ver = New-Object System.Windows.Controls.TextBlock; $ver.VerticalAlignment = 'Center'; $ver.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 3)
    $ver.Text = if ($Item.Installed -and $Item.Available) { "$($Item.Installed) -> $($Item.Available)" } elseif ($Item.Installed) { [string]$Item.Installed } elseif ($Item.Kb) { [string]$Item.Kb } else { '' }
    Set-Brush $ver ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
    $detail = New-Object System.Windows.Controls.TextBlock; $detail.Text = [string]$Item.Detail; $detail.TextWrapping = 'Wrap'; $detail.VerticalAlignment = 'Center'; $detail.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 4)
    Set-Brush $detail ([System.Windows.Controls.TextBlock]::ForegroundProperty) $(if ($Item.Status -eq 'Error') { 'Danger' } else { 'MutedText' })
    foreach ($e in $chk, $pill, $title, $ver, $detail) { [void]$grid.Children.Add($e) }
    $grid
}
function New-UpdGroupHead([string]$Text) {
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $Text; $t.FontWeight = 'SemiBold'; $t.Margin = '0,14,0,2'
    Set-Brush $t ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'Primary'; $t
}
function Update-UpdatesView {
    $ui.PanelUpdItems.Children.Clear()
    if ($script:UpdItems.Count -eq 0) { $ui.TxtUpdState.Text = $(if ($script:UpdJob) { $ui.TxtUpdState.Text } else { 'Nothing searched yet. Press Search.' }) }
    $last = ''
    foreach ($item in ($script:UpdItems | Sort-Object { @('Windows', 'Microsoft 365 Apps', 'Edge', 'Teams', 'OneDrive', 'FSLogix', 'Defender', 'Software').IndexOf([string]$_.Group) }, Title)) {
        if ($item.Group -ne $last) { [void]$ui.PanelUpdItems.Children.Add((New-UpdGroupHead $item.Group)); $last = $item.Group }
        [void]$ui.PanelUpdItems.Children.Add((New-UpdRow $item))
    }
    $ui.TxtUpdNotes.Text = (@($script:UpdNotes) -join "`r`n")
    $failedRepair = $script:UpdLastRun -and @($script:UpdLastRun.Results | Where-Object { $_.Status -eq 'Failed' -and $_.Repair }).Count -gt 0
    $ui.BoxUpdRepair.Visibility = ConvertTo-Vis ([bool]$failedRepair)
    # history
    $ui.PanelUpdHistory.Children.Clear()
    $hist = @(Get-AVDTuneUpdateHistory -Root $script:StateRoot -Last 12)
    if ($hist.Count -eq 0) { $t = New-Text 'No update run yet.' 'Hint'; [void]$ui.PanelUpdHistory.Children.Add($t) }
    foreach ($h in $hist) {
        $line = "{0}   {1}   {2}{3}" -f ([datetime]$h.At).ToString('yyyy-MM-dd HH:mm'), $h.Status.PadRight(9), $h.Title, $(if ($h.Code -and $h.Status -eq 'Failed') { " ($($h.Code)): $($h.Message)" } else { '' })
        $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $line; $t.TextWrapping = 'Wrap'; $t.FontFamily = 'Cascadia Mono, Consolas'; $t.FontSize = 12; $t.Margin = '0,2,0,2'
        Set-Brush $t ([System.Windows.Controls.TextBlock]::ForegroundProperty) $(if ($h.Status -eq 'Failed') { 'Danger' } else { 'Text' })
        [void]$ui.PanelUpdHistory.Children.Add($t)
    }
    $s = Get-AVDTuneUpdateSettings $script:StateRoot
    $ui.ChkUpdDrivers.IsChecked = $s.IncludeDrivers; $ui.ChkUpdPreviews.IsChecked = $s.IncludePreviews; $ui.ChkUpdMicrosoft.IsChecked = $s.MicrosoftUpdate
    if (-not $ui.TxtUpdKbs.IsKeyboardFocused) { $ui.TxtUpdKbs.Text = ($s.ExcludedKbs -join ', ') }
}
function Start-UpdateRun([object[]]$Items) {
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot of today on the Overview first.' }
    $list = @($Items | Where-Object { $_.Selectable })
    if ($list.Count -eq 0) { throw 'Nothing is selected.' }
    $block = Get-AVDTuneUpdateBlockStatus $script:Machine
    $ask = "Update $($list.Count) item(s)?`nThe update block is lifted for the run and put back afterwards."
    if (-not (Confirm-Action $ask 'Update')) { return }
    $ui.TxtUpdState.Text = 'Starting the run ...'
    Start-UpdJob 'Run' $list
}
Add-Click $ui.BtnUpdScan { Start-UpdJob 'Scan' $null; $ui.TxtUpdState.Text = 'Searching ...' }
Add-Click $ui.BtnUpdAll { Start-UpdateRun @($script:UpdItems | Where-Object { $_.Selectable -and $_.Status -eq 'Available' -or $_.Selectable -and $_.Status -eq 'Check' }) }
Add-Click $ui.BtnUpdSelected { Start-UpdateRun @($script:UpdItems | Where-Object { $_.Selectable -and $script:UpdChecked[$_.Id] }) }
Add-Click $ui.BtnRepairDism { if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot first.' }; if (Confirm-Action 'Run DISM /Online /Cleanup-Image /RestoreHealth? This takes a while.' 'Repair') { Start-UpdJob 'Repair-Dism' $null } }
Add-Click $ui.BtnRepairSfc { if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot first.' }; if (Confirm-Action 'Run sfc /scannow? This takes a while.' 'Repair') { Start-UpdJob 'Repair-Sfc' $null } }
Add-Click $ui.BtnUpdSave {
    $kbs = ConvertTo-AVDTuneKbList ([string]$ui.TxtUpdKbs.Text)
    $s = Set-AVDTuneUpdateSettings -Root $script:StateRoot -IncludeDrivers ([bool]$ui.ChkUpdDrivers.IsChecked) -IncludePreviews ([bool]$ui.ChkUpdPreviews.IsChecked) -ExcludedKbs $kbs -MicrosoftUpdate ([bool]$ui.ChkUpdMicrosoft.IsChecked)
    Show-Toast 'Update settings saved. Search again to apply them to the list.'
}
$script:UpdNotes = @()

# ---------------------------------------------------------------- Update block page
function Update-UpdateBlockView {
    $st = Get-AVDTuneUpdateBlockStatus $script:Machine
    $script:UpdStatus = $st
    $map = @{ On = @('SuccessBg', 'Success', 'Blocked'); Partial = @('WarningBg', 'Warning', 'Partly'); Off = @('WarningBg', 'Warning', 'Not blocked') }
    $crash = Get-AVDTuneMaintenanceCrash -Root $script:StateRoot
    $pair = $map[[string]$st.State]
    if ($crash) { $pair = @('ErrorBg', 'Danger', 'Interrupted') }
    Set-Brush $ui.PillBlock ([System.Windows.Controls.Border]::BackgroundProperty) $pair[0]
    $ui.TxtBlockPill.Text = $pair[2]; Set-Brush $ui.TxtBlockPill ([System.Windows.Controls.TextBlock]::ForegroundProperty) $pair[1]
    $ui.TxtBlockSummary.Text = "$($st.Compliant) of $($st.Applicable) settings are in place.$(if ($st.State -ne 'On' -and $st.Missing) { ' Missing: ' + $st.Missing + '.' })"
    $ui.TxtBlockFindings.Text = (@($st.Findings) -join "`r`n")
    $ui.BoxBlockCrash.Visibility = ConvertTo-Vis ([bool]$crash)
    if ($crash) { $ui.TxtBlockCrash.Text = "The maintenance mode of $(([datetime]$crash.Started).ToString('yyyy-MM-dd HH:mm')) (by $($crash.User)) did not end properly: AVDTune was closed or stopped in the middle. The update block may be lifted. Repair puts back what was on before and writes a change log entry." }
    $ui.PanelBlockItems.Children.Clear()
    $last = ''
    foreach ($i in $st.Items) {
        if ($i.Group -ne $last) { [void]$ui.PanelBlockItems.Children.Add((New-UpdGroupHead $i.Group)); $last = $i.Group }
        $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,4,0,4'
        foreach ($w in 100, '*', 160) { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
        $k = if (-not $i.Applicable) { @('Hover', 'MutedText', 'Not installed') } elseif ($i.Compliant) { @('SuccessBg', 'Success', 'In place') } else { @('WarningBg', 'Warning', 'Missing') }
        $pill = New-Object System.Windows.Controls.Border; Set-Brush $pill ([System.Windows.Controls.Border]::StyleProperty) 'Pill'; $pill.Padding = '10,2'; $pill.HorizontalAlignment = 'Left'; $pill.VerticalAlignment = 'Center'
        Set-Brush $pill ([System.Windows.Controls.Border]::BackgroundProperty) $k[0]
        $pt = New-Object System.Windows.Controls.TextBlock; $pt.Text = $k[2]; $pt.FontSize = 12; $pt.FontWeight = 'SemiBold'; Set-Brush $pt ([System.Windows.Controls.TextBlock]::ForegroundProperty) $k[1]; $pill.Child = $pt
        $t = New-Object System.Windows.Controls.TextBlock; $t.Text = [string]$i.Title; $t.TextWrapping = 'Wrap'; $t.VerticalAlignment = 'Center'; $t.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1); $t.Margin = '0,0,10,0'; $t.ToolTip = "$($i.Why)`r`nSource: $($i.Source)"
        $s = New-Object System.Windows.Controls.TextBlock; $s.Text = [string]$i.State; $s.VerticalAlignment = 'Center'; $s.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2); Set-Brush $s ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
        foreach ($e in $pill, $t, $s) { [void]$g.Children.Add($e) }
        [void]$ui.PanelBlockItems.Children.Add($g)
    }
}
function Start-BlockChange([string]$Mode) {
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot of today on the Overview first.' }
    $ask = if ($Mode -eq 'Off') { 'Switch the update block off? Users can then see and run updates until you switch it on again. Do this only for work on the master.' } else { 'Switch the update block on?' }
    if (-not (Confirm-Action $ask 'Update block')) { return }
    Start-UpdJob "Block-$Mode" $null
}
Add-Click $ui.BtnBlockOn { Start-BlockChange 'On' }
Add-Click $ui.BtnBlockOff { Start-BlockChange 'Off' }
Add-Click $ui.BtnBlockRepair { if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot of today on the Overview first.' }; Start-UpdJob 'Block-Repair' $null }
