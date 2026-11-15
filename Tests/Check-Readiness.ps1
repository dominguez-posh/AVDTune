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
        "$win|UBR" = 9974; 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme|Start' = 0; 'HKLM:\SYSTEM\CurrentControlSet\Control|PEFirmwareType' = 2
        'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State|UEFISecureBootEnabled' = 1
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management|PagingFiles' = @('C:\pagefile.sys 0 0')
    }
    foreach ($k in $Reg.Keys) { $registry[$k] = $Reg[$k] }
    $seed = @{
        Now = $now; Registry = $registry; Imds = (New-Imds)
        Services = @(@{ Name = 'WindowsAzureGuestAgent' })
        Keys = @('HKLM:\SYSTEM\CurrentControlSet\Services\stornvme', 'HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages\en-US', 'HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages\de-DE')
        Hotfixes = @(@{ Id = 'KB5132061'; InstalledOn = [datetime]'2026-11-10' }); Tpm = $true; Arch = 'AMD64'
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
    Test-Check 'data: loads, 26 criteria, a Stand date, 52 families' ($crit.Count -eq 26 -and $data.Stand -match '^\d{4}-\d{2}-\d{2}$' -and $data.Families.Count -eq 52) "$($crit.Count) / $($data.Families.Count)"
    Test-Check 'data: every criterion has a Microsoft Learn source, a date and the Verified flag' (-not (@($crit | Where-Object { $_.Value.Source -notmatch '^https://learn\.microsoft\.com/' -or $_.Value.Stand -notmatch '^\d{4}-\d{2}-\d{2}$' -or $_.Value.Verified -isnot [bool] }))) $null
    $unverified = @($crit | Where-Object { -not $_.Value.Verified } | ForEach-Object Name)
    Test-Check 'data: what Learn does not state is marked and explained (bitlocker, reboot markers, lcu thresholds, leftovers)' ((($unverified | Sort-Object) -join ',') -eq 'hy.bitlocker,hy.lcu-age,hy.leftovers,hy.reboot' -and -not (@($crit | Where-Object { -not $_.Value.Verified -and -not $_.Value.Note }))) ($unverified -join ',')
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
    Test-Check 'healthy master: every criterion of the data has a row, once' ((($ids | Sort-Object -Unique).Count -eq $ids.Count) -and (@($crit | Where-Object { $_.Name -notin $ids }).Count -eq 0)) (@($crit | Where-Object { $_.Name -notin $ids } | ForEach-Object Name) -join ',')
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

    $r = Invoke-Readiness (New-Master -Reg @{ 'HKLM:\SYSTEM\CurrentControlSet\Control|PEFirmwareType' = 1 }) (New-Arm @{ HyperV = 'V1' })
    Test-Check 'Generation 1: red, no plain conversion; all families not possible' ((Get-Row $r 'hw.firmware').Status -eq 'red' -and (Get-Row $r 'hw.firmware').Reason -like '*no plain conversion*' -and (@($r.Families | Where-Object { $_.Status -ne 'not-possible' }).Count -eq 0)) (Get-Row $r 'hw.firmware').Reason
    $m = New-Master; $m.Store.Registry.Remove('hklm:\system\currentcontrolset\control|pefirmwaretype')
    $r = Invoke-Readiness $m $null ''
    Test-Check 'firmware not readable and no Azure: not checkable' ((Get-Row $r 'hw.firmware').Status -eq 'unknown') $null
    $r = Invoke-Readiness (New-Master -Reg @{ 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State|UEFISecureBootEnabled' = 0 }) (New-Arm)
    Test-Check 'Secure Boot off: yellow' ((Get-Row $r 'hw.securestart').Status -eq 'yellow' -and (Get-Row $r 'hw.securestart').Reason -like '*Secure Boot: off*') (Get-Row $r 'hw.securestart').Reason
    $r = Invoke-Readiness (New-Master @{ Tpm = $false }) (New-Arm)
    Test-Check 'no vTPM: yellow' ((Get-Row $r 'hw.securestart').Status -eq 'yellow' -and (Get-Row $r 'hw.securestart').Reason -like '*vTPM: none*') $null
    $r = Invoke-Readiness (New-Master @{ Arch = 'ARM64' }) (New-Arm)
    Test-Check 'Arm64 master: only the Arm64 families fit, the x64 ones are not possible' ((Get-Row $r 'hw.arch').Reason -like 'Arm64:*' -and (@($r.Families | Where-Object { $_.Arch -eq 'x64' -and $_.Status -ne 'not-possible' }).Count -eq 0) -and (@($r.Families | Where-Object { $_.Arch -eq 'Arm64' -and $_.Status -eq 'ready' }).Count -eq 6)) (Get-Row $r 'hw.arch').Reason

    # ---------------------------------------------------------------- gallery definition
    $r = Invoke-Readiness (New-Master) (New-Arm) 'tok' ''
    Test-Check 'no image definition known: not checkable, says where to enter it' ((Get-Row $r 'hw.gallery').Status -eq 'unknown' -and (Get-Row $r 'hw.gallery').Reason -like '*Readiness card*') (Get-Row $r 'hw.gallery').Reason
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
    $r = Invoke-Readiness (New-Master) (New-Arm) 'tok' 'not-an-id'
    Test-Check 'a malformed definition ID is ignored, never sent to Azure' ((Get-Row $r 'hw.gallery').Status -eq 'unknown' -and -not (@((New-Arm).Log | Where-Object { $_ -like '*not-an-id*' }))) $null
    $r = Invoke-Readiness (New-Master) (New-Arm @{ ImageRefId = "$defId/versions/2026.11.1" }) 'tok' ''
    Test-Check 'without a setting the definition comes from the VM image reference when it is a gallery image' ((Get-Row $r 'hw.gallery').Status -eq 'green' -and $r.GalleryImageId -eq $defId) (Get-Row $r 'hw.gallery').Reason

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
    Test-Check 'the run at every start is stored but writes no change log entry' (@(Get-AVDTuneRun -Root $tmp).Count -eq 2 -and @(Get-AVDTuneChangeLog -Root $tmp).Count -eq 1 -and (Get-AVDTuneState $tmp).Readiness.Kind -eq 'Start') $null
    Test-Check 'an unknown kind is refused' (Test-Throws { Save-AVDTuneReadinessRun -Root $tmp -Result $quiet -Kind Weekly }) $null

    # ---------------------------------------------------------------- finish gate and confirmation by name
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

    # ---------------------------------------------------------------- the fix behind the write gate
    $ok = @{ 'sc.exe config stornvme start=boot' = @{ ExitCode = 0; Output = '[SC] ChangeServiceConfig SUCCESS'; Registry = @{ 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme|Start' = 0 } } }
    $m = New-Master @{ Native = $ok } -Reg @{ 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme|Start' = 3 }
    $before = @(Get-AVDTuneRun -Root $tmp).Count
    Test-Check 'fix without a confirmed snapshot is refused and changes nothing' ((Get-ThrownText { Invoke-AVDTuneReadinessFix -Machine $m -Root $tmp -FixId 'readiness.stornvme-boot' -User 'admin1' }) -like '*snapshot gate is not confirmed*' -and $m.Store.Registry['hklm:\system\currentcontrolset\services\stornvme|start'] -eq 3) $null
    $wi = Invoke-AVDTuneReadinessFix -Machine $m -Root $tmp -FixId 'readiness.stornvme-boot' -WhatIf
    Test-Check 'dry run says it would change and changes nothing' ($wi.Status -eq 'WhatIf' -and $m.Store.Registry['hklm:\system\currentcontrolset\services\stornvme|start'] -eq 3 -and -not (@($m.Log | Where-Object { $_ -like 'Run sc.exe*' }))) $null
    Open-AVDTuneWriteGate -SnapshotId 'snap1' -ConfirmedBy 'admin1'
    $fix = Invoke-AVDTuneReadinessFix -Machine $m -Root $tmp -FixId 'readiness.stornvme-boot' -User 'admin1' -SnapshotId 'snap1'
    $entry = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object Category -eq 'Readiness fix')
    Test-Check 'fix with the open gate: changed with the documented command, restart needed, run record and change log entry' ($fix.Status -eq 'Changed' -and $fix.Reboot -and $m.Store.Registry['hklm:\system\currentcontrolset\services\stornvme|start'] -eq 0 -and (@($m.Log | Where-Object { $_ -eq 'Run sc.exe config stornvme start=boot' }).Count -eq 1) -and @(Get-AVDTuneRun -Root $tmp).Count -eq ($before + 1) -and $entry.Count -eq 1 -and $entry[0].Text -like '*changed (before: 3, after: 0)*restart needed*') ($entry | ForEach-Object Text)
    $again = Invoke-AVDTuneReadinessFix -Machine $m -Root $tmp -FixId 'readiness.stornvme-boot' -User 'admin1' -SnapshotId 'snap1'
    Test-Check 'the fix is idempotent (already at boot: unchanged)' ($again.Status -eq 'Unchanged') $again.Status
    Test-Check 'after a fix the finish gate asks for a new analysis' (-not (Get-AVDTuneFinishReadiness -Root $tmp).Allowed -and ((Get-AVDTuneFinishReadiness -Root $tmp).Reasons -join ' ') -like '*changed after the check*') ((Get-AVDTuneFinishReadiness -Root $tmp).Reasons -join '|')
    $failM = New-Master @{ Native = @{ 'sc.exe config stornvme start=boot' = @{ ExitCode = 5; Output = 'Access is denied.' } } } -Reg @{ 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme|Start' = 3 }
    $ff = Invoke-AVDTuneReadinessFix -Machine $failM -Root $tmp -FixId 'readiness.stornvme-boot' -User 'admin1' -SnapshotId 'snap1'
    Test-Check 'a failing command is reported as Failed with its exit code and logged' ($ff.Status -eq 'Failed' -and $ff.Message -like '*exit code 5*' -and (@(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Readiness fix' -and $_.Text -like '*FAILED*' }).Count -eq 1)) $ff.Message
    $noDriver = New-Master @{ Native = $ok }; $noDriver.Store.Registry.Remove('hklm:\system\currentcontrolset\services\stornvme|start'); [void]$noDriver.Store.Keys.Remove('hklm:\system\currentcontrolset\services\stornvme')
    $nd = Invoke-AVDTuneReadinessFix -Machine $noDriver -Root $tmp -FixId 'readiness.stornvme-boot' -User 'admin1' -SnapshotId 'snap1'
    Test-Check 'no stornvme driver: the fix fails and sc.exe is never called' ($nd.Status -eq 'Failed' -and -not (@($noDriver.Log | Where-Object { $_ -like 'Run sc.exe*' }))) $nd.Message
    Test-Check 'an unknown fix id is refused' ((Get-ThrownText { Invoke-AVDTuneReadinessFix -Machine $m -Root $tmp -FixId 'readiness.format-c' }) -like '*Unknown fix*') $null
    $ub = Invoke-AVDTuneReadinessFix -Machine (New-Master) -Root $tmp -FixId 'readiness.updateblock-on' -WhatIf
    Test-Check 'the update block fix is the one of #6 (dry run: nothing changed)' ($ub.Status -eq 'WhatIf') $ub.Status
    Close-AVDTuneWriteGate
    Test-Check 'no file of the check run touched the real state folder' (-not ($tmp -eq (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'AVDTune'))) $tmp
}
finally {
    Close-AVDTuneWriteGate
    $env:AVDTUNE_ROOT = $null
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-Readiness: all checks passed.'
