# The App Masking page (dot-sourced by Start-AVDTune.ps1; plan 5b and 5c, issue 29). Logic is in Modules\AVDTune.Masking.psm1; this file builds the page in code (so
# Start-AVDTune.ps1 and UI\AVDTune.xaml need only one hook each) and runs the quick changes on the window thread as tasks of the task bar. Every change of the master goes
# through the write gate (snapshot confirmed) and has a change log entry and an undo; a group in AD is only created after a confirmation that names group, OU and domain.
# The domain account's password is typed here, used for this one connection and cleared; it is never saved, logged or put into a task text.
# Test mode: the fake masking adapter and the fake LDAP run inline; no FSLogix, no domain controller, no Public Desktop of this computer.

$script:MaskFake = $null
if ($script:TestMode) {
    . (Get-TestScript 'FakeMasking.ps1')
    $script:MaskFake = @{ M = (New-AVDTuneFakeMasking -Seed @{ Desktop = @(
                    @{ Name = 'Contoso App.lnk'; Target = 'C:\Apps\app.exe'; IsShortcut = $true }, @{ Name = 'Notes.lnk'; Target = 'C:\Apps\notes.exe'; IsShortcut = $true }) }); Ldap = (New-AVDTuneFakeMaskingLdap) }
}
$script:MaskOv = $null
$script:MaskChecks = @{}
$script:MaskUiBuilt = $false

function Get-MaskAdapter { if ($script:TestMode) { $script:MaskFake.M } else { if (-not $script:RealMask) { $script:RealMask = New-AVDTuneMaskingAdapter }; $script:RealMask } }
function Get-MaskAnswers { $e = $null; try { $e = Get-AVDTuneEnvironment $script:StateRoot } catch { }; if ($e) { Get-AVDTuneEnvironmentAnswers $e } else { $null } }
function Get-MaskDirectory { $d = $null; try { $d = Read-AVDTuneJson (Join-Path $script:StateRoot 'config\directory.json') } catch { }; if ($d -and (Get-AVDTuneProp $d 'Directory')) { $d.Directory } else { $null } }
function Get-MaskGroupSam($G) { $s = [string](Get-AVDTuneProp $G 'Sam'); if ($s) { $s } else { [string]$G.Name } }
function Get-MaskGateSnapshot { $g = Get-AVDTuneWriteGate; if ($g) { [string]$g.SnapshotId } else { '' } }
function Assert-MaskWrite { if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot of today on the Overview first.' }; Assert-NoOtherWriter }

function New-MaskText([string]$Text, [string]$Style = '', [string]$Margin = '0') {
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $Text; $t.TextWrapping = 'Wrap'; $t.Margin = $Margin
    if ($Style) { $t.SetResourceReference([System.Windows.Controls.TextBlock]::StyleProperty, $Style) }
    $t
}
function New-MaskButton([string]$Text, [string]$Automation, [bool]$Primary = $false) {
    $b = New-Object System.Windows.Controls.Button; $b.Content = $Text; $b.Margin = '0,0,8,0'; $b.Padding = '12,6'
    if ($Primary) { $b.SetResourceReference([System.Windows.Controls.Control]::StyleProperty, 'PrimaryButton') }
    [System.Windows.Automation.AutomationProperties]::SetName($b, $Automation)
    $b
}
function New-MaskCard([string]$Title, [string]$Hint) {
    $card = New-Object System.Windows.Controls.Border; $card.Margin = '0,16,0,0'; $card.Padding = '20,16'
    $card.SetResourceReference([System.Windows.Controls.Border]::StyleProperty, 'CardBox'); $card.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'Card')
    $panel = New-Object System.Windows.Controls.StackPanel
    [void]$panel.Children.Add((New-MaskText $Title 'CardTitle'))
    if ($Hint) { [void]$panel.Children.Add((New-MaskText $Hint 'Hint' '0,4,0,0')) }
    $card.Child = $panel
    [pscustomobject]@{ Card = $card; Panel = $panel }
}
function New-MaskLabeled([string]$Label, $Control) {
    $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,4,0,4'
    foreach ($w in 230, '*') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
    $l = New-MaskText $Label '' '0,0,8,0'; $l.VerticalAlignment = 'Center'
    $Control.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
    [void]$g.Children.Add($l); [void]$g.Children.Add($Control)
    $g
}

