# The "Cleanup and finish" page (dot-sourced by Start-AVDTune.ps1). Logic is in Modules\AVDTune.Finish.psm1 (issues #36, #9).
# The gate is evaluated again on the UI thread directly when the button is pressed (Test-AVDTuneFinishGate reads state.json, run records and the
# change log fresh) and once more inside Invoke-AVDTuneFinish before the journal is written. The run is a task on the task bar; the window and the
# log off stay blocked while it runs (Start-AVDTune.ps1: Add_Closing and SessionEnding look at $script:SealJob).
# Test mode: the same background runspace as in real life (like the updates), with the one fake machine of the window and the fake finish adapter made inside it.
# The write block (integrity check of the tool failed) is handed to the runspace: it imports its own module instance and would otherwise open the gate.

$script:SealJob = $null
$script:SealLast = $null
$script:SealFakeScript = $(if ($script:TestMode) { (Get-TestScript 'FakeFinish.ps1') } else { '' })
$script:SealFakeSeed = $null   # test hook: hashtable for New-AVDTuneFakeFinish

function Set-SealBusy([bool]$Busy) {
    $ui.BtnSealRun.IsEnabled = -not $Busy; $ui.BtnSealRepair.IsEnabled = -not $Busy
    $window.Cursor = $(if ($Busy) { [System.Windows.Input.Cursors]::AppStarting } else { $null })
}
function Update-SealView {
    $gate = Test-AVDTuneFinishGate -Root $script:StateRoot -Machine $script:Machine
    $crash = Get-AVDTuneFinishCrash -Root $script:StateRoot
    $state = Get-AVDTuneState $script:StateRoot
    $pair = if ($script:SealJob) { @('AccentSubtle', 'Primary', 'Running') } elseif ($crash) { @('ErrorBg', 'Danger', 'Interrupted') } elseif ([bool]$state.Sealed) { @('SuccessBg', 'Success', 'Finished') } elseif ($gate.Allowed) { @('SuccessBg', 'Success', 'Allowed') } else { @('WarningBg', 'Warning', 'Locked') }
    Set-Brush $ui.PillSeal ([System.Windows.Controls.Border]::BackgroundProperty) $pair[0]
    $ui.TxtSealPill.Text = $pair[2]; Set-Brush $ui.TxtSealPill ([System.Windows.Controls.TextBlock]::ForegroundProperty) $pair[1]
    $ui.TxtSealGate.Text = $(if ($gate.Allowed) { "Image version $($gate.Version) can be finished: the healthcheck is green or confirmed and nothing changed after it." } else { 'Locked. ' + (@($gate.Reasons) -join ' ') })
    $ui.TxtSealNotes.Text = (@($gate.Notes) -join ' ')
    $ui.BtnSealRun.IsEnabled = ($gate.Allowed -and -not $script:SealJob)
    $ui.BoxSealCrash.Visibility = ConvertTo-Vis ([bool]$crash -and -not $script:SealJob)   # a running finish has an active journal by design
    if ($crash) { $ui.TxtSealCrash.Text = "The finish of $(([datetime]$crash.Started).ToString('yyyy-MM-dd HH:mm')) (by $($crash.User)) did not end properly: AVDTune was closed or stopped in the middle. Windows Update or BITS may still be stopped. Repair starts them again as they were and writes a change log entry. A restart of the master starts the services as well." }
    if ($script:SealLast) { $ui.TxtSealResult.Text = [string]$script:SealLast }
    $ui.PanelSealSteps.Children.Clear()
    foreach ($line in 'Delete the files directly in the Windows temp folder and the error report folders (sub folders and links are not entered and are counted as skipped; a read-only file with more than one link stays; a file in use stays).', 'Empty the Windows Update download cache (Windows Update and BITS are stopped for it and started again at once).', 'Remove the downloaded benchmark tool (diskspd).', 'Update block on, no maintenance mode left.', 'Remove every token and the sign-in profiles, and check that no token is in AVDTune files (only the state folder is checked, not export locations you chose yourself).', 'Close the image version in state.json; write the run record and the change log.') {
        $t = New-Object System.Windows.Controls.TextBlock; $t.Text = [string][char]0x2022 + ' ' + $line; $t.TextWrapping = 'Wrap'; $t.Margin = '0,2,0,2'
        [void]$ui.PanelSealSteps.Children.Add($t)
    }
    $ui.TxtSealLater.Text = 'Not part of this step yet: restart first and resume, DISM component cleanup, the imaging tool and snapshot housekeeping. With "upload at the finish" on (Protocol page, change log) the change log goes to SharePoint before the finish starts.'
}
function Start-SealJob {
    foreach ($other in 'SealJob', 'UpdJob', 'BenchJob', 'ReadyJob', 'OverviewJob', 'FslJob', 'OptJob', 'OptRun') { if (Get-Variable -Scope Script -Name $other -ValueOnly -ErrorAction SilentlyContinue) { throw 'Another operation is still running.' } }
    Assert-NoOtherWriter   # the central list too (release, language, VDI, Office, software jobs, #49)
    if ($script:SignInBusy) { throw 'A sign-in is running: start the finish when it is done.' }   # the finish uses its session (#49)
    # the gate again, directly before the first write, on the UI thread (a change between display and click blocks here)
    $gate = Test-AVDTuneFinishGate -Root $script:StateRoot -Machine $script:Machine
    if (-not $gate.Allowed) { Update-SealView; throw "The finish is not allowed: $(@($gate.Reasons) -join ' ')" }
    $wg = Get-AVDTuneWriteGate
    $task = Start-AVDTuneUiTask -Kind 'finish' -Title 'Cleanup and finish' -Step 'Starting'
    $sync = [hashtable]::Synchronized(@{ Text = ''; Percent = 0 })
    $ps = New-AVDTunePowerShell
    [void]$ps.AddScript({
            param($AppRoot, $Root, $Gate, $User, $Ctx, $Sync, $Block, $FakeMachineScript, $FakeFinishScript, $FakeSeed, $SharedMachine)
            $ErrorActionPreference = 'Stop'
            Import-Module (Join-Path $AppRoot 'Modules\AVDTune.psm1') -Force
            foreach ($part in 'Trust', 'Session', 'Snapshot', 'UpdateBlock', 'Readiness', 'Finish') { Import-Module (Join-Path $AppRoot "Modules\AVDTune.$part.psm1") -Force }
            if ($FakeMachineScript) {
                . $FakeMachineScript; . $FakeFinishScript
                $m = $SharedMachine; if (-not $m) { $m = New-AVDTuneFakeMachine -Seed @{} }
                $fin = New-AVDTuneFakeFinish -Seed $(if ($FakeSeed) { $FakeSeed } else { @{} })
            }
            else { $m = New-AVDTuneMachine; $fin = New-AVDTuneFinishAdapter -Root $Root }
            if ($Block) { Set-AVDTuneWriteBlock $Block } elseif ($Gate) { Open-AVDTuneWriteGate -SnapshotId $Gate.SnapshotId -ConfirmedBy $Gate.ConfirmedBy }
            # the CURRENT sign-in session of the window, read each time (a new sign-in replaces the object in the context)
            Invoke-AVDTuneFinish -Machine $m -Fin $fin -Root $Root -User $User -SnapshotId $Gate.SnapshotId -SessionProvider { $Ctx.Session } -Progress { param($t, $p) $Sync.Text = $t; $Sync.Percent = $p }
        }).AddArgument($script:AppRoot).AddArgument($script:StateRoot).AddArgument($wg).AddArgument([string]$env:USERNAME).AddArgument($script:StartContext).AddArgument($sync).AddArgument((Get-AVDTuneWriteBlock)).AddArgument($(if ($script:TestMode) { $script:TestInfo.FakeScript } else { '' })).AddArgument($script:SealFakeScript).AddArgument($script:SealFakeSeed).AddArgument($(if ($script:TestMode) { $script:Machine } else { $null }))
    $script:SealJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Sync = $sync; Task = $task }
    Set-ShutdownBlock $true; Set-SealBusy $true
}

