<#
    AVDTune snapshot gate: nothing changes the master until a finished snapshot of its OS disk is confirmed that was made after the last
    change of the previous image version and before the first change of this one (Get-AVDTuneSnapshotWindow in AVDTune.psm1; #27: one
    snapshot per version, not per change; a rollback goes back to the start of the version), and the administrator has confirmed it by
    typing first and last name (not matched against the sign-in: shared admin accounts are used). With no change recorded yet any finished
    snapshot counts (user decision 2026-11-15). At the start of a version that is the snapshot after the last change of the previous
    version; when the master reconnects in a version that already has changes, the administrator chooses from the snapshots (the newest
    valid one is preselected, the others are shown with the reason). Until then the engine stays read only (Test-AVDTuneWriteAllowed).

      * The VM finds itself through the instance metadata service (machine adapter member Imds): subscription, resource group, VM, OS disk.
      * Azure Resource Manager is an adapter ($Arm): Invoke = { param($Method, $Path, $Token, $Body) } returns
        @{ Status; Body; Error } and never throws (Status 0 = no connection). New-AVDTuneArmAdapter is the real one (only
        https://management.azure.com), Tests\Fakes\FakeServices.ps1 has the fake.
      * Snapshot: incremental, name from the pattern of the environment (environment.json Snapshot.NamePattern, default
        {OsDisk}-{DD}.{MM}.{YYYY}-{N} as in the administrators' own process, {N} = next free number of that day), tags ImageVersion,
        CreatedBy (user), CreatedWith=AVDTune.
      * The confirmation is written to state.json (SnapshotGate), the change log and returned for the protocol: typed name, signed-in
        Microsoft account, local Windows account, time, snapshot ID, whether AVDTune made it. The open gate itself lives in memory only.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')

$script:ArmHost = 'https://management.azure.com'
$script:ComputeApi = '2023-10-02'
# The snapshot time comes from Azure, the changes from the clock of this VM: the margin (AVDTune.psm1, Test-AVDTuneSnapshotInWindow) keeps a
# VM clock that is off by a few minutes from making a wrong snapshot count
$script:ClockBufferMinutes = Get-AVDTuneSnapshotClockBufferMinutes
function Get-AVDTuneSnapshotClockBuffer { $script:ClockBufferMinutes }
$script:ConfirmationText = 'Ich bestaetige, dass vor diesem Lauf ein Snapshot des Golden Masters erstellt wurde und ein Rollback moeglich ist.'

function Get-AVDTuneGateText { $script:ConfirmationText }

#region ARM calls

function Invoke-AVDTuneArm {
    <#
        One ARM request through the adapter; a readable error instead of a status code. Returns the parsed body.
        -Action names the permission that a 403 means.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Token, $Body, [string]$Action, [string]$Scope)
    $r = & $Arm.Invoke $Method $Path $Token $Body
    $status = [int](Get-AVDTuneProp $r 'Status')
    if ($status -ge 200 -and $status -lt 300) { return (Get-AVDTuneProp $r 'Body') }
    $detail = [string](Get-AVDTuneProp $r 'Error')
    $bodyError = Get-AVDTuneProp (Get-AVDTuneProp $r 'Body') 'error'
    if ($bodyError -and (Get-AVDTuneProp $bodyError 'message')) { $detail = [string]$bodyError.message }
    switch ($status) {
        0 { throw "No connection to Azure Resource Manager (management.azure.com). Check the network, the proxy and the VM's outbound access.$(if ($detail) { " ($detail)" })" }
        401 { throw 'Azure rejected the sign-in token (401). Sign in again on the Overview.' }
        403 { throw "Azure refuses this (403): the signed-in account lacks the permission$(if ($Action) { " $Action" })$(if ($Scope) { " on $Scope" }). Grant a role that contains it (for snapshots: Disk Snapshot Contributor or Contributor on the resource group) or ask an administrator.$(if ($detail) { " ($detail)" })" }
        404 { throw "Azure does not know this resource (404)$(if ($Scope) { ": $Scope" }).$(if ($detail) { " ($detail)" })" }
        429 { throw 'Azure asks to slow down (429). Wait a minute and try again.' }
        default { throw "Azure answered $status$(if ($detail) { ": $detail" })." }
    }
}

function ConvertTo-AVDTuneArmPath([string]$Path) {
    # A nextLink is an absolute URL: only the ARM host is accepted, the host part is dropped
    if ($Path -like "$($script:ArmHost)/*") { return $Path.Substring($script:ArmHost.Length) }
    if ($Path.StartsWith('/subscriptions/') -or $Path.StartsWith('/subscriptions?')) { return $Path }
    throw 'Azure returned a link to another host; it is not followed.'
}

#endregion

#region VM identity (instance metadata)

function Get-AVDTuneVmIdentity {
    <# Subscription, resource group, VM and OS disk of this VM from the instance metadata. Available = $false outside Azure or when the OS disk is not a managed disk. #>
    param([Parameter(Mandatory)]$Machine)
    $none = { param($why) [pscustomobject]@{ Available = $false; Problem = $why; SubscriptionId = ''; ResourceGroup = ''; VmName = ''; VmId = ''; Location = ''; OsDiskName = ''; OsDiskId = '' } }
    $imds = & $Machine.Imds
    $c = Get-AVDTuneProp $imds 'compute'
    if (-not $c) { return (& $none 'This is not an Azure VM or the instance metadata service is not reachable (169.254.169.254).') }
    $sub = [string](Get-AVDTuneProp $c 'subscriptionId'); $rg = [string](Get-AVDTuneProp $c 'resourceGroupName'); $vm = [string](Get-AVDTuneProp $c 'name')
    $disk = Get-AVDTuneProp (Get-AVDTuneProp $c 'storageProfile') 'osDisk'
    $diskName = [string](Get-AVDTuneProp $disk 'name')
    $diskId = [string](Get-AVDTuneProp (Get-AVDTuneProp $disk 'managedDisk') 'id')
    if ($sub -notmatch '^[0-9a-fA-F-]{36}$' -or $rg -notmatch '^[A-Za-z0-9._()-]+$' -or $vm -notmatch '^[A-Za-z0-9._()-]+$') { return (& $none 'The instance metadata has no valid subscription, resource group or VM name (letters, digits and . _ ( ) - only).') }
    if (-not $diskName) { return (& $none 'The instance metadata has no OS disk.') }
    if (-not $diskId) { return (& $none 'The OS disk is not a managed disk; AVDTune can only snapshot managed disks.') }
    if ($diskId -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._()-]+/providers/Microsoft\.Compute/disks/[A-Za-z0-9._()-]+$') { return (& $none 'The OS disk ID of the instance metadata has an unexpected form.') }
    [pscustomobject]@{
        Available = $true; Problem = ''; SubscriptionId = $sub; ResourceGroup = $rg; VmName = $vm; VmId = [string](Get-AVDTuneProp $c 'vmId')
        Location = [string](Get-AVDTuneProp $c 'location'); OsDiskName = $diskName; OsDiskId = $diskId
    }
}

#endregion

#region snapshots

$script:DefaultSnapshotNamePattern = '{OsDisk}-{DD}.{MM}.{YYYY}-{N}'
$script:SnapshotNameTokens = @('OsDisk', 'VM', 'ImageVersion', 'YYYY', 'MM', 'DD', 'N')
function Get-AVDTuneDefaultSnapshotNamePattern { $script:DefaultSnapshotNamePattern }

function Test-AVDTuneSnapshotNamePattern {
    <# Error text for a name pattern, '' when it is fine: tokens {OsDisk} {VM} {ImageVersion} {YYYY} {MM} {DD} {N}, {N} required, else letters, digits, '_', '.', '-'. #>
    param([string]$Pattern)
    if (-not $Pattern) { return 'The snapshot name pattern is empty.' }
    if ($Pattern.Length -gt 80) { return 'The snapshot name pattern is longer than 80 characters.' }
    if ($Pattern -notmatch '\{N\}') { return 'The snapshot name pattern needs the counter {N}.' }
    $rest = [regex]::Replace($Pattern, '\{(' + ($script:SnapshotNameTokens -join '|') + ')\}', '')
    if ($rest -match '[^A-Za-z0-9_.-]') { return "The snapshot name pattern has characters Azure does not allow or unknown tokens (allowed: $(@($script:SnapshotNameTokens | ForEach-Object { "{$_}" }) -join ' '), letters, digits, '_', '.', '-')." }
    ''
}

function Get-AVDTuneSnapshotName {
    <#
        The name of a new snapshot from the pattern of the environment. {N} is the next free number among the existing snapshot names that
        match the pattern for that day (1 when none). Azure: 1 to 80 characters, letters, digits, '_', '.', '-', starts with a letter or digit,
        ends with a letter, digit or '_'.
    #>
    param([string]$Pattern = $script:DefaultSnapshotNamePattern, [Parameter(Mandatory)][string]$OsDiskName, [string]$VmName, [string]$ImageVersion,
        [Parameter(Mandatory)][datetime]$At, [string[]]$ExistingNames = @())
    $problem = Test-AVDTuneSnapshotNamePattern $Pattern
    if ($problem) { throw $problem }
    if ($Pattern -match '\{ImageVersion\}' -and -not (Test-AVDTuneImageVersion $ImageVersion)) { throw 'Start an image version first (Overview, Start new version): the snapshot name carries it.' }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $clean = { param($v) [regex]::Replace([string]$v, '[^A-Za-z0-9_.-]', '-') }
    $values = @{ OsDisk = (& $clean $OsDiskName); VM = (& $clean $VmName); ImageVersion = [string]$ImageVersion; YYYY = $At.ToString('yyyy', $inv); MM = $At.ToString('MM', $inv); DD = $At.ToString('dd', $inv) }
    $parts = $Pattern -split '\{N\}'
    $fill = { param($text) $out = $text; foreach ($k in $values.Keys) { $out = $out.Replace("{$k}", $values[$k]) }; $out }
    $filled = @($parts | ForEach-Object { & $fill $_ })
    $regex = '^' + ((@($filled | ForEach-Object { [regex]::Escape($_) })) -join '(\d+)') + '$'
    $highest = 0
    foreach ($n in @($ExistingNames)) {
        $m = [regex]::Match([string]$n, $regex, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) { foreach ($g in @($m.Groups | Select-Object -Skip 1)) { $v = [int]$g.Value; if ($v -gt $highest) { $highest = $v } } }
    }
    $name = $filled -join [string]($highest + 1)
    if ($name.Length -gt 80) { throw "The snapshot name '$name' is longer than the 80 characters Azure allows: shorten the name pattern of the environment." }
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*[A-Za-z0-9_]$') { throw "The snapshot name '$name' is not allowed by Azure (start with a letter or digit, end with a letter, digit or '_')." }
    $name
}

function ConvertTo-AVDTuneTagValue([string]$Text) { (Remove-AVDTuneControlCharacters $Text 256) -replace '[<>%&\\?/]', '_' }

function ConvertTo-AVDTuneSnapshotInfo {
    # Valid: finished (Succeeded) and inside the window of the current version (Test-AVDTuneSnapshotInWindow); Reason says why not. No window: any finished one.
    param($Item, $Window)
    $p = Get-AVDTuneProp $Item 'properties'
    $tags = Get-AVDTuneProp $Item 'tags'
    $created = $null
    $raw = Get-AVDTuneProp $p 'timeCreated'
    if ($raw) { try { $created = ([datetime]::Parse([string]$raw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).ToLocalTime() } catch { } }
    $state = [string](Get-AVDTuneProp $p 'provisioningState')
    $byTool = ([string](Get-AVDTuneProp $tags 'CreatedWith') -eq 'AVDTune')
    $id = [string](Get-AVDTuneProp $Item 'id')
    # Finished: Succeeded and, when Azure reports them (Premium SSD v2 / Ultra snapshots may be Succeeded before the data is usable), completionPercent 100
    # and snapshotAccessState Available; a field that is not there counts as before
    $pct = Get-AVDTuneProp $p 'completionPercent'; $access = [string](Get-AVDTuneProp $p 'snapshotAccessState')
    $notReady = if ($state -ne 'Succeeded') { "Not finished (state $(if ($state) { $state } else { 'unknown' }))." }
    elseif ($null -ne $pct -and [double]$pct -lt 100) { "Not finished ($([int][double]$pct) percent)." }
    elseif ($access -and $access -ne 'Available') { "Not usable yet (access state $access)." }
    else { '' }
    $fit = if ($notReady) { [pscustomobject]@{ Valid = $false; Kind = ''; Reason = $notReady } } else { Test-AVDTuneSnapshotInWindow -Created $created -Id $id -Window $Window }
    [pscustomobject]@{
        Name = [string](Get-AVDTuneProp $Item 'name'); Id = [string](Get-AVDTuneProp $Item 'id'); Created = $created; State = $state
        Sku = [string](Get-AVDTuneProp (Get-AVDTuneProp $Item 'sku') 'name')
        Incremental = [bool](Get-AVDTuneProp $p 'incremental'); ByAVDTune = $byTool
        ImageVersion = [string](Get-AVDTuneProp $tags 'ImageVersion'); CreatedBy = [string](Get-AVDTuneProp $tags 'CreatedBy')
        Finished = (-not $notReady)
        Valid = [bool]$fit.Valid; Reason = [string]$fit.Reason; Kind = [string]$fit.Kind
    }
}

function Get-AVDTuneOsDiskSnapshots {
    <# All snapshots of this OS disk in the VM's resource group (newest first), each with Valid and Reason (finished and inside -Window, Get-AVDTuneSnapshotWindow). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)]$Vm, $Window)
    $path = "/subscriptions/$($Vm.SubscriptionId)/resourceGroups/$($Vm.ResourceGroup)/providers/Microsoft.Compute/snapshots?api-version=$($script:ComputeApi)"
    $found = New-Object System.Collections.ArrayList
    for ($page = 0; $path -and $page -lt 20; $page++) {
        $body = Invoke-AVDTuneArm -Arm $Arm -Method GET -Path $path -Token $Token -Action 'Microsoft.Compute/snapshots/read' -Scope "resource group $($Vm.ResourceGroup)"
        foreach ($item in @(Get-AVDTuneProp $body 'value')) {
            if (-not $item) { continue }
            $source = [string](Get-AVDTuneProp (Get-AVDTuneProp (Get-AVDTuneProp $item 'properties') 'creationData') 'sourceResourceId')
            if ($source -ieq $Vm.OsDiskId) { [void]$found.Add((ConvertTo-AVDTuneSnapshotInfo -Item $item -Window $Window)) }
        }
        $next = [string](Get-AVDTuneProp $body 'nextLink')
        $path = if ($next) { ConvertTo-AVDTuneArmPath $next } else { $null }
    }
    @($found | Sort-Object { if ($_.Created) { $_.Created } else { [datetime]::MinValue } } -Descending)
}

function Get-AVDTuneIncrementalSnapshotSku {
    <#
        The SKU for a new incremental snapshot of a disk: Azure refuses (400) an incremental snapshot whose SKU differs from the existing incremental
        snapshots of the same disk (e.g. one made as Standard_ZRS in the portal). Only Standard_LRS and Standard_ZRS are used; the newest existing incremental
        snapshot decides, otherwise Standard_LRS.
    #>
    param($Snapshots)
    $allowed = 'Standard_LRS', 'Standard_ZRS'
    $inc = @(@($Snapshots) | Where-Object { $_ -and $_.Incremental -and $_.Sku } | Sort-Object { if ($_.Created) { $_.Created } else { [datetime]::MinValue } } -Descending)
    foreach ($s in $inc) { if ($allowed -ccontains [string]$s.Sku) { return [string]$s.Sku } }
    'Standard_LRS'
}

function Start-AVDTuneSnapshot {
    <#
        Starts an incremental snapshot of the OS disk. Returns Name, Id and State immediately; the snapshot is usable when
        Get-AVDTuneSnapshotState says Succeeded. The disk is read first (it must exist and tells the location).
        -ExistingSnapshots: the snapshots of this disk (Get-AVDTuneOsDiskSnapshots); their SKU is kept (Get-AVDTuneIncrementalSnapshotSku).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)]$Vm, [Parameter(Mandatory)][string]$ImageVersion, [string]$User, [datetime]$At = (Get-Date),
        [string]$NamePattern = $script:DefaultSnapshotNamePattern, [string[]]$ExistingNames = @(), $ExistingSnapshots = @())
    if (-not (Test-AVDTuneImageVersion $ImageVersion)) { throw 'Start an image version first (Overview, Start new version): the snapshot tags carry it.' }
    $name = Get-AVDTuneSnapshotName -Pattern $NamePattern -OsDiskName $Vm.OsDiskName -VmName $Vm.VmName -ImageVersion $ImageVersion -At $At -ExistingNames $ExistingNames
    $diskBody = Invoke-AVDTuneArm -Arm $Arm -Method GET -Path "$($Vm.OsDiskId)?api-version=$($script:ComputeApi)" -Token $Token -Action 'Microsoft.Compute/disks/read' -Scope "the OS disk $($Vm.OsDiskName)"
    $location = [string](Get-AVDTuneProp $diskBody 'location'); if (-not $location) { $location = $Vm.Location }
    $id = "/subscriptions/$($Vm.SubscriptionId)/resourceGroups/$($Vm.ResourceGroup)/providers/Microsoft.Compute/snapshots/$name"
    $body = [ordered]@{
        location = $location
        sku = @{ name = (Get-AVDTuneIncrementalSnapshotSku $ExistingSnapshots) }
        tags = @{ ImageVersion = (ConvertTo-AVDTuneTagValue $ImageVersion); CreatedBy = (ConvertTo-AVDTuneTagValue $User); CreatedWith = 'AVDTune'; Vm = (ConvertTo-AVDTuneTagValue $Vm.VmName) }
        properties = @{ incremental = $true; creationData = @{ createOption = 'Copy'; sourceResourceId = $Vm.OsDiskId } }
    }
    $put = Invoke-AVDTuneArm -Arm $Arm -Method PUT -Path "${id}?api-version=$($script:ComputeApi)" -Token $Token -Body $body -Action 'Microsoft.Compute/snapshots/write' -Scope "resource group $($Vm.ResourceGroup)"
    $state = [string](Get-AVDTuneProp (Get-AVDTuneProp $put 'properties') 'provisioningState')
    [pscustomobject]@{ Name = $name; Id = $id; State = $(if ($state) { $state } else { 'Creating' }); StartedAt = $At }
}

