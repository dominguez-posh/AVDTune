<#
    AVDTune readiness analysis and image hygiene (docs\plans\avdtune.md, sections 1c, 2a, 7a): is this master set up for the current VM sizes (v6/v7 and later)
    and is it clean enough to become an image? Read only. Part of the first analysis and of the healthcheck before "Abschliessen".

      * The criteria are data (readiness.json at the root of the tool): for each one a source (Microsoft Learn), the date it was read and whether Learn
        really states it (Verified). What Learn does not state is marked Verified=false and said so in the result; nothing is guessed.
      * Every access to the machine goes through the machine adapter ($Machine, Tests\Fakes\FakeMachine.ps1 has the fake), every access to Azure through
        the ARM adapter ($Arm, AVDTune.Snapshot.psm1). No ARM access (not signed in, 403, offline) makes the Azure based checks "unknown" (not checkable),
        never green and never a crash: a check that throws becomes "unknown" with the reason.
      * Row status: green, yellow, red, unknown, info (info is not counted). Red blocks "Abschliessen", yellow and unknown need a confirmation that
        names every open item (Confirm-AVDTuneReadinessAcknowledgement). Overall: red, else yellow (also for unknown), else green.
      * Fixes only where safe and documented: stornvme to boot (the step of the Learn conversion script) and the update block on (#6). Both are steps behind
        the write gate (snapshot confirmed), with a run record and a change log entry. Everything else is only a hint.
      * Every run is stored: run record (runs\), state.json (Readiness) and, for a named kind, a change log entry. Nothing here writes to the master.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Snapshot.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.UpdateBlock.psm1')

$script:ComputeApi = '2024-07-01'
$script:NetworkApi = '2024-01-01'
$script:GalleryApi = '2023-07-03'
$script:GalleryPattern = '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Compute/galleries/[^/]+/images/[^/]+$'
$script:NicPattern = '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Network/networkInterfaces/[^/]+$'
$script:Kinds = @('Start', 'Erstanalyse', 'Healthcheck', 'Manual')

#region data

function Get-AVDTuneReadinessDataPath { Join-Path (Split-Path $PSScriptRoot -Parent) 'readiness.json' }

function Get-AVDTuneReadinessData {
    <# Loads and checks readiness.json: every criterion needs an https Learn source, a date and the Verified flag (with a note when false). #>
    [CmdletBinding()]
    param([string]$Path = (Get-AVDTuneReadinessDataPath))
    $d = Read-AVDTuneJson $Path
    if ($null -eq $d) { throw "The readiness data is missing or empty: $Path" }
    if ([int](Get-AVDTuneProp $d 'Schema') -ne 1) { throw 'readiness.json has an unknown schema.' }
    if ([string](Get-AVDTuneProp $d 'Stand') -notmatch '^\d{4}-\d{2}-\d{2}$') { throw 'readiness.json needs a Stand date (yyyy-MM-dd).' }
    $criteria = Get-AVDTuneProp $d 'Criteria'
    if (-not $criteria) { throw 'readiness.json has no criteria.' }
    foreach ($p in $criteria.PSObject.Properties) {
        $c = $p.Value
        if (-not (Get-AVDTuneProp $c 'Title')) { throw "Criterion $($p.Name) has no title." }
        if ([string](Get-AVDTuneProp $c 'Source') -notmatch '^https://learn\.microsoft\.com/') { throw "Criterion $($p.Name) needs a Microsoft Learn source (https://learn.microsoft.com/...)." }
        if ([string](Get-AVDTuneProp $c 'Stand') -notmatch '^\d{4}-\d{2}-\d{2}$') { throw "Criterion $($p.Name) needs a Stand date." }
        if ((Get-AVDTuneProp $c 'Verified') -isnot [bool]) { throw "Criterion $($p.Name) needs Verified true or false." }
        if (-not (Get-AVDTuneProp $c 'Verified') -and -not (Get-AVDTuneProp $c 'Note')) { throw "Criterion $($p.Name) is not verified and needs a note that says why." }
    }
    foreach ($f in @($d.Families)) {
        foreach ($n in 'Name', 'SizePattern', 'Generation', 'Arch', 'TempDisk', 'Network') { if ($null -eq (Get-AVDTuneProp $f $n)) { throw "A family in readiness.json misses $n." } }
        if ([string]$f.Arch -notin 'x64', 'Arm64') { throw "Family $($f.Name): Arch must be x64 or Arm64." }
        [void][regex]::new([string]$f.SizePattern)
    }
    foreach ($b in @($d.Windows.Builds)) { foreach ($n in 'Build', 'Latest', 'EndOfUpdates') { if (-not (Get-AVDTuneProp $b $n)) { throw "A Windows build in readiness.json misses $n." } } }
    $d
}

function ConvertTo-AVDTuneGalleryImageId {
    # A gallery image definition ID, or $null; a version suffix (/versions/x) is dropped
    param([string]$Text)
    $t = ([string]$Text).Trim()
    if (-not $t) { return $null }
    $t = $t -replace '/versions/[^/]+/?$', ''
    $t = $t.TrimEnd('/')
    if ($t -match $script:GalleryPattern) { $t } else { $null }
}

#endregion

#region rows

function New-AVDTuneReadinessRow {
    param([Parameter(Mandatory)]$Data, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Group,
        [Parameter(Mandatory)][ValidateSet('green', 'yellow', 'red', 'unknown', 'info')][string]$Status, [Parameter(Mandatory)][string]$Reason, [string]$Fix, [string]$FixId, [string]$Found)
    $c = Get-AVDTuneProp $Data.Criteria $Id
    if (-not $c) { throw "No criterion $Id in readiness.json." }
    [pscustomobject]@{
        Id = $Id; Group = $Group; Title = [string]$c.Title; Status = $Status; Reason = $Reason; Fix = $Fix; FixId = $FixId; Found = $Found
        Source = [string]$c.Source; Stand = [string]$c.Stand; Verified = [bool]$c.Verified; Note = [string](Get-AVDTuneProp $c 'Note')
    }
}

#endregion

#region Azure reads

function Get-AVDTuneReadinessArm {
    <#
        What Azure says about this VM: the VM (size, disk controller, security), its NICs and the gallery image definition. Never throws: Ok = $false and
        Problem say why a part is not checkable. -GalleryImageId is the definition to check (setting); without it the VM's own image reference is used
        when it is a gallery image.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, $Arm, [string]$Token, [string]$NoTokenReason, [string]$GalleryImageId)
    $r = [ordered]@{ Ok = $false; Problem = ''; Vm = $null; Nics = @(); NicProblem = ''; Gallery = $null; GalleryId = ''; GalleryProblem = '' }
    $id = Get-AVDTuneVmIdentity $Machine
    if (-not $id.Available) { $r.Problem = $id.Problem; return [pscustomobject]$r }
    if (-not $Arm) { $r.Problem = 'No Azure access is configured (no Azure Resource Manager adapter).'; return [pscustomobject]$r }
    if (-not $Token) { $r.Problem = $(if ($NoTokenReason) { $NoTokenReason } else { 'Not signed in: sign in on the Overview to read the VM settings from Azure.' }); return [pscustomobject]$r }
    try {
        $path = "/subscriptions/$($id.SubscriptionId)/resourceGroups/$($id.ResourceGroup)/providers/Microsoft.Compute/virtualMachines/$($id.VmName)?api-version=$($script:ComputeApi)&`$expand=instanceView"
        $r.Vm = Invoke-AVDTuneArm -Arm $Arm -Method GET -Path $path -Token $Token -Action 'Microsoft.Compute/virtualMachines/read' -Scope "the VM $($id.VmName)"
        $r.Ok = $true
    }
    catch { $r.Problem = $_.Exception.Message; return [pscustomobject]$r }
    # NICs
    try {
        $nics = New-Object System.Collections.ArrayList
        $refs = @(Get-AVDTuneProp (Get-AVDTuneProp (Get-AVDTuneProp $r.Vm 'properties') 'networkProfile') 'networkInterfaces')
        foreach ($ref in $refs) {
            $nicId = [string](Get-AVDTuneProp $ref 'id')
            if ($nicId -notmatch $script:NicPattern) { throw 'The VM names a network interface with an unexpected ID.' }
            $nic = Invoke-AVDTuneArm -Arm $Arm -Method GET -Path "${nicId}?api-version=$($script:NetworkApi)" -Token $Token -Action 'Microsoft.Network/networkInterfaces/read' -Scope 'the network interface'
            [void]$nics.Add([pscustomobject]@{ Name = [string](Get-AVDTuneProp $nic 'name'); AcceleratedNetworking = [bool](Get-AVDTuneProp (Get-AVDTuneProp $nic 'properties') 'enableAcceleratedNetworking') })
        }
        $r.Nics = @($nics)
    }
    catch { $r.NicProblem = $_.Exception.Message }
    # gallery image definition
    $defId = ConvertTo-AVDTuneGalleryImageId $GalleryImageId
    if (-not $defId) { $defId = ConvertTo-AVDTuneGalleryImageId ([string](Get-AVDTuneProp (Get-AVDTuneProp (Get-AVDTuneProp (Get-AVDTuneProp $r.Vm 'properties') 'storageProfile') 'imageReference') 'id')) }
    if ($defId) {
        $r.GalleryId = $defId
        try { $r.Gallery = Invoke-AVDTuneArm -Arm $Arm -Method GET -Path "${defId}?api-version=$($script:GalleryApi)" -Token $Token -Action 'Microsoft.Compute/galleries/images/read' -Scope 'the image definition' }
        catch { $r.GalleryProblem = $_.Exception.Message }
    }
    [pscustomobject]$r
}

