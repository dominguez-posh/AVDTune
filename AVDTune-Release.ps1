# The "Integrity and updates" card on the Overview (dot-sourced by Start-AVDTune.ps1). Logic is in Modules\AVDTune.Release.psm1; this file shows the result of
# the integrity check, starts the work (check at start, update check, install, repair, back to the previous version) in a background runspace and polls it
# with the window timer. Nothing here installs by itself: install, repair and back run only on a click and after a confirmation.
# A failed integrity check sets the write block of the engine (Modules\AVDTune.psm1): the write gate stays shut and AVDTune is read only until it is repaired
# and started again. Test mode: fake HTTP adapter (Tests\Fakes\FakeRelease.ps1) and an install folder inside the test state, never GitHub or Program Files.

$script:Rel = @{ ComputerName = [string](& $script:Machine.ComputerName); Status = $null; Latest = $null; CheckError = ''; Job = $null; Restart = ''; Info = $null }
$script:RelFakeHttp = $null   # test hook: a fake HTTP adapter for the smoke driver
$script:RelInstallRoot = $(if ($script:TestMode) { Join-Path $script:StateRoot 'install-test' } else { Get-AVDTuneInstallRoot })
$script:RelOriginalBanner = [string]$ui.TxtReadOnly.Text
$script:RelPill = @{
    ok = @('SuccessBg', 'Success', 'Verified'); bad = @('ErrorBg', 'Danger', 'Files changed'); dev = @('Hover', 'Text', 'Development copy'); unprotected = @('WarningBg', 'Warning', 'Not protected')
    unverified = @('WarningBg', 'Warning', 'Not verified'); running = @('Hover', 'MutedText', 'Checking'); failed = @('ErrorBg', 'Danger', 'Check failed')
}
if ($script:TestMode) { . (Join-Path (Split-Path $env:AVDTUNE_FAKE -Parent) 'FakeRelease.ps1') }

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

function Test-RelRunActive { [bool]($script:UpdJob -or ($script:ReadyJob -and $script:ReadyJob.Kind -eq 'Fix')) }

function Set-RelBusy([bool]$Busy) {
    foreach ($b in $ui.BtnRelCheck, $ui.BtnRelRepair, $ui.BtnRelInstall, $ui.BtnRelBack, $ui.ChkRelEarly) { $b.IsEnabled = -not $Busy }
}

