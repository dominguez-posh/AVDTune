# The Environment page (dot-sourced by Start-AVDTune.ps1; plan section 1b, docs\environment-wizard.md). Logic is in Modules\AVDTune.Environment.psm1; this file loads the page
# from UI\AVDTune.Environment.xaml, builds the form from the first-run answers and shows the plan. Reading (the plan) and every change (create, undo) run in a background
# runspace behind a task in the bar at the bottom (#44, EnvJob): the window stays responsive while Azure works (an asynchronous operation takes seconds to a few minutes).
# Every change shows the plan first and asks for the confirmation of exactly that plan; the module refuses a different plan.
# Test mode: the fake ARM (Tests\Fakes\FakeEnvArm.ps1) and no token of a real sign-in; nothing leaves this computer.

$script:EnvFake = $null
if ($script:TestMode) { . (Get-TestScript 'FakeEnvArm.ps1'); $script:EnvFake = New-AVDTuneFakeEnvArm }
$script:EnvFields = @{}
$script:EnvPlan = $null
$script:EnvUndoPlan = $null

[xml]$envXaml = Get-Content (Join-Path $PSScriptRoot 'UI\AVDTune.Environment.xaml') -Raw -Encoding UTF8
$envPage = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($envXaml))
foreach ($node in $envXaml.SelectNodes("//*[@*[local-name()='Name']]")) {
    $name = $node.Attributes | Where-Object LocalName -eq 'Name' | Select-Object -ExpandProperty Value
    $ui[$name] = $envPage.FindName($name)
}
$ui.PageEnvironment = $envPage
[void]$ui.PagePlaceholder.Parent.Children.Add($envPage)

function Get-EnvToken { if ($script:TestMode) { return @{ Token = 'fake-arm-token'; Reason = '' } }; Get-ReadyToken }
function Get-EnvAnswers { $e = $null; try { $e = Get-AVDTuneEnvironment $script:StateRoot } catch { }; if ($e) { Get-AVDTuneEnvironmentAnswers $e } else { $null } }
function Get-EnvUser { [string]$env:USERNAME }
function Get-EnvGateSnapshot { $g = Get-AVDTuneWriteGate; if ($g) { [string]$g.SnapshotId } else { '' } }

$script:EnvFieldList = @(
    @{ Key = 'SubscriptionId'; Label = 'Subscription ID'; Hint = 'of the storage account (taken from this VM when it runs in Azure)' }
    @{ Key = 'ResourceGroup'; Label = 'Resource group'; Hint = 'of the storage account and the private endpoint' }
    @{ Key = 'Location'; Label = 'Region'; Hint = 'for example westeurope' }
    @{ Key = 'AccountName'; Label = 'Storage account name'; Hint = '3 to 24 lower case letters and digits; unique in all of Azure' }
    @{ Key = 'Sku'; Label = 'Redundancy'; Hint = 'Premium_LRS (one zone) or Premium_ZRS (three zones)'; Default = 'Premium_LRS' }
    @{ Key = 'ShareName'; Label = 'Share name'; Hint = 'lower case letters, digits, hyphens'; Default = 'profiles' }
    @{ Key = 'Users'; Label = 'Number of users'; Hint = 'with GiB per user this sets the size of the share'; Default = '100' }
    @{ Key = 'GiBPerUser'; Label = 'GiB per user'; Hint = 'profile size Premium minimum is 100 GiB in total'; Default = '30' }
    @{ Key = 'SubnetId'; Label = 'Subnet (resource ID)'; Hint = 'of the session hosts; the private endpoint goes here (only with a private endpoint)' }
    @{ Key = 'PrivateEndpointName'; Label = 'Private endpoint name'; Hint = 'only with a private endpoint' }
    @{ Key = 'DnsZoneResourceGroup'; Label = 'Resource group of the DNS zone'; Hint = 'empty = the resource group above' }
    @{ Key = 'AllowedIps'; Label = 'Allowed IP ranges'; Hint = 'only with a public endpoint, separated by commas' }
    @{ Key = 'UsersGroupId'; Label = 'User group (object ID)'; Hint = 'gets Storage File Data SMB Share Contributor on the share; empty = you assign it' }
    @{ Key = 'AdminsGroupId'; Label = 'Admin group (object ID)'; Hint = 'gets Elevated Contributor; empty = you assign it' }
    @{ Key = 'UsersGroupName'; Label = 'User group (name, for display)'; Hint = 'optional: shown in the plan next to the object ID (AVDTune does not look names up)' }
    @{ Key = 'AdminsGroupName'; Label = 'Admin group (name, for display)'; Hint = 'optional, shown in the plan' }
    @{ Key = 'DomainName'; Label = 'Domain name (hybrid identities)'; Hint = 'optional, Entra Kerberos with synchronized users; goes with the GUID' }
    @{ Key = 'DomainGuid'; Label = 'Domain GUID (hybrid identities)'; Hint = 'optional' }
)

