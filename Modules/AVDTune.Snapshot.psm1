<#
    AVDTune snapshot gate: nothing changes the master until a finished snapshot of its OS disk exists that is newer than the last change
    AVDTune made on the master (Get-AVDTuneLastChange; with no change recorded yet any finished snapshot counts; user decision 2026-11-15),
    and the administrator has confirmed it by typing first and last name (not matched against the sign-in: shared admin accounts are
    used). Until then the engine stays read only (Test-AVDTuneWriteAllowed in AVDTune.psm1).

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
# The snapshot time comes from Azure, the last change from the clock of this VM: a snapshot must be at least this many minutes newer, so a
# clock of the VM that runs a few minutes behind cannot make a snapshot from before the change look newer
$script:ClockBufferMinutes = 10
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
    # Valid: finished (Succeeded) and at least ClockBufferMinutes newer than the last change of AVDTune on the master (any finished one when there was none)
    param($Item, $LastChange)
    $p = Get-AVDTuneProp $Item 'properties'
    $tags = Get-AVDTuneProp $Item 'tags'
    $created = $null
    $raw = Get-AVDTuneProp $p 'timeCreated'
    if ($raw) { try { $created = ([datetime]::Parse([string]$raw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).ToLocalTime() } catch { } }
    $state = [string](Get-AVDTuneProp $p 'provisioningState')
    $byTool = ([string](Get-AVDTuneProp $tags 'CreatedWith') -eq 'AVDTune')
    [pscustomobject]@{
        Name = [string](Get-AVDTuneProp $Item 'name'); Id = [string](Get-AVDTuneProp $Item 'id'); Created = $created; State = $state
        Incremental = [bool](Get-AVDTuneProp $p 'incremental'); ByAVDTune = $byTool
        ImageVersion = [string](Get-AVDTuneProp $tags 'ImageVersion'); CreatedBy = [string](Get-AVDTuneProp $tags 'CreatedBy')
        Finished = ($state -eq 'Succeeded')
        Valid = [bool]($created -and $state -eq 'Succeeded' -and ($null -eq $LastChange -or $created.ToUniversalTime() -gt ([datetime]$LastChange).ToUniversalTime().AddMinutes($script:ClockBufferMinutes)))
    }
}

function Get-AVDTuneOsDiskSnapshots {
    <# All snapshots of this OS disk in the VM's resource group (newest first), each with Valid (finished and newer than -LastChange). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)]$Vm, $LastChange)
    $path = "/subscriptions/$($Vm.SubscriptionId)/resourceGroups/$($Vm.ResourceGroup)/providers/Microsoft.Compute/snapshots?api-version=$($script:ComputeApi)"
    $found = New-Object System.Collections.ArrayList
    for ($page = 0; $path -and $page -lt 20; $page++) {
        $body = Invoke-AVDTuneArm -Arm $Arm -Method GET -Path $path -Token $Token -Action 'Microsoft.Compute/snapshots/read' -Scope "resource group $($Vm.ResourceGroup)"
        foreach ($item in @(Get-AVDTuneProp $body 'value')) {
            if (-not $item) { continue }
            $source = [string](Get-AVDTuneProp (Get-AVDTuneProp (Get-AVDTuneProp $item 'properties') 'creationData') 'sourceResourceId')
            if ($source -ieq $Vm.OsDiskId) { [void]$found.Add((ConvertTo-AVDTuneSnapshotInfo -Item $item -LastChange $LastChange)) }
        }
        $next = [string](Get-AVDTuneProp $body 'nextLink')
        $path = if ($next) { ConvertTo-AVDTuneArmPath $next } else { $null }
    }
    @($found | Sort-Object { if ($_.Created) { $_.Created } else { [datetime]::MinValue } } -Descending)
}

