# The Customizations page (dot-sourced by Start-AVDTune.ps1 after the App Masking and Software pages; plan 3d, issue #85). Logic is in Modules\AVDTune.Custom.psm1.
# Why its own page: shortcuts, fonts and own steps are three lists of the customer's details with the same Test/Apply/Undo flow, too much for the User experience
# page (watermark) and not App Masking (that page decides who sees a desktop entry; a shortcut made here uses it for its "Visible for").
# The page is built in code (one hook in Start-AVDTune.ps1, none in UI\AVDTune.xaml); every text comes from the language files (T 'cust.*').
# Reading the state runs in a background runspace (New-AVDTunePowerShell) as a task; Apply, Undo and the test of the scripts are writer jobs (CustJob, #66) behind the
# write gate. Saving an item only writes AVDTune's own state (config\customizations.json). Test mode: the fake machine, the fake customization adapter and a fake library.

$script:CustJob = $null
$script:CustStatus = $null
$script:CustLibrary = $null
$script:CustLibraryError = ''
$script:CustUiBuilt = $false
$script:CustForm = @{}
$script:CustFake = $null
$script:CustAfter = $null
$script:CustQueued = $false
$script:CustReadKinds = @('Status', 'Reach', 'Preview')   # the kinds of CustJob that do not change the master (also in WriterReadOnlyKinds)
if ($script:TestMode) {
    . (Get-TestScript 'FakeCustom.ps1')
    $script:CustFake = New-AVDTuneFakeCustom -Seed @{ Library = @{ 'corp-sans.ttf' = 'FONT'; 'crm.ico' = 'ICON'; 'policy.txt' = 'Policy'; 'setup-printer.ps1' = 'param($AVDTuneMode) exit 0' }; Files = @{ 'C:\Apps\crm.exe' = 'exe' } }
}

function Get-CustAdapter { if ($script:TestMode) { $script:CustFake } else { if (-not $script:RealCust) { $script:RealCust = New-AVDTuneCustomAdapter }; $script:RealCust } }

# ---------------------------------------------------------------- the job
$script:CustWorkerText = @'
param($AppRoot, $FakeDir, $Root, $Kind, $Ids, $Gate, $Sync, $User, $Tokens, $SiteUrl, $Library, $SharedMachine, $SharedCustom)
$ErrorActionPreference = 'Stop'
foreach ($n in 'AVDTune', 'AVDTune.Updates', 'AVDTune.Software', 'AVDTune.FSLogix', 'AVDTune.Directory', 'AVDTune.Masking', 'AVDTune.Custom') { Import-Module (Join-Path $AppRoot "Modules\$n.psm1") -Force }
$ctx = $null
try {
    if ($FakeDir) {
        . (Join-Path $FakeDir 'FakeMachine.ps1'); . (Join-Path $FakeDir 'FakeSoftware.ps1'); . (Join-Path $FakeDir 'FakeCustom.ps1')
        $m = New-AVDTuneFakeMachine; $c = $SharedCustom   # an own fake machine (only its clock is used): the shared one must not be called from two runspaces (#80)
        $lib = New-AVDTuneFakeLibrary
        foreach ($k in @($c.Store.Library.Keys)) { Add-AVDTuneFakeLibraryAsset -Library $lib -Name $k -Content $c.Store.Library[$k] }
        $ctx = New-AVDTuneLibraryContext -SitesToken $lib.SitesToken -GraphToken $lib.GraphToken -SiteUrl $lib.SiteUrl -Library $lib.Library -Transport $lib.Transport
    }
    else {
        $m = New-AVDTuneMachine; $c = New-AVDTuneCustomAdapter
        if ($SiteUrl -and $Tokens -and $Tokens.Sites) { $ctx = New-AVDTuneLibraryContext -SitesToken $Tokens.Sites -GraphToken $Tokens.Graph -SiteUrl $SiteUrl -Library $Library }
    }
    if ($Gate) { Open-AVDTuneWriteGate -SnapshotId $Gate.SnapshotId -ConfirmedBy $Gate.ConfirmedBy }
    switch ($Kind) {
        { $_ -in 'Status', 'Reach', 'TestScripts' } {
            $lib = $null; $libError = ''
            if ($ctx) { $Sync.Text = 'library'; try { $lib = Get-AVDTuneAssetManifest -Context $ctx } catch { $libError = $_.Exception.Message } }
            elseif ($Tokens -and $Tokens.Reason) { $libError = [string]$Tokens.Reason }
            $Sync.Text = 'status'
            # the scripts are tested like a change of the master (marker, LastChange, run record, review #85 L5); UNC paths are asked only on request (L2)
            $st = if ($Kind -eq 'TestScripts') { Invoke-AVDTuneCustomScriptTest -Machine $m -C $c -Root $Root } else { Get-AVDTuneCustomStatus -Machine $m -C $c -Root $Root -NoScripts -CheckUnc:($Kind -eq 'Reach') }
            [pscustomobject]@{ Status = $st; Library = $lib; LibraryError = $libError }
        }
        'Preview' { $Sync.Text = 'library'; [pscustomobject]@{ Preview = (Get-AVDTuneCustomPreview -C $c -Root $Root -Context $ctx -Name $Ids[0] -Sha256 $Ids[1]) } }
        { $_ -in 'Apply', 'Undo' } { $Sync.Text = 'run'; Invoke-AVDTuneCustomRun -Machine $m -C $c -Root $Root -Mode $Kind -Ids $Ids -Context $ctx -User $User -SnapshotId $Gate.SnapshotId }
    }
}
finally { if ($ctx) { Close-AVDTuneLibraryContext $ctx }; $Tokens = $null }
'@

