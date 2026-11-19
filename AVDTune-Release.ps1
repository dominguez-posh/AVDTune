# The "Integrity and updates" card on the Overview (dot-sourced by Start-AVDTune.ps1). Logic is in Modules\AVDTune.Release.psm1; this file shows the result of
# the integrity check, starts the work (check at start, update check, install, repair, back to the previous version) in a background runspace and polls it
# with the window timer. Nothing here installs by itself: install, repair and back run only on a click and after a confirmation.
# A failed integrity check sets the write block of the engine (Modules\AVDTune.psm1): the write gate stays shut and AVDTune is read only until it is repaired
# and started again. Test mode: fake HTTP adapter (Tests\Fakes\FakeRelease.ps1) and an install folder inside the test state, never GitHub or Program Files.

$script:Rel = @{ ComputerName = [string](& $script:Machine.ComputerName); Status = $null; Latest = $null; CheckError = ''; Restart = ''; Info = $null }
$script:RelJob = $null   # the release job: a writer for install, repair and back (AVDTune-Tasks.ps1 WriterJobVariables, #49)
$script:RelFakeHttp = $null   # test hook: a fake HTTP adapter for the smoke driver
$script:RelInstallRoot = $(if ($script:TestMode) { Join-Path $script:StateRoot 'install-test' } else { Get-AVDTuneInstallRoot })
$script:RelPill = @{   # the text of a pill is rel.pill.<key>
    ok = @('SuccessBg', 'Success'); bad = @('ErrorBg', 'Danger'); dev = @('Hover', 'Text'); unprotected = @('WarningBg', 'Warning')
    unverified = @('WarningBg', 'Warning'); running = @('Hover', 'MutedText'); failed = @('ErrorBg', 'Danger')
}
if ($script:TestMode) { . (Get-TestScript 'FakeRelease.ps1') }

# Until the check has run, everything but the test mode's development copy is read only (the check is in the background and takes a moment)
$script:Rel.Info = Get-AVDTuneInstallInfo -AppRoot $script:AppRoot -InstallRoot $script:RelInstallRoot -AllowDevelopment:$script:TestMode
if ($script:Rel.Info.Mode -ne 'Development') { Set-AVDTuneWriteBlock 'the integrity check of the tool is still running.' }

function Get-RelHttp {
    if (-not $script:TestMode) { return $null }   # the runspace creates the real adapter itself
    if ($script:RelFakeHttp) { return $script:RelFakeHttp }
    $h = New-AVDTuneFakeReleaseHttp
    $h.Store.Text[(Get-AVDTuneReleaseFeedUrl)] = New-AVDTuneFakeFeed @('0.9.0')
    $m = [ordered]@{ Schema = 1; Product = 'AVDTune'; Version = '0.9.0'; Commit = ('a' * 40); Date = '2026-11-20T10:00:00Z'; Prerelease = $false; Notes = "- Demo release notes (test mode)"
        Zip = [ordered]@{ Name = 'AVDTune-0.9.0.zip'; Size = 1000; Sha256 = ('b' * 64) }
        Files = @([ordered]@{ Path = 'Start-AVDTune.ps1'; Size = 1; Sha256 = ('c' * 64) }, [ordered]@{ Path = 'VERSION'; Size = 6; Sha256 = ('d' * 64) }) }
    $h.Store.Text[(Get-AVDTuneReleaseUrl -Version '0.9.0' -Name 'manifest.json')] = ($m | ConvertTo-Json -Depth 5)
    $script:RelFakeHttp = $h
    $h
}

