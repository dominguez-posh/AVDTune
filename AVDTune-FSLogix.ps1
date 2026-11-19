# The FSLogix page (dot-sourced by Start-AVDTune.ps1). Logic is in Modules\AVDTune.FSLogix.psm1 and AVDTune.Storage.psm1; this file builds the form and starts the work
# in background runspaces that the window timer polls (#72, like the Optimization page since #66): the page is there at once and reads the master in the background
# (Start-FslRead: fltmc, registry, local groups, the domain SID of the master, redirections.xml, Defender); every change (settings, lists, redirections.xml, Defender,
# ACL, install) and the long checks (function test, storage check) run as one job (Start-FslJob) with a task on the task bar. Changes start only after a successful
# read (the confirmation names what the read found), never while another writer runs, and the window waits for a running change before it closes.
# Everything that changes the master is behind the write gate (snapshot confirmed).
# Test mode: the fake machine, the fake FSLogix adapter and the fake Azure, file share and LDAP services run inline on the UI thread (their closures belong to this
# runspace); no network, no tenant, no share, no Defender of this computer.
# The Azure storage token is the Storage audience of the sign-in (issue 18, optional: a registration without its consent signs in without it): without it the ACL rows say why.

$script:FslFake = $null
if ($script:TestMode) {
    . (Get-TestScript 'FakeFSLogix.ps1'); . (Get-TestScript 'FakeStorage.ps1')
    $script:FslFake = @{ F = (New-AVDTuneFakeFSLogix); Arm = (New-AVDTuneFakeStorageArm); Files = (New-AVDTuneFakeFiles); Ldap = (New-AVDTuneFakeStorageLdap) }
}
$script:FslJob = $null
$script:FslReadJob = $null      # the background read of the page (#72, read only, one at a time)
$script:FslState = $null        # what the last successful read found (see $script:FslReadText)
$script:FslStale = $false       # the last read failed: the page is older than the master, nothing is changed from it until a read works again
$script:FslStateAt = $null      # when that read was taken over
$script:FslMaxAgeMinutes = 10   # a change is not worked out from an older read: it is read again first
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
# the kinds of Start-FslJob that change the master or the share (Install is one too; Test changes the share only with the write tests, Storage only reads)
$script:FslChangeKinds = @('Settings', 'SettingsUndo', 'Lists', 'ListsUndo', 'Group', 'Redirections', 'RedirectionsUndo', 'Defender', 'DefenderUndo', 'Acl', 'AclUndo')

function Get-FslAnswers { $e = $null; try { $e = Get-AVDTuneEnvironment $script:StateRoot } catch { }; if ($e) { Get-AVDTuneEnvironmentAnswers $e } else { $null } }
function Test-FslApplies { $a = Get-FslAnswers; [bool]($a -and [string](Get-AVDTuneProp $a 'Profiles') -ne 'None') }
function Get-FslUser { [string]$env:USERNAME }
function Format-FslValue($v) { if ($null -eq $v) { '' } else { (@($v) | ForEach-Object { [string]$_ }) -join '; ' } }
function Test-FslBusy { [bool]($script:FslJob -or $script:FslReadJob) }
function Test-FslWriting {
    # a running job that changes the master or the share: closing the window and signing out wait for it (a read-only check may be dropped)
    $j = $script:FslJob
    [bool]($j -and -not ($j.Kind -eq 'Storage' -or ($j.Kind -eq 'Test' -and -not $j.Write)))
}
function Assert-FslFresh {
    # a change is worked out from what the page read (the plan of the lists, the Defender list, the settings): not while that read runs, not from a read that failed
    if ($script:FslReadJob) { throw 'The FSLogix state of the master is still being read. Wait until it is done.' }
    if (-not $script:FslState -or $script:FslStale) { throw 'The last read of the FSLogix state failed, so the page may be out of date. Open the page again (or use Retry on the task bar) first.' }
    if (-not $script:FslStateAt -or ((Get-Date) - $script:FslStateAt).TotalMinutes -gt $script:FslMaxAgeMinutes) {
        Start-FslRead
        throw "The FSLogix state on the page is older than $($script:FslMaxAgeMinutes) minutes. It is being read again: check the page and confirm again when the read is done."
    }
}
function Assert-FslWrite { if (-not (Test-AVDTuneWriteAllowed)) { throw (T 'ready.err.readonly') }; Assert-NoOtherWriter; Assert-FslFresh }
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

# ---------------------------------------------------------------- reading the page in the background (#72)
# One reader for the runspace and for the test mode (inline): a script block made from this text, so it does not belong to the UI runspace. Read only.
$script:FslReadText = @'
param($C)
$m = $C.Machine; $F = $C.F
$locations = @(Get-AVDTuneFSLogixLocations -Machine $m)
$target = Get-AVDTuneRedirectionsTarget $m
$redirText = $null; $redirErr = ''
if ($target) { try { $redirText = & $F.ReadText $target } catch { $redirErr = $_.Exception.Message } }
[pscustomobject]@{
    Info = Get-AVDTuneFSLogixInfo -Machine $m
    Settings = @(Get-AVDTuneFSLogixSettingsState -Machine $m)
    LastChange = Get-AVDTuneFSLogixLastChange -Root $C.Root
    Groups = Get-AVDTuneFSLogixGroups -F $F
    Choices = Get-AVDTuneFSLogixGroupChoices -Root $C.Root -Answers $C.Answers
    Plan = Get-AVDTuneFSLogixListPlan -F $F -Root $C.Root -Answers $C.Answers
    RedirDefault = Get-AVDTuneRedirectionsDefaultFolder $m
    RedirTarget = $target; RedirText = $redirText; RedirError = $redirErr
    Locations = $locations
    Defender = Get-AVDTuneFSLogixDefenderState -F $F -VhdLocations $locations
    TestRecord = Get-AVDTuneFSLogixTestRecord -Root $C.Root
}
'@