function Start-CustJob([string]$Kind, [string[]]$Ids = @(), $After) {
    if ($script:CustJob) { throw (T 'cust.err.busy') }
    $writes = $Kind -notin $script:CustReadKinds
    if ($writes) {
        if (-not (Test-AVDTuneWriteAllowed)) { throw (T 'shell.readonly') }
        Assert-NoOtherWriter
    }
    $settings = Get-SwSettings
    $siteUrl = [string]$settings.StoreSiteUrl
    $tokens = if ($siteUrl -and -not $script:TestMode) { Get-SwTokens } else { @{ Sites = ''; Graph = ''; Reason = '' } }
    $sync = [hashtable]::Synchronized(@{ Text = '' })
    $ps = New-AVDTunePowerShell
    [void]$ps.AddScript($script:CustWorkerText).AddArgument($script:AppRoot).AddArgument($script:SwFakeDir).AddArgument($script:StateRoot).AddArgument($Kind).AddArgument(@($Ids)).AddArgument((Get-AVDTuneWriteGate)).AddArgument($sync).AddArgument((Get-SwUser)).AddArgument($tokens).AddArgument($siteUrl).AddArgument([string]$settings.StoreLibrary).AddArgument($(if ($script:TestMode) { $script:Machine } else { $null })).AddArgument($(if ($script:TestMode) { $script:CustFake } else { $null }))
    $retry = $(if ($Kind -eq 'Status') { @{ Command = 'Start-CustJob'; Arguments = @('Status') } })
    $task = Start-AVDTuneUiTask -Kind "customizations-$($Kind.ToLower())" -Title (T "cust.task.$($Kind.ToLower())") -Step (T 'cust.task.start') -Retry $retry
    $script:CustJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Kind = $Kind; Sync = $sync; Task = $task; Ids = @($Ids) }
    $script:CustAfter = $After
    $tokens = $null
    if ($writes) { Set-ShutdownBlock $true }
    Set-CustBusy $true
}

function Set-CustBusy([bool]$Busy) {
    if (-not $script:CustUiBuilt) { return }
    foreach ($b in $ui.BtnCustRefresh, $ui.BtnCustUnc, $ui.BtnCustApplyAll, $ui.BtnCustScripts, $ui.BtnCustSave) { $b.IsEnabled = -not $Busy }
    foreach ($p in $ui.PanelCustShortcuts, $ui.PanelCustFonts, $ui.PanelCustSteps) { $p.IsEnabled = -not $Busy }
}