# #46: the end action after a successful finish (ComboBox CmbSealEnd): asked first, the protocol is written before; shutdown.exe through the engine (full path, Authenticode).
# Test mode: the start is recorded in SealEndRan instead (the developer's machine is never signed out or shut down).
$script:SealEndRan = $null
function Invoke-SealEndAction {
    $action = @('None', 'LogOff', 'Shutdown')[[Math]::Max(0, $ui.CmbSealEnd.SelectedIndex)]
    if ($action -eq 'None') { return }
    $v = [string](Get-AVDTuneState $script:StateRoot).ImageVersion
    if (-not (Confirm-Action (T $(if ($action -eq 'LogOff') { 'seal.end.ask.logoff' } else { 'seal.end.ask.shutdown' }) $v) 'AVDTune')) { return }
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'seal' -Subject $(if ($action -eq 'LogOff') { "Sign out after the finish of $v" } else { "Shut down after the finish of $v" })); Save-Protocol
    $runner = if ($script:TestMode) { { param($File, $Arguments) $script:SealEndRan = @{ File = $File; Arguments = @($Arguments) }; [pscustomobject]@{ ExitCode = 0; Output = '' } } } else { $null }
    try { if ($runner) { [void](Invoke-AVDTuneFinishEndAction -Action $action -Root $script:StateRoot -Runner $runner) } else { [void](Invoke-AVDTuneFinishEndAction -Action $action -Root $script:StateRoot) } }
    catch { $why = T 'seal.end.failed' $_.Exception.Message; [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'seal' -Subject $why); Save-Protocol; Show-Error $why }
}
function Complete-SealJob {
    $job = $script:SealJob
    if (-not $job) { return }
    if (-not $job.Handle.IsCompleted) { Update-AVDTuneUiTask $job.Task -Step ([string]$job.Sync.Text) -Percent ([int]$job.Sync.Percent); return }
    $script:SealJob = $null
    Set-ShutdownBlock $false
    $result = $null; $err = ''
    try { $out = @($job.PS.EndInvoke($job.Handle)); if ($job.PS.Streams.Error.Count -gt 0) { $err = $job.PS.Streams.Error[0].Exception.Message }; $result = $out | Select-Object -Last 1 }
    catch { $err = $_.Exception.Message }
    finally { $job.PS.Dispose() }
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
    if (-not $failed) { Invoke-SealEndAction }   # #46: sign out or shut down, as chosen, after asking
    if ($script:CloseWhenDone -and -not $script:SealJob -and -not $script:UpdJob -and -not $script:BenchJob) { if ($failed) { $script:CloseWhenDone = $false } else { $window.Close() } }
}
$script:Timer.Add_Tick({ try { Complete-SealJob } catch { Show-Error $_.Exception.Message } })