function Build-MaskPage {
    if ($script:MaskUiBuilt) { return }
    $parent = $ui.PagePlaceholder.Parent
    $page = New-Object System.Windows.Controls.Grid; $page.Visibility = 'Collapsed'
    $sv = New-Object System.Windows.Controls.ScrollViewer; $sv.SetResourceReference([System.Windows.Controls.ScrollViewer]::StyleProperty, 'PageScroll')
    $root = New-Object System.Windows.Controls.StackPanel; $root.Margin = '40,32,40,28'; $root.MaxWidth = 1000; $root.HorizontalAlignment = 'Left'
    [void]$root.Children.Add((New-MaskText 'App Masking' 'PageTitle'))
    $ui.TxtMaskSubtitle = New-MaskText 'FSLogix hiding rules for icons on the Public Desktop, with groups from Active Directory or a local group. Everything that changes the master is behind the snapshot gate and has an undo.' 'Subtitle'
    [void]$root.Children.Add($ui.TxtMaskSubtitle)

    # ---- Public Desktop
    $c1 = New-MaskCard 'Public Desktop' 'Every file on C:\Users\Public\Desktop and whether a hiding rule covers it. Tick entries and use the wizard below; entries nobody hides are seen by every user.'
    $ui.TxtMaskCounter = New-MaskText '' '' '0,8,0,0'; $ui.TxtMaskCounter.FontWeight = 'SemiBold'; [void]$c1.Panel.Children.Add($ui.TxtMaskCounter)
    $ui.PanelMaskDesk = New-Object System.Windows.Controls.StackPanel; $ui.PanelMaskDesk.Margin = '0,8,0,0'; [void]$c1.Panel.Children.Add($ui.PanelMaskDesk)
    $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.Margin = '0,10,0,0'
    $ui.BtnMaskRefresh = New-MaskButton 'Refresh' 'Read the rule sets and the Public Desktop again'
    $ui.BtnMaskUncovered = New-MaskButton 'Tick the uncovered entries' 'Tick every entry that no rule hides'
    $ui.BtnMaskLogoff = New-MaskButton 'Add the Abmelden shortcut' 'Put a sign out shortcut on the Public Desktop for all users'
    foreach ($b in $ui.BtnMaskRefresh, $ui.BtnMaskUncovered, $ui.BtnMaskLogoff) { [void]$row.Children.Add($b) }
    [void]$c1.Panel.Children.Add($row)
    $ui.TxtMaskLogoffNote = New-MaskText '' 'Hint' '0,6,0,0'; [void]$c1.Panel.Children.Add($ui.TxtMaskLogoffNote)
    [void]$root.Children.Add($c1.Card)

    # ---- wizard
    $c2 = New-MaskCard 'Set up visibility (wizard)' 'The ticked entries get a hiding rule in the rule set below. Rule sets are written exactly like the FSLogix Rule Editor writes them; a rule set that exists keeps its other rules.'
    $ui.TxtMaskName = New-Object System.Windows.Controls.TextBox; $ui.TxtMaskName.Text = 'Public Desktop'; $ui.TxtMaskName.Padding = '8,6'; [System.Windows.Automation.AutomationProperties]::SetName($ui.TxtMaskName, 'Name of the rule set')
    [void]$c2.Panel.Children.Add((New-MaskLabeled 'Rule set name' $ui.TxtMaskName))
    $ui.CmbMaskVis = New-Object System.Windows.Controls.ComboBox; $ui.CmbMaskVis.Padding = '8,6'; [System.Windows.Automation.AutomationProperties]::SetName($ui.CmbMaskVis, 'Who still sees the ticked entries')
    [void]$c2.Panel.Children.Add((New-MaskLabeled 'Visible for' $ui.CmbMaskVis))
    $ui.CmbMaskKind = New-Object System.Windows.Controls.ComboBox; $ui.CmbMaskKind.Padding = '8,6'; [System.Windows.Automation.AutomationProperties]::SetName($ui.CmbMaskKind, 'Kind of group')
    [void]$c2.Panel.Children.Add((New-MaskLabeled 'Group' $ui.CmbMaskKind))
    $ui.CmbMaskExisting = New-Object System.Windows.Controls.ComboBox; $ui.CmbMaskExisting.Padding = '8,6'; [System.Windows.Automation.AutomationProperties]::SetName($ui.CmbMaskExisting, 'Existing AD group')
    [void]$c2.Panel.Children.Add((New-MaskLabeled 'Existing AD group' $ui.CmbMaskExisting))
    $ui.CmbMaskOu = New-Object System.Windows.Controls.ComboBox; $ui.CmbMaskOu.Padding = '8,6'; [System.Windows.Automation.AutomationProperties]::SetName($ui.CmbMaskOu, 'OU for the new AD group')
    [void]$c2.Panel.Children.Add((New-MaskLabeled 'OU for a new AD group' $ui.CmbMaskOu))
    $ui.TxtMaskGroup = New-Object System.Windows.Controls.TextBox; $ui.TxtMaskGroup.Padding = '8,6'; [System.Windows.Automation.AutomationProperties]::SetName($ui.TxtMaskGroup, 'Name of the new group')
    [void]$c2.Panel.Children.Add((New-MaskLabeled 'Name of the new group' $ui.TxtMaskGroup))
    $ui.TxtMaskDc = New-Object System.Windows.Controls.TextBox; $ui.TxtMaskDc.Padding = '8,6'; [System.Windows.Automation.AutomationProperties]::SetName($ui.TxtMaskDc, 'Domain controller')
    [void]$c2.Panel.Children.Add((New-MaskLabeled 'Domain controller (new AD group)' $ui.TxtMaskDc))
    $ui.TxtMaskUser = New-Object System.Windows.Controls.TextBox; $ui.TxtMaskUser.Padding = '8,6'; [System.Windows.Automation.AutomationProperties]::SetName($ui.TxtMaskUser, 'Domain account')
    [void]$c2.Panel.Children.Add((New-MaskLabeled 'Domain account' $ui.TxtMaskUser))
    $ui.PwdMask = New-Object System.Windows.Controls.PasswordBox; $ui.PwdMask.Padding = '8,6'; [System.Windows.Automation.AutomationProperties]::SetName($ui.PwdMask, 'Password of the domain account')
    [void]$c2.Panel.Children.Add((New-MaskLabeled 'Password (used once, not saved)' $ui.PwdMask))
    $ui.TxtMaskCaps = New-MaskText '' 'Hint' '0,6,0,0'; [void]$c2.Panel.Children.Add($ui.TxtMaskCaps)
    $row2 = New-Object System.Windows.Controls.StackPanel; $row2.Orientation = 'Horizontal'; $row2.Margin = '0,10,0,0'
    $ui.BtnMaskPreview = New-MaskButton 'Preview' 'Show what would be written, nothing is changed'
    $ui.BtnMaskApply = New-MaskButton 'Apply' 'Write the rule set and create the group if chosen' $true
    $ui.BtnMaskUndo = New-MaskButton 'Undo the last change' 'Put back the files, shortcut or group of the last change'
    foreach ($b in $ui.BtnMaskPreview, $ui.BtnMaskApply, $ui.BtnMaskUndo) { [void]$row2.Children.Add($b) }
    [void]$c2.Panel.Children.Add($row2)
    $ui.TxtMaskState = New-MaskText '' '' '0,8,0,0'; [void]$c2.Panel.Children.Add($ui.TxtMaskState)
    [void]$root.Children.Add($c2.Card)

    # ---- rule sets
    $c3 = New-MaskCard 'Rule sets' 'Everything in C:\Program Files\FSLogix\Apps\Rules (.fxr and .fxa), including sets made with the Rule Editor. Parts AVDTune does not know are kept as they are.'
    $ui.TxtMaskFslVersion = New-MaskText '' 'Hint' '0,4,0,0'; [void]$c3.Panel.Children.Add($ui.TxtMaskFslVersion)
    $ui.PanelMaskSets = New-Object System.Windows.Controls.StackPanel; $ui.PanelMaskSets.Margin = '0,8,0,0'; [void]$c3.Panel.Children.Add($ui.PanelMaskSets)
    [void]$root.Children.Add($c3.Card)

    $sv.Content = $root; $page.Children.Add($sv) | Out-Null
    $ui.PageAppMasking = $page; [void]$parent.Children.Add($page)
    $script:MaskUiBuilt = $true
}

