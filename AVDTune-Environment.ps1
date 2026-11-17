# The Environment page (dot-sourced by Start-AVDTune.ps1; plan section 1b, docs\environment-wizard.md). Logic is in Modules\AVDTune.Environment.psm1; this file loads the page
# from UI\AVDTune.Environment.xaml, builds the form from the first-run answers and shows the plan. Reading (the plan) and every change (create, undo) run on the window
# thread behind a task in the bar at the bottom, like the changes of the FSLogix page: the window waits while Azure works (an asynchronous operation takes seconds to a few
# minutes). Every change shows the plan first and asks for the confirmation of exactly that plan; the module refuses a different plan.
# Test mode: the fake ARM (Tests\Fakes\FakeEnvArm.ps1) and no token of a real sign-in; nothing leaves this computer.

$script:EnvFake = $null
if ($script:TestMode) { . (Get-TestScript 'FakeEnvArm.ps1'); $script:EnvFake = New-AVDTuneFakeEnvArm }
$script:EnvFields = @{}
$script:EnvPlan = $null
$script:EnvUndoPlan = $null
$script:EnvRealArm = $null

[xml]$envXaml = Get-Content (Join-Path $PSScriptRoot 'UI\AVDTune.Environment.xaml') -Raw -Encoding UTF8
$envPage = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($envXaml))
foreach ($node in $envXaml.SelectNodes("//*[@*[local-name()='Name']]")) {
    $name = $node.Attributes | Where-Object LocalName -eq 'Name' | Select-Object -ExpandProperty Value
    $ui[$name] = $envPage.FindName($name)
}
$ui.PageEnvironment = $envPage
[void]$ui.PagePlaceholder.Parent.Children.Add($envPage)

function Get-EnvArm { if ($script:TestMode) { $script:EnvFake } else { if (-not $script:EnvRealArm) { $script:EnvRealArm = New-AVDTuneArmAdapter }; $script:EnvRealArm } }
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

function Invoke-EnvTask([string]$Kind, [string]$Title, [string]$Step, [scriptblock]$Block) {
    # The task shows in the bar first, then the call blocks the window thread (like Invoke-FslChange)
    $task = Start-AVDTuneUiTask -Kind $Kind -Title $Title -Step $Step
    try { Update-TaskBar; $window.Dispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Render) } catch { }
    $out = $null
    try { $out = & $Block }
    catch { Complete-AVDTuneUiTask $task -Failed -Summary $_.Exception.Message; throw }
    if ($out -and $out.PSObject.Properties['Status'] -and $out.Status -in 'Failed', 'Refused') { Complete-AVDTuneUiTask $task -Failed -Summary ([string]$out.Message) }
    else { Complete-AVDTuneUiTask $task -Summary $(if ($out -and $out.PSObject.Properties['Message']) { [string]$out.Message } else { 'done' }) }
    $out
}

