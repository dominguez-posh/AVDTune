# The Printers page (dot-sourced by Start-AVDTune.ps1 after the Customizations page; plan 3b, issue #86). Logic is in Modules\AVDTune.Printers.psm1.
# Only for identity models with a domain (Entra only: a hint to Universal Print). Print servers only from AD (pinned LDAPS of the start sequence; a typed name must be in
# that list); the server is read and its drivers are exported over WinRM with Kerberos (the domain account as UPN). The password is typed here, used for one job and cleared.
# Read checks every driver (export, limits, catalog signature); the administrator confirms the plan with the signers (another publisher than WHQL is allowed in a second
# confirmation) and Apply gets exactly that plan: a server that answers differently stops it (M1). Every read and change is a background job (New-AVDTunePowerShell) and a
# task; Apply, Undo and Maintain are writer jobs (PrnJob, #66) behind the write gate. Maintenance (bottom of this file) is a card on the Updates page: read the server again
# with the domain account of the start sequence (or a typed password), update new and changed drivers in maintenance mode with the checks of the first install, remove
# drivers no printer of the server uses any more. Texts from the language files (T 'prn.*'). Test mode: the fake printer adapter and the fake LDAP.

$script:PrnJob = $null
$script:PrnUiBuilt = $false
$script:PrnInventory = $null
$script:PrnCheck = @()
$script:PrnWarnings = @()
$script:PrnFake = $null
$script:PrnReadKinds = @('Servers', 'Read')   # the kinds of PrnJob that do not change the master (also in WriterReadOnlyKinds)
if ($script:TestMode) { . (Get-TestScript 'FakePrinters.ps1'); $script:PrnFake = New-AVDTuneFakePrinters }
# a TrustedHosts value left by the first version of this page (d63e941) is put back at the start (journal); the page checks again
if (Test-Path -LiteralPath (Get-AVDTunePrinterJournalPath $script:StateRoot) -PathType Leaf) { try { [void](Repair-AVDTunePrinterTrustedHosts -P $(if ($script:TestMode) { $script:PrnFake } else { New-AVDTunePrinterAdapter }) -Root $script:StateRoot) } catch { } }

function Get-PrnAdapter { if ($script:TestMode) { $script:PrnFake } else { if (-not $script:RealPrn) { $script:RealPrn = New-AVDTunePrinterAdapter }; $script:RealPrn } }
function Get-PrnAvailability { $e = $null; try { $e = Get-AVDTuneEnvironment $script:StateRoot } catch { }; Get-AVDTunePrinterAvailability $(if ($e) { Get-AVDTuneEnvironmentAnswers $e } else { $null }) }
function Get-PrnDc { $e = $null; try { $e = Get-AVDTuneEnvironmentFile $script:StateRoot } catch { }; Get-AVDTuneProp $e 'Dc' }
function Get-PrnDnsDomain { $d = $null; try { $d = Read-AVDTuneJson (Join-Path $script:StateRoot 'config\directory.json') } catch { }; [string](Get-AVDTuneProp (Get-AVDTuneProp $d 'Directory') 'DnsName') }

