<#
    AVDTune trust checks for files that are loaded into the elevated process.

    WebView2 SDK (embedded sign-in window): the shared sign-in (Shared\Modules\Keevault.psm1, Get-PackTuneWebView2) checks the Microsoft
    signature only right after it downloaded the DLLs; files that are already in the cache folder are loaded without any check. A user
    without admin rights could plant DLLs there before AVDTune ran for the first time. So AVDTune checks the folder itself before every
    call that loads the DLLs (Assert-AVDTuneWebView2Cache) and records what it trusted after a good check (Register-AVDTuneWebView2Cache):
      * only the three expected files, no other file or folder, no reparse point;
      * every file: Authenticode Valid, signer O=Microsoft Corporation, chain to a Microsoft root (pinned thumbprints);
      * every file matches the trust record (SHA-256 and file version) that AVDTune wrote in the protected state folder after an earlier good check.
    Anything else: the folder is deleted, so the shared code downloads a fresh copy and checks its signature; when the folder cannot be
    deleted the sign-in is stopped. The real fix (check before every load) belongs into the shared module in PackTune.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')

$script:WebView2Files = @('Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll', 'WebView2Loader.dll')
# Microsoft Root Certificate Authority 2010, Microsoft Root Certificate Authority 2011, Microsoft Root Authority (SHA-1 thumbprints)
$script:MicrosoftRoots = @('3B1EFD3A66EA28B16697394703A72CA340A05BD5', '8F43288AD272F3103B6FB1428485EA3014C0BCFE', 'A43489159A520F0D93D032CCAF37E7FE20A8B419')

function Get-AVDTuneFileSha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('X2') }) -join '' } finally { $stream.Dispose(); $sha.Dispose() }
}

function Test-AVDTuneMicrosoftSignature {
    <# Ok when the file has a valid Authenticode signature of Microsoft Corporation whose chain ends in a Microsoft root. Reason says why not. #>
    param([Parameter(Mandatory)][string]$Path)
    $no = { param($why) [pscustomobject]@{ Ok = $false; Reason = $why; Signer = '' } }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return (& $no 'missing') }
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid') { return (& $no "signature $($sig.Status)") }
    $signer = $sig.SignerCertificate
    if (-not $signer -or $signer.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') { return (& $no "signer is not Microsoft Corporation ($(if ($signer) { $signer.Subject }))") }
    $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
    try {
        $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck   # Authenticode already checked; no network wait
        $chain.ChainPolicy.VerificationFlags = [Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreNotTimeValid   # time stamped signatures outlive the certificate
        $built = $chain.Build($signer)
        $elements = @($chain.ChainElements | ForEach-Object { $_.Certificate })
        $root = if ($elements.Count -gt 0) { $elements[-1] } else { $null }
        if (-not $built -or -not $root) { return (& $no ('chain not valid: ' + ((@($chain.ChainStatus | ForEach-Object { $_.Status })) -join ', '))) }
        if ($root.Thumbprint.ToUpperInvariant() -notin $script:MicrosoftRoots) { return (& $no "chain ends in $($root.Subject), not in a Microsoft root") }
    }
    finally { $chain.Dispose() }
    [pscustomobject]@{ Ok = $true; Reason = ''; Signer = $signer.Subject }
}

function Get-AVDTuneWebView2TrustFile([string]$Root = (Get-AVDTuneRoot)) { Join-Path $Root 'config\webview2-trust.json' }

function Get-AVDTuneFolderProblems {
    # Files other than the expected ones, sub folders and reparse points in a cache folder
    param([string]$Folder, [string[]]$Expected)
    $problems = New-Object System.Collections.ArrayList
    $dir = New-Object IO.DirectoryInfo $Folder
    if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { [void]$problems.Add('the folder is a link'); return @($problems) }
    foreach ($item in $dir.GetFileSystemInfos()) {
        if ($item -is [IO.DirectoryInfo]) { [void]$problems.Add("unexpected folder $($item.Name)"); continue }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { [void]$problems.Add("$($item.Name) is a link"); continue }
        if ($item.Name -notin $Expected) { [void]$problems.Add("unexpected file $($item.Name)") }
    }
    @($problems)
}

function Remove-AVDTuneFolderNoFollow([string]$Folder) {
    # Deletes a folder; a link (junction, symlink) is removed itself, never what it points to
    $dir = New-Object IO.DirectoryInfo $Folder
    if (-not $dir.Exists) { return }
    if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $dir.Delete(); return }
    foreach ($item in $dir.GetFileSystemInfos()) {
        if ($item -is [IO.DirectoryInfo]) { Remove-AVDTuneFolderNoFollow $item.FullName }
        else { $item.Attributes = [IO.FileAttributes]::Normal; $item.Delete() }
    }
    $dir.Delete()
}