function Complete-CustJob {
    $job = $script:CustJob
    if (-not $job) { return }
    if (-not $job.Handle.IsCompleted) {
        $t = [string]$job.Sync.Text
        if ($t) { Update-AVDTuneUiTask $job.Task -Step (T "cust.step.$t") }
        return
    }
    $script:CustJob = $null
    if ($job.Kind -notin $script:CustReadKinds) { Set-ShutdownBlock $false }
    $result = $null; $err = ''
    try {
        $out = @($job.PS.EndInvoke($job.Handle))
        if ($job.PS.Streams.Error.Count -gt 0) { $err = $job.PS.Streams.Error[0].Exception.Message }
        $result = $out | Select-Object -Last 1
    }
    catch { $err = $_.Exception.Message }
    finally { $job.PS.Dispose() }
    Set-CustBusy $false
    $failed = [bool]$err; $summary = ''
    if ($job.Kind -eq 'Preview') { $summary = $(if ($err) { T 'cust.read.failed' $err } else { $result.Preview.Name }) }
    elseif ($job.Kind -in 'Status', 'Reach', 'TestScripts') {
        if ($err) { $summary = T 'cust.read.failed' $err }
        else {
            $script:CustStatus = $result.Status; $script:CustLibrary = $result.Library; $script:CustLibraryError = [string]$result.LibraryError
            $summary = T 'cust.read.done' (@($script:CustStatus.Items | Where-Object { $_.Status -eq 'Compliant' }).Count) @($script:CustStatus.Items).Count
        }
    }
    else {
        $run = if ($result) { $result.Run } else { $null }
        if ($run) { foreach ($r in $run.Results) { Register-StepResult $r } }
        $ch = if ($run) { @($run.Results | Where-Object { $_.Status -eq 'Changed' }).Count } else { 0 }
        $bad = if ($run) { @($run.Results | Where-Object { $_.Status -eq 'Failed' }) } else { @() }
        if ($bad.Count -gt 0) { $failed = $true }
        $summary = T 'cust.run.done' $ch $bad.Count
        if ($bad.Count -gt 0) { $summary += ' ' + $bad[0].Title + ': ' + $bad[0].Message }
        if ($result -and @($result.Skipped).Count -gt 0) { $summary += ' ' + (@($result.Skipped | ForEach-Object { "$($_.Title): $($_.Message)" }) -join ' ') }
        if ($err) { $summary += " $err" }
        Show-Toast $summary
        [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'customizations' -Subject $summary)
        Save-Protocol
        Start-OverviewRefresh
    }
    Complete-AVDTuneUiTask $job.Task -Failed:$failed -Summary $summary
    if ($script:CustUiBuilt) { $ui.TxtCustState.Text = $summary }
    $after = $script:CustAfter; $script:CustAfter = $null
    if ($after -and -not $err -and $result -and $job.Kind -notin 'Status', 'Reach') { try { Invoke-CustAfter $after $result } catch { Show-Error $_.Exception.Message } }
    if ((($job.Kind -notin 'Status', 'Reach', 'Preview', 'TestScripts') -or $script:CustQueued) -and -not $script:CustJob) { $script:CustQueued = $false; Start-CustJob 'Status' }
    Update-CustView
}
$script:Timer.Add_Tick({ try { Complete-CustJob } catch { Show-Error $_.Exception.Message } })

function Invoke-CustAfter($After, $Result) {
    # What follows a run on the window thread (no closures: they would hide the functions of this script): the visibility of new desktop shortcuts, or taking an undone item out of the list
    switch ($After.Kind) {
        'Visibility' { foreach ($it in @($After.Items)) { $st = @($Result.Run.Results | Where-Object { $_.Id -eq (Get-AVDTuneCustomStepId $it) })[0]; if ($st -and $st.Status -in 'Changed', 'Unchanged') { Set-CustVisibility $it } } }
        'Save' {
            # the file or script was fetched against its pinned SHA256: the administrator sees size, hash and the first lines before it goes into the list (review #85, M3/L1)
            $pv = $Result.Preview
            $lines = if (@($pv.Lines).Count) { (@($pv.Lines) -join "`n") } else { '-' }
            if (Confirm-Action (T 'cust.ask.preview' $pv.Name $pv.Size $pv.Sha256 $lines) (T 'nav.customizations')) { Add-CustItem $After.Raw }
        }
        'Remove' { if (-not (Read-AVDTuneCustomUndo $script:StateRoot).ContainsKey($After.Id)) { Remove-AVDTuneCustomItem -Root $script:StateRoot -Id $After.Id; Show-Toast (T 'cust.removed' $After.Title) } }
    }
}