function Update-EnvView {
    Initialize-EnvFields
    $a = Get-EnvAnswers
    if (-not $a) { $ui.TxtEnvState.Text = 'Answer the first-run questions on the Overview first: the identity model decides what is planned here.'; foreach ($b in $ui.BtnEnvPlan, $ui.BtnEnvUndoPlan, $ui.BtnEnvMasterTest, $ui.BtnEnvMasterApply) { $b.IsEnabled = $false }; return }
    $applies = ([string]$a.Profiles -eq 'AzureFiles')
    foreach ($b in $ui.BtnEnvPlan, $ui.BtnEnvUndoPlan, $ui.BtnEnvMasterTest, $ui.BtnEnvMasterApply) { $b.IsEnabled = $applies }
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

Add-Click $ui.BtnEnvPlan {
    $tok = Get-EnvToken
    if (-not $tok.Token) { throw $tok.Reason }
    $spec = Get-EnvSpec; $identity = Get-EnvIdentity; $a = Get-EnvAnswers
    $script:EnvPlan = Invoke-EnvTask 'Environment' 'Plan the FSLogix storage' 'Reading Azure (nothing is changed)' { Get-AVDTuneEnvPlan -Arm (Get-EnvArm) -Token $tok.Token -Spec $spec -Identity $identity -Identities ([string]$a.Identities) -User (Get-EnvUser) -ImageVersion ([string](Get-AVDTuneState $script:StateRoot).ImageVersion) }
    Show-EnvPlan $script:EnvPlan "Plan (hash $($script:EnvPlan.Hash))"
    $ui.BtnEnvApply.IsEnabled = ($script:EnvPlan.Changes -gt 0 -and $script:EnvPlan.Blocked.Count -eq 0)
    $ui.TxtEnvResult.Text = "$($script:EnvPlan.Changes) resource(s) to create or change; nothing was written."
}
Add-Click $ui.BtnEnvApply {
    if (-not $script:EnvPlan) { throw 'Make the plan first.' }
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot of today on the Overview first.' }; Assert-NoOtherWriter
    $p = $script:EnvPlan
    $lines = @($p.Steps | Where-Object { $_.Action -in 'Create', 'Update' } | ForEach-Object { "$($_.Action): $($_.Title)" }) -join "`n"
    if (-not (Confirm-Action "Create or change exactly these Azure resources?`n`n$lines`n`nPlan $($p.Hash)" 'Environment')) { return }
    $tok = Get-EnvToken
    if (-not $tok.Token) { throw $tok.Reason }
    $a = Get-EnvAnswers
    $r = Invoke-EnvTask 'Environment' 'Create the FSLogix storage' 'Creating the resources one by one' { Invoke-AVDTuneEnvApply -Arm (Get-EnvArm) -Token $tok.Token -Spec $p.Spec -Identity $p.Identity -Identities ([string]$a.Identities) -ConfirmedHash $p.Hash -Root $script:StateRoot -User (Get-EnvUser) -SnapshotId (Get-EnvGateSnapshot) }
    foreach ($x in @($r.Results)) { Register-StepResult ([pscustomobject]@{ Id = $x.Id; Section = 'FSLogix'; Title = $x.Title; Mode = 'Apply'; Status = $x.Status; Message = $x.Message; At = (Get-Date).ToString('o') }) }
    $ui.TxtEnvResult.Text = [string]$r.Message
    Show-Toast ([string]$r.Message)
    $ui.BtnEnvApply.IsEnabled = $false
    Start-OverviewRefresh
}
Add-Click $ui.BtnEnvUndoPlan {
    $tok = Get-EnvToken
    if (-not $tok.Token) { throw $tok.Reason }
    $script:EnvUndoPlan = Invoke-EnvTask 'Environment' 'Plan the undo' 'Reading Azure (nothing is changed)' { Get-AVDTuneEnvUndoPlan -Arm (Get-EnvArm) -Token $tok.Token -Root $script:StateRoot }
    Show-EnvPlan ([pscustomobject]@{ Steps = @($script:EnvUndoPlan.Steps) }) 'What AVDTune may take back'
    $ui.BtnEnvUndo.IsEnabled = ($script:EnvUndoPlan.Count -gt 0)
    $ui.TxtEnvResult.Text = "$($script:EnvUndoPlan.Count) step(s) can be taken back. A share with profile data and an account whose share is not verified empty always stay."
}
Add-Click $ui.BtnEnvUndo {
    if (-not $script:EnvUndoPlan) { throw 'Show what can be taken back first.' }
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot of today on the Overview first.' }; Assert-NoOtherWriter
    $p = $script:EnvUndoPlan
    $lines = @($p.Steps | Where-Object { $_.Action -in 'Delete', 'Restore' } | ForEach-Object { "$($_.Action): $($_.Id)" }) -join "`n"
    if (-not (Confirm-Action "Take back exactly this?`n`n$lines`n`nPlan $($p.Hash)" 'Environment')) { return }
    $tok = Get-EnvToken
    if (-not $tok.Token) { throw $tok.Reason }
    $r = Invoke-EnvTask 'Environment' 'Take back the FSLogix storage' 'Deleting what AVDTune created' { Invoke-AVDTuneEnvUndo -Arm (Get-EnvArm) -Token $tok.Token -ConfirmedHash $p.Hash -Root $script:StateRoot -User (Get-EnvUser) -SnapshotId (Get-EnvGateSnapshot) }
    $ui.TxtEnvResult.Text = [string]$r.Message
    Show-Toast ([string]$r.Message)
    $ui.BtnEnvUndo.IsEnabled = $false
    Start-OverviewRefresh
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