# ---------------------------------------------------------------- the job
$script:PrnWorkerText = @'
param($AppRoot, $FakeDir, $Root, $Kind, $Server, $Plan, $Selected, $Policy, $Gate, $Sync, $User, $Account, $Dc, $SharedP, $SharedLdap, $Remove, $SharedMachine)
$ErrorActionPreference = 'Stop'
foreach ($n in 'AVDTune', 'AVDTune.Updates', 'AVDTune.Directory', 'AVDTune.Start', 'AVDTune.Custom', 'AVDTune.Printers') { Import-Module (Join-Path $AppRoot "Modules\$n.psm1") -Force }
try {
    if ($FakeDir) { . (Join-Path $FakeDir 'FakeMachine.ps1'); $m = New-AVDTuneFakeMachine; $p = $SharedP } else { $m = New-AVDTuneMachine; $p = New-AVDTunePrinterAdapter }
    if ($Gate) { Open-AVDTuneWriteGate -SnapshotId $Gate.SnapshotId -ConfirmedBy $Gate.ConfirmedBy }
    if ($Kind -ne 'Undo') {
        # the print servers published in AD, over the pinned LDAPS connection of the start sequence (H1: only these are used)
        $Sync.Text = 'ad'
        if (-not $Account) { throw (T 'prn.err.password') }
        if ($FakeDir) { $ldap = $SharedLdap; $conn = 'c' }
        else {
            $ldap = New-AVDTuneLdapAdapter
            $r = Connect-AVDTuneDirectory -Ldap $ldap -Server $Dc -User $Account.Ldap -Password $Account.Password -Pins (Get-AVDTuneDcPins (Get-AVDTuneEnvironment $Root))
            if ($r.Status -ne 'Connected') { throw "No connection to the domain controller ($($r.Status)): $($r.Message)" }
            $conn = $r.Connection
        }
        try { $found = Find-AVDTunePrintServers -Ldap $ldap -Connection $conn } finally { if (-not $FakeDir) { Disconnect-AVDTuneDirectory -Ldap $ldap -Connection $conn } }
        $allowed = @($found.Servers | ForEach-Object { $_.Name })
    }
    switch ($Kind) {
        'Servers' { [pscustomobject]@{ Found = $found } }
        'Read' {
            Assert-AVDTunePrinterServerAllowed -Server $Server -Allowed $allowed
            $Sync.Text = 'read'
            $signers = @(Get-AVDTunePrinterSigners -Root $Root)
            $inv = Invoke-AVDTunePrinterSession -P $p -Server $Server -Credential $Account -Block { param($s) $i = Get-AVDTunePrinterInventory -P $p -Session $s -Server $Server; $Sync.Text = 'check'; Add-AVDTunePrinterSignatures -P $p -Session $s -Inventory $i -Root $Root -Signers $signers }
            $Sync.Auth = 'ok'   # the account worked (a kept account of the start sequence is forgotten only when it did not)
            Save-AVDTunePrinterLastRead -Root $Root -Inventory $inv   # for the Updates page and the readiness row; never a source of an install
            $Sync.Text = 'local'
            [pscustomobject]@{ Inventory = $inv; Check = @(Get-AVDTunePrinterDriverStatus -P $p -Drivers @(Get-AVDTunePrinterDriverPlan -Inventory $inv)); Warnings = @(Get-AVDTunePrinterPolicyWarnings -P $p) }
        }
        'Apply' {
            Assert-AVDTunePrinterServerAllowed -Server $Server -Allowed $allowed
            $Sync.Text = 'read'
            $inv = Invoke-AVDTunePrinterSession -P $p -Server $Server -Credential $Account -Block { param($s) Get-AVDTunePrinterInventory -P $p -Session $s -Server $Server }
            $diff = @(Compare-AVDTunePrinterPlan -Confirmed @($Plan) -Fresh @(Get-AVDTunePrinterDriverPlan -Inventory $inv -Selected @($Selected)))
            if ($diff.Count) { throw "The print server answers differently than in the confirmed plan; nothing was installed. Read the printers again. $($diff -join '; ')" }
            $Sync.Text = 'run'
            $r = Invoke-AVDTunePrinterRun -Machine $m -P $p -Root $Root -Mode Apply -Drivers @($Plan) -Credential $Account -Policy:$Policy -User $User -SnapshotId $Gate.SnapshotId
            [pscustomobject]@{ Run = $r.Run; Check = $r.Check }
        }
        'Maintain' {
            # Updates page: the same checks as Apply (fresh read against the confirmed plan, then the checked export with the confirmed signer per driver), in maintenance mode;
            # the drivers to remove are checked against this fresh read inside Invoke-AVDTunePrinterMaintenance
            Assert-AVDTunePrinterServerAllowed -Server $Server -Allowed $allowed
            $Sync.Text = 'read'
            $inv = Invoke-AVDTunePrinterSession -P $p -Server $Server -Credential $Account -Block { param($s) Get-AVDTunePrinterInventory -P $p -Session $s -Server $Server }
            $Sync.Auth = 'ok'
            $names = @(@($Plan) | ForEach-Object { [string]$_.Name })
            $diff = @(Compare-AVDTunePrinterPlan -Confirmed @($Plan) -Fresh @(Get-AVDTunePrinterDriverPlan -Inventory $inv | Where-Object { $_.Name -in $names }))
            if ($diff.Count) { throw "The print server answers differently than in the confirmed plan; nothing was installed. Read the print server again. $($diff -join '; ')" }
            $Sync.Text = 'run'
            $r = Invoke-AVDTunePrinterMaintenance -Machine $(if ($SharedMachine) { $SharedMachine } else { $m }) -P $p -Root $Root -Drivers @($Plan) -Remove @($Remove) -Inventory $inv -Credential $Account -User $User -SnapshotId $Gate.SnapshotId
            [pscustomobject]@{ Run = [pscustomobject]@{ Results = @($r.Results) }; Check = @($r.Check); Removed = @($r.Removed) }
        }
        'Undo' { $Sync.Text = 'run'; $r = Invoke-AVDTunePrinterRun -Machine $m -P $p -Root $Root -Mode Undo -User $User -SnapshotId $Gate.SnapshotId; [pscustomobject]@{ Run = $r.Run; Check = @() } }
    }
}
finally { $Account = $null }
'@

function New-PrnUpdAccount {
    # The account for a job started on the Updates page: the typed password, else the account of the start sequence kept for this session (#75; only for the pinned
    # domain controller). The SecureString is a copy that the job disposes; nothing is written anywhere.
    $user = [string](Get-AVDTuneProp (Get-PrnDc) 'User'); $fromSession = $false
    $secure = $ui.PwdUpdPrn.SecurePassword
    $ui.PwdUpdPrn.Clear()
    if ($secure.Length -eq 0) {
        $secure.Dispose()
        $kept = $null; try { $kept = Get-AVDTuneSessionDcAccount -Pins (Get-AVDTuneDcPins (Get-AVDTuneEnvironment $script:StateRoot)) } catch { }
        if ($kept) { $user = [string]$kept.User; $secure = $kept.Password; $fromSession = $true }
        elseif ($script:TestMode) { $secure = New-Object System.Security.SecureString }
        else { throw (T 'prn.upd.err.password') }
    }
    try { $upn = ConvertTo-AVDTunePrinterUpn -User $user -DnsDomain (Get-PrnDnsDomain) } catch { $secure.Dispose(); throw }
    [pscustomobject]@{ User = $upn; Ldap = $user; Password = $secure; FromSession = $fromSession }
}

