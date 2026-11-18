# A fake customization adapter (Modules\AVDTune.Custom.psm1, $C) for the checks and the GUI smoke test: files, registry, folders with their rules, shortcuts, the library
# and library scripts, all in memory. Nothing here touches the computer it runs on. Writes are logged in .Store.Log.
# Dot-source this file, then: $c = New-AVDTuneFakeCustom [-Seed @{ ... }]
# Seed keys (all optional): Files (path -> text or bytes), Folders (array), Rules (folder -> array of @{ Sid; Rights; Inherited }), Registry ('path|name' -> @{ Value; Kind }), Reachable (array of paths that answer, also UNC),
# Library (name -> text or bytes: the files of AVDTune-Assets), Shortcuts (path -> @{ Target; Arguments; Icon; WorkingDirectory; Description }), Links (array of paths that are links).
# Switches on .Store: FailWrite (a path or registry key part: the write throws), Tamper (library name -> other bytes: the download is different), ScriptMode
# (sha256 -> 'Ok' | 'Broken' (test answers 7) | 'NoChange' (apply does nothing)).

. (Join-Path $PSScriptRoot 'FakeShared.ps1')   # fakes that several runspaces use at once (#80)
function New-AVDTuneFakeCustom {
    param([hashtable]$Seed = @{})
    $enc = New-Object Text.UTF8Encoding $false
    $toBytes = { param($v) if ($v -is [byte[]]) { , $v } else { , $enc.GetBytes([string]$v) } }.GetNewClosure()
    $store = @{
        Files = @{}; Folders = @{}; Registry = @{}; Shortcuts = @{}; Rules = @{}; Reachable = @{}; Library = @{}; Links = @{}; Log = (New-Object System.Collections.ArrayList)
        FailWrite = ''; Tamper = @{}; ScriptMode = @{}; ScriptState = @{}; Runs = (New-Object System.Collections.ArrayList); Downloads = 0
    }
    foreach ($f in 'C:\Windows\Fonts', 'C:\Windows\System32\drivers\etc', 'C:\Users\Public\Desktop', 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs', 'C:\Apps', 'C:\Data') { $store.Folders[$f.ToLowerInvariant()] = $true }
    $store.Files['c:\windows\system32\drivers\etc\hosts'] = (& $toBytes "# hosts of the fake`r`n127.0.0.1 localhost`r`n")
    if ($Seed.Files) { foreach ($k in $Seed.Files.Keys) { $store.Files[([string]$k).ToLowerInvariant()] = (& $toBytes $Seed.Files[$k]); $store.Folders[(Split-Path ([string]$k) -Parent).ToLowerInvariant()] = $true } }
    foreach ($f in @($Seed.Folders)) { if ($f) { $store.Folders[([string]$f).ToLowerInvariant()] = $true } }
    if ($Seed.Rules) { foreach ($k in $Seed.Rules.Keys) { $store.Rules[([string]$k).ToLowerInvariant()] = @($Seed.Rules[$k]) } }
    if ($Seed.Registry) { foreach ($k in $Seed.Registry.Keys) { $store.Registry[([string]$k).ToLowerInvariant()] = $Seed.Registry[$k] } }
    foreach ($p in @($Seed.Reachable)) { if ($p) { $store.Reachable[([string]$p).ToLowerInvariant()] = $true } }
    if ($Seed.Library) { foreach ($k in $Seed.Library.Keys) { $store.Library[[string]$k] = (& $toBytes $Seed.Library[$k]) } }
    if ($Seed.Shortcuts) { foreach ($k in $Seed.Shortcuts.Keys) { $store.Shortcuts[([string]$k).ToLowerInvariant()] = [pscustomobject]$Seed.Shortcuts[$k] } }
    foreach ($p in @($Seed.Links)) { if ($p) { $store.Links[([string]$p).ToLowerInvariant()] = $true } }
    $sha = { param([byte[]]$b) $h = [Security.Cryptography.SHA256]::Create(); try { ([BitConverter]::ToString($h.ComputeHash($b)) -replace '-', '').ToLowerInvariant() } finally { $h.Dispose() } }
    $fail = { param($what) if ($store.FailWrite -and ([string]$what).ToLowerInvariant().Contains($store.FailWrite.ToLowerInvariant())) { throw "Write refused (fake): $what" } }.GetNewClosure()
    $log = { param($t) [void]$store.Log.Add($t) }.GetNewClosure()

    $c = [ordered]@{ Kind = 'Fake'; Store = $store }
    $c.Sha = $sha
    $c.Folder = {
        param($Name)
        switch ($Name) {
            'PublicDesktop' { 'C:\Users\Public\Desktop' } 'StartMenu' { 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs' } 'Fonts' { 'C:\Windows\Fonts' }
            'Hosts' { 'C:\Windows\System32\drivers\etc\hosts' } 'PublicIcons' { 'C:\ProgramData\AVDTune-Public\Icons' } default { throw "Unknown folder $Name." }
        }
    }
    $c.RegGet = { param($Path, $Name) $k = "$Path|$Name".ToLowerInvariant(); if ($store.Registry.ContainsKey($k)) { $store.Registry[$k] } else { $null } }.GetNewClosure()
    $c.RegSet = { param($Path, $Name, $Value, $Type) & $fail $Path; $store.Registry["$Path|$Name".ToLowerInvariant()] = @{ Value = $Value; Kind = [string]$Type }; & $log "RegSet $Path|$Name=$Value ($Type)" }.GetNewClosure()
    $c.RegRemove = { param($Path, $Name) & $fail $Path; $store.Registry.Remove("$Path|$Name".ToLowerInvariant()); & $log "RegRemove $Path|$Name" }.GetNewClosure()
    $c.FileHash = { param($Path) $k = ([string]$Path).ToLowerInvariant(); if ($store.Links.ContainsKey($k)) { throw "$Path is a link." }; if ($store.Files.ContainsKey($k)) { & $sha $store.Files[$k] } else { $null } }.GetNewClosure()
    $c.ReadText = { param($Path) $k = ([string]$Path).ToLowerInvariant(); if ($store.Links.ContainsKey($k)) { throw "$Path is a link: not read." }; if ($store.Files.ContainsKey($k)) { @{ Text = $enc.GetString($store.Files[$k]); Encoding = 'utf-8' } } else { $null } }.GetNewClosure()
    $c.WriteText = {
        param($Path, $Text, $Encoding)
        & $fail $Path
        $k = ([string]$Path).ToLowerInvariant()
        if ($store.Links.ContainsKey($k)) { throw "$Path is a link: nothing is written through it." }
        if (-not $store.Folders.ContainsKey((Split-Path $k -Parent))) { throw "The folder of $Path does not exist." }
        $store.Files[$k] = $enc.GetBytes([string]$Text); & $log "WriteText $Path"
    }.GetNewClosure()
    $c.FileSize = { param($Path) $k = ([string]$Path).ToLowerInvariant(); if ($store.Files.ContainsKey($k)) { [int64]$store.Files[$k].Length } else { throw "$Path is missing." } }.GetNewClosure()
    $c.FileDelete = { param($Path) & $fail $Path; $store.Files.Remove(([string]$Path).ToLowerInvariant()); & $log "FileDelete $Path" }.GetNewClosure()
    $c.FileMove = { param($From, $To) $f = ([string]$From).ToLowerInvariant(); $store.Files[([string]$To).ToLowerInvariant()] = $store.Files[$f]; $store.Files.Remove($f) }.GetNewClosure()
    $c.CopyFile = {
        param($From, $To, $Access)
        & $fail $To
        $t = ([string]$To).ToLowerInvariant(); $dir = Split-Path $t -Parent
        if ($store.Links.ContainsKey($t) -or $store.Links.ContainsKey($dir)) { throw "$To is a link: nothing is written through it." }
        if (-not $store.Folders.ContainsKey($dir)) { if ($Access -eq 'UsersRead') { $store.Folders[$dir] = $true } else { throw "The folder $dir does not exist." } }
        if ($store.Files.ContainsKey($t)) { throw "$To exists (CreateNew)." }
        $store.Files[$t] = $store.Files[([string]$From).ToLowerInvariant()]; & $log "CopyFile $To ($Access)"
    }.GetNewClosure()
    $c.DirInfo = {
        param($Path)
        $k = ([string]$Path).ToLowerInvariant()
        if (-not $store.Folders.ContainsKey($k)) { return @{ Exists = $false; Link = $false; Rules = @() } }
        @{ Exists = $true; Link = $store.Links.ContainsKey($k); Rules = @(@($store.Rules[$k]) | Where-Object { $_ }) }
    }.GetNewClosure()
    $c.DirCreate = { param($Path) & $fail $Path; $k = ([string]$Path).ToLowerInvariant(); if (-not $store.Folders.ContainsKey((Split-Path $k -Parent))) { throw "The folder $(Split-Path $Path -Parent) does not exist." }; $store.Folders[$k] = $true; & $log "DirCreate $Path" }.GetNewClosure()
    # like Windows: a rule for a SID with the same inheritance merges with the existing one (rights OR), removing takes the rights bits out (review #85, L3)
    $c.DirAddRule = {
        param($Path, $Sid, $Rights, $Inherit = 3, $Propagate = 0)
        & $fail $Path
        $k = ([string]$Path).ToLowerInvariant()
        if ($store.Links.ContainsKey($k)) { throw "$Path is a link." }
        $rules = @(@($store.Rules[$k]) | Where-Object { $_ })
        $hit = @($rules | Where-Object { $_.Sid -eq $Sid -and -not $_.Inherited -and [int]$_.Inherit -eq [int]$Inherit -and [int]$_.Propagate -eq [int]$Propagate })
        if ($hit.Count) { $hit[0].Rights = [int]$hit[0].Rights -bor [int]$Rights } else { $rules += @{ Sid = $Sid; Rights = [int]$Rights; Inherited = $false; Inherit = [int]$Inherit; Propagate = [int]$Propagate } }
        $store.Rules[$k] = $rules
        & $log "DirAddRule $Path $Sid $Rights"
    }.GetNewClosure()
    $c.DirRemoveRule = {
        param($Path, $Sid, $Rights)
        $k = ([string]$Path).ToLowerInvariant()
        $out = @()
        foreach ($r in @(@($store.Rules[$k]) | Where-Object { $_ })) {
            if ($r.Sid -eq $Sid -and -not $r.Inherited) { $r.Rights = [int]$r.Rights -band (-bnot [int]$Rights); if ([int]$r.Rights -eq 0) { continue } }
            $out += $r
        }
        $store.Rules[$k] = $out
        & $log "DirRemoveRule $Path $Sid"
    }.GetNewClosure()
    $c.DirRemoveEmpty = { param($Path) $k = ([string]$Path).ToLowerInvariant(); $busy = @($store.Files.Keys | Where-Object { $_.StartsWith($k + '\') }).Count + @($store.Folders.Keys | Where-Object { $_.StartsWith($k + '\') }).Count; if ($busy -eq 0) { $store.Folders.Remove($k); & $log "DirRemoveEmpty $Path" } }.GetNewClosure()
    $c.ShortcutRead = { param($Path) $k = ([string]$Path).ToLowerInvariant(); if ($store.Shortcuts.ContainsKey($k)) { $store.Shortcuts[$k] } else { $null } }.GetNewClosure()
    $c.ShortcutWrite = {
        param($Path, $Target, $Arguments, $Icon, $WorkingDirectory, $Description)
        & $fail $Path
        $k = ([string]$Path).ToLowerInvariant()
        if ($store.Links.ContainsKey((Split-Path $k -Parent))) { throw "The folder of $Path is not safe (link): no shortcut was written." }
        $store.Shortcuts[$k] = [pscustomobject]@{ Target = $Target; Arguments = $Arguments; Icon = $Icon; WorkingDirectory = $WorkingDirectory; Description = $Description }; & $log "ShortcutWrite $Path"
    }.GetNewClosure()
    $c.ShortcutDelete = { param($Path) & $fail $Path; $store.Shortcuts.Remove(([string]$Path).ToLowerInvariant()); & $log "ShortcutDelete $Path" }.GetNewClosure()
    $c.Reachable = { param($Path) $k = ([string]$Path).ToLowerInvariant(); $store.Reachable.ContainsKey($k) -or $store.Files.ContainsKey($k) -or $store.Folders.ContainsKey($k) }.GetNewClosure()
    $c.CacheFolder = { param($Root) $d = Join-Path $Root 'custom\files'; $store.Folders[$d.ToLowerInvariant()] = $true; $d }.GetNewClosure()
    $c.Download = {
        param($Context, $Name, $Sha256, $Destination)
        if (-not $Context) { throw 'No library context.' }
        if (-not $store.Library.ContainsKey($Name)) { throw "Graph answered 404." }
        $store.Downloads++
        $b = if ($store.Tamper.ContainsKey($Name)) { $store.Tamper[$Name] } else { $store.Library[$Name] }
        if ((& $sha $b) -ne $Sha256) { throw "$Name from the library does not match its SHA256: not used." }
        $store.Files[([string]$Destination).ToLowerInvariant()] = $b
    }.GetNewClosure()
    $c.RunScript = {
        # A library script of the fake: in place after Apply, missing after Undo (per SHA256); ScriptMode Broken answers 7, NoChange leaves Apply without effect
        param($Path, $Sha256, $Mode, $TimeoutSeconds)
        $k = ([string]$Path).ToLowerInvariant()
        if (-not $store.Files.ContainsKey($k) -or (& $sha $store.Files[$k]) -ne $Sha256) { throw 'The script does not match its pinned SHA256: not started.' }
        [void]$store.Runs.Add("$Mode $Sha256")
        $how = if ($store.ScriptMode.ContainsKey($Sha256)) { $store.ScriptMode[$Sha256] } else { 'Ok' }
        if ($how -eq 'Broken') { return [pscustomobject]@{ ExitCode = 7; Output = 'broken' } }
        switch ($Mode) {
            'Test' { [pscustomobject]@{ ExitCode = $(if ($store.ScriptState[$Sha256]) { 0 } else { 1 }); Output = '' } }
            'Apply' { if ($how -ne 'NoChange') { $store.ScriptState[$Sha256] = $true }; & $log "Script Apply $Sha256"; [pscustomobject]@{ ExitCode = 0; Output = '' } }
            'Undo' { $store.ScriptState[$Sha256] = $false; & $log "Script Undo $Sha256"; [pscustomobject]@{ ExitCode = 0; Output = '' } }
        }
    }.GetNewClosure()
    ConvertTo-AVDTuneFakeShared ([pscustomobject]$c)
}

function Get-AVDTuneFakeCustomLibrary {
    # The library of the fake as manifest rows (what Get-AVDTuneAssetManifest returns)
    param([Parameter(Mandatory)]$C)
    @($C.Store.Library.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Name = $_; Sha256 = (& $C.Sha $C.Store.Library[$_]); Size = [int64]$C.Store.Library[$_].Length; Extension = [IO.Path]::GetExtension($_).ToLowerInvariant() } })
}