# ---------------------------------------------------------------- App Masking for a desktop shortcut (#69 mechanism)
function Set-CustVisibility($Item) {
    $req = Get-AVDTuneCustomMaskingRequest -Item $Item
    if (-not $req) { return }
    Assert-MaskWrite
    $mm = Get-MaskAdapter; $dir = Get-MaskDirectory
    $row = @(Get-AVDTuneMaskingList -M $mm -Directory $dir | Where-Object { $_.Name -ceq $req.FileName })[0]
    if (-not $row) { throw (T 'cust.mask.norow' $req.FileName) }
    $ch = Get-AVDTuneShortcutChange -Row $row -M $mm -Mode $req.Mode -GroupSid $req.GroupSid -Directory $dir
    if ($ch.Action -ne 'Save') { return }
    if (-not (Confirm-Action (T 'cust.mask.ask' $req.FileName $ch.Old $ch.New) (T 'nav.appmasking'))) { return }
    $p = $ch.SaveParams; $lc = $null
    try {
        if ($p.Directory) { $lc = Get-MaskLdap; $p.Ldap = $lc.Ldap; $p.Conn = $lc.Conn }
        $preview = Save-AVDTuneRuleSet -Machine $script:Machine -M $mm -Root $script:StateRoot @p -WhatIf
        if ($preview.AssignmentChange) {
            if (-not (Confirm-Action (T 'cust.mask.change' $p.Name $preview.AssignmentChange.Old $preview.AssignmentChange.New) (T 'nav.appmasking'))) { return }
            $p.ExpectedChange = @{ Old = [string]$preview.AssignmentChange.Old; New = [string]$preview.AssignmentChange.New }
        }
        $run = Invoke-MaskChange -Title (T 'cust.mask.task' $req.FileName) -Step $p.Name -Block { Save-AVDTuneRuleSet -Machine $script:Machine -M $mm -Root $script:StateRoot @p -User ([string]$env:USERNAME) -SnapshotId (Get-MaskGateSnapshot) }
    }
    finally { if ($lc) { & $lc.Close }; if ($ui.PwdMask) { $ui.PwdMask.Clear() } }
    Show-MaskRun $run (T 'nav.appmasking')
}

# ---------------------------------------------------------------- the page
function New-CustCombo([object[]]$Items, [string]$Automation, [bool]$Editable = $false) {
    $cb = New-Object System.Windows.Controls.ComboBox; $cb.Padding = '8,6'; $cb.IsEditable = $Editable
    if (@($Items).Count -gt 0) { $cb.ItemsSource = @($Items); if (-not $Editable) { $cb.SelectedIndex = 0 } }   # an empty list stays open for Items.Add (Visible for)
    [System.Windows.Automation.AutomationProperties]::SetName($cb, $Automation)
    $cb
}