function Start-PrnJob([string]$Kind, [object[]]$Plan = @(), [string[]]$Remove = @(), [switch]$Updates) {
    if ($script:PrnJob) { throw (T 'prn.err.busy') }
    $writes = $Kind -notin $script:PrnReadKinds
    if ($writes) {
        if (-not (Test-AVDTuneWriteAllowed)) { throw (T 'shell.readonly') }
        Assert-NoOtherWriter
    }
    if ($Kind -eq 'Maintain' -and -not $script:PrnInventory) { throw (T 'prn.upd.err.unread') }
    $server = if ($Kind -in 'Apply', 'Maintain' -and $script:PrnInventory) { [string]$script:PrnInventory.Server } elseif ($Updates) { [string]$ui.CmbUpdPrnServer.SelectedItem } else { ([string]$ui.CmbPrnServer.Text).Trim() }   # Apply and Maintain work on the server that was read (the plan belongs to it)
    if ($Kind -in 'Read', 'Apply', 'Maintain' -and -not (Test-AVDTunePrinterServerName $server)) { throw (T 'prn.err.server') }
    $account = $null
    if ($Updates) { $account = New-PrnUpdAccount }
    elseif ($Kind -ne 'Undo') {
        $user = ([string]$ui.TxtPrnUser.Text).Trim()
        $upn = ConvertTo-AVDTunePrinterUpn -User $user -DnsDomain (Get-PrnDnsDomain)   # throws before the password is taken
        $secure = $ui.PwdPrn.SecurePassword   # a copy: disposed when the job has ended
        $ui.PwdPrn.Clear()
        if ($secure.Length -eq 0 -and -not $script:TestMode) { $secure.Dispose(); throw (T 'prn.err.password') }
        $account = [pscustomobject]@{ User = $upn; Ldap = $user; Password = $secure; FromSession = $false }
    }
    $selected = @(if (-not $Updates) { Get-PrnSelected })
    $sync = [hashtable]::Synchronized(@{ Text = '' })
    $ps = New-AVDTunePowerShell
    [void]$ps.AddScript($script:PrnWorkerText).AddArgument($script:AppRoot).AddArgument($script:SwFakeDir).AddArgument($script:StateRoot).AddArgument($Kind).AddArgument($server).AddArgument(@($Plan)).AddArgument($selected).AddArgument([bool](-not $Updates -and $ui.ChkPrnPolicy.IsChecked)).AddArgument((Get-AVDTuneWriteGate)).AddArgument($sync).AddArgument((Get-SwUser)).AddArgument($account).AddArgument([string](Get-AVDTuneProp (Get-PrnDc) 'Server')).AddArgument($(if ($script:TestMode) { $script:PrnFake } else { $null })).AddArgument($(if ($script:TestMode) { $script:Services.Ldap } else { $null })).AddArgument(@($Remove)).AddArgument($(if ($script:TestMode) { $script:Machine } else { $null }))
    $task = Start-AVDTuneUiTask -Kind "printers-$($Kind.ToLower())" -Title (T "prn.task.$($Kind.ToLower())") -Step (T 'prn.task.start')
    $script:PrnJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Kind = $Kind; Sync = $sync; Task = $task; Account = $account; FromSession = [bool]($account -and $account.FromSession) }
    if ($writes) { Set-ShutdownBlock $true }
    Set-PrnBusy $true
}

function Set-PrnBusy([bool]$Busy) {
    if ($script:PrnUiBuilt) { foreach ($b in $ui.BtnPrnFind, $ui.BtnPrnRead, $ui.BtnPrnApply, $ui.BtnPrnUndo, $ui.PanelPrnPrinters) { $b.IsEnabled = -not $Busy } }
    if ($script:PrnUpdBuilt) { foreach ($b in $ui.BtnUpdPrnRead, $ui.BtnUpdPrnUpdate, $ui.BtnUpdPrnRemove, $ui.PanelUpdPrnRows) { $b.IsEnabled = -not $Busy } }
}

