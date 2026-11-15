<#
    AVDTune snapshot gate: nothing changes the master until a snapshot of its OS disk from today exists and the administrator has confirmed it
    by typing the full name. Until then the engine stays read only (Test-AVDTuneWriteAllowed in AVDTune.psm1).

      * The VM finds itself through the instance metadata service (machine adapter member Imds): subscription, resource group, VM, OS disk.
      * Azure Resource Manager is an adapter ($Arm): Invoke = { param($Method, $Path, $Token, $Body) } returns
        @{ Status; Body; Error } and never throws (Status 0 = no connection). New-AVDTuneArmAdapter is the real one (only
        https://management.azure.com), Tests\Fakes\FakeServices.ps1 has the fake.
      * Snapshot: incremental, name <vm>-avdtune-<image version>-<yyyyMMdd-HHmm>, tags ImageVersion, CreatedBy (user), CreatedWith=AVDTune.
      * The confirmation is written to state.json (SnapshotGate), the change log and returned for the protocol: name, time, snapshot ID,
        whether AVDTune made it. The open gate itself lives in memory only; a new start of AVDTune starts closed.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')

$script:ArmHost = 'https://management.azure.com'
$script:ComputeApi = '2023-10-02'
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
    if ($Path.StartsWith('/subscriptions/')) { return $Path }
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
    if ($sub -notmatch '^[0-9a-fA-F-]{36}$' -or -not $rg -or -not $vm) { return (& $none 'The instance metadata has no subscription, resource group or VM name.') }
    if (-not $diskName) { return (& $none 'The instance metadata has no OS disk.') }
    if (-not $diskId) { return (& $none 'The OS disk is not a managed disk; AVDTune can only snapshot managed disks.') }
    if ($diskId -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Compute/disks/[^/]+$') { return (& $none 'The OS disk ID of the instance metadata has an unexpected form.') }
    [pscustomobject]@{
        Available = $true; Problem = ''; SubscriptionId = $sub; ResourceGroup = $rg; VmName = $vm; VmId = [string](Get-AVDTuneProp $c 'vmId')
        Location = [string](Get-AVDTuneProp $c 'location'); OsDiskName = $diskName; OsDiskId = $diskId
    }
}

#endregion

#region snapshots

function Get-AVDTuneSnapshotName {
    # <vm>-avdtune-<image version>-<yyyyMMdd-HHmm>; Azure allows 80 characters of letters, digits, '_', '.', '-'
    param([Parameter(Mandatory)][string]$VmName, [Parameter(Mandatory)][string]$ImageVersion, [Parameter(Mandatory)][datetime]$At)
    if (-not (Test-AVDTuneImageVersion $ImageVersion)) { throw 'Start an image version first (Overview, Start new version): the snapshot name and tags carry it.' }
    $suffix = '-avdtune-{0}-{1}' -f $ImageVersion, $At.ToString('yyyyMMdd-HHmm', [Globalization.CultureInfo]::InvariantCulture)
    $vm = [regex]::Replace($VmName, '[^A-Za-z0-9_.-]', '-').Trim('-', '.')
    if (-not $vm) { $vm = 'vm' }
    if ($vm.Length + $suffix.Length -gt 80) { $vm = $vm.Substring(0, 80 - $suffix.Length).TrimEnd('-', '.') }
    $vm + $suffix
}

function ConvertTo-AVDTuneTagValue([string]$Text) { (Remove-AVDTuneControlCharacters $Text 256) -replace '[<>%&\\?/]', '_' }

function ConvertTo-AVDTuneSnapshotInfo {
    param($Item, [datetime]$Today)
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
        IsToday = [bool]($created -and $created.Date -eq $Today.Date -and $state -eq 'Succeeded')
    }
}

function Get-AVDTuneOsDiskSnapshots {
    <# All snapshots of this OS disk in the VM's resource group (newest first), each with IsToday (succeeded and created today, local time). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)]$Vm, [datetime]$Now = (Get-Date))
    $path = "/subscriptions/$($Vm.SubscriptionId)/resourceGroups/$($Vm.ResourceGroup)/providers/Microsoft.Compute/snapshots?api-version=$($script:ComputeApi)"
    $found = New-Object System.Collections.ArrayList
    for ($page = 0; $path -and $page -lt 20; $page++) {
        $body = Invoke-AVDTuneArm -Arm $Arm -Method GET -Path $path -Token $Token -Action 'Microsoft.Compute/snapshots/read' -Scope "resource group $($Vm.ResourceGroup)"
        foreach ($item in @(Get-AVDTuneProp $body 'value')) {
            if (-not $item) { continue }
            $source = [string](Get-AVDTuneProp (Get-AVDTuneProp (Get-AVDTuneProp $item 'properties') 'creationData') 'sourceResourceId')
            if ($source -ieq $Vm.OsDiskId) { [void]$found.Add((ConvertTo-AVDTuneSnapshotInfo -Item $item -Today $Now)) }
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
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)]$Vm, [Parameter(Mandatory)][string]$ImageVersion, [string]$User, [datetime]$At = (Get-Date))
    $name = Get-AVDTuneSnapshotName -VmName $Vm.VmName -ImageVersion $ImageVersion -At $At
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
    [pscustomobject]@{ Id = $Id; State = [string](Get-AVDTuneProp $p 'provisioningState'); Percent = $(if ($null -ne $percent) { [double]$percent } else { $null }); Info = (ConvertTo-AVDTuneSnapshotInfo -Item $b -Today (Get-Date)) }
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
    <# The typed full name: at least two words; when the sign-in told the name, it must be the same (case and spacing ignored). #>
    param([string]$Typed, [string]$Expected)
    $t = ([regex]::Replace([string]$Typed, '\s+', ' ')).Trim()
    if (@($t -split ' ' | Where-Object { $_ }).Count -lt 2 -or $t.Length -lt 5) { return [pscustomobject]@{ Ok = $false; Message = 'Type your full name (first and last name).' } }
    if ($t -match '[\x00-\x1F]') { return [pscustomobject]@{ Ok = $false; Message = 'The name contains control characters.' } }
    $e = ([regex]::Replace([string]$Expected, '\s+', ' ')).Trim()
    if ($e -and -not [string]::Equals($t, $e, [StringComparison]::OrdinalIgnoreCase)) { return [pscustomobject]@{ Ok = $false; Message = 'The name does not match the account that is signed in. Type it as it is in your Microsoft account.' } }
    [pscustomobject]@{ Ok = $true; Message = '' }
}