function Build-CustPage {
    if ($script:CustUiBuilt) { return }
    $parent = $ui.PagePlaceholder.Parent
    $page = New-Object System.Windows.Controls.Grid; $page.Visibility = 'Collapsed'
    $sv = New-Object System.Windows.Controls.ScrollViewer; $sv.SetResourceReference([System.Windows.Controls.ScrollViewer]::StyleProperty, 'PageScroll')
    $root = New-Object System.Windows.Controls.StackPanel; $root.Margin = '40,32,40,28'; $root.MaxWidth = 1000; $root.HorizontalAlignment = 'Left'
    [void]$root.Children.Add((New-MaskText (T 'nav.customizations') 'PageTitle'))
    $ui.TxtCustSubtitle = New-MaskText (T 'cust.subtitle') 'Subtitle'; [void]$root.Children.Add($ui.TxtCustSubtitle)
    $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.Margin = '0,12,0,0'
    $ui.BtnCustRefresh = New-MaskButton (T 'cust.btn.refresh') (T 'cust.btn.refresh.tip')
    $ui.BtnCustScripts = New-MaskButton (T 'cust.btn.scripts') (T 'cust.btn.scripts.tip')
    $ui.BtnCustUnc = New-MaskButton (T 'cust.btn.unc') (T 'cust.btn.unc.tip')
    $ui.BtnCustApplyAll = New-MaskButton (T 'cust.btn.applyall') (T 'cust.btn.applyall.tip') $true
    foreach ($b in $ui.BtnCustRefresh, $ui.BtnCustUnc, $ui.BtnCustScripts, $ui.BtnCustApplyAll) { [void]$row.Children.Add($b) }
    [void]$root.Children.Add($row)
    $ui.TxtCustState = New-MaskText '' 'Hint' '0,8,0,0'; [void]$root.Children.Add($ui.TxtCustState)
    $ui.TxtCustLibrary = New-MaskText '' 'Hint' '0,4,0,0'; [void]$root.Children.Add($ui.TxtCustLibrary)
    foreach ($k in 'Shortcuts', 'Fonts', 'Steps') {
        $card = New-MaskCard (T "cust.card.$($k.ToLower())") (T "cust.card.$($k.ToLower()).hint")
        $p = New-Object System.Windows.Controls.StackPanel; $p.Margin = '0,8,0,0'; [void]$card.Panel.Children.Add($p)
        $ui["PanelCust$k"] = $p
        [void]$root.Children.Add($card.Card)
    }
    $add = New-MaskCard (T 'cust.card.add') (T 'cust.card.add.hint')
    $ui.CmbCustKind = New-CustCombo @(Get-AVDTuneCustomKinds | ForEach-Object { T "cust.kind.$($_.ToLower())" }) (T 'cust.field.kind')
    [void]$add.Panel.Children.Add((New-MaskLabeled (T 'cust.field.kind') $ui.CmbCustKind))
    $ui.PanelCustForm = New-Object System.Windows.Controls.StackPanel; [void]$add.Panel.Children.Add($ui.PanelCustForm)
    $ui.BtnCustSave = New-MaskButton (T 'cust.btn.save') (T 'cust.btn.save.tip') $true; $ui.BtnCustSave.HorizontalAlignment = 'Left'; $ui.BtnCustSave.Margin = '0,10,0,0'
    [void]$add.Panel.Children.Add($ui.BtnCustSave)
    $ui.TxtCustErrors = New-MaskText '' '' '0,8,0,0'; Set-Brush $ui.TxtCustErrors ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'Danger'; [void]$add.Panel.Children.Add($ui.TxtCustErrors)
    [void]$root.Children.Add($add.Card)
    $sv.Content = $root; [void]$page.Children.Add($sv)
    $ui.PageCustomizations = $page; [void]$parent.Children.Add($page)
    $ui.CmbCustKind.Add_SelectionChanged({ try { Update-CustForm } catch { Show-Error $_.Exception.Message } })
    Add-Click $ui.BtnCustRefresh { Start-CustJob 'Status' }
    Add-Click $ui.BtnCustUnc { if (Confirm-Action (T 'cust.ask.unc') (T 'nav.customizations')) { Start-CustJob 'Reach' } }
    Add-Click $ui.BtnCustScripts { if (Confirm-Action (T 'cust.ask.scripts') (T 'nav.customizations')) { Start-CustJob 'TestScripts' } }
    Add-Click $ui.BtnCustApplyAll { Invoke-CustApply @() }
    Add-Click $ui.BtnCustSave { Save-CustForm }
    $script:CustUiBuilt = $true
    Update-CustForm
}

function Get-CustKind { @(Get-AVDTuneCustomKinds)[[Math]::Max(0, $ui.CmbCustKind.SelectedIndex)] }

function Get-CustLibraryFiles([string[]]$Extensions) {
    if (-not $script:CustLibrary -or $script:CustLibrary.State -ne 'Ready') { return @() }
    @($script:CustLibrary.Files | Where-Object { $_.Extension -in $Extensions } | ForEach-Object { $_.Name })
}