function Initialize-EnvFields {
    if ($script:EnvFields.Count -gt 0) { return }
    foreach ($f in $script:EnvFieldList) {
        $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,4,0,4'
        foreach ($w in 230, 330, '*') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
        $l = New-Object System.Windows.Controls.TextBlock; $l.Text = $f.Label; $l.FontWeight = 'SemiBold'; $l.VerticalAlignment = 'Center'
        $b = New-Object System.Windows.Controls.TextBox; $b.Padding = '6,4'; $b.Margin = '0,0,10,0'; $b.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
        if ($f.Default) { $b.Text = $f.Default }
        [System.Windows.Automation.AutomationProperties]::SetName($b, $f.Label)
        $h = New-Object System.Windows.Controls.TextBlock; $h.Text = $f.Hint; $h.TextWrapping = 'Wrap'; $h.FontSize = 12; $h.VerticalAlignment = 'Center'; $h.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2)
        Set-Brush $h ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
        foreach ($e in $l, $b, $h) { [void]$g.Children.Add($e) }
        [void]$ui.PanelEnvFields.Children.Add($g)
        $script:EnvFields[$f.Key] = $b
    }
}

function Get-EnvSpec {
    $a = Get-EnvAnswers
    $t = @{}; foreach ($k in $script:EnvFields.Keys) { $t[$k] = $script:EnvFields[$k].Text.Trim() }
    $users = 0; [void][int]::TryParse($t.Users, [ref]$users); $gib = 0; [void][int]::TryParse($t.GiBPerUser, [ref]$gib)
    [pscustomobject]@{
        SubscriptionId = $t.SubscriptionId; ResourceGroup = $t.ResourceGroup; Location = $t.Location; AccountName = $t.AccountName; Sku = $t.Sku; ShareName = $t.ShareName; Users = $users; GiBPerUser = $gib
        Endpoint = $(if ($a) { [string]$a.Endpoint } else { 'Private' }); SubnetId = $t.SubnetId; PrivateEndpointName = $t.PrivateEndpointName; DnsZone = $(if ($a) { [string]$a.DnsZone } else { 'Azure' })
        DnsZoneResourceGroup = $t.DnsZoneResourceGroup; UsersGroupId = $t.UsersGroupId; AdminsGroupId = $t.AdminsGroupId; UsersGroupName = $t.UsersGroupName; AdminsGroupName = $t.AdminsGroupName; DomainName = $t.DomainName; DomainGuid = $t.DomainGuid
        AllowedIps = @($t.AllowedIps -split '[,;\s]+' | Where-Object { $_ })
    }
}
function Get-EnvIdentity { $a = Get-EnvAnswers; if (-not $a) { return $null }; (Resolve-AVDTuneEnvironmentPlan $a).AzureFilesAuth }

