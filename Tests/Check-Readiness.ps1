#requires -Version 5.1
<#
.SYNOPSIS
    Checks the readiness analysis and image hygiene (Modules\AVDTune.Readiness.psm1, readiness.json) against the fake machine, the fake Azure
    Resource Manager and a temporary state folder: the data (sources, dates, Verified), every check green and in its failure paths (no Azure
    access, 403, offline, VM on SCSI, stornvme not at boot, paths on D:, no MANA, Generation 1, Arm64, gallery definition without NVMe, Windows out of
    service, hygiene findings), a check that throws, the families, storing the run, the confirmation by name, the finish gate and the fix behind the
    write gate. Nothing touches the registry, services or tasks of this computer, nothing is written to Azure (only GET is allowed).
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Snapshot.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.UpdateBlock.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Readiness.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Start.psm1') -Force
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeServices.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Test-Throws([scriptblock]$Block) { try { & $Block | Out-Null; $false } catch { $true } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }

$win = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$sub = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
$defId = "/subscriptions/$sub/resourceGroups/rg-example/providers/Microsoft.Compute/galleries/gal1/images/def1"
$goodGallery = @{ Features = @(@{ name = 'DiskControllerTypes'; value = 'SCSI, NVMe' }, @{ name = 'SecurityType'; value = 'TrustedLaunchSupported' }, @{ name = 'IsAcceleratedNetworkSupported'; value = 'True' }); Architecture = 'x64'; HyperV = 'V2' }
$goodBlock = [pscustomobject]@{ State = 'On'; Compliant = 12; Applicable = 12; Missing = '' }
$now = [datetime]'2026-11-15 10:00'