function Update-CustForm {
    # One labelled control per field of the chosen kind; the SHA256 fields are not asked for (they come from the manifest)
    $ui.PanelCustForm.Children.Clear(); $script:CustForm = @{}; $ui.TxtCustErrors.Text = ''
    $kind = Get-CustKind
    $ch = Get-AVDTuneCustomChoices
    $groups = @(); $d = Get-MaskDirectory; if ($d) { $groups = @(@(Get-AVDTuneProp $d 'Groups') | Where-Object { $_ -and (Get-AVDTuneProp $_ 'Sid') }) }
    foreach ($f in (Get-AVDTuneCustomFields $kind)) {
        if ($f -in 'Sha256', 'IconSha256') { continue }
        $label = T "cust.field.$($f.ToLower())"
        $ctl = switch ($f) {
            'Location' { New-CustCombo $ch.Locations $label }
            'ValueType' { New-CustCombo $ch.ValueTypes $label }
            'Rights' { New-CustCombo $ch.Rights $label }
            'Principal' { New-CustCombo $ch.Principals $label $true }
            'IconSource' { New-CustCombo @('Target', 'Library') $label }
            'Undo' { New-CustCombo @('No', 'Yes') $label }
            'IconFile' { New-CustCombo (Get-CustLibraryFiles @('.ico')) $label }
            'File' { New-CustCombo (Get-CustLibraryFiles $(switch ($kind) { 'Font' { @('.ttf', '.otf') } 'Script' { @('.ps1') } default { @('.txt', '.ini', '.xml', '.json', '.cfg', '.config', '.ico', '.png', '.jpg', '.bmp', '.reg', '.pdf', '.url') } })) $label }
            'Visibility' {
                $cb = New-CustCombo @() $label
                $cb.Items.Add((T 'cust.vis.everyone')) | Out-Null; $cb.Items.Add((T 'cust.vis.admins')) | Out-Null
                $tags = @('', 'Admins'); foreach ($g in $groups) { $cb.Items.Add([string](Get-MaskGroupSam $g)) | Out-Null; $tags += [string]$g.Sid }
                $cb.Tag = $tags; $cb.SelectedIndex = 0; $cb
            }
            default { $tb = New-Object System.Windows.Controls.TextBox; $tb.Padding = '8,6'; [System.Windows.Automation.AutomationProperties]::SetName($tb, $label); if ($f -eq 'IconIndex') { $tb.Text = '0' } elseif ($f -eq 'TimeoutSeconds') { $tb.Text = '600' }; $tb }
        }
        $script:CustForm[$f] = $ctl
        [void]$ui.PanelCustForm.Children.Add((New-MaskLabeled $label $ctl))
    }
    if (@(Get-AVDTuneCustomFields $kind) -match 'File' -and -not (Get-CustLibraryFiles @('.ttf', '.otf', '.ico', '.ps1', '.txt'))) { $ui.TxtCustErrors.Text = T 'cust.form.nolibrary' }
}

function Get-CustFormRaw {
    $raw = @{ Kind = (Get-CustKind) }
    foreach ($f in $script:CustForm.Keys) {
        $c = $script:CustForm[$f]
        $raw[$f] = if ($c -is [System.Windows.Controls.TextBox]) { [string]$c.Text }
        elseif ($f -eq 'Visibility') { if ($c.SelectedIndex -ge 0) { [string]$c.Tag[$c.SelectedIndex] } else { '' } }
        elseif ($c.IsEditable) { [string]$c.Text }
        else { [string]$c.SelectedItem }
    }
    $raw
}

function Get-CustFiles { if ($script:CustLibrary -and $script:CustLibrary.State -eq 'Ready') { @($script:CustLibrary.Files) } else { @() } }

function Save-CustForm {
    # a file or a script from the library is shown first (size, SHA256, first lines); everything else is added at once
    $raw = Get-CustFormRaw
    $check = ConvertTo-AVDTuneCustomItem -Raw $raw -FromForm -Library (Get-CustFiles) -Forbidden (Get-AVDTuneCustomForbiddenFolders -Root $script:StateRoot)
    if (-not $check.Valid) { $ui.TxtCustErrors.Text = ($check.Errors -join "`r`n"); return }
    if ($check.Item.Kind -in 'FileCopy', 'Script') { Start-CustJob 'Preview' @($check.Item.File, $check.Item.Sha256) @{ Kind = 'Save'; Raw = $raw }; return }
    Add-CustItem $raw
}

function Add-CustItem($Raw) {
    $r = Add-AVDTuneCustomItem -Root $script:StateRoot -Raw $Raw -Library (Get-CustFiles)
    if (-not $r.Valid) { $ui.TxtCustErrors.Text = ($r.Errors -join "`r`n"); return }
    $ui.TxtCustErrors.Text = ''
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'customizations' -Subject (T 'cust.saved' (Get-AVDTuneCustomTitle $r.Item)))
    Save-Protocol
    Show-Toast (T 'cust.saved' (Get-AVDTuneCustomTitle $r.Item))
    Update-CustForm
    if ($script:CustJob) { $script:CustQueued = $true } else { Start-CustJob 'Status' }
}

