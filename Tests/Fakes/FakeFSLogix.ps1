# Fake of the FSLogix adapter (Modules\AVDTune.FSLogix.psm1, New-AVDTuneFSLogixAdapter): download, zip, files, DNS, TCP, share, Defender, local groups,
# in memory. No download, no share, no change of this computer. Everything asked is in .Log. Switches live in .Store:
#   Latest (@{ Ok; Url; Error }), DownloadFails, ExpandFails, NoInstaller, Protected ($false = download folder not protected), InstallerVersion,
#   Signatures (hashtable file name -> @{ Valid; Subject; Issuer; OriginalFilename }), Files (hashtable path -> text), FailWrite (paths that cannot be written),
#   Dns (host -> @{ Ok; Addresses; Error }), Tcp (host -> $true/$false), Probe (unc -> 'Ok' | 'Denied' | 'Failed'), WriteFail (name of the step that fails), Acl (unc -> SDDL),
#   Tickets (strings), Defender (@{ Paths; Processes } or $null = not readable), Groups (name -> array of SIDs; a missing name = group not there), FrxMissing,
#   MasterDomainSid (domain SID the master resolves for <NetBIOS>\Domain Admins; '' = cannot be resolved), LocalGroupAddFails (SIDs whose LocalGroupAdd throws).
# All names and addresses are made up (example.test, contoso).
function New-AVDTuneFakeFSLogix {
    param([hashtable]$Seed = @{})
    $s = @{
        Latest = @{ Ok = $true; Url = 'https://download.microsoft.com/download/00000000-0000-0000-0000-000000000000/FSLogix_26.08.zip'; Error = '' }
        DownloadFails = $false; ExpandFails = $false; NoInstaller = $false; Protected = $true; InstallerVersion = '3.26.826.17182'; Signatures = @{}; Files = @{}; FailWrite = @()
        Dns = @{}; Tcp = @{}; Probe = @{}; WriteFail = ''; Acl = @{}; Tickets = @(); Defender = @{ Paths = @(); Processes = @() }
        Groups = @{ 'FSLogix Profile Include List' = @('S-1-1-0'); 'FSLogix Profile Exclude List' = @() }; FrxMissing = $false; MasterDomainSid = ''; LocalGroupAddFails = @(); KeyMapFails = $false; Mapped = $false; KeySeen = $null; AsUser = $null
        Log = (New-Object System.Collections.ArrayList); Folders = @()
    }
    foreach ($e in $Seed.GetEnumerator()) { $s[$e.Key] = $e.Value }
    $a = [ordered]@{ Kind = 'Fake'; Store = $s; Log = $s.Log }
    $a.LatestRelease = { [void]$s.Log.Add('LatestRelease'); $s.Latest }.GetNewClosure()
    $a.NewTempFolder = { param($Root) $d = "C:\fake\temp\fslogix-$($s.Folders.Count)"; $s.Folders += $d; [void]$s.Log.Add("NewTempFolder $d"); $d }.GetNewClosure()
    $a.IsProtectedFolder = { param($Dir, $Root) [bool]$s.Protected }.GetNewClosure()
    $a.Download = { param($Url, $Dest, $Max) [void]$s.Log.Add("Download $Url"); if ($s.DownloadFails) { @{ Ok = $false; Error = 'fake: no connection' } } else { @{ Ok = $true; Error = ''; Bytes = 1000 } } }.GetNewClosure()
    $a.Expand = { param($Zip, $Dir) [void]$s.Log.Add("Expand $Zip"); if ($s.ExpandFails) { @{ Ok = $false; Error = 'fake: bad zip' } } else { @{ Ok = $true; Error = '' } } }.GetNewClosure()
    $a.FindInstaller = { param($Dir) if ($s.NoInstaller) { $null } else { "$Dir\x64\Release\FSLogixAppsSetup.exe" } }.GetNewClosure()
    $a.FindFrx = { if ($s.FrxMissing) { $null } else { 'C:\fake\FSLogix\Apps\frx.exe' } }.GetNewClosure()
    $a.FileVersion = { param($Path) $s.InstallerVersion }.GetNewClosure()
    $a.VerifySignature = {
        param($Path)
        $leaf = Split-Path $Path -Leaf
        [void]$s.Log.Add("VerifySignature $leaf")
        $sig = if ($s.Signatures.ContainsKey($leaf)) { $s.Signatures[$leaf] } else { @{ Valid = $true; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Issuer = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US' } }
        [pscustomobject]@{ Valid = [bool]$sig.Valid; Status = $(if ($sig.Valid) { 'Valid' } else { 'NotSigned' }); Subject = [string]$sig.Subject; Issuer = [string]$sig['Issuer']; OriginalFilename = $(if ($sig.ContainsKey('OriginalFilename')) { [string]$sig.OriginalFilename } else { $leaf }) }
    }.GetNewClosure()
    $a.RemoveFolder = { param($Dir) [void]$s.Log.Add("RemoveFolder $Dir") }.GetNewClosure()
    $a.ReadText = { param($Path) if ($s.Files.ContainsKey($Path)) { $s.Files[$Path] } else { $null } }.GetNewClosure()
    $a.WriteText = { param($Path, $Text) [void]$s.Log.Add("WriteText $Path"); if ($Path -in @($s.FailWrite)) { throw 'fake: the share refuses the write' }; $s.Files[$Path] = $Text }.GetNewClosure()
    $a.DeleteFile = { param($Path) [void]$s.Log.Add("DeleteFile $Path"); $s.Files.Remove($Path) }.GetNewClosure()
    $a.Dns = { param($H) [void]$s.Log.Add("Dns $H"); if ($s.Dns.ContainsKey($H)) { $s.Dns[$H] } else { @{ Ok = $true; Addresses = @('10.0.0.4'); Error = '' } } }.GetNewClosure()
    $a.Tcp = { param($H, $Port) [void]$s.Log.Add("Tcp $H`:$Port"); if ($s.Tcp.ContainsKey($H) -and -not $s.Tcp[$H]) { @{ Ok = $false; Error = 'timeout' } } else { @{ Ok = $true; Error = '' } } }.GetNewClosure()
    $a.ShareProbe = { param($Unc) [void]$s.Log.Add("ShareProbe $Unc"); $k = if ($s.Probe.ContainsKey($Unc)) { $s.Probe[$Unc] } else { 'Ok' }; switch ($k) { 'Ok' { @{ Ok = $true; Kind = ''; Error = '' } } 'Denied' { @{ Ok = $false; Kind = 'Denied'; Error = 'access denied' } } default { @{ Ok = $false; Kind = 'Failed'; Error = 'The network path was not found' } } } }.GetNewClosure()
    $a.ShareWriteTest = {
        param($Unc)
        [void]$s.Log.Add("ShareWriteTest $Unc")
        @{ Steps = @('create folder', 'write file', 'read file', 'delete file', 'delete folder' | ForEach-Object { @{ Name = $_; Ok = ($_ -ne $s.WriteFail); Error = $(if ($_ -eq $s.WriteFail) { 'Access is denied' } else { '' }) } }) }
    }.GetNewClosure()
    $a.ShareAcl = { param($Unc) if ($s.Acl.ContainsKey($Unc)) { $s.Acl[$Unc] } else { $null } }.GetNewClosure()
    $a.KeyMapAdd = { param($Unc, $User, $Key) [void]$s.Log.Add("KeyMapAdd $Unc as $User"); if ($s.KeyMapFails) { throw 'fake: system error 1326, logon failure' }; $s.Mapped = $true; $s.KeySeen = $Key }.GetNewClosure()
    $a.KeyMapRemove = { param($Unc) [void]$s.Log.Add("KeyMapRemove $Unc"); $s.Mapped = $false }.GetNewClosure()
    $a.ShareTestAsUser = {
        param($Unc, $User, $Password, $Dc)
        [void]$s.Log.Add("ShareTestAsUser $Unc as $User via $Dc")
        if ($s.AsUser) { return $s.AsUser }
        @{ LogonFailed = $false; Error = ''; Steps = @('create folder', 'write file', 'read file', 'delete file', 'delete folder' | ForEach-Object { @{ Name = $_; Ok = $true; Error = '' } }) }
    }.GetNewClosure()
    $a.KerberosTickets = { @($s.Tickets) }.GetNewClosure()
    $a.DefenderGet = { $s.Defender }.GetNewClosure()
    $a.DefenderAdd = { param($Kind, $Value) [void]$s.Log.Add("DefenderAdd $Kind $Value"); if ($Kind -eq 'Process') { $s.Defender.Processes = @($s.Defender.Processes) + $Value } else { $s.Defender.Paths = @($s.Defender.Paths) + $Value } }.GetNewClosure()
    $a.DefenderRemove = { param($Kind, $Value) [void]$s.Log.Add("DefenderRemove $Kind $Value"); if ($Kind -eq 'Process') { $s.Defender.Processes = @($s.Defender.Processes | Where-Object { $_ -ne $Value }) } else { $s.Defender.Paths = @($s.Defender.Paths | Where-Object { $_ -ne $Value }) } }.GetNewClosure()
    $a.LocalGroupMembers = { param($Name) if ($s.Groups.ContainsKey($Name)) { @{ Exists = $true; Members = @($s.Groups[$Name]) } } else { @{ Exists = $false; Members = @() } } }.GetNewClosure()
    $a.MasterDomainSid = { param($NetBios) [void]$s.Log.Add("MasterDomainSid $NetBios"); [string]$s.MasterDomainSid }.GetNewClosure()
    $a.LocalGroupAdd = { param($Name, $Sid) [void]$s.Log.Add("LocalGroupAdd $Name $Sid"); if ($Sid -in @($s.LocalGroupAddFails)) { throw "fake: the group refuses $Sid" }; $s.Groups[$Name] = @($s.Groups[$Name]) + $Sid }.GetNewClosure()
    $a.LocalGroupRemove = { param($Name, $Sid) [void]$s.Log.Add("LocalGroupRemove $Name $Sid"); $s.Groups[$Name] = @($s.Groups[$Name] | Where-Object { $_ -ne $Sid }) }.GetNewClosure()
    [pscustomobject]$a
}