function Get-AVDTuneSnapshotState {
    # State of a snapshot by ID: Creating, Succeeded, Failed ...; Percent when Azure reports it
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Id)
    if ($Id -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Compute/snapshots/[^/]+$') { throw 'Not a snapshot resource ID.' }
    $b = Invoke-AVDTuneArm -Arm $Arm -Method GET -Path "${Id}?api-version=$($script:ComputeApi)" -Token $Token -Action 'Microsoft.Compute/snapshots/read' -Scope 'the snapshot'
    $p = Get-AVDTuneProp $b 'properties'
    $percent = Get-AVDTuneProp $p 'completionPercent'
    [pscustomobject]@{ Id = $Id; State = $($st = [string](Get-AVDTuneProp $p 'provisioningState'); $inf = ConvertTo-AVDTuneSnapshotInfo -Item $b -Window $null; if ($st -eq 'Succeeded' -and -not $inf.Finished) { 'Creating' } else { $st }); Percent = $(if ($null -ne $percent) { [double]$percent } else { $null }); Info = (ConvertTo-AVDTuneSnapshotInfo -Item $b -Window $null) }
}

function Wait-AVDTuneSnapshot {
    # Blocking wait for command line and checks; the window polls Get-AVDTuneSnapshotState from a timer instead
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Id, [int]$TimeoutSeconds = 600, [int]$PollSeconds = 5)
    $until = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $s = Get-AVDTuneSnapshotState -Arm $Arm -Token $Token -Id $Id
        if ($s.State -eq 'Succeeded') { return $s }
        if ($s.State -in 'Failed', 'Canceled') { throw "The snapshot failed in Azure (state $($s.State))." }
        if ((Get-Date) -gt $until) { throw "The snapshot is not ready after $TimeoutSeconds seconds (state $($s.State)). It may still finish: check the resource group." }
        if ($PollSeconds -gt 0) { Start-Sleep -Seconds $PollSeconds }
    }
}

