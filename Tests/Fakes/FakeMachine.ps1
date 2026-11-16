# A fake machine for the checks and the GUI smoke test: the same adapter as New-AVDTuneMachine (Modules\AVDTune.psm1), kept in memory.
# Nothing here touches the registry, services, tasks or processes of the computer it runs on. Writes are logged in .Log.
# Dot-source this file, then: $m = New-AVDTuneFakeMachine [-Seed @{ ... }]
# Seed keys (all optional): Registry (hashtable 'path|name' -> value), Keys (array of registry keys that exist), Services (array of
# @{ Name; Status; StartType }), Tasks (array of @{ Path; Name; Enabled }), Imds (object or $null), Native (hashtable 'file args' -> @{ ExitCode; Output }),
# ComputerName, Now (datetime, fixed clock), and for the readiness analysis: Paths (array of existing paths), Dirs (hashtable folder -> names), Hotfixes (array of @{ Id; InstalledOn }),
# NetAdapters (array of @{ Name; Description; Status }), Pnp (array of PnP instance IDs that are present), Arch ('AMD64' or 'ARM64'), Tpm ($true/$false/$null), Firmware ('UEFI'/'BIOS'/$null, GetFirmwareType). A Native entry can carry Registry (hashtable) that is applied when the command runs. $m.Store.FailWrites = @('part of a key|name') makes RegSet throw for matching values (error path checks).

