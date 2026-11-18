# The custom software card of the Software page (dot-sourced by Start-AVDTune.ps1 after the Customizations page; plan 3e, issue #87). Logic: Modules\AVDTune.Recording.psm1.
# Why a card and not a tab: the Software page is one column of cards without tabs; the plan's tab "Eigene Software" is this card at its end. It is built in code (no change
# of UI\Software.xaml) and reuses the row and form helpers of the Customizations and App Masking pages; every text comes from the language files (T 'csw.*').
# The installer is a file of the library (AVDTune-Assets, like the customizations of #85): the form takes its SHA256 from the manifest and the recording installs only
# a file that matches it. Reading (list, installed versions, manifest) is a background job; the recording is a writer job (CswJob, #66) behind the write gate.
# Test mode: the fake machine, a fake customization adapter with two fake installers in its library and the fake recording adapter.

$script:CswJob = $null
$script:CswStatus = $null
$script:CswLibrary = $null
$script:CswLibraryError = ''
$script:CswUiBuilt = $false
$script:CswForm = @{}
$script:CswMode = @{ Kind = 'Install'; Id = ''; Name = '' }
$script:CswReadKinds = @('Status')   # the kinds of CswJob that do not change the master (also in WriterReadOnlyKinds)
$script:CswFields = @('Name', 'Vendor', 'Version', 'Contact', 'Installer', 'Arguments', 'Dependencies', 'LicenseNotes', 'TimeoutSeconds')
$script:CswFakeC = $null; $script:CswFakeR = $null
if ($script:TestMode) {
    . (Get-TestScript 'FakeRecording.ps1')   # FakeCustom.ps1 is loaded by the Customizations page
    $script:CswFakeC = New-AVDTuneFakeCustom -Seed @{ Library = @{ 'example-app.msi' = 'Example App 5.2 (fake MSI)'; 'example-app-5.3.msi' = 'Example App 5.3 (fake MSI)' } }
    $cswKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'   # a fake product code made at the start (no fixed id in the product files)
    $script:CswFakeR = New-AVDTuneFakeRecording -Seed @{ Effects = @{
            (& $script:CswFakeC.Sha $script:CswFakeC.Store.Library['example-app.msi']) = @{ ExitCode = 0; Programs = @{ $cswKey = @{ DisplayName = 'Example App'; DisplayVersion = '5.2.0'; Publisher = 'Example Vendor' } }; Files = @{ 'C:\Program Files\Example App\app.exe' = 'f|1|1' }; Shortcuts = @{ 'C:\Users\Public\Desktop\Example App.lnk' = 'C:\Program Files\Example App\app.exe' } }
            (& $script:CswFakeC.Sha $script:CswFakeC.Store.Library['example-app-5.3.msi']) = @{ ExitCode = 3010; Programs = @{ $cswKey = @{ DisplayName = 'Example App'; DisplayVersion = '5.3.0'; Publisher = 'Example Vendor' } } }
        } }
}

