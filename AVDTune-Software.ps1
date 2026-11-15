# The Software page (dot-sourced by Start-AVDTune.ps1; issue 31). Logic is in Modules\AVDTune.Software.psm1; this file builds the lists, starts the long work (reading,
# search, install, update, remove) in a background runspace as a task on the task bar and polls it with the window timer. The page itself is UI\Software.xaml, loaded here
# and added next to the other pages (UI\AVDTune.xaml is not touched). Every winget/choco/msiexec call runs in the module, inside the lock Global\PackTune.
# The library tokens are asked for on the UI thread (the sign-in object belongs to it) and handed to the runspace as plain strings for this one job; they are not kept.
# Test mode: the runspace uses the fake machine, the fake update adapter and the fake package store (Tests\Fakes), never a real install and never a tenant.

$script:SwJob = $null
$script:SwInstalled = @(); $script:SwManaged = @(); $script:SwResults = @(); $script:SwLibrary = $null; $script:SwLibraryError = ''; $script:SwNotes = @()
$script:SwScanned = $false
$script:SwLastRun = $null
$script:SwFakeDir = $(if ($script:TestMode) { [string]$script:TestInfo.FakeDir } else { '' })
$script:SwFakeNative = @{
    '*winget.exe search --query *' = @{ ExitCode = 0; Output = "Name   Id         Version Source`r`n--------------------------------`r`n7-Zip  7zip.7zip  24.08   winget`r`n" }
    '*choco.exe search *' = @{ ExitCode = 0; Output = 'git|2.45.0' }
    '*winget.exe list *' = @{ ExitCode = 0; Output = "Name   Id         Version Available Source`r`n------------------------------------------`r`n7-Zip  7zip.7zip  23.01   24.08     winget`r`n" }
    '*winget.exe upgrade --source *' = @{ ExitCode = 0; Output = "Name   Id         Version Available Source`r`n------------------------------------------`r`n7-Zip  7zip.7zip  23.01   24.08     winget`r`n" }
    '*choco.exe list *' = @{ ExitCode = 0; Output = 'git|2.40.0' }
    '*choco.exe outdated *' = @{ ExitCode = 0; Output = 'git|2.40.0|2.45.0|false' }
    '*winget.exe install *' = @{ ExitCode = 0; Output = 'ok' }; '*winget.exe upgrade --id *' = @{ ExitCode = 0; Output = 'ok' }; '*winget.exe uninstall *' = @{ ExitCode = 0; Output = 'ok' }
    '*choco.exe install *' = @{ ExitCode = 0; Output = 'ok' }; '*choco.exe upgrade *' = @{ ExitCode = 0; Output = 'ok' }; '*choco.exe uninstall *' = @{ ExitCode = 0; Output = 'ok' }
    '*msiexec.exe /i *' = @{ ExitCode = 0; Output = '' }; '*msiexec.exe /x *' = @{ ExitCode = 0; Output = '' }
}
$script:SwFakeRegistry = $null   # test hook: extra registry values (Uninstall keys) for the fake machine

# ---------------------------------------------------------------- the page: loaded from its own XAML and added next to the others
$script:SwXml = [xml](Get-Content (Join-Path $PSScriptRoot 'UI\Software.xaml') -Raw -Encoding UTF8)
$script:SwRoot = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($script:SwXml))
foreach ($node in $script:SwXml.SelectNodes("//*[@*[local-name()='Name']]")) {
    $name = $node.Attributes | Where-Object LocalName -eq 'Name' | Select-Object -ExpandProperty Value
    $ui[$name] = $script:SwRoot.FindName($name)
}
$ui.PageSoftware = $script:SwRoot
$swParent = $ui.PageFSLogix.Parent
if ($swParent -isnot [System.Windows.Controls.Panel]) { throw 'The Software page cannot be added: the pages have no panel as parent.' }
[void]$swParent.Children.Add($script:SwRoot)
$ui.CmbSwSource.ItemsSource = @('winget and Chocolatey', 'winget', 'Chocolatey')
$ui.CmbSwSource.SelectedIndex = 0

function Test-SwBusy { [bool]$script:SwJob }
function Get-SwSettings { Get-AVDTuneSoftwareSettings $script:StateRoot }
function Get-SwUser { [string]$env:USERNAME }

