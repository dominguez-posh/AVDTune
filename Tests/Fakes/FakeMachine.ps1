# A fake machine for the checks and the GUI smoke test: the same adapter as New-AVDTuneMachine (Modules\AVDTune.psm1), kept in memory.
# Nothing here touches the registry, services, tasks or processes of the computer it runs on. Writes are logged in .Log.
# Dot-source this file, then: $m = New-AVDTuneFakeMachine [-Seed @{ ... }]
# Seed keys (all optional): Registry (hashtable 'path|name' -> value), Keys (array of registry keys that exist), Services (array of
# @{ Name; Status; StartType }), Tasks (array of @{ Path; Name; Enabled }), Imds (object or $null), Native (hashtable 'file args' -> @{ ExitCode; Output }),
# ComputerName, Now (datetime, fixed clock).

function New-AVDTuneFakeMachine {
    param([hashtable]$Seed = @{})
    $store = @{
        Registry = @{}; Keys = @{}; Services = @{}; Tasks = @{}; Native = @{}; Log = (New-Object System.Collections.ArrayList)
        ComputerName = $(if ($Seed.ComputerName) { $Seed.ComputerName } else { 'GM-TEST01' }); Now = $Seed.Now; Imds = $null
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
    foreach ($t in @($Seed.Tasks)) { if ($t) { $store.Tasks[(([string]$t.Path) + ([string]$t.Name)).ToLowerInvariant()] = [pscustomobject]@{ Path = $t.Path; Name = $t.Name; Enabled = [bool]$t.Enabled } } }
    $store.Imds = if ($Seed.ContainsKey('Imds')) { $Seed.Imds } else {
        [pscustomobject]@{ compute = [pscustomobject]@{
                name = 'gm-test01'; resourceGroupName = 'rg-example'; location = 'westeurope'; vmSize = 'Standard_D4s_v5'
                storageProfile = [pscustomobject]@{
                    imageReference = [pscustomobject]@{ publisher = 'microsoftwindowsdesktop'; offer = 'office-365'; sku = 'win11-25h2-avd-m365'; version = 'latest' }
                    osDisk = [pscustomobject]@{ name = 'gm-test01_osdisk' }
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
    $m.RegSet = {
        param($Path, $Name, $Value, $Type)
        $k = (([string]$Path) + '|' + ([string]$Name)).ToLowerInvariant()
        $store.Registry[$k] = $Value; [void]$store.Log.Add("RegSet $Path|$Name=$Value ($Type)")
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
    $m.TaskSetEnabled = {
        param($Path, $Name, $Enabled)
        $store.Tasks[(([string]$Path) + ([string]$Name)).ToLowerInvariant()].Enabled = [bool]$Enabled; [void]$store.Log.Add("TaskSetEnabled $Path$Name=$Enabled")
    }.GetNewClosure()
    $m.Run = {
        param($File, [string[]]$Arguments)
        $key = (@($File) + @($Arguments)) -join ' '
        [void]$store.Log.Add("Run $key")
        if ($store.Native.ContainsKey($key)) { [pscustomobject]$store.Native[$key] } else { [pscustomobject]@{ ExitCode = 1; Output = "fake: no answer for $key" } }
    }.GetNewClosure()
    $m.Imds = { $store.Imds }.GetNewClosure()
    [pscustomobject]$m
}