function Set-EnvPill($Text, [string]$Status) {
    $pair = $script:ReadyPill[$Status]
    $pill = New-Object System.Windows.Controls.Border
    Set-Brush $pill ([System.Windows.Controls.Border]::StyleProperty) 'Pill'; $pill.Padding = '10,2'; $pill.VerticalAlignment = 'Center'; $pill.HorizontalAlignment = 'Left'
    Set-Brush $pill ([System.Windows.Controls.Border]::BackgroundProperty) $pair[0]
    $pt = New-Object System.Windows.Controls.TextBlock; $pt.Text = $Text; $pt.FontSize = 12; $pt.FontWeight = 'SemiBold'
    Set-Brush $pt ([System.Windows.Controls.TextBlock]::ForegroundProperty) $pair[1]
    $pill.Child = $pt
    $pill
}

function New-EnvRow($Step) {
    $status = switch ($Step.Action) { 'Create' { 'yellow' } 'Update' { 'yellow' } 'None' { 'green' } 'Blocked' { 'red' } 'Keep' { 'yellow' } 'Delete' { 'yellow' } 'Restore' { 'yellow' } 'Covered' { 'info' } 'Gone' { 'info' } default { 'info' } }
    $label = switch ($Step.Action) { 'Create' { 'Create' } 'Update' { 'Change' } 'None' { 'Exists' } 'Manual' { 'By hand' } 'Deferred' { 'Later' } default { [string]$Step.Action } }
    $grid = New-Object System.Windows.Controls.Grid; $grid.Margin = '0,5,0,5'
    foreach ($w in 110, 330, '*') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$grid.ColumnDefinitions.Add($c) }
    $pill = Set-EnvPill $label $status
    $title = New-Object System.Windows.Controls.TextBlock; $title.Text = [string]$Step.Title; $title.TextWrapping = 'Wrap'; $title.FontWeight = 'SemiBold'; $title.VerticalAlignment = 'Center'; $title.Margin = '0,0,10,0'; $title.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
    $why = if ($Step.PSObject.Properties['Why']) { [string]$Step.Why } else { [string]$Step.Reason }
    $changes = if ($Step.PSObject.Properties['Changes'] -and @($Step.Changes).Count -gt 0) { "`r`n" + (@($Step.Changes) -join '; ') } else { '' }
    $reason = New-Object System.Windows.Controls.TextBlock; $reason.Text = $why + $changes; $reason.TextWrapping = 'Wrap'; $reason.VerticalAlignment = 'Center'; $reason.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2)
    Set-Brush $reason ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
    $tip = if ($Step.PSObject.Properties['Source']) { "Source: $($Step.Source)`r`nStated on Microsoft Learn: $(if ($Step.Verified) { 'yes' } else { 'no' })$(if ($Step.Note) { "`r`n" + $Step.Note })" } else { '' }
    foreach ($e in $pill, $title, $reason) { if ($tip) { $e.ToolTip = $tip }; [void]$grid.Children.Add($e) }
    $grid
}

function Show-EnvPlan($Plan, [string]$Title) {
    $ui.PanelEnvPlan.Children.Clear()
    $ui.TxtEnvPlanTitle.Text = $Title
    foreach ($b in @($Plan.PSObject.Properties['Blocked'] | ForEach-Object { $_.Value })) { $t = New-Object System.Windows.Controls.TextBlock; $t.Text = "Blocked: $b"; $t.TextWrapping = 'Wrap'; $t.Margin = '0,4,0,4'; Set-Brush $t ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'Danger'; [void]$ui.PanelEnvPlan.Children.Add($t) }
    foreach ($w in @($Plan.PSObject.Properties['Warnings'] | ForEach-Object { $_.Value })) { $t = New-Object System.Windows.Controls.TextBlock; $t.Text = "Note: $w"; $t.TextWrapping = 'Wrap'; $t.Margin = '0,4,0,4'; Set-Brush $t ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'Warning'; [void]$ui.PanelEnvPlan.Children.Add($t) }
    foreach ($s in @($Plan.Steps)) { [void]$ui.PanelEnvPlan.Children.Add((New-EnvRow $s)) }
}