function Get-MaskKindChoices($Caps) {
    $k = @()
    if ($Caps.AdGroups) { $k += 'Existing AD group'; $k += 'New AD group (created in AD after your confirmation)' }
    $k += 'New local group of this master (not verified on a VM)'
    $k
}

function Update-MaskView {
    Build-MaskPage
    $applies = Test-AVDTuneWriteAllowed
    $caps = Get-AVDTuneMaskingCapabilities (Get-MaskAnswers)
    $dir = Get-MaskDirectory
    $settings = Get-AVDTuneMaskingSettings -Root $script:StateRoot
    $ui.TxtMaskCaps.Text = $caps.Note
    $ui.CmbMaskVis.ItemsSource = @('Nobody except Administrators (hidden for everyone)') + $(if ($caps.AdGroups -or $caps.LocalGroups) { @('Administrators and one group') })
    if ($ui.CmbMaskVis.SelectedIndex -lt 0) { $ui.CmbMaskVis.SelectedIndex = 0 }
    $ui.CmbMaskKind.ItemsSource = @(Get-MaskKindChoices $caps); if ($ui.CmbMaskKind.SelectedIndex -lt 0) { $ui.CmbMaskKind.SelectedIndex = 0 }
    $ui.CmbMaskExisting.ItemsSource = @(if ($dir) { @($dir.Groups | Where-Object { $_.Security } | ForEach-Object { Get-MaskGroupSam $_ }) } else { @() })
    $ous = New-Object System.Collections.ArrayList
    $walk = $null; $walk = { param($nodes, $depth) foreach ($n in @($nodes)) { if ($n) { [void]$ous.Add(([string]$n.Dn)); & $walk @($n.Children) ($depth + 1) } } }
    if ($dir) { & $walk @($dir.OuTree) 0 }
    $ui.CmbMaskOu.ItemsSource = @($ous); if ($ui.CmbMaskOu.SelectedIndex -lt 0 -and $ous.Count -gt 0) { $ui.CmbMaskOu.SelectedIndex = 0 }
    if (-not $ui.TxtMaskDc.Text -and $caps.AdGroups) { $a = Get-MaskAnswers; $ui.TxtMaskDc.Text = [string](Get-AVDTuneProp $a 'DomainController') }
    if (-not $ui.TxtMaskGroup.Text) { try { $ui.TxtMaskGroup.Text = Get-AVDTuneAppGroupName -Prefix $settings.Prefix -Name $ui.TxtMaskName.Text } catch { } }
    $err = $null
    try { $script:MaskOv = Get-AVDTuneMaskingOverview -M (Get-MaskAdapter) } catch { $err = $_.Exception.Message; $script:MaskOv = $null }
    $ui.PanelMaskDesk.Children.Clear(); $ui.PanelMaskSets.Children.Clear(); $script:MaskChecks = @{}
    $short = Get-AVDTuneComfortShortcuts -M (Get-MaskAdapter)
    $ui.TxtMaskLogoffNote.Text = [string]$short[0].Note
    $ui.TxtMaskFslVersion.Text = $(try { $i = Get-AVDTuneFSLogixInfo -Machine $script:Machine; if ($i.Installed) { "FSLogix $($i.Version) is installed." } else { 'FSLogix is not installed: the rules folder does not exist yet.' } } catch { '' })
    if ($err) { $ui.TxtMaskCounter.Text = $err; return }
    $ov = $script:MaskOv
    $ui.TxtMaskCounter.Text = $(if ($ov.Uncovered -gt 0) { "$($ov.Uncovered) of $(@($ov.PublicDesktop).Count) entries are not hidden by any rule: every user sees them." } else { "All $(@($ov.PublicDesktop).Count) entries are covered." })
    foreach ($d in @($ov.PublicDesktop)) {
        $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,3,0,3'
        foreach ($w in 28, 250, 200, '*') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
        $cb = New-Object System.Windows.Controls.CheckBox; $cb.VerticalAlignment = 'Center'; [System.Windows.Automation.AutomationProperties]::SetName($cb, "Select $($d.Name)")
        $cb.IsChecked = ($d.State -eq 'Uncovered' -and $d.IsShortcut -and $d.Name -notlike 'Abmelden*')
        $script:MaskChecks[[string]$d.Name] = $cb
        $n = New-MaskText $d.Name '' '0'; $n.FontWeight = 'SemiBold'; $n.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1); $n.ToolTip = "$($d.Target) $($d.Arguments)"
        $s = New-MaskText $(if ($d.State -eq 'Hidden') { 'Hidden' } elseif ($d.State -eq 'NotHiding') { 'Rule without effect' } else { 'Not covered' }) '' '0'
        $s.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2); $s.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $(if ($d.State -eq 'Hidden') { 'Success' } else { 'Warning' }))
        $t = New-MaskText ("$($d.Text)" + $(if ($d.RuleSet) { " ($($d.RuleSet))" } else { '' })) 'Hint' '0'; $t.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 3)
        foreach ($e in $cb, $n, $s, $t) { [void]$g.Children.Add($e) }
        [void]$ui.PanelMaskDesk.Children.Add($g)
    }
    if (@($ov.PublicDesktop).Count -eq 0) { [void]$ui.PanelMaskDesk.Children.Add((New-MaskText 'The Public Desktop has no entries.' 'Hint')) }
    foreach ($rs in @($ov.RuleSets)) {
        $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,4,0,4'
        foreach ($w in 220, '*', 'Auto') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
        $n = New-MaskText $rs.Name '' '0'; $n.FontWeight = 'SemiBold'
        $txt = "$(@($rs.Rules).Count) hiding rule(s)" + $(if ($rs.OtherRules -gt 0) { ", $($rs.OtherRules) other (kept)" } else { '' }) + $(if ($rs.Visibility) { '; ' + $rs.Visibility.Text } else { '' }) + $(if (@($rs.Problems).Count -gt 0) { '. Problems: ' + (@($rs.Problems) -join ' ') } else { '' })
        $d = New-MaskText $txt 'Hint' '0'; $d.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
        $rm = New-MaskButton 'Remove' "Remove the rule set $($rs.Name)"; $rm.Margin = '8,0,0,0'; $rm.Tag = [string]$rs.Name; $rm.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2)
        $rm.Add_Click({ param($src) try { Remove-MaskSet ([string]$src.Tag) } catch { Show-Error $_.Exception.Message } })
        foreach ($e in $n, $d, $rm) { [void]$g.Children.Add($e) }
        [void]$ui.PanelMaskSets.Children.Add($g)
    }
    if (@($ov.RuleSets).Count -eq 0) { [void]$ui.PanelMaskSets.Children.Add((New-MaskText 'No rule sets yet.' 'Hint')) }
    foreach ($b in $ui.BtnMaskApply, $ui.BtnMaskUndo, $ui.BtnMaskLogoff) { $b.IsEnabled = [bool]$applies }
}