function Start-FslRead {
    # Reads what the page shows in the background: fltmc (up to 30 s), the registry, the local groups (ADSI), the domain SID of the master, redirections.xml (it may be on a
    # share), Defender (Get-MpPreference). On the window thread the page looked frozen. Read only. One read at a time and not while an FSLogix job runs (the job reads
    # again when it is done). The window does not wait for it when it closes.
    if ($script:FslReadJob -or $script:FslJob) { return }
    $task = Start-AVDTuneUiTask -Kind 'fslogix-read' -Title 'Reading the FSLogix state' -Step 'Reading the installation, settings, lists, redirections.xml and Defender exclusions of the master' -Retry @{ Command = 'Start-FslRead'; Arguments = @() }
    $answers = Get-FslAnswers
    if ($script:TestMode) {
        # Test mode runs on the window thread at a later timer tick (Complete-FslRead): the fake machine is a closure of this runspace and must not run while the overview reads it on its own thread
        $script:FslReadJob = @{ Inline = $true; Answers = $answers; Task = $task }
    }
    else {
        $ps = New-AVDTunePowerShell
        [void]$ps.AddScript({
                param($AppRoot, $Root, $Answers, $ReadText)
                $ErrorActionPreference = 'Stop'
                Import-Module (Join-Path $AppRoot 'Modules\AVDTune.psm1') -Force
                Import-Module (Join-Path $AppRoot 'Modules\AVDTune.FSLogix.psm1') -Force
                & ([scriptblock]::Create($ReadText)) @{ Machine = (New-AVDTuneMachine); F = (New-AVDTuneFSLogixAdapter); Root = $Root; Answers = $Answers }
            }).AddArgument($script:AppRoot).AddArgument($script:StateRoot).AddArgument($answers).AddArgument($script:FslReadText)
        $script:FslReadJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Task = $task }
    }
    Update-FslButtons
}
function Complete-FslRead {
    $job = $script:FslReadJob
    if (-not $job) { return }
    if ($job.Inline) { if ($script:OverviewJob) { return } }   # test mode: not while the overview reads the same fake machine on its own thread
    elseif (-not $job.Handle.IsCompleted) { return }
    $script:FslReadJob = $null
    $res = $null; $err = ''; $streamErr = ''
    if ($job.Inline) {
        try { $res = & ([scriptblock]::Create($script:FslReadText)) @{ Machine = $script:Machine; F = $script:FslFake.F; Root = $script:StateRoot; Answers = $job.Answers } } catch { $err = $_.Exception.Message }
    }
    else {
        try {
            $res = @($job.PS.EndInvoke($job.Handle)) | Select-Object -Last 1
            if ($job.PS.Streams.Error.Count -gt 0) { $streamErr = $job.PS.Streams.Error[0].Exception.Message }
        }
        catch { $err = $_.Exception.Message }
        finally { $job.PS.Dispose() }
    }
    if (-not $res -and -not $err) { $err = $(if ($streamErr) { $streamErr } else { 'No result.' }) }
    if (-not $err) { $script:FslState = $res; $script:FslStale = $false; $script:FslStateAt = Get-Date; Complete-AVDTuneUiTask $job.Task -Summary 'FSLogix state read' }
    else { Complete-AVDTuneUiTask $job.Task -Failed -Summary "The FSLogix state could not be read: $err"; if ($script:FslState) { $script:FslStale = $true } }   # the page on screen is older than the master: nothing is changed from it
    Update-FslButtons
    if ($script:CurrentPage -eq 'FSLogix') {
        Show-FslState
        if ($err) { $ui.TxtFslState.Text = (T 'fsl.readfail' $err $(if ($script:FslState) { (T 'fsl.readfail.old') })); Show-Error "The FSLogix state could not be read: $err" }
    }
}
function Update-FslButtons {
    # while a job runs: no second job; while the page is read, or after a read that failed: no change (Assert-FslWrite refuses as well)
    $job = [bool]$script:FslJob
    $noChange = $job -or [bool]$script:FslReadJob -or -not $script:FslState -or $script:FslStale
    foreach ($b in $ui.BtnFslTest, $ui.BtnFslTestWrite, $ui.BtnFslStorage) { $b.IsEnabled = -not $job }
    foreach ($b in $ui.BtnFslInstall, $ui.BtnFslAclSet, $ui.BtnFslAclUndo, $ui.BtnFslSettingsApply, $ui.BtnFslSettingsUndo, $ui.BtnFslListsApply, $ui.BtnFslListsUndo, $ui.BtnFslGroupAdd, $ui.BtnFslGroupRemove, $ui.BtnFslExcludeAdmins, $ui.BtnFslRedirSave, $ui.BtnFslRedirUndo, $ui.BtnFslDefAdd, $ui.BtnFslDefUndo) { $b.IsEnabled = -not $noChange }
}
function Set-FslCursor { $window.Cursor = $(if ($script:FslJob -and $script:CurrentPage -eq 'FSLogix') { [System.Windows.Input.Cursors]::AppStarting } else { $null }) }   # only when a job starts or ends (as before)

# ---------------------------------------------------------------- the form: installation
function Start-FslLatestLookup {
    # Reads the newest release (HEAD on the Microsoft link, no download, 15 s limit) with the same function as the Updates page, in the background; cached.
    if ($script:FslLatestLookup) { return }
    $r = $script:FslLatestResult
    if ($r -and ((Get-Date) - $r.At).TotalMinutes -lt $(if ($r.Result.Ok) { 60 } else { 5 })) { return }
    if ($script:TestMode) { $script:FslLatestResult = @{ Result = (Get-AVDTuneFSLogixLatest -F $script:FslFake.F); At = (Get-Date) }; return }
    $ps = New-AVDTunePowerShell
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
    # the window is closing: a lookup or a read of the page that still runs is stopped without waiting (the process ends right after); its runspace is discarded
    $job = $script:FslLatestLookup; $script:FslLatestLookup = $null
    if ($job) { try { [void]$job.PS.BeginStop($null, $null) } catch { } }
    $read = $script:FslReadJob; $script:FslReadJob = $null
    if ($read -and $read.PS) { try { [void]$read.PS.BeginStop($null, $null) } catch { } }
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
    $st = $script:FslState
    if (-not $st) { Set-FslPill $ui.PillFslInstall $ui.TxtFslInstallPill 'info'; $ui.TxtFslInstallPill.Text = (T 'fsl.reading'); $ui.PillFslInstall.ToolTip = $null; $ui.TxtFslVersion.Text = (T 'fsl.reading.install'); return }
    $info = $st.Info
    $vs = $null
    if ($info.Installed) {
        Start-FslLatestLookup
        $vs = Get-AVDTuneFSLogixVersionState -Installed $info.Version -Latest $(if ($script:FslLatestResult) { $script:FslLatestResult.Result })
        if ($script:FslLatestLookup -and -not $script:FslLatestResult) { Set-FslPill $ui.PillFslInstall $ui.TxtFslInstallPill 'info'; $ui.TxtFslInstallPill.Text = (T 'fsl.checkupdates') }
        else { Set-FslPill $ui.PillFslInstall $ui.TxtFslInstallPill $vs.Pill; $ui.TxtFslInstallPill.Text = $vs.Text }
        $ui.PillFslInstall.ToolTip = $(if ($vs.Reason) { $vs.Reason } else { $null })
        $svc = if ($info.Frxsvc.Present) { "frxsvc $($info.Frxsvc.Status)" } else { 'frxsvc missing' }
        $drv = if (-not $info.DriversRead) { 'drivers not read' } elseif ($info.Drivers.Count -gt 0) { "drivers: $($info.Drivers -join ', ')" } else { 'no filter driver loaded' }
        $ui.TxtFslVersion.Text = (T 'fsl.version' $($info.Version) $svc $drv)
    }
    else { Set-FslPill $ui.PillFslInstall $ui.TxtFslInstallPill 'red'; $ui.TxtFslInstallPill.Text = (T 'ov.val.notinstalled'); $ui.TxtFslVersion.Text = (T 'fsl.notinstalled') }
    $ui.TxtFslLatest.Text = $(if ($vs -and $vs.State -in 'Update', 'Unknown' -and $vs.Reason -and -not $script:FslLatest) { $vs.Reason } elseif ($script:FslLatest) { $script:FslLatest } else { (T 'fsl.newest.hint') })
}