# ---------------------------------------------------------------- the job
$script:SwWorkerText = @'
param($AppRoot, $FakeDir, $Root, $Kind, $Argument, $Gate, $Sync, $User, $Tokens, $SiteUrl, $Library, $SharedMachine, $FakeNative, $FakeRegistry)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $AppRoot 'Modules\AVDTune.psm1') -Force
Import-Module (Join-Path $AppRoot 'Modules\AVDTune.Updates.psm1') -Force
Import-Module (Join-Path $AppRoot 'Modules\AVDTune.Software.psm1') -Force
$ctx = $null
try {
    if ($FakeDir) {
        . (Join-Path $FakeDir 'FakeMachine.ps1'); . (Join-Path $FakeDir 'FakeUpdates.ps1'); . (Join-Path $FakeDir 'FakeSoftware.ps1')
        $m = $SharedMachine; if (-not $m) { $m = New-AVDTuneFakeMachine }
        $u = New-AVDTuneFakeUpdates -Seed @{ Native = $FakeNative }
        $lib = New-AVDTuneFakeLibrary
        [void](Add-AVDTuneFakeLibraryPackage $lib -App 'contoso-tool' -Version '1.0.0' -Product '{AAAAAAAA-0000-1111-2222-333333333333}' -Name 'Contoso Tool')
        [void](Add-AVDTuneFakeLibraryPackage $lib -App 'contoso-tool' -Version '1.1.0' -Product '{BBBBBBBB-0000-1111-2222-333333333333}' -Name 'Contoso Tool')
        [void](Add-AVDTuneFakeLibraryPackage $lib -App 'orphan-pkg' -Version '2.0' -NoAnchor)
        if ($SiteUrl) { $ctx = New-AVDTuneLibraryContext -SitesToken $lib.SitesToken -GraphToken $lib.GraphToken -SiteUrl $SiteUrl -Library $Library -Http $lib.Http }
    }
    else {
        $m = New-AVDTuneMachine; $u = New-AVDTuneUpdateAdapter
        if ($SiteUrl -and $Tokens -and $Tokens.Sites -and $Tokens.Graph) { $ctx = New-AVDTuneLibraryContext -SitesToken $Tokens.Sites -GraphToken $Tokens.Graph -SiteUrl $SiteUrl -Library $Library }
    }
    if ($Gate) { Open-AVDTuneWriteGate -SnapshotId $Gate.SnapshotId -ConfirmedBy $Gate.ConfirmedBy }
    $progress = { param($t) $Sync.Text = $t }
    switch ($Kind) {
        'Scan' {
            $notes = New-Object System.Collections.ArrayList
            $Sync.Text = 'Reading the installed software ...'
            $installed = @(Get-AVDTuneInstalledSoftware -Machine $m)
            $Sync.Text = 'Asking winget and Chocolatey ...'
            $managed = Get-AVDTuneManagedSoftware -U $u
            foreach ($n in @($managed.Notes)) { [void]$notes.Add($n) }
            $library = $null; $libError = ''
            if ($ctx) { $Sync.Text = 'Reading the PackTune library ...'; try { $library = Get-AVDTuneLibraryItems -Context $ctx -Machine $m } catch { $libError = $_.Exception.Message } }
            elseif ($SiteUrl) { $libError = $(if ($Tokens -and $Tokens.Reason) { [string]$Tokens.Reason } else { 'Not signed in: sign in on the Overview to read the library.' }) }
            [pscustomobject]@{ Installed = $installed; Managed = @($managed.Items); Library = $library; LibraryError = $libError; Notes = @($notes) }
        }
        'Search' { Search-AVDTuneCatalog -U $u -Query ([string]$Argument.Query) -Source ([string]$Argument.Source) }
        'Run' { Invoke-AVDTuneSoftwareRun -Machine $m -U $u -Root $Root -Items $Argument -LibraryContext $ctx -User $User -SnapshotId $Gate.SnapshotId -Progress $progress }
    }
}
finally { if ($ctx) { Close-AVDTuneLibraryContext $ctx }; $Tokens = $null }
'@