function Update-EnvView {
    Initialize-EnvFields
    $a = Get-EnvAnswers
    if (-not $a) { $ui.TxtEnvState.Text = 'Answer the first-run questions on the Overview first: the identity model decides what is planned here.'; foreach ($b in $ui.BtnEnvPlan, $ui.BtnEnvUndoPlan, $ui.BtnEnvMasterTest, $ui.BtnEnvMasterApply) { $b.IsEnabled = $false }; return }
    $applies = ([string]$a.Profiles -eq 'AzureFiles')
    foreach ($b in $ui.BtnEnvPlan, $ui.BtnEnvUndoPlan, $ui.BtnEnvMasterTest, $ui.BtnEnvMasterApply) { $b.IsEnabled = ($applies -and -not $script:EnvJob) }   # a running job (#44) keeps them locked until it ends
    if (-not $applies) { $ui.TxtEnvState.Text = 'Profiles are not on Azure Files (first-run questions): there is nothing to create here.'; return }
    $identity = Get-EnvIdentity
    $model = Get-AVDTuneEnvIdentityModel -Identity $identity -Identities ([string]$a.Identities)
    $ui.TxtEnvModel.Text = "Identity: $identity ($($model.DirectoryServiceOptions)). Endpoint: $($a.Endpoint), DNS: $($a.DnsZone). " + (@($model.Notes) -join ' ')
    if ($script:EnvFields['SubscriptionId'].Text -eq '') {
        $vm = Get-AVDTuneVmIdentity -Machine $script:Machine
        if ($vm.Available) { $script:EnvFields['SubscriptionId'].Text = $vm.SubscriptionId; $script:EnvFields['ResourceGroup'].Text = $vm.ResourceGroup; $script:EnvFields['Location'].Text = $vm.Location }
    }
    $ui.TxtEnvState.Text = $(if (Test-AVDTuneWriteAllowed) { 'The snapshot is confirmed: the plan can be carried out.' } else { 'Read only: you can make the plan; creating needs the confirmed snapshot of the Overview.' })
}