function Complete-PrnJob {
    $job = $script:PrnJob
    if (-not $job) { return }
    if (-not $job.Handle.IsCompleted) { $t = [string]$job.Sync.Text; if ($t) { Update-AVDTuneUiTask $job.Task -Step (T "prn.step.$t") }; return }
    $script:PrnJob = $null
    if ($job.Kind -notin $script:PrnReadKinds) { Set-ShutdownBlock $false }
    $result = $null; $err = ''
    try {
        $out = @($job.PS.EndInvoke($job.Handle))
        if ($job.PS.Streams.Error.Count -gt 0) { $err = $job.PS.Streams.Error[0].Exception.Message }
        $result = $out | Select-Object -Last 1
    }
    catch { $err = $_.Exception.Message }
    finally { $job.PS.Dispose(); if ($job.Account) { $job.Account.Password.Dispose() } }
    # the kept account of the start sequence did not get as far as a read of the server: it is forgotten, the next job asks for the password (#75, as on the App Masking page)
    if ($err -and $job.FromSession -and [string]$job.Sync.Auth -ne 'ok') { Clear-AVDTuneSessionDcAccount }
    Set-PrnBusy $false
    $failed = [bool]$err; $summary = ''
    switch ($job.Kind) {
        'Servers' {
            if ($err) { $summary = T 'prn.read.failed' $err }
            else {
                $names = @($result.Found.Servers | ForEach-Object { $_.Name })
                $ui.CmbPrnServer.ItemsSource = $names; if ($names.Count -and -not $ui.CmbPrnServer.Text) { $ui.CmbPrnServer.SelectedIndex = 0 }
                $summary = T 'prn.servers.done' $names.Count
                if (@($result.Found.Skipped).Count) { $summary += ' ' + (T 'prn.servers.skipped' (@($result.Found.Skipped) -join ', ')) }
            }
        }
        'Read' {
            if ($err) { $summary = T 'prn.read.failed' $err }
            else { $script:PrnInventory = $result.Inventory; $script:PrnCheck = @($result.Check); $script:PrnWarnings = @($result.Warnings); $summary = T 'prn.read.done' @($script:PrnInventory.Printers).Count $script:PrnInventory.Server }
        }
        default {
            $run = if ($result) { $result.Run } else { $null }
            if ($run) { foreach ($r in $run.Results) { Register-StepResult $r } }
            $check = @(if ($result) { $result.Check } else { $script:PrnCheck })
            if ($result -and $job.Kind -eq 'Maintain') {
                # only the drivers of this run were checked: the others keep their row, removed ones lose it
                $touched = @($check | ForEach-Object { $_.Name }) + @($result.Removed)
                $script:PrnCheck = @(@($script:PrnCheck | Where-Object { $_.Name -notin $touched }) + $check)
            }
            elseif ($result) { $script:PrnCheck = $check }
            $ch = if ($run) { @($run.Results | Where-Object { $_.Status -eq 'Changed' }).Count } else { 0 }
            $bad = if ($run) { @($run.Results | Where-Object { $_.Status -eq 'Failed' }) } else { @() }
            $wrong = @($check | Where-Object { -not $_.Ok })
            if ($bad.Count -gt 0 -or $wrong.Count -gt 0) { $failed = $true }
            $summary = T 'prn.run.done' $ch $bad.Count
            if ($bad.Count -gt 0) { $summary += ' ' + $bad[0].Title + ': ' + $bad[0].Message }
            if ($wrong.Count -gt 0) { $summary += ' ' + (T 'prn.check.wrong' (@($wrong | ForEach-Object { "$($_.Name) ($($_.Installed) / $($_.Version))" }) -join ', ')) }
            foreach ($w in @($check | Where-Object { $_.Warning })) { $summary += " $($w.Name): $($w.Warning)" }
            if ($err) { $summary += " $err" }
            Show-Toast $summary
            [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'printers' -Subject $summary)
            Save-Protocol
            Start-OverviewRefresh
        }
    }
    Complete-AVDTuneUiTask $job.Task -Failed:$failed -Summary $summary
    if ($script:PrnUiBuilt) { $ui.TxtPrnState.Text = $summary; Update-PrnView }
    if ($script:PrnUpdBuilt) { $ui.TxtUpdPrnState.Text = $summary; Update-PrnUpdCard }
}
$script:Timer.Add_Tick({ try { Complete-PrnJob } catch { Show-Error $_.Exception.Message } })

# ---------------------------------------------------------------- the page
function Build-PrnPage {
    if ($script:PrnUiBuilt) { return }
    $parent = $ui.PagePlaceholder.Parent
    $page = New-Object System.Windows.Controls.Grid; $page.Visibility = 'Collapsed'
    $sv = New-Object System.Windows.Controls.ScrollViewer; $sv.SetResourceReference([System.Windows.Controls.ScrollViewer]::StyleProperty, 'PageScroll')
    $root = New-Object System.Windows.Controls.StackPanel; $root.Margin = '40,32,40,28'; $root.MaxWidth = 1000; $root.HorizontalAlignment = 'Left'
    [void]$root.Children.Add((New-MaskText (T 'nav.printers') 'PageTitle'))
    [void]$root.Children.Add((New-MaskText (T 'prn.subtitle') 'Subtitle'))
    $ui.TxtPrnEntra = New-MaskText (T 'prn.entra') '' '0,12,0,0'; [void]$root.Children.Add($ui.TxtPrnEntra)
    $ui.PanelPrnMain = New-Object System.Windows.Controls.StackPanel; [void]$root.Children.Add($ui.PanelPrnMain)
    $c1 = New-MaskCard (T 'prn.card.server') (T 'prn.card.server.hint')
    $ui.CmbPrnServer = New-Object System.Windows.Controls.ComboBox; $ui.CmbPrnServer.Padding = '8,6'; $ui.CmbPrnServer.IsEditable = $true
    [System.Windows.Automation.AutomationProperties]::SetName($ui.CmbPrnServer, (T 'prn.field.server'))
    [void]$c1.Panel.Children.Add((New-MaskLabeled (T 'prn.field.server') $ui.CmbPrnServer))
    $ui.TxtPrnUser = New-Object System.Windows.Controls.TextBox; $ui.TxtPrnUser.Padding = '8,6'; [System.Windows.Automation.AutomationProperties]::SetName($ui.TxtPrnUser, (T 'prn.field.user'))
    [void]$c1.Panel.Children.Add((New-MaskLabeled (T 'prn.field.user') $ui.TxtPrnUser))
    $ui.PwdPrn = New-Object System.Windows.Controls.PasswordBox; $ui.PwdPrn.Padding = '8,6'; $ui.PwdPrn.MaxLength = 256; [System.Windows.Automation.AutomationProperties]::SetName($ui.PwdPrn, (T 'prn.field.password'))
    [void]$c1.Panel.Children.Add((New-MaskLabeled (T 'prn.field.password') $ui.PwdPrn))
    $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.Margin = '0,10,0,0'
    $ui.BtnPrnFind = New-MaskButton (T 'prn.btn.find') (T 'prn.btn.find.tip')
    $ui.BtnPrnRead = New-MaskButton (T 'prn.btn.read') (T 'prn.btn.read.tip') $true
    foreach ($b in $ui.BtnPrnFind, $ui.BtnPrnRead) { [void]$row.Children.Add($b) }
    [void]$c1.Panel.Children.Add($row)
    [void]$ui.PanelPrnMain.Children.Add($c1.Card)
    $c2 = New-MaskCard (T 'prn.card.printers') (T 'prn.card.printers.hint')
    $ui.PanelPrnPrinters = New-Object System.Windows.Controls.StackPanel; $ui.PanelPrnPrinters.Margin = '0,8,0,0'; [void]$c2.Panel.Children.Add($ui.PanelPrnPrinters)
    [void]$ui.PanelPrnMain.Children.Add($c2.Card)
    $c3 = New-MaskCard (T 'prn.card.drivers') (T 'prn.card.drivers.hint')
    $ui.PanelPrnDrivers = New-Object System.Windows.Controls.StackPanel; $ui.PanelPrnDrivers.Margin = '0,8,0,0'; [void]$c3.Panel.Children.Add($ui.PanelPrnDrivers)
    $ui.TxtPrnWarnings = New-MaskText '' '' '0,8,0,0'; Set-Brush $ui.TxtPrnWarnings ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'Warning'; [void]$c3.Panel.Children.Add($ui.TxtPrnWarnings)
    $ui.ChkPrnPolicy = New-Object System.Windows.Controls.CheckBox; $ui.ChkPrnPolicy.Content = T 'prn.policy'; $ui.ChkPrnPolicy.IsChecked = $true; $ui.ChkPrnPolicy.Margin = '0,10,0,0'
    [void]$c3.Panel.Children.Add($ui.ChkPrnPolicy)
    $row2 = New-Object System.Windows.Controls.StackPanel; $row2.Orientation = 'Horizontal'; $row2.Margin = '0,10,0,0'
    $ui.BtnPrnApply = New-MaskButton (T 'prn.btn.apply') (T 'prn.btn.apply.tip') $true
    $ui.BtnPrnUndo = New-MaskButton (T 'prn.btn.undo') (T 'prn.btn.undo.tip')
    foreach ($b in $ui.BtnPrnApply, $ui.BtnPrnUndo) { [void]$row2.Children.Add($b) }
    [void]$c3.Panel.Children.Add($row2)
    [void]$ui.PanelPrnMain.Children.Add($c3.Card)
    $ui.TxtPrnState = New-MaskText '' 'Hint' '0,8,0,0'; [void]$ui.PanelPrnMain.Children.Add($ui.TxtPrnState)
    $sv.Content = $root; [void]$page.Children.Add($sv)
    $ui.PagePrinters = $page; [void]$parent.Children.Add($page)
    Add-Click $ui.BtnPrnFind { Start-PrnJob 'Servers' }
    Add-Click $ui.BtnPrnRead { Start-PrnJob 'Read' }
    Add-Click $ui.BtnPrnApply { Invoke-PrnApply }
    Add-Click $ui.BtnPrnUndo { if (Confirm-Action (T 'prn.ask.undo') (T 'nav.printers')) { Start-PrnJob 'Undo' } }
    $ui.TxtPrnUser.Text = [string](Get-AVDTuneProp (Get-PrnDc) 'User')
    $saved = Get-AVDTunePrinterState -Root $script:StateRoot
    if (@($saved.Servers).Count) { $ui.CmbPrnServer.Text = [string]@($saved.Servers)[0] }
    $script:PrnUiBuilt = $true
}