function Get-MaskLdap {
    # A connection for one change: the domain account of the form, pinned LDAPS only (nothing is sent without a pin; the start sequence pins it). Returns Ldap, Conn, Dispose.
    $server = $ui.TxtMaskDc.Text.Trim(); $user = $ui.TxtMaskUser.Text.Trim()
    if ($script:TestMode) { return [pscustomobject]@{ Ldap = $script:MaskFake.Ldap; Conn = 'c'; Close = { } } }
    $secure = $ui.PwdMask.SecurePassword   # a copy: disposed as soon as the connection is made or has failed
    try {
        if ($secure.Length -eq 0) { throw 'Enter the domain account and its password for the connection to the domain controller.' }
        $ldap = New-AVDTuneLdapAdapter
        $e = Get-AVDTuneEnvironment $script:StateRoot
        $r = Connect-AVDTuneDirectory -Ldap $ldap -Server $server -User $user -Password $secure -Pins (Get-AVDTuneDcPins $e)
    }
    finally { $secure.Dispose() }
    if ($r.Status -ne 'Connected') { throw "No connection to the domain controller ($($r.Status)): $($r.Message) Pin the certificate and connect in the start sequence first." }
    $conn = $r.Connection
    [pscustomobject]@{ Ldap = $ldap; Conn = $conn; Close = { Disconnect-AVDTuneDirectory -Ldap $ldap -Connection $conn }.GetNewClosure() }
}

