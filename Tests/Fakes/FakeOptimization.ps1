# Fake members for the optimization list (AppX packages, Microsoft Defender preferences, registry detail), added to the fake machine of FakeMachine.ps1.
# Nothing here touches the computer it runs on. Dot-source FakeMachine.ps1 first, then: Add-AVDTuneOptimizationFakeMembers $m -Appx @('Microsoft.BingNews') -Defender @{ PUAProtection = 0 }
# $m.Store.FailWrites = @('part') makes AppxRemove and MpSet throw when the name contains the part (error path checks); $m.Store.Appx and $m.Store.Mp hold the state.
# Like the real system, Get-MpPreference answers 0 for a setting that was never set; $m.Store.MpUnreported = @('Name') makes MpGet answer $null (setting not reported).
# $m.Store.MpAbsent = $true makes MpGet throw like a host without Defender (command missing); $m.Store.MpError = 'text' makes it throw any other read error.
# $m.Store.RegKinds['path|name'] = 'Binary' (lower case key) makes RegInfo report another kind than DWord/String.
# #41: SharedSignaturesPath is text ('' = no path, not 0). $m.Store.Unc['\\server\share'] = @{ Ok; GuidFolders; Error } is what UncReadable answers for a path (lower case key); any other path cannot be reached.

. $(if (Get-Command Resolve-AVDTuneTestScript -ErrorAction Ignore) { $fakeShared = Resolve-AVDTuneTestScript -Path (Join-Path $PSScriptRoot 'FakeShared.ps1') -AppRoot (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent); if (-not $fakeShared) { throw 'FakeShared.ps1 is not a file below the Tests folder of this copy.' }; $fakeShared } else { Join-Path $PSScriptRoot 'FakeShared.ps1' })   # fakes that several runspaces use at once (#80), through the test script gate when the module is loaded
function Add-AVDTuneOptimizationFakeMembers {
    param([Parameter(Mandatory)]$Machine, [string[]]$Appx = @(), [hashtable]$Defender = @{})
    $store = $Machine.Store
    $store.Appx = @{}; foreach ($a in $Appx) { $store.Appx[$a.ToLowerInvariant()] = [pscustomobject]@{ Installed = $true; Provisioned = $true } }
    $store.Mp = @{}; foreach ($k in $Defender.Keys) { $store.Mp[[string]$k] = $Defender[$k] }
    $store.MpUnreported = @(); $store.RegKinds = @{}; $store.Unc = @{}; $store.DnsDomain = ''
    if (-not $store.Mp.ContainsKey('SharedSignaturesPath')) { $store.Mp['SharedSignaturesPath'] = '' }
    # Default user profile (#40): loading is simulated through the real Mount-/Dismount-AVDTuneDefaultHive with fake operations. $m.Store.Hive holds Loaded, Registry
    # ('path|name' lower case -> value), Kinds, Keys, Loads, Unloads; Stale = a hive left loaded by a crash (set Loaded = $true before the first use), FailLoad = reg load
    # fails, StuckUnloads = n unload attempts fail (an open handle), PathError = the profile path check throws this text. The members refuse when the hive is not loaded.
    # the same table as HiveLoaded/HiveUnload of FakeMachine.ps1 (one hive)
    if (-not $store.Hive) { $store.Hive = @{ Loaded = $false; StuckUnloads = 0; Unloads = 0; Log = (New-Object System.Collections.ArrayList) } }
    $hive = $store.Hive
    foreach ($kv in @(@{ Registry = @{}; Kinds = @{}; Keys = @{}; Loads = 0; FailLoad = $false; PathError = $null; Mounted = $false }.GetEnumerator())) { $hive[$kv.Key] = $kv.Value }
    $hops = @{
        Loaded = { [bool]$hive.Loaded }.GetNewClosure()
        Reg = {
            param($Arguments)
            [void]$hive.Log.Add("reg $($Arguments -join ' ')")   # loading is a read, not a write: its own log
            if ($Arguments[0] -eq 'load') { if ($hive.FailLoad) { return [pscustomobject]@{ ExitCode = 1; Output = 'fake: access denied' } }; $hive.Loaded = $true; $hive.Loads++; return [pscustomobject]@{ ExitCode = 0; Output = '' } }
            if ($hive.StuckUnloads -gt 0) { $hive.StuckUnloads--; return [pscustomobject]@{ ExitCode = 1; Output = 'fake: in use' } }
            $hive.Loaded = $false; $hive.Unloads++; [pscustomobject]@{ ExitCode = 0; Output = '' }
        }.GetNewClosure()
        HivePath = { if ($hive.PathError) { throw [string]$hive.PathError }; 'C:\Users\Default\NTUSER.DAT' }.GetNewClosure()
        Sleep = { param($ms) }
    }
    $hensure = { if (-not $hive.Mounted) { Mount-AVDTuneDefaultHive -Ops $hops; $hive.Mounted = $true }; if (-not $hive.Loaded) { throw 'fake: HKU\AVDTune_DefaultUser is not loaded' } }.GetNewClosure()
    $hkeyExists = { param($p) $p = ([string]$p).ToLowerInvariant(); if ($hive.Keys.ContainsKey($p)) { return $true }; foreach ($k in @($hive.Keys.Keys) + @($hive.Registry.Keys)) { if ($k.StartsWith($p + '\') -or $k.StartsWith($p + '|')) { return $true } }; $false }.GetNewClosure()
    $Machine | Add-Member -NotePropertyName HiveInfo -NotePropertyValue ({
            param($Path, $Name)
            Assert-OptHiveAccess -Path $Path -Name ([string]$Name); & $hensure
            $k = (([string]$Path) + '|' + ([string]$Name)).ToLowerInvariant()
            if (-not $hive.Registry.ContainsKey($k)) { return [pscustomobject]@{ KeyExists = (& $hkeyExists $Path); Exists = $false; Kind = $null; Value = $null } }
            [pscustomobject]@{ KeyExists = $true; Exists = $true; Kind = $hive.Kinds[$k]; Value = $hive.Registry[$k] }
        }.GetNewClosure())
    $Machine | Add-Member -NotePropertyName HiveKeyExists -NotePropertyValue ({ param($Path) & $hensure; & $hkeyExists $Path }.GetNewClosure())
    $Machine | Add-Member -NotePropertyName HiveSet -NotePropertyValue ({
            param($Path, $Name, $Value, $Type)
            Assert-OptHiveAccess -Path $Path -Name ([string]$Name)
            if (-not (Test-AVDTuneWriteAllowed)) { throw 'The write gate is closed: the default user profile is not changed.' }
            & $hensure
            $k = (([string]$Path) + '|' + ([string]$Name)).ToLowerInvariant()
            foreach ($bad in @($store.FailWrites)) { if ($bad -and $k -like "*$($bad.ToLowerInvariant())*") { throw "fake: hive write refused for $Path|$Name" } }
            $hive.Registry[$k] = $Value; $hive.Kinds[$k] = [string]$Type; [void]$store.Log.Add("HiveSet $Path|$Name=$Value ($Type)")
        }.GetNewClosure())
    $Machine | Add-Member -NotePropertyName HiveRemove -NotePropertyValue ({
            param($Path, $Name)
            Assert-OptHiveAccess -Path $Path -Name ([string]$Name)
            if (-not (Test-AVDTuneWriteAllowed)) { throw 'The write gate is closed: the default user profile is not changed.' }
            & $hensure
            $k = (([string]$Path) + '|' + ([string]$Name)).ToLowerInvariant()
            $hive.Registry.Remove($k); $hive.Kinds.Remove($k); [void]$store.Log.Add("HiveRemove $Path|$Name")
        }.GetNewClosure())
    $Machine | Add-Member -NotePropertyName HiveKeyRemoveEmpty -NotePropertyValue ({
            param($Path)
            Assert-OptHiveAccess -Path $Path -Name $null
            if (-not (Test-AVDTuneWriteAllowed)) { throw 'The write gate is closed: the default user profile is not changed.' }
            & $hensure
            $p = ([string]$Path).ToLowerInvariant()
            foreach ($k in @($hive.Keys.Keys) + @($hive.Registry.Keys)) { if ($k.StartsWith($p + '\') -or $k.StartsWith($p + '|')) { [void]$store.Log.Add("HiveKeyKept $Path"); return } }
            $hive.Keys.Remove($p); [void]$store.Log.Add("HiveKeyRemoveEmpty $Path")
        }.GetNewClosure())
    $Machine | Add-Member -NotePropertyName HiveUnmount -NotePropertyValue ({
            if (-not $hive.Mounted) { return }
            if (-not (Dismount-AVDTuneDefaultHive -Ops $hops)) { throw 'HKU\AVDTune_DefaultUser could not be unloaded (a handle is still open); it is unloaded before the next use.' }
            $hive.Mounted = $false
        }.GetNewClosure())
    $m = $Machine
    $Machine | Add-Member -NotePropertyName AppxState -NotePropertyValue ({
            param($Name)
            $k = ([string]$Name).ToLowerInvariant()
            if ($store.Appx.ContainsKey($k)) { $store.Appx[$k] } else { [pscustomobject]@{ Installed = $false; Provisioned = $false } }
        }.GetNewClosure())
    $Machine | Add-Member -NotePropertyName AppxRemove -NotePropertyValue ({
            param($Name)
            foreach ($bad in @($store.FailWrites)) { if ($bad -and ([string]$Name).ToLowerInvariant() -like "*$($bad.ToLowerInvariant())*") { throw "fake: remove refused for $Name" } }
            $store.Appx.Remove(([string]$Name).ToLowerInvariant()); [void]$store.Log.Add("AppxRemove $Name")
        }.GetNewClosure())
    $Machine | Add-Member -NotePropertyName MpGet -NotePropertyValue ({
            param($Name)
            if ($store.MpAbsent) { throw [System.Management.Automation.CommandNotFoundException]::new('The term Get-MpPreference is not recognized.') }   # no Defender on this host
            if ($store.MpError) { throw [string]$store.MpError }   # any other read error (a policy, a damaged WMI)
            if (@($store.MpUnreported) -contains [string]$Name) { return $null }
            if ($store.Mp.ContainsKey([string]$Name)) { $store.Mp[[string]$Name] } else { 0 }
        }.GetNewClosure())
    $Machine | Add-Member -NotePropertyName MpSet -NotePropertyValue ({
            param($Name, $Value, $Restore = $false)
            foreach ($bad in @($store.FailWrites)) { if ($bad -and ([string]$Name).ToLowerInvariant() -like "*$($bad.ToLowerInvariant())*") { throw "fake: Set-MpPreference refused for $Name" } }
            # like Set-MpPreference: the threat actions are an enum (Clean=1, Quarantine=2, Remove=3, Allow=6, UserDefined=8, NoAction=9, Block=10, None=11), 0 and other numbers cannot be bound
            if ([string]$Name -like '*ThreatDefaultAction' -and (@(1, 2, 3, 6, 8, 9, 10, 11) -notcontains [int]$Value)) { throw "fake: Set-MpPreference cannot bind $Value to $Name (not a value of the enum ThreatAction)" }
            $store.Mp[[string]$Name] = $Value; [void]$store.Log.Add("MpSet $Name=$Value restore=$Restore")
        }.GetNewClosure())
    $Machine | Add-Member -NotePropertyName DnsDomain -NotePropertyValue ({ [string]$store.DnsDomain }.GetNewClosure())
    $Machine | Add-Member -NotePropertyName UncReadable -NotePropertyValue ({
            param($Path, $Domains = @())
            [void]$store.Log.Add("UncReadable $Path")
            $hp = Get-OptUncHostProblem -HostName (Get-OptUncHost $Path) -Domains @($Domains); if ($hp) { throw "Refused: $hp" }   # like the real member
            $k = ([string]$Path).TrimEnd('\').ToLowerInvariant()
            if ($store.Unc.ContainsKey($k)) { $store.Unc[$k] } else { @{ Ok = $false; GuidFolders = 0; Error = 'The network path was not found.' } }
        }.GetNewClosure())
    $Machine | Add-Member -NotePropertyName RegInfo -NotePropertyValue ({
            param($Path, $Name)
            $k = (([string]$Path) + '|' + ([string]$Name)).ToLowerInvariant()
            $keyExists = [bool](& $m.RegKeyExists $Path)
            if (-not $store.Registry.ContainsKey($k)) { return [pscustomobject]@{ KeyExists = $keyExists; Exists = $false; Kind = $null; Value = $null } }
            $v = $store.Registry[$k]
            $kind = if ($store.RegKinds.ContainsKey($k)) { $store.RegKinds[$k] } elseif ($v -is [string]) { 'String' } else { 'DWord' }
            [pscustomobject]@{ KeyExists = $keyExists; Exists = $true; Kind = $kind; Value = $v }
        }.GetNewClosure())
    $Machine | Add-Member -NotePropertyName RegKeyRemoveEmpty -NotePropertyValue ({
            param($Path)
            # like the real member: only when the key holds no values and no sub keys; otherwise it stays (logged as RegKeyKept)
            $p = ([string]$Path).ToLowerInvariant()
            $hasValues = $false; $hasSub = $false
            foreach ($k in $store.Registry.Keys) { if ($k.StartsWith($p + '|')) { $hasValues = $true }; if ($k.StartsWith($p + '\')) { $hasSub = $true } }
            foreach ($k in $store.Keys.Keys) { if ($k.StartsWith($p + '\')) { $hasSub = $true } }
            if ($hasValues -or $hasSub) { [void]$store.Log.Add("RegKeyKept $Path"); return }
            $store.Keys.Remove($p); [void]$store.Log.Add("RegKeyRemoveEmpty $Path")
        }.GetNewClosure())
    ConvertTo-AVDTuneFakeShared $Machine
}