function Start-AVDTuneSnapshot {
    <#
        Starts an incremental snapshot of the OS disk. Returns Name, Id and State immediately; the snapshot is usable when
        Get-AVDTuneSnapshotState says Succeeded. The disk is read first (it must exist and tells the location).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)]$Vm, [Parameter(Mandatory)][string]$ImageVersion, [string]$User, [datetime]$At = (Get-Date),
        [string]$NamePattern = $script:DefaultSnapshotNamePattern, [string[]]$ExistingNames = @())
    if (-not (Test-AVDTuneImageVersion $ImageVersion)) { throw 'Start an image version first (Overview, Start new version): the snapshot tags carry it.' }
    $name = Get-AVDTuneSnapshotName -Pattern $NamePattern -OsDiskName $Vm.OsDiskName -VmName $Vm.VmName -ImageVersion $ImageVersion -At $At -ExistingNames $ExistingNames
    $diskBody = Invoke-AVDTuneArm -Arm $Arm -Method GET -Path "$($Vm.OsDiskId)?api-version=$($script:ComputeApi)" -Token $Token -Action 'Microsoft.Compute/disks/read' -Scope "the OS disk $($Vm.OsDiskName)"
    $location = [string](Get-AVDTuneProp $diskBody 'location'); if (-not $location) { $location = $Vm.Location }
    $id = "/subscriptions/$($Vm.SubscriptionId)/resourceGroups/$($Vm.ResourceGroup)/providers/Microsoft.Compute/snapshots/$name"
    $body = [ordered]@{
        location = $location
        sku = @{ name = 'Standard_LRS' }
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
    [pscustomobject]@{ Id = $Id; State = [string](Get-AVDTuneProp $p 'provisioningState'); Percent = $(if ($null -ne $percent) { [double]$percent } else { $null }); Info = (ConvertTo-AVDTuneSnapshotInfo -Item $b -LastChange $null) }
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
        Snapshots = the snapshots of the OS disk; Chosen = the newest valid one (finished and newer than the last change of AVDTune).
    #>
    param([Parameter(Mandatory)]$Vm, $Snapshots, [bool]$Confirmed = (Test-AVDTuneWriteAllowed), $LastChange)
    if (-not $Vm.Available) { return [pscustomobject]@{ Status = 'NoVm'; Detail = $Vm.Problem; Chosen = $null; Snapshots = @() } }
    $list = @($Snapshots | Where-Object { $_ })
    $valid = @($list | Where-Object { $_.Valid })
    $chosen = $valid | Select-Object -First 1
    $since = if ($LastChange) { "made at least $($script:ClockBufferMinutes) minutes after the last change by AVDTune ($(([datetime]$LastChange).ToString('yyyy-MM-dd HH:mm')); the margin covers a clock of this VM that runs behind Azure)" } else { 'that is finished (AVDTune has not changed this master yet)' }
    if ($Confirmed) { return [pscustomobject]@{ Status = 'Confirmed'; Detail = 'The snapshot is confirmed; the pages can change the master.'; Chosen = $chosen; Snapshots = $list } }
    if ($chosen) { return [pscustomobject]@{ Status = 'SnapshotReady'; Detail = "A snapshot $since exists: $($chosen.Name). Confirm it to unlock the pages."; Chosen = $chosen; Snapshots = $list } }
    [pscustomobject]@{ Status = 'NoValidSnapshot'; Detail = "No snapshot of the OS disk $since. Create one now."; Chosen = $null; Snapshots = $list }
}

function Confirm-AVDTuneSnapshotGate {
    <#
        Confirmation of a valid snapshot by the typed name. Checks again that the snapshot is finished and newer than the last change of AVDTune
        (Get-AVDTuneLastChange, read from state.json, runs and change log now). Writes SnapshotGate into state.json and an entry into the change
        log (typed name, signed-in Microsoft account, local Windows account, time, snapshot ID, created by AVDTune yes/no), then opens the
        write gate of the engine. Returns the record for the protocol.
    #>
    [CmdletBinding()]
    param(
        [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)][string]$TypedName, [string]$SignedInAccount,
        [string]$WindowsAccount = "$env:USERDOMAIN\$env:USERNAME", [Parameter(Mandatory)][string]$ImageVersion, [Parameter(Mandatory)]$Machine
    )
    if ([string]$Snapshot.State -ne 'Succeeded' -or -not $Snapshot.Created) { throw 'Only a finished snapshot can be confirmed.' }
    $last = Get-AVDTuneLastChange -Root $Root
    if ($last -and ([datetime]$Snapshot.Created).ToUniversalTime() -le $last.ToUniversalTime().AddMinutes($script:ClockBufferMinutes)) {
        throw "The snapshot $($Snapshot.Name) ($(([datetime]$Snapshot.Created).ToString('yyyy-MM-dd HH:mm'))) is older than the last change AVDTune made on this master ($($last.ToString('yyyy-MM-dd HH:mm'))) plus $($script:ClockBufferMinutes) minutes for clock differences between this VM and Azure: a rollback to it could lose that change. Create a new snapshot."
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
        LastChange = $(if ($last) { $last.ToString('o') } else { $null }); Text = $script:ConfirmationText
    }
    [void](Set-AVDTuneState -Root $Root -Values @{ SnapshotGate = $record })
    $made = if ($Snapshot.ByAVDTune) { 'yes' } else { 'no' }
    $text = "Snapshot $($Snapshot.Name) confirmed by $name (Microsoft account $ms, Windows account $win) at $($now.ToString('yyyy-MM-dd HH:mm')); created $(([datetime]$Snapshot.Created).ToString('yyyy-MM-dd HH:mm')); created by AVDTune: $made"
    [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $ImageVersion -Category 'Snapshot' -Component 'OS disk' -ChangeType $(if ($Snapshot.ByAVDTune) { 'Added' } else { 'Note' }) -Text $text -User $name -SnapshotId $Snapshot.Id -Source Step -At $now)
    Open-AVDTuneWriteGate -SnapshotId $Snapshot.Id -ConfirmedBy $name
    $record
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
            [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $parsed; Error = '' }
        }
        finally { $response.Close() }
    }
    [pscustomobject]$adapter
}

#endregion

Export-ModuleMember -Function Get-AVDTuneSnapshotClockBuffer, Get-AVDTuneGateText, Invoke-AVDTuneArm, ConvertTo-AVDTuneArmPath, Get-AVDTuneVmIdentity, Get-AVDTuneDefaultSnapshotNamePattern, Test-AVDTuneSnapshotNamePattern, Get-AVDTuneSnapshotName, Get-AVDTuneOsDiskSnapshots, Start-AVDTuneSnapshot,
    Get-AVDTuneSnapshotState, Wait-AVDTuneSnapshot, Test-AVDTuneConfirmationName, Get-AVDTuneGateStatus, Confirm-AVDTuneSnapshotGate, New-AVDTuneArmAdapter