# ---------------------------------------------------------------- the job
$script:CswWorkerText = @'
param($AppRoot, $FakeDir, $Root, $Kind, $App, $Mode, $Gate, $Sync, $User, $Tokens, $SiteUrl, $Library, $SharedC, $SharedR)
$ErrorActionPreference = 'Stop'
foreach ($n in 'AVDTune', 'AVDTune.Updates', 'AVDTune.Software', 'AVDTune.FSLogix', 'AVDTune.Directory', 'AVDTune.Masking', 'AVDTune.Custom', 'AVDTune.Recording') { Import-Module (Join-Path $AppRoot "Modules\$n.psm1") -Force }
$ctx = $null
try {
    if ($FakeDir) {
        . (Join-Path $FakeDir 'FakeMachine.ps1'); . (Join-Path $FakeDir 'FakeSoftware.ps1')
        $m = New-AVDTuneFakeMachine; $c = $SharedC; $r = $SharedR   # an own fake machine (only its clock is used); the shared fakes are used by one job at a time
        $lib = New-AVDTuneFakeLibrary
        foreach ($k in @($c.Store.Library.Keys)) { Add-AVDTuneFakeLibraryAsset -Library $lib -Name $k -Content $c.Store.Library[$k] }
        $ctx = New-AVDTuneLibraryContext -SitesToken $lib.SitesToken -GraphToken $lib.GraphToken -SiteUrl $lib.SiteUrl -Library $lib.Library -Transport $lib.Transport
    }
    else {
        $m = New-AVDTuneMachine; $c = New-AVDTuneCustomAdapter; $r = New-AVDTuneRecordingAdapter
        if ($SiteUrl -and $Tokens -and $Tokens.Sites) { $ctx = New-AVDTuneLibraryContext -SitesToken $Tokens.Sites -GraphToken $Tokens.Graph -SiteUrl $SiteUrl -Library $Library }
    }
    if ($Gate) { Open-AVDTuneWriteGate -SnapshotId $Gate.SnapshotId -ConfirmedBy $Gate.ConfirmedBy }
    switch ($Kind) {
        'Status' {
            $lib = $null; $libError = ''
            if ($ctx) { $Sync.Text = 'library'; try { $lib = Get-AVDTuneAssetManifest -Context $ctx } catch { $libError = $_.Exception.Message } }
            elseif ($Tokens -and $Tokens.Reason) { $libError = [string]$Tokens.Reason }
            $Sync.Text = 'status'
            [pscustomobject]@{ Status = (Get-AVDTuneRecordingStatus -R $r -Root $Root); Library = $lib; LibraryError = $libError }
        }
        'Record' { Invoke-AVDTuneRecording -Machine $m -R $r -C $c -App $App -Root $Root -Context $ctx -Kind $Mode -User $User -SnapshotId $Gate.SnapshotId -Progress $Sync }
    }
}
finally { if ($ctx) { Close-AVDTuneLibraryContext $ctx }; $Tokens = $null }
'@

function Start-CswJob([string]$Kind, $App, [string]$Mode = 'Install') {
    if ($script:CswJob) { throw (T 'csw.err.busy') }
    $writes = $Kind -notin $script:CswReadKinds
    if ($writes) {
        if (-not (Test-AVDTuneWriteAllowed)) { throw (T 'shell.readonly') }
        Assert-NoOtherWriter
    }
    $settings = Get-SwSettings
    $siteUrl = [string]$settings.StoreSiteUrl
    $tokens = if ($siteUrl -and -not $script:TestMode) { Get-SwTokens } else { @{ Sites = ''; Graph = ''; Reason = '' } }
    $sync = [hashtable]::Synchronized(@{ Text = '' })
    $ps = New-AVDTunePowerShell
    [void]$ps.AddScript($script:CswWorkerText).AddArgument($script:AppRoot).AddArgument($script:SwFakeDir).AddArgument($script:StateRoot).AddArgument($Kind).AddArgument($App).AddArgument($Mode).AddArgument((Get-AVDTuneWriteGate)).AddArgument($sync).AddArgument((Get-SwUser)).AddArgument($tokens).AddArgument($siteUrl).AddArgument([string]$settings.StoreLibrary).AddArgument($script:CswFakeC).AddArgument($script:CswFakeR)
    $retry = $(if ($Kind -eq 'Status') { @{ Command = 'Start-CswJob'; Arguments = @('Status') } })
    $task = Start-AVDTuneUiTask -Kind "customsoftware-$($Kind.ToLower())" -Title (T "csw.task.$($Kind.ToLower())") -Step (T 'csw.task.start') -Retry $retry
    $script:CswJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Kind = $Kind; Sync = $sync; Task = $task }
    $tokens = $null
    if ($writes) { Set-ShutdownBlock $true }
    Set-CswBusy $true
}

function Set-CswBusy([bool]$Busy) {
    if (-not $script:CswUiBuilt) { return }
    foreach ($b in $ui.BtnCswRecord, $ui.BtnCswNew, $ui.BtnCswRefresh, $ui.PanelCswApps) { $b.IsEnabled = -not $Busy }
}