Add-Click $ui.BtnSealRun {
    $gate = Test-AVDTuneFinishGate -Root $script:StateRoot -Machine $script:Machine
    if (-not $gate.Allowed) { Update-SealView; throw "The finish is not allowed: $(@($gate.Reasons) -join ' ')" }
    if (-not (Confirm-Action (Get-AVDTuneFinishConfirmText -Root $script:StateRoot) 'Finish')) { return }
    # #89: with the option on, the change log goes to SharePoint first, while the sign-in is still there (the finish removes the tokens); then the finish
    if (Test-SpUploadAtFinish) { Start-SpJob 'ChangeLog' { Start-SealJob }; return }
    Start-SealJob
}
Add-Click $ui.BtnSealRepair {
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot of today on the Overview first.' }; Assert-NoOtherWriter -AllowSealed   # the repair puts back what a crash left lifted, also after the version was closed (#50)
    $hold = Enter-AVDTuneWriter -Kind 'finish-repair' -Title 'Repairing the finish' -AllowSealed   # the central lock (#49) while the repair writes
    try { $r = Repair-AVDTuneFinishCrash -Machine $script:Machine -Root $script:StateRoot -User ([string]$env:USERNAME) } finally { Exit-AVDTuneWriter $hold }
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'seal' -Subject 'Finish repaired' -Note $r.Message); Save-Protocol
    Show-Toast $r.Message
    Update-SealView
}