function Get-PrnSelected { if (-not $script:PrnUiBuilt) { return @() }; @($ui.PanelPrnPrinters.Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] -and $_.IsChecked -and $_.IsEnabled } | ForEach-Object { [string]$_.Tag }) }

function Get-PrnPlan { if (-not $script:PrnInventory) { return @() }; $sel = @(Get-PrnSelected); if ($sel.Count -eq 0) { return @() }; @(Get-AVDTunePrinterDriverPlan -Inventory $script:PrnInventory -Selected $sel) }

function Get-PrnSignerName([string]$Subject) { $cn = Get-AVDTunePrinterDnPart $Subject 'CN'; if ($cn) { $cn } else { $Subject } }

function Invoke-PrnApply {
    $plan = @(Get-PrnPlan)
    if ($plan.Count -eq 0) { Show-Toast (T 'prn.none'); return }
    $plan = @(Confirm-PrnSigners $plan)
    if ($plan.Count -eq 0) { Show-Toast (T 'prn.none'); return }
    $list = (@($plan[0..([Math]::Min(12, $plan.Count) - 1)] | ForEach-Object { "- $($_.Name) $($_.Version), $(T 'prn.signed' (Get-PrnSignerName $_.Signer))" }) -join "`n") + $(if ($plan.Count -gt 12) { "`n..." } else { '' })
    $ask = (T 'prn.ask.apply' $plan.Count $script:PrnInventory.Server $list) + $(if ($ui.ChkPrnPolicy.IsChecked) { "`n`n" + (T 'prn.ask.policy') } else { '' })
    if (-not (Confirm-Action $ask (T 'nav.printers'))) { return }
    Start-PrnJob 'Apply' $plan
}

function Confirm-PrnSigners([object[]]$Plan) {
    # a publisher that is not WHQL and not allowed yet: the administrator allows it (saved in config, protocol) or its drivers stay out of the plan. Returns the allowed part.
    $plan = @($Plan)
    foreach ($g in @($plan | Where-Object { -not $_.Allowed } | Group-Object Thumbprint)) {
        $f = $g.Group[0]
        if (Confirm-Action (T 'prn.ask.signer' (Get-PrnSignerName $f.Signer) $f.Thumbprint (@($g.Group | ForEach-Object { $_.Name }) -join ', ')) (T 'nav.printers')) {
            Add-AVDTunePrinterSigner -Root $script:StateRoot -Thumbprint $f.Thumbprint -Subject $f.Signer -User (Get-SwUser)
            [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'printers' -Subject (T 'prn.signer.added' (Get-PrnSignerName $f.Signer) $f.Thumbprint)); Save-Protocol
            foreach ($d in $g.Group) { $d.Allowed = $true }
        }
    }
    @($plan | Where-Object { $_.Allowed })
}