#endregion

#region the gate

function Test-AVDTuneConfirmationName {
    <#
        The typed name: at least first and last name (two words with two letters or more each). Not matched against the sign-in, because shared
        admin accounts are used (user decision 2026-11-15); the protocol and the change log record the typed name with both accounts instead.
    #>
    param([string]$Typed)
    $t = ([regex]::Replace([string]$Typed, '\s+', ' ')).Trim()
    if ($t -match '[\x00-\x1F]') { return [pscustomobject]@{ Ok = $false; Message = 'The name contains control characters.' } }
    $words = @($t -split ' ' | Where-Object { $_ })
    $named = @($words | Where-Object { ([regex]::Matches($_, '\p{L}')).Count -ge 2 })
    if ($words.Count -lt 2 -or $named.Count -lt 2) { return [pscustomobject]@{ Ok = $false; Message = 'Type your first and last name.' } }
    [pscustomobject]@{ Ok = $true; Message = '' }
}

function Get-AVDTuneGateStatus {
    <#
        Where the gate stands: NoVm (not Azure / no OS disk), NoValidSnapshot (create one), SnapshotReady (confirm it), Confirmed.
        Snapshots = the snapshots of the OS disk; Chosen = the newest valid one (finished, after the last change of the previous version, before
        the first change of this one: -Window, Get-AVDTuneSnapshotWindow). Mode = VersionStart or Reconnect (changes already made in this version).
    #>
    param([Parameter(Mandatory)]$Vm, $Snapshots, [bool]$Confirmed = (Test-AVDTuneWriteAllowed), $Window)
    if (-not $Vm.Available) { return [pscustomobject]@{ Status = 'NoVm'; Detail = $Vm.Problem; Chosen = $null; Snapshots = @() } }
    $list = @($Snapshots | Where-Object { $_ })
    $valid = @($list | Where-Object { $_.Valid })
    $chosen = $valid | Select-Object -First 1
    $lower = if ($Window) { $Window.Lower } else { $null }
    $reconnect = [bool]($Window -and $Window.FirstChange)
    $since = if ($reconnect) { "from the start of this version: made before the first change of this version ($(([datetime]$Window.FirstChange).ToString('yyyy-MM-dd HH:mm')))$(if ($lower) { " and at least $($script:ClockBufferMinutes) minutes after the last change of the previous version ($(([datetime]$lower).ToString('yyyy-MM-dd HH:mm')))" }); or from the current state (made at least $($script:ClockBufferMinutes) minutes after the last change, so it loses nothing); a rollback goes back to the start of the version or to the current state" }
    elseif ($lower) { "made at least $($script:ClockBufferMinutes) minutes after the last change by AVDTune ($(([datetime]$lower).ToString('yyyy-MM-dd HH:mm')); the margin covers a clock of this VM that runs behind Azure)" }
    else { 'that is finished (AVDTune has not changed this master yet)' }
    $mode = if ($reconnect) { 'Reconnect' } else { 'VersionStart' }
    if ($Confirmed) { return [pscustomobject]@{ Status = 'Confirmed'; Mode = $mode; Detail = 'The snapshot is confirmed; the pages can change the master.'; Chosen = $chosen; Snapshots = $list } }
    if ($chosen) { return [pscustomobject]@{ Status = 'SnapshotReady'; Mode = $mode; Detail = "A snapshot $since exists: $($chosen.Name). Confirm it to unlock the pages."; Chosen = $chosen; Snapshots = $list } }
    [pscustomobject]@{ Status = 'NoValidSnapshot'; Mode = $mode; Detail = "No snapshot of the OS disk $since.$(if ($reconnect) { ' Choose another one or create one now (it is the current state).' } else { ' Create one now.' })"; Chosen = $null; Snapshots = $list }
}