function Invoke-MaskChange {
    # A change of the master on the window thread, shown as a task; ends failed when the call throws or a step failed. No Retry: every one of these changes the master or AD.
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Step, [Parameter(Mandatory)][scriptblock]$Block)
    $task = Start-AVDTuneUiTask -Kind 'appmasking' -Title $Title -Step $Step
    try { Update-TaskBar; $window.Dispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Render) } catch { }
    $out = $null
    try { $out = & $Block }
    catch { Complete-AVDTuneUiTask $task -Failed -Summary $_.Exception.Message; throw }
    $failed = @(); if ($out -and $out.PSObject.Properties['Results']) { $failed = @($out.Results | Where-Object { $_.Status -eq 'Failed' }) }
    if ($failed.Count -gt 0) { Complete-AVDTuneUiTask $task -Failed -Summary "$($failed.Count) step(s) failed: $($failed[0].Message)" }
    else { Complete-AVDTuneUiTask $task -Summary "$(@($out.Results | Where-Object { $_.Status -in 'Changed', 'Reverted' }).Count) changed" }
    $out
}

function Get-MaskRequest {
    # What the wizard form asks for, validated by the module again; throws with the reason
    $entries = @(foreach ($k in $script:MaskChecks.Keys) { if ($script:MaskChecks[$k].IsChecked) { @{ Folder = '%SystemDriveFolder%\Users\Public\Desktop'; Name = [string]$k } } })
    if ($entries.Count -eq 0) { throw 'Tick at least one entry of the Public Desktop.' }
    $p = @{ Name = $ui.TxtMaskName.Text.Trim(); Entries = $entries; Visibility = 'Hidden' }
    if ($ui.CmbMaskVis.SelectedIndex -eq 1) {
        $p.Visibility = 'HiddenExceptGroups'
        $kind = [string]$ui.CmbMaskKind.SelectedItem
        $dir = Get-MaskDirectory
        if ($kind -like 'Existing AD*') {
            $gn = [string]$ui.CmbMaskExisting.SelectedItem
            $g = if ($dir) { @($dir.Groups | Where-Object { (Get-MaskGroupSam $_) -eq $gn })[0] } else { $null }
            if (-not $g) { throw 'Choose an existing AD group (read from the domain controller in the start sequence).' }
            # bound by sAMAccountName and SID: the module checks both against the domain controller and takes account and DN from there
            $p.Groups = @([pscustomobject]@{ Sam = (Get-MaskGroupSam $g); Sid = [string]$g.Sid; Account = "$($dir.NetBiosName)\$(Get-MaskGroupSam $g)"; Dn = [string]$g.Dn })
            $p.Directory = $dir
        }
        elseif ($kind -like 'New AD*') {
            if (-not $dir) { throw 'The domain is not read yet: connect to the domain controller in the start sequence first.' }
            $p.CreateGroup = @{ Kind = 'Ad'; Name = $ui.TxtMaskGroup.Text.Trim(); OuDn = [string]$ui.CmbMaskOu.SelectedItem }
            $p.Directory = $dir
        }
        else { $p.CreateGroup = @{ Kind = 'Local'; Name = $ui.TxtMaskGroup.Text.Trim() } }
    }
    $p
}