function Get-AVDTuneGateStatus {
    <#
        Where the gate stands: NoVm (not Azure / no OS disk), NoSnapshotToday (create one), SnapshotToday (confirm it), Confirmed.
        Snapshots = the snapshots of the OS disk; Chosen = the newest of today.
    #>
    param([Parameter(Mandatory)]$Vm, $Snapshots, [bool]$Confirmed = (Test-AVDTuneWriteAllowed))
    if (-not $Vm.Available) { return [pscustomobject]@{ Status = 'NoVm'; Detail = $Vm.Problem; Chosen = $null; Snapshots = @() } }
    $list = @($Snapshots | Where-Object { $_ })
    $today = @($list | Where-Object { $_.IsToday })
    $chosen = $today | Select-Object -First 1
    if ($Confirmed) { return [pscustomobject]@{ Status = 'Confirmed'; Detail = 'The snapshot is confirmed; the pages can change the master.'; Chosen = $chosen; Snapshots = $list } }
    if ($chosen) { return [pscustomobject]@{ Status = 'SnapshotToday'; Detail = "A snapshot of today exists: $($chosen.Name). Confirm it to unlock the pages."; Chosen = $chosen; Snapshots = $list } }
    [pscustomobject]@{ Status = 'NoSnapshotToday'; Detail = 'No snapshot of the OS disk from today. Create one now.'; Chosen = $null; Snapshots = $list }
}

function Confirm-AVDTuneSnapshotGate {
    <#
        Confirmation of a snapshot of today by the typed full name. Writes SnapshotGate into state.json and an entry into the change log
        (name, time, snapshot ID, created by AVDTune yes/no), then opens the write gate of the engine. Returns the record for the protocol.
    #>
    [CmdletBinding()]
    param(
        [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)][string]$TypedName, [string]$ExpectedName, [string]$User,
        [Parameter(Mandatory)][string]$ImageVersion, [Parameter(Mandatory)]$Machine, [string]$VmName
    )
    if (-not $Snapshot.IsToday) { throw 'Only a finished snapshot of today can be confirmed.' }
    $check = Test-AVDTuneConfirmationName -Typed $TypedName -Expected $ExpectedName
    if (-not $check.Ok) { throw $check.Message }
    $name = ([regex]::Replace($TypedName, '\s+', ' ')).Trim()
    $now = (& $Machine.Now)
    $record = [pscustomobject][ordered]@{
        SnapshotName = $Snapshot.Name; SnapshotId = $Snapshot.Id; SnapshotCreated = $Snapshot.Created.ToString('o'); CreatedByAVDTune = [bool]$Snapshot.ByAVDTune
        ConfirmedBy = $name; ConfirmedAt = $now.ToString('o'); ImageVersion = $ImageVersion; User = $User; Text = $script:ConfirmationText
    }
    [void](Set-AVDTuneState -Root $Root -Values @{ SnapshotGate = $record })
    $made = if ($Snapshot.ByAVDTune) { 'yes' } else { 'no' }
    $text = "Snapshot $($Snapshot.Name) confirmed by $name at $($now.ToString('yyyy-MM-dd HH:mm')); created $($Snapshot.Created.ToString('yyyy-MM-dd HH:mm')); created by AVDTune: $made"
    [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $ImageVersion -Category 'Snapshot' -Component 'OS disk' -ChangeType $(if ($Snapshot.ByAVDTune) { 'Added' } else { 'Note' }) -Text $text -User $User -SnapshotId $Snapshot.Id -Source Step -At $now)
    Open-AVDTuneWriteGate -SnapshotId $Snapshot.Id -ConfirmedBy $name
    $record
}

#endregion

#region real adapter

function New-AVDTuneArmAdapter {
    <#
        The real ARM adapter: HTTPS to management.azure.com only (any other host or a path outside /subscriptions is refused), bearer token,
        no redirects followed, never throws (Status 0 = no connection). Not used by the checks (they use the fake).
    #>
    $adapter = [ordered]@{ Kind = 'Real' }
    $adapter.Invoke = {
        param($Method, $Path, $Token, $Body)
        if ($Path -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/' -or $Path -match '\.\.' -or $Path -match '[\s\x00-\x1F]') { return [pscustomobject]@{ Status = 0; Body = $null; Error = 'Refused: not an ARM resource path.' } }
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
            $response = Get-AVDTuneProp $_.Exception 'Response'
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

Export-ModuleMember -Function Get-AVDTuneGateText, Invoke-AVDTuneArm, Get-AVDTuneVmIdentity, Get-AVDTuneSnapshotName, Get-AVDTuneOsDiskSnapshots, Start-AVDTuneSnapshot,
    Get-AVDTuneSnapshotState, Wait-AVDTuneSnapshot, Test-AVDTuneConfirmationName, Get-AVDTuneGateStatus, Confirm-AVDTuneSnapshotGate, New-AVDTuneArmAdapter