function Update-PrnDrivers {
    $ui.PanelPrnDrivers.Children.Clear()
    $ui.TxtPrnWarnings.Text = (@($script:PrnWarnings | ForEach-Object { T 'prn.warn.policy' $_ }) -join "`r`n")
    $plan = @(Get-PrnPlan)
    if ($plan.Count -eq 0) { [void]$ui.PanelPrnDrivers.Children.Add((New-MaskText (T 'prn.drivers.empty') 'Hint')); return }
    $cmp = @(Compare-AVDTunePrinterDrivers -Installed (Get-AVDTunePrinterState -Root $script:StateRoot).Drivers -Server $plan)
    foreach ($d in $plan) {
        $chk = @($script:PrnCheck | Where-Object { $_.Name -eq $d.Name })[0]
        $c = @($cmp | Where-Object { $_.Name -eq $d.Name })[0]
        $inst = if ($chk -and $chk.Installed) { T 'prn.drv.installed' $chk.Installed } else { T 'prn.drv.missing' }
        $sig = if ($d.Whql) { T 'prn.sig.whql' } elseif ($d.Allowed) { T 'prn.sig.allowed' (Get-PrnSignerName $d.Signer) } else { T 'prn.sig.ask' (Get-PrnSignerName $d.Signer) }
        $line = T 'prn.drv.line' $d.Name $d.Version $d.Architecture $(if ($d.PackageAware) { T 'prn.pa.yes' } else { T 'prn.pa.no' }) (@($d.Printers) -join ', ')
        [void]$ui.PanelPrnDrivers.Children.Add((New-MaskText "$line $sig $inst$(if ($c) { ' ' + (T "prn.maint.$($c.Status.ToLower())") })" '' '0,2,0,2'))
    }
}

function Update-PrnView {
    if (-not $script:PrnUiBuilt) { return }
    $av = Get-PrnAvailability
    $ui.TxtPrnEntra.Visibility = ConvertTo-Vis (-not $av.Domain)
    $ui.PanelPrnMain.Visibility = ConvertTo-Vis $av.Domain
    $ui.PanelPrnPrinters.Children.Clear()
    $inv = $script:PrnInventory
    if (-not $inv) { [void]$ui.PanelPrnPrinters.Children.Add((New-MaskText (T 'prn.notread') 'Hint')) }
    else {
        foreach ($pr in @($inv.Printers)) {
            $cb = New-Object System.Windows.Controls.CheckBox; $cb.Tag = [string]$pr.Name; $cb.Margin = '0,3,0,3'
            $cb.Content = if ($pr.Problem) { "$($pr.Name) ($($pr.ShareName)): $($pr.Problem)" } else { "$($pr.Name) ($($pr.ShareName)) - $($pr.Driver) $($pr.Version)" }
            $cb.IsChecked = -not $pr.Problem; $cb.IsEnabled = -not $pr.Problem -and -not $script:PrnJob
            $cb.Add_Click({ try { Update-PrnDrivers } catch { Show-Error $_.Exception.Message } })
            [void]$ui.PanelPrnPrinters.Children.Add($cb)
        }
    }
    Update-PrnDrivers
}

function Update-PrnPage {
    Build-PrnPage
    try { if (Repair-AVDTunePrinterTrustedHosts -P (Get-PrnAdapter) -Root $script:StateRoot) { Show-Toast (T 'prn.repaired') } } catch { Show-Error $_.Exception.Message }
    Update-PrnView
}

# ---------------------------------------------------------------- maintenance on the Updates page (plan 3b)
$script:PrnUpdBuilt = $false
$script:PrnUpdChecked = @{}   # 'status|driver' -> checked, kept while the rows are built again

function Get-PrnUpdRows {
    # the drivers of the read in this session against what AVDTune installed from that server: New, Changed, Same, Gone (Removable only for drivers AVDTune added)
    if (-not $script:PrnInventory) { return @() }
    $inv = $script:PrnInventory
    @(Get-AVDTunePrinterMaintenance -Installed (Get-AVDTunePrinterState -Root $script:StateRoot).Drivers -Server @(Get-AVDTunePrinterDriverPlan -Inventory $inv) -ReadServer ([string]$inv.Server) -InUse @(Get-AVDTunePrinterInUse -Inventory $inv) -Added @(Get-AVDTunePrinterAdded -Root $script:StateRoot))
}

function Get-PrnUpdateNotes {
    # The line of the Updates page: the drivers of the last read of the print server against what AVDTune installed
    $saved = Get-AVDTunePrinterState -Root $script:StateRoot
    if (-not $script:PrnInventory) { if (@($saved.Drivers).Count) { return , (T 'prn.upd.unread' @($saved.Drivers).Count (@($saved.Servers) -join ', ')) }; return @() }
    $rows = @(Get-PrnUpdRows)
    $todo = @($rows | Where-Object { $_.Status -in 'New', 'Changed' }); $gone = @($rows | Where-Object { $_.Status -eq 'Gone' })
    if ($todo.Count -eq 0 -and $gone.Count -eq 0) { return , (T 'prn.upd.same' $script:PrnInventory.Server) }
    $out = @()
    if ($todo.Count) { $out += T 'prn.upd.todo' $todo.Count $script:PrnInventory.Server (@($todo | ForEach-Object { "$($_.Name) $(if ($_.Installed) { $_.Installed } else { '-' }) -> $($_.ServerVersion)" }) -join '; ') }
    if ($gone.Count) { $out += T 'prn.upd.gone' $gone.Count $script:PrnInventory.Server (@($gone | ForEach-Object { $_.Name }) -join '; ') }
    @($out)
}