function Get-AVDTuneVerifiedSnapshot {
    <#
        Reads one snapshot from Azure by ID and checks that it is a snapshot of THIS OS disk: sourceResourceId equals the OS disk ID and, when both are
        there, the snapshot's sourceUniqueId equals the uniqueId of the disk (a disk deleted and created again under the same name is another disk).
        Returns the snapshot info (state, creation time from Azure); throws otherwise.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)]$Vm, [Parameter(Mandatory)][string]$Id)
    if ($Id -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._()-]+/providers/Microsoft\.Compute/snapshots/[A-Za-z0-9._-]+$') { throw 'Not a snapshot resource ID.' }
    $body = Invoke-AVDTuneArm -Arm $Arm -Method GET -Path "${Id}?api-version=$($script:ComputeApi)" -Token $Token -Action 'Microsoft.Compute/snapshots/read' -Scope 'the snapshot'
    if ([string](Get-AVDTuneProp $body 'id') -ine $Id) { throw 'Azure answered with another snapshot than the one asked for.' }
    $cd = Get-AVDTuneProp (Get-AVDTuneProp $body 'properties') 'creationData'
    if ([string](Get-AVDTuneProp $cd 'sourceResourceId') -ine $Vm.OsDiskId) { throw 'The snapshot is not a snapshot of the OS disk of this VM.' }
    $disk = Invoke-AVDTuneArm -Arm $Arm -Method GET -Path "$($Vm.OsDiskId)?api-version=$($script:ComputeApi)" -Token $Token -Action 'Microsoft.Compute/disks/read' -Scope "the OS disk $($Vm.OsDiskName)"
    $diskUnique = [string](Get-AVDTuneProp (Get-AVDTuneProp $disk 'properties') 'uniqueId'); $snapUnique = [string](Get-AVDTuneProp $cd 'sourceUniqueId')
    if ($diskUnique -and $snapUnique -and $diskUnique -ine $snapUnique) { throw 'The snapshot was made from another disk of the same name (the unique ID of the source differs).' }
    ConvertTo-AVDTuneSnapshotInfo -Item $body -Window $null
}

function Confirm-AVDTuneSnapshotGate {
    <#
        Confirmation of a valid snapshot by the typed name. Checks again that the snapshot is finished, newer than the last change of the previous
        version and older than the first change of this one (Get-AVDTuneSnapshotWindow, read from state.json, runs and change log now; the caller's
        word that it is valid does not count). Writes SnapshotGate into state.json and an entry into the change
        log (typed name, signed-in Microsoft account, local Windows account, time, snapshot ID, created by AVDTune yes/no), then opens the
        write gate of the engine. Returns the record for the protocol.
    #>
    [CmdletBinding()]
    param(
        [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)][string]$TypedName, [string]$SignedInAccount,
        [string]$WindowsAccount = "$env:USERDOMAIN\$env:USERNAME", [Parameter(Mandatory)][string]$ImageVersion, [Parameter(Mandatory)]$Machine,
        $Arm, [string]$Token, $Vm
    )
    # With -Arm (the window always passes it): the snapshot is read from Azure again now and what the caller says about it (time, state, source) is not used
    if ($Arm) {
        if (-not $Vm -or -not $Token) { throw 'The snapshot cannot be read again: the VM and the token are needed.' }
        $Snapshot = Get-AVDTuneVerifiedSnapshot -Arm $Arm -Token $Token -Vm $Vm -Id ([string]$Snapshot.Id)
    }
    # without -Arm what the caller says is taken as it is: only the test mode (Test-AVDTuneTestMode, the one decision) may do that
    elseif (-not (Test-AVDTuneTestMode).Enabled) { throw 'The snapshot gate needs Azure to read the snapshot again (-Arm); without it only the test mode may confirm.' }
    if ([string]$Snapshot.State -ne 'Succeeded' -or -not $Snapshot.Created -or ($Snapshot.PSObject.Properties['Finished'] -and -not $Snapshot.Finished)) { throw 'Only a finished snapshot can be confirmed.' }
    $last = Get-AVDTuneLastChange -Root $Root
    $window = Get-AVDTuneSnapshotWindow -Root $Root
    $fit = Test-AVDTuneSnapshotInWindow -Created $Snapshot.Created -Id ([string]$Snapshot.Id) -Window $window
    if (-not $fit.Valid) {
        throw "The snapshot $($Snapshot.Name) ($(([datetime]$Snapshot.Created).ToString('yyyy-MM-dd HH:mm'))) does not count: $($fit.Reason) Choose another snapshot or create a new one."
    }
    $check = Test-AVDTuneConfirmationName -Typed $TypedName
    if (-not $check.Ok) { throw $check.Message }
    $name = Remove-AVDTuneControlCharacters (([regex]::Replace($TypedName, '\s+', ' ')).Trim()) 100
    $ms = Remove-AVDTuneControlCharacters $SignedInAccount 120; if (-not $ms) { $ms = 'not signed in' }
    $win = Remove-AVDTuneControlCharacters $WindowsAccount 120
    $now = (& $Machine.Now)
    $record = [pscustomobject][ordered]@{
        SnapshotName = $Snapshot.Name; SnapshotId = $Snapshot.Id; SnapshotCreated = ([datetime]$Snapshot.Created).ToString('o'); CreatedByAVDTune = [bool]$Snapshot.ByAVDTune
        ConfirmedBy = $name; SignedInAccount = $ms; WindowsAccount = $win; ConfirmedAt = $now.ToString('o'); ImageVersion = $ImageVersion
        LastChange = $(if ($last) { $last.ToString('o') } else { $null }); Mode = $window.Mode; SnapshotKind = $fit.Kind
        FirstChange = $(if ($window.FirstChange) { ([datetime]$window.FirstChange).ToString('o') } else { $null })
        PreviousVersionEnd = $(if ($window.Lower) { ([datetime]$window.Lower).ToString('o') } else { $null }); Text = $script:ConfirmationText
    }
    [void](Set-AVDTuneState -Root $Root -Values @{ SnapshotGate = $record })
    $made = if ($Snapshot.ByAVDTune) { 'yes' } else { 'no' }
    $text = "Snapshot $($Snapshot.Name) confirmed by $name (Microsoft account $ms, Windows account $win) at $($now.ToString('yyyy-MM-dd HH:mm')); created $(([datetime]$Snapshot.Created).ToString('yyyy-MM-dd HH:mm')); created by AVDTune: $made; $(if ($window.Mode -eq 'Reconnect') { "reconnect in version $ImageVersion (first change $(([datetime]$window.FirstChange).ToString('yyyy-MM-dd HH:mm'))): $(if ($fit.Kind -eq 'CurrentState') { 'snapshot of the current state after the last change, rollback goes back to this current state' } else { 'rollback goes back to the start of the version' })" } else { "start of version $ImageVersion" })"
    [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $ImageVersion -Category 'Snapshot' -Component 'OS disk' -ChangeType $(if ($Snapshot.ByAVDTune) { 'Added' } else { 'Note' }) -Text $text -User $name -SnapshotId $Snapshot.Id -Source Step -At $now)
    Open-AVDTuneWriteGate -SnapshotId $Snapshot.Id -ConfirmedBy $name -SnapshotCreated ([datetime]$Snapshot.Created).ToString('o')
    $record
}

