# The cards "Export" and "Old snapshots" of the Protocol page (dot-sourced by Start-AVDTune.ps1 after the SharePoint card; plan phase 7 and 7a, issue #91).
# Logic: Modules\AVDTune.Export.psm1 (the ZIP) and Modules\AVDTune.Snapshot.psm1 (gallery versions, the housekeeping plan and the deletion).
# Export: read only for the master, a call on the window thread (a task on the bar); the ZIP goes to <state>\exports or a file the administrator chooses.
# Old snapshots: "Read" lists the snapshots of the OS disk with the reason why each one stays or may go, and records new gallery versions (made by the imaging
# tool) in the change log; "Delete" asks with the list of names and deletes only those, as a writer (Enter-AVDTuneWriter, not after the finish) with the open
# snapshot gate. Every text comes from the language files (T 'exp.*'). Test mode: the fake ARM of the start sequence and the window's fake machine.

$script:ExpUiBuilt = $false
$script:ExpLast = ''
$script:SnapPlan = @()
$script:SnapLast = ''

function Get-ExpComparison {
    # the benchmark comparison per image version and its CSV/JSON text; nothing when there is no result (the export goes on without it)
    try {
        $c = Get-AVDTuneBenchmarkVersionComparison -Root $script:StateRoot
        if (@($c.Rows).Count -eq 0) { return $null }
        [pscustomobject]@{ Comparison = $c; Csv = (ConvertTo-AVDTuneBenchmarkComparisonText -Comparison $c -Format Csv); Json = (ConvertTo-AVDTuneBenchmarkComparisonText -Comparison $c -Format Json) }
    }
    catch { $null }
}

function Invoke-ExpExport {
    $folder = Get-AVDTuneExportFolder -Root $script:StateRoot
    $name = Get-AVDTuneExportFileName -Version ([string](Get-AVDTuneState $script:StateRoot).ImageVersion)
    $target = Join-Path $folder $name
    if (-not $script:TestMode) {
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Title = T 'exp.dlg'; $dlg.Filter = 'ZIP (*.zip)|*.zip'; $dlg.InitialDirectory = $folder; $dlg.FileName = $name
        if (-not $dlg.ShowDialog()) { return }
        $target = $dlg.FileName
    }
    $r = Invoke-UiTaskInline -Kind 'export' -Title (T 'exp.task') -Step (T 'exp.task.step') -Block {
        $cmp = Get-ExpComparison
        $rec = $null; try { $rec = (Get-AVDTuneRecordedApps -Root $script:StateRoot).Apps } catch { }
        $ex = Get-AVDTuneExportEntries -Root $script:StateRoot -Machine $script:Machine -Recorded $rec -Comparison $(if ($cmp) { $cmp.Comparison }) -ComparisonCsv $(if ($cmp) { $cmp.Csv }) -ComparisonJson $(if ($cmp) { $cmp.Json }) -Computer ([string](& $script:Machine.ComputerName))
        Export-AVDTuneBundle -Export $ex -Path $target
    }
    $script:ExpLast = T 'exp.done' $r.Path $r.Files $(if (@($r.Skipped).Count) { (@($r.Skipped) | ForEach-Object { Remove-PackTuneProtocolSecrets $_ 200 }) -join '; ' } else { '-' })
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'other' -Subject (T 'exp.protocol' $r.Path $r.Sha256))
    Save-Protocol
    if (-not $r.FolderAdminOnly) { $script:ExpLast += ' ' + (T 'exp.warn.acl' ([IO.Path]::GetDirectoryName($r.Path))) }
    Show-Toast $(if ($r.FolderAdminOnly) { T 'exp.toast' $r.Path } else { T 'exp.warn.acl' ([IO.Path]::GetDirectoryName($r.Path)) })
    Update-ExpView
}

# ---------------------------------------------------------------- old snapshots
function Get-SnapGallery { $e = $null; try { $e = Get-AVDTuneEnvironment $script:StateRoot } catch { }; if ($e) { Get-AVDTuneEnvironmentGallery $e } else { '' } }
function Get-SnapNamePattern { $p = ''; try { $p = [string](Get-AVDTuneEnvironmentAnswers (Get-AVDTuneEnvironment $script:StateRoot)).SnapshotNamePattern } catch { }; if ($p) { $p } else { Get-AVDTuneDefaultSnapshotNamePattern } }
function Read-SnapSettingsBox {
    $k = 0; $d = 0
    if (-not [int]::TryParse(([string]$ui.TxtSnapKeep.Text).Trim(), [ref]$k) -or $k -lt 1 -or $k -gt 50) { throw (T 'exp.snap.err.keep') }
    if (-not [int]::TryParse(([string]$ui.TxtSnapDays.Text).Trim(), [ref]$d) -or $d -lt 0 -or $d -gt 3650) { throw (T 'exp.snap.err.days') }
    Set-AVDTuneSnapshotCleanupSettings -Root $script:StateRoot -Keep $k -MinAgeDays $d
}