# ---------------------------------------------------------------- the form: settings
function Update-FslSettings {
    $st = $script:FslState
    if (-not $st) { $ui.TxtFslSettingsState.Text = (T 'fsl.reading.settings'); return }
    $keep = @{}; foreach ($k in $script:FslInputs.Keys) { $e = $script:FslInputs[$k]; if ($e.Box.Text -ne $e.Shown) { $keep[$k] = $e.Box.Text } }   # only what the administrator typed
    $ui.PanelFslSettings.Children.Clear(); $script:FslInputs = @{}
    $odfcHead = $false
    foreach ($s in @($st.Settings)) {
        if ($s.Scope -eq 'ODFC' -and -not $odfcHead) { $odfcHead = $true; [void]$ui.PanelFslSettings.Children.Add((New-UpdGroupHead (T 'fsl.head.odfc'))) }
        elseif ($s.Scope -eq 'Profile' -and $s.Name -eq 'Enabled') { [void]$ui.PanelFslSettings.Children.Add((New-UpdGroupHead (T 'fsl.head.profile'))) }
        $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,5,0,5'
        foreach ($w in 220, 240, 140, 90, '*') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
        $name = New-Object System.Windows.Controls.TextBlock; $name.Text = $s.Name; $name.FontWeight = 'SemiBold'; $name.VerticalAlignment = 'Center'
        $box = New-Object System.Windows.Controls.TextBox; $box.Padding = '6,4'; $box.Margin = '0,0,10,0'; $box.VerticalAlignment = 'Center'; $box.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
        $shown = Format-FslValue $s.Current
        $key = "$($s.Scope):$($s.Name)"
        $box.Text = $(if ($keep.ContainsKey($key)) { $keep[$key] } else { $shown })
        [System.Windows.Automation.AutomationProperties]::SetName($box, "$($s.Scope) setting $($s.Name)")
        $rec = New-Object System.Windows.Controls.TextBlock; $rec.Text = $(if ($null -ne $s.Recommended) { (T 'fsl.recommended' $($s.Recommended)) } else { '' }); $rec.VerticalAlignment = 'Center'; $rec.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2)
        Set-Brush $rec ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
        $pillStatus = switch ($s.Status) { 'ok' { 'green' } 'differs' { 'yellow' } default { 'info' } }
        $pill = New-FslPillBlock $pillStatus $(switch ($s.Status) { 'ok' { 'Set' } 'differs' { 'Differs' } default { 'Not set' } }); $pill.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 3)
        $why = New-Object System.Windows.Controls.TextBlock; $why.Text = $s.Explain + $(if (-not $s.Verified -and $s.Note) { (T 'fsl.learn' $($s.Note)) }); $why.TextWrapping = 'Wrap'; $why.FontSize = 12; $why.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 4)
        Set-Brush $why ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
        $tip = "Source: $($s.Source)`r`nA recommendation stated on Microsoft Learn: $(if ($s.Verified) { 'yes' } else { 'no' })$(if ($s.Note) { "`r`n" + $s.Note })"
        foreach ($e in $name, $box, $rec, $pill, $why) { $e.ToolTip = $tip; [void]$g.Children.Add($e) }
        [void]$ui.PanelFslSettings.Children.Add($g)
        $script:FslInputs[$key] = @{ Box = $box; Scope = $s.Scope; Name = $s.Name; Type = $s.Type; Shown = $shown; Recommended = $s.Recommended }
    }
    $lc = $st.LastChange
    $ui.TxtFslSettingsState.Text = if ($lc) { (T 'fsl.lastchange' $(([datetime]$lc.At).ToString('yyyy-MM-dd HH:mm')) $($lc.User) $($lc.Plan)) } else { (T 'fsl.nochange') }
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
    $ui.TxtFslSettingsState.Text = (T 'fsl.filled')
}
Add-Click $ui.BtnFslSettingsTest {
    # a dry run: reads the registry values of the form (quick) and writes nothing
    $vals = Get-FslFormValues
    if ($vals.Count -eq 0) { $ui.TxtFslSettingsState.Text = (T 'fsl.nothingtochange'); return }
    $run = Set-AVDTuneFSLogixSettings -Machine $script:Machine -Root $script:StateRoot -Values $vals -WhatIf
    $lines = @($run.Results | ForEach-Object { "$($_.Id -replace '^fslogix\.', ''): $($_.Status)$(if ($_.Status -eq 'WhatIf') { " (now $(Format-FslValue $_.Before))" })" })
    $ui.TxtFslSettingsState.Text = (T 'fsl.test.prefix') + ($lines -join '; ')
}
Add-Click $ui.BtnFslSettingsApply {
    Assert-FslWrite
    $vals = Get-FslFormValues
    if ($vals.Count -eq 0) { throw (T 'fsl.nothingtochange') }
    # the same Apply also sets the recommended lists: what it would change there comes from the read of the page and is named in this one confirmation (nothing is said when the lists stay as they are)
    $listPlan = $script:FslState.Plan
    $listText = Format-AVDTuneFSLogixListChanges $listPlan
    $askText = "Write $($vals.Count) FSLogix setting(s) to the registry of this master?$(if ($listText) { " Also: $listText.$(if ($listPlan.Notice) { ' ' + $listPlan.Notice })" })"
    if (-not (Confirm-Action $askText (T 'fsl.settings.title'))) { return }
    Start-FslJob 'Settings' @{ Values = $vals; Lists = [bool]$listText; ListHash = (Get-AVDTuneFSLogixListPlanHash $listPlan) }   # the job writes the lists only when they are still as confirmed
}
Add-Click $ui.BtnFslSettingsUndo {
    Assert-FslWrite
    if (-not (Confirm-Action (T 'fsl.ask.undosettings') 'Undo')) { return }
    Start-FslJob 'SettingsUndo' @{}
}