#endregion

#region families

function Get-AVDTuneReadinessFamilies {
    <# Each v6/v7 family with what this master needs for it: Status ready | after-fix | not-possible, Needs = the reasons. Arm64 against x64 (or the reverse) is not a fix. #>
    param([Parameter(Mandatory)]$Data, [Parameter(Mandatory)][string]$OsArch, [bool]$StornvmeProblem, [bool]$Gen1, [bool]$ManaMissing, [bool]$DriveDUse)
    $arch = if ($OsArch -match 'ARM') { 'Arm64' } else { 'x64' }
    foreach ($f in @($Data.Families)) {
        $needs = New-Object System.Collections.ArrayList
        $status = 'ready'
        if ($f.Arch -ne $arch) { $status = 'not-possible'; [void]$needs.Add("needs an $($f.Arch) image (this master is $arch): no fix, build a new master") }
        elseif ($Gen1) { $status = 'not-possible'; [void]$needs.Add('needs Generation 2 (UEFI): this master is Generation 1, build a new master') }
        else {
            if ($StornvmeProblem) { $status = 'after-fix'; [void]$needs.Add('NVMe driver (stornvme) at boot') }
            if ($ManaMissing -and (@($f.Network) -contains 'MANA') -and -not (@($f.Network) -contains 'ConnectX')) { $status = 'after-fix'; [void]$needs.Add('MANA driver') }
            if ($DriveDUse) { $status = 'after-fix'; [void]$needs.Add($(if ($f.TempDisk -eq 'NVMe') { 'paths on D: (the local NVMe disk is raw at every start)' } else { 'paths on D: (no local disk)' })) }
        }
        [pscustomobject]@{ Name = [string]$f.Name; Generation = [string]$f.Generation; Arch = [string]$f.Arch; TempDisk = [string]$f.TempDisk; Network = (@($f.Network) -join ', '); Status = $status; Needs = @($needs) }
    }
}

#endregion

#region the analysis