$script:RelWork = {
    param($C)
    $ErrorActionPreference = 'Stop'
    if ($C.Import) { Import-Module (Join-Path $C.AppRoot 'Modules\AVDTune.psm1') -Force; Import-Module (Join-Path $C.AppRoot 'Modules\AVDTune.Release.psm1') -Force }
    $h = if ($C.Http) { $C.Http } else { New-AVDTuneReleaseHttp }
    $out = @{ Kind = $C.Kind; Error = '' }
    if ($C.Kind -in 'Start') {
        try { $out.Status = Get-AVDTuneIntegrityStatus -AppRoot $C.AppRoot -InstallRoot $C.InstallRoot -StateRoot $C.StateRoot -Http $h -AllowDevelopment:$C.AllowDev } catch { $out.Error = $_.Exception.Message }
    }
    if ($C.Kind -in 'Start', 'Check') {
        try { $out.Latest = Get-AVDTuneLatestRelease -Http $h -CurrentVersion $C.Version -EarlyAccess:$C.EarlyAccess } catch { $out.CheckError = $_.Exception.Message }
    }
    elseif ($C.Kind -eq 'Install') {
        $m = Get-AVDTuneReleaseManifest -Http $h -Version $C.Argument -StateRoot $C.StateRoot
        if ($m.Source -ne 'github') { throw "The manifest of version $($C.Argument) could not be loaded from GitHub: $($m.Error)" }
        $out.Result = Install-AVDTuneRelease -Http $h -Manifest $m.Manifest -InstallRoot $C.InstallRoot -StateRoot $C.StateRoot -User $C.User -RunActive:$C.RunActive -RunningVersion $C.Version
    }
    elseif ($C.Kind -eq 'Back') { $out.Result = Undo-AVDTuneRelease -InstallRoot $C.InstallRoot -StateRoot $C.StateRoot -User $C.User -RunActive:$C.RunActive }
    elseif ($C.Kind -eq 'Repair') { $out.Result = Repair-AVDTuneInstall -Http $h -AppRoot $C.AppRoot -InstallRoot $C.InstallRoot -StateRoot $C.StateRoot -User $C.User -RunActive:$C.RunActive }
    [pscustomobject]$out
}

function Test-RelRunActive { [bool](Get-AVDTuneRunningWriter) }   # the central check of AVDTune-Tasks.ps1 (#49): every job that changes the master

function Set-RelBusy([bool]$Busy) {
    foreach ($b in $ui.BtnRelCheck, $ui.BtnRelRepair, $ui.BtnRelInstall, $ui.BtnRelBack, $ui.ChkRelEarly) { $b.IsEnabled = -not $Busy }
}

function Get-RelTaskTitle([string]$Kind, [string]$Argument) {
    switch ($Kind) {
        'Start' { T 'rel.task.start' } 'Check' { T 'rel.task.check' } 'Install' { T 'rel.task.install' $Argument }
        'Back' { T 'rel.task.back' } 'Repair' { T 'rel.task.repair' } default { "AVDTune $Kind" }
    }
}
function Start-RelJob([string]$Kind, [string]$Argument = '') {
    if ($script:RelJob) { throw (T 'rel.err.busy') }
    if ($Kind -notin 'Start', 'Check') { Assert-NoOtherWriter -AllowWriteBlock:($Kind -eq 'Repair') }   # #104 N4: the repair is the way out of a write block   # install, repair and back change AVDTune: never next to another writer (#49)
    $ctx = @{
        Kind = $Kind; Argument = $Argument; AppRoot = $script:AppRoot; InstallRoot = $script:RelInstallRoot; StateRoot = $script:StateRoot; User = [string]$env:USERNAME
        Version = $(if ($script:Rel.Info.Version) { $script:Rel.Info.Version } else { [string]$script:ToolVersion }); EarlyAccess = [bool](Get-AVDTuneReleaseSettings $script:StateRoot).EarlyAccess
        RunActive = (Test-RelRunActive); Http = (Get-RelHttp); Import = (-not $script:TestMode); AllowDev = [bool]$script:TestMode
    }
    Set-RelBusy $true
    if ($Kind -notin 'Start', 'Check') { Set-ShutdownBlock $true }   # install, repair and back change AVDTune: log off and shut down wait (#49)
    # the checks are read only and can be started again from the list; install, back and repair change the tool and are started on the card
    $task = Start-AVDTuneUiTask -Kind "release-$($Kind.ToLower())" -Title (Get-RelTaskTitle $Kind $Argument) -Step $(if ($Kind -in 'Start', 'Check') { T 'rel.task.step.check' } else { T 'rel.task.step.install' }) -Retry $(if ($Kind -in 'Start', 'Check') { @{ Command = 'Start-RelJob'; Arguments = @($Kind) } })
    if ($script:TestMode) {
        # inline: the fakes are closures of this runspace (same reason as the readiness check)
        $res = $null; $err = ''
        try { $res = & $script:RelWork $ctx } catch { $err = $_.Exception.Message }
        $script:RelJob = @{ Inline = $true; Result = $res; Err = $err; Kind = $Kind; Task = $task }
        return
    }
    $ps = New-AVDTunePowerShell
    [void]$ps.AddScript($script:RelWork.ToString()).AddArgument($ctx)
    $script:RelJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Kind = $Kind; Task = $task }
}

