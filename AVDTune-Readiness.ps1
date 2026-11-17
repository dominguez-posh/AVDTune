# The Readiness card on the Overview (dot-sourced by Start-AVDTune.ps1). Logic is in Modules\AVDTune.Readiness.psm1; this file builds the list, starts the
# analysis and the fixes in a background runspace and polls it with the window timer. The analysis reads only; the stornvme fix and the update block fix
# need the open write gate (snapshot confirmed). Test mode: the runspace uses the fake machine and the fake Azure Resource Manager, never a real tenant.
# The Azure token is read on the UI thread, handed to the runspace as an argument for this one run and never stored.

$script:Ready = $null
$script:ReadyJob = $null
$script:ReadyQueued = $null
$script:ReadyOpen = @{}
$script:ReadyPill = @{ green = @('SuccessBg', 'Success', 'Green'); yellow = @('WarningBg', 'Warning', 'Yellow'); red = @('ErrorBg', 'Danger', 'Red'); unknown = @('Hover', 'MutedText', 'Not checkable'); info = @('Hover', 'MutedText', 'Info') }
$script:ReadyRank = @{ red = 0; yellow = 1; unknown = 2; green = 3; info = 4 }
$script:ReadySettingsPath = Join-Path $script:StateRoot 'config\readiness-settings.json'

function Get-ReadySettings {
    # The chosen image definition lives in environment.json (Gallery); an older config\readiness-settings.json is still read when there is none
    $id = ''
    try { $id = Get-AVDTuneEnvironmentGallery (Get-AVDTuneEnvironment $script:StateRoot) } catch { }
    if (-not $id) {
        $s = $null
        try { $s = Read-AVDTuneJson $script:ReadySettingsPath } catch { }
        if ($s) { $id = [string](ConvertTo-AVDTuneGalleryImageId ([string](Get-AVDTuneProp $s 'GalleryImageId'))) }
    }
    [pscustomobject]@{ GalleryImageId = [string]$id }
}
$script:ReadyGalleryItems = @()
function Get-ReadyGallerySelection {
    # The definition ID behind the selected line of the list, '' when none
    $i = $ui.CmbReadyGallery.SelectedIndex
    if ($i -ge 0 -and $i -lt @($script:ReadyGalleryItems).Count) { [string]@($script:ReadyGalleryItems)[$i].Id } else { '' }
}
function Format-ReadyGalleryName([string]$Id) { if ($Id) { (($Id -split '/')[-3]) + ' / ' + (($Id -split '/')[-1]) } else { '' } }
function Update-ReadyGallery {
    # The image definition part of the card: what is used and where it came from, and the definitions found to choose from
    $r = $script:Ready
    $saved = (Get-ReadySettings).GalleryImageId
    $items = New-Object System.Collections.ArrayList
    if ($r) { foreach ($c in @($r.GalleryCandidates)) { if ($c) { [void]$items.Add([pscustomobject]@{ Id = [string]$c.Id; Label = [string]$c.Label }) } } }
    if ($saved -and -not @($items | Where-Object { $_.Id -ieq $saved })) { [void]$items.Insert(0, [pscustomobject]@{ Id = $saved; Label = "$(Format-ReadyGalleryName $saved) (chosen)" }) }
    if ($r -and $r.GalleryImageId -and -not @($items | Where-Object { $_.Id -ieq $r.GalleryImageId })) { [void]$items.Insert(0, [pscustomobject]@{ Id = [string]$r.GalleryImageId; Label = "$(Format-ReadyGalleryName $r.GalleryImageId) (found)" }) }
    # The list shows the labels (strings: WPF cannot bind to the properties of a PowerShell object); $script:ReadyGalleryItems keeps the IDs in the same order
    $keep = Get-ReadyGallerySelection
    $script:ReadyGalleryItems = @($items)
    $ui.CmbReadyGallery.ItemsSource = [string[]]@($items | ForEach-Object { $_.Label })
    $pick = if ($keep -and @($items | Where-Object { $_.Id -eq $keep })) { $keep } elseif ($saved) { $saved } elseif ($r -and $r.GalleryImageId) { [string]$r.GalleryImageId } else { '' }
    $index = 0; for ($i = 0; $i -lt $items.Count; $i++) { if ($items[$i].Id -ieq $pick) { $index = $i } }
    if ($items.Count -gt 0) { $ui.CmbReadyGallery.SelectedIndex = $index }
    $ui.CmbReadyGallery.IsEnabled = ($items.Count -gt 0)
    $ui.BtnReadyGallery.IsEnabled = ($items.Count -gt 0)
    $ui.BtnReadyGalleryClear.Visibility = ConvertTo-Vis ([bool]$saved)
    $ui.TxtReadyGalleryState.Text = $(
        if ($saved) { T 'ready.gal.chosen' (Format-ReadyGalleryName $saved) }
        elseif ($r -and $r.GallerySource -eq 'Matched' -and $r.GalleryMatch) { T 'ready.gal.matched' $r.GalleryMatch.Label $r.GalleryMatch.VersionName $r.GalleryMatch.How }
        elseif ($r -and $r.GallerySource -eq 'ImageReference') { T 'ready.gal.imageref' (Format-ReadyGalleryName $r.GalleryImageId) }
        elseif ($items.Count -gt 0) { T 'ready.gal.choose' }
        elseif ($r -and $r.Arm.Ok) { T 'ready.gal.none' }
        else { T 'ready.gal.signin' })
}
function Get-ReadyToken {
    $s = $script:StartContext.Session
    if (-not $s -or -not $s.Connected) { return @{ Token = ''; Reason = (T 'ready.err.nosignin') } }
    try { @{ Token = (Get-AVDTuneAccessToken -Session $s -Audience Arm); Reason = '' } } catch { @{ Token = ''; Reason = $_.Exception.Message } }
}
function Get-ReadyKind {
    $had = @(Get-AVDTuneRun -Root $script:StateRoot | Where-Object { $_.PSObject.Properties['Kind'] -and $_.Kind -eq 'Erstanalyse' }).Count
    if ($had -gt 0) { 'Healthcheck' } else { 'Erstanalyse' }
}

