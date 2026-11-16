# Fake of the Office adapter (Modules\AVDTune.Office.psm1, New-AVDTuneOfficeAdapter): the ODT page, the download, the signature, the run of the package and of
# setup.exe, in memory. No download, no install, nothing of this computer is touched. setup.exe /configure works on the fake machine like the real one in outline:
# it reads the configuration.xml that was handed over and writes the Click-to-Run registry values of the result (or removes them for <Remove All="TRUE"/>).
# Everything asked is in .Log. Switches live in .Store:
#   Page (@{ Ok; Text; Error }), DownloadFails, Protected ($false = download folder not protected), Signatures (hashtable leaf -> @{ Valid; Subject; Issuer; OriginalFilename }),
#   OdtFiles (names in the unpacked folder), ProtectedOdt ($false = the unpacked folder is not protected), HoldFails ($true = setup.exe cannot be held), SetupOutput (text the run gives back), PackageExit, NoSetup, SetupExit, ConfigureNoEffect ($true = setup.exe exits 0 but the registry does not change), SwapSetupAfterCheck ($true = the signature of setup.exe
#   is wrong from the second check on), Texts (hashtable path -> text written), Folders, Build (build number a fresh install reports).
# All names are made up. The package link is of the real shape (guid, officedeploymenttool_<build>-<build>.exe) but points nowhere useful.
function New-AVDTuneFakeOffice {
    param([Parameter(Mandatory)]$Machine, [hashtable]$Seed = @{})
    $s = @{
        Page = @{ Ok = $true; Text = '<html><a href="https://download.microsoft.com/download/00000000-1111-2222-3333-444444444444/officedeploymenttool_19999-20000.exe">Download</a></html>'; Error = '' }
        DownloadFails = $false; Protected = $true; ProtectedOdt = $true; OdtFiles = @('setup.exe', 'configuration-Office365-x64.xml', 'configuration-Office2019Enterprise.xml'); HoldFails = $false; SetupOutput = ''; Signatures = @{}; PackageExit = 0; NoSetup = $false; SetupExit = 0; ConfigureNoEffect = $false; SwapSetupAfterCheck = $false
        Texts = @{}; Folders = @(); Build = '16.0.19999.20000'; SetupChecks = 0
        Log = (New-Object System.Collections.ArrayList)
    }
    foreach ($e in $Seed.GetEnumerator()) { $s[$e.Key] = $e.Value }
    $ms = $Machine
    $ctr = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun'
    $guids = @{ MonthlyEnterprise = '55336b82-a18d-4dd6-b5f6-9e5095c314a6'; Current = '492350f6-3a01-4f97-b9c0-c7c6ddf67d60'; SemiAnnual = '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114'; CurrentPreview = '64256afe-f5d9-4f86-8936-8840a6a4f5be'; BetaChannel = 'b8f9b850-328d-4355-9145-c59439a0c4cf' }
    $a = [ordered]@{ Kind = 'Fake'; Store = $s; Log = $s.Log }
    $a.OdtPage = { [void]$s.Log.Add('OdtPage'); $s.Page }.GetNewClosure()
    $a.NewTempFolder = { param($Root) $d = "C:\fake\temp\office-$($s.Folders.Count)"; $s.Folders += $d; [void]$s.Log.Add("NewTempFolder $d"); $d }.GetNewClosure()
    $a.IsProtectedFolder = { param($Dir, $Root) [void]$s.Log.Add("IsProtectedFolder $Dir"); if ($Dir -like '*\odt') { [bool]$s.ProtectedOdt } else { [bool]$s.Protected } }.GetNewClosure()
    $a.Download = { param($Url, $Dest, $Max) [void]$s.Log.Add("Download $Url"); if ($s.DownloadFails) { @{ Ok = $false; Error = 'fake: no connection' } } else { @{ Ok = $true; Error = ''; Bytes = 1000 } } }.GetNewClosure()
    $a.VerifySignature = {
        param($Path)
        $leaf = Split-Path $Path -Leaf
        [void]$s.Log.Add("VerifySignature $leaf")
        if ($leaf -eq 'setup.exe') { $s.SetupChecks++ }
        $sig = if ($s.Signatures.ContainsKey($leaf)) { $s.Signatures[$leaf] } else { @{ Valid = $true; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Issuer = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US' } }
        if ($leaf -eq 'setup.exe' -and $s.SwapSetupAfterCheck -and $s.SetupChecks -ge 2) { $sig = @{ Valid = $true; Subject = 'CN=Evil Corp, O=Evil Corp, C=US'; Issuer = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US' } }
        $orig = if ($sig.ContainsKey('OriginalFilename')) { [string]$sig.OriginalFilename } elseif ($leaf -eq 'odt-package.exe') { 'officedeploymenttool_19999-20000.exe' } else { $leaf }
        $pn = if ($sig.ContainsKey('ProductName')) { [string]$sig.ProductName } elseif ($leaf -eq 'setup.exe') { 'Microsoft Office' } else { '' }
        $fd = if ($sig.ContainsKey('FileDescription')) { [string]$sig.FileDescription } elseif ($leaf -eq 'setup.exe') { 'Microsoft Office Deployment Tool' } else { '' }
        [pscustomobject]@{ Valid = [bool]$sig.Valid; Status = $(if ($sig.Valid) { 'Valid' } else { 'NotSigned' }); Subject = [string]$sig.Subject; Issuer = [string]$sig['Issuer']; OriginalFilename = $orig; ProductName = $pn; FileDescription = $fd; FileMajor = $(if ($sig.ContainsKey('FileMajor')) { [int]$sig.FileMajor } else { 16 }) }
    }.GetNewClosure()
    $a.Run = {
        param($File, [string[]]$Arguments, [int]$TimeoutSeconds = 600)
        $leaf = Split-Path $File -Leaf
        [void]$s.Log.Add("Run $File $($Arguments -join ' ')")
        if ($leaf -eq 'odt-package.exe') { return [pscustomobject]@{ ExitCode = $s.PackageExit; Output = '' } }
        if ($leaf -ne 'setup.exe') { return [pscustomobject]@{ ExitCode = 1; Output = 'fake: unknown program' } }
        if ($s.SetupExit -notin 0, 3010, 1641 -or $s.ConfigureNoEffect) { return [pscustomobject]@{ ExitCode = $s.SetupExit; Output = $s.SetupOutput } }
        $text = [string]$s.Texts[$Arguments[1]]
        $c = $null; try { $c = Test-AVDTuneOfficeXml $text } catch { }
        if (-not $c -or -not $c.Ok) { return [pscustomobject]@{ ExitCode = 30015; Output = 'fake: bad configuration' } }
        $k = "$ctr\Configuration"
        if ($c.Remove) { foreach ($n in 'VersionToReport', 'CDNBaseUrl', 'Platform', 'SharedComputerLicensing', 'UpdatesEnabled', 'ProductReleaseIds') { & $ms.RegRemove $k $n } }
        else {
            & $ms.RegSet $k 'VersionToReport' $s.Build 'String'
            & $ms.RegSet $k 'CDNBaseUrl' "http://officecdn.microsoft.com/pr/$($guids[$c.Channel])" 'String'
            & $ms.RegSet $k 'Platform' $(if ($c.Edition -eq '64') { 'x64' } else { 'x86' }) 'String'
            if ($c.Shared) { & $ms.RegSet $k 'SharedComputerLicensing' $c.Shared 'String' }
            & $ms.RegSet $k 'UpdatesEnabled' $c.UpdatesEnabled 'String'
            & $ms.RegSet $k 'ProductReleaseIds' $c.Product 'String'
            foreach ($l in $c.Languages) { if ($l -ne 'MatchOS') { & $ms.RegSet "$ctr\ProductReleaseIDs\$($c.Product)\$($l.ToLowerInvariant())" 'Installed' 1 'DWord' } }
        }
        [pscustomobject]@{ ExitCode = $s.SetupExit; Output = '' }
    }.GetNewClosure()
    $a.FindSetup = { param($Dir) if ($s.NoSetup) { $null } else { "$Dir\setup.exe" } }.GetNewClosure()
    $a.HoldFile = {
        param($Path)
        [void]$s.Log.Add("HoldFile $Path")
        if ($s.HoldFails) { throw 'fake: the file is in use' }
        $h = [pscustomobject]@{ Path = $Path; Log = $s.Log }; Add-Member -InputObject $h -MemberType ScriptMethod -Name Dispose -Value { [void]$this.Log.Add("ReleaseFile $($this.Path)") } -PassThru
    }.GetNewClosure()
    $a.ListFolder = { param($Dir) [void]$s.Log.Add("ListFolder $Dir"); @($s.OdtFiles) }.GetNewClosure()
    $a.WriteText = { param($Path, $Text) [void]$s.Log.Add("WriteText $Path"); $s.Texts[$Path] = $Text }.GetNewClosure()
    $a.RemoveFolder = { param($Dir) [void]$s.Log.Add("RemoveFolder $Dir") }.GetNewClosure()
    [pscustomobject]$a
}
