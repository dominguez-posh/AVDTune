# The "Cleanup and finish" page (dot-sourced by Start-AVDTune.ps1). Logic is in Modules\AVDTune.Finish.psm1 (issues #36, #9).
# The gate is evaluated again on the UI thread directly when the button is pressed (Test-AVDTuneFinishGate reads state.json, run records and the
# change log fresh) and once more inside Invoke-AVDTuneFinish before the journal is written. The run is a task on the task bar; the window and the
# log off stay blocked while it runs (Start-AVDTune.ps1: Add_Closing and SessionEnding look at $script:SealJob).
# Test mode: the run is inline on the UI thread with the fake machine and the fake finish adapter (the fakes are closures of this runspace).

$script:SealJob = $null
$script:SealLast = $null
$script:SealFakeScript = $(if ($script:TestMode) { (Get-TestScript 'FakeFinish.ps1') } else { '' })
$script:SealFakeSeed = $null   # test hook: hashtable for New-AVDTuneFakeFinish

function Get-SealAdapter {
    if ($script:TestMode) { . $script:SealFakeScript; return (New-AVDTuneFakeFinish -Seed $(if ($script:SealFakeSeed) { $script:SealFakeSeed } else { @{} })) }
    New-AVDTuneFinishAdapter -Root $script:StateRoot
}
function Set-SealBusy([bool]$Busy) {
    $ui.BtnSealRun.IsEnabled = -not $Busy; $ui.BtnSealRepair.IsEnabled = -not $Busy
    $window.Cursor = $(if ($Busy) { [System.Windows.Input.Cursors]::AppStarting } else { $null })
}
function Update-SealView {
    $gate = Test-AVDTuneFinishGate -Root $script:StateRoot
    $crash = Get-AVDTuneFinishCrash -Root $script:StateRoot
    $state = Get-AVDTuneState $script:StateRoot
    $pair = if ($script:SealJob) { @('AccentSubtle', 'Primary', 'Running') } elseif ($crash) { @('ErrorBg', 'Danger', 'Interrupted') } elseif ([bool]$state.Sealed) { @('SuccessBg', 'Success', 'Finished') } elseif ($gate.Allowed) { @('SuccessBg', 'Success', 'Allowed') } else { @('WarningBg', 'Warning', 'Locked') }
    Set-Brush $ui.PillSeal ([System.Windows.Controls.Border]::BackgroundProperty) $pair[0]
    $ui.TxtSealPill.Text = $pair[2]; Set-Brush $ui.TxtSealPill ([System.Windows.Controls.TextBlock]::ForegroundProperty) $pair[1]
    $ui.TxtSealGate.Text = $(if ($gate.Allowed) { "Image version $($gate.Version) can be finished: the healthcheck is green or confirmed and nothing changed after it." } else { 'Locked. ' + (@($gate.Reasons) -join ' ') })
    $ui.TxtSealNotes.Text = (@($gate.Notes) -join ' ')
    $ui.BtnSealRun.IsEnabled = ($gate.Allowed -and -not $script:SealJob)
    $ui.BoxSealCrash.Visibility = ConvertTo-Vis ([bool]$crash)
    if ($crash) { $ui.TxtSealCrash.Text = "The finish of $(([datetime]$crash.Started).ToString('yyyy-MM-dd HH:mm')) (by $($crash.User)) did not end properly: AVDTune was closed or stopped in the middle. Windows Update or BITS may still be stopped. Repair starts them again as they were and writes a change log entry." }
    if ($script:SealLast) { $ui.TxtSealResult.Text = [string]$script:SealLast }
    $ui.PanelSealSteps.Children.Clear()
    foreach ($line in 'Empty the Windows temp folder and the error reports (contents only, links are never followed, a file in use stays).', 'Empty the Windows Update download cache (Windows Update and BITS are stopped for it and started again at once).', 'Remove the downloaded benchmark tool (diskspd).', 'Update block on, no maintenance mode left.', 'Remove every token and the sign-in profiles, and check that no token is in AVDTune files.', 'Close the image version in state.json; write the run record and the change log.') {
        $t = New-Object System.Windows.Controls.TextBlock; $t.Text = [string][char]0x2022 + ' ' + $line; $t.TextWrapping = 'Wrap'; $t.Margin = '0,2,0,2'
        [void]$ui.PanelSealSteps.Children.Add($t)
    }
    $ui.TxtSealLater.Text = 'Not part of this step yet: restart first and resume, DISM component cleanup, sending the change log to SharePoint, log off or shut down, the imaging tool and snapshot housekeeping.'
}
function Start-SealJob {
    if ($script:SealJob -or $script:UpdJob -or $script:BenchJob) { throw 'Another operation is still running.' }
    # the gate again, directly before the first write, on the UI thread (a change between display and click blocks here)
    $gate = Test-AVDTuneFinishGate -Root $script:StateRoot
    if (-not $gate.Allowed) { Update-SealView; throw "The finish is not allowed: $(@($gate.Reasons) -join ' ')" }
    $wg = Get-AVDTuneWriteGate
    $task = Start-AVDTuneUiTask -Kind 'finish' -Title 'Cleanup and finish' -Step 'Starting'
    $session = $script:StartContext.Session
    if ($script:TestMode) {
        $res = $null; $err = ''
        try { $res = Invoke-AVDTuneFinish -Machine $script:Machine -Fin (Get-SealAdapter) -Root $script:StateRoot -User ([string]$env:USERNAME) -SnapshotId ([string]$wg.SnapshotId) -Session $session -Progress { param($t, $p) Update-AVDTuneUiTask $task -Step $t -Percent $p } }
        catch { $err = $_.Exception.Message }
        $script:SealJob = @{ Inline = $true; Result = $res; Err = $err; Task = $task }
        Set-ShutdownBlock $true; Set-SealBusy $true
        return
    }
    $sync = [hashtable]::Synchronized(@{ Text = ''; Percent = 0 })
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param($AppRoot, $Root, $Gate, $User, $Session, $Sync)
            $ErrorActionPreference = 'Stop'
            Import-Module (Join-Path $AppRoot 'Modules\AVDTune.psm1') -Force
            foreach ($part in 'Trust', 'Session', 'Snapshot', 'UpdateBlock', 'Readiness', 'Finish') { Import-Module (Join-Path $AppRoot "Modules\AVDTune.$part.psm1") -Force }
            if ($Gate) { Open-AVDTuneWriteGate -SnapshotId $Gate.SnapshotId -ConfirmedBy $Gate.ConfirmedBy }
            Invoke-AVDTuneFinish -Machine (New-AVDTuneMachine) -Fin (New-AVDTuneFinishAdapter -Root $Root) -Root $Root -User $User -SnapshotId $Gate.SnapshotId -Session $Session -Progress { param($t, $p) $Sync.Text = $t; $Sync.Percent = $p }
        }).AddArgument($script:AppRoot).AddArgument($script:StateRoot).AddArgument($wg).AddArgument([string]$env:USERNAME).AddArgument($session).AddArgument($sync)
    $script:SealJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Sync = $sync; Task = $task }
    Set-ShutdownBlock $true; Set-SealBusy $true
}
function Complete-SealJob {
    $job = $script:SealJob
    if (-not $job) { return }
    if (-not $job.Inline -and -not $job.Handle.IsCompleted) { Update-AVDTuneUiTask $job.Task -Step ([string]$job.Sync.Text) -Percent ([int]$job.Sync.Percent); return }
    $script:SealJob = $null
    Set-ShutdownBlock $false
    $result = $null; $err = ''
    if ($job.Inline) { $result = $job.Result; $err = [string]$job.Err }
    else {
        try { $out = @($job.PS.EndInvoke($job.Handle)); if ($job.PS.Streams.Error.Count -gt 0) { $err = $job.PS.Streams.Error[0].Exception.Message }; $result = $out | Select-Object -Last 1 }
        catch { $err = $_.Exception.Message }
        finally { $job.PS.Dispose() }
    }
    Set-SealBusy $false
    $failed = [bool]($err -or -not $result -or $result.Status -ne 'Finished')
    $text = if ($err -and -not $result) { "The finish stopped: $err" } elseif ($result) { [string]$result.Message } else { 'The finish returned no result.' }
    $script:SealLast = $text
    if ($result) { foreach ($r in $result.Results) { Register-StepResult $r } }
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'seal' -Subject 'Cleanup and finish' -Note $text)
    Save-Protocol
    Show-Toast $text
    if (-not $failed) { try { Update-StartView } catch { } }
    Update-SealView; Start-OverviewRefresh
    Complete-AVDTuneUiTask $job.Task -Failed:$failed -Summary $text
    if ($script:CloseWhenDone -and -not $script:SealJob -and -not $script:UpdJob -and -not $script:BenchJob) { if ($failed) { $script:CloseWhenDone = $false } else { $window.Close() } }
}
$script:Timer.Add_Tick({ try { Complete-SealJob } catch { Show-Error $_.Exception.Message } })

Add-Click $ui.BtnSealRun {
    $gate = Test-AVDTuneFinishGate -Root $script:StateRoot
    if (-not $gate.Allowed) { Update-SealView; throw "The finish is not allowed: $(@($gate.Reasons) -join ' ')" }
    if (-not (Confirm-Action (Get-AVDTuneFinishConfirmText -Root $script:StateRoot) 'Finish')) { return }
    Start-SealJob
}
Add-Click $ui.BtnSealRepair {
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot of today on the Overview first.' }
    $r = Repair-AVDTuneFinishCrash -Machine $script:Machine -Root $script:StateRoot -User ([string]$env:USERNAME)
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'seal' -Subject 'Finish repaired' -Note $r.Message); Save-Protocol
    Show-Toast $r.Message
    Update-SealView
}