function Set-ReadyBusy([bool]$Busy) {
    $ui.BtnReadyRun.IsEnabled = -not $Busy
    $window.Cursor = $(if ($Busy -and $script:CurrentPage -eq 'Overview') { [System.Windows.Input.Cursors]::AppStarting } else { $null })
}
function New-ReadyTask([string]$Kind, [string]$FixId) {
    # the analysis is read only and can be started again from the list; a fix changes the master and is started on the card (with its confirmation)
    $title = switch ($Kind) { 'Fix' { T 'ready.task.fix' $FixId } 'Healthcheck' { T 'ready.task.healthcheck' } 'Erstanalyse' { T 'ready.task.initial' } 'Start' { T 'ready.task.start' } default { T 'ready.task.manual' } }
    $retry = if ($Kind -ne 'Fix') { @{ Command = 'Start-ReadyJob'; Arguments = @($Kind, '') } }
    Start-AVDTuneUiTask -Kind "readiness-$($Kind.ToLower())" -Title $title -Step $(if ($Kind -eq 'Fix') { T 'ready.task.step.fix' } else { T 'ready.task.step.check' }) -Retry $retry
}
function Start-ReadyJob([string]$Kind, [string]$FixId) {
    # Kind: Start | Erstanalyse | Healthcheck | Manual (analysis) or Fix. A request while one runs is queued (the newest one wins).
    # Test mode: the inline run waits while the Overview refresh uses the same fake machine on its own thread (the timer starts it afterwards)
    if ($Kind -eq 'Fix') { Assert-NoOtherWriter }   # a fix changes the master (#66)
    if ($script:ReadyJob -or ($script:TestMode -and $script:OverviewJob)) { $script:ReadyQueued = @{ Kind = $Kind; FixId = $FixId }; return }
    $tok = Get-ReadyToken
    $gate = Get-AVDTuneWriteGate
    $gallery = (Get-ReadySettings).GalleryImageId
    if ($script:TestMode) {
        # Test mode runs inline on the UI thread: the fakes are closures of this runspace, and running them on a second thread while this one executes
        # script corrupts the engine state of the runspace. The real adapters have no such limit and run in the background.
        $res = $null; $err = ''
        try {
            $res = if ($Kind -eq 'Fix') { Invoke-AVDTuneReadinessFix -Machine $script:Machine -Root $script:StateRoot -FixId $FixId -User ([string]$env:USERNAME) -SnapshotId ([string]$gate.SnapshotId) }
            else { Invoke-AVDTuneReadiness -Machine $script:Machine -Arm $script:ReadyFakeArm -Token $tok.Token -NoTokenReason $tok.Reason -GalleryImageId $gallery -FSLogixApplies (Test-FslApplies) -FSLogixTest (Get-AVDTuneFSLogixTestRecord -Root $script:StateRoot) -Root $script:StateRoot }
        }
        catch { $err = $_.Exception.Message }
        $script:ReadyJob = @{ Inline = $true; Result = $res; Err = $err; Kind = $Kind; FixId = $FixId; Task = (New-ReadyTask $Kind $FixId) }
        Set-ReadyBusy $true
        Update-ReadyView
        return
    }
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param($AppRoot, $Root, $Kind, $FixId, $Token, $Reason, $Gallery, $Gate, $User, $FslApplies, $FslTest)
            $ErrorActionPreference = 'Stop'
            Import-Module (Join-Path $AppRoot 'Modules\AVDTune.psm1') -Force
            foreach ($part in 'Snapshot', 'UpdateBlock', 'Readiness', 'FSLogix') { Import-Module (Join-Path $AppRoot "Modules\AVDTune.$part.psm1") -Force }
            $m = New-AVDTuneMachine
            if ($Kind -eq 'Fix') {
                if ($Gate) { Open-AVDTuneWriteGate -SnapshotId $Gate.SnapshotId -ConfirmedBy $Gate.ConfirmedBy }
                Invoke-AVDTuneReadinessFix -Machine $m -Root $Root -FixId $FixId -User $User -SnapshotId $Gate.SnapshotId
            }
            else { Invoke-AVDTuneReadiness -Machine $m -Arm (New-AVDTuneArmAdapter) -Token $Token -NoTokenReason $Reason -GalleryImageId $Gallery -FSLogixApplies $FslApplies -FSLogixTest $FslTest -Root $Root }
        }).AddArgument($script:AppRoot).AddArgument($script:StateRoot).AddArgument($Kind).AddArgument($FixId).AddArgument($tok.Token).AddArgument($tok.Reason).AddArgument($gallery).AddArgument($gate).AddArgument([string]$env:USERNAME).AddArgument((Test-FslApplies)).AddArgument((Get-AVDTuneFSLogixTestRecord -Root $script:StateRoot))
    $script:ReadyJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Kind = $Kind; FixId = $FixId; Task = (New-ReadyTask $Kind $FixId) }
    Set-ReadyBusy $true
    Update-ReadyView
}
function Complete-ReadyJob {
    $job = $script:ReadyJob
    if (-not $job) {
        if ($script:ReadyQueued -and -not ($script:TestMode -and $script:OverviewJob)) { $q = $script:ReadyQueued; $script:ReadyQueued = $null; Start-ReadyJob $q.Kind $q.FixId }
        return
    }
    if (-not $job.Inline -and -not $job.Handle.IsCompleted) { return }
    $script:ReadyJob = $null
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
    Set-ReadyBusy $false
    if ($err -or -not $result) { Complete-AVDTuneUiTask $job.Task -Failed -Summary $(if ($job.Kind -eq 'Fix') { T 'ready.err.fix' $err } else { T 'ready.err.analysis' $err }) }
    elseif ($job.Kind -eq 'Fix') { Complete-AVDTuneUiTask $job.Task -Failed:([bool]($result.Status -eq 'Failed')) -Summary "$($result.FixId): $($result.Status). $($result.Message)" }
    else { Complete-AVDTuneUiTask $job.Task -Summary (T 'ready.counts' $result.Overall $result.Counts.Red $result.Counts.Yellow $result.Counts.Unknown $result.Counts.Green) }
    if ($job.Kind -eq 'Fix') {
        if ($err -or -not $result) { Show-Error (T 'ready.err.fix' $err) }
        else {
            if (@($result.Results).Count -eq 1 -and $result.FixId -ne 'readiness.updateblock-on') { Register-StepResult $result.Results[0] }
            $text = "$($result.FixId): $($result.Status). $($result.Message)$(if ($result.Reboot) { ' A restart is needed.' })"
            [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'setup' -Subject 'Readiness fix' -Note $text)
            Save-Protocol
            Show-Toast $text
            Start-OverviewRefresh
            $script:ReadyQueued = @{ Kind = (Get-ReadyKind); FixId = '' }   # the analysis is stale after a fix
        }
    }
    elseif ($err -or -not $result) { $ui.TxtReadySummary.Text = T 'ready.err.analysis' $err; Show-Error (T 'ready.err.analysis.toast' $err) }
    else {
        $script:Ready = $result
        $gate = Get-AVDTuneWriteGate
        try { [void](Save-AVDTuneReadinessRun -Root $script:StateRoot -Result $result -Kind $job.Kind -User ([string]$env:USERNAME) -SnapshotId $(if ($gate) { [string]$gate.SnapshotId } else { '' })) }
        catch { Show-Error (T 'ready.err.store' $_.Exception.Message) }
        if ($job.Kind -ne 'Start') {
            $note = "$($result.Overall): $($result.Counts.Red) red, $($result.Counts.Yellow) yellow, $($result.Counts.Unknown) not checkable, $($result.Counts.Green) green"
            [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'setup' -Subject "Readiness analysis ($($job.Kind))" -Note $note)
            Save-Protocol
        }
    }
    $queued = $script:ReadyQueued; $script:ReadyQueued = $null
    if ($queued) { Start-ReadyJob $queued.Kind $queued.FixId } else { Update-ReadyView }
}
$script:Timer.Add_Tick({ try { Complete-ReadyJob } catch { Show-Error $_.Exception.Message } })