function Add-RelProtocol([string]$Subject, [string]$Note, [string]$Result = 'ok') {
    [void](Add-PackTuneProtocolAction -Protocol $script:Protocol -Category 'other' -Subject $Subject -Result $Result -Note (Remove-PackTuneProtocolSecrets $Note 200))
    Save-Protocol
}

function Update-ReleaseView {
    $s = $script:Rel.Status
    $key = if ($s) { [string]$s.Status } else { 'running' }
    $pair = $script:RelPill[$key]
    Set-Brush $ui.PillRelease ([System.Windows.Controls.Border]::BackgroundProperty) $pair[0]
    Set-Brush $ui.TxtRelStatus ([System.Windows.Controls.TextBlock]::ForegroundProperty) $pair[1]
    $ui.TxtRelStatus.Text = T "rel.pill.$key"
    $mode = if ($script:Rel.Info) { [string]$script:Rel.Info.Mode } else { '' }
    $detail = if ($s) { [string]$s.Message + $(if (@($s.Warnings).Count -gt 0) { "`r`n" + (@($s.Warnings) -join "`r`n") }) } else { T 'rel.comparing' }
    if ($script:Rel.Restart) { $detail = $script:Rel.Restart + "`r`n" + $detail }
    if ($s -and (Get-AVDTuneProp $s 'OldLauncher')) { $detail = (T 'rel.oldlauncher') + "`r`n" + $detail }   # #73: first, it runs cmdlets before the safe module path until repaired
    $ui.TxtRelDetail.Text = $detail
    $files = @()
    if ($s -and ($s.Status -eq 'bad' -or @($s.Acl).Count -gt 0)) {
        $files += @($s.Acl | ForEach-Object { T 'rel.file.folder' $_ })
    }
    if ($s -and $s.Status -eq 'bad') {
        $files += @($s.Changed | ForEach-Object { T 'rel.file.changed' $_ }) + @($s.Missing | ForEach-Object { T 'rel.file.missing' $_ }) + @($s.Extra | ForEach-Object { T 'rel.file.extra' $_ })
    }
    $ui.TxtRelFiles.Text = ($files -join "`r`n")
    $ui.TxtRelFiles.Visibility = ConvertTo-Vis ($files.Count -gt 0)
    $ui.BtnRelRepair.Visibility = ConvertTo-Vis ([bool]($s -and $s.Status -eq 'bad' -and $mode -eq 'Installed' -and -not $script:Rel.Restart))
    $skip = [bool]($s -and $s.Status -eq 'unverified' -and $mode -eq 'Installed' -and $s.Blocked)
    $ui.PanelRelSkip.Visibility = ConvertTo-Vis $skip
    if ($skip) { $ui.TxtRelSkipHint.Text = T 'rel.skiphint' $script:Rel.ComputerName }
    $latest = $script:Rel.Latest
    $notes = ''
    if ($latest) {
        $early = $(if ($latest.Prerelease) { T 'rel.early.note' } else { '' })
        $notes = if ($latest.Newer) { T 'rel.newer' $latest.Version $early ([string]$latest.Date).Substring(0, 10) $latest.Notes } else { T 'rel.newest' $latest.Version $early }
    }
    elseif ($script:Rel.CheckError) { $notes = T 'rel.checkerr' $script:Rel.CheckError }
    $ui.TxtRelNotes.Text = $notes
    $ui.TxtRelNotes.Visibility = ConvertTo-Vis ([bool]$notes)
    $offerInstall = $false; $installText = T 'rel.install'
    if ($latest -and -not $script:Rel.Restart -and ($s -and $s.Status -ne 'bad')) {
        if ($mode -eq 'Installed' -and $latest.Newer) { $offerInstall = $true; $installText = T 'rel.install.version' $latest.Version }
        elseif ($mode -eq 'Unprotected' -and ($latest.Newer -or $latest.Version -eq $script:Rel.Info.Version)) { $offerInstall = $true; $installText = T 'rel.install.in' $latest.Version $script:RelInstallRoot }
        elseif ($script:TestMode -and $latest.Newer) { $offerInstall = $true; $installText = T 'rel.install.version' $latest.Version }
    }
    $ui.BtnRelInstall.Content = $installText
    $ui.BtnRelInstall.Visibility = ConvertTo-Vis $offerInstall
    $inst = Get-AVDTuneInstallState $script:RelInstallRoot
    $ui.BtnRelBack.Visibility = ConvertTo-Vis ([bool]($inst -and $inst.Previous -and ($mode -eq 'Installed' -or $script:TestMode) -and -not $script:Rel.Restart))
    $ui.BtnRelBack.Content = $(if ($inst -and $inst.Previous) { T 'rel.back.version' $inst.Previous } else { T 'rel.back' })
    $ui.ChkRelEarly.IsChecked = [bool](Get-AVDTuneReleaseSettings $script:StateRoot).EarlyAccess
    # the banner on the other pages says why AVDTune is read only
    $block = Get-AVDTuneWriteBlock
    $ui.TxtReadOnly.Text = $(if ($block) { T 'rel.banner.block' $block } else { T 'shell.readonly' })
}