# ---------------------------------------------------------------- groups
function Get-FslGroupChoices { if ($script:FslState) { $script:FslState.Choices } else { Get-AVDTuneFSLogixGroupChoices -Root $script:StateRoot -Answers (Get-FslAnswers) } }
function Resolve-FslSid([string]$Text, $Choices) {
    $t = $Text.Trim()
    if (Test-AVDTuneSid $t) { return $t }
    $hit = @($Choices.Groups | Where-Object { $_.Name -ieq $t })
    if ($hit.Count -gt 0) { return [string]$hit[0].Sid }
    $null
}
function Update-FslGroups {
    $st = $script:FslState
    if (-not $st) { $ui.TxtFslGroups.Text = (T 'fsl.reading.lists'); return }
    $g = $st.Groups
    $fmt = { param($l) if ($null -eq $l) { 'the group does not exist' } elseif (@($l).Count -eq 0) { '(empty)' } else { @($l) -join ', ' } }
    $ui.TxtFslGroups.Text = (T 'fsl.lists' $($g.IncludeName) $(& $fmt $g.Include) $($g.ExcludeName) $(& $fmt $g.Exclude))
    $ch = $st.Choices
    foreach ($cmb in $ui.CmbFslGroup, $ui.CmbFslUsersGroup, $ui.CmbFslAdminsGroup) { $keepText = $cmb.Text; $cmb.ItemsSource = @($ch.Groups | ForEach-Object { $_.Name }); $cmb.Text = $keepText }
    $plan = $st.Plan
    $want = @(foreach ($l in 'Include', 'Exclude') { $x = @($plan.Entries | Where-Object { $_.List -eq $l }); if ($x.Count -gt 0) { "$($l.ToLowerInvariant()) $((@($x | ForEach-Object { $_.Label })) -join ', ')" } }) -join '; '
    $ui.TxtFslListsNotice.Text = (T 'fsl.lists.recommended' $want $(if ($plan.Notice) { ' ' + $plan.Notice }))
    $ui.TxtFslGroupHint.Text = $(if ($ch.Source -eq 'Directory') { (T 'fsl.lists.groups' $(@($ch.Groups).Count)) } else { $ch.Hint })
}
function Invoke-FslGroupChange([string]$Action, [string]$Text) {
    Assert-FslWrite
    $list = [string]$ui.CmbFslList.SelectedItem
    $sid = Resolve-FslSid $Text (Get-FslGroupChoices)
    if (-not $sid) { throw "'$Text' is neither a group of the domain nor a SID (S-1-...)." }
    if (-not (Confirm-Action (T 'fsl.ask.listmember' $Action $sid $list) (T 'fsl.lists.title'))) { return }
    Start-FslJob 'Group' @{ List = $list; Action = $Action; Sid = $sid }
}
function Invoke-FslRecommendedLists {
    # Include = Everyone (only while the list is empty), Exclude = local Administrators (+ Domain Admins of a domain SID that was checked); what changes comes from the read
    # of the page and is named in the confirmation. Nothing to change = nothing asked, nothing written. (The settings Apply sets them in the same job.)
    Assert-FslWrite
    $plan = $script:FslState.Plan
    $text = Format-AVDTuneFSLogixListChanges $plan
    if (-not $text) { $ui.TxtFslState.Text = (T 'fsl.lists.alreadyset' $(if ($plan.Notice) { ' ' + $plan.Notice })); Show-Toast $ui.TxtFslState.Text; return }
    if (-not (Confirm-Action (T 'fsl.ask.lists' $text $(if ($plan.Notice) { ' ' + $plan.Notice })) (T 'fsl.lists.title'))) { return }
    Start-FslJob 'Lists' @{ ListHash = (Get-AVDTuneFSLogixListPlanHash $plan) }   # the job writes only when the lists are still as confirmed
}
Add-Click $ui.BtnFslListsApply { Invoke-FslRecommendedLists }
Add-Click $ui.BtnFslListsUndo {
    Assert-FslWrite
    if (-not (Confirm-Action (T 'fsl.ask.undolists') 'Undo')) { return }
    Start-FslJob 'ListsUndo' @{}
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
        $cb.Content = (T 'fsl.redir.group' $($t.Group) $(@($t.Paths).Count)) + $(if (-not $t.Verified) { (T 'fsl.redir.unverified') } else { (T 'fsl.redir.learn') })
        $cb.IsChecked = [bool]$t.Verified; $cb.Margin = '0,2,0,2'; $cb.ToolTip = "$($t.Note)`r`n$(@($t.Paths) -join "`r`n")"
        [System.Windows.Automation.AutomationProperties]::SetName($cb, (T 'fsl.redir.group.name' $($t.Group)))
        [void]$ui.PanelFslTemplate.Children.Add($cb)
        $script:FslTemplateBoxes[$t.Group] = $cb
    }
}
function Update-FslRedirections {
    # prefilled: the folder set in the registry, otherwise <ProgramData>\AVDTune-Public\FSLogix\Redirections; only the groups are left to pick (the folder is created protected on save)
    $st = $script:FslState
    if (-not $st) { return }
    if (-not $ui.TxtFslRedirFolder.IsKeyboardFocused -and -not $ui.TxtFslRedirFolder.Text) { $ui.TxtFslRedirFolder.Text = [string]$st.RedirDefault }
    if (-not $ui.TxtFslRedirXml.Text -and $st.RedirTarget) {
        if ($st.RedirError) { $ui.TxtFslRedirState.Text = (T 'fsl.redir.readfail' $($st.RedirTarget) $($st.RedirError)) }
        elseif ($null -ne $st.RedirText) { $ui.TxtFslRedirXml.Text = [string]$st.RedirText; $ui.TxtFslRedirState.Text = (T 'fsl.redir.readfrom' $($st.RedirTarget)) }
    }
}
Add-Click $ui.BtnFslRedirGenerate {
    $paths = @(foreach ($t in (Get-AVDTuneRedirectionTemplate)) { if ($script:FslTemplateBoxes[$t.Group].IsChecked) { $t.Paths } })
    if ($paths.Count -eq 0) { throw 'Tick at least one template group.' }
    $ui.TxtFslRedirXml.Text = New-AVDTuneRedirectionsXml -Excludes $paths -ExcludeCommonFolders 0
    $ui.TxtFslRedirState.Text = (T 'fsl.redir.generated' $($paths.Count))
}
Add-Click $ui.BtnFslRedirValidate {
    $v = Test-AVDTuneRedirectionsXml $ui.TxtFslRedirXml.Text
    $ui.TxtFslRedirState.Text = if ($v.Ok) { (T 'fsl.redir.valid' $($v.Excludes.Count) $($v.Includes.Count) $($v.ExcludeCommonFolders)) } else { (T 'fsl.redir.invalid') + ($v.Problems -join ' ') }
}
Add-Click $ui.BtnFslRedirSave {
    Assert-FslWrite
    $folder = $ui.TxtFslRedirFolder.Text.Trim()
    if (-not $folder) { throw 'Enter the folder (RedirXMLSourceFolder), a share or a local folder. Users need read access to it.' }
    if (-not (Confirm-Action (T 'fsl.ask.redir' $folder) (T 'fsl.title.redir'))) { return }
    Start-FslJob 'Redirections' @{ Xml = [string]$ui.TxtFslRedirXml.Text; Folder = $folder }
}
Add-Click $ui.BtnFslRedirUndo {
    Assert-FslWrite
    if (-not (Confirm-Action (T 'fsl.ask.undoredir') 'Undo')) { return }
    Start-FslJob 'RedirectionsUndo' @{}
}

# ---------------------------------------------------------------- Defender
function Update-FslDefender {
    $ui.PanelFslDefender.Children.Clear()
    $st = $script:FslState
    if (-not $st) { $ui.TxtFslDefState.Text = (T 'fsl.reading.defender'); return }
    $s = $st.Defender
    if (-not $s.Readable) { $ui.TxtFslDefState.Text = (T 'fsl.defender.unreadable'); return }
    $open = @($s.Items | Where-Object { -not $_.Present }).Count
    $ui.TxtFslDefState.Text = (T 'fsl.defender.count' $(@($s.Items).Count - $open) $(@($s.Items).Count) $(if (@($s.NotDefender).Count -gt 0) { (T 'fsl.defender.other') + ((@($s.NotDefender) | ForEach-Object { $_.Value }) -join '; ') + '.' }))
    foreach ($i in $s.Items) {
        $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,2,0,2'
        foreach ($w in 30, 100, 80, '*') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
        # one checkbox per exclusion (default on): what is switched off is not set and not in the undo list. A set exclusion cannot be switched off here (Undo removes the ones AVDTune added).
        $chk = New-Object System.Windows.Controls.CheckBox; $chk.VerticalAlignment = 'Center'; $chk.Tag = [string]$i.Value
        $chk.IsChecked = (-not $i.Present -and -not $script:FslDefOff.ContainsKey(([string]$i.Value).ToLowerInvariant())) -or [bool]$i.Present; $chk.IsEnabled = -not $i.Present
        [System.Windows.Automation.AutomationProperties]::SetName($chk, (T 'fsl.defender.item.name' $($i.Value)))
        $chk.Add_Checked({ param($src, $e) try { $script:FslDefOff.Remove(([string]$src.Tag).ToLowerInvariant()) } catch { } })
        $chk.Add_Unchecked({ param($src, $e) try { $script:FslDefOff[([string]$src.Tag).ToLowerInvariant()] = $true } catch { } })
        $pill = New-FslPillBlock $(if ($i.Present) { 'green' } else { 'yellow' }) $(if ($i.Present) { 'Set' } else { 'Missing' })
        $pill.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
        $kind = New-Object System.Windows.Controls.TextBlock; $kind.Text = $i.Kind; $kind.VerticalAlignment = 'Center'; $kind.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2); Set-Brush $kind ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
        $val = New-Object System.Windows.Controls.TextBlock; $val.Text = $i.Value + $(if ($i.Risk) { (T 'fsl.defender.risk' $($i.Risk)) }); $val.FontFamily = 'Cascadia Mono, Consolas'; $val.FontSize = 12; $val.TextWrapping = 'Wrap'; $val.VerticalAlignment = 'Center'; $val.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 3)
        [void]$g.Children.Add($chk)
        foreach ($e in $pill, $kind, $val) { $e.ToolTip = (T 'fsl.defender.tip' $($i.Reason) $($i.Source) $(if ($i.Verified) { 'yes' } else { 'no' }) $(if ($i.Note) { "`r`n" + $i.Note })); [void]$g.Children.Add($e) }
        [void]$ui.PanelFslDefender.Children.Add($g)
    }
}
Add-Click $ui.BtnFslDefAdd {
    Assert-FslWrite
    $off = @($script:FslDefOff.Keys)
    if (-not (Confirm-Action (T 'fsl.ask.defender' $(if ($off.Count -gt 0) { " $($off.Count) are unticked and will not be set." })) (T 'fsl.defender.title'))) { return }
    Start-FslJob 'Defender' @{ Skip = $off; DefenderHash = (Get-AVDTuneFSLogixDefenderHash -State $script:FslState.Defender -Skip $off) }   # the job sets only what was confirmed
}
Add-Click $ui.BtnFslDefUndo {
    Assert-FslWrite
    if (-not (Confirm-Action (T 'fsl.ask.undodefender') 'Undo')) { return }
    Start-FslJob 'DefenderUndo' @{}
}