function New-Imds([string]$Size = 'Standard_D4s_v6') {
    [pscustomobject]@{ compute = [pscustomobject]@{
            name = 'gm-test01'; resourceGroupName = 'rg-example'; subscriptionId = $sub; vmId = '00000000-1111-2222-3333-444444444444'; location = 'westeurope'; vmSize = $Size
            storageProfile = [pscustomobject]@{ imageReference = [pscustomobject]@{ publisher = 'microsoftwindowsdesktop'; offer = 'office-365'; sku = 'win11-25h2-avd-m365'; version = 'latest' }
                osDisk = [pscustomobject]@{ name = 'gm-test01_osdisk'; managedDisk = [pscustomobject]@{ id = "/subscriptions/$sub/resourceGroups/rg-example/providers/Microsoft.Compute/disks/gm-test01_osdisk" } } } } }
}
function New-Master([hashtable]$Extra = @{}, [hashtable]$Reg = @{}) {
    $registry = @{
        "$win|UBR" = 9974; 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme|Start' = 0
        'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State|UEFISecureBootEnabled' = 1
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management|PagingFiles' = @('C:\pagefile.sys 0 0')
    }
    foreach ($k in $Reg.Keys) { $registry[$k] = $Reg[$k] }
    $seed = @{
        Now = $now; Registry = $registry; Imds = (New-Imds)
        Services = @(@{ Name = 'WindowsAzureGuestAgent' })
        Keys = @('HKLM:\SYSTEM\CurrentControlSet\Services\stornvme', 'HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages\en-US', 'HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages\de-DE')
        Hotfixes = @(@{ Id = 'KB5132061'; InstalledOn = [datetime]'2026-11-10' }); Tpm = $true; Arch = 'AMD64'; Firmware = 'UEFI'
        NetAdapters = @(@{ Name = 'Ethernet'; Description = 'Microsoft Hyper-V Network Adapter'; Status = 'Up' }, @{ Name = 'Ethernet 3'; Description = 'Microsoft Azure Network Adapter #2'; Status = 'Up' })
        Pnp = @('PCI\VEN_1414&DEV_00BA&SUBSYS_00BA1414&REV_00\1')
        Native = @{ 'manage-bde.exe -status C:' = @{ ExitCode = 0; Output = "Conversion Status:    Fully Decrypted`r`nProtection Status:    Protection Off`r`n" } }
    }
    foreach ($e in $Extra.GetEnumerator()) { if ($e.Key -eq 'Keys') { $seed.Keys = @($seed.Keys) + @($e.Value) } else { $seed[$e.Key] = $e.Value } }
    New-AVDTuneFakeMachine -Seed $seed
}
function Invoke-Readiness($Machine, $Arm = $null, [string]$Token = 'tok', [string]$Gallery = $defId, $Block = $goodBlock) {
    Invoke-AVDTuneReadiness -Machine $Machine -Arm $Arm -Token $Token -GalleryImageId $Gallery -UpdateBlock $Block
}
function Get-Row($Result, [string]$Id) { @($Result.Rows | Where-Object Id -eq $Id)[0] }
function New-Arm([hashtable]$Vm = @{}, [hashtable]$Galleries = @{ def1 = $goodGallery }) { New-AVDTuneFakeArm -Seed @{ Vm = $Vm; Galleries = $Galleries } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-ready-' + [guid]::NewGuid().ToString('N'))
try {
    $env:AVDTUNE_ROOT = $tmp
    [void](Initialize-AVDTuneState -Root $tmp)
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-15') -User 'admin1')
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- the data
    $data = Get-AVDTuneReadinessData
    $crit = @($data.Criteria.PSObject.Properties)
    Test-Check 'data: loads, 29 criteria, a Stand date, 52 families' ($crit.Count -eq 29 -and $data.Stand -match '^\d{4}-\d{2}-\d{2}$' -and $data.Families.Count -eq 52) "$($crit.Count) / $($data.Families.Count)"
    Test-Check 'data: every criterion has a Microsoft Learn source, a date and the Verified flag' (-not (@($crit | Where-Object { $_.Value.Source -notmatch '^https://learn\.microsoft\.com/' -or $_.Value.Stand -notmatch '^\d{4}-\d{2}-\d{2}$' -or $_.Value.Verified -isnot [bool] }))) $null
    $unverified = @($crit | Where-Object { -not $_.Value.Verified } | ForEach-Object Name)
    Test-Check 'data: what Learn does not state is marked and explained (bitlocker, reboot markers, lcu thresholds, leftovers, public shortcut, FSLogix-Test)' ((($unverified | Sort-Object) -join ',') -eq 'hy.bitlocker,hy.fslogix-test,hy.lcu-age,hy.leftovers,hy.public-shortcut,hy.reboot' -and -not (@($crit | Where-Object { -not $_.Value.Verified -and -not $_.Value.Note }))) ($unverified -join ',')
    Test-Check 'data: the Arm64 families are the Cobalt ones' ((@($data.Families | Where-Object Arch -eq 'Arm64' | ForEach-Object Name | Sort-Object) -join ',') -eq 'Dpdsv6,Dpldsv6,Dplsv6,Dpsv6,Epdsv6,Epsv6') $null
    Test-Check 'data: local disk only on the d sizes (Ddsv6 NVMe, Dsv6 none), Dasv6 has ConnectX and no MANA, Ddsv6 MANA' ((@($data.Families | Where-Object Name -eq 'Ddsv6')[0].TempDisk -eq 'NVMe') -and (@($data.Families | Where-Object Name -eq 'Dsv6')[0].TempDisk -eq 'None') -and (@($data.Families | Where-Object Name -eq 'Dasv6')[0].Network -notcontains 'MANA') -and (@($data.Families | Where-Object Name -eq 'Ddsv6')[0].Network -contains 'MANA')) $null
    Test-Check 'data: the family patterns match their sizes' (('Standard_D4ds_v6' -match (@($data.Families | Where-Object Name -eq 'Ddsv6')[0].SizePattern)) -and ('Standard_D4s_v6' -notmatch (@($data.Families | Where-Object Name -eq 'Ddsv6')[0].SizePattern)) -and ('Standard_D4s_v6' -match (@($data.Families | Where-Object Name -eq 'Dsv6')[0].SizePattern))) $null
    Test-Check 'data: no GUID, host or tenant name in the file (public repo)' ((Get-Content (Get-AVDTuneReadinessDataPath) -Raw) -notmatch '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|\.onmicrosoft\.|\.sharepoint\.') $null
    $badDir = Join-Path $tmp 'baddata'; New-Item -ItemType Directory -Path $badDir | Out-Null
    $raw = Get-Content (Get-AVDTuneReadinessDataPath) -Raw
    Set-Content (Join-Path $badDir 'a.json') ($raw -replace '"Source": "https://learn\.microsoft\.com/en-us/azure/virtual-machines/enable-nvme-faqs"', '"Source": "http://example.invalid/x"') -Encoding UTF8
    Set-Content (Join-Path $badDir 'b.json') ($raw -replace '"Verified": false, "Note": "Microsoft sets no age limit[^"]*"', '"Verified": false') -Encoding UTF8
    Set-Content (Join-Path $badDir 'c.json') '{ "Schema": 1 }' -Encoding UTF8
    Test-Check 'data: a source that is not Microsoft Learn is refused' ((Get-ThrownText { Get-AVDTuneReadinessData -Path (Join-Path $badDir 'a.json') }) -like '*Microsoft Learn source*') $null
    Test-Check 'data: an unverified criterion without a note is refused' ((Get-ThrownText { Get-AVDTuneReadinessData -Path (Join-Path $badDir 'b.json') }) -like '*needs a note*') $null
    Test-Check 'data: a file without Stand and criteria is refused, a missing file too' ((Test-Throws { Get-AVDTuneReadinessData -Path (Join-Path $badDir 'c.json') }) -and (Test-Throws { Get-AVDTuneReadinessData -Path (Join-Path $badDir 'none.json') })) $null

    # ---------------------------------------------------------------- a healthy master
    $arm = New-Arm
    $r = Invoke-Readiness (New-Master) $arm
    $ids = @($r.Rows | ForEach-Object Id)
    Test-Check 'healthy master: every criterion of the data has a row, once (the FSLogix-Test row only with FSLogix)' ((($ids | Sort-Object -Unique).Count -eq $ids.Count) -and (@($crit | Where-Object { $_.Name -notin $ids -and $_.Name -ne 'hy.fslogix-test' }).Count -eq 0)) (@($crit | Where-Object { $_.Name -notin $ids } | ForEach-Object Name) -join ',')
    Test-Check 'healthy master: green overall, nothing red, yellow or unknown' ($r.Overall -eq 'green' -and $r.Counts.Red -eq 0 -and $r.Counts.Yellow -eq 0 -and $r.Counts.Unknown -eq 0) (($r.Rows | Where-Object { $_.Status -in 'red', 'yellow', 'unknown' } | ForEach-Object { "$($_.Id)=$($_.Status): $($_.Reason)" }) -join ' | ')
    Test-Check 'every row carries source, date and verified flag' (-not (@($r.Rows | Where-Object { $_.Source -notmatch '^https://learn' -or -not $_.Stand }))) $null
    $f = @($r.Families)
    Test-Check 'families: the x64 ones are ready, the Arm64 ones are not possible (no fix)' ((@($f | Where-Object { $_.Arch -eq 'x64' -and $_.Status -ne 'ready' }).Count -eq 0) -and (@($f | Where-Object { $_.Arch -eq 'Arm64' -and $_.Status -eq 'not-possible' }).Count -eq 6) -and ((@($f | Where-Object Name -eq 'Dpsv6')[0].Needs -join ' ') -like '*Arm64 image*')) $null
    Test-Check 'only GET went to Azure (read only)' (-not (@($arm.Log | Where-Object { $_ -notlike 'GET *' }))) ($arm.Log -join ' | ')
    Test-Check 'the VM size row names the family' ((Get-Row $r 'hw.vm-size').Reason -like '*Dsv6*') (Get-Row $r 'hw.vm-size').Reason

    # ---------------------------------------------------------------- no Azure access
    $r = Invoke-Readiness (New-Master) (New-Arm) ''
    $azRows = 'hw.disk-controller', 'hw.accelnet', 'hw.gallery'
    Test-Check 'no sign-in: the Azure checks are "not checkable" with the reason, the others still run' ((@($azRows | Where-Object { (Get-Row $r $_).Status -ne 'unknown' -or (Get-Row $r $_).Reason -notlike '*Not checkable*sign in*' }).Count -eq 0) -and (Get-Row $r 'hw.stornvme').Status -eq 'green' -and $r.Overall -eq 'yellow' -and -not $r.Arm.Ok) (Get-Row $r 'hw.gallery').Reason
    $r = Invoke-Readiness (New-Master) $null 'tok'
    Test-Check 'no Azure adapter at all is reported, not crashed on' ((Get-Row $r 'hw.disk-controller').Status -eq 'unknown' -and (Get-Row $r 'hw.disk-controller').Reason -like '*No Azure access is configured*') $null
    $off = New-Arm; $off.Store.Offline = $true
    $r = Invoke-Readiness (New-Master) $off
    Test-Check 'Azure offline: not checkable with the connection hint' ((Get-Row $r 'hw.disk-controller').Status -eq 'unknown' -and (Get-Row $r 'hw.disk-controller').Reason -like '*No connection to Azure Resource Manager*') (Get-Row $r 'hw.disk-controller').Reason
    $forbidden = New-Arm; $forbidden.Store.VmForbidden = $true
    $r = Invoke-Readiness (New-Master) $forbidden
    Test-Check '403 on the VM: not checkable, names the permission' ((Get-Row $r 'hw.disk-controller').Reason -like '*403*Microsoft.Compute/virtualMachines/read*') (Get-Row $r 'hw.disk-controller').Reason
    $nicForbidden = New-Arm; $nicForbidden.Store.NicForbidden = $true
    $r = Invoke-Readiness (New-Master) $nicForbidden
    Test-Check '403 on the NIC: only the accelerated networking check is not checkable' ((Get-Row $r 'hw.accelnet').Status -eq 'unknown' -and (Get-Row $r 'hw.disk-controller').Status -eq 'green') (Get-Row $r 'hw.accelnet').Reason
    $r = Invoke-AVDTuneReadiness -Machine (New-Master @{ Imds = $null }) -Arm (New-Arm) -Token 'tok' -UpdateBlock $goodBlock
    Test-Check 'not an Azure VM: the VM size and the Azure checks are not checkable, no crash' ((Get-Row $r 'hw.vm-size').Status -eq 'unknown' -and (Get-Row $r 'hw.disk-controller').Reason -like '*not an Azure VM*') (Get-Row $r 'hw.disk-controller').Reason

    # ---------------------------------------------------------------- hardware findings
    $r = Invoke-Readiness (New-Master) (New-Arm @{ DiskControllerType = 'SCSI' })
    Test-Check 'VM on SCSI: yellow, the conversion path is the hint, AVDTune does not convert' ((Get-Row $r 'hw.disk-controller').Status -eq 'yellow' -and (Get-Row $r 'hw.disk-controller').Reason -like '*SCSI*deallocated*AVDTune does not convert*') (Get-Row $r 'hw.disk-controller').Reason
    $r = Invoke-Readiness (New-Master) (New-Arm @{ DiskControllerType = '' })
    Test-Check 'Azure reports no controller type: not checkable' ((Get-Row $r 'hw.disk-controller').Status -eq 'unknown') $null

    $r = Invoke-Readiness (New-Master -Reg @{ 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme|Start' = 3 }) (New-Arm)
    $row = Get-Row $r 'hw.stornvme'
    Test-Check 'stornvme on demand: red with the fix id and the Learn command in the reason' ($row.Status -eq 'red' -and $row.FixId -eq 'readiness.stornvme-boot' -and $row.Reason -like '*sc.exe config stornvme start=boot*') $row.Reason
    Test-Check 'stornvme red: every family needs it and the list says so' ((@($r.Families | Where-Object { $_.Arch -eq 'x64' -and ($_.Status -ne 'after-fix' -or ($_.Needs -join ' ') -notlike '*stornvme*') }).Count -eq 0)) $null
    $m = New-Master; $m.Store.Registry.Remove('hklm:\system\currentcontrolset\services\stornvme|start'); [void]$m.Store.Keys.Remove('hklm:\system\currentcontrolset\services\stornvme')
    $r = Invoke-Readiness $m (New-Arm)
    Test-Check 'stornvme missing: red, no fix offered (AVDTune cannot add a driver)' ((Get-Row $r 'hw.stornvme').Status -eq 'red' -and -not (Get-Row $r 'hw.stornvme').FixId) $null
    $r = Invoke-Readiness (New-Master -Reg @{ 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme\Parameters|IoTimeoutValue' = 30 }) (New-Arm)
    Test-Check 'IoTimeoutValue 30: yellow; 240: green' ((Get-Row $r 'hw.nvme-timeout').Status -eq 'yellow' -and (Get-Row (Invoke-Readiness (New-Master -Reg @{ 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme\Parameters|IoTimeoutValue' = 240 }) (New-Arm)) 'hw.nvme-timeout').Status -eq 'green') $null

    $r = Invoke-Readiness (New-Master @{ NetAdapters = @(@{ Name = 'Ethernet'; Description = 'Microsoft Hyper-V Network Adapter'; Status = 'Up' }); Pnp = @('PCI\VEN_1414&DEV_00BA&SUBSYS_00BA1414&REV_00\1') }) (New-Arm)
    Test-Check 'MANA hardware without driver: red, the download is named' ((Get-Row $r 'hw.mana').Status -eq 'red' -and (Get-Row $r 'hw.mana').Fix -like '*aka.ms/manawindowsdrivers*') (Get-Row $r 'hw.mana').Reason
    Test-Check 'no MANA driver: the families that need MANA (Ddsv6) are after-fix, the ConnectX ones (Dasv6) are not' ((@($r.Families | Where-Object Name -eq 'Ddsv6')[0].Status -eq 'after-fix') -and (@($r.Families | Where-Object Name -eq 'Dasv6')[0].Status -eq 'ready')) (@($r.Families | Where-Object Name -eq 'Dasv6')[0].Status)
    $r = Invoke-Readiness (New-Master @{ NetAdapters = @(@{ Name = 'Ethernet'; Description = 'Microsoft Hyper-V Network Adapter'; Status = 'Up' }); Pnp = @() }) (New-Arm)
    Test-Check 'no MANA hardware on this VM: not checkable (the driver cannot be seen), not green' ((Get-Row $r 'hw.mana').Status -eq 'unknown' -and (Get-Row $r 'hw.mana').Reason -like '*without MANA*') (Get-Row $r 'hw.mana').Reason
    $r = Invoke-Readiness (New-Master) (New-Arm @{ Nics = @(@{ Name = 'nic1'; AccelNet = $true }, @{ Name = 'nic2'; AccelNet = $false }) })
    Test-Check 'accelerated networking off on one NIC: yellow, names the NIC' ((Get-Row $r 'hw.accelnet').Status -eq 'yellow' -and (Get-Row $r 'hw.accelnet').Reason -like '*nic2*' -and (Get-Row $r 'hw.accelnet').Reason -notlike '*nic1*') (Get-Row $r 'hw.accelnet').Reason

    $r = Invoke-Readiness (New-Master -Reg @{ 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management|PagingFiles' = @('D:\pagefile.sys 0 0') }) (New-Arm)
    Test-Check 'page file on D: is red, with how to move it; all families are after-fix' ((Get-Row $r 'hw.pagefile-d').Status -eq 'red' -and (Get-Row $r 'hw.pagefile-d').Fix -like '*C:*' -and (@($r.Families | Where-Object { $_.Arch -eq 'x64' -and $_.Status -ne 'after-fix' }).Count -eq 0)) (Get-Row $r 'hw.pagefile-d').Reason
    Test-Check 'the family list tells local disk (raw NVMe) from no local disk for D:' ((($r.Families | Where-Object Name -eq 'Ddsv6')[0].Needs -join ' ') -like '*raw*' -and (($r.Families | Where-Object Name -eq 'Dsv6')[0].Needs -join ' ') -like '*no local disk*') $null
    $r = Invoke-Readiness (New-Master -Reg @{ 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management|PagingFiles' = @('?:\pagefile.sys') }) (New-Arm)
    Test-Check 'the system-managed page file form is not flagged' ((Get-Row $r 'hw.pagefile-d').Status -eq 'green') $null
    $r = Invoke-Readiness (New-Master -Reg @{ 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment|TEMP' = 'D:\Temp'; 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment|TMP' = 'C:\Windows\TEMP'; 'HKLM:\SOFTWARE\FSLogix\Profiles|CacheDirectory' = 'D:\FSLogixCache' }) (New-Arm)
    Test-Check 'TEMP on D: and FSLogix cache on D: are yellow with the value' ((Get-Row $r 'hw.temp-env-d').Status -eq 'yellow' -and (Get-Row $r 'hw.temp-env-d').Reason -like '*TEMP=D:\Temp*' -and (Get-Row $r 'hw.temp-env-d').Reason -notlike '*TMP=*' -and (Get-Row $r 'hw.fslogix-d').Status -eq 'yellow' -and (Get-Row $r 'hw.fslogix-d').Reason -like '*CacheDirectory=D:\FSLogixCache*') (Get-Row $r 'hw.temp-env-d').Reason

    $r = Invoke-Readiness (New-Master @{ Firmware = 'BIOS' }) (New-Arm @{ HyperV = 'V1'; DiskHyperV = 'V1'; SecurityType = 'Standard' })
    Test-Check 'Generation 1: red, no plain conversion; all families not possible' ((Get-Row $r 'hw.firmware').Status -eq 'red' -and (Get-Row $r 'hw.firmware').Reason -like '*guest firmware BIOS*no plain conversion*' -and (@($r.Families | Where-Object { $_.Status -ne 'not-possible' }).Count -eq 0)) (Get-Row $r 'hw.firmware').Reason
    # #16: the test VM (26H2, Trusted Launch) had no PEFirmwareType (a Windows PE value) and ARM has no properties.extended (that is Resource Graph)
    $noGuest = { $x = New-Master @{ Firmware = $null }; $x.Store.Registry.Remove('hklm:\system\currentcontrolset\control\secureboot\state|uefisecurebootenabled'); $x }
    $m = & $noGuest
    $r = Invoke-Readiness $m $null ''
    Test-Check 'firmware not readable and no Azure: not checkable, says what was tried' ((Get-Row $r 'hw.firmware').Status -eq 'unknown' -and (Get-Row $r 'hw.firmware').Reason -like '*GetFirmwareType*') (Get-Row $r 'hw.firmware').Reason
    $r = Invoke-Readiness (New-Master) $null ''
    Test-Check '#16: GetFirmwareType UEFI alone (no PEFirmwareType, no Azure) is green' ((Get-Row $r 'hw.firmware').Status -eq 'green' -and (Get-Row $r 'hw.firmware').Found -like '*guest firmware UEFI*') (Get-Row $r 'hw.firmware').Reason
    $realArm = New-Arm
    $r = Invoke-Readiness (& $noGuest) $realArm
    Test-Check '#16: the answer of the test VM (no instanceView.hyperVGeneration): Gen2 from the OS disk and the security type, green' ((Get-Row $r 'hw.firmware').Status -eq 'green' -and (Get-Row $r 'hw.firmware').Found -like '*OS disk V2*security type TrustedLaunch*' -and @($realArm.Log | Where-Object { $_ -like 'GET */disks/gm-test01_osdisk?api-version=2023-10-02' }).Count -eq 1) (Get-Row $r 'hw.firmware').Reason
    $r = Invoke-Readiness (& $noGuest) (New-Arm @{ DiskHyperV = '' })
    Test-Check 'no generation on the disk either: Trusted Launch (needs Gen2) is enough for green' ((Get-Row $r 'hw.firmware').Status -eq 'green' -and (Get-Row $r 'hw.firmware').Found -eq 'security type TrustedLaunch (needs Generation 2)') (Get-Row $r 'hw.firmware').Found
    $imdsSb = New-Imds; $imdsSb.compute | Add-Member -NotePropertyName securityProfile -NotePropertyValue ([pscustomobject]@{ secureBootEnabled = 'true'; virtualTpmEnabled = 'true' })
    $m = & $noGuest; $m.Store.Imds = $imdsSb
    $r = Invoke-Readiness $m $null ''
    Test-Check 'only the instance metadata (securityProfile.secureBootEnabled) answers: green' ((Get-Row $r 'hw.firmware').Status -eq 'green' -and (Get-Row $r 'hw.firmware').Found -like '*instance metadata*') (Get-Row $r 'hw.firmware').Found
    $r = Invoke-Readiness (& $noGuest) (New-Arm @{ DiskHyperV = 'V1'; SecurityType = 'Standard' })
    Test-Check 'the OS disk says V1: red even when the guest cannot tell' ((Get-Row $r 'hw.firmware').Status -eq 'red' -and (Get-Row $r 'hw.firmware').Reason -like '*OS disk V1*') (Get-Row $r 'hw.firmware').Reason
    $r = Invoke-Readiness (New-Master @{ Firmware = 'BIOS' }) (New-Arm)
    Test-Check 'sources disagree (guest BIOS, Azure V2): red and says to check' ((Get-Row $r 'hw.firmware').Status -eq 'red' -and (Get-Row $r 'hw.firmware').Reason -like '*Other sources say otherwise*') (Get-Row $r 'hw.firmware').Reason
    $realFw = & (New-AVDTuneMachine).FirmwareType
    Test-Check 'the real adapter asks GetFirmwareType (read only): UEFI, BIOS or nothing' ($null -eq $realFw -or $realFw -in 'UEFI', 'BIOS') $realFw
    $r = Invoke-Readiness (New-Master -Reg @{ 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State|UEFISecureBootEnabled' = 0 }) (New-Arm)
    Test-Check 'Secure Boot off: yellow' ((Get-Row $r 'hw.securestart').Status -eq 'yellow' -and (Get-Row $r 'hw.securestart').Reason -like '*Secure Boot: off*') (Get-Row $r 'hw.securestart').Reason
    $r = Invoke-Readiness (New-Master @{ Tpm = $false }) (New-Arm)
    Test-Check 'no vTPM: yellow' ((Get-Row $r 'hw.securestart').Status -eq 'yellow' -and (Get-Row $r 'hw.securestart').Reason -like '*vTPM: none*') $null
    $r = Invoke-Readiness (New-Master @{ Arch = 'ARM64' }) (New-Arm)
    Test-Check 'Arm64 master: only the Arm64 families fit, the x64 ones are not possible' ((Get-Row $r 'hw.arch').Reason -like 'Arm64:*' -and (@($r.Families | Where-Object { $_.Arch -eq 'x64' -and $_.Status -ne 'not-possible' }).Count -eq 0) -and (@($r.Families | Where-Object { $_.Arch -eq 'Arm64' -and $_.Status -eq 'ready' }).Count -eq 6)) (Get-Row $r 'hw.arch').Reason

    # ---------------------------------------------------------------- gallery definition
    $r = Invoke-Readiness (New-Master) (New-Arm) 'tok' ''
    Test-Check '#16: no gallery visible: yellow with the explanation (created later, e.g. by Hydra), not "not checkable"' ((Get-Row $r 'hw.gallery').Status -eq 'yellow' -and (Get-Row $r 'hw.gallery').Reason -like '*No Azure Compute Gallery is visible*in 1 subscription(s)*created later*Hydra*') (Get-Row $r 'hw.gallery').Reason

    # ---- #16: the gallery search, with answers as the real ARM gives them (ids, paging with nextLink, a 403 on one subscription)
    $sub2 = 'bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee'; $sub3 = 'cccccccc-bbbb-cccc-dddd-eeeeeeeeeeee'
    $vmRes = "/subscriptions/$sub/resourceGroups/rg-example/providers/Microsoft.Compute/virtualMachines/gm-test01"
    $diskRes = "/subscriptions/$sub/resourceGroups/rg-example/providers/Microsoft.Compute/disks/gm-test01_osdisk"
    $scsiOnly = @(@{ name = 'DiskControllerTypes'; value = 'SCSI' }, @{ name = 'SecurityType'; value = 'TrustedLaunchSupported' })
    $newSearch = {
        param([hashtable]$AvdVersion = @{ Name = '2026.11.1'; SourceVm = "/subscriptions/$sub/resourceGroups/rg-other/providers/Microsoft.Compute/virtualMachines/other-vm" })
        @{ Paging = $true
            Subscriptions = @(@{ Id = $sub; Name = 'Example subscription' }, @{ Id = $sub3; Name = 'Locked subscription'; Forbidden = $true }, @{ Id = $sub2; Name = 'Second subscription' })
            Galleries = @(
                @{ Sub = $sub; Rg = 'rg-images'; Name = 'galA'; Images = @(
                        @{ Name = 'win11-avd'; Features = $goodGallery.Features; Versions = @($AvdVersion, @{ Name = '2026.10.1'; SourceVm = "/subscriptions/$sub/resourceGroups/rg-other/providers/Microsoft.Compute/virtualMachines/old-master"; Published = '2026-10-01' }) }
                        @{ Name = 'win11-scsi'; Features = $scsiOnly; Versions = @(@{ Name = '1.0.0'; SourceVm = "/subscriptions/$sub/resourceGroups/rg-other/providers/Microsoft.Compute/virtualMachines/other-vm" }) }
                        @{ Name = 'ubuntu'; OsType = 'Linux'; Features = $goodGallery.Features })
                }
                @{ Sub = $sub2; Rg = 'rg-x'; Name = 'galB'; Images = @(@{ Name = 'win10-gen1'; HyperV = 'V1' }, @{ Name = 'win11-arm'; Architecture = 'Arm64'; Features = $goodGallery.Features }) }
            )
        }
    }
    $sArm = New-AVDTuneFakeArm -Seed @{ Search = (& $newSearch @{ Name = '2026.11.1'; SourceVm = $vmRes; Published = '2026-11-14' }) }
    $r = Invoke-Readiness (New-Master) $sArm 'tok' ''
    $row = Get-Row $r 'hw.gallery'
    Test-Check 'a version captured from this VM (source.virtualMachineId): the definition is taken automatically and checked (green)' ($row.Status -eq 'green' -and $r.GallerySource -eq 'Matched' -and $r.GalleryImageId -eq "/subscriptions/$sub/resourceGroups/rg-images/providers/Microsoft.Compute/galleries/galA/images/win11-avd" -and $row.Reason -like '*galA/win11-avd, found automatically: version 2026.11.1 was captured from this VM*') $row.Reason
    Test-Check 'the search reads only (GET), follows nextLink pages, reads the other subscription after the 403 one' ((-not @($sArm.Log | Where-Object { $_ -notlike 'GET *' })) -and @($sArm.Log | Where-Object { $_ -like '*fakepage=2*' }).Count -gt 0 -and @($sArm.Log | Where-Object { $_ -like "GET /subscriptions/$sub2/providers/Microsoft.Compute/galleries?*" }).Count -ge 1 -and @($sArm.Log | Where-Object { $_ -like '*/galB/images?*' }).Count -ge 1) ($sArm.Log -join ' | ')
    Test-Check 'Linux definitions are not searched for versions' (-not @($sArm.Log | Where-Object { $_ -like '*/images/ubuntu/versions*' })) $null
    $sArm = New-AVDTuneFakeArm -Seed @{ Search = (& $newSearch @{ Name = '2026.11.2'; SourceId = $diskRes }) }
    $r = Invoke-Readiness (New-Master) $sArm 'tok' ''
    Test-Check 'a version made from the OS disk (source.id) is found' ($r.GallerySource -eq 'Matched' -and $r.GalleryMatch.How -like '*OS disk of this VM*') $r.GalleryMatch.How
    $snapRes = "/subscriptions/$sub/resourceGroups/rg-example/providers/Microsoft.Compute/snapshots/gm-test01_osdisk-14.11.2026-1"
    $sArm = New-AVDTuneFakeArm -Seed @{ Snapshots = @(@{ Name = 'gm-test01_osdisk-14.11.2026-1'; Created = [datetime]'2026-11-14 08:00' }); Search = (& $newSearch @{ Name = '2026.11.3'; OsDiskSourceId = $snapRes }) }
    $r = Invoke-Readiness (New-Master) $sArm 'tok' ''
    Test-Check 'a version made from a snapshot of the OS disk (osDiskImage.source.id) is found' ($r.GallerySource -eq 'Matched' -and $r.GalleryMatch.How -like '*snapshot gm-test01_osdisk-14.11.2026-1*') $r.GalleryMatch.How
    $miRes = "/subscriptions/$sub/resourceGroups/rg-images/providers/Microsoft.Compute/images/gm-test01-image"
    $srch = & $newSearch @{ Name = '2026.11.4'; SourceId = $miRes }; $srch.ManagedImages = @{ $miRes = $vmRes }
    $r = Invoke-Readiness (New-Master) (New-AVDTuneFakeArm -Seed @{ Search = $srch }) 'tok' ''
    Test-Check 'a version made from a managed image of this VM is found' ($r.GallerySource -eq 'Matched' -and $r.GalleryMatch.How -like '*managed image of this VM*') $r.GalleryMatch.How
    $sArm = New-AVDTuneFakeArm -Seed @{ Search = (& $newSearch) }
    $r = Invoke-Readiness (New-Master) $sArm 'tok' ''
    $row = Get-Row $r 'hw.gallery'
    $labels = @($r.GalleryCandidates | ForEach-Object { $_.Name })
    Test-Check 'no version from this VM, several definitions: yellow, choose from the Windows Gen2 x64 ones (fitting first), not "not checkable"' ($row.Status -eq 'yellow' -and $row.Reason -like '*2 Windows Generation 2 definition(s) fit*choose*' -and (($labels -join ',') -eq 'win11-avd,win11-scsi') -and $r.GalleryCandidates[0].Fits -and -not $r.GalleryCandidates[1].Fits -and $r.GalleryCandidates[1].Label -like '*no NVMe*') "$($row.Reason) / $($labels -join ',')"
    Test-Check 'the 403 on one subscription is named in the reason, the search went on' ($row.Reason -like '*Locked subscription*403*galleries/read*') $row.Reason
    $only = @{ Subscriptions = @(@{ Id = $sub; Name = 'Example subscription' }); Galleries = @(@{ Sub = $sub; Rg = 'rg-x'; Name = 'galL'; Images = @(@{ Name = 'ubuntu'; OsType = 'Linux' }, @{ Name = 'win10-gen1'; HyperV = 'V1' }) }) }
    $r = Invoke-Readiness (New-Master) (New-AVDTuneFakeArm -Seed @{ Search = $only }) 'tok' ''
    Test-Check 'galleries without a fitting definition: yellow, says how to get one' ((Get-Row $r 'hw.gallery').Status -eq 'yellow' -and (Get-Row $r 'hw.gallery').Reason -like '*have no Windows Generation 2 definition*' -and @($r.GalleryCandidates).Count -eq 0) (Get-Row $r 'hw.gallery').Reason
    $locked = @{ Subscriptions = @(@{ Id = $sub; Name = 'Example subscription'; Forbidden = $true }); Galleries = @() }
    $r = Invoke-Readiness (New-Master) (New-AVDTuneFakeArm -Seed @{ Search = $locked }) 'tok' ''
    Test-Check '403 on the only subscription: yellow, with the permission named' ((Get-Row $r 'hw.gallery').Status -eq 'yellow' -and (Get-Row $r 'hw.gallery').Reason -like '*No Azure Compute Gallery is visible*403*') (Get-Row $r 'hw.gallery').Reason
    $idn = Get-AVDTuneVmIdentity (New-Master)
    $s = Find-AVDTuneGalleryImage -Arm (New-AVDTuneFakeArm -Seed @{ Search = (& $newSearch) }) -Token 'tok' -Identity $idn -OsArch 'AMD64' -Limits @{ Subscriptions = 1 }
    Test-Check 'limit: only N subscriptions (this VM first), said so' ($s.Subscriptions -eq 1 -and (@($s.Limited) -join ' ') -like '*only 1 of 3 subscriptions*') (@($s.Limited) -join ' ')
    $s = Find-AVDTuneGalleryImage -Arm (New-AVDTuneFakeArm -Seed @{ Search = (& $newSearch) }) -Token 'tok' -Identity $idn -OsArch 'AMD64' -Limits @{ Requests = 3 }
    Test-Check 'limit: the search stops after N requests and says so, no throw' ($s.Requests -le 3 -and (@($s.Limited) -join ' ') -like '*stopped after 3 requests*') (@($s.Limited) -join ' ')
    $evil = [pscustomobject]@{ Log = (New-Object System.Collections.ArrayList); Invoke = $null }
    $evil.Invoke = { param($Method, $Path, $Token, $Body) [void]$evil.Log.Add("$Method $Path"); if ($Path.StartsWith('/subscriptions?')) { [pscustomobject]@{ Status = 200; Body = [pscustomobject]@{ value = @(); nextLink = 'https://evil.example/subscriptions?api-version=1' }; Error = '' } } else { [pscustomobject]@{ Status = 200; Body = [pscustomobject]@{ value = @() }; Error = '' } } }.GetNewClosure()
    $s = Find-AVDTuneGalleryImage -Arm $evil -Token 'tok' -Identity $idn -OsArch 'AMD64'
    Test-Check 'a nextLink to another host is not followed (noted), the search still reads this subscription' ((@($s.Notes) -join ' ') -like '*another host*' -and -not @($evil.Log | Where-Object { $_ -like '*evil*' }) -and @($evil.Log | Where-Object { $_ -like "GET /subscriptions/$sub/providers/Microsoft.Compute/galleries?*" }).Count -eq 1) (@($s.Notes) -join ' ')
    $evil2 = [pscustomobject]@{ Log = (New-Object System.Collections.ArrayList); Invoke = $null }
    $evil2.Invoke = { param($Method, $Path, $Token, $Body) [void]$evil2.Log.Add("$Method $Path"); if ($Path.StartsWith('/subscriptions?')) { [pscustomobject]@{ Status = 200; Body = [pscustomobject]@{ value = @(); nextLink = "https://management.azure.com/subscriptions/$sub/resourceGroups/rg/providers/Microsoft.Compute/snapshots/x?api-version=1" }; Error = '' } } else { [pscustomobject]@{ Status = 200; Body = [pscustomobject]@{ value = @() }; Error = '' } } }.GetNewClosure()
    $s = Find-AVDTuneGalleryImage -Arm $evil2 -Token 'tok' -Identity $idn -OsArch 'AMD64'
    Test-Check 'a nextLink on the ARM host to another resource is not followed either' ((@($s.Notes) -join ' ') -like '*another resource*' -and -not @($evil2.Log | Where-Object { $_ -like '*snapshots/x*' })) (@($s.Notes) -join ' ')
    $real = New-AVDTuneArmAdapter
    $dirty = "evil`r`nINJECT " + ('x' * 200)
    $labelArm = [pscustomobject]@{ Invoke = { param($Method, $Path, $Token, $Body)
            $body = switch -Wildcard ($Path) {
                "/subscriptions/$sub/providers/Microsoft.Compute/galleries?*" { @{ value = @(@{ id = "/subscriptions/$sub/resourceGroups/rg/providers/Microsoft.Compute/galleries/galZ"; name = $dirty }) } }
                '*/galleries/galZ/images?*' { @{ value = @(@{ id = "/subscriptions/$sub/resourceGroups/rg/providers/Microsoft.Compute/galleries/galZ/images/defZ"; name = $dirty; properties = @{ osType = 'Windows'; hyperVGeneration = 'V2' } }) } }
                default { @{ value = @() } }  # '/subscriptions?*' also matches '/subscriptions/', so the specific paths come first
            }
            [pscustomobject]@{ Status = 200; Body = ([pscustomobject]$body | ConvertTo-Json -Depth 8 | ConvertFrom-Json); Error = '' } }.GetNewClosure() }
    $s = Find-AVDTuneGalleryImage -Arm $labelArm -Token 'tok' -Identity $idn -OsArch 'AMD64'
    $lbl = [string]@($s.Candidates)[0].Label
    Test-Check 'labels from ARM names: no control characters, each name at most 80 characters' (@($s.Candidates).Count -eq 1 -and $lbl -notmatch '[\x00-\x1F\x7F]' -and $lbl.Length -lt 260 -and $lbl -like 'evil INJECT*') ("$lbl | " + (@($s.Notes) -join ' '))
    $refused = @(@('POST', '/subscriptions?api-version=2022-12-01'), @('PUT', '/subscriptions?api-version=2022-12-01'), @('DELETE', '/subscriptions?api-version=2022-12-01'), @('PATCH', '/subscriptions?api-version=2022-12-01'), @('GET', '/subscriptions'), @('GET', '/tenants?api-version=2022-12-01'), @('GET', '/subscriptions?api-version=1?x=2'), @('GET', '/subscriptions?api-version=1#x') | ForEach-Object { [string](& $real.Invoke $_[0] $_[1] 'tok' $null).Error })
    Test-Check 'real adapter: the subscription list is GET only, other paths outside a subscription stay refused (no network)' (@($refused | Where-Object { $_ -notlike 'Refused*' }).Count -eq 0) ($refused -join ' | ')
    $r = Invoke-Readiness (New-Master) (New-Arm) 'tok' "$defId/versions/1.0.0"
    Test-Check 'a version suffix is dropped, definition with NVMe, Trusted Launch and accelerated networking is green' ((Get-Row $r 'hw.gallery').Status -eq 'green' -and $r.GalleryImageId -eq $defId) (Get-Row $r 'hw.gallery').Reason
    $r = Invoke-Readiness (New-Master) (New-Arm @{} @{ def1 = @{ Features = @(@{ name = 'SecurityType'; value = 'TrustedLaunchSupported' }); Architecture = 'x64'; HyperV = 'V2' } })
    Test-Check 'definition without NVMe: red, names why an image from it cannot be used' ((Get-Row $r 'hw.gallery').Status -eq 'red' -and (Get-Row $r 'hw.gallery').Reason -like "*DiskControllerType is 'not set'*cannot be used for NVMe*") (Get-Row $r 'hw.gallery').Reason
    $r = Invoke-Readiness (New-Master) (New-Arm @{} @{ def1 = @{ Features = @(@{ name = 'DiskControllerType'; value = 'SCSI' }); Architecture = 'x64'; HyperV = 'V2' } })
    Test-Check 'definition with SCSI only: red' ((Get-Row $r 'hw.gallery').Status -eq 'red') $null
    $r = Invoke-Readiness (New-Master) (New-Arm @{} @{ def1 = @{ Features = @(@{ name = 'DiskControllerType'; value = 'SCSI, NVMe' }, @{ name = 'SecurityType'; value = 'Standard' }); Architecture = 'x64'; HyperV = 'V2' } })
    Test-Check 'the singular spelling DiskControllerType is accepted; Standard security and no accelerated flag are yellow' ((Get-Row $r 'hw.gallery').Status -eq 'yellow' -and (Get-Row $r 'hw.gallery').Reason -like "*SecurityType is 'Standard'*IsAcceleratedNetworkSupported is 'not set'*") (Get-Row $r 'hw.gallery').Reason
    $r = Invoke-Readiness (New-Master) (New-Arm @{} @{ def1 = @{ Features = $goodGallery.Features; Architecture = 'Arm64'; HyperV = 'V1' } })
    Test-Check 'definition for Arm64 and Generation 1 against an x64 master: red' ((Get-Row $r 'hw.gallery').Status -eq 'red' -and (Get-Row $r 'hw.gallery').Reason -like '*V1*' -and (Get-Row $r 'hw.gallery').Reason -like '*Arm64 but this master is x64*') (Get-Row $r 'hw.gallery').Reason
    $r = Invoke-Readiness (New-Master) (New-Arm @{} @{})
    Test-Check 'definition not found (404): not checkable' ((Get-Row $r 'hw.gallery').Status -eq 'unknown' -and (Get-Row $r 'hw.gallery').Reason -like '*404*') (Get-Row $r 'hw.gallery').Reason
    $gf = New-Arm; $gf.Store.GalleryForbidden = $true
    $r = Invoke-Readiness (New-Master) $gf
    Test-Check 'definition not readable (403): not checkable, names the permission' ((Get-Row $r 'hw.gallery').Status -eq 'unknown' -and (Get-Row $r 'hw.gallery').Reason -like '*galleries/images/read*') (Get-Row $r 'hw.gallery').Reason
    $badArm = New-Arm
    $r = Invoke-Readiness (New-Master) $badArm 'tok' 'not-an-id'
    Test-Check 'a malformed definition ID is ignored, never sent to Azure' ((Get-Row $r 'hw.gallery').Status -eq 'yellow' -and -not $r.GalleryImageId -and -not (@($badArm.Log | Where-Object { $_ -like '*not-an-id*' }))) $null
    $r = Invoke-Readiness (New-Master) (New-Arm @{ ImageRefId = "$defId/versions/2026.11.1" }) 'tok' ''
    Test-Check 'without a setting the definition comes from the VM image reference when it is a gallery image' ((Get-Row $r 'hw.gallery').Status -eq 'green' -and $r.GalleryImageId -eq $defId) (Get-Row $r 'hw.gallery').Reason

    # ---- #16: the chosen definition in environment.json, with a change log entry
    $envRoot = Join-Path $tmp 'envtest'; [void](Initialize-AVDTuneState -Root $envRoot); [void](Start-AVDTuneImageVersion -Root $envRoot -Date ([datetime]'2026-11-15') -User 'admin1')
    $avdId = "/subscriptions/$sub/resourceGroups/rg-images/providers/Microsoft.Compute/galleries/galA/images/win11-avd"
    Test-Check 'choosing needs the first-run answers' ((Get-ThrownText { Set-AVDTuneEnvironmentGallery -Root $envRoot -DefinitionId $avdId -User 'admin1' }) -like '*first-run*') $null
    [void](Save-AVDTuneEnvironment -Root $envRoot -Answers (Get-AVDTuneEnvironmentDefaults) -User 'admin1')
    $logBefore = @(Get-AVDTuneChangeLog -Root $envRoot).Count
    $t = Set-AVDTuneEnvironmentGallery -Root $envRoot -DefinitionId $avdId -Label 'galA / win11-avd' -User 'admin1'
    $envNow = Get-AVDTuneEnvironment $envRoot
    Test-Check 'the choice is saved in environment.json (id, label, who, when) and goes into the change log' ((Get-AVDTuneEnvironmentGallery $envNow) -eq $avdId -and $envNow.Gallery.ChosenBy -eq 'admin1' -and $t -like '*none -> galA/win11-avd*' -and @(Get-AVDTuneChangeLog -Root $envRoot).Count -eq ($logBefore + 1)) $t
    Test-Check 'the same choice again changes nothing' ((Set-AVDTuneEnvironmentGallery -Root $envRoot -DefinitionId $avdId -User 'admin1') -eq '' -and @(Get-AVDTuneChangeLog -Root $envRoot).Count -eq ($logBefore + 1)) $null
    Test-Check 'only a gallery image definition ID is accepted' ((Get-ThrownText { Set-AVDTuneEnvironmentGallery -Root $envRoot -DefinitionId "$avdId/versions/1.0.0" -User 'admin1' }) -like '*not the Resource ID*' -and (Test-Throws { Set-AVDTuneEnvironmentGallery -Root $envRoot -DefinitionId '/subscriptions/x/../y' -User 'admin1' })) $null
    $a = Get-AVDTuneEnvironmentAnswers (Get-AVDTuneEnvironment $envRoot); $a.Profiles = 'None'
    [void](Save-AVDTuneEnvironment -Root $envRoot -Answers $a -User 'admin1')
    [void](Set-AVDTuneEnvironmentSignIn -Root $envRoot -TenantId '11111111-2222-3333-4444-555555555555' -User 'admin1')
    Test-Check 'saving the answers or the sign-in keeps the chosen definition' ((Get-AVDTuneEnvironmentGallery (Get-AVDTuneEnvironment $envRoot)) -eq $avdId) $null
    $r = Invoke-Readiness (New-Master) (New-AVDTuneFakeArm -Seed @{ Search = (& $newSearch) }) 'tok' (Get-AVDTuneEnvironmentGallery (Get-AVDTuneEnvironment $envRoot))
    Test-Check 'with the chosen definition the row is checked (green) and names it as chosen; no search' ((Get-Row $r 'hw.gallery').Status -eq 'green' -and (Get-Row $r 'hw.gallery').Reason -like '*galA/win11-avd, chosen*' -and $r.GallerySource -eq 'Saved' -and @($r.GalleryCandidates).Count -eq 0) (Get-Row $r 'hw.gallery').Reason
    $t = Set-AVDTuneEnvironmentGallery -Root $envRoot -DefinitionId '' -User 'admin1'
    Test-Check 'clearing the choice is saved and logged' ((Get-AVDTuneEnvironmentGallery (Get-AVDTuneEnvironment $envRoot)) -eq '' -and $t -like '*-> none*') $t

    # ---------------------------------------------------------------- Windows
    $m = New-Master -Reg @{ "$win|CurrentBuildNumber" = '22631'; "$win|UBR" = 7714 }
    $r = Invoke-Readiness $m (New-Arm)
    Test-Check 'Windows 23H2 is out of service: red' ((Get-Row $r 'hy.windows-support').Status -eq 'red' -and (Get-Row $r 'hy.windows-support').Reason -like '*out of service*') (Get-Row $r 'hy.windows-support').Reason
    $r = Invoke-Readiness (New-Master -Reg @{ "$win|CurrentBuildNumber" = '77777' }) (New-Arm)
    Test-Check 'a build that is not in the table: yellow, says so with the Stand' ((Get-Row $r 'hy.windows-support').Status -eq 'yellow' -and (Get-Row $r 'hy.windows-support').Reason -like "*not in the table*Stand $($data.Stand)*") (Get-Row $r 'hy.windows-support').Reason
    $r = Invoke-AVDTuneReadiness -Machine (New-Master @{ Now = [datetime]'2027-08-01' }) -Arm (New-Arm) -Token 'tok' -GalleryImageId $defId -UpdateBlock $goodBlock
    Test-Check 'Windows 24H2 ends 2027-10-12: within 180 days it is yellow, with the date' ((Get-Row $r 'hy.windows-support').Status -eq 'yellow' -and (Get-Row $r 'hy.windows-support').Reason -like '*2027-10-12*') (Get-Row $r 'hy.windows-support').Reason
    $r = Invoke-AVDTuneReadiness -Machine (New-Master @{ Now = [datetime]'2027-11-01' }) -Arm (New-Arm) -Token 'tok' -GalleryImageId $defId -UpdateBlock $goodBlock
    Test-Check 'after the end date: red' ((Get-Row $r 'hy.windows-support').Status -eq 'red') $null
    $r = Invoke-Readiness (New-Master -Reg @{ "$win|EditionID" = 'Enterprise' }) (New-Arm)
    Test-Check 'not Enterprise multi-session: yellow with the edition' ((Get-Row $r 'hy.windows-support').Status -eq 'yellow' -and (Get-Row $r 'hy.windows-support').Reason -like '*Enterprise, not Enterprise multi-session*') (Get-Row $r 'hy.windows-support').Reason

    $r = Invoke-Readiness (New-Master @{ Hotfixes = @(@{ Id = 'KB1'; InstalledOn = [datetime]'2026-09-20' }) }) (New-Arm)
    Test-Check 'last update 56 days ago: yellow (own threshold, marked unverified)' ((Get-Row $r 'hy.lcu-age').Status -eq 'yellow' -and (Get-Row $r 'hy.lcu-age').Verified -eq $false) (Get-Row $r 'hy.lcu-age').Reason
    $r = Invoke-Readiness (New-Master @{ Hotfixes = @(@{ Id = 'KB1'; InstalledOn = [datetime]'2026-05-01' }) }) (New-Arm)
    Test-Check 'last update 198 days ago: red' ((Get-Row $r 'hy.lcu-age').Status -eq 'red') (Get-Row $r 'hy.lcu-age').Reason
    $r = Invoke-Readiness (New-Master @{ Hotfixes = @() }) (New-Arm)
    Test-Check 'no dated update in the list: not checkable' ((Get-Row $r 'hy.lcu-age').Status -eq 'unknown') $null
    $r = Invoke-Readiness (New-Master -Reg @{ "$win|UBR" = 4652 }) (New-Arm)
    Test-Check 'a build behind the newest known one is at least yellow, with both builds' ((Get-Row $r 'hy.lcu-age').Status -eq 'yellow' -and (Get-Row $r 'hy.lcu-age').Reason -like '*26100.4652*26100.9974*') (Get-Row $r 'hy.lcu-age').Reason

    # ---------------------------------------------------------------- hygiene
    $r = Invoke-Readiness (New-Master @{ Services = @(@{ Name = 'WindowsAzureGuestAgent' }, @{ Name = 'RDAgentBootLoader' }) ; Keys = @('HKLM:\SOFTWARE\Microsoft\RDInfraAgent') } -Reg @{ 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent|RegistrationToken' = 'eyJexample' }) (New-Arm)
    Test-Check 'AVD agent, boot loader and a registration token: red each' ((Get-Row $r 'hy.avd-agent').Status -eq 'red' -and (Get-Row $r 'hy.reg-token').Status -eq 'red') $null
    # A fresh Marketplace image has the Azure VM Agent, whose service is called 'RdAgent': that is not the AVD agent (seen on the test VM)
    $r = Invoke-Readiness (New-Master @{ Services = @(@{ Name = 'WindowsAzureGuestAgent' }, @{ Name = 'RdAgent' }) }) (New-Arm)
    Test-Check 'Azure VM Agent service RdAgent alone is not the AVD agent: green' ((Get-Row $r 'hy.avd-agent').Status -eq 'green') (Get-Row $r 'hy.avd-agent').Reason
    Test-Check 'the token itself is never part of the result' ((($r | ConvertTo-Json -Depth 8) -notlike '*eyJexample*')) $null
    $r = Invoke-Readiness (New-Master @{ Native = @{ 'dsregcmd.exe /status' = @{ ExitCode = 0; Output = "    AzureAdJoined : YES`r`n    DomainJoined : YES" }; 'manage-bde.exe -status C:' = @{ ExitCode = 0; Output = "Protection Status:    Protection Off" } } }) (New-Arm)
    Test-Check 'joined to a domain and Entra ID: red, both named' ((Get-Row $r 'hy.join').Status -eq 'red' -and (Get-Row $r 'hy.join').Reason -like '*Microsoft Entra ID and a domain*') (Get-Row $r 'hy.join').Reason
    $r = Invoke-Readiness (New-Master @{ Native = @{ 'dsregcmd.exe /status' = @{ ExitCode = 1; Output = '' }; 'manage-bde.exe -status C:' = @{ ExitCode = 1; Output = '' } } }) (New-Arm)
    Test-Check 'dsregcmd and manage-bde without an answer: not checkable' ((Get-Row $r 'hy.join').Status -eq 'unknown' -and (Get-Row $r 'hy.bitlocker').Status -eq 'unknown') $null
    $r = Invoke-Readiness (New-Master @{ Native = @{ 'manage-bde.exe -status C:' = @{ ExitCode = 0; Output = "Conversion Status:    Fully Encrypted`r`nProtection Status:    Protection On" } } }) (New-Arm)
    Test-Check 'BitLocker on: yellow, not red (not verified on Learn)' ((Get-Row $r 'hy.bitlocker').Status -eq 'yellow') $null
    $r = Invoke-Readiness (New-Master @{ Keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') }) (New-Arm)
    Test-Check 'restart pending: yellow' ((Get-Row $r 'hy.reboot').Status -eq 'yellow') $null
    $r = Invoke-Readiness (New-Master -Reg @{ 'HKLM:\SYSTEM\Setup|SystemSetupInProgress' = 1 }) (New-Arm)
    Test-Check 'Windows setup still running: red' ((Get-Row $r 'hy.reboot').Status -eq 'red') $null
    $r = Invoke-Readiness (New-Master) (New-Arm) 'tok' $defId ([pscustomobject]@{ State = 'Off'; Compliant = 0; Applicable = 12; Missing = 'Windows' })
    Test-Check 'update block off: red with the fix' ((Get-Row $r 'hy.update-block').Status -eq 'red' -and (Get-Row $r 'hy.update-block').FixId -eq 'readiness.updateblock-on') $null
    $r = Invoke-Readiness (New-Master) (New-Arm) 'tok' $defId ([pscustomobject]@{ State = 'Partial'; Compliant = 5; Applicable = 12; Missing = 'Edge' })
    Test-Check 'update block partly on: yellow with what is missing' ((Get-Row $r 'hy.update-block').Status -eq 'yellow' -and (Get-Row $r 'hy.update-block').Reason -like '*Edge*') $null
    $r = Invoke-AVDTuneReadiness -Machine (New-Master) -Arm (New-Arm) -Token 'tok' -GalleryImageId $defId
    $fslOff = Invoke-Readiness (New-Master)
    Test-Check 'FSLogix-Test: not part of the analysis when the environment has no FSLogix' (-not (Get-Row $fslOff 'hy.fslogix-test')) $null
    $fslRun = { param($rec) Invoke-AVDTuneReadiness -Machine (New-Master) -Arm $null -Token '' -GalleryImageId $defId -UpdateBlock $goodBlock -FSLogixApplies $true -FSLogixTest $rec }
    $fn = & $fslRun $null
    $fg = & $fslRun ([pscustomobject]@{ At = '2026-11-15T09:00:00.0000000'; Overall = 'green'; Red = 0; Yellow = 0; OpenIds = @() })
    $fy = & $fslRun ([pscustomobject]@{ At = '2026-11-15T09:00:00.0000000'; Overall = 'yellow'; Red = 0; Yellow = 2; OpenIds = @('fs.defender', 'fs.admins') })
    $fr = & $fslRun ([pscustomobject]@{ At = '2026-11-15T09:00:00.0000000'; Overall = 'red'; Red = 1; Yellow = 0; OpenIds = @('fs.services') })
    Test-Check 'FSLogix-Test not run: yellow with the fix; green test: green; yellow test: yellow with the ids; red test: red (blocks Finish)' ((Get-Row $fn 'hy.fslogix-test').Status -eq 'yellow' -and (Get-Row $fn 'hy.fslogix-test').Fix -like '*FSLogix page*' -and (Get-Row $fg 'hy.fslogix-test').Status -eq 'green' -and (Get-Row $fy 'hy.fslogix-test').Status -eq 'yellow' -and (Get-Row $fy 'hy.fslogix-test').Reason -like '*fs.defender*' -and (Get-Row $fr 'hy.fslogix-test').Status -eq 'red' -and $fr.RedIds -contains 'hy.fslogix-test') $null
    Test-Check 'FSLogix-Test row carries its source and says it is AVDTune''s own criterion (not verified)' ((Get-Row $fg 'hy.fslogix-test').Source -like 'https://learn.microsoft.com/*' -and -not (Get-Row $fg 'hy.fslogix-test').Verified -and (Get-Row $fg 'hy.fslogix-test').Note -like '*own criterion*') $null
    $greenRec = [pscustomobject]@{ At = '2026-11-15T09:00:00.0000000'; Overall = 'green'; Red = 0; Yellow = 0; OpenIds = @() }
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastChange = '2026-11-15T10:00:00.0000000' })
    $fStale = Invoke-AVDTuneReadiness -Machine (New-Master) -Arm $null -Token '' -GalleryImageId $defId -UpdateBlock $goodBlock -FSLogixApplies $true -FSLogixTest $greenRec -Root $tmp
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastChange = '2026-11-15T08:00:00.0000000' })
    $fFresh = Invoke-AVDTuneReadiness -Machine (New-Master) -Arm $null -Token '' -GalleryImageId $defId -UpdateBlock $goodBlock -FSLogixApplies $true -FSLogixTest $greenRec -Root $tmp
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastChange = $null })
    Test-Check 'FSLogix-Test green only when the test is younger than the last change: older test yellow with the fix, younger test green' ((Get-Row $fStale 'hy.fslogix-test').Status -eq 'yellow' -and (Get-Row $fStale 'hy.fslogix-test').Reason -like '*older than the last change*' -and (Get-Row $fFresh 'hy.fslogix-test').Status -eq 'green') ((Get-Row $fStale 'hy.fslogix-test').Reason + ' | ' + (Get-Row $fFresh 'hy.fslogix-test').Reason)
    Test-Check 'update block without a given status is read live from the machine (a fresh master: off, red)' ((Get-Row $r 'hy.update-block').Status -eq 'red') $null
    $r = Invoke-Readiness (New-Master -Reg @{ 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection|senseGuid' = 'abc' }) (New-Arm)
    Test-Check 'Defender onboarding done on the master (senseGuid): red' ((Get-Row $r 'hy.defender-onboarding').Status -eq 'red') $null
    $r = Invoke-Readiness (New-Master @{ Services = @(@{ Name = 'WindowsAzureGuestAgent' }, @{ Name = 'Sense'; Status = 'Running' }) }) (New-Arm)
    Test-Check 'sensor running without a device ID: yellow' ((Get-Row $r 'hy.defender-onboarding').Status -eq 'yellow') $null
    $r = Invoke-Readiness (New-Master) (New-Arm)
    Test-Check 'Azure VM agent: running is green, a stopped one is yellow, none is yellow' ((Get-Row $r 'hy.vm-agent').Status -eq 'green' -and (Get-Row (Invoke-Readiness (New-Master @{ Services = @(@{ Name = 'WindowsAzureGuestAgent'; Status = 'Stopped' }) }) (New-Arm)) 'hy.vm-agent').Status -eq 'yellow' -and (Get-Row (Invoke-Readiness (New-Master @{ Services = @() }) (New-Arm)) 'hy.vm-agent').Status -eq 'yellow') $null
    $r = Invoke-Readiness (New-Master @{ Tasks = @(@{ Path = '\'; Name = 'PilotOverlay'; Enabled = $true }, @{ Path = '\'; Name = 'MicrosoftEdgeUpdateTaskMachineCore'; Enabled = $true }); Paths = @('C:\Drivers'); Dirs = @{ 'C:\ProgramData' = @('start.vbs', 'readme.txt') } }) (New-Arm)
    $left = Get-Row $r 'hy.leftovers'
    Test-Check 'leftovers: task, driver folder and VBS starter found, the Edge task is not one' ($left.Status -eq 'yellow' -and $left.Reason -like '*task PilotOverlay*' -and $left.Reason -like '*folder C:\Drivers*' -and $left.Reason -like '*start.vbs*' -and $left.Reason -notlike '*Edge*' -and $left.Reason -notlike '*readme*') $left.Reason
    $pubOk = (Get-Row (Invoke-Readiness (New-Master) (New-Arm)) 'hy.public-shortcut').Status -eq 'green'
    $pub = Get-Row (Invoke-Readiness (New-Master @{ Dirs = @{ 'C:\Users\Public\Desktop' = @('AVDTune.lnk', 'Microsoft Edge.lnk') } }) (New-Arm)) 'hy.public-shortcut'
    Test-Check 'an AVDTune shortcut on the Public Desktop is yellow and named (other shortcuts are not); none is green' ($pubOk -and $pub.Status -eq 'yellow' -and $pub.Reason -like '*C:\Users\Public\Desktop\AVDTune.lnk*' -and $pub.Reason -notlike '*Edge*' -and $pub.Verified -eq $false) $pub.Reason
    $r = Invoke-Readiness (New-Master) (New-Arm)
    Test-Check 'languages are information only' ((Get-Row $r 'hy.language').Status -eq 'info' -and (Get-Row $r 'hy.language').Reason -like '*de-DE, en-US*') (Get-Row $r 'hy.language').Reason

    # ---------------------------------------------------------------- a check that throws
    $m = New-Master; $m | Add-Member -MemberType NoteProperty -Name NetAdapters -Value { throw 'adapter list failed' } -Force
    $r = Invoke-Readiness $m (New-Arm)
    Test-Check 'a check that throws becomes "not checkable" with the reason, the other checks still run' ((Get-Row $r 'hw.mana').Status -eq 'unknown' -and (Get-Row $r 'hw.mana').Reason -like '*adapter list failed*' -and (Get-Row $r 'hw.stornvme').Status -eq 'green') (Get-Row $r 'hw.mana').Reason

    # ---------------------------------------------------------------- storing a run
    Close-AVDTuneWriteGate
    $red = Invoke-Readiness (New-Master -Reg @{ 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme|Start' = 3 }) (New-Arm @{ DiskControllerType = 'SCSI' })
    $saved = Save-AVDTuneReadinessRun -Root $tmp -Result $red -Kind Healthcheck -User 'admin1' -SnapshotId 'snap1' -At $now
    $runs = @(Get-AVDTuneRun -Root $tmp)
    $state = Get-AVDTuneState $tmp
    $log = @(Get-AVDTuneChangeLog -Root $tmp)
    Test-Check 'a run is stored: run record with rows and families, state.json Readiness, change log entry' ($runs.Count -eq 1 -and $runs[0].Kind -eq 'Healthcheck' -and $runs[0].Overall -eq 'red' -and @($runs[0].Results).Count -eq $red.Rows.Count -and @($runs[0].Families).Count -eq 52 -and $state.Readiness.RunId -eq $saved.RunId -and $state.Readiness.Red -eq 1 -and $log.Count -eq 1 -and $log[0].Category -eq 'Readiness' -and $log[0].Text -like '*overall red*hw.stornvme (red)*') ($log | ForEach-Object Text)
    $quiet = Invoke-Readiness (New-Master) (New-Arm)
    [void](Save-AVDTuneReadinessRun -Root $tmp -Result $quiet -Kind Start -User 'admin1' -At $now.AddMinutes(1))
    Test-Check 'the run at every start is stored but writes no change log entry, and does not replace the healthcheck record' (@(Get-AVDTuneRun -Root $tmp).Count -eq 2 -and @(Get-AVDTuneChangeLog -Root $tmp).Count -eq 1 -and (Get-AVDTuneState $tmp).Readiness.Kind -eq 'Healthcheck' -and (Get-AVDTuneState $tmp).Readiness.Overall -eq 'red') $null
    Test-Check 'an unknown kind is refused' (Test-Throws { Save-AVDTuneReadinessRun -Root $tmp -Result $quiet -Kind Weekly }) $null

    # ---------------------------------------------------------------- finish gate and confirmation by name
    [void](Save-AVDTuneReadinessRun -Root $tmp -Result $quiet -Kind Healthcheck -User 'admin1' -At $now.AddMinutes(1))
    $g = Get-AVDTuneFinishReadiness -Root $tmp
    Test-Check 'finish gate: a green analysis opens it' ($g.Allowed -and $g.Overall -eq 'green' -and $g.Reasons.Count -eq 0) ($g.Reasons -join '|')
    [void](Set-AVDTuneState -Root $tmp -Values @{ Readiness = $null })
    Test-Check 'finish gate: no analysis yet locks it' (-not (Get-AVDTuneFinishReadiness -Root $tmp).Allowed -and (Get-AVDTuneFinishReadiness -Root $tmp).Reasons[0] -like '*No healthcheck yet*') $null
    [void](Save-AVDTuneReadinessRun -Root $tmp -Result $red -Kind Healthcheck -User 'admin1' -At $now.AddMinutes(2))
    $g = Get-AVDTuneFinishReadiness -Root $tmp
    Test-Check 'finish gate: red locks it and names the item' (-not $g.Allowed -and ($g.Reasons -join ' ') -like '*1 red item(s)*hw.stornvme*') ($g.Reasons -join '|')
    $ackText = Get-ThrownText { Confirm-AVDTuneReadinessAcknowledgement -Root $tmp -Typed 'hw.stornvme' -User 'admin1' }
    Test-Check 'red cannot be confirmed' ($ackText -like '*red cannot be confirmed*') $ackText
    $yellow = Invoke-Readiness (New-Master @{ Keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'); Native = @{ 'manage-bde.exe -status C:' = @{ ExitCode = 0; Output = 'Protection Status:    Protection On' } } }) (New-Arm @{ DiskControllerType = 'SCSI' })
    [void](Save-AVDTuneReadinessRun -Root $tmp -Result $yellow -Kind Healthcheck -User 'admin1' -At $now.AddMinutes(3))
    Test-Check 'yellow analysis: overall yellow, three open items' ($yellow.Overall -eq 'yellow' -and (@($yellow.OpenIds) -join ',') -eq 'hw.disk-controller,hy.bitlocker,hy.reboot') (@($yellow.OpenIds) -join ',')
    $g = Get-AVDTuneFinishReadiness -Root $tmp
    Test-Check 'finish gate: unconfirmed yellow locks it' (-not $g.Allowed -and ($g.Reasons -join ' ') -like '*3 yellow*not confirmed by name*') ($g.Reasons -join '|')
    $miss = Get-ThrownText { Confirm-AVDTuneReadinessAcknowledgement -Root $tmp -Typed 'hy.bitlocker, hw.disk-controller' -User 'admin1' }
    Test-Check 'confirmation needs every name; the missing one is named' ($miss -like '*Missing: hy.reboot*') $miss
    Test-Check 'a general "ok" is not a confirmation' (Test-Throws { Confirm-AVDTuneReadinessAcknowledgement -Root $tmp -Typed 'ok' -User 'admin1' }) $null
    [void](Confirm-AVDTuneReadinessAcknowledgement -Root $tmp -Typed 'HY.REBOOT hw.disk-controller;hy.bitlocker' -User 'admin1' -At $now.AddMinutes(4))
    $g = Get-AVDTuneFinishReadiness -Root $tmp
    $rec = Get-AVDTuneReadinessRecord -Root $tmp
    Test-Check 'finish gate: confirmed by name opens it; who and when are recorded; a change log entry names the items' ($g.Allowed -and $rec.AcknowledgedBy -eq 'admin1' -and @($rec.Acknowledged).Count -eq 3 -and (@(Get-AVDTuneChangeLog -Root $tmp | Where-Object Component -eq 'Confirmation')[0].Text -like '*confirmed by admin1*hy.reboot*')) ($g.Reasons -join '|')
    [void](Add-AVDTuneChangeLogEntry -Root $tmp -Version (Get-AVDTuneState $tmp).ImageVersion -Category 'Updates' -ChangeType Updated -Text 'KB5132061 installed' -User 'admin1' -Source Step -At $now.AddMinutes(10))
    $g = Get-AVDTuneFinishReadiness -Root $tmp
    Test-Check 'finish gate: a change after the check locks it again' (-not $g.Allowed -and ($g.Reasons -join ' ') -like '*changed after the check*run the analysis again*') ($g.Reasons -join '|')
    $later = Invoke-Readiness (New-Master @{ Now = $now.AddMinutes(20) }) (New-Arm)
    [void](Save-AVDTuneReadinessRun -Root $tmp -Result $later -Kind Healthcheck -User 'admin1' -At $now.AddMinutes(20))
    Test-Check 'finish gate: a new analysis after the change opens it; a note is no change' ((Get-AVDTuneFinishReadiness -Root $tmp).Allowed) ((Get-AVDTuneFinishReadiness -Root $tmp).Reasons -join '|')
    Test-Check 'nothing to confirm on a green analysis' (Test-Throws { Confirm-AVDTuneReadinessAcknowledgement -Root $tmp -Typed 'x' -User 'admin1' }) $null

    # ---------------------------------------------------------------- finding 1: a red from Azure survives a run without Azure, only a start/manual run never opens the gate
    $badDef = New-Arm @{} @{ def1 = @{ Features = @(@{ name = 'DiskControllerTypes'; value = 'SCSI' }); Architecture = 'x64'; HyperV = 'V2' } }
    $redAz = Invoke-Readiness (New-Master) $badDef
    Test-Check 'precondition: the gallery definition without NVMe is a red from Azure' ((Get-Row $redAz 'hw.gallery').Status -eq 'red') $null
    [void](Save-AVDTuneReadinessRun -Root $tmp -Result $redAz -Kind Healthcheck -User 'admin1' -At $now.AddMinutes(30))
    $noAz = Invoke-Readiness (New-Master) $null ''
    Test-Check 'precondition: without Azure the same row is only not checkable' ((Get-Row $noAz 'hw.gallery').Status -eq 'unknown') $null
    [void](Save-AVDTuneReadinessRun -Root $tmp -Result $noAz -Kind Healthcheck -User 'admin1' -At $now.AddMinutes(31))
    $g = Get-AVDTuneFinishReadiness -Root $tmp; $rec = Get-AVDTuneReadinessRecord -Root $tmp
    Test-Check 'a later run without Azure keeps the red: the row is red again, counted, named in the gate' ((Get-Row $noAz 'hw.gallery').Status -eq 'red' -and (Get-Row $noAz 'hw.gallery').Reason -like '*Still red*' -and $rec.RedIds -contains 'hw.gallery' -and $noAz.Overall -eq 'red' -and -not $g.Allowed -and ($g.Reasons -join ' ') -like '*hw.gallery*') ($g.Reasons -join '|')
    $miss = Get-ThrownText { Confirm-AVDTuneReadinessAcknowledgement -Root $tmp -Typed ((@($rec.OpenIds) + 'hw.gallery') -join ' ') -User 'admin1' }
    Test-Check 'the carried red cannot be confirmed away, naming it does not help' ($miss -like '*red cannot be confirmed*' -and -not (Get-AVDTuneFinishReadiness -Root $tmp).Allowed) $miss
    $noAz2 = Invoke-Readiness (New-Master) $null ''
    [void](Save-AVDTuneReadinessRun -Root $tmp -Result $noAz2 -Kind Healthcheck -User 'admin1' -At $now.AddMinutes(32))
    Test-Check 'the red survives any number of runs without Azure' ((Get-Row $noAz2 'hw.gallery').Status -eq 'red' -and -not (Get-AVDTuneFinishReadiness -Root $tmp).Allowed) $null
    $greenAz = Invoke-Readiness (New-Master @{ Now = $now.AddMinutes(33) }) (New-Arm)
    [void](Save-AVDTuneReadinessRun -Root $tmp -Result $greenAz -Kind Healthcheck -User 'admin1' -At $now.AddMinutes(33))
    Test-Check 'a successful Azure reading that shows it green clears the red' ((Get-Row $greenAz 'hw.gallery').Status -eq 'green' -and (Get-AVDTuneFinishReadiness -Root $tmp).Allowed) ((Get-AVDTuneFinishReadiness -Root $tmp).Reasons -join '|')
    [void](Save-AVDTuneReadinessRun -Root $tmp -Result (Invoke-Readiness (New-Master) (New-Arm)) -Kind Manual -User 'admin1' -At $now.AddMinutes(34))
    $g = Get-AVDTuneFinishReadiness -Root $tmp
    Test-Check 'a manual run is no healthcheck: the gate stays locked and says so' (-not $g.Allowed -and ($g.Reasons -join ' ') -like "*kind 'Manual'*only an Erstanalyse or a healthcheck counts*") ($g.Reasons -join '|')
    $startOnly = Get-ThrownText { Confirm-AVDTuneReadinessAcknowledgement -Root $tmp -Typed 'x' -User 'admin1' }
    Test-Check 'a record of another kind cannot be confirmed' ($startOnly -like '*Only the Erstanalyse or a healthcheck*') $startOnly
    [void](Save-AVDTuneReadinessRun -Root $tmp -Result (Invoke-Readiness (New-Master @{ Now = $now.AddMinutes(35) }) (New-Arm)) -Kind Healthcheck -User 'admin1' -At $now.AddMinutes(35))
    [void](Save-AVDTuneReadinessRun -Root $tmp -Result (Invoke-Readiness (New-Master) $null '') -Kind Start -User 'admin1' -At $now.AddMinutes(36))
    Test-Check 'a start run after a healthcheck does not replace it: the gate stays open' ((Get-AVDTuneReadinessRecord -Root $tmp).Kind -eq 'Healthcheck' -and (Get-AVDTuneFinishReadiness -Root $tmp).Allowed) ((Get-AVDTuneFinishReadiness -Root $tmp).Reasons -join '|')

    # ---------------------------------------------------------------- finding 4: analysis and confirmation are no change of the master
    $lcBefore = Get-AVDTuneLastChange -Root $tmp
    [void](Add-AVDTuneChangeLogEntry -Root $tmp -Version (Get-AVDTuneState $tmp).ImageVersion -Category 'Readiness' -Component 'Confirmation' -ChangeType Note -Text 'x' -User 'admin1' -Source Step -At $now.AddHours(5))
    Test-Check 'a Readiness change log entry does not move LastChange' ((Get-AVDTuneLastChange -Root $tmp) -eq $lcBefore) "$lcBefore / $(Get-AVDTuneLastChange -Root $tmp)"
    [void](Add-AVDTuneChangeLogEntry -Root $tmp -Version (Get-AVDTuneState $tmp).ImageVersion -Category 'Readiness fix' -Component 'Readiness' -ChangeType Changed -Text 'x' -User 'admin1' -Source Step -At $now.AddHours(6))
    Test-Check 'a real fix entry (Readiness fix) does move LastChange' ((Get-AVDTuneLastChange -Root $tmp) -gt $lcBefore) $null

    # ---------------------------------------------------------------- finding 3: resource ID segments
    foreach ($bad in @('/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg1/providers/Microsoft.Compute/galleries/g1/images/def1?x=1', '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg 1/providers/Microsoft.Compute/galleries/g1/images/def1', '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg1/providers/Microsoft.Compute/galleries/g1/images/def1#x', '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg1/providers/Microsoft.Compute/galleries/g%2f1/images/def1')) {
        Test-Check "gallery ID with a character outside [A-Za-z0-9._()-] is refused: $bad" ($null -eq (ConvertTo-AVDTuneGalleryImageId $bad)) $null
    }
    Test-Check 'a normal ID with dots, brackets and dashes is accepted' ($null -ne (ConvertTo-AVDTuneGalleryImageId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-1.a(b)/providers/Microsoft.Compute/galleries/g_1/images/def-1')) $null

    # ---------------------------------------------------------------- the fix behind the write gate
    $ok = @{ 'sc.exe config stornvme start=boot' = @{ ExitCode = 0; Output = '[SC] ChangeServiceConfig SUCCESS'; Registry = @{ 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme|Start' = 0 } } }
    $m = New-Master @{ Native = $ok } -Reg @{ 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme|Start' = 3 }
    $before = @(Get-AVDTuneRun -Root $tmp).Count
    Test-Check 'fix without a confirmed snapshot is refused and changes nothing' ((Get-ThrownText { Invoke-AVDTuneReadinessFix -Machine $m -Root $tmp -FixId 'readiness.stornvme-boot' -User 'admin1' }) -like '*snapshot gate is not confirmed*' -and $m.Store.Registry['hklm:\system\currentcontrolset\services\stornvme|start'] -eq 3) $null
    $wi = Invoke-AVDTuneReadinessFix -Machine $m -Root $tmp -FixId 'readiness.stornvme-boot' -WhatIf
    Test-Check 'dry run says it would change and changes nothing' ($wi.Status -eq 'WhatIf' -and $m.Store.Registry['hklm:\system\currentcontrolset\services\stornvme|start'] -eq 3 -and -not (@($m.Log | Where-Object { $_ -like 'Run sc.exe*' }))) $null
    Open-AVDTuneWriteGate -SnapshotId 'snap1' -ConfirmedBy 'admin1'
    $fix = Invoke-AVDTuneReadinessFix -Machine $m -Root $tmp -FixId 'readiness.stornvme-boot' -User 'admin1' -SnapshotId 'snap1'
    $entry = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Readiness fix' -and $_.Text -ne 'x' })
    Test-Check 'fix with the open gate: changed with the documented command, restart needed, run record and change log entry' ($fix.Status -eq 'Changed' -and $fix.Reboot -and $m.Store.Registry['hklm:\system\currentcontrolset\services\stornvme|start'] -eq 0 -and (@($m.Log | Where-Object { $_ -eq 'Run sc.exe config stornvme start=boot' }).Count -eq 1) -and @(Get-AVDTuneRun -Root $tmp).Count -eq ($before + 1) -and $entry.Count -eq 1 -and $entry[0].Text -like '*changed (before: 3, after: 0)*restart needed*') ($entry | ForEach-Object Text)
    $again = Invoke-AVDTuneReadinessFix -Machine $m -Root $tmp -FixId 'readiness.stornvme-boot' -User 'admin1' -SnapshotId 'snap1'
    Test-Check 'the fix is idempotent (already at boot: unchanged)' ($again.Status -eq 'Unchanged') $again.Status
    Test-Check 'after a fix the finish gate asks for a new analysis' (-not (Get-AVDTuneFinishReadiness -Root $tmp).Allowed -and ((Get-AVDTuneFinishReadiness -Root $tmp).Reasons -join ' ') -like '*changed after the check*') ((Get-AVDTuneFinishReadiness -Root $tmp).Reasons -join '|')
    $failM = New-Master @{ Native = @{ 'sc.exe config stornvme start=boot' = @{ ExitCode = 5; Output = 'Access is denied.' } } } -Reg @{ 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme|Start' = 3 }
    $ff = Invoke-AVDTuneReadinessFix -Machine $failM -Root $tmp -FixId 'readiness.stornvme-boot' -User 'admin1' -SnapshotId 'snap1'
    Test-Check 'finding 5: a failed fix also sets state.json LastChange' ((Get-AVDTuneState $tmp).PSObject.Properties['LastChange'] -and $ff.Status -eq 'Failed') $null
    Test-Check 'a failing command is reported as Failed with its exit code and logged' ($ff.Status -eq 'Failed' -and $ff.Message -like '*exit code 5*' -and (@(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Readiness fix' -and $_.Text -like '*FAILED*' }).Count -eq 1)) $ff.Message
    $noDriver = New-Master @{ Native = $ok }; $noDriver.Store.Registry.Remove('hklm:\system\currentcontrolset\services\stornvme|start'); [void]$noDriver.Store.Keys.Remove('hklm:\system\currentcontrolset\services\stornvme')
    $nd = Invoke-AVDTuneReadinessFix -Machine $noDriver -Root $tmp -FixId 'readiness.stornvme-boot' -User 'admin1' -SnapshotId 'snap1'
    Test-Check 'no stornvme driver: the fix fails and sc.exe is never called' ($nd.Status -eq 'Failed' -and -not (@($noDriver.Log | Where-Object { $_ -like 'Run sc.exe*' }))) $nd.Message
    Test-Check 'an unknown fix id is refused' ((Get-ThrownText { Invoke-AVDTuneReadinessFix -Machine $m -Root $tmp -FixId 'readiness.format-c' }) -like '*Unknown fix*') $null
    $ub = Invoke-AVDTuneReadinessFix -Machine (New-Master) -Root $tmp -FixId 'readiness.updateblock-on' -WhatIf
    Test-Check 'the update block fix is the one of #6 (dry run: nothing changed)' ($ub.Status -eq 'WhatIf') $ub.Status
    # default user profile left loaded by a crash (#40): red with a one-click fix that unloads it
    $hm = New-Master @{ HiveLoaded = $true }
    $hr = Invoke-AVDTuneReadiness -Machine $hm -Arm (New-Arm) -Token 'tok' -UpdateBlock $goodBlock
    $hrow = Get-Row $hr 'hy.default-hive'
    Test-Check 'default profile still loaded: red, says so, offers the unload fix' ($hrow.Status -eq 'red' -and $hrow.Reason -like '*still loaded*' -and $hrow.FixId -eq 'readiness.default-hive-unload') ($hrow | ConvertTo-Json -Compress)
    Test-Check 'default profile not loaded: green' ((Get-Row (Invoke-AVDTuneReadiness -Machine (New-Master) -Arm (New-Arm) -Token 'tok' -UpdateBlock $goodBlock) 'hy.default-hive').Status -eq 'green') $null
    $hf = Invoke-AVDTuneReadinessFix -Machine $hm -Root $tmp -FixId 'readiness.default-hive-unload' -User 'admin1' -SnapshotId 'snap1'
    Test-Check 'the unload fix unloads the hive (one reg unload) and is idempotent' ($hf.Status -eq 'Changed' -and -not $hm.Store.Hive.Loaded -and @($hm.Store.Hive.Log).Count -eq 1 -and (Invoke-AVDTuneReadinessFix -Machine $hm -Root $tmp -FixId 'readiness.default-hive-unload' -User 'admin1' -SnapshotId 'snap1').Status -eq 'Unchanged') "$($hf.Status) $($hf.Message)"
    $hs = New-Master @{ HiveLoaded = $true }; $hs.Store.Hive.StuckUnloads = 99
    $hsf = Invoke-AVDTuneReadinessFix -Machine $hs -Root $tmp -FixId 'readiness.default-hive-unload' -User 'admin1' -SnapshotId 'snap1'
    Test-Check 'an unload that keeps failing: the fix fails with the hint to restart, after a limited number of tries' ($hsf.Status -eq 'Failed' -and $hsf.Message -like '*restart*' -and @($hs.Store.Hive.Log).Count -eq 5) "$($hsf.Message) tries=$(@($hs.Store.Hive.Log).Count)"
    Close-AVDTuneWriteGate
    Test-Check 'the unload fix needs the open write gate' ((Get-ThrownText { Invoke-AVDTuneReadinessFix -Machine (New-Master @{ HiveLoaded = $true }) -Root $tmp -FixId 'readiness.default-hive-unload' -User 'admin1' }) -like '*snapshot gate is not confirmed*') $null
    $startSrc = Get-Content -Raw (Join-Path $repo 'Start-AVDTune.ps1')
    Test-Check 'start: a default profile left loaded is unloaded at the start and noted in the protocol' ($startSrc -match 'Invoke-AVDTuneDefaultHiveUnload -Machine \$script:Machine' -and $startSrc -match 'Default user profile was still loaded') $null
    Test-Check 'no file of the check run touched the real state folder' (-not ($tmp -eq (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'AVDTune'))) $tmp
}
finally {
    Close-AVDTuneWriteGate
    $env:AVDTUNE_ROOT = $null
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-Readiness: all checks passed.'