function Complete-RelResult($Job, $Res, [string]$Err) {
    $script:RelJob = $null
    Set-RelBusy $false
    $kind = $Job.Kind
    if ($kind -notin 'Start', 'Check') { Set-ShutdownBlock $false }
    if ($Err) {
        Complete-AVDTuneUiTask $Job.Task -Failed -Summary $Err
        if ($kind -eq 'Start') { Set-AVDTuneWriteBlock "the integrity check could not run ($Err)."; $script:Rel.Status = [pscustomobject]@{ Status = 'failed'; Message = (T 'rel.err.check' $Err); Warnings = @(); Changed = @(); Missing = @(); Extra = @() } }
        else { Show-Error $Err; Add-RelProtocol "AVDTune $kind" $Err 'failed' }
        Update-ReleaseView
        return
    }
    if ($kind -eq 'Start') {
        if ($Res.Error) {
            Set-AVDTuneWriteBlock "the integrity check could not run ($($Res.Error))."
            $script:Rel.Status = [pscustomobject]@{ Status = 'failed'; Message = (T 'rel.err.check' $Res.Error); Warnings = @(); Changed = @(); Missing = @(); Extra = @() }
        }
        else {
            $script:Rel.Status = $Res.Status
            Set-AVDTuneIntegrityBlock $Res.Status
            if ($Res.Status.Status -eq 'bad') { Add-RelProtocol 'Warning: AVDTune files differ from the release' ("$($Res.Status.Changed.Count) changed, $($Res.Status.Missing.Count) missing, $($Res.Status.Extra.Count) extra; read only until repaired") 'failed'; Show-Toast (T 'rel.toast.bad') }
            elseif ($Res.Status.Status -eq 'unverified') { Add-RelProtocol 'AVDTune files not verified' $Res.Status.Message 'skipped' }
        }
    }
    if ($kind -in 'Start', 'Check') { $script:Rel.Latest = $Res.Latest; $script:Rel.CheckError = [string]$Res.CheckError }
    if ($kind -in 'Install', 'Back', 'Repair') {
        $r = $Res.Result
        $script:Rel.Restart = $r.Text
        Add-RelProtocol "AVDTune $(@{ Install = 'update'; Back = 'switched back'; Repair = 'repaired' }[$kind])" $r.Text $(if ($kind -eq 'Repair' -and -not $r.Ok) { 'failed' } else { 'ok' })
        Show-Toast $r.Text
        if ($kind -eq 'Repair' -and $r.Ok) { $script:Rel.Status = [pscustomobject]@{ Status = 'bad'; Message = (T 'rel.repaired'); Warnings = @(); Changed = @(); Missing = @(); Extra = @() } }
        if ($kind -eq 'Repair' -and -not $r.Ok) { $script:Rel.Status = [pscustomobject]@{ Status = 'bad'; Message = (T 'rel.notrepaired' (@($r.Failed) -join '; ')); Warnings = @(); Changed = @($r.Remaining.Changed); Missing = @($r.Remaining.Missing); Extra = @($r.Remaining.Extra) } ; $script:Rel.Restart = '' }
    }
    $summary = if ($kind -in 'Install', 'Back', 'Repair') { [string]$Res.Result.Text } elseif ($kind -eq 'Start' -and $Res.Error) { T 'rel.err.check' $Res.Error } elseif ($Res.CheckError) { T 'rel.checkerr' $Res.CheckError } elseif ($kind -eq 'Start') { [string]$script:Rel.Status.Message } elseif ($script:Rel.Latest.Newer) { T 'rel.summary.available' $script:Rel.Latest.Version } else { T 'rel.summary.current' }
    Complete-AVDTuneUiTask $Job.Task -Failed:([bool]($Res.Error -or $Res.CheckError -or ($kind -eq 'Start' -and $script:Rel.Status.Status -in 'bad', 'failed') -or ($kind -eq 'Repair' -and -not $Res.Result.Ok))) -Summary $summary
    Update-ReleaseView
    if ($script:CurrentPage -eq 'Protocol') { Update-ProtocolView }
}