#endregion

#region snapshot housekeeping and the image versions of the gallery (plan 7a, issue #91)

$script:GalleryApi = '2023-07-03'
$script:CleanupRegexTimeout = [TimeSpan]::FromSeconds(1)
$script:GalleryDefinitionIdPattern = '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._()-]+/providers/Microsoft\.Compute/galleries/[A-Za-z0-9._()-]+/images/[A-Za-z0-9._()-]+$'
$script:SnapshotIdPattern = '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._()-]+/providers/Microsoft\.Compute/snapshots/[A-Za-z0-9._-]{1,80}$'

function Get-AVDTuneGalleryVersions {
    <#
        Read only: the image versions of the gallery image definition the image is captured into (environment.json Gallery.ImageDefinitionId), newest first:
        Name (major.minor.patch), Published (publishingProfile.publishedDate, local time), Regions (target regions), State. The imaging tool (Hydra for AVD or
        another) writes them; AVDTune only reads. Paging through nextLink on the ARM host only, at most 10 pages, 500 versions.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$DefinitionId)
    if ($DefinitionId.Length -gt 400 -or $DefinitionId -notmatch $script:GalleryDefinitionIdPattern) { throw 'That is not the Resource ID of a gallery image definition.' }
    $ro = New-AVDTuneReadOnlyArm -Arm $Arm
    $path = "$DefinitionId/versions?api-version=$($script:GalleryApi)"
    $found = New-Object System.Collections.ArrayList
    for ($page = 0; $path -and $page -lt 10 -and $found.Count -lt 500; $page++) {
        $body = Invoke-AVDTuneArm -Arm $ro -Method GET -Path $path -Token $Token -Action 'Microsoft.Compute/galleries/images/versions/read' -Scope 'the image definition'
        foreach ($v in @(Get-AVDTuneProp $body 'value')) {
            if (-not $v) { continue }
            $name = [string](Get-AVDTuneProp $v 'name')
            if ($name -notmatch '^\d{1,9}\.\d{1,9}\.\d{1,9}$') { continue }
            $p = Get-AVDTuneProp $v 'properties'; $pub = Get-AVDTuneProp $p 'publishingProfile'
            $published = $null
            $raw = [string](Get-AVDTuneProp $pub 'publishedDate')
            if ($raw) { try { $published = ([datetime]::Parse($raw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).ToLocalTime() } catch { } }
            $regions = @(@(Get-AVDTuneProp $pub 'targetRegions') | Where-Object { $_ } | ForEach-Object { ([string](Get-AVDTuneProp $_ 'name')).Trim() } | Where-Object { $_ -match '^[A-Za-z0-9 ]{2,40}$' } | Select-Object -First 30)
            $state = [string](Get-AVDTuneProp $p 'provisioningState'); if ($state -notmatch '^[A-Za-z]{1,30}$') { $state = '' }
            [void]$found.Add([pscustomobject]@{ Name = $name; Published = $published; Regions = $regions; State = $state })
        }
        $next = [string](Get-AVDTuneProp $body 'nextLink')
        $path = if ($next) { ConvertTo-AVDTuneArmPath $next } else { $null }
    }
    @($found | Sort-Object { if ($_.Published) { $_.Published } else { [datetime]::MinValue } } -Descending)
}

function Add-AVDTuneGalleryVersionEntries {
    <#
        Plan 7a, after the imaging: every gallery version that was published after the finish of an image version and is not in the change log yet gets one
        entry (category Imaging, component "gallery <name>") in the change log of the newest version finished before it was published: gallery version, date,
        replicated regions. A gallery version without a finished version before it is not recorded. Returns the new entries.
    #>
    param([string]$Root = (Get-AVDTuneRoot), $GalleryVersions, [string]$User)
    $state = Get-AVDTuneState $Root
    $finished = @(foreach ($v in @(@(Get-AVDTuneProp $state 'Versions') | Where-Object { $_ })) {
            $f = ConvertTo-AVDTuneUtc (Get-AVDTuneProp $v 'Finished')
            if ($f -and (Test-AVDTuneImageVersion ([string]$v.Version))) { [pscustomobject]@{ Version = [string]$v.Version; Finished = $f.ToLocalTime() } }
        }) | Sort-Object Finished
    $known = @(Get-AVDTuneChangeLog -Root $Root | Where-Object { $_.Category -eq 'Imaging' } | ForEach-Object { [string]$_.Component })
    $added = New-Object System.Collections.ArrayList
    foreach ($g in @($GalleryVersions | Where-Object { $_ -and $_.Published } | Sort-Object Published)) {
        $component = "gallery $($g.Name)"
        if ($known -contains $component) { continue }
        $owner = @($finished | Where-Object { $_.Finished -le $g.Published } | Select-Object -Last 1)
        if ($owner.Count -eq 0) { continue }
        $text = "Image version $($g.Name) in the Azure Compute Gallery, published $($g.Published.ToString('yyyy-MM-dd HH:mm'))$(if (@($g.Regions).Count) { ", replicated to $(@($g.Regions) -join ', ')" }), made by the imaging tool after the finish of $($owner[0].Version) ($($owner[0].Finished.ToString('yyyy-MM-dd HH:mm')))."
        [void]$added.Add((Add-AVDTuneChangeLogEntry -Root $Root -Version $owner[0].Version -Category 'Imaging' -Component $component -ChangeType 'Note' -Text $text -User $User -Source Step))
        $known += $component
    }
    @($added)
}

function ConvertTo-AVDTuneSnapshotNameRegex {
    # Pure. The regex of the names the pattern of the environment makes (tokens filled with the disk and VM names, the date parts and {N} as digits); '' for a pattern that is not valid
    param([string]$Pattern, [string]$OsDiskName, [string]$VmName)
    if (-not $Pattern -or (Test-AVDTuneSnapshotNamePattern $Pattern)) { return '' }
    $clean = { param($v) [regex]::Escape([regex]::Replace([string]$v, '[^A-Za-z0-9_.-]', '-')) }
    $map = @{ OsDisk = (& $clean $OsDiskName); VM = (& $clean $VmName); ImageVersion = '\d{4}\.\d{2}\.\d{3}'; YYYY = '\d{4}'; MM = '\d{2}'; DD = '\d{2}'; N = '\d{1,6}' }
    $parts = [regex]::Split($Pattern, '(\{(?:' + ($script:SnapshotNameTokens -join '|') + ')\})')
    '\A' + (@(foreach ($p in $parts) { if ($p -match '^\{(\w+)\}$' -and $map.ContainsKey($Matches[1])) { $map[$Matches[1]] } else { [regex]::Escape($p) } }) -join '') + '\z'
}

