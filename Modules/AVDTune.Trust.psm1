<#
    AVDTune checks for the WebView2 cache folder that is loaded into the elevated process.

    The shared sign-in (Shared\Modules\PackTune.SignIn.psm1, Get-PackTuneWebView2) pins the WebView2 SDK (one NuGet version, SHA-256 of the
    package and of the three DLLs) and checks signature (Microsoft Corporation), hash and write permissions of the files on every load; a
    cache that fails is removed. AVDTune therefore no longer keeps its own signature, hash or trust-record check (it was a duplicate).
    What the shared code does not look at, and AVDTune keeps (Assert-AVDTuneWebView2Cache, before every sign-in):
      * the folder holds only the three DLLs and the marker webview2-sdk.json: no other file (side loading next to the DLLs), no sub folder,
        no link (junction or symlink), and the folder itself is not a link;
      * anything else: the folder is deleted (a link is removed itself, never its target), so the shared code downloads the pinned version
        again; when it cannot be deleted the sign-in is stopped.
    That the folder is below the protected state root (Administrators and SYSTEM only) is checked by the state root check of AVDTune.psm1.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')

$script:WebView2Files = @('Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll', 'WebView2Loader.dll', 'webview2-sdk.json')

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
        Called before every sign-in. Returns Status: Empty (nothing there, the shared code downloads and checks), Clean (only the expected
        entries; the shared code checks signature and hashes on load) or Reset (the folder had other entries or was a link and was deleted;
        Problems says why). Throws when such a folder cannot be deleted: then nothing may be loaded.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Folder)
    if (-not (Test-Path -LiteralPath $Folder)) { return [pscustomobject]@{ Status = 'Empty'; Problems = @() } }
    $problems = @(Get-AVDTuneFolderProblems -Folder $Folder -Expected $script:WebView2Files)
    if ($problems.Count -eq 0) { return [pscustomobject]@{ Status = 'Clean'; Problems = @() } }
    try { Remove-AVDTuneFolderNoFollow $Folder }
    catch { throw "The WebView2 folder $Folder has unexpected content ($($problems -join '; ')) and cannot be deleted: $($_.Exception.Message). The sign-in is stopped." }
    if (Test-Path -LiteralPath $Folder) { throw "The WebView2 folder $Folder has unexpected content and is still there. The sign-in is stopped." }
    [pscustomobject]@{ Status = 'Reset'; Problems = $problems }
}

Export-ModuleMember -Function Assert-AVDTuneWebView2Cache, Remove-AVDTuneFolderNoFollow