function Invoke-CustApply([string[]]$Ids) {
    $items = @($script:CustStatus.Items | Where-Object { $Ids.Count -eq 0 -or $_.Id -in $Ids })
    if ($items.Count -eq 0) { Show-Toast (T 'cust.none'); return }
    $list = (@($items | Select-Object -First 12 | ForEach-Object { '- ' + $_.Title }) -join "`n") + $(if ($items.Count -gt 12) { "`n..." } else { '' })
    $risky = @($items | Where-Object { $_.Title -like '*RISK:*' })
    $ask = (T 'cust.ask.apply' $items.Count $list) + $(if ($risky.Count) { "`n`n" + (T 'cust.ask.risk' $risky.Count) } else { '' })
    if (-not (Confirm-Action $ask (T 'nav.customizations'))) { return }
    $vis = @($items | Where-Object { Get-AVDTuneCustomMaskingRequest -Item $_.Item } | ForEach-Object { $_.Item })
    Start-CustJob 'Apply' $Ids $(if ($vis.Count) { @{ Kind = 'Visibility'; Items = $vis } })
}

function Get-CustRow([string]$Id) { $r = @($script:CustStatus.Items | Where-Object { $_.Id -eq $Id })[0]; if (-not $r) { throw (T 'cust.err.norow') }; $r }

function Invoke-CustUndo($Row, [bool]$Remove) {
    $ask = if ($Remove) { T 'cust.ask.remove' $Row.Title } else { T 'cust.ask.undo' $Row.Title }
    if (-not (Confirm-Action $ask (T 'nav.customizations'))) { return }
    if (-not $Row.Undo) {
        if ($Remove) { Remove-AVDTuneCustomItem -Root $script:StateRoot -Id $Row.Id; Show-Toast (T 'cust.removed' $Row.Title); Start-CustJob 'Status' } else { Show-Toast (T 'cust.nothing') }
        return
    }
    Start-CustJob 'Undo' @($Row.Id) $(if ($Remove) { @{ Kind = 'Remove'; Id = $Row.Id; Title = $Row.Title } })
}

$script:CustPill = @{ Compliant = @('SuccessBg', 'Success', 'cust.pill.ok'); NonCompliant = @('WarningBg', 'Warning', 'cust.pill.missing'); Failed = @('ErrorBg', 'Danger', 'cust.pill.failed'); Unknown = @('Hover', 'MutedText', 'cust.pill.unknown'); Invalid = @('ErrorBg', 'Danger', 'cust.pill.invalid') }
function New-CustRow([string]$Status, [string]$Title, [string]$Detail, [object[]]$Buttons) {
    $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,4,0,4'
    foreach ($w in 120, '*', 'Auto') { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$g.ColumnDefinitions.Add($cd) }
    $k = $script:CustPill[$Status]; if (-not $k) { $k = $script:CustPill.Unknown }
    $pill = New-Object System.Windows.Controls.Border; Set-Brush $pill ([System.Windows.Controls.Border]::StyleProperty) 'Pill'; $pill.Padding = '10,2'; $pill.HorizontalAlignment = 'Left'; $pill.VerticalAlignment = 'Top'
    Set-Brush $pill ([System.Windows.Controls.Border]::BackgroundProperty) $k[0]
    $pt = New-Object System.Windows.Controls.TextBlock; $pt.Text = T $k[2]; $pt.FontSize = 12; $pt.FontWeight = 'SemiBold'; Set-Brush $pt ([System.Windows.Controls.TextBlock]::ForegroundProperty) $k[1]; $pill.Child = $pt
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1); $sp.Margin = '0,0,10,0'
    [void]$sp.Children.Add((New-MaskText $Title)); if ($Detail) { [void]$sp.Children.Add((New-MaskText $Detail 'Hint' '0,2,0,0')) }
    $bp = New-Object System.Windows.Controls.StackPanel; $bp.Orientation = 'Horizontal'; $bp.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2); $bp.VerticalAlignment = 'Top'
    foreach ($b in @($Buttons)) { if ($b) { [void]$bp.Children.Add($b) } }
    foreach ($e in $pill, $sp, $bp) { [void]$g.Children.Add($e) }
    $g
}