function Get-AVDTuneSnapshotCleanupSettings {
    # The settings of the housekeeping (config\snapshot-cleanup.json): Keep (newest N kept, 1-50, default 2), MinAgeDays (0-3650, default 7); a value of the wrong type or range is the default
    param([string]$Root = (Get-AVDTuneRoot))
    $o = $null; try { $o = Read-AVDTuneJson (Join-Path $Root 'config\snapshot-cleanup.json') } catch { }
    $num = { param($v, $min, $max, $def) if (($v -is [int] -or $v -is [long]) -and $v -ge $min -and $v -le $max) { [int]$v } else { $def } }
    [pscustomobject]@{ Keep = (& $num (Get-AVDTuneProp $o 'Keep') 1 50 2); MinAgeDays = (& $num (Get-AVDTuneProp $o 'MinAgeDays') 0 3650 7) }
}

function Set-AVDTuneSnapshotCleanupSettings {
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][ValidateRange(1, 50)][int]$Keep, [Parameter(Mandatory)][ValidateRange(0, 3650)][int]$MinAgeDays)
    Write-AVDTuneFile (Join-Path $Root 'config\snapshot-cleanup.json') ([ordered]@{ Keep = $Keep; MinAgeDays = $MinAgeDays } | ConvertTo-Json)
    Get-AVDTuneSnapshotCleanupSettings -Root $Root
}

function Get-AVDTuneSnapshotCleanupPlan {
    <#
        Pure. Which snapshots of the OS disk may go (plan 7a, snapshot housekeeping), each with Delete and Reason. A snapshot is KEPT when it is
        not finished; the confirmed snapshot of the gate (state.json SnapshotGate, the open write gate); the snapshot of the running image version (its tag
        ImageVersion, FirstChangeSnapshotId); not made by AVDTune (tag CreatedWith) and not named by the pattern of the environment (AVDTune never deletes
        those); one of the newest -Keep finished snapshots; younger than -MinAgeDays; or no image version in the gallery was published after it. Only what
        passes all of these is offered for deletion.
    #>
    param($Snapshots, $State, $GalleryVersions, [string]$GalleryProblem, [ValidateRange(1, 50)][int]$Keep = 2, [ValidateRange(0, 3650)][int]$MinAgeDays = 7,
        [string]$NamePattern = $script:DefaultSnapshotNamePattern, [string]$OsDiskName, [string]$VmName, $GateSnapshotId, [datetime]$Now = (Get-Date))
    $confirmed = @([string](Get-AVDTuneProp (Get-AVDTuneProp $State 'SnapshotGate') 'SnapshotId'), [string]$GateSnapshotId) | Where-Object { $_ }
    $running = [string](Get-AVDTuneProp $State 'ImageVersion')
    $firstId = [string](Get-AVDTuneProp $State 'FirstChangeSnapshotId')
    $regex = ConvertTo-AVDTuneSnapshotNameRegex -Pattern $NamePattern -OsDiskName $OsDiskName -VmName $VmName
    $finished = @(@($Snapshots) | Where-Object { $_ -and $_.Finished -and $_.Created } | Sort-Object Created -Descending)
    $newest = @($finished | Select-Object -First $Keep | ForEach-Object { [string]$_.Id })
    $gallery = @(@($GalleryVersions) | Where-Object { $_ -and $_.Published } | Sort-Object Published -Descending)
    $rows = foreach ($s in @(@($Snapshots) | Where-Object { $_ })) {
        $named = $false
        if ($regex) { try { $named = [regex]::IsMatch([string]$s.Name, $regex, [Text.RegularExpressions.RegexOptions]::IgnoreCase, $script:CleanupRegexTimeout) } catch { $named = $false } }
        $age = if ($s.Created) { ($Now - [datetime]$s.Created).TotalDays } else { $null }
        $newer = @(if ($s.Created) { $gallery | Where-Object { $_.Published -gt [datetime]$s.Created } | Select-Object -First 1 })
        $reason = if (-not $s.Finished -or -not $s.Created) { 'Not finished: kept.' }
        elseif ($confirmed | Where-Object { $_ -ieq [string]$s.Id }) { 'The confirmed snapshot of the snapshot gate: kept.' }
        elseif (($firstId -and $firstId -ieq [string]$s.Id) -or ($running -and [string]$s.ImageVersion -eq $running)) { "The snapshot of the running image version $($running): kept." }
        elseif (-not $s.ByAVDTune -and -not $named) { 'Not made by AVDTune and not named by the snapshot name pattern of the environment: AVDTune does not delete it.' }
        elseif ($newest -contains [string]$s.Id) { "One of the newest $Keep finished snapshots: kept." }
        elseif ($null -ne $age -and $age -lt $MinAgeDays) { "Younger than $MinAgeDays days: kept." }
        elseif ($gallery.Count -eq 0) { "No image version of the gallery is known$(if ($GalleryProblem) { " ($GalleryProblem)" }): kept until one newer than the snapshot is found." }
        elseif ($newer.Count -eq 0) { 'No image version in the gallery is newer than this snapshot: kept.' }
        else { '' }
        [pscustomobject]@{ Snapshot = $s; Name = [string]$s.Name; Id = [string]$s.Id; Created = $s.Created; ImageVersion = [string]$s.ImageVersion; ByAVDTune = [bool]$s.ByAVDTune; Named = $named
            Delete = (-not $reason); Reason = $(if ($reason) { $reason } else { "Image version $($newer[0].Name) in the gallery (published $($newer[0].Published.ToString('yyyy-MM-dd HH:mm'))) is newer: can be deleted." }) }
    }
    @($rows)
}

