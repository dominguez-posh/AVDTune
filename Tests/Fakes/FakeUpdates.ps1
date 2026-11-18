# Fake of the update adapter (Modules\AVDTune.Updates.psm1, New-AVDTuneUpdateAdapter): WUA, native tools, Defender, the lock, in memory.
# No Windows Update call, no process, no mutex. Everything asked is in .Log. Switches live in .Store.
#   Wua = list of @{ Id; Title; Kbs; IsDriver; SizeMB; Reboot }, WuaSearchFails (hresult), WuaResults = hashtable id -> array of @{ Ok; ResultCode; HResult; RebootRequired } (one per attempt),
#   MicrosoftUpdate (registered), RegisterFails, Native = hashtable 'file arg arg' -> @{ ExitCode; Output } (or an array, one per call), Tools = names that exist,
#   LockError (text: the lock cannot be taken), Defender, DefenderFails, Appx = hashtable name -> version,
#   Signatures = hashtable file name -> @{ Valid; Subject; Issuer; OriginalFilename } (otherwise the right publisher of each tool: Microsoft, choco Chocolatey),
#   Missing = full paths that do not exist. Stage/Unstage (copy of a tool into a private folder) only log.
. (Join-Path $PSScriptRoot 'FakeShared.ps1')   # fakes that several runspaces use at once (#80)
function New-AVDTuneFakeUpdates {
    param([hashtable]$Seed = @{})
    $s = @{ Wua = @(); WuaSearchFails = $null; WuaResults = @{}; MicrosoftUpdate = $false; RegisterFails = $false; Native = @{}; Tools = @('winget.exe', 'choco.exe', 'teamsbootstrapper.exe')
        LockError = ''; LockHeld = $false; Defender = @{ Version = '1.400.1.0'; LastUpdated = (Get-Date).AddHours(-2) }; DefenderFails = $false
        Appx = @{ MSTeams = '25000.1.1.0' }; Signatures = @{}; Missing = @()
        Files = @{ OneDrive = '25.100.0' }; Log = (New-Object System.Collections.ArrayList); Calls = @{} }
    foreach ($e in $Seed.GetEnumerator()) { $s[$e.Key] = $e.Value }
    $u = [ordered]@{ Kind = 'Fake'; Store = $s; Log = $s.Log }
    $u.Sleep = { param($Seconds) }.GetNewClosure()
    $u.Path = { param($Name) switch ($Name) { 'C2R' { 'C:\fake\OfficeC2RClient.exe' } 'EdgeUpdate' { 'C:\fake\MicrosoftEdgeUpdate.exe' } 'Dism' { 'C:\fake\System32\Dism.exe' } 'Sfc' { 'C:\fake\System32\sfc.exe' } default { "C:\fake\$Name.exe" } } }
    $u.Exists = { param($Path) [bool]$Path -and $Path -notin $s.Missing }.GetNewClosure()
    $u.FileVersion = { param($Path) $n = [IO.Path]::GetFileNameWithoutExtension($Path); if ($s.Files.ContainsKey($n)) { $s.Files[$n] } else { $null } }.GetNewClosure()
    $u.AppxVersion = { param($Name) if ($s.Appx.ContainsKey($Name)) { $s.Appx[$Name] } else { $null } }.GetNewClosure()
    $u.FindTool = { param($Name, $Extra) if ($Name -in $s.Tools) { "C:\fake\$Name" } else { $null } }.GetNewClosure()
    $u.VerifySignature = {
        param($Path)
        $leaf = Split-Path $Path -Leaf
        [void]$s.Log.Add("VerifySignature $Path")
        $sig = if ($s.Signatures.ContainsKey($leaf)) { $s.Signatures[$leaf] } elseif ($leaf -eq 'choco.exe') {
            @{ Valid = $true; Subject = 'CN="Chocolatey Software, Inc", O="Chocolatey Software, Inc", L=Topeka, S=Kansas, C=US'; Issuer = 'CN=DigiCert Trusted G4 Code Signing RSA4096 SHA384 2021 CA1, O="DigiCert, Inc.", C=US' }
        }
        else { @{ Valid = $true; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Issuer = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US' } }
        [pscustomobject]@{ Valid = [bool]$sig.Valid; Status = $(if ($sig.Valid) { 'Valid' } else { 'NotSigned' }); Subject = [string]$sig.Subject; Issuer = [string]$sig['Issuer']
            OriginalFilename = $(if ($sig.ContainsKey('OriginalFilename')) { [string]$sig.OriginalFilename } else { $leaf }); ProductName = '' }
    }.GetNewClosure()
    $u.Stage = { param($Path, $Root) [void]$s.Log.Add("Stage $Path"); 'C:\fake\staged\' + (Split-Path $Path -Leaf) }.GetNewClosure()
    $u.Unstage = { param($Path) [void]$s.Log.Add("Unstage $Path") }.GetNewClosure()
    $u.Run = {
        param($File, [string[]]$Arguments, [int]$TimeoutSeconds = 600)
        if (-not $s.LockHeld -and ($File -like '*winget*' -or $File -like '*choco*') -and $Arguments[0] -in 'upgrade', 'outdated') { [void]$s.Log.Add("UNLOCKED $File") }
        $key = (@($File) + @($Arguments)) -join ' '
        [void]$s.Log.Add("Run $key")
        $hit = $null
        foreach ($k in $s.Native.Keys) { if ($key -like $k) { $hit = $s.Native[$k]; break } }
        if ($null -eq $hit) { return [pscustomobject]@{ ExitCode = 1; Output = "fake: no answer for $key" } }
        if ($hit -is [array]) { $n = [int]$s.Calls[$key]; $s.Calls[$key] = $n + 1; $hit = $hit[[Math]::Min($n, $hit.Count - 1)] }
        [pscustomobject]$hit
    }.GetNewClosure()
    $u.WuaMicrosoftUpdateRegistered = { [bool]$s.MicrosoftUpdate }.GetNewClosure()
    $u.WuaRegisterMicrosoftUpdate = { [void]$s.Log.Add('WuaRegisterMicrosoftUpdate'); if ($s.RegisterFails) { @{ Ok = $false; Error = 'fake: no connection' } } else { $s.MicrosoftUpdate = $true; @{ Ok = $true; Error = '' } } }.GetNewClosure()
    $u.WuaSearch = {
        param($UseMicrosoftUpdate)
        [void]$s.Log.Add("WuaSearch microsoftupdate=$UseMicrosoftUpdate")
        if ($null -ne $s.WuaSearchFails) { return @{ Ok = $false; HResult = $s.WuaSearchFails; Error = 'fake'; Updates = @() } }
        @{ Ok = $true; HResult = 0; Error = ''; Updates = @($s.Wua | ForEach-Object { [pscustomobject]$_ }) }
    }.GetNewClosure()
    $u.WuaInstall = {
        param($Id)
        $n = [int]$s.Calls["wua:$Id"]; $s.Calls["wua:$Id"] = $n + 1
        [void]$s.Log.Add("WuaInstall $Id attempt $($n + 1)")
        $list = @($s.WuaResults[$Id]); if ($list.Count -eq 0 -or $null -eq $list[0]) { return @{ Ok = $true; ResultCode = 2; HResult = 0; RebootRequired = $false } }
        $list[[Math]::Min($n, $list.Count - 1)]
    }.GetNewClosure()
    $u.GetFSLogix = { if ($s.ContainsKey('FSLogix')) { $s.FSLogix } else { $null } }.GetNewClosure()
    $u.GetVdi = { if ($s.ContainsKey('Vdi')) { $s.Vdi } else { $null } }.GetNewClosure()
    $u.DefenderStatus = { $s.Defender }.GetNewClosure()
    $u.DefenderUpdate = { [void]$s.Log.Add('DefenderUpdate'); if ($s.DefenderFails) { @{ Ok = $false; Error = 'fake: offline' } } else { $s.Defender = @{ Version = '1.400.9.0'; LastUpdated = [datetime]'2026-11-15T12:00:00' }; @{ Ok = $true; Error = '' } } }.GetNewClosure()
    $u.LockEnter = { if ($s.LockError) { @{ Ok = $false; Error = $s.LockError } } else { $s.LockHeld = $true; [void]$s.Log.Add('LockEnter'); @{ Ok = $true; Error = '' } } }.GetNewClosure()
    $u.LockExit = { $s.LockHeld = $false; [void]$s.Log.Add('LockExit') }.GetNewClosure()
    ConvertTo-AVDTuneFakeShared ([pscustomobject]$u)
}