function Start-RelJob([string]$Kind, [string]$Argument = '') {
    if ($script:Rel.Job) { throw 'Another check of the tool is still running.' }
    $ctx = @{
        Kind = $Kind; Argument = $Argument; AppRoot = $script:AppRoot; InstallRoot = $script:RelInstallRoot; StateRoot = $script:StateRoot; User = [string]$env:USERNAME
        Version = $(if ($script:Rel.Info.Version) { $script:Rel.Info.Version } else { [string]$script:ToolVersion }); EarlyAccess = [bool](Get-AVDTuneReleaseSettings $script:StateRoot).EarlyAccess
        RunActive = (Test-RelRunActive); Http = (Get-RelHttp); Import = (-not $script:TestMode); AllowDev = [bool]$script:TestMode
    }
    Set-RelBusy $true
    if ($script:TestMode) {
        # inline: the fakes are closures of this runspace (same reason as the readiness check)
        $res = $null; $err = ''
        try { $res = & $script:RelWork $ctx } catch { $err = $_.Exception.Message }
        $script:Rel.Job = @{ Inline = $true; Result = $res; Err = $err; Kind = $Kind }
        return
    }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:RelWork.ToString()).AddArgument($ctx)
    $script:Rel.Job = @{ PS = $ps; Handle = $ps.BeginInvoke(); Kind = $Kind }
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
    $ui.TxtRelStatus.Text = $pair[2]
    $mode = if ($script:Rel.Info) { [string]$script:Rel.Info.Mode } else { '' }
    $detail = if ($s) { [string]$s.Message + $(if (@($s.Warnings).Count -gt 0) { "`r`n" + (@($s.Warnings) -join "`r`n") }) } else { 'Comparing the files with the release ...' }
    if ($script:Rel.Restart) { $detail = $script:Rel.Restart + "`r`n" + $detail }
    $ui.TxtRelDetail.Text = $detail
    $files = @()
    if ($s -and ($s.Status -eq 'bad' -or @($s.Acl).Count -gt 0)) {
        $files += @($s.Acl | ForEach-Object { "folder    $_" })
    }
    if ($s -and $s.Status -eq 'bad') {
        $files += @($s.Changed | ForEach-Object { "changed   $_" }) + @($s.Missing | ForEach-Object { "missing   $_" }) + @($s.Extra | ForEach-Object { "extra     $_" })
    }
    $ui.TxtRelFiles.Text = ($files -join "`r`n")
    $ui.TxtRelFiles.Visibility = ConvertTo-Vis ($files.Count -gt 0)
    $ui.BtnRelRepair.Visibility = ConvertTo-Vis ([bool]($s -and $s.Status -eq 'bad' -and $mode -eq 'Installed' -and -not $script:Rel.Restart))
    $skip = [bool]($s -and $s.Status -eq 'unverified' -and $mode -eq 'Installed' -and $s.Blocked)
    $ui.PanelRelSkip.Visibility = ConvertTo-Vis $skip
    if ($skip) { $ui.TxtRelSkipHint.Text = "To continue without the check, type the name of this computer ($($script:Rel.ComputerName)). This is written to the protocol and the change log." }
    $latest = $script:Rel.Latest
    $notes = ''
    if ($latest) {
        $notes = if ($latest.Newer) { "Version $($latest.Version)$(if ($latest.Prerelease) { ' (early access)' }) is available, released $(([string]$latest.Date).Substring(0, 10)). Release notes:`r`n$($latest.Notes)" } else { "AVDTune $($latest.Version) is the newest version$(if ($latest.Prerelease) { ' (early access)' })." }
    }
    elseif ($script:Rel.CheckError) { $notes = "Update check: $($script:Rel.CheckError)" }
    $ui.TxtRelNotes.Text = $notes
    $ui.TxtRelNotes.Visibility = ConvertTo-Vis ([bool]$notes)
    $offerInstall = $false; $installText = 'Install update'
    if ($latest -and -not $script:Rel.Restart -and ($s -and $s.Status -ne 'bad')) {
        if ($mode -eq 'Installed' -and $latest.Newer) { $offerInstall = $true; $installText = "Install $($latest.Version)" }
        elseif ($mode -eq 'Unprotected' -and ($latest.Newer -or $latest.Version -eq $script:Rel.Info.Version)) { $offerInstall = $true; $installText = "Install $($latest.Version) in $($script:RelInstallRoot)" }
        elseif ($script:TestMode -and $latest.Newer) { $offerInstall = $true; $installText = "Install $($latest.Version)" }
    }
    $ui.BtnRelInstall.Content = $installText
    $ui.BtnRelInstall.Visibility = ConvertTo-Vis $offerInstall
    $inst = Get-AVDTuneInstallState $script:RelInstallRoot
    $ui.BtnRelBack.Visibility = ConvertTo-Vis ([bool]($inst -and $inst.Previous -and ($mode -eq 'Installed' -or $script:TestMode) -and -not $script:Rel.Restart))
    if ($inst -and $inst.Previous) { $ui.BtnRelBack.Content = "Back to version $($inst.Previous)" }
    $ui.ChkRelEarly.IsChecked = [bool](Get-AVDTuneReleaseSettings $script:StateRoot).EarlyAccess
    # the banner on the other pages says why AVDTune is read only
    $block = Get-AVDTuneWriteBlock
    $ui.TxtReadOnly.Text = $(if ($block) { "Read only: $block (see the card Integrity and updates on the Overview)" } else { $script:RelOriginalBanner })
}