function Remove-AVDTuneOldSnapshots {
    <#
        Deletes the snapshots the administrator confirmed by name (plan 7a; an Azure change, not a change of the master: it needs the open snapshot gate and an open
        image version, sets no LastChange, writes one change log entry per deleted snapshot). Everything is read again from Azure first (snapshots of this disk, gallery
        versions) and planned again: when a confirmed name is no longer offered for deletion nothing is deleted. Each snapshot is read again by ID (it must be one of
        THIS OS disk) right before its DELETE. A refusal (403: no right Microsoft.Compute/snapshots/delete) stops the rest. Returns Deleted, Failed, Message.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)]$Vm, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string[]]$ConfirmedNames,
        [string]$GalleryDefinitionId, [ValidateRange(1, 50)][int]$Keep = 2, [ValidateRange(0, 3650)][int]$MinAgeDays = 7, [string]$NamePattern = $script:DefaultSnapshotNamePattern,
        [string]$User, [datetime]$Now = (Get-Date))
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm the snapshot on the Overview first; old snapshots are deleted only with an open snapshot gate.' }
    Assert-AVDTuneNotSealed -Root $Root
    if (-not $Vm.Available) { throw [string]$Vm.Problem }
    $names = @($ConfirmedNames | Where-Object { $_ } | Select-Object -Unique)
    if ($names.Count -eq 0) { throw 'No snapshot was confirmed for deletion.' }
    $state = Get-AVDTuneState $Root
    $version = [string](Get-AVDTuneProp $state 'ImageVersion')
    if (-not (Test-AVDTuneImageVersion $version)) { throw 'Start an image version first (Overview, Start new version): the change log entries need it.' }
    $snaps = @(Get-AVDTuneOsDiskSnapshots -Arm $Arm -Token $Token -Vm $Vm)
    $gv = @(); $gp = ''
    if ($GalleryDefinitionId) { try { $gv = @(Get-AVDTuneGalleryVersions -Arm $Arm -Token $Token -DefinitionId $GalleryDefinitionId) } catch { $gp = $_.Exception.Message } } else { $gp = 'no gallery image definition chosen' }
    $gate = Get-AVDTuneWriteGate
    $plan = @(Get-AVDTuneSnapshotCleanupPlan -Snapshots $snaps -State $state -GalleryVersions $gv -GalleryProblem $gp -Keep $Keep -MinAgeDays $MinAgeDays -NamePattern $NamePattern -OsDiskName $Vm.OsDiskName -VmName $Vm.VmName -GateSnapshotId $(if ($gate) { [string]$gate.SnapshotId }) -Now $Now)
    $todo = New-Object System.Collections.ArrayList
    foreach ($n in $names) {
        $row = @($plan | Where-Object { $_.Name -ceq $n })
        if ($row.Count -ne 1 -or -not $row[0].Delete) { throw "The snapshot $n is no longer offered for deletion ($(if ($row.Count) { $row[0].Reason } else { 'not found' })). Nothing was deleted; read the list again." }
        if ($row[0].Id -notmatch $script:SnapshotIdPattern) { throw "The snapshot $n has an unexpected resource ID: nothing was deleted." }
        [void]$todo.Add($row[0])
    }
    $deleted = New-Object System.Collections.ArrayList; $failed = New-Object System.Collections.ArrayList; $failedNames = New-Object System.Collections.ArrayList; $message = ''
    foreach ($r in $todo) {
        try {
            $info = Get-AVDTuneVerifiedSnapshot -Arm $Arm -Token $Token -Vm $Vm -Id $r.Id
            if ($info.Name -cne $r.Name) { throw 'Azure answered with another snapshot.' }
            [void](Invoke-AVDTuneArm -Arm $Arm -Method DELETE -Path "$($r.Id)?api-version=$($script:ComputeApi)" -Token $Token -Action 'Microsoft.Compute/snapshots/delete' -Scope "the snapshot $($r.Name)")
            [void]$deleted.Add($r.Name)
            $text = "Snapshot $($r.Name) of the OS disk deleted (created $(([datetime]$r.Created).ToString('yyyy-MM-dd HH:mm'))$(if ($r.ImageVersion) { ", image version $($r.ImageVersion)" })): $($r.Reason)"
            [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $version -Category 'Snapshot' -Component 'OS disk' -ChangeType 'Removed' -Text $text -User $User -SnapshotId $r.Id -Source Step)
        }
        catch {
            [void]$failed.Add("$($r.Name): $($_.Exception.Message)"); [void]$failedNames.Add($r.Name)
            if ($_.Exception.Message -like '*(403)*' -or $_.Exception.Message -like '*(401)*') { $message = $_.Exception.Message; break }
        }
    }
    [pscustomobject]@{ Deleted = @($deleted); Failed = @($failed); Message = $message; Skipped = @($todo | Where-Object { $deleted -notcontains $_.Name -and $failedNames -notcontains $_.Name } | ForEach-Object { $_.Name }) }
}

#endregion

#region what Azure says about this VM (issue #64: read only, before the snapshot is confirmed)

$script:FactsRegexTimeout = [TimeSpan]::FromSeconds(2)
# Azure data is checked with a length limit and a regex with a timeout
function Test-AVDTuneFactsText([string]$Text, [string]$Pattern) { ($Text.Length -le 1024) -and [regex]::IsMatch($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase, $script:FactsRegexTimeout) }
$script:FactsComputeApi = '2024-07-01'
$script:FactsNetworkApi = '2024-01-01'
$script:FactsStorageApi = '2023-05-01'
$script:FactsDnsApi = '2020-06-01'
$script:FactsNicPattern = '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._()-]+/providers/Microsoft\.Network/networkInterfaces/[A-Za-z0-9._()-]+$'
$script:FactsSubnetPattern = '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._()-]+/providers/Microsoft\.Network/virtualNetworks/([A-Za-z0-9._()-]{1,64})/subnets/([A-Za-z0-9._()-]{1,80})$'

function New-AVDTuneReadOnlyArm {
    <# The ARM adapter that only answers GET without a body: anything else is refused before it reaches the real adapter (Status 0, never throws). Everything before the snapshot gate reads through this. #>
    param([Parameter(Mandatory)]$Arm)
    $inner = $Arm
    $a = [ordered]@{ Kind = 'ReadOnly'; Inner = $inner }
    $a.Invoke = {
        param($Method, $Path, $Token, $Body)
        if ([string]$Method -cne 'GET' -or $null -ne $Body) { return [pscustomobject]@{ Status = 0; Body = $null; Error = 'Refused: only GET requests are made before the snapshot gate is open.' } }
        & $inner.Invoke $Method $Path $Token $Body
    }.GetNewClosure()
    [pscustomobject]$a
}