function Invoke-AVDTuneReadiness {
    <#
        Runs every check and returns the result: Rows (Id, Group, Title, Status, Reason, Fix, FixId, Found, Source, Stand, Verified, Note), Counts, Overall, OpenIds
        (yellow and unknown), Families, Arm (Ok/Problem), Stand. Needs nothing but the adapters; with $Arm and $Token it also reads Azure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Machine, $Arm, [string]$Token, [string]$NoTokenReason, [string]$GalleryImageId, $Data, $UpdateBlock
    )
    if (-not $Data) { $Data = Get-AVDTuneReadinessData }
    $now = & $Machine.Now
    $rows = New-Object System.Collections.ArrayList
    function Add-Row([string]$Id, [string]$Group, [string]$Status, [string]$Reason, [string]$Fix, [string]$FixId, [string]$Found) {
        [void]$rows.Add((New-AVDTuneReadinessRow -Data $Data -Id $Id -Group $Group -Status $Status -Reason $Reason -Fix $Fix -FixId $FixId -Found $Found))
    }
    function Invoke-Check([string]$Id, [string]$Group, [scriptblock]$Body) {
        try { & $Body }
        catch { [void]$rows.Add((New-AVDTuneReadinessRow -Data $Data -Id $Id -Group $Group -Status unknown -Reason "Not checkable: the check failed ($($_.Exception.Message))")) }
    }
    $hw = 'Hardware generation'; $hy = 'Image hygiene'
    $az = Get-AVDTuneReadinessArm -Machine $Machine -Arm $Arm -Token $Token -NoTokenReason $NoTokenReason -GalleryImageId $GalleryImageId
    $armProps = if ($az.Ok) { Get-AVDTuneProp $az.Vm 'properties' } else { $null }
    $osArch = [string](& $Machine.OsArchitecture)
    $flags = @{ Stornvme = $false; Gen1 = $false; ManaMissing = $false; DriveD = $false; Families = @() }

    # ---- hardware generation
    Invoke-Check 'hw.vm-size' $hw {
        $size = ''
        $imds = & $Machine.Imds
        $c = Get-AVDTuneProp $imds 'compute'
        if ($c) { $size = [string](Get-AVDTuneProp $c 'vmSize') }
        if (-not $size -and $armProps) { $size = [string](Get-AVDTuneProp (Get-AVDTuneProp $armProps 'hardwareProfile') 'vmSize') }
        if (-not $size) { Add-Row 'hw.vm-size' $hw 'unknown' 'Not checkable: this is not an Azure VM or the instance metadata is not reachable.'; return }
        $fam = @($Data.Families | Where-Object { $size -match $_.SizePattern } | Select-Object -First 1)
        if ($fam.Count -gt 0) { Add-Row 'hw.vm-size' $hw 'info' "$size is in the family $($fam[0].Name) ($($fam[0].Generation), $($fam[0].Arch), local disk: $($fam[0].TempDisk), network: $($fam[0].Network))." -Found $size }
        else { Add-Row 'hw.vm-size' $hw 'info' "$size is not in the v6/v7 list of readiness.json (an older generation or a family not listed). The master can still run here; the checks below say whether it also fits the newer sizes." -Found $size }
    }
    Invoke-Check 'hw.disk-controller' $hw {
        if (-not $az.Ok) { Add-Row 'hw.disk-controller' $hw 'unknown' "Not checkable: $($az.Problem)"; return }
        $type = [string](Get-AVDTuneProp (Get-AVDTuneProp $armProps 'storageProfile') 'diskControllerType')
        if (-not $type) { Add-Row 'hw.disk-controller' $hw 'unknown' 'Not checkable: Azure reports no disk controller type for this VM.'; return }
        if ($type -eq 'NVMe') { Add-Row 'hw.disk-controller' $hw 'green' 'The VM runs on the NVMe controller.' -Found $type }
        else { Add-Row 'hw.disk-controller' $hw 'yellow' "The VM runs on $type, not NVMe. That is fine for older sizes. For v6/v7 the VM must be created or converted with the NVMe controller (VM stopped and deallocated; Microsoft's conversion script, a community utility, with a snapshot first). AVDTune does not convert the VM." 'Convert the controller outside the master (see the source), or deploy new session hosts from an NVMe-ready image definition.' -Found $type }
    }
    Invoke-Check 'hw.stornvme' $hw {
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme'
        if (-not (& $Machine.RegKeyExists $key)) {
            $flags.Stornvme = $true
            Add-Row 'hw.stornvme' $hw 'red' 'The Windows NVMe driver (stornvme) is not there. A master without it cannot find its disk on an NVMe-only size.' 'Use a current Windows 11 build (a build that has the driver); AVDTune cannot add it.'
            return
        }
        $start = & $Machine.RegGet $key 'Start'
        if ($null -ne $start -and [string]$start -match '^\d+$' -and [int]$start -eq 0) { Add-Row 'hw.stornvme' $hw 'green' 'stornvme is set to start at boot (Start=0).' -Found '0' }
        else {
            $flags.Stornvme = $true
            Add-Row 'hw.stornvme' $hw 'red' "stornvme does not start at boot (Start=$start). NVMe-only sizes need it at boot; Microsoft's conversion sets it with 'sc.exe config stornvme start=boot'." 'Set stornvme to start at boot (a step with confirmation; takes effect after a restart).' 'readiness.stornvme-boot' ([string]$start)
        }
    }
    Invoke-Check 'hw.nvme-timeout' $hw {
        $v = & $Machine.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme\Parameters' 'IoTimeoutValue'
        if ($null -eq $v) { Add-Row 'hw.nvme-timeout' $hw 'green' 'No IoTimeoutValue is set: Windows uses its default.'; return }
        if ([string]$v -match '^\d+$' -and [int]$v -ge 240) { Add-Row 'hw.nvme-timeout' $hw 'green' "IoTimeoutValue is $v seconds." -Found ([string]$v) }
        else { Add-Row 'hw.nvme-timeout' $hw 'yellow' "IoTimeoutValue is $v seconds. Learn: the NVMe timeout should be 240 seconds so that Azure's own recovery comes first; some older images have 30." 'Set IoTimeoutValue under stornvme\Parameters to 240 (DWORD).' -Found ([string]$v) }
    }
    Invoke-Check 'hw.mana' $hw {
        $adapters = @(& $Machine.NetAdapters)
        $mana = @($adapters | Where-Object { [string]$_.Description -like '*Microsoft Azure Network Adapter*' })
        if ($mana.Count -gt 0) { Add-Row 'hw.mana' $hw 'green' 'The MANA adapter is installed and shown in the network adapters.' -Found $mana[0].Description; return }
        $pnp = [bool](& $Machine.PnpPresent '^PCI\\VEN_1414&DEV_00BA&')
        if ($pnp) {
            $flags.ManaMissing = $true
            Add-Row 'hw.mana' $hw 'red' 'The MANA hardware is on this VM but there is no MANA network driver: the image would run without accelerated networking on MANA sizes.' 'Install the MANA driver (https://aka.ms/manawindowsdrivers, the readme of the download has the steps).'
        }
        else {
            $flags.ManaMissing = $true
            Add-Row 'hw.mana' $hw 'unknown' 'Not checkable: this VM runs on hardware without MANA, so the driver in the image cannot be seen from inside. Test the image once on a MANA size (Get-NetAdapter shows Microsoft Azure Network Adapter).'
        }
    }
    Invoke-Check 'hw.accelnet' $hw {
        if (-not $az.Ok) { Add-Row 'hw.accelnet' $hw 'unknown' "Not checkable: $($az.Problem)"; return }
        if ($az.NicProblem) { Add-Row 'hw.accelnet' $hw 'unknown' "Not checkable: $($az.NicProblem)"; return }
        if ($az.Nics.Count -eq 0) { Add-Row 'hw.accelnet' $hw 'unknown' 'Not checkable: the VM has no network interface in the answer from Azure.'; return }
        $off = @($az.Nics | Where-Object { -not $_.AcceleratedNetworking })
        if ($off.Count -eq 0) { Add-Row 'hw.accelnet' $hw 'green' "Accelerated Networking is on for $($az.Nics.Count) network interface(s)." }
        else { Add-Row 'hw.accelnet' $hw 'yellow' "Accelerated Networking is off on: $(($off | ForEach-Object { $_.Name }) -join ', '). The newer sizes require it (Learn, Dsv6 page)." 'Switch Accelerated Networking on for the NIC (Azure portal, VM stopped).' -Found (($off | ForEach-Object { $_.Name }) -join ', ') }
    }
    Invoke-Check 'hw.pagefile-d' $hw {
        $paging = & $Machine.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'PagingFiles'
        $onD = @(@($paging) | Where-Object { $_ -and ([string]$_).Trim() -match '^(?i)d:' })
        if ($onD.Count -gt 0) {
            $flags.DriveD = $true
            Add-Row 'hw.pagefile-d' $hw 'red' "The page file is set on D: ($($onD -join '; ')). Sizes without a local disk have no D:, and on sizes with one it is raw NVMe at every start: a master with this page file breaks there." 'Move the page file to C: or let the system manage it (System Properties, Advanced, Performance, Virtual memory), then restart. AVDTune does not change the page file.' -Found ($onD -join '; ')
        }
        else { Add-Row 'hw.pagefile-d' $hw 'green' 'No page file is set on D:.' }
    }
    Invoke-Check 'hw.temp-env-d' $hw {
        $envKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        $bad = @('TEMP', 'TMP' | ForEach-Object { $v = [string](& $Machine.RegGet $envKey $_); if ($v.Trim() -match '^(?i)d:') { "$_=$v" } })
        if ($bad.Count -gt 0) { $flags.DriveD = $true; Add-Row 'hw.temp-env-d' $hw 'yellow' "TEMP or TMP of the machine points to D: ($($bad -join '; ')). Without a D: or with a raw local disk, programs that write there fail." 'Point TEMP and TMP to a folder on C: (system environment variables).' -Found ($bad -join '; ') }
        else { Add-Row 'hw.temp-env-d' $hw 'green' 'TEMP and TMP of the machine are not on D:.' }
    }
    Invoke-Check 'hw.fslogix-d' $hw {
        $key = 'HKLM:\SOFTWARE\FSLogix\Profiles'
        $bad = @('CacheDirectory', 'WriteCacheDirectory', 'ProxyDirectory' | ForEach-Object { $v = [string](& $Machine.RegGet $key $_); if ($v.Trim() -match '^(?i)d:') { "$_=$v" } })
        if ($bad.Count -gt 0) { $flags.DriveD = $true; Add-Row 'hw.fslogix-d' $hw 'yellow' "The FSLogix local cache is on D: ($($bad -join '; ')). Learn asks for fast, available storage there; D: can be missing or raw after a start." 'Move the FSLogix cache folders to a drive that is always there (FSLogix page).' -Found ($bad -join '; ') }
        else { Add-Row 'hw.fslogix-d' $hw 'green' 'No FSLogix cache folder is set on D:.' }
    }
    Invoke-Check 'hw.firmware' $hw {
        $fw = & $Machine.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control' 'PEFirmwareType'
        $gen = [string](Get-AVDTuneProp (Get-AVDTuneProp (Get-AVDTuneProp $armProps 'extended') 'instanceView') 'hyperVGeneration')
        if ($gen -eq 'V1' -or ($null -ne $fw -and [string]$fw -eq '1')) {
            $flags.Gen1 = $true
            Add-Row 'hw.firmware' $hw 'red' 'This master is Generation 1 (BIOS). The v6 and v7 sizes need Generation 2 (UEFI), and there is no plain conversion.' 'Build a new master from a Generation 2 image (or follow the Trusted Launch upgrade of Microsoft first).' -Found $(if ($gen) { $gen } else { 'BIOS' })
        }
        elseif ($gen -eq 'V2' -or ($null -ne $fw -and [string]$fw -eq '2')) { Add-Row 'hw.firmware' $hw 'green' 'Generation 2: the master boots with UEFI.' -Found $(if ($gen) { $gen } else { 'UEFI' }) }
        else { Add-Row 'hw.firmware' $hw 'unknown' 'Not checkable: neither the firmware type of the guest nor the generation from Azure could be read.' }
    }
    Invoke-Check 'hw.securestart' $hw {
        $sb = & $Machine.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
        $tpm = & $Machine.TpmPresent
        $sec = Get-AVDTuneProp $armProps 'securityProfile'
        $type = [string](Get-AVDTuneProp $sec 'securityType')
        $parts = @("Secure Boot: $(if ($null -eq $sb) { 'not readable' } elseif ([string]$sb -eq '1') { 'on' } else { 'off' })", "vTPM: $(if ($null -eq $tpm) { 'not readable' } elseif ($tpm) { 'present' } else { 'none' })")
        if ($type) { $parts += "security type in Azure: $type" }
        $text = $parts -join '; '
        if ($null -eq $sb -and $null -eq $tpm) { Add-Row 'hw.securestart' $hw 'unknown' "Not checkable: $text."; return }
        if (([string]$sb -eq '1') -and $tpm -eq $true) { Add-Row 'hw.securestart' $hw 'green' "Trusted Launch features are on ($text)." -Found $text }
        else { Add-Row 'hw.securestart' $hw 'yellow' "Not fully Trusted Launch ($text). Learn recommends Trusted Launch for Generation 2; the image definition decides what new VMs get." 'Enable Secure Boot and vTPM on the VM (Azure portal, Security type Trusted Launch).' -Found $text }
    }
    Invoke-Check 'hw.arch' $hw {
        $a = if ($osArch -match 'ARM') { 'Arm64' } elseif ($osArch) { 'x64' } else { '' }
        if (-not $a) { Add-Row 'hw.arch' $hw 'unknown' 'Not checkable: the processor architecture of Windows could not be read.'; return }
        $armCount = @($Data.Families | Where-Object { $_.Arch -eq 'Arm64' }).Count
        if ($a -eq 'x64') { Add-Row 'hw.arch' $hw 'info' "x64: the Arm64 families ($armCount in the list) need an Arm64 image and are not possible with this master." -Found 'x64' }
        else { Add-Row 'hw.arch' $hw 'info' "Arm64: only the Arm64 families fit this master; the x64 families need an x64 image." -Found 'Arm64' }
    }
    Invoke-Check 'hw.gallery' $hw {
        if (-not $az.Ok) { Add-Row 'hw.gallery' $hw 'unknown' "Not checkable: $($az.Problem)"; return }
        if (-not $az.GalleryId) { Add-Row 'hw.gallery' $hw 'unknown' 'Not checkable: no image definition is known. Enter the Resource ID of the definition the image is captured into (Readiness card on the Overview).'; return }
        if ($az.GalleryProblem) { Add-Row 'hw.gallery' $hw 'unknown' "Not checkable: $($az.GalleryProblem)"; return }
        $p = Get-AVDTuneProp $az.Gallery 'properties'
        $features = @(Get-AVDTuneProp $p 'features')
        $feature = { param($n) $hit = @($features | Where-Object { $_ -and ([string](Get-AVDTuneProp $_ 'name')) -like "$n*" } | Select-Object -First 1); if ($hit.Count -gt 0) { [string](Get-AVDTuneProp $hit[0] 'value') } else { $null } }
        $disk = & $feature 'DiskControllerType'
        $sec = & $feature 'SecurityType'
        $accel = & $feature 'IsAcceleratedNetworkSupported'
        $arch = [string](Get-AVDTuneProp $p 'architecture'); $gen = [string](Get-AVDTuneProp $p 'hyperVGeneration')
        $red = New-Object System.Collections.ArrayList; $yellow = New-Object System.Collections.ArrayList
        if ($disk -notmatch '(?i)nvme') { [void]$red.Add("DiskControllerType is '$(if ($disk) { $disk } else { 'not set' })', not SCSI, NVMe: an image captured into it cannot be used for NVMe VMs (v6/v7)") }
        if ($gen -and $gen -ne 'V2') { [void]$red.Add("the definition is $gen, not V2 (Generation 2)") }
        $want = if ($osArch -match 'ARM') { 'Arm64' } else { 'x64' }
        if ($arch -and $arch -ne $want) { [void]$red.Add("the definition is $arch but this master is $want") }
        if ($sec -notmatch '(?i)^TrustedLaunch') { [void]$yellow.Add("SecurityType is '$(if ($sec) { $sec } else { 'not set' })' (Trusted Launch is not supported by the definition)") }
        if ($accel -notmatch '(?i)^true$') { [void]$yellow.Add("IsAcceleratedNetworkSupported is '$(if ($accel) { $accel } else { 'not set' })'") }
        $found = "disk=$disk; security=$sec; accelerated=$accel; architecture=$arch; generation=$gen"
        if ($red.Count -gt 0) { Add-Row 'hw.gallery' $hw 'red' ('The image definition does not fit v6/v7: ' + (@($red) + @($yellow) -join '; ') + '.') 'Capture into a definition with the features DiskControllerType SCSI,NVMe, SecurityType TrustedLaunchSupported, accelerated networking and Generation 2 (create a new definition; features cannot be added to an existing one in the portal).' -Found $found }
        elseif ($yellow.Count -gt 0) { Add-Row 'hw.gallery' $hw 'yellow' ('The image definition fits NVMe but: ' + ($yellow -join '; ') + '.') 'Use a definition with SecurityType TrustedLaunchSupported and IsAcceleratedNetworkSupported True.' -Found $found }
        else { Add-Row 'hw.gallery' $hw 'green' 'The image definition supports NVMe, Trusted Launch and accelerated networking, Generation 2.' -Found $found }
    }

    # ---- image hygiene
    Invoke-Check 'hy.windows-support' $hy {
        $w = Get-AVDTuneWindowsInfo $Machine
        if (-not $w.Build) { Add-Row 'hy.windows-support' $hy 'unknown' 'Not checkable: the Windows build could not be read.'; return }
        $entry = @($Data.Windows.Builds | Where-Object { [string]$_.Build -eq $w.Build } | Select-Object -First 1)
        $edition = if ($w.MultiSession) { '' } else { " The edition is $($w.Edition), not Enterprise multi-session." }
        if ($entry.Count -eq 0) { Add-Row 'hy.windows-support' $hy 'yellow' "Build $($w.Build) is not in the table of readiness.json (Stand $($Data.Stand)): check the Windows release information.$edition" 'Compare with the release information page (the source) and update readiness.json.' -Found $w.FullBuild; return }
        $e = $entry[0]
        $end = [string]$e.EndOfUpdates
        if ($end -eq 'ended') { Add-Row 'hy.windows-support' $hy 'red' "Windows $($e.Version) (build $($w.Build)) is out of service for Enterprise and multi-session: it gets no updates.$edition" 'Build the master on a Windows version that is in service.' -Found "$($e.Version) $($w.FullBuild)"; return }
        $endDate = [datetime]::ParseExact($end, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $left = [int]($endDate - $now.Date).TotalDays
        if ($left -lt 0) { Add-Row 'hy.windows-support' $hy 'red' "Windows $($e.Version) ended on $end (Enterprise and multi-session).$edition" 'Build the master on a Windows version that is in service.' -Found "$($e.Version) $($w.FullBuild)" }
        elseif ($left -le [int]$Data.Windows.WarnDaysBeforeEnd -or -not $w.MultiSession) { Add-Row 'hy.windows-support' $hy 'yellow' "Windows $($e.Version) is in service until $end ($left days).$edition" 'Plan the move to a newer Windows version.' -Found "$($e.Version) $($w.FullBuild)" }
        else { Add-Row 'hy.windows-support' $hy 'green' "Windows $($e.Version) (build $($w.FullBuild)) is in service until $end." -Found "$($e.Version) $($w.FullBuild)" }
    }
    Invoke-Check 'hy.lcu-age' $hy {
        $w = Get-AVDTuneWindowsInfo $Machine
        $entry = @($Data.Windows.Builds | Where-Object { [string]$_.Build -eq $w.Build } | Select-Object -First 1)
        $behind = ''
        if ($entry.Count -gt 0 -and $w.Ubr -match '^\d+$' -and ([string]$entry[0].Latest) -match '^\d+\.(\d+)$' -and [int]$w.Ubr -lt [int]$Matches[1]) { $behind = "Build $($w.FullBuild); the newest known build of this version in the data is $($entry[0].Latest) (Stand $($Data.Stand))." }
        $dates = @(@(& $Machine.Hotfixes) | Where-Object { $_ -and $_.InstalledOn } | ForEach-Object { [datetime]$_.InstalledOn })
        if ($dates.Count -eq 0) {
            if ($behind) { Add-Row 'hy.lcu-age' $hy 'yellow' "The date of the last update could not be read. $behind" 'Run the Windows updates (Updates page).' -Found $w.FullBuild }
            else { Add-Row 'hy.lcu-age' $hy 'unknown' 'Not checkable: Windows lists no installed update with a date.' }
            return
        }
        $newest = ($dates | Sort-Object -Descending | Select-Object -First 1)
        $age = [int]($now.Date - $newest.Date).TotalDays
        $text = "The newest installed update is from $($newest.ToString('yyyy-MM-dd')) ($age days ago)."
        if ($age -gt [int]$Data.Thresholds.LcuRedDays) { Add-Row 'hy.lcu-age' $hy 'red' ("$text More than $($Data.Thresholds.LcuRedDays) days: the image would start far behind. $behind").Trim() 'Run the Windows updates (Updates page).' -Found "$age days" }
        elseif ($age -gt [int]$Data.Thresholds.LcuYellowDays -or $behind) { Add-Row 'hy.lcu-age' $hy 'yellow' ("$text $behind").Trim() 'Run the Windows updates (Updates page).' -Found "$age days" }
        else { Add-Row 'hy.lcu-age' $hy 'green' $text -Found "$age days" }
    }
    Invoke-Check 'hy.avd-agent' $hy {
        $svc = @('RDAgentBootLoader', 'RDAgent' | Where-Object { & $Machine.ServiceGet $_ })
        $key = [bool](& $Machine.RegKeyExists 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent')
        if ($svc.Count -gt 0 -or $key) { Add-Row 'hy.avd-agent' $hy 'red' 'The AVD agent or boot loader is installed. It must not be on the master: the host pool installs it on the session hosts (a master that joined a host pool breaks the new session hosts).' 'Uninstall the Remote Desktop Services Infrastructure Agent and the boot loader (Apps).' -Found ($svc -join ', ') }
        else { Add-Row 'hy.avd-agent' $hy 'green' 'The AVD agent and boot loader are not installed.' }
    }
    Invoke-Check 'hy.reg-token' $hy {
        $t = [string](& $Machine.RegGet 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' 'RegistrationToken')
        if ($t.Trim()) { Add-Row 'hy.reg-token' $hy 'red' 'A host pool registration token is in the registry (RDInfraAgent). It would end up in every session host.' 'Remove the agent (see the AVD agent check); the token goes with it.' }
        else { Add-Row 'hy.reg-token' $hy 'green' 'No registration token in the registry.' }
    }
    Invoke-Check 'hy.join' $hy {
        $dsreg = $null
        try { $dsreg = & $Machine.Run 'dsregcmd.exe' @('/status') } catch { }
        if (-not ($dsreg -and $dsreg.ExitCode -eq 0 -and $dsreg.Output)) { Add-Row 'hy.join' $hy 'unknown' 'Not checkable: dsregcmd /status gave no answer.'; return }
        $joined = @(); if ($dsreg.Output -match '(?im)^\s*AzureAdJoined\s*:\s*YES') { $joined += 'Microsoft Entra ID' }; if ($dsreg.Output -match '(?im)^\s*DomainJoined\s*:\s*YES') { $joined += 'a domain' }
        if ($joined.Count -gt 0) { Add-Row 'hy.join' $hy 'red' ('The master is joined to ' + ($joined -join ' and ') + '. A master must not be joined (leave before the image is made).') 'Leave the domain or Microsoft Entra ID (local admin sign-in needed).' -Found ($joined -join ', ') }
        else { Add-Row 'hy.join' $hy 'green' 'Not joined to a domain or Microsoft Entra ID.' }
    }
    Invoke-Check 'hy.bitlocker' $hy {
        $r = $null
        try { $r = & $Machine.Run 'manage-bde.exe' @('-status', 'C:') } catch { }
        if (-not ($r -and $r.ExitCode -eq 0 -and $r.Output)) { Add-Row 'hy.bitlocker' $hy 'unknown' 'Not checkable: manage-bde gave no answer.'; return }
        if ($r.Output -match '(?im)Protection Status:\s*Protection On' -or $r.Output -match '(?im)Conversion Status:\s*(Fully Encrypted|Encryption in Progress)') { Add-Row 'hy.bitlocker' $hy 'yellow' 'BitLocker is on for C:. The process asks for it to be off on the master (no Learn page states why; see the note).' 'Turn BitLocker off and wait until the drive is decrypted (manage-bde -off C:).' }
        else { Add-Row 'hy.bitlocker' $hy 'green' 'BitLocker is off for C:.' }
    }
    Invoke-Check 'hy.reboot' $hy {
        $pending = New-Object System.Collections.ArrayList
        if (& $Machine.RegKeyExists 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { [void]$pending.Add('servicing') }
        if (& $Machine.RegKeyExists 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { [void]$pending.Add('Windows Update') }
        $rename = & $Machine.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations'
        if ($rename -and @($rename).Count -gt 0) { [void]$pending.Add('file operations') }
        $setup = & $Machine.RegGet 'HKLM:\SYSTEM\Setup' 'SystemSetupInProgress'
        if ($null -ne $setup -and [string]$setup -eq '1') { Add-Row 'hy.reboot' $hy 'red' 'A Windows setup operation is still running (SystemSetupInProgress=1).' 'Let setup finish and restart.'; return }
        if ($pending.Count -gt 0) { Add-Row 'hy.reboot' $hy 'yellow' ('A restart is waiting: ' + ($pending -join ', ') + '.') 'Restart the master (the Finish step restarts and continues).' -Found ($pending -join ', ') }
        else { Add-Row 'hy.reboot' $hy 'green' 'No restart is waiting.' }
    }
    Invoke-Check 'hy.update-block' $hy {
        $st = $UpdateBlock
        if (-not $st) { $st = Get-AVDTuneUpdateBlockStatus $Machine }
        switch ([string]$st.State) {
            'On' { Add-Row 'hy.update-block' $hy 'green' "The update block is on ($($st.Compliant) of $($st.Applicable) settings)." }
            'Partial' { Add-Row 'hy.update-block' $hy 'yellow' "The update block is only partly on ($($st.Compliant) of $($st.Applicable) settings; missing: $($st.Missing))." 'Switch the update block on (Update block page).' 'readiness.updateblock-on' }
            default { Add-Row 'hy.update-block' $hy 'red' 'The update block for users is off: users could see and run updates on the session hosts.' 'Switch the update block on (Update block page, or the fix here).' 'readiness.updateblock-on' }
        }
    }
    Invoke-Check 'hy.defender-onboarding' $hy {
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection'
        $guid = [string](& $Machine.RegGet $key 'senseGuid')
        if ($guid.Trim()) { Add-Row 'hy.defender-onboarding' $hy 'red' 'This master was onboarded to Defender for Endpoint (senseGuid is set). Every clone would carry the same device ID and not show up as a new device.' 'Offboard the master and clear the local registration data as described in the source, then onboard through the VDI onboarding script on the session hosts.' }
        elseif (& $Machine.ServiceGet 'Sense') { $s = & $Machine.ServiceGet 'Sense'; if ($s.Status -eq 'Running') { Add-Row 'hy.defender-onboarding' $hy 'yellow' 'The Defender for Endpoint sensor (Sense) is running although no device ID is stored yet: the master may be onboarding.' 'Check the Defender portal; do not onboard the master.' } else { Add-Row 'hy.defender-onboarding' $hy 'green' 'The sensor is installed but not running and has no device ID: the master is not onboarded.' } }
        else { Add-Row 'hy.defender-onboarding' $hy 'green' 'The master is not onboarded to Defender for Endpoint.' }
    }
    Invoke-Check 'hy.language' $hy {
        $names = @(& $Machine.RegSubKeys 'HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages')
        if ($names.Count -eq 0) { Add-Row 'hy.language' $hy 'unknown' 'Not checkable: the installed display languages could not be read.'; return }
        Add-Row 'hy.language' $hy 'info' ("Installed display languages: " + (($names | Sort-Object) -join ', ') + '. Which ones the users need is set on the Setup page (later phase).') -Found (($names | Sort-Object) -join ', ')
    }
    Invoke-Check 'hy.vm-agent' $hy {
        $a = & $Machine.ServiceGet 'WindowsAzureGuestAgent'
        if (-not $a) { Add-Row 'hy.vm-agent' $hy 'yellow' 'The Azure VM agent (WindowsAzureGuestAgent) is not installed: extensions, backup and some Azure services need it.' 'Install the Azure VM agent (the source has the download).'; return }
        $bad = @(@($a) | Where-Object { $_ -and $_.Status -ne 'Running' })
        if ($bad.Count -gt 0) { Add-Row 'hy.vm-agent' $hy 'yellow' "The Azure VM agent service $(($bad | ForEach-Object { $_.Name }) -join ', ') is not running. Whether the agent is current is not checked." 'Start the service or reinstall the agent.' }
        else { Add-Row 'hy.vm-agent' $hy 'green' 'The Azure VM agent is installed and running (whether it is the newest version is not checked).' }
    }
    Invoke-Check 'hy.leftovers' $hy {
        $found = New-Object System.Collections.ArrayList
        foreach ($name in @(& $Machine.TaskList '\')) {
            foreach ($pattern in @($Data.Hygiene.LeftoverTaskPatterns)) { if ($name -match $pattern) { [void]$found.Add("task $name"); break } }
        }
        foreach ($path in @($Data.Hygiene.LeftoverPaths)) { if (& $Machine.PathExists $path) { [void]$found.Add("folder $path") } }
        foreach ($file in @(& $Machine.DirList ([string]$Data.Hygiene.LeftoverStarterFolder) ([string]$Data.Hygiene.LeftoverStarterFilter))) { [void]$found.Add("file $(Join-Path ([string]$Data.Hygiene.LeftoverStarterFolder) $file)") }
        if ($found.Count -gt 0) { Add-Row 'hy.leftovers' $hy 'yellow' ('Leftovers of earlier scripts: ' + ($found -join '; ') + '.') 'Check each one and remove it by hand if it is not needed (AVDTune does not delete things it did not create).' -Found ($found -join '; ') }
        else { Add-Row 'hy.leftovers' $hy 'green' 'No leftovers of earlier scripts found (scheduled tasks, VBS starters, driver export folders).' }
    }

    # ---- families (needs the flags of the checks above)
    Invoke-Check 'hw.families' $hw {
        $fams = @(Get-AVDTuneReadinessFamilies -Data $Data -OsArch $osArch -StornvmeProblem $flags.Stornvme -Gen1 $flags.Gen1 -ManaMissing $flags.ManaMissing -DriveDUse $flags.DriveD)
        $flags.Families = $fams
        $ready = @($fams | Where-Object Status -eq 'ready').Count; $fix = @($fams | Where-Object Status -eq 'after-fix').Count; $no = @($fams | Where-Object Status -eq 'not-possible').Count
        Add-Row 'hw.families' $hw 'info' "Of $($fams.Count) v6/v7 families: $ready ready, $fix after fixing the items above, $no not possible with this master (architecture or generation)." -Found "$ready/$fix/$no"
    }
    $families = @($flags.Families)

    $counts = [ordered]@{ Green = 0; Yellow = 0; Red = 0; Unknown = 0; Info = 0 }
    foreach ($r in $rows) { switch ($r.Status) { 'green' { $counts.Green++ } 'yellow' { $counts.Yellow++ } 'red' { $counts.Red++ } 'unknown' { $counts.Unknown++ } default { $counts.Info++ } } }
    $overall = if ($counts.Red -gt 0) { 'red' } elseif ($counts.Yellow -gt 0 -or $counts.Unknown -gt 0) { 'yellow' } else { 'green' }
    [pscustomobject]@{
        At = $now.ToString('o'); Stand = [string]$Data.Stand; Overall = $overall; Counts = [pscustomobject]$counts; Rows = @($rows)
        OpenIds = @($rows | Where-Object { $_.Status -in 'yellow', 'unknown' } | ForEach-Object { $_.Id }); RedIds = @($rows | Where-Object { $_.Status -eq 'red' } | ForEach-Object { $_.Id })
        Families = @($families); Arm = [pscustomobject]@{ Ok = [bool]$az.Ok; Problem = [string]$az.Problem }; GalleryImageId = [string]$az.GalleryId
    }
}

#endregion

#region storing, confirmation, finish gate

function Save-AVDTuneReadinessRun {
    <#
        Stores a result: run record (append only), state.json Readiness (a new analysis clears an earlier confirmation) and, for every kind except 'Start',
        a change log entry (when an image version is started). Kind: Start (run at every start) | Erstanalyse | Healthcheck | Manual.
    #>
    [CmdletBinding()]
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Result, [Parameter(Mandatory)][ValidateSet('Start', 'Erstanalyse', 'Healthcheck', 'Manual')][string]$Kind, [string]$User, [string]$SnapshotId, [datetime]$At = (Get-Date))
    $state = Get-AVDTuneState $Root
    $slim = @($Result.Rows | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Group = $_.Group; Title = $_.Title; Status = $_.Status; Reason = $_.Reason; Fix = $_.Fix; FixId = $_.FixId; Source = $_.Source; Stand = $_.Stand; Verified = $_.Verified } })
    $run = [pscustomobject][ordered]@{
        Id = $null; Plan = "Readiness analysis ($Kind)"; Kind = $Kind; Started = $Result.At; Ended = $At.ToString('o'); User = $User; SnapshotId = $SnapshotId; WhatIf = $false
        ImageVersion = $state.ImageVersion; Reboot = $false; Overall = $Result.Overall; Counts = $Result.Counts; Results = $slim; Families = @($Result.Families)
    }
    $path = Add-AVDTuneRun -Root $Root -Run $run
    $record = [pscustomobject][ordered]@{
        RunId = $run.Id; At = $Result.At; Kind = $Kind; Overall = $Result.Overall; Green = $Result.Counts.Green; Yellow = $Result.Counts.Yellow; Red = $Result.Counts.Red; Unknown = $Result.Counts.Unknown
        OpenIds = @($Result.OpenIds); RedIds = @($Result.RedIds); Acknowledged = @(); AcknowledgedBy = ''; AcknowledgedAt = $null
    }
    [void](Set-AVDTuneState -Root $Root -Values @{ Readiness = $record })
    if ($Kind -ne 'Start' -and $state.ImageVersion) {
        $label = if ($Kind -eq 'Manual') { 'Readiness analysis' } else { $Kind }
        $names = @($Result.Rows | Where-Object { $_.Status -in 'red', 'yellow', 'unknown' } | ForEach-Object { "$($_.Id) ($($_.Status))" })
        $text = "$label`: overall $($Result.Overall) ($($Result.Counts.Red) red, $($Result.Counts.Yellow) yellow, $($Result.Counts.Unknown) not checkable, $($Result.Counts.Green) green)" + $(if ($names.Count -gt 0) { '; open: ' + ($names -join ', ') } else { '' })
        [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'Readiness' -Component $label -ChangeType Note -Text $text -User $User -SnapshotId $SnapshotId -RunId $run.Id -Source Step -At $At)
    }
    [pscustomobject]@{ RunId = $run.Id; Path = $path }
}

function Get-AVDTuneReadinessRecord {
    param([string]$Root = (Get-AVDTuneRoot))
    Get-AVDTuneProp (Get-AVDTuneState $Root) 'Readiness'
}

function Confirm-AVDTuneReadinessAcknowledgement {
    <#
        Yellow and not checkable items need a confirmation that names every one of them: -Typed holds the item ids (separated by space, comma or semicolon).
        Red items cannot be confirmed, they must be fixed and the analysis run again. Writes state.json and a change log entry.
    #>
    [CmdletBinding()]
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Typed, [Parameter(Mandatory)][string]$User, [datetime]$At = (Get-Date))
    $rec = Get-AVDTuneReadinessRecord -Root $Root
    if (-not $rec) { throw 'There is no analysis to confirm: run the readiness analysis first.' }
    if ([int]$rec.Red -gt 0) { throw "$($rec.Red) red item(s) must be fixed first ($(@($rec.RedIds) -join ', ')); red cannot be confirmed. Fix them and run the analysis again." }
    $open = @($rec.OpenIds)
    if ($open.Count -eq 0) { throw 'Nothing to confirm: there are no yellow or not checkable items.' }
    $names = @(([string]$Typed -split '[\s,;]+') | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    $missing = @($open | Where-Object { $_.ToLowerInvariant() -notin $names })
    if ($missing.Count -gt 0) { throw "Type the name of every open item to confirm. Missing: $($missing -join ', ')." }
    $rec.Acknowledged = $open; $rec.AcknowledgedBy = $User; $rec.AcknowledgedAt = $At.ToString('o')
    [void](Set-AVDTuneState -Root $Root -Values @{ Readiness = $rec })
    $state = Get-AVDTuneState $Root
    if ($state.ImageVersion) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'Readiness' -Component 'Confirmation' -ChangeType Note -Text ("Open items confirmed by $User`: " + ($open -join ', ')) -User $User -RunId ([string]$rec.RunId) -Source Step -At $At) }
    $rec
}