# ---------------------------------------------------------------- results: function test and storage check
function Update-FslTestView {
    $ui.PanelFslTest.Children.Clear()
    $rec = if ($script:FslState) { $script:FslState.TestRecord } else { $null }
    $r = $script:FslTest
    if ($r) {
        Set-FslPill $ui.PillFslTest $ui.TxtFslTestPill $r.Overall; $ui.TxtFslTestPill.Text = $script:ReadyPill[$r.Overall][2]
        $ui.TxtFslTestSummary.Text = (T 'fsl.test.summary' $($r.Counts.Red) $($r.Counts.Yellow) $($r.Counts.Green) $(if ($r.WriteTests) { (T 'fsl.test.withwrite') } else { (T 'fsl.test.withoutwrite') }) $(([datetime]$r.At).ToString('HH:mm:ss')))
        $order = @{ red = 0; yellow = 1; green = 2; info = 3 }
        foreach ($row in ($r.Rows | Sort-Object { $order[[string]$_.Status] }, Step)) { [void]$ui.PanelFslTest.Children.Add((New-FslResultRow $row)) }
    }
    elseif ($rec) { Set-FslPill $ui.PillFslTest $ui.TxtFslTestPill $rec.Overall; $ui.TxtFslTestPill.Text = $script:ReadyPill[[string]$rec.Overall][2]; $ui.TxtFslTestSummary.Text = (T 'fsl.test.last' $(([datetime]$rec.At).ToString('yyyy-MM-dd HH:mm')) $($rec.User) $($rec.Red) $($rec.Yellow)) }
    else { Set-FslPill $ui.PillFslTest $ui.TxtFslTestPill 'unknown'; $ui.TxtFslTestPill.Text = (T 'ready.pill.notrun'); $ui.TxtFslTestSummary.Text = (T 'fsl.test.notrun') }
}
function Update-FslStorageView {
    $ui.PanelFslStorage.Children.Clear()
    $r = $script:FslStorage
    $undo = Get-AVDTuneStorageAclUndo -Root $script:StateRoot
    $ui.BtnFslAclUndo.Visibility = $(if ($undo) { 'Visible' } else { 'Collapsed' })   # the ACL AVDTune set can be put back (#24)
    if (-not $r) { $ui.TxtFslStorageSummary.Text = (T 'fsl.storage.notrun'); $ui.BtnFslAclSet.Visibility = 'Collapsed'; $ui.TxtFslAclDiff.Visibility = 'Collapsed'; return }
    $ui.TxtFslStorageSummary.Text = (T 'fsl.storage.summary' $($r.Account) $($r.Overall) $($r.Counts.Red) $($r.Counts.Yellow) $($r.Counts.Unknown) $($r.Counts.Green) $(if ($r.KeyUsed) { (T 'fsl.storage.keyused') }))
    $order = @{ red = 0; yellow = 1; unknown = 2; green = 3; info = 4 }
    foreach ($row in ($r.Rows | Sort-Object { $order[[string]$_.Status] }, Step)) { [void]$ui.PanelFslStorage.Children.Add((New-FslResultRow $row)) }
    if ($r.AclDiff) {
        $d = $r.AclDiff
        $ui.TxtFslAclDiff.Text = (T 'fsl.acl.now') + ($d.Found -join "`r`n  ") + (T 'fsl.acl.recommended') + ($d.Expected -join "`r`n  ") + (T 'fsl.acl.findings') + (($d.Findings | ForEach-Object { "$($_.Status): $($_.Text)" }) -join "`r`n  ")
        $ui.TxtFslAclDiff.Visibility = 'Visible'; $ui.BtnFslAclSet.Visibility = 'Visible'
    }
    else { $ui.TxtFslAclDiff.Visibility = 'Collapsed'; $ui.BtnFslAclSet.Visibility = 'Collapsed' }
}

# ---------------------------------------------------------------- background work
# One worker for the runspace and for the test mode (inline): a script block made from this text, so it does not belong to the UI runspace.
# Install, Test and Storage are the long checks and the install; the other kinds are the changes of the page (#72), each a run through Invoke-AVDTune (gate, change log, LastChange).
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
    'Settings' {
        # the settings and, when the confirmation named list changes, the recommended lists in the same job (no other writer between them); the lists only when no setting failed
        # the lists as confirmed: checked before anything is written (a list that changed since the read stops the whole job) and again by the module when it writes
        if ($C.Args.Lists) {
            if (-not $C.Args.ListHash) { throw 'The confirmed state of the lists is missing. Nothing was written.' }
            if ((Get-AVDTuneFSLogixListPlanHash (Get-AVDTuneFSLogixListPlan -F $C.F -Root $C.Root -Answers $C.Answers)) -ne $C.Args.ListHash) { throw 'The FSLogix lists changed after they were read. Nothing was written: read the page again and confirm the new state.' }
        }
        $run = Set-AVDTuneFSLogixSettings -Machine $C.Machine -Root $C.Root -Values $C.Args.Values -User $C.User -SnapshotId $C.SnapshotId
        $lists = $null
        if ($C.Args.Lists -and @($run.Results | Where-Object { $_.Status -eq 'Failed' }).Count -eq 0) { $lists = Set-AVDTuneFSLogixRecommendedLists -Machine $C.Machine -F $C.F -Root $C.Root -Answers $C.Answers -User $C.User -SnapshotId $C.SnapshotId -ExpectedHash $C.Args.ListHash }
        [pscustomobject]@{ Runs = @(@($run, $lists) | Where-Object { $_ }) }
    }
    'SettingsUndo' { [pscustomobject]@{ Runs = @(Undo-AVDTuneFSLogixSettings -Machine $C.Machine -Root $C.Root -User $C.User -SnapshotId $C.SnapshotId) } }
    'Group' { [pscustomobject]@{ Runs = @(Set-AVDTuneFSLogixGroupMember -Machine $C.Machine -F $C.F -Root $C.Root -List $C.Args.List -Action $C.Args.Action -Sid $C.Args.Sid -User $C.User -SnapshotId $C.SnapshotId) } }
    'Lists' { if (-not $C.Args.ListHash) { throw 'The confirmed state of the lists is missing. Nothing was written.' }; [pscustomobject]@{ Runs = @(Set-AVDTuneFSLogixRecommendedLists -Machine $C.Machine -F $C.F -Root $C.Root -Answers $C.Answers -User $C.User -SnapshotId $C.SnapshotId -ExpectedHash $C.Args.ListHash) } }
    'ListsUndo' { [pscustomobject]@{ Runs = @(Undo-AVDTuneFSLogixRecommendedLists -Machine $C.Machine -F $C.F -Root $C.Root -User $C.User -SnapshotId $C.SnapshotId) } }
    'Redirections' { [pscustomobject]@{ Runs = @(Save-AVDTuneRedirections -Machine $C.Machine -F $C.F -Root $C.Root -Xml $C.Args.Xml -Folder $C.Args.Folder -User $C.User -SnapshotId $C.SnapshotId) } }
    'RedirectionsUndo' { [pscustomobject]@{ Runs = @(Undo-AVDTuneRedirections -Machine $C.Machine -F $C.F -Root $C.Root -User $C.User -SnapshotId $C.SnapshotId) } }
    'Defender' { if (-not $C.Args.DefenderHash) { throw 'The confirmed state of the Defender exclusions is missing. Nothing was set.' }; [pscustomobject]@{ Runs = @(Set-AVDTuneFSLogixDefender -Machine $C.Machine -F $C.F -Root $C.Root -VhdLocations @(Get-AVDTuneFSLogixLocations -Machine $C.Machine) -User $C.User -SnapshotId $C.SnapshotId -Skip @($C.Args.Skip) -ExpectedHash $C.Args.DefenderHash) } }
    'DefenderUndo' { [pscustomobject]@{ Runs = @(Undo-AVDTuneFSLogixDefender -Machine $C.Machine -F $C.F -Root $C.Root -User $C.User -SnapshotId $C.SnapshotId) } }
    'AclUndo' {
        # review F2: the shares of this master's VHDLocations (the environment of the page), read here in the worker
        $allowed = @(Get-AVDTuneFSLogixLocations -Machine $C.Machine | ForEach-Object { Split-AVDTuneUncShare $_ } | Where-Object { $_ -and $_.IsAzureFiles } | ForEach-Object { "$($_.Account)/$($_.Share)" })
        Undo-AVDTuneStorageRootAcl -Files $C.Files -Token $C.StorageToken -AllowedShares $allowed -Root $C.Root -User $C.User -SnapshotId $C.SnapshotId
    }
    'Acl' { Set-AVDTuneStorageRootAcl -Files $C.Files -Account $C.Args.Account -Share $C.Args.Share -Token $C.StorageToken -UsersSid $C.Args.UsersSid -AdminsSid $C.Args.AdminsSid -ConfirmedHash $C.Args.Hash -Root $C.Root -User $C.User -SnapshotId $C.SnapshotId }
    default { throw "Unknown FSLogix job '$Kind'." }
}
'@