function Show-MaskRun($Run, [string]$What) {
    foreach ($r in @($Run.Results)) { Register-StepResult $r }
    $changed = @($Run.Results | Where-Object { $_.Status -in 'Changed', 'Reverted' }).Count; $failed = @($Run.Results | Where-Object { $_.Status -eq 'Failed' })
    $text = "${What}: $changed changed$(if ($failed.Count -gt 0) { ", $($failed.Count) failed ($($failed[0].Message))" })."
    Show-Toast $text; $ui.TxtMaskState.Text = $text
    Start-OverviewRefresh
}

function Invoke-MaskSave([bool]$WhatIf) {
    # One try/finally around everything: the connection is closed and the password box is cleared on every path (preview, refusal of the confirmation, error, success).
    # The connection (with the password) is only made when it is needed: for the preview (nothing is written), and for a write only after the write gate and the confirmation.
    $lc = $null; $run = $null
    try {
        $p = Get-MaskRequest
        $m = Get-MaskAdapter
        if ($WhatIf) {
            if ($p.Directory) { $lc = Get-MaskLdap; $p.Ldap = $lc.Ldap; $p.Conn = $lc.Conn }   # the groups are checked against the DC (name, SID) and the DN of the built-in Administrators group is read from it
            $run = Save-AVDTuneRuleSet -Machine $script:Machine -M $m -Root $script:StateRoot @p -WhatIf
            $lines = @($run.Results | ForEach-Object { "$($_.Title): $($_.Status)" })
            $chg = if ($run.AssignmentChange) { " The existing assignment changes from '$($run.AssignmentChange.Old)' to '$($run.AssignmentChange.New)'." } else { '' }
            $ui.TxtMaskState.Text = 'Preview (nothing written): ' + ($lines -join '; ') + '.' + $chg + ' Rule lines: ' + ((@($p.Entries) | ForEach-Object { "$($_.Folder)  $($_.Name)  flags 0x00000222" }) -join ' | ')
            return
        }
        Assert-MaskWrite
        $text = "Write the rule set '$($p.Name)' with $(@($p.Entries).Count) hiding rule(s) to C:\Program Files\FSLogix\Apps\Rules?"
        if ($p.CreateGroup) {
            $where = if ($p.CreateGroup.Kind -eq 'Ad') { "in Active Directory, OU $($p.CreateGroup.OuDn), domain $($p.Directory.DnsName)" } else { 'on this master' }
            $text = "Create the group '$($p.CreateGroup.Name)' $where and write the rule set '$($p.Name)'? The group is deleted again by 'Undo the last change' as long as it has no members."
        }
        if (-not (Confirm-Action $text 'App Masking')) { return }
        if ($p.CreateGroup) { $p.Confirmed = $true }
        if ($p.Directory) { $lc = Get-MaskLdap; $p.Ldap = $lc.Ldap; $p.Conn = $lc.Conn }   # only now: after the write gate and the confirmation
        # an existing rule set whose assignment would mean something else: both meanings in a second question; Old and New go to the module, which refuses when the real values differ
        $preview = Save-AVDTuneRuleSet -Machine $script:Machine -M $m -Root $script:StateRoot @p -WhatIf
        if ($preview.AssignmentChange) {
            if (-not (Confirm-Action "The rule set '$($p.Name)' exists already and its assignment changes:`nNow: $($preview.AssignmentChange.Old)`nNew: $($preview.AssignmentChange.New)`nThis changes who sees the hidden items. Continue?" 'App Masking')) { return }
            $p.ExpectedChange = @{ Old = [string]$preview.AssignmentChange.Old; New = [string]$preview.AssignmentChange.New }
        }
        $run = Invoke-MaskChange -Title 'Writing the App Masking rule set' -Step "Rule set $($p.Name)" -Block { Save-AVDTuneRuleSet -Machine $script:Machine -M $m -Root $script:StateRoot @p -User ([string]$env:USERNAME) -SnapshotId (Get-MaskGateSnapshot) }
    }
    finally { if ($lc) { & $lc.Close }; $ui.PwdMask.Clear() }
    Show-MaskRun $run 'App Masking'; Update-MaskView
}