function Get-AVDTuneAzureFacts {
    <#
        What Azure knows about this VM and its surroundings, for prefilling the first-run questions: region, virtual network and subnet of the primary network
        interface, the storage accounts of the resource group (kind, public access, private endpoints, Azure Files identity setting) and whether the resource
        group has the private DNS zone privatelink.file.core.windows.net. Only GET (through New-AVDTuneReadOnlyArm), every name validated before it is used.
        Reachable = $false when the VM itself cannot be read (no connection, 401, 403, 404): then nothing is known and the questions are asked without
        prefill from Azure. A part that cannot be read (for example no right on the storage accounts) is left empty and named in Problems.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)]$Vm)
    $ro = New-AVDTuneReadOnlyArm -Arm $Arm
    $problems = New-Object System.Collections.ArrayList
    $r = [ordered]@{ Reachable = $false; Problem = ''; Region = ''; VNet = ''; Subnet = ''; SubnetId = ''; StorageAccounts = @(); DnsZone = $null; Problems = @() }
    if (-not $Vm.Available) { $r.Problem = [string]$Vm.Problem; return [pscustomobject]$r }
    $rgPath = "/subscriptions/$($Vm.SubscriptionId)/resourceGroups/$($Vm.ResourceGroup)"
    try {
        $body = Invoke-AVDTuneArm -Arm $ro -Method GET -Path "$rgPath/providers/Microsoft.Compute/virtualMachines/$($Vm.VmName)?api-version=$script:FactsComputeApi" -Token $Token -Action 'Microsoft.Compute/virtualMachines/read' -Scope "the VM $($Vm.VmName)"
    }
    catch { $r.Problem = $_.Exception.Message; return [pscustomobject]$r }
    $r.Reachable = $true
    $loc = ([string](Get-AVDTuneProp $body 'location')).Trim().ToLowerInvariant()
    if ($loc -match '^[a-z0-9]{2,40}$') { $r.Region = $loc } elseif ([string]$Vm.Location -match '^[A-Za-z0-9]{2,40}$') { $r.Region = ([string]$Vm.Location).ToLowerInvariant() }
    # primary network interface -> subnet
    try {
        $refs = @(Get-AVDTuneProp (Get-AVDTuneProp (Get-AVDTuneProp $body 'properties') 'networkProfile') 'networkInterfaces' | Where-Object { $_ })
        $ref = @($refs | Where-Object { (Get-AVDTuneProp (Get-AVDTuneProp $_ 'properties') 'primary') -eq $true } | Select-Object -First 1)
        if ($ref.Count -eq 0 -and $refs.Count -gt 0) { $ref = @($refs[0]) }
        if ($ref.Count -gt 0) {
            $nicId = [string](Get-AVDTuneProp $ref[0] 'id')
            if (-not (Test-AVDTuneFactsText $nicId $script:FactsNicPattern)) { throw 'The VM names a network interface with an unexpected ID.' }
            $nic = Invoke-AVDTuneArm -Arm $ro -Method GET -Path "${nicId}?api-version=$script:FactsNetworkApi" -Token $Token -Action 'Microsoft.Network/networkInterfaces/read' -Scope 'the network interface'
            $cfgs = @(Get-AVDTuneProp (Get-AVDTuneProp $nic 'properties') 'ipConfigurations' | Where-Object { $_ })
            $cfg = @($cfgs | Where-Object { (Get-AVDTuneProp (Get-AVDTuneProp $_ 'properties') 'primary') -eq $true } | Select-Object -First 1)
            if ($cfg.Count -eq 0 -and $cfgs.Count -gt 0) { $cfg = @($cfgs[0]) }
            if ($cfg.Count -gt 0) {
                $sid = [string](Get-AVDTuneProp (Get-AVDTuneProp (Get-AVDTuneProp $cfg[0] 'properties') 'subnet') 'id')
                if (Test-AVDTuneFactsText $sid $script:FactsSubnetPattern) { $sm = [regex]::Match($sid, $script:FactsSubnetPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase, $script:FactsRegexTimeout); $r.SubnetId = $sid; $r.VNet = $sm.Groups[1].Value; $r.Subnet = $sm.Groups[2].Value }
                elseif ($sid) { [void]$problems.Add('The subnet ID of the network interface has an unexpected form; it is not used.') }
            }
        }
    }
    catch { [void]$problems.Add("Network: $($_.Exception.Message)") }
    # storage accounts of the resource group
    try {
        $list = Invoke-AVDTuneArm -Arm $ro -Method GET -Path "$rgPath/providers/Microsoft.Storage/storageAccounts?api-version=$script:FactsStorageApi" -Token $Token -Action 'Microsoft.Storage/storageAccounts/read' -Scope "the resource group $($Vm.ResourceGroup)"
        $accounts = New-Object System.Collections.ArrayList
        foreach ($s in @(Get-AVDTuneProp $list 'value' | Where-Object { $_ } | Select-Object -First 50)) {
            $name = [string](Get-AVDTuneProp $s 'name')
            if ($name -cnotmatch '^[a-z0-9]{3,24}$') { continue }
            $p = Get-AVDTuneProp $s 'properties'
            $kind = [string](Get-AVDTuneProp $s 'kind')
            if ($kind -notmatch '^[A-Za-z0-9]{1,30}$') { $kind = '' }
            $pub = [string](Get-AVDTuneProp $p 'publicNetworkAccess'); if ($pub -notin 'Enabled', 'Disabled', 'SecuredByPerimeter') { $pub = '' }
            $dso = [string](Get-AVDTuneProp (Get-AVDTuneProp $p 'azureFilesIdentityBasedAuthentication') 'directoryServiceOptions'); if ($dso -notin 'AADKERB', 'AD', 'AADDS', 'None') { $dso = '' }
            [void]$accounts.Add([pscustomobject]@{ Name = $name; Kind = $kind; PublicAccess = $pub; PrivateEndpoints = @(Get-AVDTuneProp $p 'privateEndpointConnections' | Where-Object { $_ }).Count; IdentityAuth = $dso })
        }
        $r.StorageAccounts = @($accounts)
    }
    catch { [void]$problems.Add("Storage accounts: $($_.Exception.Message)") }
    # private DNS zone for Azure Files in the resource group
    try {
        $zones = Invoke-AVDTuneArm -Arm $ro -Method GET -Path "$rgPath/providers/Microsoft.Network/privateDnsZones?api-version=$script:FactsDnsApi" -Token $Token -Action 'Microsoft.Network/privateDnsZones/read' -Scope "the resource group $($Vm.ResourceGroup)"
        $r.DnsZone = (@(Get-AVDTuneProp $zones 'value' | Where-Object { $_ -and ([string](Get-AVDTuneProp $_ 'name')) -ieq 'privatelink.file.core.windows.net' }).Count -gt 0)
    }
    catch { [void]$problems.Add("Private DNS zones: $($_.Exception.Message)") }
    $r.Problems = @($problems)
    [pscustomobject]$r
}

#endregion

#region real adapter

function New-AVDTuneArmAdapter {
    <#
        The real ARM adapter: HTTPS to management.azure.com only (any other host or a path outside /subscriptions/<id>/ is refused, except
        GET /subscriptions?api-version=... for the list of subscriptions), bearer token,
        no redirects followed, never throws (Status 0 = no connection). Not used by the checks (they use the fake).
    #>
    $adapter = [ordered]@{ Kind = 'Real' }
    $adapter.Invoke = {
        param($Method, $Path, $Token, $Body)
        # A resource path of one subscription, or the list of the subscriptions (GET /subscriptions?api-version=..., readiness: gallery search)
        if (($Path -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/' -and -not ($Method -eq 'GET' -and $Path -match '^/subscriptions\?api-version=')) -or $Path -match '\.\.' -or $Path -match '#' -or [regex]::Matches($Path, '\?').Count -gt 1 -or $Path -match '[\s\x00-\x1F]') { return [pscustomobject]@{ Status = 0; Body = $null; Error = 'Refused: not an ARM resource path.' } }
        # .NET Framework 4.x may still offer TLS 1.0/1.1 by default: TLS 1.2 is asked for explicitly (added, never removed: TLS 1.3 stays when the system has it)
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try {
            $request = [System.Net.HttpWebRequest]::Create("https://management.azure.com$Path")
            $request.Method = $Method; $request.Timeout = 60000; $request.AllowAutoRedirect = $false
            $request.Headers.Add('Authorization', "Bearer $Token")
            $request.Accept = 'application/json'
            if ($null -ne $Body) {
                $bytes = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 8 -Compress))
                $request.ContentType = 'application/json'; $request.ContentLength = $bytes.Length
                $stream = $request.GetRequestStream(); try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            }
            $response = $request.GetResponse()
        }
        catch {
            # An HTTP error answer (400/403/404...) is a response on the inner WebException, not "no connection"
            $response = Get-AVDTuneWebResponse $_.Exception
            if (-not $response) { return [pscustomobject]@{ Status = 0; Body = $null; Error = $_.Exception.Message } }
        }
        try {
            $text = (New-Object IO.StreamReader($response.GetResponseStream())).ReadToEnd()
            $parsed = $null; if ($text.Trim()) { try { $parsed = $text | ConvertFrom-Json } catch { } }
            $hs = @{}; foreach ($k in $response.Headers.AllKeys) { $hs[[string]$k] = [string]$response.Headers[$k] }   # Azure-AsyncOperation, Location, Retry-After of asynchronous operations (environment wizard)
            [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $parsed; Error = ''; Headers = $hs }
        }
        finally { $response.Close() }
    }
    [pscustomobject]$adapter
}

#endregion

Export-ModuleMember -Function Get-AVDTuneVerifiedSnapshot, Get-AVDTuneSnapshotClockBuffer, Get-AVDTuneGateText, Invoke-AVDTuneArm, ConvertTo-AVDTuneArmPath, Get-AVDTuneVmIdentity, Get-AVDTuneDefaultSnapshotNamePattern, Test-AVDTuneSnapshotNamePattern, Get-AVDTuneSnapshotName, Get-AVDTuneOsDiskSnapshots, Get-AVDTuneIncrementalSnapshotSku, Start-AVDTuneSnapshot,
    Get-AVDTuneSnapshotState, Wait-AVDTuneSnapshot, Test-AVDTuneConfirmationName, Get-AVDTuneGateStatus, Confirm-AVDTuneSnapshotGate, New-AVDTuneArmAdapter, New-AVDTuneReadOnlyArm, Get-AVDTuneAzureFacts,
    Get-AVDTuneGalleryVersions, Add-AVDTuneGalleryVersionEntries, ConvertTo-AVDTuneSnapshotNameRegex, Get-AVDTuneSnapshotCleanupPlan, Remove-AVDTuneOldSnapshots, Get-AVDTuneSnapshotCleanupSettings, Set-AVDTuneSnapshotCleanupSettings