function Format-ReadyFamilies($Families) {
    $f = @($Families)
    if ($f.Count -eq 0) { return '' }
    $ready = @($f | Where-Object Status -eq 'ready'); $fix = @($f | Where-Object Status -eq 'after-fix'); $no = @($f | Where-Object Status -eq 'not-possible')
    $lines = @()
    if ($ready.Count -gt 0) { $lines += (T 'ready.fam.ready' $ready.Count) + (($ready | ForEach-Object { $_.Name }) -join ', ') }
    if ($fix.Count -gt 0) { $lines += (T 'ready.fam.afterfix' $fix.Count) + (($fix | ForEach-Object { $_.Name }) -join ', ') }
    if ($no.Count -gt 0) {
        $reasons = @($no | ForEach-Object { ($_.Needs | Select-Object -First 1) } | Group-Object | ForEach-Object { "$($_.Count) x $($_.Name)" })
        $lines += (T 'ready.fam.no' $no.Count) + ($reasons -join '; ')
    }
    $lines -join "`r`n"
}
function New-ReadyRow($Row) {
    $wrap = New-Object System.Windows.Controls.StackPanel
    $wrap.Margin = '0,6,0,6'
    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in 120, 230, '*', 'Auto') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$grid.ColumnDefinitions.Add($c) }
    $pair = $script:ReadyPill[[string]$Row.Status]
    $pill = New-Object System.Windows.Controls.Border
    Set-Brush $pill ([System.Windows.Controls.Border]::StyleProperty) 'Pill'
    $pill.Padding = '10,2'; $pill.VerticalAlignment = 'Top'; $pill.HorizontalAlignment = 'Left'; $pill.Margin = '0,2,0,0'
    Set-Brush $pill ([System.Windows.Controls.Border]::BackgroundProperty) $pair[0]
    $pt = New-Object System.Windows.Controls.TextBlock; $pt.Text = T "ready.pill.$([string]$Row.Status)"; $pt.FontSize = 12; $pt.FontWeight = 'SemiBold'
    Set-Brush $pt ([System.Windows.Controls.TextBlock]::ForegroundProperty) $pair[1]
    $pill.Child = $pt
    $title = New-Object System.Windows.Controls.TextBlock; $title.Text = [string]$Row.Title; $title.FontWeight = 'SemiBold'; $title.TextWrapping = 'Wrap'; $title.Margin = '0,3,10,0'; $title.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
    $reason = New-Object System.Windows.Controls.TextBlock; $reason.Text = [string]$Row.Reason; $reason.TextWrapping = 'Wrap'; $reason.Margin = '0,3,10,0'; $reason.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2)
    Set-Brush $reason ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
    $buttons = New-Object System.Windows.Controls.StackPanel; $buttons.Orientation = 'Horizontal'; $buttons.VerticalAlignment = 'Top'; $buttons.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 3)
    $safe = ([string]$Row.Id) -replace '[^A-Za-z0-9]', '_'
    if ($Row.FixId -and $Row.Status -in 'red', 'yellow') {
        $fixBtn = New-Object System.Windows.Controls.Button; $fixBtn.Content = T 'ready.fix'; $fixBtn.Margin = '0,0,6,0'; $fixBtn.Name = "BtnReadyFix_$safe"; $fixBtn.DataContext = [string]$Row.FixId
        $fixBtn.IsEnabled = (Test-AVDTuneWriteAllowed)
        if (-not $fixBtn.IsEnabled) { $fixBtn.ToolTip = T 'ready.fix.readonly' }
        [System.Windows.Automation.AutomationProperties]::SetName($fixBtn, (T 'ready.fix.name' $Row.Title))
        $fixBtn.Add_Click({ param($src) try { Start-ReadyFix ([string]$src.DataContext) } catch { Show-Error $_.Exception.Message } })
        [void]$buttons.Children.Add($fixBtn); $ui[$fixBtn.Name] = $fixBtn
    }
    $open = [bool]$script:ReadyOpen[[string]$Row.Id]
    $more = New-Object System.Windows.Controls.Button; $more.Content = $(if ($open) { T 'ready.hide' } else { T 'ready.details' }); $more.Name = "BtnReadyMore_$safe"; $more.DataContext = [string]$Row.Id
    [System.Windows.Automation.AutomationProperties]::SetName($more, (T 'ready.details.name' $Row.Title))
    $more.Add_Click({ param($src) $id = [string]$src.DataContext; $script:ReadyOpen[$id] = -not [bool]$script:ReadyOpen[$id]; Update-ReadyView })
    [void]$buttons.Children.Add($more); $ui[$more.Name] = $more
    foreach ($e in $pill, $title, $reason, $buttons) { [void]$grid.Children.Add($e) }
    [void]$wrap.Children.Add($grid)
    if ($open) {
        $lines = @()
        if ($Row.Found) { $lines += T 'ready.row.found' $Row.Found }
        if ($Row.Fix) { $lines += T 'ready.row.fix' $Row.Fix }
        $lines += T 'ready.row.source' $Row.Source $Row.Stand
        $lines += $(if ($Row.Verified) { T 'ready.row.verified' } else { T 'ready.row.unverified' })
        if ($Row.Note) { $lines += T 'ready.row.note' $Row.Note }
        $d = New-Object System.Windows.Controls.TextBlock; $d.Text = ($lines -join "`r`n"); $d.TextWrapping = 'Wrap'; $d.Margin = '120,6,0,2'; $d.FontSize = 12
        Set-Brush $d ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
        $d.Name = "TxtReadyDetail_$safe"; $ui[$d.Name] = $d
        [void]$wrap.Children.Add($d)
    }
    $wrap
}
function Update-ReadyView {
    $r = $script:Ready
    $ui.PanelReadyRows.Children.Clear()
    Update-ReadyGallery
    $finish = Get-AVDTuneFinishReadiness -Root $script:StateRoot
    $pair = if ($script:ReadyJob) { @('AccentSubtle', 'Primary') } elseif (-not $r) { @('Hover', 'MutedText') } else { $script:ReadyPill[[string]$r.Overall] }
    Set-Brush $ui.PillReady ([System.Windows.Controls.Border]::BackgroundProperty) $pair[0]
    $ui.TxtReadyPill.Text = $(if ($script:ReadyJob) { T 'ready.pill.running' } elseif (-not $r) { T 'ready.pill.notrun' } else { T "ready.pill.$([string]$r.Overall)" }); Set-Brush $ui.TxtReadyPill ([System.Windows.Controls.TextBlock]::ForegroundProperty) $pair[1]
    $ui.TxtReadyGate.Text = $(if ($finish.Allowed) { T 'ready.gate.allowed' } else { (T 'ready.gate.locked') + (@($finish.Reasons) -join ' ') })
    Set-Brush $ui.TxtReadyGate ([System.Windows.Controls.TextBlock]::ForegroundProperty) $(if ($finish.Allowed) { 'Success' } else { 'Danger' })
    $rec = Get-AVDTuneReadinessRecord -Root $script:StateRoot
    if (-not $r) {
        $ui.TxtReadySummary.Text = $(if ($script:ReadyJob) { T 'ready.analysing' } else { T 'ready.notrun' })
        $ui.TxtReadyFamilies.Text = ''
        $ui.PanelReadyAck.Visibility = 'Collapsed'
        return
    }
    $azure = if ($r.Arm.Ok) { T 'ready.azure.ok' } else { T 'ready.azure.no' $r.Arm.Problem }
    $ui.TxtReadySummary.Text = T 'ready.summary' (([datetime]$r.At).ToString('HH:mm:ss')) $r.Counts.Red $r.Counts.Yellow $r.Counts.Unknown $r.Counts.Green $r.Stand $azure
    Set-Brush $ui.TxtReadySummary ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'Text'
    $order = @{}; $i = 0; foreach ($row in $r.Rows) { $order[$row.Id] = $i++ }
    foreach ($group in 'Hardware generation', 'Image hygiene') {
        $rows = @($r.Rows | Where-Object { $_.Group -eq $group } | Sort-Object { $script:ReadyRank[[string]$_.Status] }, { $order[$_.Id] })
        if ($rows.Count -eq 0) { continue }
        [void]$ui.PanelReadyRows.Children.Add((New-UpdGroupHead $(if ($group -ceq 'Hardware generation') { T 'ready.group.hardware' } else { T 'ready.group.hygiene' })))
        foreach ($row in $rows) { [void]$ui.PanelReadyRows.Children.Add((New-ReadyRow $row)) }
    }
    $ui.TxtReadyFamilies.Text = Format-ReadyFamilies $r.Families
    $open = if ($rec) { @($rec.OpenIds) } else { @() }
    $needAck = ($rec -and [int]$rec.Red -eq 0 -and $open.Count -gt 0 -and @($open | Where-Object { $_ -notin @($rec.Acknowledged) }).Count -gt 0)
    $ui.PanelReadyAck.Visibility = ConvertTo-Vis $needAck
    if ($needAck) { $ui.TxtReadyAckHint.Text = T 'ready.ackhint' ($open -join ', ') }
}
function Start-ReadyFix([string]$FixId) {
    if (-not (Test-AVDTuneWriteAllowed)) { throw (T 'ready.err.readonly') }; Assert-NoOtherWriter
    $row = @($script:Ready.Rows | Where-Object { $_.FixId -eq $FixId } | Select-Object -First 1)
    $ask = if ($FixId -eq 'readiness.updateblock-on') { T 'ready.ask.updateblock' } else { T 'ready.ask.fix' $row[0].Title }
    if (-not (Confirm-Action $ask (T 'ready.fix'))) { return }
    Start-ReadyJob 'Fix' $FixId
}