function Complete-RelResult($Job, $Res, [string]$Err) {
    $script:Rel.Job = $null
    Set-RelBusy $false
    $kind = $Job.Kind
    if ($Err) {
        if ($kind -eq 'Start') { Set-AVDTuneWriteBlock "the integrity check could not run ($Err)."; $script:Rel.Status = [pscustomobject]@{ Status = 'failed'; Message = "The integrity check could not run: $Err"; Warnings = @(); Changed = @(); Missing = @(); Extra = @() } }
        else { Show-Error $Err; Add-RelProtocol "AVDTune $kind" $Err 'failed' }
        Update-ReleaseView
        return
    }
    if ($kind -eq 'Start') {
        if ($Res.Error) {
            Set-AVDTuneWriteBlock "the integrity check could not run ($($Res.Error))."
            $script:Rel.Status = [pscustomobject]@{ Status = 'failed'; Message = "The integrity check could not run: $($Res.Error)"; Warnings = @(); Changed = @(); Missing = @(); Extra = @() }
        }
        else {
            $script:Rel.Status = $Res.Status
            Set-AVDTuneIntegrityBlock $Res.Status
            if ($Res.Status.Status -eq 'bad') { Add-RelProtocol 'Warning: AVDTune files differ from the release' ("$($Res.Status.Changed.Count) changed, $($Res.Status.Missing.Count) missing, $($Res.Status.Extra.Count) extra; read only until repaired") 'failed'; Show-Toast 'The files of AVDTune do not match the release. AVDTune is read only until you repair it on the Overview.' }
            elseif ($Res.Status.Status -eq 'unverified') { Add-RelProtocol 'AVDTune files not verified' $Res.Status.Message 'skipped' }
        }
    }
    if ($kind -in 'Start', 'Check') { $script:Rel.Latest = $Res.Latest; $script:Rel.CheckError = [string]$Res.CheckError }
    if ($kind -in 'Install', 'Back', 'Repair') {
        $r = $Res.Result
        $script:Rel.Restart = $r.Text
        Add-RelProtocol "AVDTune $(@{ Install = 'update'; Back = 'switched back'; Repair = 'repaired' }[$kind])" $r.Text $(if ($kind -eq 'Repair' -and -not $r.Ok) { 'failed' } else { 'ok' })
        Show-Toast $r.Text
        if ($kind -eq 'Repair' -and $r.Ok) { $script:Rel.Status = [pscustomobject]@{ Status = 'bad'; Message = 'Repaired. AVDTune stays read only in this session: restart it (the code that is running was loaded from the files that were wrong).'; Warnings = @(); Changed = @(); Missing = @(); Extra = @() } }
        if ($kind -eq 'Repair' -and -not $r.Ok) { $script:Rel.Status = [pscustomobject]@{ Status = 'bad'; Message = "Not everything could be repaired: $(@($r.Failed) -join '; ')"; Warnings = @(); Changed = @($r.Remaining.Changed); Missing = @($r.Remaining.Missing); Extra = @($r.Remaining.Extra) } ; $script:Rel.Restart = '' }
    }
    Update-ReleaseView
    if ($script:CurrentPage -eq 'Protocol') { Update-ProtocolView }
}