function Remove-MaskSet([string]$Name) {
    Assert-MaskWrite
    if (-not (Confirm-Action "Delete the rule set '$Name' (both files)? 'Undo the last change' restores them." 'App Masking')) { return }
    $m = Get-MaskAdapter
    $run = Invoke-MaskChange -Title 'Removing an App Masking rule set' -Step $Name -Block { Remove-AVDTuneRuleSet -Machine $script:Machine -M $m -Root $script:StateRoot -Name $Name -User ([string]$env:USERNAME) -SnapshotId (Get-MaskGateSnapshot) }
    Show-MaskRun $run 'Remove rule set'; Update-MaskView
}

Build-MaskPage
Add-Click $ui.BtnMaskRefresh { Update-MaskView }
Add-Click $ui.BtnMaskUncovered { foreach ($d in @($script:MaskOv.PublicDesktop)) { if ($script:MaskChecks.ContainsKey([string]$d.Name)) { $script:MaskChecks[[string]$d.Name].IsChecked = ($d.State -ne 'Hidden' -and $d.IsShortcut) } } }
Add-Click $ui.BtnMaskPreview { Invoke-MaskSave $true }
Add-Click $ui.BtnMaskApply { Invoke-MaskSave $false }
Add-Click $ui.BtnMaskLogoff {
    Assert-MaskWrite
    if (-not (Confirm-Action 'Put the shortcut "Abmelden" (signs the user out, no confirmation dialog) on the Public Desktop for all users?' 'Public Desktop')) { return }
    $m = Get-MaskAdapter
    # the Public Desktop folder: Windows lets Authenticated Users/Users/Interactive change it. That is a warning, confirmed explicitly; any other problem (link, foreign owner, other write access) stops with its reason.
    $prev = Add-AVDTuneComfortShortcut -Machine $script:Machine -M $m -Root $script:StateRoot -Id logoff -WhatIf
    $expected = @($prev.DesktopWarnings)
    if ($expected.Count -gt 0) {
        if (-not (Confirm-Action "Warning: the folder of the Public Desktop can be changed by users ($($expected -join '; ')). That is the Windows default, but every user could replace or delete the shortcut, or put another one there. The file of the shortcut itself stays read only for users. Create the shortcut anyway?" 'Public Desktop')) { return }
    }
    $run = Invoke-MaskChange -Title 'Adding the Abmelden shortcut' -Step 'Public Desktop' -Block { Add-AVDTuneComfortShortcut -Machine $script:Machine -M $m -Root $script:StateRoot -Id logoff -ExpectedWarnings $expected -User ([string]$env:USERNAME) -SnapshotId (Get-MaskGateSnapshot) }
    Show-MaskRun $run 'Comfort shortcut'; Update-MaskView
}
Add-Click $ui.BtnMaskUndo {
    $m = Get-MaskAdapter; $lc = $null
    try {
        Assert-MaskWrite
        if (-not (Confirm-Action 'Put back what the last App Masking change found (files, shortcut, or the group it created)? A file that was changed after AVDTune wrote it, or a group with members, is not touched.' 'Undo')) { return }
        $u = Read-AVDTuneJson (Get-AVDTuneMaskingUndoPath $script:StateRoot)
        $p = @{}
        if ($u -and @(Get-AVDTuneProp $u 'Groups' | Where-Object { $_ -and $_.Kind -eq 'Ad' }).Count -gt 0) { $lc = Get-MaskLdap; $p.Ldap = $lc.Ldap; $p.Conn = $lc.Conn }
        $run = Invoke-MaskChange -Title 'Undoing the last App Masking change' -Step 'Putting back' -Block { Undo-AVDTuneMaskingChange -Machine $script:Machine -M $m -Root $script:StateRoot @p -User ([string]$env:USERNAME) -SnapshotId (Get-MaskGateSnapshot) }
    }
    finally { if ($lc) { & $lc.Close }; $ui.PwdMask.Clear() }
    Show-MaskRun $run 'Undo'; Update-MaskView
}