Add-Click $ui.BtnReadyRun { Start-ReadyJob (Get-ReadyKind) '' }
Add-Click $ui.BtnReadyAck {
    $rec = Confirm-AVDTuneReadinessAcknowledgement -Root $script:StateRoot -Typed ([string]$ui.TxtReadyAck.Text) -User ([string]$env:USERNAME)
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'setup' -Subject 'Readiness: open items confirmed' -Note ((@($rec.Acknowledged)) -join ', '))
    Save-Protocol
    $ui.TxtReadyAck.Text = ''
    Show-Toast (T 'ready.toast.acked')
    Update-ReadyView
}
function Save-ReadyGallery([string]$Id) {
    $item = @($script:ReadyGalleryItems | Where-Object { $_ -and $_.Id -eq $Id } | Select-Object -First 1)
    $text = Set-AVDTuneEnvironmentGallery -Root $script:StateRoot -DefinitionId $Id -Label $(if ($item.Count -gt 0) { [string]$item[0].Label } else { '' }) -User ([string]$env:USERNAME)
    if (-not $Id -and (Test-Path -LiteralPath $script:ReadySettingsPath)) { Write-AVDTuneFile $script:ReadySettingsPath ([ordered]@{ GalleryImageId = '' } | ConvertTo-Json) }   # the older setting must not come back
    if ($text) { [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'setup' -Subject 'Readiness: image definition' -Note $text); Save-Protocol }
    Show-Toast $(if ($Id) { T 'ready.toast.saved' (Format-ReadyGalleryName $Id) } else { T 'ready.toast.cleared' })
    Start-ReadyJob 'Start' ''
}
Add-Click $ui.BtnReadyGallery {
    $id = Get-ReadyGallerySelection
    if (-not $id) { throw (T 'ready.err.choose') }
    Save-ReadyGallery $id
}
Add-Click $ui.BtnReadyGalleryClear { Save-ReadyGallery '' }