function Invoke-SnapRead {
    $settings = Read-SnapSettingsBox
    $vm = Get-AVDTuneVmIdentity $script:Machine
    if (-not $vm.Available) { throw $vm.Problem }
    $def = Get-SnapGallery
    $out = Invoke-UiTaskInline -Kind 'snapshot-read' -Title (T 'exp.snap.task.read') -Step (T 'exp.snap.task.read') -Block {
        $token = Get-ArmToken
        $snaps = @(Get-AVDTuneOsDiskSnapshots -Arm (Get-StartArm) -Token $token -Vm $vm)
        $gv = @(); $gp = ''
        if ($def) { try { $gv = @(Get-AVDTuneGalleryVersions -Arm (Get-StartArm) -Token $token -DefinitionId $def) } catch { $gp = $_.Exception.Message } } else { $gp = T 'exp.snap.nogallery' }
        $token = $null
        $new = @(); if ($gv.Count) { $new = @(Add-AVDTuneGalleryVersionEntries -Root $script:StateRoot -GalleryVersions $gv -User ([string]$env:USERNAME)) }
        $gate = Get-AVDTuneWriteGate
        $plan = @(Get-AVDTuneSnapshotCleanupPlan -Snapshots $snaps -State (Get-AVDTuneState $script:StateRoot) -GalleryVersions $gv -GalleryProblem $gp -Keep $settings.Keep -MinAgeDays $settings.MinAgeDays -NamePattern (Get-SnapNamePattern) -OsDiskName $vm.OsDiskName -VmName $vm.VmName -GateSnapshotId $(if ($gate) { [string]$gate.SnapshotId }))
        [pscustomobject]@{ Plan = $plan; Gallery = $gv; GalleryProblem = $gp; New = $new }
    }
    $script:SnapPlan = @($out.Plan)
    $script:SnapLast = T 'exp.snap.read' @($out.Plan).Count @($out.Plan | Where-Object Delete).Count $(if (@($out.Gallery).Count) { $out.Gallery[0].Name } else { '-' }) @($out.New).Count
    if ($out.GalleryProblem) { $script:SnapLast += ' ' + (T 'exp.snap.galleryproblem' (Remove-PackTuneProtocolSecrets $out.GalleryProblem 300)) }
    foreach ($n in @($out.New)) { [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'other' -Subject (T 'exp.snap.gallerynote' $n.Component $n.Version)) }
    if (@($out.New).Count) { Save-Protocol }
    Update-ExpView
}

function Invoke-SnapDelete {
    $names = @($script:SnapPlan | Where-Object Delete | ForEach-Object Name)
    if ($names.Count -eq 0) { Show-Toast (T 'exp.snap.none'); return }
    if (-not (Test-AVDTuneWriteAllowed)) { throw (T 'exp.snap.err.gate') }
    if (-not (Confirm-Action (T 'exp.snap.ask' $names.Count ($names -join "`n")) (T 'exp.snap.title.ask'))) { return }
    $settings = Read-SnapSettingsBox
    $vm = Get-AVDTuneVmIdentity $script:Machine
    $def = Get-SnapGallery
    $hold = Enter-AVDTuneWriter -Kind 'SnapshotCleanup' -Title (T 'exp.snap.task.delete')
    try {
        $r = Invoke-UiTaskInline -Kind 'snapshot-delete' -Title (T 'exp.snap.task.delete') -Step (T 'exp.snap.task.delete') -Block {
            $token = Get-ArmToken
            try { Remove-AVDTuneOldSnapshots -Arm (Get-StartArm) -Token $token -Vm $vm -Root $script:StateRoot -ConfirmedNames $names -GalleryDefinitionId $def -Keep $settings.Keep -MinAgeDays $settings.MinAgeDays -NamePattern (Get-SnapNamePattern) -User ([string]$env:USERNAME) }
            finally { $token = $null }
        }
    }
    finally { Exit-AVDTuneWriter $hold }
    $script:SnapLast = T 'exp.snap.deleted' @($r.Deleted).Count $(if (@($r.Failed).Count) { (@($r.Failed) | ForEach-Object { Remove-PackTuneProtocolSecrets $_ 300 }) -join ' ' } else { '-' })
    [void](Add-PackTuneProtocolAction -Protocol $script:Protocol -Category 'other' -Subject (T 'exp.snap.protocol' @($r.Deleted).Count) -Result $(if (@($r.Failed).Count) { 'failed' } else { 'ok' }) -Note (Remove-PackTuneProtocolSecrets ((@($r.Deleted) + @($r.Failed)) -join '; ') 400))
    Save-Protocol
    Show-Toast $script:SnapLast
    $script:SnapPlan = @()
    Update-ExpView
}