function Get-SwTokens {
    # On the UI thread: the sign-in object belongs to it. Plain strings for one job; nothing is kept here.
    $t = @{ Sites = ''; Graph = ''; Reason = '' }
    if ($script:TestMode) { return $t }
    $s = $script:StartContext.Session
    if (-not $s -or -not $s.Connected) { $t.Reason = 'Not signed in: sign in on the Overview to read the library.'; return $t }
    try { $t.Sites = [string](Get-AVDTuneAccessToken -Session $s -Audience Sites); $t.Graph = [string](Get-AVDTuneAccessToken -Session $s -Audience Graph) }
    catch { $t.Sites = ''; $t.Graph = ''; $t.Reason = $_.Exception.Message }
    $t
}
function Get-SwTaskTitle([string]$Kind, $Argument) {
    switch ($Kind) {
        'Scan' { 'Reading installed software' }
        'Search' { "Searching the catalog for $([string]$Argument.Query)" }
        'Run' { $n = @($Argument).Count; if ($n -eq 1) { "$($Argument[0].Action) $($Argument[0].Title)" } else { "Software: $n packages" } }
        default { "Software operation $Kind" }
    }
}
function Start-SwJob([string]$Kind, $Argument) {
    if ($script:SwJob) { throw 'Another software operation is still running.' }
    if ($script:UpdJob) { throw 'An update operation is running. Wait until it is done.' }
    if ($script:BenchJob) { throw 'A benchmark is running. Wait until it is done.' }
    $settings = Get-SwSettings
    $siteUrl = [string]$settings.StoreSiteUrl
    if ($script:TestMode -and -not $siteUrl) { $siteUrl = '' }
    $tokens = if ($siteUrl -and $Kind -in 'Scan', 'Run') { Get-SwTokens } else { @{ Sites = ''; Graph = ''; Reason = '' } }
    $sync = [hashtable]::Synchronized(@{ Text = '' })
    $gate = Get-AVDTuneWriteGate
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:SwWorkerText).AddArgument($script:AppRoot).AddArgument($script:SwFakeDir).AddArgument($script:StateRoot).AddArgument($Kind).AddArgument($Argument).AddArgument($gate).AddArgument($sync).AddArgument((Get-SwUser)).AddArgument($tokens).AddArgument($siteUrl).AddArgument([string]$settings.StoreLibrary).AddArgument($(if ($script:TestMode) { $script:Machine } else { $null })).AddArgument($script:SwFakeNative).AddArgument($script:SwFakeRegistry)
    # reading and searching are safe to run again from the list; everything that changes the master is started on the page, with its confirmation
    $retry = $(if ($Kind -eq 'Scan') { @{ Command = 'Start-SwJob'; Arguments = @('Scan', $null) } })
    $task = Start-AVDTuneUiTask -Kind "software-$($Kind.ToLower())" -Title (Get-SwTaskTitle $Kind $Argument) -Step 'Starting' -Retry $retry
    $script:SwJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Kind = $Kind; Sync = $sync; Task = $task }
    $tokens = $null
    Set-ShutdownBlock $true
    Set-SwBusy $true
}
function Set-SwBusy([bool]$Busy) {
    foreach ($b in $ui.BtnSwRefresh, $ui.BtnSwUpdateAll, $ui.BtnSwSearch, $ui.BtnSwSaveSite) { $b.IsEnabled = -not $Busy }
    foreach ($panel in $ui.PanelSwManaged, $ui.PanelSwResults, $ui.PanelSwLibrary) { $panel.IsEnabled = -not $Busy }
    $window.Cursor = $(if ($Busy) { [System.Windows.Input.Cursors]::AppStarting } else { $null })
}
function Complete-SwJob {
    $job = $script:SwJob
    if (-not $job) { return }
    if (-not $job.Handle.IsCompleted) {
        $text = [string]$job.Sync.Text
        if ($text) { Update-AVDTuneUiTask $job.Task -Step $text }
        if ($job.Task.Step -and $script:CurrentPage -eq 'Software') { $ui.TxtSwState.Text = [string]$job.Task.Step }
        return
    }
    $script:SwJob = $null
    Set-ShutdownBlock $false
    $result = $null; $err = ''
    try {
        $out = @($job.PS.EndInvoke($job.Handle))
        if ($job.PS.Streams.Error.Count -gt 0) { $err = $job.PS.Streams.Error[0].Exception.Message }
        $result = $out | Select-Object -Last 1
    }
    catch { $err = $_.Exception.Message }
    finally { $job.PS.Dispose() }
    Set-SwBusy $false
    $failed = [bool]$err
    $summary = ''
    try {
        switch ($job.Kind) {
            'Scan' {
                if ($err) { $summary = "Reading failed: $err" }
                else {
                    $script:SwInstalled = @($result.Installed); $script:SwManaged = @($result.Managed); $script:SwLibrary = $result.Library; $script:SwLibraryError = [string]$result.LibraryError; $script:SwNotes = @($result.Notes); $script:SwScanned = $true
                    $summary = "Read at $((Get-Date).ToString('HH:mm:ss')): $($script:SwInstalled.Count) installed, $(@($script:SwManaged | Where-Object { $_.Available }).Count) with a newer version."
                }
                $ui.TxtSwState.Text = $summary
            }
            'Search' {
                if ($err) { $summary = "The search failed: $err" } else { $script:SwResults = @($result.Items); $script:SwNotes = @($result.Notes); $summary = "$($script:SwResults.Count) result(s)." }
                $ui.TxtSwState.Text = $summary
            }
            'Run' {
                if ($err) { Show-Error $err }
                if ($result) {
                    $script:SwLastRun = $result
                    foreach ($r in $result.Results) { Register-StepResult $r }
                    $ok = @($result.Results | Where-Object { $_.Status -eq 'Changed' }).Count; $bad = @($result.Results | Where-Object { $_.Status -eq 'Failed' }).Count
                    if ($bad -gt 0) { $failed = $true }
                    $firstBad = @($result.Results | Where-Object { $_.Status -eq 'Failed' } | Select-Object -First 1)
                    $summary = "Run finished: $ok changed, $bad failed.$(if ($result.Reboot) { ' A restart is needed.' })$(if ($firstBad.Count) { ' ' + $firstBad[0].Title + ': ' + $firstBad[0].Message })$(if ($err) { " $err" })"
                }
                else { $summary = "The run stopped: $err" }
                $ui.TxtSwState.Text = $summary
                Show-Toast $summary
                Start-OverviewRefresh
            }
        }
        Update-SoftwareView
    }
    catch { Complete-AVDTuneUiTask $job.Task -Failed -Summary $_.Exception.Message; throw }
    Complete-AVDTuneUiTask $job.Task -Failed:$failed -Summary $summary
    # a run changed the master: read again
    if ($job.Kind -eq 'Run' -and -not $script:SwJob -and -not $script:CloseWhenDone) { Start-SwJob 'Scan' $null }
    if ($script:CloseWhenDone -and -not $script:SwJob -and -not $script:UpdJob -and -not $script:BenchJob) { if ($failed) { $script:CloseWhenDone = $false; Show-Error "Not closed because the operation failed: $summary" } else { $window.Close() } }
}
$script:Timer.Add_Tick({ try { Complete-SwJob } catch { Show-Error $_.Exception.Message } })