function Get-FslSids {
    $ch = Get-FslGroupChoices
    $users = @(); $admins = @()
    if ($ui.CmbFslUsersGroup.Text.Trim()) { $s = Resolve-FslSid $ui.CmbFslUsersGroup.Text $ch; if ($s) { $users = @($s) } }
    if ($ui.CmbFslAdminsGroup.Text.Trim()) { $s = Resolve-FslSid $ui.CmbFslAdminsGroup.Text $ch; if ($s) { $admins = @($s) } }
    @{ Users = $users; Admins = $admins }
}
function Get-FslKindText([string]$Kind) {
    # the name of a task kind in the chosen language (keys fsl.kind.*), the kind itself when there is no key
    $k = 'fsl.kind.' + $Kind.ToLowerInvariant()
    if ((Test-AVDTuneTextKey $k) -and (Test-AVDTuneHasText $k)) { T $k } else { $Kind }
}
function New-FslTask([string]$Kind, [bool]$Write) {
    # Retry only for what reads (function test without the write tests, storage check): the install, the write tests that create files on the share and every change of
    # the master or the share start from their own confirmation
    # title and step on the task bar in the chosen language (keys fsl.task.* and fsl.step.*)
    $title = if ($Kind -eq 'Test' -and $Write) { T 'fsl.task.testwrite' } elseif ($Kind -in 'Install', 'Test', 'Storage', 'Settings', 'SettingsUndo', 'Group', 'Lists', 'ListsUndo', 'Redirections', 'RedirectionsUndo', 'Defender', 'DefenderUndo', 'AclUndo') { T ('fsl.task.' + $Kind.ToLowerInvariant()) } else { T 'fsl.task.acl' }
    $step = if ($Kind -in 'Install', 'Test', 'Storage', 'Settings', 'Redirections', 'Defender', 'Acl', 'AclUndo') { T ('fsl.step.' + $Kind.ToLowerInvariant()) } else { T 'fsl.step.other' }
    $taskKind = switch ($Kind) {
        { $_ -in 'Settings', 'SettingsUndo' } { 'fslogix-settings' } { $_ -in 'Lists', 'ListsUndo' } { 'fslogix-lists' } 'Group' { 'fslogix-groups' } { $_ -in 'Redirections', 'RedirectionsUndo' } { 'fslogix-redirections' }
        { $_ -in 'Defender', 'DefenderUndo' } { 'fslogix-defender' } { $_ -in 'Acl', 'AclUndo' } { 'fslogix-acl' } default { "fslogix-$($Kind.ToLower())" }
    }
    $retry = if ($Kind -eq 'Test' -and -not $Write) { @{ Command = 'Start-FslJob'; Arguments = @('Test', @{ Write = $false }) } } elseif ($Kind -eq 'Storage') { @{ Command = 'Start-FslJob'; Arguments = @('Storage', @{}) } }
    Start-AVDTuneUiTask -Kind $taskKind -Title $title -Step $step -Retry $retry
}
function Get-FslStorageToken {
    # The Storage audience token for the ACL rows (memory only, goes to the Files adapter of the checked account). Without it the reason says why (not signed in, or the registration was made before issue 18: set up again).
    $s = $script:StartContext.Session
    if (-not $s -or -not $s.Connected) { return @{ Token = ''; Reason = 'no token for Azure Storage (https://storage.azure.com/): not signed in. Sign in on the Overview.' } }
    try { @{ Token = (Get-AVDTuneAccessToken -Session $s -Audience Storage); Reason = '' } } catch { @{ Token = ''; Reason = 'no token for Azure Storage (https://storage.azure.com/): ' + $_.Exception.Message } }
}
function Start-FslJob([string]$Kind, [hashtable]$Arg = @{}) {
    if ($script:FslJob) { throw 'Another FSLogix operation is still running.' }
    Assert-NoOtherWriter
    if ($Kind -in $script:FslChangeKinds) { Assert-FslFresh }   # a change is worked out from the read of the page: not while it runs, not from a failed one
    $sids = Get-FslSids
    $gate = Get-AVDTuneWriteGate
    $common = @{ Root = $script:StateRoot; User = (Get-FslUser); SnapshotId = $(if ($gate) { [string]$gate.SnapshotId } else { '' }); UsersSids = $sids.Users; AdminsSids = $sids.Admins; Write = [bool]$Arg.Write; Args = $Arg; Answers = (Get-FslAnswers) }
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
    if ($Kind -in 'Acl', 'AclUndo') { $st = Get-FslStorageToken; if (-not $st.Token) { throw "The NTFS ACL cannot be changed: $($st.Reason)" }; $common.StorageToken = $st.Token }   # the Storage token of the sign-in (memory only, removed with the job; #24)
    if ($script:TestMode) {
        $c = $common.Clone(); $c.Machine = $script:Machine; $c.F = $script:FslFake.F; $c.Progress = $null
        if ($Kind -eq 'Storage') { $c.Arm = $script:FslFake.Arm; $c.Files = $script:FslFake.Files; $c.Ldap = $script:FslFake.Ldap; $c.FakeLdap = $true; $c.ArmToken = 'fake-arm-token' }   # the storage token comes from the fake session through Get-FslStorageToken (in $common), like in real use
        if ($Kind -in 'Acl', 'AclUndo') { $c.Files = $script:FslFake.Files }
        $res = $null; $err = ''
        try { $res = & ([scriptblock]::Create($script:FslWorkerText)) $Kind $c } catch { $err = $_.Exception.Message }
        $c.StorageToken = $null; $c.ArmToken = $null; $c.TestPassword = $null
        $script:FslJob = @{ Inline = $true; Result = $res; Err = $err; Kind = $Kind; Write = [bool]$Arg.Write; Task = (New-FslTask $Kind ([bool]$Arg.Write)); Common = $common }
    }
    else {
        $sync = [hashtable]::Synchronized(@{ Text = '' })
        $ps = New-AVDTunePowerShell
        [void]$ps.AddScript({
                param($AppRoot, $Kind, $Common, $Gate, $Sync, $WorkerText)
                $ErrorActionPreference = 'Stop'
                Import-Module (Join-Path $AppRoot 'Modules\AVDTune.psm1') -Force
                Import-Module (Join-Path $AppRoot 'Modules\AVDTune.Updates.psm1') -Force
                Import-Module (Join-Path $AppRoot 'Modules\AVDTune.Snapshot.psm1') -Force
                Import-Module (Join-Path $AppRoot 'Modules\AVDTune.Directory.psm1') -Force
                Import-Module (Join-Path $AppRoot 'Modules\AVDTune.FSLogix.psm1') -Force
                Import-Module (Join-Path $AppRoot 'Modules\AVDTune.Storage.psm1') -Force
                $c = $Common.Clone(); $c.Machine = New-AVDTuneMachine; $c.F = New-AVDTuneFSLogixAdapter; $c.Progress = { param($t) $Sync.Text = $t }
                if ($Kind -eq 'Storage') { $c.Arm = New-AVDTuneArmAdapter; $c.Files = New-AVDTuneFilesAdapter; $c.Ldap = New-AVDTuneLdapAdapter; $c.FakeLdap = $false }
                if ($Kind -in 'Acl', 'AclUndo') { $c.Files = New-AVDTuneFilesAdapter }
                if ($Gate) { Open-AVDTuneWriteGate -SnapshotId $Gate.SnapshotId -ConfirmedBy $Gate.ConfirmedBy -SnapshotCreated ([string](Get-AVDTuneProp $Gate 'SnapshotCreated')) }
                & ([scriptblock]::Create($WorkerText)) $Kind $c
            }).AddArgument($script:AppRoot).AddArgument($Kind).AddArgument($common).AddArgument($gate).AddArgument($sync).AddArgument($script:FslWorkerText)
        $script:FslJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Kind = $Kind; Sync = $sync; Write = [bool]$Arg.Write; Task = (New-FslTask $Kind ([bool]$Arg.Write)); Common = $common }
    }
    Set-ShutdownBlock $true
    Update-FslButtons; Set-FslCursor
    if ($script:CurrentPage -eq 'FSLogix') { $ui.TxtFslState.Text = (T 'fsl.running' $(Get-FslKindText $Kind)) }
}
function Complete-FslChangeTask($Task, $Result) {
    # the task of a change: failed when a step of a run failed or the change says Failed (ACL); otherwise the count of changed steps
    $runs = @(); if ($Result -and $Result.PSObject.Properties['Runs']) { $runs = @($Result.Runs | Where-Object { $_ }) }
    $results = @($runs | ForEach-Object { @($_.Results) } | Where-Object { $_ })
    $failed = @($results | Where-Object { $_.Status -eq 'Failed' })
    if ($runs.Count -eq 0 -and $Result -and $Result.PSObject.Properties['Status'] -and $Result.Status -eq 'Failed') { Complete-AVDTuneUiTask $Task -Failed -Summary ([string]$Result.Message) }
    elseif ($failed.Count -gt 0) { Complete-AVDTuneUiTask $Task -Failed -Summary "$($failed.Count) step(s) failed: $($failed[0].Message)" }
    elseif ($runs.Count -gt 0) { Complete-AVDTuneUiTask $Task -Summary "$(@($results | Where-Object { $_.Status -eq 'Changed' }).Count) changed" }
    else { Complete-AVDTuneUiTask $Task -Summary "$([string]$Result.Status). $([string]$Result.Message)" }
}
function Complete-FslJob {
    $job = $script:FslJob
    if (-not $job) { return }
    if (-not $job.Inline -and -not $job.Handle.IsCompleted) { if ($job.Sync.Text) { Update-AVDTuneUiTask $job.Task -Step ([string]$job.Sync.Text); if ($script:CurrentPage -eq 'FSLogix') { $ui.TxtFslState.Text = $job.Sync.Text } }; return }
    $script:FslJob = $null
    Set-ShutdownBlock $false
    $result = $null; $err = ''; $streamErr = ''
    if ($job.Inline) { $result = $job.Result; $err = [string]$job.Err }
    else {
        try {
            $out = @($job.PS.EndInvoke($job.Handle))
            if ($job.PS.Streams.Error.Count -gt 0) { $streamErr = $job.PS.Streams.Error[0].Exception.Message }
            $result = $out | Select-Object -Last 1
        }
        catch { $err = $_.Exception.Message }
        finally { $job.PS.Dispose() }
    }
    # a result that is there is always evaluated (a change may have been made); an error of the stream is reported in addition (#66)
    if (-not $result -and -not $err) { $err = $(if ($streamErr) { $streamErr } else { 'No result.' }); $streamErr = '' }
    # No token or password stays referenced after the run (the hashtable of the job, the copy of the worker was local to it)
    if ($job.Common) {
        if ($job.Common.ContainsKey('TestPassword') -and $job.Common.TestPassword -is [System.Security.SecureString]) { try { $job.Common.TestPassword.Dispose() } catch { } }   # the copy of the password box is zeroed, not only dropped
        foreach ($k in 'StorageToken', 'ArmToken', 'TestPassword') { if ($job.Common.ContainsKey($k)) { $job.Common[$k] = $null } }; $job.Common = $null
    }
    Update-FslButtons; Set-FslCursor
    $what = Get-FslKindText $job.Kind
    if ($job.Kind -eq 'Storage') { $ui.PwdFslPassword.Clear(); $ui.ChkFslKey.IsChecked = $false }   # the password and the key confirmation are for one run, also after an error
    if ($err -or -not $result) {
        Complete-AVDTuneUiTask $job.Task -Failed -Summary "The $what failed: $err"; $ui.TxtFslState.Text = (T 'fsl.failed' $what $err); Show-Error $ui.TxtFslState.Text
        if ($script:CloseWhenDone) { $script:CloseWhenDone = $false }   # the administrator sees the error first
        Update-FslView; return
    }
    switch ($job.Kind) {
        'Install' {
            Register-StepResult $result.Result
            $ui.TxtFslState.Text = (T 'fsl.installresult' $($result.Install.Status) $($result.Install.Message) $(if ($result.Result.Reboot) { (T 'fsl.restartfirst') }))
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
            $ui.TxtFslState.Text = (T 'fsl.test.result' $($result.Overall) $($result.Counts.Red) $($result.Counts.Yellow) $($result.Counts.Green))
            Complete-AVDTuneUiTask $job.Task -Summary $ui.TxtFslState.Text
            Show-Toast $ui.TxtFslState.Text
            if (-not $script:ReadyJob) { Start-ReadyJob 'Manual' '' } else { $script:ReadyQueued = @{ Kind = 'Manual'; FixId = '' } }   # the healthcheck row follows the test
        }
        'Storage' {
            $script:FslStorage = $result
            [void](Save-AVDTuneStorageCheckRun -Root $script:StateRoot -Result $result -User (Get-FslUser) -SnapshotId (Get-FslGateSnapshot))
            [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'fslogix' -Subject 'FSLogix storage check' -Note "$($result.Overall): $($result.Counts.Red) red, $($result.Counts.Yellow) yellow, $($result.Counts.Unknown) not checkable$(if ($result.KeyUsed) { '; the account key was used for this run (in memory only)' })")
            Save-Protocol
            $ui.TxtFslState.Text = (T 'fsl.storage.result' $($result.Overall))
            Complete-AVDTuneUiTask $job.Task -Summary "Storage check: $($result.Overall) ($($result.Counts.Red) red, $($result.Counts.Yellow) yellow, $($result.Counts.Unknown) not checkable)"
            Show-Toast $ui.TxtFslState.Text
            $ui.PwdFslPassword.Clear(); $ui.ChkFslKey.IsChecked = $false   # the confirmation of the key fallback is for one run
        }
        { $_ -in 'Acl', 'AclUndo' } {
            Complete-FslChangeTask $job.Task $result
            $ui.TxtFslState.Text = "$(Get-FslKindText $job.Kind): $($result.Status). $($result.Message)"; Show-Toast $ui.TxtFslState.Text; Update-FslStorageView
            [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'fslogix' -Subject 'NTFS ACL of the share root' -Note "$($result.Status). $($result.Message)"); Save-Protocol
        }
        default {
            # the changes of the page: every run is shown and registered (protocol, change log); the notice of the lists says what was kept and why
            Complete-FslChangeTask $job.Task $result
            $runs = @($result.Runs | Where-Object { $_ })
            for ($i = 0; $i -lt $runs.Count; $i++) {
                $label = if ($job.Kind -eq 'Settings' -and $i -gt 0) { 'FSLogix lists' } else { $what }
                Show-FslRun $runs[$i] $label
                if ($runs[$i].PSObject.Properties['Notice'] -and $runs[$i].Notice) { $ui.TxtFslState.Text = "$($ui.TxtFslState.Text) $($runs[$i].Notice)"; if ($job.Kind -eq 'ListsUndo') { Show-Toast $ui.TxtFslState.Text } }
            }
            if ($job.Kind -eq 'Redirections') { $ui.TxtFslRedirState.Text = $ui.TxtFslState.Text }
        }
    }
    if ($streamErr) { Show-Error "The $what also reported an error: $streamErr" }
    if ($script:CloseWhenDone -and -not (Get-AVDTuneRunningWriter)) { $window.Close(); return }
    Update-FslView   # the page reads the master again after every job (also after a failed one); changes stay locked until it is read
}
$script:Timer.Add_Tick({ try { Complete-FslJob } catch { Show-Error $_.Exception.Message } })
$script:Timer.Add_Tick({ try { Complete-FslRead } catch { Show-Error $_.Exception.Message } })
$script:Timer.Add_Tick({ try { Complete-FslLatestLookup } catch { } })
# Closing and signing out during a change would end it in the middle: the window waits and closes by itself when it is done (a read-only check does not hold it)
$window.Add_Closing({
        param($src, $e)
        if (-not (Test-FslWriting)) { return }
        $e.Cancel = $true; $script:CloseWhenDone = $true
        Show-Toast 'An FSLogix change is still running. AVDTune closes by itself when it is done.'
    })