# ---------------------------------------------------------------- the cards
function Build-ExpCards {
    if ($script:ExpUiBuilt) { return }
    $grid = New-Object System.Windows.Controls.Grid; $grid.Margin = '0,0,0,18'
    foreach ($w in '*', '16', '*') { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$grid.ColumnDefinitions.Add($cd) }
    # export
    $e = New-MaskCard (T 'exp.title') (T 'exp.hint')
    $ui.BtnExport = New-MaskButton (T 'exp.btn') (T 'exp.btn') $true; $ui.BtnExport.Margin = '0,10,0,0'; $ui.BtnExport.HorizontalAlignment = 'Left'
    [void]$e.Panel.Children.Add($ui.BtnExport)
    $ui.TxtExpState = New-MaskText '' 'Hint' '0,8,0,0'; [void]$e.Panel.Children.Add($ui.TxtExpState)
    [void]$grid.Children.Add($e.Card)
    # old snapshots
    $s = New-MaskCard (T 'exp.snap.title') (T 'exp.snap.hint')
    $row = New-Object System.Windows.Controls.WrapPanel; $row.Margin = '0,8,0,0'
    $ui.TxtSnapKeep = New-Object System.Windows.Controls.TextBox; $ui.TxtSnapKeep.Width = 50; $ui.TxtSnapKeep.Padding = '6,4'; $ui.TxtSnapKeep.MaxLength = 2
    $ui.TxtSnapDays = New-Object System.Windows.Controls.TextBox; $ui.TxtSnapDays.Width = 60; $ui.TxtSnapDays.Padding = '6,4'; $ui.TxtSnapDays.MaxLength = 4
    [System.Windows.Automation.AutomationProperties]::SetName($ui.TxtSnapKeep, (T 'exp.snap.keep')); [System.Windows.Automation.AutomationProperties]::SetName($ui.TxtSnapDays, (T 'exp.snap.days'))
    foreach ($pair in @(@((T 'exp.snap.keep'), $ui.TxtSnapKeep), @((T 'exp.snap.days'), $ui.TxtSnapDays))) {
        $l = New-MaskText $pair[0] '' '0,0,6,6'; $l.VerticalAlignment = 'Center'; $pair[1].Margin = '0,0,16,6'
        [void]$row.Children.Add($l); [void]$row.Children.Add($pair[1])
    }
    [void]$s.Panel.Children.Add($row)
    $btns = New-Object System.Windows.Controls.WrapPanel
    $ui.BtnSnapRead = New-MaskButton (T 'exp.snap.btn.read') (T 'exp.snap.btn.read')
    $ui.BtnSnapDelete = New-MaskButton (T 'exp.snap.btn.delete') (T 'exp.snap.btn.delete')
    foreach ($b in $ui.BtnSnapRead, $ui.BtnSnapDelete) { $b.Margin = '0,0,8,6'; [void]$btns.Children.Add($b) }
    [void]$s.Panel.Children.Add($btns)
    $ui.TxtSnapList = New-MaskText '' '' '0,6,0,0'; $ui.TxtSnapList.FontFamily = 'Cascadia Mono, Consolas'; $ui.TxtSnapList.FontSize = 12
    [void]$s.Panel.Children.Add($ui.TxtSnapList)
    $ui.TxtSnapState = New-MaskText '' 'Hint' '0,6,0,0'; [void]$s.Panel.Children.Add($ui.TxtSnapState)
    $s.Card.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2)
    [void]$grid.Children.Add($s.Card)
    foreach ($c in $e.Card, $s.Card) { $c.Margin = '0' }
    $ui.HostExport.Content = $grid
    Add-Click $ui.BtnExport { Invoke-ExpExport }
    Add-Click $ui.BtnSnapRead { Invoke-SnapRead }
    Add-Click $ui.BtnSnapDelete { Invoke-SnapDelete }
    $cfg = Get-AVDTuneSnapshotCleanupSettings -Root $script:StateRoot
    $ui.TxtSnapKeep.Text = [string]$cfg.Keep; $ui.TxtSnapDays.Text = [string]$cfg.MinAgeDays
    $script:ExpUiBuilt = $true
}

function Update-ExpView {
    if (-not $script:ExpUiBuilt) { return }
    $ui.TxtExpState.Text = $(if ($script:ExpLast) { $script:ExpLast } else { T 'exp.state' (Join-Path $script:StateRoot 'exports') })
    $lines = foreach ($r in @($script:SnapPlan)) {
        $when = if ($r.Created) { ([datetime]$r.Created).ToString('yyyy-MM-dd') } else { '----------' }
        "$(if ($r.Delete) { '[x]' } else { '[ ]' }) $($r.Name)  $when  $(if ($r.ImageVersion) { $r.ImageVersion } else { '-' })`r`n      $($r.Reason)"
    }
    $ui.TxtSnapList.Text = $(if (@($script:SnapPlan).Count) { $lines -join "`r`n" } else { T 'exp.snap.notread' })
    $ui.TxtSnapState.Text = $(if ($script:SnapLast) { $script:SnapLast } elseif (-not (Test-AVDTuneWriteAllowed)) { T 'exp.snap.err.gate' } else { '' })
    $ui.BtnSnapDelete.IsEnabled = [bool](@($script:SnapPlan | Where-Object Delete).Count -gt 0 -and (Test-AVDTuneWriteAllowed) -and -not (Test-AVDTuneSealed -Root $script:StateRoot))
}

function Show-ExportCard([bool]$Visible) {
    # called by Update-ProtocolView: the cards belong to the change log view
    $ui.HostExport.Visibility = ConvertTo-Vis $Visible
    if (-not $Visible) { return }
    Build-ExpCards
    Update-ExpView
}
$script:ExpReady = $true