function Complete-CswJob {
    $job = $script:CswJob
    if (-not $job) { return }
    if (-not $job.Handle.IsCompleted) { $t = [string]$job.Sync.Text; if ($t) { Update-AVDTuneUiTask $job.Task -Step (T "csw.step.$t") }; return }
    $script:CswJob = $null
    if ($job.Kind -notin $script:CswReadKinds) { Set-ShutdownBlock $false }
    $result = $null; $err = ''
    try {
        $out = @($job.PS.EndInvoke($job.Handle))
        if ($job.PS.Streams.Error.Count -gt 0) { $err = $job.PS.Streams.Error[0].Exception.Message }
        $result = $out | Select-Object -Last 1
    }
    catch { $err = $_.Exception.Message }
    finally { $job.PS.Dispose() }
    Set-CswBusy $false
    $failed = [bool]$err; $summary = ''
    if ($job.Kind -eq 'Status') {
        if ($err) { $summary = T 'csw.read.failed' $err }
        else { $script:CswStatus = $result.Status; $script:CswLibrary = $result.Library; $script:CswLibraryError = [string]$result.LibraryError; $summary = T 'csw.read.done' @($script:CswStatus.Apps).Count }
    }
    else {
        $run = if ($result) { $result.Run } else { $null }
        if ($run) { foreach ($r in $run.Results) { Register-StepResult $r } }
        $rec = if ($result) { $result.Record } else { $null }
        if ($rec -and $rec.Result -eq 'Changed') {
            $n = 0; foreach ($p in $rec.Counts.PSObject.Properties) { $n += [int]$p.Value.Added + [int]$p.Value.Changed + [int]$p.Value.Removed }
            $summary = T 'csw.rec.done' $rec.App.Name $n $(if ($rec.Detection) { "$($rec.Detection.Key) $($rec.Detection.Version)" } else { T 'csw.rec.nodetection' }) $result.Folder
            $script:CswMode = @{ Kind = 'Install'; Id = ''; Name = '' }
            Clear-CswForm
        }
        else {
            $failed = $true
            $msg = if ($run) { [string]@($run.Results)[0].Message } else { $err }
            $summary = T 'csw.rec.failed' $(if ($rec) { $rec.App.Name } else { '' }) "$msg $(if ($err -and $run) { $err })".Trim()
        }
        Show-Toast $summary
        [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'software' -Subject $summary)
        Save-Protocol
        Start-OverviewRefresh
    }
    Complete-AVDTuneUiTask $job.Task -Failed:$failed -Summary $summary
    if ($script:CswUiBuilt) { $ui.TxtCswState.Text = $summary }
    if ($job.Kind -ne 'Status' -and -not $script:CswJob) { Start-CswJob 'Status' }
    Update-CswView
}
$script:Timer.Add_Tick({ try { Complete-CswJob } catch { Show-Error $_.Exception.Message } })