function Build-PrnUpdCard {
    if ($script:PrnUpdBuilt) { return }
    $c = New-MaskCard (T 'prn.upd.card') (T 'prn.upd.card.hint')
    $ui.CmbUpdPrnServer = New-Object System.Windows.Controls.ComboBox; $ui.CmbUpdPrnServer.Padding = '8,6'   # not editable: only servers AVDTune installed from (the job still asks AD)
    [System.Windows.Automation.AutomationProperties]::SetName($ui.CmbUpdPrnServer, (T 'prn.field.server'))
    [void]$c.Panel.Children.Add((New-MaskLabeled (T 'prn.field.server') $ui.CmbUpdPrnServer))
    $ui.PwdUpdPrn = New-Object System.Windows.Controls.PasswordBox; $ui.PwdUpdPrn.Padding = '8,6'; $ui.PwdUpdPrn.MaxLength = 256
    [System.Windows.Automation.AutomationProperties]::SetName($ui.PwdUpdPrn, (T 'prn.upd.field.password'))
    [void]$c.Panel.Children.Add((New-MaskLabeled (T 'prn.upd.field.password') $ui.PwdUpdPrn))
    $ui.TxtUpdPrnAccount = New-MaskText '' 'Hint' '0,2,0,0'; [void]$c.Panel.Children.Add($ui.TxtUpdPrnAccount)
    $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.Margin = '0,10,0,0'
    $ui.BtnUpdPrnRead = New-MaskButton (T 'prn.upd.btn.read') (T 'prn.upd.btn.read.tip')
    [void]$row.Children.Add($ui.BtnUpdPrnRead); [void]$c.Panel.Children.Add($row)
    $ui.PanelUpdPrnRows = New-Object System.Windows.Controls.StackPanel; $ui.PanelUpdPrnRows.Margin = '0,10,0,0'; [void]$c.Panel.Children.Add($ui.PanelUpdPrnRows)
    $row2 = New-Object System.Windows.Controls.StackPanel; $row2.Orientation = 'Horizontal'; $row2.Margin = '0,10,0,0'
    $ui.BtnUpdPrnUpdate = Set-AVDTuneWriterButton (New-MaskButton (T 'prn.upd.btn.update') (T 'prn.upd.btn.update.tip') $true)
    $ui.BtnUpdPrnRemove = Set-AVDTuneWriterButton (New-MaskButton (T 'prn.upd.btn.remove') (T 'prn.upd.btn.remove.tip'))
    foreach ($b in $ui.BtnUpdPrnUpdate, $ui.BtnUpdPrnRemove) { [void]$row2.Children.Add($b) }
    [void]$c.Panel.Children.Add($row2)
    $ui.TxtUpdPrnState = New-MaskText '' 'Hint' '0,8,0,0'; [void]$c.Panel.Children.Add($ui.TxtUpdPrnState)
    $ui.CardUpdPrn = $c.Card
    # below the card "Available" of the Updates page (its notes line names the printer drivers too)
    $available = $ui.TxtUpdNotes.Parent.Parent; $pagePanel = $available.Parent
    $pagePanel.Children.Insert($pagePanel.Children.IndexOf($available) + 1, $c.Card)
    Add-Click $ui.BtnUpdPrnRead { Start-PrnJob 'Read' -Updates }
    Add-Click $ui.BtnUpdPrnUpdate { Invoke-PrnUpdUpdate }
    Add-Click $ui.BtnUpdPrnRemove { Invoke-PrnUpdRemove }
    $script:PrnUpdBuilt = $true
}

function Get-PrnUpdChecked([string]$Status) {
    if (-not $script:PrnUpdBuilt) { return @() }
    @($ui.PanelUpdPrnRows.Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] -and $_.IsChecked -and $_.IsEnabled -and ([string]$_.Tag).StartsWith("$Status|") } | ForEach-Object { ([string]$_.Tag).Substring($Status.Length + 1) })
}

