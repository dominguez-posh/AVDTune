# A fake finish adapter for the checks and the GUI smoke test: the same members as New-AVDTuneFinishAdapter (Modules\AVDTune.Finish.psm1), kept in memory.
# Nothing here touches a folder, file, service or token of this computer.
# Dot-source this file, then: $f = New-AVDTuneFakeFinish [-Seed @{ ... }]
# Seed keys (all optional):
#   Items       hashtable Id -> array of entries; an entry is a name or @{ Name; Locked = $true; Link = $true; Dir = $true; ReadOnly = $true; Links = 2; Target = 'name of a protected list' }
#               (cleared in depth like the real adapter, #48: a Dir entry goes with its content, a Link entry is removed itself, a ReadOnly entry goes without its mark
#               being changed; with NoPosixDelete a ReadOnly entry with Links -ne 1 is skipped, as the real one does without POSIX delete)
#               Ids: temp, wer-queue, wer-archive, wu-download (the targets of the real adapter, with made-up paths)
#   LinkTargets hashtable name -> array of names: what a link points to. ClearFolder removes a link itself and never touches this list (a counter-test reads it)
#   Present     array of paths that exist for PathExists (default: the diskspd folder is NOT there)
#   TokenFiles  array of relative file names that "hold a token pattern" (FindTokenFiles returns them; they are never edited)
#   FailClear   array of target ids whose ClearFolder throws
#   NoPosixDelete  $true: the file system has no POSIX delete (a read-only entry with more than one link is skipped, not deleted)
#   Dependents  hashtable service name -> array of running dependent services (RunningDependents)
# .Store holds the state, .Log what was asked (never a secret).

function New-AVDTuneFakeFinish {
    param([hashtable]$Seed = @{})
    $store = @{
        Items = @{}; LinkTargets = @{}; Present = @(@($Seed.Present) | Where-Object { $_ }); TokenFiles = @(@($Seed.TokenFiles) | Where-Object { $_ }); FailClear = @(@($Seed.FailClear) | Where-Object { $_ }); NoPosixDelete = [bool]$Seed.NoPosixDelete; Dependents = $(if ($Seed.Dependents) { $Seed.Dependents } else { @{} })
        Log = (New-Object System.Collections.ArrayList)
        Paths = [ordered]@{ 'temp' = 'C:\Windows\Temp'; 'wer-queue' = 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue'; 'wer-archive' = 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive'; 'wu-download' = 'C:\Windows\SoftwareDistribution\Download' }
    }
    foreach ($id in $store.Paths.Keys) {
        $list = New-Object System.Collections.ArrayList
        if ($Seed.Items -and $Seed.Items.ContainsKey($id)) { foreach ($e in @($Seed.Items[$id])) { [void]$list.Add($(if ($e -is [System.Collections.IDictionary]) { [pscustomobject]$e } else { [pscustomobject]@{ Name = [string]$e; Locked = $false; Link = $false; Dir = $false; ReadOnly = $false; Links = 1; Target = '' } })) } }
        $store.Items[$store.Paths[$id]] = $list
    }
    foreach ($e in @($store.Items.Values)) { foreach ($i in $e) { foreach ($p in 'Locked', 'Link', 'Dir', 'ReadOnly', 'Links', 'Target') { if (-not $i.PSObject.Properties[$p]) { Add-Member -InputObject $i -NotePropertyName $p -NotePropertyValue $(switch ($p) { 'Target' { '' } 'Links' { 1 } default { $false } }) } } } }
    if ($Seed.LinkTargets) { foreach ($k in $Seed.LinkTargets.Keys) { $store.LinkTargets[[string]$k] = New-Object System.Collections.ArrayList(, @($Seed.LinkTargets[$k])) } }
    $a = [ordered]@{ Kind = 'Fake'; Store = $store; Log = $store.Log }
    $a.CleanTargets = { @($store.Paths.Keys | ForEach-Object { [pscustomobject]@{ Id = $_; Path = $store.Paths[$_] } }) }.GetNewClosure()
    $a.CountItems = { param($Path) if ($store.Items.ContainsKey($Path)) { $store.Items[$Path].Count } else { 0 } }.GetNewClosure()
    $a.ClearFolder = {
        param($Path)
        [void]$store.Log.Add("ClearFolder $Path")
        $id = @($store.Paths.Keys | Where-Object { $store.Paths[$_] -eq $Path })[0]
        if ($id -and $id -in $store.FailClear) { throw "fake: cannot clear $Path" }
        $removed = 0; $left = 0; $skipped = 0
        if ($store.Items.ContainsKey($Path)) {
            foreach ($i in @($store.Items[$Path].ToArray())) {
                if ($store.NoPosixDelete -and $i.ReadOnly -and $i.Links -ne 1) { $skipped++; continue }
                if ($i.Locked) { $left++; continue }
                $store.Items[$Path].Remove($i); $removed++   # a link is removed itself: its target list in LinkTargets stays untouched
                if ($i.Link) { [void]$store.Log.Add("LinkRemoved $($i.Name)") }
            }
        }
        [pscustomobject]@{ Removed = $removed; Left = $left; Skipped = $skipped }
    }.GetNewClosure()
    $a.RunningDependents = { param($Name) @($store.Dependents[[string]$Name] | Where-Object { $_ }) }.GetNewClosure()
    $a.PathExists = { param($Path) $Path -in $store.Present }.GetNewClosure()
    $a.RemoveFolder = { param($Path) [void]$store.Log.Add("RemoveFolder $Path"); $store.Present = @($store.Present | Where-Object { $_ -ne $Path }) }.GetNewClosure()
    $a.FindTokenFiles = { param($StateRoot) [void]$store.Log.Add('FindTokenFiles'); @($store.TokenFiles) }.GetNewClosure()
    [pscustomobject]$a
}
