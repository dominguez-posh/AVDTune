# Fake members for the optimization list (AppX packages and Microsoft Defender preferences), added to the fake machine of FakeMachine.ps1.
# Nothing here touches the computer it runs on. Dot-source FakeMachine.ps1 first, then: Add-AVDTuneOptimizationFakeMembers $m -Appx @('Microsoft.BingNews') -Defender @{ PUAProtection = 0 }
# $m.Store.FailWrites = @('part') makes AppxRemove and MpSet throw when the name contains the part (error path checks); $m.Store.Appx and $m.Store.Mp hold the state.

function Add-AVDTuneOptimizationFakeMembers {
    param([Parameter(Mandatory)]$Machine, [string[]]$Appx = @(), [hashtable]$Defender = @{})
    $store = $Machine.Store
    $store.Appx = @{}; foreach ($a in $Appx) { $store.Appx[$a.ToLowerInvariant()] = [pscustomobject]@{ Installed = $true; Provisioned = $true } }
    $store.Mp = @{}; foreach ($k in $Defender.Keys) { $store.Mp[[string]$k] = $Defender[$k] }
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
            if ($store.Mp.ContainsKey([string]$Name)) { $store.Mp[[string]$Name] } else { $null }
        }.GetNewClosure())
    $Machine | Add-Member -NotePropertyName MpSet -NotePropertyValue ({
            param($Name, $Value)
            foreach ($bad in @($store.FailWrites)) { if ($bad -and ([string]$Name).ToLowerInvariant() -like "*$($bad.ToLowerInvariant())*") { throw "fake: Set-MpPreference refused for $Name" } }
            $store.Mp[[string]$Name] = $Value; [void]$store.Log.Add("MpSet $Name=$Value")
        }.GetNewClosure())
    $Machine
}