# #44: plan, create, undo plan and undo run in a background runspace (New-AVDTunePowerShell), like the writer jobs of the other pages (#66/#72): the window stays
# responsive while Azure works, the task bar shows the step, the window timer polls the result. Apply and Undo are writer jobs (EnvJob in WriterJobVariables; Plan and
# UndoPlan only read Azure): write gate and Assert-NoOtherWriter first, the gate goes into the runspace, the shutdown block holds while they run. The token is taken on
# the window thread (sign-in), handed over in memory and removed from the job table when it ends. #45: a run that stopped in the middle (journal step still Started)
# is closed first by the plan and the undo plan, from the real state of its resources (GET only), and named in the protocol.
$script:EnvJob = $null
$script:EnvReadKinds = @('Plan', 'UndoPlan')   # the kinds of EnvJob that do not change anything (also in WriterReadOnlyKinds)
$script:EnvWorkerText = @'
param($AppRoot, $Root, $Kind, $A, $Gate, $Sync, $SharedArm, $FakeScript)
$ErrorActionPreference = 'Stop'
foreach ($n in 'AVDTune', 'AVDTune.Snapshot', 'AVDTune.Environment') { Import-Module (Join-Path $AppRoot "Modules\$n.psm1") -Force }
# test mode: the fake ARM of the window (its store is shared, so the page sees what was made) with the helpers of its script in this runspace
if ($FakeScript) { . $FakeScript; $arm = $SharedArm } else { $arm = New-AVDTuneArmAdapter }
if ($Gate) { Open-AVDTuneWriteGate -SnapshotId $Gate.SnapshotId -ConfirmedBy $Gate.ConfirmedBy }
$closed = @()
if ($Kind -in 'Plan', 'UndoPlan' -and @(Get-AVDTuneEnvInterrupted -Root $Root).Count -gt 0) { $Sync.Text = 'interrupted'; $closed = @(Resolve-AVDTuneEnvInterrupted -Arm $arm -Token $A.Token -Root $Root -User $A.User) }
$Sync.Text = 'azure'
$out = $null
switch ($Kind) {
    'Plan' { $out = Get-AVDTuneEnvPlan -Arm $arm -Token $A.Token -Spec $A.Spec -Identity $A.Identity -Identities $A.Identities -User $A.User -ImageVersion $A.ImageVersion }
    'Apply' { $out = Invoke-AVDTuneEnvApply -Arm $arm -Token $A.Token -Spec $A.Spec -Identity $A.Identity -Identities $A.Identities -ConfirmedHash $A.Hash -Root $Root -User $A.User -SnapshotId $A.SnapshotId }
    'UndoPlan' { $out = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $A.Token -Root $Root }
    'Undo' { $out = Invoke-AVDTuneEnvUndo -Arm $arm -Token $A.Token -ConfirmedHash $A.Hash -Root $Root -User $A.User -SnapshotId $A.SnapshotId }
    default { throw "Unknown environment job '$Kind'." }
}
[pscustomobject]@{ Result = $out; Closed = $closed }
'@
$script:EnvJobText = @{
    Plan = @('Plan the FSLogix storage', 'Reading Azure (nothing is changed)'); Apply = @('Create the FSLogix storage', 'Creating the resources one by one')
    UndoPlan = @('Plan the undo', 'Reading Azure (nothing is changed)'); Undo = @('Take back the FSLogix storage', 'Deleting what AVDTune created')
}
function Set-EnvBusy([bool]$Busy) {
    $a = Get-EnvAnswers; $applies = ($a -and [string]$a.Profiles -eq 'AzureFiles')
    foreach ($b in $ui.BtnEnvPlan, $ui.BtnEnvUndoPlan, $ui.BtnEnvMasterTest, $ui.BtnEnvMasterApply) { $b.IsEnabled = ($applies -and -not $Busy) }
    if ($Busy) { $ui.BtnEnvApply.IsEnabled = $false; $ui.BtnEnvUndo.IsEnabled = $false }
}
function Start-EnvJob([string]$Kind, [hashtable]$A) {
    if ($script:EnvJob) { throw 'An environment task is still running. Wait until it is done.' }
    $writes = $Kind -notin $script:EnvReadKinds
    if ($writes) {
        if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot of today on the Overview first.' }
        Assert-NoOtherWriter
    }
    $sync = [hashtable]::Synchronized(@{ Text = '' })
    $ps = New-AVDTunePowerShell
    $task = $null
    try {
        [void]$ps.AddScript($script:EnvWorkerText).AddArgument($script:AppRoot).AddArgument($script:StateRoot).AddArgument($Kind).AddArgument($A).AddArgument($(if ($writes) { Get-AVDTuneWriteGate } else { $null })).AddArgument($sync).AddArgument($(if ($script:TestMode) { $script:EnvFake } else { $null })).AddArgument($(if ($script:TestMode) { Get-TestScript 'FakeEnvArm.ps1' } else { $null }))
        $task = Start-AVDTuneUiTask -Kind "environment-$($Kind.ToLower())" -Title $script:EnvJobText[$Kind][0] -Step $script:EnvJobText[$Kind][1]
        $script:EnvJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Kind = $Kind; Sync = $sync; Task = $task; A = $A }
    }
    catch {
        # nothing started: the runspace and the token go at once, a task that was shown ends failed (#44 review)
        $ps.Dispose(); $A.Token = $null
        if ($task) { Complete-AVDTuneUiTask $task -Failed -Summary $_.Exception.Message }
        throw
    }
    if ($writes) { Set-ShutdownBlock $true }
    Set-EnvBusy $true
}
function Complete-EnvJob {
    $job = $script:EnvJob
    if (-not $job) { return }
    if (-not $job.Handle.IsCompleted) { if ([string]$job.Sync.Text -eq 'interrupted') { Update-AVDTuneUiTask $job.Task -Step 'Closing a run that stopped in the middle (GET only)' }; return }
    $script:EnvJob = $null
    $res = $null; $err = ''
    try {
        $out = @($job.PS.EndInvoke($job.Handle))
        if ($job.PS.Streams.Error.Count -gt 0) { $err = $job.PS.Streams.Error[0].Exception.Message }
        $res = $out | Select-Object -Last 1
    }
    catch { $err = $_.Exception.Message }
    finally {
        # always, whatever failed above or here: the token lives only as long as the job, the runspace goes, the shutdown block and the buttons are released (#44 review)
        $job.A.Token = $null
        try { $job.PS.Dispose() } catch { }
        try { if ($job.Kind -notin $script:EnvReadKinds) { Set-ShutdownBlock $false } } catch { }
        try { Set-EnvBusy $false } catch { }
    }
    if ($res -and @($res.Closed).Count -gt 0) {
        $text = T 'env.interrupted.closed' ((@($res.Closed | ForEach-Object { "$($_.Id): $($_.Status) ($($_.Message))" }) -join '; '))
        [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'other' -Subject $text); Save-Protocol
        Show-Toast $text
    }
    $r = if ($res) { $res.Result } else { $null }
    if ($err -or -not $r) {
        if (-not $err) { $err = 'The job ended without a result.' }
        $ui.TxtEnvResult.Text = $err
        Complete-AVDTuneUiTask $job.Task -Failed -Summary $err
        if ($job.Kind -notin $script:EnvReadKinds) { Start-OverviewRefresh }
        return
    }
    switch ($job.Kind) {
        'Plan' {
            $script:EnvPlan = $r
            Show-EnvPlan $r "Plan (hash $($r.Hash))"
            $ui.BtnEnvApply.IsEnabled = ($r.Changes -gt 0 -and $r.Blocked.Count -eq 0)
            $ui.TxtEnvResult.Text = "$($r.Changes) resource(s) to create or change; nothing was written."
        }
        'Apply' {
            foreach ($x in @($r.Results)) { Register-StepResult ([pscustomobject]@{ Id = $x.Id; Section = 'FSLogix'; Title = $x.Title; Mode = 'Apply'; Status = $x.Status; Message = $x.Message; At = (Get-Date).ToString('o') }) }
            $ui.TxtEnvResult.Text = [string]$r.Message
            Show-Toast ([string]$r.Message)
            Start-OverviewRefresh
        }
        'UndoPlan' {
            $script:EnvUndoPlan = $r
            Show-EnvPlan ([pscustomobject]@{ Steps = @($r.Steps) }) 'What AVDTune may take back'
            $ui.BtnEnvUndo.IsEnabled = ($r.Count -gt 0)
            $ui.TxtEnvResult.Text = "$($r.Count) step(s) can be taken back. A share with profile data and an account whose share is not verified empty always stay."
        }
        'Undo' {
            $ui.TxtEnvResult.Text = [string]$r.Message
            Show-Toast ([string]$r.Message)
            Start-OverviewRefresh
        }
    }
    $bad = ($r.PSObject.Properties['Status'] -and $r.Status -in 'Failed', 'Refused')
    Complete-AVDTuneUiTask $job.Task -Failed:$bad -Summary $(if ($r.PSObject.Properties['Message'] -and $r.Message) { [string]$r.Message } else { 'done' })
}
$script:Timer.Add_Tick({ try { Complete-EnvJob } catch { Show-Error $_.Exception.Message } })