# ---------------------------------------------------------------- the card
function Build-CswCard {
    if ($script:CswUiBuilt) { return }
    $stack = $ui.PageSoftware.Children[0].Content
    $c = New-MaskCard (T 'csw.card.title') (T 'csw.card.hint')
    $ui.TxtCswLibrary = New-MaskText '' 'Hint' '0,4,0,0'; [void]$c.Panel.Children.Add($ui.TxtCswLibrary)
    $ui.PanelCswApps = New-Object System.Windows.Controls.StackPanel; $ui.PanelCswApps.Margin = '0,8,0,0'; [void]$c.Panel.Children.Add($ui.PanelCswApps)
    $ui.TxtCswMode = New-MaskText '' 'CardTitle' '0,16,0,0'; [void]$c.Panel.Children.Add($ui.TxtCswMode)
    [void]$c.Panel.Children.Add((New-MaskText (T 'csw.form.secrets') 'Hint' '0,2,0,6'))
    foreach ($f in $script:CswFields) {
        $label = T "csw.field.$($f.ToLower())"
        if ($f -eq 'Installer') { $ctl = New-CustCombo @() $label }
        else { $ctl = New-Object System.Windows.Controls.TextBox; $ctl.Padding = '8,6'; $ctl.MaxLength = $(if ($f -eq 'LicenseNotes') { 1000 } else { 512 }); [System.Windows.Automation.AutomationProperties]::SetName($ctl, $label) }
        $script:CswForm[$f] = $ctl
        [void]$c.Panel.Children.Add((New-MaskLabeled $label $ctl))
    }
    $ui.TxtCswErrors = New-MaskText '' '' '0,6,0,0'; Set-Brush $ui.TxtCswErrors ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'Danger'; [void]$c.Panel.Children.Add($ui.TxtCswErrors)
    $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.Margin = '0,10,0,0'
    $ui.BtnCswRecord = New-MaskButton (T 'csw.btn.record') (T 'csw.btn.record.tip') $true
    $ui.BtnCswNew = New-MaskButton (T 'csw.btn.new') (T 'csw.btn.new.tip')
    $ui.BtnCswRefresh = New-MaskButton (T 'csw.btn.refresh') (T 'csw.btn.refresh.tip')
    foreach ($b in $ui.BtnCswRecord, $ui.BtnCswNew, $ui.BtnCswRefresh) { [void]$row.Children.Add($b) }
    [void]$c.Panel.Children.Add($row)
    $ui.TxtCswState = New-MaskText '' 'Hint' '0,8,0,0'; [void]$c.Panel.Children.Add($ui.TxtCswState)
    [void]$stack.Children.Add($c.Card)
    $ui.CardCsw = $c.Card
    Add-Click $ui.BtnCswRecord { Invoke-CswRecord }
    Add-Click $ui.BtnCswNew { $script:CswMode = @{ Kind = 'Install'; Id = ''; Name = '' }; Clear-CswForm; Update-CswView }
    Add-Click $ui.BtnCswRefresh { Start-CswJob 'Status' }
    $script:CswUiBuilt = $true
    Clear-CswForm
}

function Clear-CswForm {
    if (-not $script:CswUiBuilt) { return }
    foreach ($f in $script:CswFields) { $ctl = $script:CswForm[$f]; if ($ctl -is [System.Windows.Controls.ComboBox]) { $ctl.SelectedIndex = -1 } else { $ctl.Text = '' } }
    $script:CswForm['TimeoutSeconds'].Text = '3600'
    $ui.TxtCswErrors.Text = ''
}

function Get-CswFiles { if ($script:CswLibrary -and $script:CswLibrary.State -eq 'Ready') { @($script:CswLibrary.Files | Where-Object { $_.Extension -in '.msi', '.exe' }) } else { @() } }

function Get-CswForm {
    $raw = @{}
    foreach ($f in $script:CswFields) { $ctl = $script:CswForm[$f]; $raw[$f] = if ($ctl -is [System.Windows.Controls.ComboBox]) { [string]$ctl.SelectedItem } else { [string]$ctl.Text } }
    if ($script:CswMode.Id) { $raw['Id'] = $script:CswMode.Id }
    $raw
}

function Invoke-CswRecord {
    $chk = ConvertTo-AVDTuneRecordingApp -Raw (Get-CswForm) -FromForm -Library (Get-CswFiles)
    if (-not $chk.Valid) { $ui.TxtCswErrors.Text = ($chk.Errors -join "`r`n"); return }
    $a = $chk.App
    $ui.TxtCswErrors.Text = ''
    if ($chk.Cleaned) { foreach ($f in 'LicenseNotes', 'Contact', 'Dependencies') { $script:CswForm[$f].Text = $a.$f }; $ui.TxtCswErrors.Text = T 'csw.form.cleaned' }
    $file = @(Get-CswFiles | Where-Object { $_.Name -ceq $a.Installer })[0]
    $ask = T 'csw.ask.record' $a.Name $a.Version $a.Installer $file.Size $a.Sha256 $a.TimeoutSeconds $(if ($a.Arguments) { $a.Arguments } else { '-' })
    if ($chk.Cleaned) { $ask += "`n`n" + (T 'csw.form.cleaned') }
    if (@($chk.Warnings).Count) { $ask += "`n`n" + (T 'csw.ask.warnings' (@($chk.Warnings) -join "`n")) }
    if (-not (Confirm-Action $ask (T 'csw.card.title'))) { return }
    Start-CswJob 'Record' $a $script:CswMode.Kind
}