$script:FslSessionEnding = [System.Windows.SessionEndingCancelEventHandler]{ param($src, $e) if (Test-FslWriting) { $e.Cancel = $true; Show-Toast 'Log off or shut down was held back: an FSLogix change is still running. Try again when it is done.' } }
if ([System.Windows.Application]::Current) { [System.Windows.Application]::Current.add_SessionEnding($script:FslSessionEnding) }
$window.Add_Closed({ try { if ($script:FslSessionEnding -and [System.Windows.Application]::Current) { [System.Windows.Application]::Current.remove_SessionEnding($script:FslSessionEnding) } } catch { } })   # a handler left on the application keeps the process from ending

Add-Click $ui.BtnFslTest { Start-FslJob 'Test' @{ Write = $false }; $ui.TxtFslState.Text = (T 'fsl.test.running') }
Add-Click $ui.BtnFslTestWrite {
    if (-not (Confirm-Action (T 'fsl.ask.writetests') (T 'fsl.writetests'))) { return }
    Start-FslJob 'Test' @{ Write = $true }; $ui.TxtFslState.Text = (T 'fsl.test.runningwrite')
}
Add-Click $ui.BtnFslInstall {
    Assert-FslWrite
    if (-not (Confirm-Action (T 'fsl.ask.install') 'FSLogix')) { return }
    Start-FslJob 'Install' @{}; $ui.TxtFslState.Text = (T 'fsl.lookingup')
}
Add-Click $ui.BtnFslStorage {
    if ($ui.ChkFslKey.IsChecked -and -not (Confirm-Action (T 'fsl.ask.accountkey') (T 'fsl.accountkey'))) { $ui.ChkFslKey.IsChecked = $false; return }
    Start-FslJob 'Storage' @{}; $ui.TxtFslState.Text = (T 'fsl.storage.running')
}
Add-Click $ui.BtnFslAclSet {
    $r = $script:FslStorage
    if (-not $r -or -not $r.AclDiff) { throw 'Run the storage check first: it shows the diff.' }
    $sids = Get-FslSids
    if ($sids.Users.Count -eq 0 -or $sids.Admins.Count -eq 0) { throw 'Name the users group and the administrators group.' }
    Assert-FslWrite
    if ($r.KeyUsed) { throw 'The ACL was read with the account key; setting it needs the token path (role Storage File Data Privileged Contributor).' }
    if (-not (Confirm-Action (T 'fsl.ask.acl' $($r.AclDiff.Share) $($r.AclDiff.Account)) (T 'fsl.title.acl'))) { return }
    $d = $r.AclDiff
    $share = [pscustomobject]@{ Account = [string]$d.Account; Share = [string]$d.Share }   # the share the check looked at and the administrator saw, not the first location again
    if (-not $share.Account -or -not $share.Share) { throw 'The diff does not name the share: run the storage check again.' }
    Start-FslJob 'Acl' @{ Account = $share.Account; Share = $share.Share; UsersSid = $sids.Users[0]; AdminsSid = $sids.Admins[0]; Hash = $d.Hash }
}

