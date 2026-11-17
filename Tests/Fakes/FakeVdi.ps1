# Fake of the VDI component adapter (Modules\AVDTune.Vdi.psm1, New-AVDTuneVdiAdapter): redirects, download, signature, hold, run of the Teams bootstrapper, msiexec and winget, in memory.
# No download, no install, nothing of this computer is touched. The programs work on the fake machine like the real ones in outline: teamsbootstrapper.exe -p/-x sets or clears the Teams package,
# msiexec /i writes the Uninstall entry of the MSI (name and version from the Store), /x removes it, winget install/uninstall of OneDrive sets or clears the per machine OneDrive.
# Everything asked is in .Log. Switches live in .Store:
#   Redirects (hashtable entry link -> @{ Ok; Url; Error }), DownloadFails, Protected ($false = download folder not protected), Header (bytes of the file; default a real MSI header, text for the exe),
#   Signatures (hashtable leaf -> @{ Valid; Subject; Issuer; OriginalFilename }), SwapAfterCheck ($true = the file has another signer from the second check on), HoldFails, Running (names of running processes),
#   MsiProps (hashtable leaf -> properties of the MSI: ProductName, Manufacturer, ProductVersion), Exit (hashtable leaf or 'winget' -> exit code), NoEffect ($true = the program exits 0 and changes nothing), TeamsVersion, WebrtcVersion, MmrVersion, OneDriveVersion, Folders, Held (files held now).
#   Session host cards (issue 77): UdpListening / FirewallUdp ($true, $false or $null = cannot be read), TeredoType, Files (full paths that exist, e.g. the Defender VDI onboarding scripts).
# All names are made up; the addresses are of the real shape but point nowhere.
. (Join-Path $PSScriptRoot 'FakeUpdates.ps1')
function New-AVDTuneFakeVdi {
    param([Parameter(Mandatory)]$Machine, [hashtable]$Seed = @{})
    $s = @{
        Redirects = @{
            'https://go.microsoft.com/fwlink/?linkid=2243204' = @{ Ok = $true; Url = 'https://download.microsoft.com/download/aaaaaaaa-0000-1111-2222-333333333333/teamsbootstrapper.exe'; Error = '' }
            'https://aka.ms/msrdcwebrtcsvc/msi' = @{ Ok = $true; Url = 'https://download.microsoft.com/download/bbbbbbbb-0000-1111-2222-333333333333/MsRdcWebRTCSvc_HostSetup_1.54.2408.19001_x64.msi'; Error = '' }
            'https://aka.ms/avdmmr/msi' = @{ Ok = $true; Url = 'https://download.microsoft.com/download/cccccccc-0000-1111-2222-333333333333/MsMmrHostMri.msi'; Error = '' }
        }
        DownloadFails = $false; Protected = $true; Header = $null; Signatures = @{}; SwapAfterCheck = $false; HoldFails = $false; Running = @(); Exit = @{}; NoEffect = $false
        TeamsVersion = '26000.1.1.0'; WebrtcVersion = '1.54.2408.19001'; MmrVersion = '1.0.2410.0'; OneDriveVersion = '25.200.0'; Folders = @(); Held = @(); Checks = 0
        Teams = $null; OneDrive = $false; MsiProps = @{}
        UdpListening = $false; FirewallUdp = $false; TeredoType = 'Default'; Files = @()
        Log = (New-Object System.Collections.ArrayList)
    }
    foreach ($e in $Seed.GetEnumerator()) { $s[$e.Key] = $e.Value }
    $ms = $Machine
    $uni = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $codes = @{ 'webrtc-redirector.msi' = '{11111111-1111-1111-1111-111111111111}'; 'mmr-host.msi' = '{22222222-2222-2222-2222-222222222222}' }
    $names = @{ 'webrtc-redirector.msi' = 'Remote Desktop WebRTC Redirector Service'; 'mmr-host.msi' = 'Remote Desktop Multimedia Redirection Service' }
    $versions = @{ 'webrtc-redirector.msi' = 'WebrtcVersion'; 'mmr-host.msi' = 'MmrVersion' }
    $uf = New-AVDTuneFakeUpdates -Seed @{ Native = @{ '*winget.exe install *' = @{ ExitCode = 0; Output = 'ok' }; '*winget.exe uninstall *' = @{ ExitCode = 0; Output = 'ok' } }; Appx = @{} }
    $origRun = $uf.Run
    $uf.Run = {
        param($File, [string[]]$Arguments, [int]$TimeoutSeconds = 600)
        $r = & $origRun $File $Arguments $TimeoutSeconds
        if ($File -like '*winget*' -and $s.Exit.ContainsKey('winget')) { return [pscustomobject]@{ ExitCode = [int]$s.Exit['winget']; Output = 'fake: winget failed' } }
        if ($File -like '*winget*' -and $r.ExitCode -eq 0 -and -not $s.NoEffect) {
            if ($Arguments[0] -eq 'install') { $s.OneDrive = $true } elseif ($Arguments[0] -eq 'uninstall') { $s.OneDrive = $false }
        }
        $r
    }.GetNewClosure()
    $a = [ordered]@{ Kind = 'Fake'; Store = $s; Log = $s.Log; U = $uf }
    $a.Resolve = { param($Entry, $Kind) [void]$s.Log.Add("Resolve $Entry"); if ($s.Redirects.ContainsKey($Entry)) { $s.Redirects[$Entry] } else { @{ Ok = $false; Url = ''; Error = 'fake: unknown entry link' } } }.GetNewClosure()
    $a.NewTempFolder = { param($Root) $d = "C:\fake\temp\vdi-$($s.Folders.Count)"; $s.Folders += $d; [void]$s.Log.Add("NewTempFolder $d"); $d }.GetNewClosure()
    $a.IsProtectedFolder = { param($Dir, $Root) [void]$s.Log.Add("IsProtectedFolder $Dir"); [bool]$s.Protected }.GetNewClosure()
    $a.Download = { param($Url, $Dest, $Max) [void]$s.Log.Add("Download $Url"); if ($s.DownloadFails) { @{ Ok = $false; Error = 'fake: no connection' } } else { @{ Ok = $true; Error = ''; Bytes = 1000 } } }.GetNewClosure()
    $a.ReadHeader = { param($Path, $Count) [void]$s.Log.Add("ReadHeader $(Split-Path $Path -Leaf)"); if ($null -ne $s.Header) { [byte[]]$s.Header } elseif ($Path -like '*.msi') { [byte[]](0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1) } else { [byte[]](0x4D, 0x5A, 0, 0, 0, 0, 0, 0) } }.GetNewClosure()
    $a.HoldFile = {
        param($Path)
        [void]$s.Log.Add("HoldFile $Path")
        if ($s.HoldFails) { throw 'fake: the file is in use' }
        $s.Held += $Path
        $h = [pscustomobject]@{ Path = $Path; Store = $s }; Add-Member -InputObject $h -MemberType ScriptMethod -Name Dispose -Value { [void]$this.Store.Log.Add("ReleaseFile $($this.Path)"); $this.Store.Held = @($this.Store.Held | Where-Object { $_ -ne $this.Path }) } -PassThru
    }.GetNewClosure()
    $a.VerifySignature = {
        param($Path)
        $leaf = Split-Path $Path -Leaf
        [void]$s.Log.Add("VerifySignature $leaf")
        $win = $leaf -eq 'msiexec.exe'
        if (-not $win) { $s.Checks++ }
        $sig = if ($s.Signatures.ContainsKey($leaf)) { $s.Signatures[$leaf] } elseif ($win) { @{ Valid = $true; Subject = 'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Issuer = 'CN=Microsoft Windows Production PCA 2011, O=Microsoft Corporation, C=US' } }
        else { @{ Valid = $true; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Issuer = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US' } }
        if (-not $win -and $s.SwapAfterCheck -and $s.Checks -ge 2) { $sig = @{ Valid = $true; Subject = 'CN=Evil Corp, O=Evil Corp, C=US'; Issuer = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US' } }
        $orig = if ($sig.ContainsKey('OriginalFilename')) { [string]$sig.OriginalFilename } elseif ($leaf -like '*.msi') { '' } else { $leaf }
        [pscustomobject]@{ Valid = [bool]$sig.Valid; Status = $(if ($sig.Valid) { 'Valid' } else { 'NotSigned' }); Subject = [string]$sig.Subject; Issuer = [string]$sig['Issuer']; OriginalFilename = $orig; ProductName = ''; FileDescription = ''; FileMajor = 1 }
    }.GetNewClosure()
    $a.ReadMsiProperties = {
        param($Path)
        $leaf = Split-Path $Path -Leaf
        [void]$s.Log.Add("ReadMsiProperties $leaf")
        if ($s.MsiProps.ContainsKey($leaf)) { $s.MsiProps[$leaf] } else { @{ ProductName = $names[$leaf]; Manufacturer = 'Microsoft Corporation'; ProductVersion = $s[$versions[$leaf]] } }
    }.GetNewClosure()
    $a.MsiexecPath = { 'C:\fake\System32\msiexec.exe' }
    $a.Run = {
        param($File, [string[]]$Arguments, [int]$TimeoutSeconds = 600)
        $leaf = Split-Path $File -Leaf
        [void]$s.Log.Add("Run $File $($Arguments -join ' ')")
        $target = if ($leaf -eq 'msiexec.exe') { if ($Arguments[0] -eq '/i') { Split-Path $Arguments[1] -Leaf } else { 'product' } } else { $leaf }
        $code = if ($s.Exit.ContainsKey($target)) { [int]$s.Exit[$target] } else { 0 }
        if ($code -notin 0, 3010, 1641) { return [pscustomobject]@{ ExitCode = $code; Output = 'fake: the program failed' } }
        if ($s.NoEffect) { return [pscustomobject]@{ ExitCode = 0; Output = '' } }
        if ($leaf -eq 'teamsbootstrapper.exe') {
            if ($Arguments[0] -eq '-p') { $s.Teams = $s.TeamsVersion } elseif ($Arguments[0] -eq '-x') { $s.Teams = $null }
        }
        elseif ($leaf -eq 'msiexec.exe') {
            if ($Arguments[0] -eq '/i' -and $names.ContainsKey($target)) {
                & $ms.RegSet "$uni\$($codes[$target])" 'DisplayName' $names[$target] 'String'; & $ms.RegSet "$uni\$($codes[$target])" 'DisplayVersion' $s[$versions[$target]] 'String'
            }
            elseif ($Arguments[0] -eq '/x') { foreach ($c in $codes.Values) { if ($c -eq $Arguments[1]) { & $ms.RegRemove "$uni\$c" 'DisplayName'; & $ms.RegRemove "$uni\$c" 'DisplayVersion' } } }
        }
        [pscustomobject]@{ ExitCode = $code; Output = '' }
    }.GetNewClosure()
    $a.RemoveFolder = { param($Dir) [void]$s.Log.Add("RemoveFolder $Dir") }.GetNewClosure()
    $a.RunningProcesses = { param($Names) [void]$s.Log.Add('RunningProcesses'); @($Names | Where-Object { $_ -in @($s.Running) }) }.GetNewClosure()
    $a.AppxVersion = { param($Name) if ($Name -eq 'MSTeams') { $s.Teams } else { $null } }.GetNewClosure()
    $a.OneDrivePath = { 'C:\fake\Program Files\Microsoft OneDrive\OneDrive.exe' }
    $a.Exists = { param($Path) if ($Path -like '*OneDrive*') { [bool]$s.OneDrive } else { @($s.Files | Where-Object { $_ -eq $Path }).Count -gt 0 } }.GetNewClosure()
    $a.UdpListener = { param($Port) [void]$s.Log.Add("UdpListener $Port"); $s.UdpListening }.GetNewClosure()
    $a.FirewallUdpIn = { param($Port) [void]$s.Log.Add("FirewallUdpIn $Port"); $s.FirewallUdp }.GetNewClosure()
    $a.TeredoType = { $s.TeredoType }.GetNewClosure()
    $a.FileVersion = { param($Path) if ($s.OneDrive) { $s.OneDriveVersion } else { $null } }.GetNewClosure()
    [pscustomobject]$a
}