# Closing and signing out during a run would end an installer in the middle (the lock and the state would be left behind): the window waits, like for an update run
$window.Add_Closing({
        param($src, $e)
        if (-not $script:SwJob) { return }
        $e.Cancel = $true; $script:CloseWhenDone = $true
        Show-Toast 'A software operation is still running. AVDTune closes by itself when it is done.'
    })
$script:SwSessionEnding = [System.Windows.SessionEndingCancelEventHandler]{ param($src, $e) if ($script:SwJob) { $e.Cancel = $true; Show-Toast 'Log off or shut down was held back: a software operation is still running. Try again when it is done.' } }
[System.Windows.Application]::Current.add_SessionEnding($script:SwSessionEnding)

# ---------------------------------------------------------------- rows
$script:SwPill = @{ winget = @('AccentSubtle', 'Primary', 'winget'); chocolatey = @('AccentSubtle', 'Primary', 'Chocolatey'); library = @('AccentSubtle', 'Primary', 'Library'); ok = @('SuccessBg', 'Success'); warn = @('WarningBg', 'Warning'); muted = @('Hover', 'MutedText') }
function New-SwPill([string]$Text, [string[]]$Pair) {
    $pill = New-Object System.Windows.Controls.Border
    Set-Brush $pill ([System.Windows.Controls.Border]::StyleProperty) 'Pill'; $pill.Padding = '10,2'; $pill.VerticalAlignment = 'Center'; $pill.HorizontalAlignment = 'Left'
    Set-Brush $pill ([System.Windows.Controls.Border]::BackgroundProperty) $Pair[0]
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $Text; $t.FontSize = 12; $t.FontWeight = 'SemiBold'; Set-Brush $t ([System.Windows.Controls.TextBlock]::ForegroundProperty) $Pair[1]
    $pill.Child = $t; $pill
}
function New-SwButton([string]$Text, $Wish, [string]$Confirm, [string]$Automation) {
    $b = New-Object System.Windows.Controls.Button
    Set-Brush $b ([System.Windows.Controls.Control]::StyleProperty) 'SmallButton'
    $b.Content = $Text; $b.Margin = '4,0,0,0'; $b.VerticalAlignment = 'Center'; $b.DataContext = @{ Wish = $Wish; Confirm = $Confirm }
    [System.Windows.Automation.AutomationProperties]::SetName($b, $Automation)
    $b.Add_Click({ param($s) try { Start-SwRun @($s.DataContext.Wish) ([string]$s.DataContext.Confirm) } catch { Show-Error $_.Exception.Message } })
    $b
}
function New-SwRow([string[]]$Widths, [object[]]$Cells) {
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '0,4,0,4'
    foreach ($w in $Widths) { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$grid.ColumnDefinitions.Add($c) }
    for ($i = 0; $i -lt $Cells.Count; $i++) { $cell = $Cells[$i]; if ($null -eq $cell) { continue }; [System.Windows.Controls.Grid]::SetColumn($cell, $i); [void]$grid.Children.Add($cell) }
    $grid
}
function New-SwText([string]$Text, [bool]$Muted = $false, [bool]$Bold = $false) {
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $Text; $t.TextWrapping = 'Wrap'; $t.VerticalAlignment = 'Center'; $t.Margin = '0,0,10,0'
    if ($Bold) { $t.FontWeight = 'SemiBold' }
    if ($Muted) { Set-Brush $t ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText' }
    $t
}
function New-SwButtons($Buttons) { $p = New-Object System.Windows.Controls.StackPanel; $p.Orientation = 'Horizontal'; $p.HorizontalAlignment = 'Right'; foreach ($b in @($Buttons)) { [void]$p.Children.Add($b) }; $p }

function Update-SoftwareView {
    $busy = Test-SwBusy
    $s = Get-SwSettings
    if (-not $ui.TxtSwSite.IsKeyboardFocused) { $ui.TxtSwSite.Text = [string]$s.StoreSiteUrl }
    if (-not $ui.TxtSwLibrary.IsKeyboardFocused) { $ui.TxtSwLibrary.Text = [string]$s.StoreLibrary }
    $ui.TxtSwNotes.Text = (@($script:SwNotes) -join "`r`n")
    if (-not $script:SwScanned -and -not $busy) { $ui.TxtSwState.Text = 'Nothing read yet. Press Refresh.' }

    # managed packages
    $ui.PanelSwManaged.Children.Clear()
    if ($script:SwManaged.Count -eq 0) { [void]$ui.PanelSwManaged.Children.Add((New-Text $(if ($script:SwScanned) { 'winget and Chocolatey manage no package here.' } else { 'Not read yet.' }) 'Hint')) }
    foreach ($p in @($script:SwManaged | Sort-Object Source, Name)) {
        $buttons = @()
        if ($p.Available) { $buttons += New-SwButton 'Update' (New-AVDTuneSoftwareItem -Action Update -Source $p.Source -Id $p.Id -Title $p.Name -Installed $p.Version) "Update $($p.Name) from $($p.Version) to $($p.Available)?" "Update $($p.Name)" }
        $buttons += New-SwButton 'Remove' (New-AVDTuneSoftwareItem -Action Remove -Source $p.Source -Id $p.Id -Title $p.Name -Installed $p.Version) "Remove $($p.Name) ($($p.Version)) from this master?" "Remove $($p.Name)"
        $ver = if ($p.Available) { "$($p.Version) -> $($p.Available)" } else { [string]$p.Version }
        [void]$ui.PanelSwManaged.Children.Add((New-SwRow @('110', '300', '200', '*') @((New-SwPill $script:SwPill[$p.Source][2] $script:SwPill[$p.Source]), (New-SwText $p.Name $false $true), (New-SwText $ver $true), (New-SwButtons $buttons))))
    }
    $ui.BtnSwUpdateAll.IsEnabled = (-not $busy) -and @($script:SwManaged | Where-Object { $_.Available }).Count -gt 0

    # search results
    $ui.PanelSwResults.Children.Clear()
    foreach ($p in @($script:SwResults)) {
        $b = New-SwButton 'Install' (New-AVDTuneSoftwareItem -Action Install -Source $p.Source -Id $p.Id -Title $p.Name) "Install $($p.Name) ($($p.Id)) from $($p.Source) on this master?" "Install $($p.Name)"
        [void]$ui.PanelSwResults.Children.Add((New-SwRow @('110', '300', '200', '*') @((New-SwPill $script:SwPill[$p.Source][2] $script:SwPill[$p.Source]), (New-SwText $p.Name $false $true), (New-SwText "$($p.Id)  $($p.Version)" $true), (New-SwButtons @($b)))))
    }

    # library
    $ui.PanelSwLibrary.Children.Clear()
    $lib = $script:SwLibrary
    if (-not $s.StoreSiteUrl) { $ui.TxtSwLibState.Text = 'No site entered. Enter the SharePoint site of the package store (https://<tenant>.sharepoint.com/sites/<name>) and press Save and read.' }
    elseif ($script:SwLibraryError) { $ui.TxtSwLibState.Text = "The library was not read: $($script:SwLibraryError)" }
    elseif (-not $lib) { $ui.TxtSwLibState.Text = $(if ($script:SwScanned) { 'The library was not read.' } else { 'Not read yet.' }) }
    elseif ($lib.State -ne 'Ready') { $ui.TxtSwLibState.Text = [string]$lib.Message }
    else { $ui.TxtSwLibState.Text = "$($lib.Message) $(@($lib.Items).Count) version(s)." + $(if (@($lib.Notes).Count) { ' ' + (@($lib.Notes) -join ' ') } else { '' }) }
    if ($lib -and $lib.State -eq 'Ready') {
        $items = @($lib.Items)
        foreach ($i in @($items | Sort-Object AppId, @{ Expression = { $_.Version }; Descending = $true })) {
            $buttons = @()
            if ($i.Installable) {
                $installedOfApp = @($items | Where-Object { $_.AppId -eq $i.AppId -and $_.Installed } | Select-Object -First 1)
                if ($i.Installed) { $buttons += New-SwButton 'Remove' (New-AVDTuneSoftwareItem -Action Remove -Source library -Id $i.AppId -Version $i.Version -Title $i.Name -Installed $i.Installed) "Remove $($i.Name) $($i.Version) from this master?" "Remove $($i.Name) $($i.Version)" }
                elseif ($installedOfApp.Count -gt 0 -and (Compare-AVDTuneVersion $i.Version $installedOfApp[0].Version) -gt 0) { $buttons += New-SwButton 'Update' (New-AVDTuneSoftwareItem -Action Update -Source library -Id $i.AppId -Version $i.Version -Title $i.Name -Installed $installedOfApp[0].Version) "Update $($i.Name) from $($installedOfApp[0].Version) to $($i.Version)?" "Update $($i.Name) to $($i.Version)" }
                elseif ($installedOfApp.Count -eq 0) { $buttons += New-SwButton 'Install' (New-AVDTuneSoftwareItem -Action Install -Source library -Id $i.AppId -Version $i.Version -Title $i.Name) "Install $($i.Name) $($i.Version) from the library? It is checked against Intune first." "Install $($i.Name) $($i.Version)" }
            }
            $status = if ($i.Installed) { New-SwPill 'Installed' $script:SwPill.ok } elseif ($i.Installable) { New-SwPill 'Available' $script:SwPill.library } else { New-SwPill 'Not installable' $script:SwPill.warn }
            $detail = if ($i.Installable) { "$($i.AppId)  $($i.Version)" } else { "$($i.AppId)  $($i.Version): $($i.Why)" }
            [void]$ui.PanelSwLibrary.Children.Add((New-SwRow @('130', '300', '300', '*') @($status, (New-SwText $i.Name $false $true), (New-SwText $detail $true), (New-SwButtons $buttons))))
        }
    }

    # installed
    $ui.PanelSwInstalled.Children.Clear()
    $ui.TxtSwInstalledTitle.Text = "Installed on this master ($($script:SwInstalled.Count))"
    foreach ($i in $script:SwInstalled) { [void]$ui.PanelSwInstalled.Children.Add((New-SwRow @('420', '160', '*') @((New-SwText $i.Name), (New-SwText $i.Version $true), (New-SwText ("$($i.Publisher)" + $(if ($i.Arch -eq 'x86') { ' (32 bit)' } else { '' })) $true)))) }
    if ($script:SwInstalled.Count -eq 0) { [void]$ui.PanelSwInstalled.Children.Add((New-Text $(if ($script:SwScanned) { 'Nothing found.' } else { 'Not read yet.' }) 'Hint')) }

    # history
    $ui.PanelSwHistory.Children.Clear()
    $hist = @(Get-AVDTuneSoftwareHistory -Root $script:StateRoot -Last 12)
    if ($hist.Count -eq 0) { [void]$ui.PanelSwHistory.Children.Add((New-Text 'No software run yet.' 'Hint')) }
    foreach ($h in $hist) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = "{0}   {1,-9}  {2,-7}  {3}{4}" -f ([datetime]$h.At).ToString('yyyy-MM-dd HH:mm'), $h.Status, $h.Action, $h.Title, $(if ($h.Status -eq 'Failed') { " ($($h.Code)): $($h.Message)" } else { '' })
        $t.TextWrapping = 'Wrap'; $t.FontFamily = 'Cascadia Mono, Consolas'; $t.FontSize = 12; $t.Margin = '0,2,0,2'
        Set-Brush $t ([System.Windows.Controls.TextBlock]::ForegroundProperty) $(if ($h.Status -eq 'Failed') { 'Danger' } else { 'Text' })
        [void]$ui.PanelSwHistory.Children.Add($t)
    }
}