function Update-CustView {
    if (-not $script:CustUiBuilt) { return }
    $lib = $script:CustLibrary
    $ui.TxtCustLibrary.Text = if ($script:CustLibraryError) { T 'cust.lib.error' $script:CustLibraryError } elseif ($lib) { "$(T 'cust.lib.state') $($lib.Message)$(if (@($lib.Notes).Count) { ' ' + (@($lib.Notes) -join ' ') })" } else { T 'cust.lib.none' }
    foreach ($p in $ui.PanelCustShortcuts, $ui.PanelCustFonts, $ui.PanelCustSteps) { $p.Children.Clear() }
    $st = $script:CustStatus
    if (-not $st) { [void]$ui.PanelCustSteps.Children.Add((New-MaskText (T 'cust.notread') 'Hint')); return }
    if ($st.Problem) { $ui.TxtCustState.Text = $st.Problem }
    $busy = [bool]$script:CustJob
    foreach ($r in @($st.Items)) {
        $detail = @()
        if ($r.State) { $detail += (T 'cust.row.state' $r.State) }
        if ($r.Message) { $detail += $r.Message }
        foreach ($x in @($r.Reach | Where-Object { $_.Ok -eq $false })) { $detail += (T 'cust.row.unreachable' $x.What $x.Path) }
        foreach ($x in @($r.Reach | Where-Object { $null -eq $_.Ok })) { $detail += (T 'cust.row.unchecked' $x.What $x.Path) }
        # the handlers find their row by the id in DataContext (no GetNewClosure: it would hide the functions of this script)
        $apply = New-MaskButton (T 'cust.btn.apply') (T 'cust.btn.apply.tip' $r.Title); $apply.Add_Click({ param($src) try { Invoke-CustApply @([string]$src.DataContext) } catch { Show-Error $_.Exception.Message } })
        $undo = $null; if ($r.Undo) { $undo = New-MaskButton (T 'cust.btn.undo') (T 'cust.btn.undo.tip' $r.Title); $undo.Add_Click({ param($src) try { Invoke-CustUndo (Get-CustRow ([string]$src.DataContext)) $false } catch { Show-Error $_.Exception.Message } }) }
        $rm = New-MaskButton (T 'cust.btn.remove') (T 'cust.btn.remove.tip' $r.Title); $rm.Add_Click({ param($src) try { Invoke-CustUndo (Get-CustRow ([string]$src.DataContext)) $true } catch { Show-Error $_.Exception.Message } })
        foreach ($b in $apply, $undo, $rm) { if ($b) { $b.IsEnabled = -not $busy; $b.DataContext = [string]$r.Id; [void](Set-AVDTuneWriterButton $b) } }
        $panel = switch ($r.Kind) { 'Shortcut' { $ui.PanelCustShortcuts } 'Font' { $ui.PanelCustFonts } default { $ui.PanelCustSteps } }
        [void]$panel.Children.Add((New-CustRow ([string]$r.Status) "$(T "cust.kind.$($r.Kind.ToLower())"): $($r.Title)" ($detail -join ' ') @($apply, $undo, $rm)))
    }
    foreach ($x in @($st.Invalid)) {
        $rm = New-MaskButton (T 'cust.btn.remove') (T 'cust.btn.remove.tip' $x.Name); $rm.DataContext = [string]$x.Id
        $rm.Add_Click({ param($src) try { $id = [string]$src.DataContext; if (Confirm-Action (T 'cust.ask.removeinvalid' $id) (T 'nav.customizations')) { Remove-AVDTuneCustomItem -Root $script:StateRoot -Id $id -Force; Start-CustJob 'Status' } } catch { Show-Error $_.Exception.Message } })
        [void]$ui.PanelCustSteps.Children.Add((New-CustRow 'Invalid' "$($x.Kind): $($x.Name)" (@($x.Errors) -join ' ') @($rm)))
    }
    foreach ($p in @(@($ui.PanelCustShortcuts, 'shortcuts'), @($ui.PanelCustFonts, 'fonts'), @($ui.PanelCustSteps, 'steps'))) { if ($p[0].Children.Count -eq 0) { [void]$p[0].Children.Add((New-MaskText (T "cust.empty.$($p[1])") 'Hint')) } }
    if ($ui.CmbCustKind.SelectedIndex -ge 0 -and $script:CustForm.Count -gt 0 -and @($script:CustForm.Keys | Where-Object { $_ -in 'File', 'IconFile' }).Count -gt 0 -and $script:CustForm[@($script:CustForm.Keys | Where-Object { $_ -in 'File', 'IconFile' })[0]].Items.Count -eq 0) { Update-CustForm }
}

function Update-CustPage {
    Build-CustPage
    Update-CustView
    if (-not $script:CustStatus -and -not $script:CustJob) { Start-CustJob 'Status' }
}