function Get-AVDTuneFinishReadiness {
    <#
        Is "Abschliessen" allowed? Needs an analysis (healthcheck) with no red item, every yellow or not checkable item confirmed by name, and no change
        of the master after it (a change log entry made by a step, except the readiness entries themselves). Allowed + Reasons (why not).
    #>
    [CmdletBinding()]
    param([string]$Root = (Get-AVDTuneRoot))
    $reasons = New-Object System.Collections.ArrayList
    $rec = Get-AVDTuneReadinessRecord -Root $Root
    if (-not $rec) { return [pscustomobject]@{ Allowed = $false; Reasons = @('No healthcheck yet: run the readiness analysis.'); Overall = ''; At = '' } }
    if ([int]$rec.Red -gt 0) { [void]$reasons.Add("$($rec.Red) red item(s): $(@($rec.RedIds) -join ', ').") }
    $open = @($rec.OpenIds); $ack = @($rec.Acknowledged)
    $unconfirmed = @($open | Where-Object { $_ -notin $ack })
    if ($unconfirmed.Count -gt 0 -and [int]$rec.Red -eq 0) { [void]$reasons.Add("$($unconfirmed.Count) yellow or not checkable item(s) are not confirmed by name: $($unconfirmed -join ', ').") }
    $at = [datetime]::Parse([string]$rec.At, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    $log = Get-AVDTuneChangeLog -Root $Root
    $after = @(@($log) | Where-Object { $_ -and $_.Source -eq 'Step' -and $_.Category -ne 'Readiness' -and ([datetime]::Parse([string]$_.At, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)) -gt $at })
    if ($after.Count -gt 0) { [void]$reasons.Add("The master was changed after the check ($($after.Count) change log entr$(if ($after.Count -eq 1) { 'y' } else { 'ies' })): run the analysis again.") }
    [pscustomobject]@{ Allowed = ($reasons.Count -eq 0); Reasons = @($reasons); Overall = [string]$rec.Overall; At = [string]$rec.At }
}

#endregion

#region fixes

function Get-AVDTuneReadinessFixes {
    # The fixes behind the write gate. Only what is safe and documented.
    $stornvme = 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme'
    $test = {
        param($m)
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme'
        if (-not (& $m.RegKeyExists $key)) { return @{ Compliant = $false; State = 'driver service missing' } }
        $s = & $m.RegGet $key 'Start'
        @{ Compliant = ($null -ne $s -and [string]$s -match '^\d+$' -and [int]$s -eq 0); State = $s }
    }
    $apply = {
        param($m)
        if (-not (& $m.RegKeyExists 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme')) { throw 'The stornvme driver is not installed; it cannot be set to boot.' }
        $r = & $m.Run 'sc.exe' @('config', 'stornvme', 'start=boot')
        if ($r.ExitCode -ne 0) { throw "sc.exe config stornvme start=boot failed (exit code $($r.ExitCode)): $([string]$r.Output)" }
    }
    @{
        'readiness.stornvme-boot' = (New-AVDTuneStep -Id 'readiness.stornvme-boot' -Section Setup -Title 'NVMe driver (stornvme): start at boot' -Why "Microsoft's SCSI to NVMe conversion sets it for Windows (sc.exe config stornvme start=boot) so that the OS finds its disk on an NVMe controller. Takes effect after the next restart; the master keeps working on SCSI sizes." -Risk Medium -Reboot $true -SourceUrl 'https://learn.microsoft.com/en-us/azure/virtual-machines/nvme-linux' -Test $test -Apply $apply)
    }
}

function Invoke-AVDTuneReadinessFix {
    <#
        Applies one fix from a result row (FixId). Needs the open write gate unless -WhatIf (the step engine refuses otherwise). Writes a run record and a
        change log entry. The update block fix is Set-AVDTuneUpdateBlock (#6). The analysis must be run again afterwards.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$FixId, [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    if ($FixId -eq 'readiness.updateblock-on') {
        $s = Set-AVDTuneUpdateBlock -Machine $Machine -Root $Root -Mode On -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf
        $bad = $s.Failed -gt 0
        return [pscustomobject]@{ FixId = $FixId; Status = $(if ($WhatIf) { 'WhatIf' } elseif ($bad) { 'Failed' } else { 'Changed' }); Message = "Update block on: $($s.Changed) setting(s) changed, state $($s.State)."; Reboot = $false; Results = @($s.Results) }
    }
    $fixes = Get-AVDTuneReadinessFixes
    if (-not $fixes.ContainsKey($FixId)) { throw "Unknown fix '$FixId'." }
    $step = $fixes[$FixId]
    $result = Invoke-AVDTuneStep -Step $step -Machine $Machine -Mode Apply -WhatIf:$WhatIf
    if ($WhatIf) { return [pscustomobject]@{ FixId = $FixId; Status = [string]$result.Status; Message = [string]$result.Message; Reboot = $false; Results = @($result) } }
    $state = Get-AVDTuneState $Root
    $run = [pscustomobject][ordered]@{
        Id = $null; Plan = "Readiness fix $FixId"; Started = (& $Machine.Now).ToString('o'); Ended = (& $Machine.Now).ToString('o'); User = $User; SnapshotId = $SnapshotId; WhatIf = $false
        ImageVersion = $state.ImageVersion; Reboot = [bool]$result.Reboot; Results = @($result)
    }
    [void](Add-AVDTuneRun -Root $Root -Run $run)
    if ($state.ImageVersion -and $result.Status -in 'Changed', 'Failed') {
        $text = if ($result.Status -eq 'Changed') { "$($step.Title): changed (before: $($result.Before), after: $($result.After))$(if ($result.Reboot) { '; restart needed' })" } else { "$($step.Title): FAILED ($($result.Message))" }
        [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'Readiness fix' -Component 'Readiness' -ChangeType Changed -Text $text -User $User -SnapshotId $SnapshotId -RunId $run.Id -Source Step)
    }
    [pscustomobject]@{ FixId = $FixId; Status = [string]$result.Status; Message = [string]$result.Message; Reboot = [bool]$result.Reboot; Results = @($result) }
}

#endregion

Export-ModuleMember -Function Get-AVDTuneReadinessDataPath, Get-AVDTuneReadinessData, ConvertTo-AVDTuneGalleryImageId, Get-AVDTuneReadinessArm, Get-AVDTuneReadinessFamilies, Invoke-AVDTuneReadiness,
    Save-AVDTuneReadinessRun, Get-AVDTuneReadinessRecord, Confirm-AVDTuneReadinessAcknowledgement, Get-AVDTuneFinishReadiness, Get-AVDTuneReadinessFixes, Invoke-AVDTuneReadinessFix