function Assert-AVDTuneWebView2Cache {
    <#
        Called before every call that loads the WebView2 DLLs. Returns Status: Empty (nothing there, the shared code downloads and checks),
        Trusted (all files match the trust record and are signed by Microsoft) or Reset (the folder was deleted; Problems says why).
        Throws when a folder that is not trusted cannot be deleted: then nothing may be loaded.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$TrustFile, [scriptblock]$Signature = { param($p) Test-AVDTuneMicrosoftSignature -Path $p })
    if (-not (Test-Path -LiteralPath $Folder)) { return [pscustomobject]@{ Status = 'Empty'; Problems = @() } }
    $problems = New-Object System.Collections.ArrayList
    foreach ($p in @(Get-AVDTuneFolderProblems -Folder $Folder -Expected $script:WebView2Files)) { [void]$problems.Add($p) }
    $trust = $null
    if ($problems.Count -eq 0) {
        $trust = Read-AVDTuneJson $TrustFile
        if (-not $trust) { [void]$problems.Add('no trust record from an earlier check') }
    }
    if ($problems.Count -eq 0) {
        foreach ($name in $script:WebView2Files) {
            $path = Join-Path $Folder $name
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { [void]$problems.Add("$name missing"); continue }
            $record = @(@(Get-AVDTuneProp $trust 'Files') | Where-Object { $_ -and $_.Name -eq $name })[0]
            $hash = Get-AVDTuneFileSha256 $path
            $version = [string]([Diagnostics.FileVersionInfo]::GetVersionInfo($path).FileVersion)
            if (-not $record -or [string]$record.Sha256 -ne $hash) { [void]$problems.Add("$name differs from the trusted file (SHA-256)"); continue }
            if ([string]$record.Version -ne $version) { [void]$problems.Add("$name has version $version, trusted $($record.Version)"); continue }
            $sig = & $Signature $path
            if (-not $sig.Ok) { [void]$problems.Add("$name $($sig.Reason)") }
        }
    }
    if ($problems.Count -eq 0) { return [pscustomobject]@{ Status = 'Trusted'; Problems = @() } }
    try { Remove-AVDTuneFolderNoFollow $Folder }
    catch { throw "The WebView2 files in $Folder are not trusted ($($problems -join '; ')) and cannot be deleted: $($_.Exception.Message). The sign-in is stopped." }
    if (Test-Path -LiteralPath $Folder) { throw "The WebView2 files in $Folder are not trusted and the folder is still there. The sign-in is stopped." }
    [pscustomobject]@{ Status = 'Reset'; Problems = @($problems) }
}

function Register-AVDTuneWebView2Cache {
    <#
        After the shared code downloaded (and loaded) the DLLs: checks them again and writes the trust record (name, SHA-256, file version,
        signer) into the protected state folder. A folder that fails the check is deleted. Returns Status: Empty, Registered or Reset.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$TrustFile, [scriptblock]$Signature = { param($p) Test-AVDTuneMicrosoftSignature -Path $p })
    if (-not (Test-Path -LiteralPath $Folder)) { return [pscustomobject]@{ Status = 'Empty'; Problems = @() } }
    $problems = New-Object System.Collections.ArrayList
    foreach ($p in @(Get-AVDTuneFolderProblems -Folder $Folder -Expected $script:WebView2Files)) { [void]$problems.Add($p) }
    $files = New-Object System.Collections.ArrayList
    if ($problems.Count -eq 0) {
        foreach ($name in $script:WebView2Files) {
            $path = Join-Path $Folder $name
            $sig = & $Signature $path
            if (-not $sig.Ok) { [void]$problems.Add("$name $($sig.Reason)"); continue }
            [void]$files.Add([ordered]@{ Name = $name; Sha256 = (Get-AVDTuneFileSha256 $path); Version = [string]([Diagnostics.FileVersionInfo]::GetVersionInfo($path).FileVersion); Signer = [string]$sig.Signer })
        }
    }
    if ($problems.Count -gt 0) {
        try { Remove-AVDTuneFolderNoFollow $Folder } catch { }
        if (Test-Path -LiteralPath $TrustFile) { Remove-Item -LiteralPath $TrustFile -Force -ErrorAction SilentlyContinue }
        return [pscustomobject]@{ Status = 'Reset'; Problems = @($problems) }
    }
    Write-AVDTuneFile $TrustFile (([ordered]@{ Schema = 1; CheckedAt = (Get-Date).ToString('o'); Files = @($files) }) | ConvertTo-Json -Depth 5)
    [pscustomobject]@{ Status = 'Registered'; Problems = @() }
}

Export-ModuleMember -Function Get-AVDTuneFileSha256, Test-AVDTuneMicrosoftSignature, Get-AVDTuneWebView2TrustFile, Assert-AVDTuneWebView2Cache, Register-AVDTuneWebView2Cache, Remove-AVDTuneFolderNoFollow