function Update-PrnUpdCard {
    # shown when the environment has a domain and AVDTune installed printer drivers from a server; called by Update-UpdatesView and after every printer job
    Build-PrnUpdCard
    $saved = Get-AVDTunePrinterState -Root $script:StateRoot
    $show = (Get-PrnAvailability).Domain -and @($saved.Servers).Count -gt 0
    $ui.CardUpdPrn.Visibility = ConvertTo-Vis $show
    if (-not $show) { return }
    $names = @($saved.Servers)
    if ((@($ui.CmbUpdPrnServer.ItemsSource) -join '|') -ne ($names -join '|')) { $ui.CmbUpdPrnServer.ItemsSource = $names }
    if ($ui.CmbUpdPrnServer.SelectedIndex -lt 0) { $ui.CmbUpdPrnServer.SelectedIndex = $(if ($script:PrnInventory -and [string]$script:PrnInventory.Server -in $names) { [Array]::IndexOf($names, [string]$script:PrnInventory.Server) } else { 0 }) }
    $kept = $null; try { $kept = Get-AVDTuneSessionDcAccount -Pins (Get-AVDTuneDcPins (Get-AVDTuneEnvironment $script:StateRoot)) -Info } catch { }
    $ui.TxtUpdPrnAccount.Text = if ($kept) { T 'prn.upd.account.kept' $kept.User } else { T 'prn.upd.account.ask' ([string](Get-AVDTuneProp (Get-PrnDc) 'User')) }
    $ui.PanelUpdPrnRows.Children.Clear()
    $rows = @(Get-PrnUpdRows)
    if (-not $script:PrnInventory) {
        $last = @(Get-AVDTunePrinterLastRead -Root $script:StateRoot | Where-Object { $_.Server -in $names } | Sort-Object At | Select-Object -Last 1)
        [void]$ui.PanelUpdPrnRows.Children.Add((New-MaskText $(if ($last.Count) { T 'prn.upd.lastread' $last[0].Server ([datetime]::Parse($last[0].At, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).ToString('yyyy-MM-dd HH:mm') } else { T 'prn.upd.neverread' }) 'Hint'))
    }
    else {
        foreach ($r in @($rows | Where-Object { $_.Status -ne 'Same' })) {
            $key = "$($r.Status)|$($r.Name)"
            $cb = New-Object System.Windows.Controls.CheckBox; $cb.Tag = $key; $cb.Margin = '0,3,0,3'
            $cb.Content = switch ($r.Status) {
                'New' { T 'prn.upd.row.new' $r.Name $r.ServerVersion }
                'Changed' { T 'prn.upd.row.changed' $r.Name $r.Installed $r.ServerVersion }
                default { if ($r.Removable) { T 'prn.upd.row.gone' $r.Name $r.Installed } else { T 'prn.upd.row.gone.kept' $r.Name $r.Installed } }
            }
            $cb.IsEnabled = ($r.Status -ne 'Gone' -or $r.Removable) -and -not $script:PrnJob
            # default: a changed driver is selected; a new one (maybe of a printer left out on purpose) and a removal are chosen by the administrator
            $cb.IsChecked = [bool]($cb.IsEnabled -and $(if ($script:PrnUpdChecked.ContainsKey($key)) { $script:PrnUpdChecked[$key] } else { $r.Status -eq 'Changed' }))
            $cb.Add_Click({ param($s) $script:PrnUpdChecked[[string]$s.Tag] = [bool]$s.IsChecked })
            [void]$ui.PanelUpdPrnRows.Children.Add($cb)
        }
        $same = @($rows | Where-Object { $_.Status -eq 'Same' }).Count
        [void]$ui.PanelUpdPrnRows.Children.Add((New-MaskText (T 'prn.upd.rows.same' $same $script:PrnInventory.Server) 'Hint' '0,4,0,0'))
    }
    $ui.BtnUpdPrnUpdate.Visibility = ConvertTo-Vis (@($rows | Where-Object { $_.Status -in 'New', 'Changed' }).Count -gt 0)
    $ui.BtnUpdPrnRemove.Visibility = ConvertTo-Vis (@($rows | Where-Object { $_.Status -eq 'Gone' -and $_.Removable }).Count -gt 0)
}

function Invoke-PrnUpdUpdate {
    # new and changed drivers like a software update: the plan of the read with its signers is confirmed, the job reads the server again and installs only what still matches
    if (-not (Test-AVDTuneWriteAllowed)) { throw (T 'shell.readonly') }
    Assert-NoOtherWriter
    $names = @(Get-PrnUpdChecked 'New') + @(Get-PrnUpdChecked 'Changed')
    $plan = @(if ($script:PrnInventory -and $names.Count) { Get-AVDTunePrinterDriverPlan -Inventory $script:PrnInventory | Where-Object { $_.Name -in $names } })
    if ($plan.Count -eq 0) { Show-Toast (T 'prn.upd.none'); return }
    $plan = @(Confirm-PrnSigners $plan)
    if ($plan.Count -eq 0) { Show-Toast (T 'prn.upd.none'); return }
    $list = (@($plan[0..([Math]::Min(12, $plan.Count) - 1)] | ForEach-Object { "- $($_.Name) $($_.Version), $(T 'prn.signed' (Get-PrnSignerName $_.Signer))" }) -join "`n") + $(if ($plan.Count -gt 12) { "`n..." } else { '' })
    if (-not (Confirm-Action (T 'prn.upd.ask.update' $plan.Count $script:PrnInventory.Server $list) (T 'prn.upd.card'))) { return }
    Start-PrnJob 'Maintain' $plan -Updates
}

function Invoke-PrnUpdRemove {
    # drivers no printer of the server uses any more: only after this confirmation, and the job checks each one against a fresh read and the files of AVDTune
    if (-not (Test-AVDTuneWriteAllowed)) { throw (T 'shell.readonly') }
    Assert-NoOtherWriter
    $names = @(Get-PrnUpdChecked 'Gone')
    if ($names.Count -eq 0) { Show-Toast (T 'prn.upd.none'); return }
    if (-not (Confirm-Action (T 'prn.upd.ask.remove' $names.Count $script:PrnInventory.Server ((@($names | ForEach-Object { "- $_" })) -join "`n")) (T 'prn.upd.card'))) { return }
    Start-PrnJob 'Maintain' @() -Remove $names -Updates
}

function Get-PrnFinishNote {
    # Finish page: installed printer drivers older than those of the print server at its last read (nothing is asked from the server here)
    $lag = Get-AVDTunePrinterDriverLag -Root $script:StateRoot
    if ($lag -and @($lag.Older).Count) { T 'prn.finish.older' @($lag.Older).Count (@($lag.Servers) -join ', ') $lag.At.ToString('yyyy-MM-dd HH:mm') } else { '' }
}