function Complete-RelJob {
    $job = $script:Rel.Job
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
$window.Add_Closed({ $script:RelTimer.Stop(); if ($script:Rel.Job -and -not $script:Rel.Job.Inline) { try { [void]$script:Rel.Job.PS.BeginStop($null, $null) } catch { } } })

Add-Click $ui.BtnRelCheck { Start-RelJob 'Check'; if ($script:Rel.Job -and $script:Rel.Job.Inline) { Complete-RelJob } }
$ui.ChkRelEarly.Add_Click({ try { [void](Set-AVDTuneReleaseSettings $script:StateRoot ([bool]$ui.ChkRelEarly.IsChecked)); Start-RelJob 'Check'; if ($script:Rel.Job -and $script:Rel.Job.Inline) { Complete-RelJob } } catch { Show-Error $_.Exception.Message } })
Add-Click $ui.BtnRelInstall {
    $v = [string]$script:Rel.Latest.Version
    if (-not (Confirm-Action "Install AVDTune $v next to the current version? ZIP and every file are checked against the SHA256 of the release manifest first. The current version stays and you can go back to it. Nothing changes until AVDTune is started again." 'Install update')) { return }
    Start-RelJob 'Install' $v; if ($script:Rel.Job.Inline) { Complete-RelJob }
}
Add-Click $ui.BtnRelRepair {
    if (-not (Confirm-Action "Download version $($script:Rel.Info.Version) again from GitHub, check it, and put the changed and missing files right and remove the extra ones? AVDTune stays read only until it is started again." 'Repair AVDTune')) { return }
    Start-RelJob 'Repair'; if ($script:Rel.Job.Inline) { Complete-RelJob }
}
Add-Click $ui.BtnRelBack {
    $p = [string](Get-AVDTuneInstallState $script:RelInstallRoot).Previous
    if (-not (Confirm-Action "Go back to version $p? Its files are checked against the saved manifest first. It takes effect when AVDTune is started again." 'Previous version')) { return }
    Start-RelJob 'Back'; if ($script:Rel.Job.Inline) { Complete-RelJob }
}
Add-Click $ui.BtnRelSkip {
    $r = Confirm-AVDTuneUnverified -StateRoot $script:StateRoot -Name $ui.TxtRelSkipName.Text -Expected $script:Rel.ComputerName -User ([string]$env:USERNAME)
    Add-RelProtocol 'AVDTune continued without the integrity check' $r.Text 'skipped'
    $script:Rel.Status.Blocked = $false
    $script:Rel.Status.Message = $script:Rel.Status.Message + ' Continued without the check on request.'
    $ui.TxtRelSkipName.Text = ''
    Show-Toast 'AVDTune continues without the integrity check. It is in the protocol.'
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
    $ui.BtnRelShortcut.Content = $(if ($link) { 'Remove desktop shortcut' } else { 'Create desktop shortcut' })
    $ui.BtnRelShortcut.IsEnabled = ($installed -or [bool]$link)
    $ui.TxtRelShortcut.Text = if (-not $installed -and -not $link) { 'Desktop shortcut: install AVDTune first (it points to the installed copy in the install folder).' }
    elseif ($link -and -not $link.Matches) { "Desktop shortcut on your desktop, but it does not point to $($script:RelInstallRoot) as administrator; create it again." }
    elseif ($link) { 'Desktop shortcut on your desktop (only yours, runs as administrator).' }
    else { 'No desktop shortcut. It goes on your desktop only, never on the Public Desktop.' }
}
function New-ShortcutNow {
    $link = New-AVDTuneDesktopShortcut -InstallRoot $script:RelInstallRoot -Folder (Get-ShortcutDesktop)
    Add-RelProtocol 'Desktop shortcut created' "$($link.Path) -> $($link.Target) $($link.Arguments) (run as administrator)"
    Show-Toast 'The shortcut is on your desktop.'
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
    $ui.TxtStageTitle.Text = 'Desktop shortcut'
    $ui.TxtStageIntro.Text = 'Create a shortcut to AVDTune on your desktop? It goes on your desktop only (this Windows account), never on the Public Desktop, so it does not end up in the image for every user. AVDTune asks once; the Integrity and updates card can create or remove it later.'
    $spec = Get-AVDTuneShortcutSpec $script:RelInstallRoot
    [void]$ui.PanelStageBody.Children.Add((New-InfoRow 'Starts' "$($spec.Target) $($spec.Arguments)"))
    [void]$ui.PanelStageBody.Children.Add((New-InfoRow 'Folder' $spec.WorkingDirectory))
    [void]$ui.PanelStageBody.Children.Add((New-InfoRow 'Runs' 'as administrator (Windows asks for confirmation)'))
    [void]$ui.PanelStageBody.Children.Add((New-InfoRow 'Desktop' (Get-ShortcutDesktop)))
    $ui.BtnStageAction.Content = 'Create the shortcut'
    $ui.BtnStageAction2.Content = 'No, thanks'; $ui.BtnStageAction2.Visibility = 'Visible'
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
        Show-Toast 'The shortcut is removed from your desktop.'
    }
    elseif ((Get-ShortcutMode) -eq 'Installed') { New-ShortcutNow; Set-AVDTuneShortcutAnswer -Root $script:StateRoot -Answer Yes }
    Update-ShortcutRow
}
Update-ShortcutRow
# A later start of the installed copy asks once, when the first-run questions are answered already (the first run asks after them)
if ((Get-AVDTuneEnvironment $script:StateRoot) -and -not $script:OpenStage) { [void](Show-ShortcutQuestion) }