# ---------------------------------------------------------------- actions
function Start-SwRun([object[]]$Items, [string]$Question) {
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot of today on the Overview first.' }
    $list = @($Items | Where-Object { $_ })
    if ($list.Count -eq 0) { throw 'Nothing to do.' }
    if (-not $Question) { $Question = "Run $($list.Count) software change(s) on this master?" }
    if (-not (Confirm-Action $Question 'Software')) { return }
    $ui.TxtSwState.Text = 'Starting ...'
    Start-SwJob 'Run' $list
}
Add-Click $ui.BtnSwRefresh { Start-SwJob 'Scan' $null; $ui.TxtSwState.Text = 'Reading ...' }
Add-Click $ui.BtnSwUpdateAll {
    $items = @($script:SwManaged | Where-Object { $_.Available } | ForEach-Object { New-AVDTuneSoftwareItem -Action Update -Source $_.Source -Id $_.Id -Title $_.Name -Installed $_.Version })
    Start-SwRun $items "Update $($items.Count) package(s) from winget and Chocolatey?"
}
Add-Click $ui.BtnSwSearch {
    $q = $ui.TxtSwQuery.Text.Trim()
    if (-not (Test-AVDTuneSearchText $q)) { throw 'The search text may contain letters, digits, space and . _ + - (up to 64 characters, starting with a letter or digit).' }
    $source = switch ($ui.CmbSwSource.SelectedIndex) { 1 { 'winget' } 2 { 'chocolatey' } default { 'Both' } }
    Start-SwJob 'Search' @{ Query = $q; Source = $source }
    $ui.TxtSwState.Text = 'Searching ...'
}
Add-Click $ui.BtnSwSaveSite {
    $s = Set-AVDTuneSoftwareSettings -Root $script:StateRoot -StoreSiteUrl $ui.TxtSwSite.Text -StoreLibrary $ui.TxtSwLibrary.Text
    Show-Toast $(if ($s.StoreSiteUrl) { 'Site saved.' } else { 'Site cleared: the library is not used.' })
    $script:SwLibrary = $null; $script:SwLibraryError = ''
    Start-SwJob 'Scan' $null
}
$ui.TxtSwQuery.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return' -and $ui.BtnSwSearch.IsEnabled) { try { & $script:ClickActions[$ui.BtnSwSearch] } catch { Show-Error $_.Exception.Message } } })

function Show-SoftwarePage {
    # Called by Show-Page: draw what is known; the first time, read it
    Update-SoftwareView
    if (-not $script:SwScanned -and -not $script:SwJob -and -not $script:UpdJob -and -not $script:BenchJob) { try { Start-SwJob 'Scan' $null } catch { Show-Error $_.Exception.Message } }
}