function Set-CswUpdate([string]$Id) {
    # "Update erfassen": the form with the details of the newest recording of the app; version and installer are chosen anew
    $app = @($script:CswStatus.Apps | Where-Object { $_.Id -eq $Id })[0]
    if (-not $app) { return }
    $l = $app.Latest.App
    Clear-CswForm
    foreach ($f in 'Name', 'Vendor', 'Contact', 'Arguments', 'Dependencies', 'LicenseNotes') { $script:CswForm[$f].Text = [string]$l.$f }
    $script:CswForm['TimeoutSeconds'].Text = [string]$l.TimeoutSeconds
    $script:CswMode = @{ Kind = 'Update'; Id = $Id; Name = [string]$l.Name }
    # the arguments taken over are checked again against today's rules (review #87): what is not allowed any more is named at once (and refused when recording)
    $ar = Test-AVDTuneRecordingArguments -Installer ([string]$l.Installer) -Arguments ([string]$l.Arguments)
    $ui.TxtCswErrors.Text = (@($ar.Errors) + @($ar.Warnings)) -join "`r`n"
    Update-CswView
}

function Update-CswView {
    if (-not $script:CswUiBuilt) { return }
    $lib = $script:CswLibrary
    $ui.TxtCswLibrary.Text = if ($script:CswLibraryError) { T 'csw.lib.error' $script:CswLibraryError } elseif ($lib) { T 'csw.lib.state' @(Get-CswFiles).Count ([string]$lib.Message) } else { T 'csw.lib.none' }
    $cb = $script:CswForm['Installer']; $sel = [string]$cb.SelectedItem
    $cb.ItemsSource = @(Get-CswFiles | ForEach-Object { $_.Name }); if ($sel) { $cb.SelectedItem = $sel }
    $ui.TxtCswMode.Text = if ($script:CswMode.Kind -eq 'Update') { T 'csw.form.update' $script:CswMode.Name } else { T 'csw.form.new' }
    $ui.PanelCswApps.Children.Clear()
    $apps = if ($script:CswStatus) { @($script:CswStatus.Apps) } else { @() }
    if ($apps.Count -eq 0) { [void]$ui.PanelCswApps.Children.Add((New-MaskText (T 'csw.empty') 'Hint')) }
    foreach ($app in $apps) {
        $st = if ($app.Latest.Result -eq 'Failed') { 'Failed' } elseif ($app.Installed -eq $true) { 'Compliant' } elseif ($app.Installed -eq $false) { 'NonCompliant' } else { 'Unknown' }
        $inst = if ($app.Installed -eq $true) { T 'csw.inst.yes' $app.InstalledVersion } elseif ($app.Installed -eq $false) { T 'csw.inst.no' } else { T 'csw.inst.unknown' }
        $docs = (@($app.Versions | ForEach-Object { "$($_.Number.ToString('000')) $($_.Kind) $($_.App.Version) $($_.Result): $($_.Folder)\documentation.html" }) -join "`r`n")
        $detail = (T 'csw.row.detail' $app.Latest.App.Version $app.Latest.Started $app.Latest.User $inst) + "`r`n" + $docs
        $b = New-MaskButton (T 'csw.btn.update') (T 'csw.btn.update.tip' $app.Name); $b.Tag = $app.Id
        $b.Add_Click({ param($s) try { Set-CswUpdate ([string]$s.Tag) } catch { Show-Error $_.Exception.Message } })
        [void]$ui.PanelCswApps.Children.Add((New-CustRow $st "$($app.Name)$(if ($app.Vendor) { " ($($app.Vendor))" })" $detail @($b)))
    }
    foreach ($n in @($script:CswStatus | Where-Object { $_ } | ForEach-Object { @($_.Notes) })) { if ($n) { [void]$ui.PanelCswApps.Children.Add((New-MaskText $n 'Hint' '0,2,0,0')) } }
}

function Show-CswCard {
    # Called with the Software page: draw what is known; the first time, read it
    Build-CswCard
    Update-CswView
    if (-not $script:CswStatus -and -not $script:CswJob) { try { Start-CswJob 'Status' } catch { Show-Error $_.Exception.Message } }
}