Add-Click $ui.BtnFslAclUndo {
    $u = Get-AVDTuneStorageAclUndo -Root $script:StateRoot
    if (-not $u) { throw 'There is nothing to undo: AVDTune has not set an ACL on a share root.' }
    Assert-FslWrite
    $before = @(); try { $before = @((ConvertFrom-AVDTuneSddl -Sddl $u.Before -DomainSid 'S-1-5-21-1-1-1').Aces | ForEach-Object { Format-AVDTuneAce $_ }) } catch { }
    if (-not (Confirm-Action (T 'fsl.ask.undoacl' $($u.Share) $($u.Account) $($before -join "`r`n  ")) (T 'fsl.title.acl'))) { return }
    Start-FslJob 'AclUndo' @{}
}

# ---------------------------------------------------------------- the page
function Show-FslState {
    # draws the page from the last read (nothing is read here)
    $applies = Test-FslApplies
    $ui.TxtFslSubtitle.Text = $(if ($applies) { (T 'fsl.subtitle') } else { (T 'fsl.notused') })
    Update-FslInstall; Update-FslSettings; Update-FslGroups; Update-FslRedirections; Update-FslDefender; Update-FslTestView; Update-FslStorageView
    Update-FslButtons
}
function Update-FslView {
    # the page is there at once with what the last read found; the master is read again in the background (#72) and the page follows when the read is done
    Start-FslRead
    Show-FslState
}
Build-FslTemplate