function Get-EnvJobToken { $tok = Get-EnvToken; if (-not $tok.Token) { throw $tok.Reason }; [string]$tok.Token }
Add-Click $ui.BtnEnvPlan {
    $a = Get-EnvAnswers
    Start-EnvJob 'Plan' @{ Token = (Get-EnvJobToken); Spec = (Get-EnvSpec); Identity = (Get-EnvIdentity); Identities = [string]$a.Identities; User = (Get-EnvUser); ImageVersion = [string](Get-AVDTuneState $script:StateRoot).ImageVersion }
}
Add-Click $ui.BtnEnvApply {
    if (-not $script:EnvPlan) { throw 'Make the plan first.' }
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot of today on the Overview first.' }; Assert-NoOtherWriter
    $p = $script:EnvPlan
    $lines = @($p.Steps | Where-Object { $_.Action -in 'Create', 'Update' } | ForEach-Object { "$($_.Action): $($_.Title)" }) -join "`n"
    if (-not (Confirm-Action "Create or change exactly these Azure resources?`n`n$lines`n`nPlan $($p.Hash)" 'Environment')) { return }
    $a = Get-EnvAnswers
    Start-EnvJob 'Apply' @{ Token = (Get-EnvJobToken); Spec = $p.Spec; Identity = $p.Identity; Identities = [string]$a.Identities; Hash = $p.Hash; User = (Get-EnvUser); SnapshotId = (Get-EnvGateSnapshot) }
}
Add-Click $ui.BtnEnvUndoPlan {
    Start-EnvJob 'UndoPlan' @{ Token = (Get-EnvJobToken); User = (Get-EnvUser) }
}
Add-Click $ui.BtnEnvUndo {
    if (-not $script:EnvUndoPlan) { throw 'Show what can be taken back first.' }
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot of today on the Overview first.' }; Assert-NoOtherWriter
    $p = $script:EnvUndoPlan
    $lines = @($p.Steps | Where-Object { $_.Action -in 'Delete', 'Restore' } | ForEach-Object { "$($_.Action): $($_.Id)" }) -join "`n"
    if (-not (Confirm-Action "Take back exactly this?`n`n$lines`n`nPlan $($p.Hash)" 'Environment')) { return }
    Start-EnvJob 'Undo' @{ Token = (Get-EnvJobToken); Hash = $p.Hash; User = (Get-EnvUser); SnapshotId = (Get-EnvGateSnapshot) }
}
function Get-EnvPlanned {
    # The master part works from the plan that was made and shown, not from the form (which may have been edited since)
    if (-not $script:EnvPlan) { throw 'Make the plan first: the settings of the master are taken from the plan you saw, not from the form.' }
    $script:EnvPlan
}
Add-Click $ui.BtnEnvMasterTest {
    $pl = Get-EnvPlanned
    $r = @(Set-AVDTuneEnvMaster -Machine $script:Machine -Spec $pl.Spec -Identity $pl.Identity -Root $script:StateRoot -User (Get-EnvUser) -WhatIf)
    $ui.TxtEnvMaster.Text = (@($r | ForEach-Object { $_.Results } | ForEach-Object { "$($_.Title): $($_.Status)" })) -join '; '
}
Add-Click $ui.BtnEnvMasterApply {
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot of today on the Overview first.' }; Assert-NoOtherWriter
    $pl = Get-EnvPlanned
    if (-not (Confirm-Action "Write these FSLogix settings to the registry of this master?`n`nEnabled = 1`nVHDLocations = $(Get-AVDTuneEnvVhdLocation $pl.Spec)$(if ($pl.Identity -eq 'EntraKerberos') { '`nCloudKerberosTicketRetrievalEnabled = 1' })" 'Environment')) { return }
    $r = @(Set-AVDTuneEnvMaster -Machine $script:Machine -Spec $pl.Spec -Identity $pl.Identity -Root $script:StateRoot -User (Get-EnvUser) -SnapshotId (Get-EnvGateSnapshot))
    foreach ($run in $r) { foreach ($x in @($run.Results)) { Register-StepResult $x } }
    $ui.TxtEnvMaster.Text = (@($r | ForEach-Object { $_.Results } | ForEach-Object { "$($_.Title): $($_.Status)" })) -join '; '
    Start-OverviewRefresh
}