function Complete-RelJob {
    $job = $script:RelJob
    if (-not $job) { return }
    if ($job.Inline) { Complete-RelResult $job $job.Result $job.Err; return }
    if (-not $job.Handle.IsCompleted) { return }
    $res = $null; $err = ''
    try {
        $out = @($job.PS.EndInvoke($job.Handle))
        if ($job.PS.Streams.Error.Count -gt 0) { throw $job.PS.Streams.Error[0].Exception.Message }
        $res = $out | Select-Object -Last 1
    }
    catch { $err = $_.Exception.Message }
    finally { $job.PS.Dispose() }
    Complete-RelResult $job $res $err
}

$script:RelTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:RelTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:RelTimer.Add_Tick({ try { Complete-RelJob } catch { Show-Error $_.Exception.Message } })
$script:RelTimer.Start()
$window.Add_Closed({ $script:RelTimer.Stop(); if ($script:RelJob -and -not $script:RelJob.Inline) { try { [void]$script:RelJob.PS.BeginStop($null, $null) } catch { } } })

Add-Click $ui.BtnRelCheck { Start-RelJob 'Check'; if ($script:RelJob -and $script:RelJob.Inline) { Complete-RelJob } }
$ui.ChkRelEarly.Add_Click({ try { [void](Set-AVDTuneReleaseSettings $script:StateRoot ([bool]$ui.ChkRelEarly.IsChecked)); Start-RelJob 'Check'; if ($script:RelJob -and $script:RelJob.Inline) { Complete-RelJob } } catch { Show-Error $_.Exception.Message } })
Add-Click $ui.BtnRelInstall {
    $v = [string]$script:Rel.Latest.Version
    if (-not (Confirm-Action (T 'rel.ask.install' $v) (T 'rel.install'))) { return }
    Start-RelJob 'Install' $v; if ($script:RelJob.Inline) { Complete-RelJob }
}
Add-Click $ui.BtnRelRepair {
    if (-not (Confirm-Action (T 'rel.ask.repair' $script:Rel.Info.Version) (T 'rel.ask.repair.title'))) { return }
    Start-RelJob 'Repair'; if ($script:RelJob.Inline) { Complete-RelJob }
}
Add-Click $ui.BtnRelBack {
    $p = [string](Get-AVDTuneInstallState $script:RelInstallRoot).Previous
    if (-not (Confirm-Action (T 'rel.ask.back' $p) (T 'rel.ask.back.title'))) { return }
    Start-RelJob 'Back'; if ($script:RelJob.Inline) { Complete-RelJob }
}
Add-Click $ui.BtnRelSkip {
    $r = Confirm-AVDTuneUnverified -StateRoot $script:StateRoot -Name $ui.TxtRelSkipName.Text -Expected $script:Rel.ComputerName -User ([string]$env:USERNAME) -Status $script:Rel.Status
    Add-RelProtocol 'AVDTune continued without the integrity check' $r.Text 'skipped'
    $script:Rel.Status.Blocked = $false
    $script:Rel.Status.Message = $script:Rel.Status.Message + ' ' + (T 'rel.skipped')
    $ui.TxtRelSkipName.Text = ''
    Show-Toast (T 'rel.toast.skip')
    Update-ReleaseView
}
# ---------------------------------------------------------------- desktop shortcut (issue #15)
# Logic in Modules\AVDTune.Shortcut.psm1. Only the desktop of the signed-in account, never the Public Desktop; only for the installed copy.
# Test mode: a desktop folder inside the test state and a mode the smoke driver can set ($script:ShortcutTestMode), never the real desktop.
$script:ShortcutTestMode = ''
function Get-ShortcutDesktop { if ($script:TestMode) { $d = Join-Path $script:StateRoot 'desktop-test'; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }; $d } else { Get-AVDTuneUserDesktop } }
function Get-ShortcutMode { if ($script:TestMode -and $script:ShortcutTestMode) { $script:ShortcutTestMode } else { [string]$script:Rel.Info.Mode } }
function Update-ShortcutRow {
    $installed = (Get-ShortcutMode) -eq 'Installed'
    $link = $null; try { $link = Get-AVDTuneDesktopShortcut -Folder (Get-ShortcutDesktop) -InstallRoot $script:RelInstallRoot } catch { }
    $ui.BtnRelShortcut.Content = $(if ($link) { T 'sc.remove' } else { T 'sc.create' })
    $ui.BtnRelShortcut.IsEnabled = ($installed -or [bool]$link)
    $ui.TxtRelShortcut.Text = if (-not $installed -and -not $link) { T 'sc.state.notinstalled' }
    elseif ($link -and -not $link.Matches) { T 'sc.state.wrong' $script:RelInstallRoot }
    elseif ($link) { T 'sc.state.ok' }
    else { T 'sc.state.none' }
    Update-BenchShortcutRow
}
# The second shortcut "AVDTune Benchmark" (#90): the launcher with -Benchmark, like AVDTune.lnk (#15). Offered in the benchmark-only card of the Benchmark page and in
# the Integrity and updates card of the Overview; both rows show the same state and use the same switch.
function Update-BenchShortcutRow {
    $installed = (Get-ShortcutMode) -eq 'Installed'
    $link = $null; try { $link = Get-AVDTuneDesktopShortcut -Folder (Get-ShortcutDesktop) -InstallRoot $script:RelInstallRoot -Benchmark } catch { }
    $text = if (-not $installed -and -not $link) { T 'sc.state.notinstalled' }
    elseif ($link -and -not $link.Matches) { T 'sc.state.wrong' $script:RelInstallRoot }
    elseif ($link) { T 'bench.sc.ok' }
    else { T 'sc.state.none' }
    foreach ($row in @(@($ui.BtnBenchShortcut, $ui.TxtBenchShortcut), @($ui.BtnRelBenchShortcut, $ui.TxtRelBenchShortcut))) {
        $row[0].Content = $(if ($link) { T 'bench.sc.remove' } else { T 'bench.sc.create' })
        $row[0].IsEnabled = ($installed -or [bool]$link)
        $row[1].Text = $text
    }
}
function Switch-BenchShortcut {
    $folder = Get-ShortcutDesktop
    if (Get-AVDTuneDesktopShortcut -Folder $folder -Benchmark) {
        [void](Remove-AVDTuneDesktopShortcut -Folder $folder -Benchmark)
        Add-RelProtocol 'Desktop shortcut AVDTune Benchmark removed' $folder
        Show-Toast (T 'sc.toast.removed')
    }
    elseif ((Get-ShortcutMode) -eq 'Installed') {
        # only the installed copy gets a shortcut (it points to the install folder); a button that is off cannot be clicked, this is the same rule for every caller
        $link = New-AVDTuneDesktopShortcut -InstallRoot $script:RelInstallRoot -Folder $folder -Benchmark
        Add-RelProtocol 'Desktop shortcut AVDTune Benchmark created' "$($link.Path) -> $($link.Target) $($link.Arguments) (run as administrator)"
        Show-Toast (T 'sc.toast.created')
    }
    Update-BenchShortcutRow
}
Add-Click $ui.BtnRelBenchShortcut { Switch-BenchShortcut }
function New-ShortcutNow {
    $link = New-AVDTuneDesktopShortcut -InstallRoot $script:RelInstallRoot -Folder (Get-ShortcutDesktop)
    Add-RelProtocol 'Desktop shortcut created' "$($link.Path) -> $($link.Target) $($link.Arguments) (run as administrator)"
    Show-Toast (T 'sc.toast.created')
}
function Show-ShortcutQuestion {
    # The small question of the first start, in the card below the stages. Returns $true when it was shown.
    $offer = Get-AVDTuneShortcutOffer -Root $script:StateRoot -Mode (Get-ShortcutMode)
    if ($offer -ne 'Ask') { return $false }
    Update-ShortcutRow
    Close-Stage
    $script:OpenStage = 'Shortcut'
    Reset-StageButtons
    $ui.BoxStage.Visibility = 'Visible'
    $ui.TxtStageMessage.Text = ''
    $ui.TxtStageTitle.Text = T 'sc.title'
    $ui.TxtStageIntro.Text = T 'sc.intro'
    $spec = Get-AVDTuneShortcutSpec $script:RelInstallRoot
    [void]$ui.PanelStageBody.Children.Add((New-InfoRow (T 'sc.row.starts') "$($spec.Target) $($spec.Arguments)"))
    [void]$ui.PanelStageBody.Children.Add((New-InfoRow (T 'sc.row.folder') $spec.WorkingDirectory))
    [void]$ui.PanelStageBody.Children.Add((New-InfoRow (T 'sc.row.runs') (T 'sc.row.runs.value')))
    [void]$ui.PanelStageBody.Children.Add((New-InfoRow (T 'sc.row.desktop') (Get-ShortcutDesktop)))
    $ui.BtnStageAction.Content = T 'sc.btn.create'
    $ui.BtnStageAction2.Content = T 'sc.btn.no'; $ui.BtnStageAction2.Visibility = 'Visible'
    $script:StageAction = {
        try { New-ShortcutNow; Set-AVDTuneShortcutAnswer -Root $script:StateRoot -Answer Yes; Close-Stage; Update-ShortcutRow }
        catch { Set-StageMessage $_.Exception.Message 'error' }
    }
    $script:StageAction2 = { Set-AVDTuneShortcutAnswer -Root $script:StateRoot -Answer No; Add-RelProtocol 'Desktop shortcut' 'Not wanted (asked once).'; Close-Stage; Update-ShortcutRow }
    $window.UpdateLayout(); $ui.BoxStage.BringIntoView()
    $true
}
Add-Click $ui.BtnRelShortcut {
    $link = Get-AVDTuneDesktopShortcut -Folder (Get-ShortcutDesktop)
    if ($link) {
        [void](Remove-AVDTuneDesktopShortcut -Folder (Get-ShortcutDesktop))
        Add-RelProtocol 'Desktop shortcut removed' $link.Path
        Show-Toast (T 'sc.toast.removed')
    }
    elseif ((Get-ShortcutMode) -eq 'Installed') { New-ShortcutNow; Set-AVDTuneShortcutAnswer -Root $script:StateRoot -Answer Yes }
    Update-ShortcutRow
}
Update-ShortcutRow
# A later start of the installed copy asks once, when the first-run questions are answered already (the first run asks after them)
if ((Get-AVDTuneEnvironment $script:StateRoot) -and -not $script:OpenStage) { [void](Show-ShortcutQuestion) }