function New-AVDTuneFakeMachine {
    param([hashtable]$Seed = @{})
    $store = @{
        Registry = @{}; Keys = @{}; Services = @{}; Tasks = @{}; Native = @{}; Log = (New-Object System.Collections.ArrayList)
        ComputerName = $(if ($Seed.ComputerName) { $Seed.ComputerName } else { 'GM-TEST01' }); Now = $Seed.Now; Imds = $null; FailWrites = @(); Kinds = @{}
        Paths = @(@($Seed.Paths) | Where-Object { $_ }); Dirs = $(if ($Seed.Dirs) { $Seed.Dirs } else { @{} }); Hotfixes = @(@($Seed.Hotfixes) | Where-Object { $_ }); NetAdapters = @(@($Seed.NetAdapters) | Where-Object { $_ })
        Files = @{}; Folders = @{}; Acl = $(if ($Seed.Acl) { $Seed.Acl } else { @{} }); Pnp = @(@($Seed.Pnp) | Where-Object { $_ }); Arch = $(if ($Seed.Arch) { $Seed.Arch } else { 'AMD64' }); Tpm = $(if ($Seed.ContainsKey('Tpm')) { $Seed.Tpm } else { $null })
        Firmware = $(if ($Seed.ContainsKey('Firmware')) { $Seed.Firmware } else { $null })
    }
    $win = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $office = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $defaults = [ordered]@{
        "$win|CurrentBuildNumber" = '26100'; "$win|UBR" = 4652; "$win|EditionID" = 'ServerRdsh'; "$win|DisplayVersion" = '25H2'; "$win|ProductName" = 'Windows 10 Enterprise multi-session'
        "$office|VersionToReport" = '16.0.19231.20138'; "$office|CDNBaseUrl" = 'http://officecdn.microsoft.com/pr/55336b82-a18d-4dd6-b5f6-9e5095c314a6'
        "$office|Platform" = 'x64'; "$office|SharedComputerLicensing" = '1'; "$office|UpdatesEnabled" = 'FALSE'
    }
    foreach ($k in $defaults.Keys) { $store.Registry[$k.ToLowerInvariant()] = $defaults[$k] }
    if ($Seed.Registry) { foreach ($k in $Seed.Registry.Keys) { $store.Registry[([string]$k).ToLowerInvariant()] = $Seed.Registry[$k] } }
    foreach ($k in @($Seed.Keys)) { if ($k) { $store.Keys[([string]$k).ToLowerInvariant()] = $true } }
    foreach ($s in @($Seed.Services)) { if ($s) { $store.Services[([string]$s.Name).ToLowerInvariant()] = [pscustomobject]@{ Name = $s.Name; Status = $(if ($s.Status) { $s.Status } else { 'Running' }); StartType = $(if ($s.StartType) { $s.StartType } else { 'Automatic' }) } } }
    foreach ($t in @($Seed.Tasks)) { if ($t) { $store.Tasks[(([string]$t.Path) + ([string]$t.Name)).ToLowerInvariant()] = [pscustomobject]@{ Path = $t.Path; Name = $t.Name; Enabled = [bool]$t.Enabled; Xml = $(if ($t -is [System.Collections.IDictionary] -and $t.Contains('Xml')) { $t['Xml'] } else { $null }) } } }
    if ($Seed.Files) { foreach ($k in @($Seed.Files.Keys)) { $store.Files[([string]$k).ToLowerInvariant()] = [pscustomobject]@{ Text = [string]$Seed.Files[$k]; Access = 'Admin' }; $store.Folders[([IO.Path]::GetDirectoryName([string]$k)).ToLowerInvariant()] = $true } }
    $store.Imds = if ($Seed.ContainsKey('Imds')) { $Seed.Imds } else {
        [pscustomobject]@{ compute = [pscustomobject]@{
                name = 'gm-test01'; resourceGroupName = 'rg-example'; subscriptionId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; vmId = '00000000-1111-2222-3333-444444444444'; location = 'westeurope'; vmSize = 'Standard_D4s_v5'
                storageProfile = [pscustomobject]@{
                    imageReference = [pscustomobject]@{ publisher = 'microsoftwindowsdesktop'; offer = 'office-365'; sku = 'win11-25h2-avd-m365'; version = 'latest' }
                    osDisk = [pscustomobject]@{ name = 'gm-test01_osdisk'; managedDisk = [pscustomobject]@{ id = '/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/rg-example/providers/Microsoft.Compute/disks/gm-test01_osdisk' } }
                } } }
    }
    $store.Native['dsregcmd.exe /status'] = if ($Seed.Native -and $Seed.Native['dsregcmd.exe /status']) { $Seed.Native['dsregcmd.exe /status'] } else {
        @{ ExitCode = 0; Output = "| Device State |`r`n    AzureAdJoined : NO`r`n  EnterpriseJoined : NO`r`n    DomainJoined : NO`r`n" }
    }
    if ($Seed.Native) { foreach ($k in $Seed.Native.Keys) { $store.Native[$k] = $Seed.Native[$k] } }

    $m = [ordered]@{ Kind = 'Fake'; Store = $store; Log = $store.Log }
    $m.ComputerName = { $store.ComputerName }.GetNewClosure()
    $m.Now = { if ($store.Now) { [datetime]$store.Now } else { Get-Date } }.GetNewClosure()
    $m.RegKeyExists = {
        param($Path)
        $p = ([string]$Path).ToLowerInvariant()
        if ($store.Keys.ContainsKey($p)) { return $true }
        foreach ($k in $store.Registry.Keys) { if ($k.StartsWith($p + '|')) { return $true } }
        $false
    }.GetNewClosure()
    $m.RegGet = { param($Path, $Name) $k = (([string]$Path) + '|' + ([string]$Name)).ToLowerInvariant(); if ($store.Registry.ContainsKey($k)) { $store.Registry[$k] } else { $null } }.GetNewClosure()
    $m.RegGetRaw = {
        param($Path, $Name)
        $k = (([string]$Path) + '|' + ([string]$Name)).ToLowerInvariant()
        if (-not $store.Registry.ContainsKey($k)) { return $null }
        $v = $store.Registry[$k]
        $kind = if ($store.Kinds -and $store.Kinds.ContainsKey($k)) { $store.Kinds[$k] } elseif ($v -is [int] -or $v -is [uint32]) { 'DWord' } elseif ($v -is [long]) { 'QWord' } else { 'String' }
        @{ Value = $v; Kind = $kind }
    }.GetNewClosure()
    $m.RegSet = {
        param($Path, $Name, $Value, $Type)
        $k = (([string]$Path) + '|' + ([string]$Name)).ToLowerInvariant()
        foreach ($bad in @($store.FailWrites)) { if ($bad -and $k -like "*$($bad.ToLowerInvariant())*") { throw "fake: write refused for $Path|$Name" } }
        $store.Registry[$k] = $Value; if ($Type) { $store.Kinds[$k] = [string]$Type }; [void]$store.Log.Add("RegSet $Path|$Name=$Value ($Type)")
    }.GetNewClosure()
    $m.RegRemove = {
        param($Path, $Name)
        $k = (([string]$Path) + '|' + ([string]$Name)).ToLowerInvariant()
        $store.Registry.Remove($k); [void]$store.Log.Add("RegRemove $Path|$Name")
    }.GetNewClosure()
    $m.ServiceGet = { param($Name) $k = ([string]$Name).ToLowerInvariant(); if ($store.Services.ContainsKey($k)) { $store.Services[$k] } else { $null } }.GetNewClosure()
    $m.ServiceSetStartup = {
        param($Name, $Startup)
        $store.Services[([string]$Name).ToLowerInvariant()].StartType = $Startup; [void]$store.Log.Add("ServiceSetStartup $Name=$Startup")
    }.GetNewClosure()
    $m.ServiceStop = { param($Name) $store.Services[([string]$Name).ToLowerInvariant()].Status = 'Stopped'; [void]$store.Log.Add("ServiceStop $Name") }.GetNewClosure()
    $m.ServiceStart = { param($Name) $store.Services[([string]$Name).ToLowerInvariant()].Status = 'Running'; [void]$store.Log.Add("ServiceStart $Name") }.GetNewClosure()
    $m.TaskGet = { param($Path, $Name) $k = (([string]$Path) + ([string]$Name)).ToLowerInvariant(); if ($store.Tasks.ContainsKey($k)) { $store.Tasks[$k] } else { $null } }.GetNewClosure()
    $m.TaskList = { param($Path) @($store.Tasks.Values | Where-Object { $_.Path -eq $Path } | ForEach-Object { $_.Name }) }.GetNewClosure()
    $m.TaskSetEnabled = {
        param($Path, $Name, $Enabled)
        $store.Tasks[(([string]$Path) + ([string]$Name)).ToLowerInvariant()].Enabled = [bool]$Enabled; [void]$store.Log.Add("TaskSetEnabled $Path$Name=$Enabled")
    }.GetNewClosure()
    $m.Run = {
        param($File, [string[]]$Arguments, [int]$TimeoutSeconds = 120)
        # a program in the system folder is keyed by its file name (the product starts it with the full path)
        $shown = $File; if ($File -and [IO.Path]::IsPathRooted($File) -and [string]::Equals((Split-Path $File -Parent), [Environment]::GetFolderPath('System'), 'OrdinalIgnoreCase')) { $shown = Split-Path $File -Leaf }
        $key = (@($shown) + @($Arguments)) -join ' '
        $fullKey = (@($File) + @($Arguments)) -join ' '
        if ($shown -ne $File -and $store.Native.ContainsKey($fullKey)) { $key = $fullKey }   # a check may key the full path
        [void]$store.Log.Add("Run $key")
        $hitKey = $null
        if ($store.Native.ContainsKey($key)) { $hitKey = $key } else { foreach ($nk in $store.Native.Keys) { if ($nk.Contains('*') -and $key -like $nk) { $hitKey = $nk; break } } }
        if ($hitKey) {
            $answer = $store.Native[$hitKey]
            $result = [pscustomobject]$answer
            if ($answer -is [System.Collections.IDictionary] -and $answer.Contains('Registry') -and $answer['ExitCode'] -in 0, 3010) { foreach ($k in $answer['Registry'].Keys) { $store.Registry[([string]$k).ToLowerInvariant()] = $answer['Registry'][$k] } }
            $result
        } else { [pscustomobject]@{ ExitCode = 1; Output = "fake: no answer for $key" } }
    }.GetNewClosure()
    $m.Imds = { $store.Imds }.GetNewClosure()
    $m.RegSubKeys = {
        param($Path)
        $prefix = (([string]$Path).ToLowerInvariant().TrimEnd('\') + '\')
        $names = @{}
        foreach ($k in @($store.Keys.Keys) + @($store.Registry.Keys | ForEach-Object { $_.Split('|')[0] })) { if ($k.StartsWith($prefix)) { $names[$k.Substring($prefix.Length).Split('\')[0]] = $true } }
        @($names.Keys)
    }.GetNewClosure()
    $m.RegNames = { param($Path) $prefix = ([string]$Path).ToLowerInvariant() + '|'; $orig = @{}; foreach ($k in $store.Registry.Keys) { if ($k.StartsWith($prefix)) { $orig[$k.Substring($prefix.Length)] = $true } }; @($orig.Keys) }.GetNewClosure()
    $m.PathExists = { param($Path) $k = ([string]$Path).ToLowerInvariant(); (@($store.Paths) | Where-Object { $_ -eq $Path }).Count -gt 0 -or $store.Files.ContainsKey($k) -or $store.Folders.ContainsKey($k.TrimEnd([char]92)) }.GetNewClosure()
    $m.DirList = { param($Path, $Filter = '*') @(@($store.Dirs[$Path]) | Where-Object { $_ -and $_ -like $Filter }) }.GetNewClosure()
    $m.Hotfixes = { $store.Hotfixes }.GetNewClosure()
    $m.NetAdapters = { $store.NetAdapters }.GetNewClosure()
    $m.PnpPresent = { param($Pattern) (@($store.Pnp | Where-Object { $_ -match $Pattern })).Count -gt 0 }.GetNewClosure()
    $m.OsArchitecture = { $store.Arch }.GetNewClosure()
    $m.TpmPresent = { $store.Tpm }.GetNewClosure()
    $m.FirmwareType = { $store.Firmware }.GetNewClosure()
    $m.KnownFolder = {
        param($Name)
        switch ($Name) { 'ProgramFiles' { 'X:\Fake\Program Files' } 'CommonAppData' { 'X:\Fake\ProgramData' } 'System' { 'X:\Fake\Windows\System32' } default { throw "Unknown folder '$Name'." } }
    }.GetNewClosure()
    $m.FileText = { param($Path) $k = ([string]$Path).ToLowerInvariant(); if ($store.Files.ContainsKey($k)) { $store.Files[$k].Text } else { $null } }.GetNewClosure()
    $m.FileWrite = {
        param($Path, $Text, $Access = 'Admin')
        $folder = [IO.Path]::GetDirectoryName([string]$Path).ToLowerInvariant()
        $k = ([string]$Path).ToLowerInvariant()
        foreach ($bad in @($store.FailWrites)) { if ($bad -and $k -like "*$($bad.ToLowerInvariant())*") { throw "fake: write refused for $Path" } }
        $check = switch ($Access) { 'Admin' { @([IO.Path]::GetDirectoryName($folder), $folder, $k) } 'UsersRead' { @($folder, $k) } default { @() } }
        foreach ($c in $check) { if ($c -and $store.Acl.ContainsKey($c) -and @($store.Acl[$c].Problems).Count -gt 0) { throw "$c is not safe ($(@($store.Acl[$c].Problems) -join '; ')). Nothing was written." } }
        if ($Access -eq 'AdminNew' -and $store.Files.ContainsKey($k)) { throw "$Path exists already. It is not overwritten." }
        $p = $folder; while ($p) { $store.Folders[$p] = $true; $p = [IO.Path]::GetDirectoryName($p) }
        $store.Files[$k] = [pscustomobject]@{ Text = [string]$Text; Access = $Access }
        [void]$store.Log.Add("FileWrite $Path ($Access)")
    }.GetNewClosure()
    $m.FileRemove = { param($Path) $k = ([string]$Path).ToLowerInvariant(); if ($store.Files.ContainsKey($k)) { $store.Files.Remove($k); [void]$store.Log.Add("FileRemove $Path") } }.GetNewClosure()
    $m.DirRemoveEmpty = {
        param($Path)
        $p = ([string]$Path).ToLowerInvariant().TrimEnd('\')
        $has = @($store.Files.Keys | Where-Object { $_.StartsWith($p + '\') }).Count -gt 0
        if ($store.Folders.ContainsKey($p) -and -not $has) { $store.Folders.Remove($p); [void]$store.Log.Add("DirRemoveEmpty $Path") }
    }.GetNewClosure()
    $m.AclReport = {
        param($Path)
        $k = ([string]$Path).ToLowerInvariant().TrimEnd('\')
        $exists = $store.Files.ContainsKey($k) -or $store.Folders.ContainsKey($k) -or $store.Acl.ContainsKey($k)
        if (-not $exists) { return [pscustomobject]@{ Exists = $false; Link = $false; Owner = ''; Protected = $false; Rules = @(); Problems = @() } }
        $seed = $store.Acl[$k]
        [pscustomobject]@{ Exists = $true; Link = $false; Owner = 'S-1-5-32-544'; Protected = $true; Rules = $(if ($seed -and @($seed.Problems).Count -gt 0) { @([pscustomobject]@{ Sid = 'S-1-5-32-545'; Write = $true; Inherited = $false }) } else { @() }); Problems = $(if ($seed) { @($seed.Problems) } else { @() }) }
    }.GetNewClosure()
    $m.TaskDetail = {
        param($Path, $Name)
        $k = (([string]$Path) + ([string]$Name)).ToLowerInvariant()
        if (-not $store.Tasks.ContainsKey($k)) { return $null }
        $t = $store.Tasks[$k]
        $info = if ($t.Xml) { Get-AVDTuneTaskInfoFromXml $t.Xml } else { [pscustomobject]@{ Execute = ''; Arguments = ''; GroupSid = ''; UserSid = ''; Logon = $false; Enabled = $t.Enabled } }
        [pscustomobject]@{ Path = $t.Path; Name = $t.Name; Enabled = [bool]$t.Enabled; Execute = $info.Execute; Arguments = $info.Arguments; GroupSid = $info.GroupSid; UserSid = $info.UserSid; Logon = $info.Logon; Xml = $t.Xml }
    }.GetNewClosure()
    $m.TaskRegisterXml = {
        param($Path, $Name, $Xml)
        $k = (([string]$Path) + ([string]$Name)).ToLowerInvariant()
        foreach ($bad in @($store.FailWrites)) { if ($bad -and $k -like "*$($bad.ToLowerInvariant())*") { throw "fake: task refused for $Path$Name" } }
        $store.Tasks[$k] = [pscustomobject]@{ Path = $Path; Name = $Name; Enabled = $true; Xml = [string]$Xml }; [void]$store.Log.Add("TaskRegisterXml $Path$Name")
    }.GetNewClosure()
    $m.TaskRemove = { param($Path, $Name) $k = (([string]$Path) + ([string]$Name)).ToLowerInvariant(); $store.Tasks.Remove($k); [void]$store.Log.Add("TaskRemove $Path$Name") }.GetNewClosure()
    [pscustomobject]$m
}
