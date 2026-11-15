<#
    AVDTune desktop shortcut (issue #15): one shortcut AVDTune.lnk on the desktop of the signed-in administrator, never on the Public Desktop
    (that one goes into the image for every user). It starts the launcher of the installed copy (Program Files\AVDTune\Start-AVDTune.ps1, #4):

      Target            <System folder>\WindowsPowerShell\v1.0\powershell.exe (full path from [Environment]::GetFolderPath('System'))
      Arguments         -NoProfile -ExecutionPolicy Bypass -File "<install folder>\Start-AVDTune.ps1"
      Working folder    the install folder
      Icon              <install folder>\AVDTune.ico when it exists, else powershell.exe
      Run as admin      set in the .lnk (LinkFlags bit RunAsUser 0x00002000, see Set-AVDTuneLnkRunAs)

    The shortcut is offered only when AVDTune runs installed (mode Installed); the answer is kept per Windows account in state.json
    (DesktopShortcut.<SID>) and not asked again. Creating and removing it later: Integrity and updates card.
    The .lnk is written with the Windows Script Host shell object (WScript.Shell), which Windows PowerShell 5.1 has without compiling code.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')

$script:ShortcutName = 'AVDTune.lnk'
$script:Description = 'AVDTune: Golden Master for Azure Virtual Desktop (runs as administrator)'
# MS-SHLLINK 2.1: ShellLinkHeader. HeaderSize 0x0000004C, LinkCLSID (the class ID of ShellLink, bytes below), LinkFlags (4 bytes) at offset 0x14
$script:LnkClsid = [byte[]](0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46)

function Get-AVDTuneShortcutName { $script:ShortcutName }

function Get-AVDTuneUserDesktop { [Environment]::GetFolderPath('DesktopDirectory') }

function Get-AVDTuneUserKey {
    # The answer belongs to the Windows account: its SID
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Test-AVDTunePublicDesktop {
    <# True when a folder is the Public Desktop (or anywhere below the Public profile): AVDTune never writes a shortcut there. #>
    param([Parameter(Mandatory)][string]$Folder)
    $f = [IO.Path]::GetFullPath($Folder).TrimEnd('\')
    $public = @([Environment]::GetFolderPath('CommonDesktopDirectory'), $env:PUBLIC, (Join-Path $env:SystemDrive 'Users\Public')) | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
    foreach ($p in $public) { if ($f -ieq $p -or $f.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    $f -match '(?i)\\Users\\(Public|Default|Default User|All Users)(\\|$)'
}

function Get-AVDTuneShortcutSpec {
    # What the shortcut must contain for an install folder
    param([Parameter(Mandatory)][string]$InstallRoot)
    $root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $ps = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $ico = Join-Path $root 'AVDTune.ico'
    [pscustomobject]@{
        Target = $ps; Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $root 'Start-AVDTune.ps1')`""; WorkingDirectory = $root
        Icon = $(if (Test-Path -LiteralPath $ico -PathType Leaf) { "$ico,0" } else { "$ps,0" }); Description = $script:Description
    }
}

function Test-AVDTuneLnkHeader([byte[]]$Bytes) {
    if ($Bytes.Length -lt 0x4C) { return $false }
    if ([BitConverter]::ToUInt32($Bytes, 0) -ne 0x4C) { return $false }
    for ($i = 0; $i -lt 16; $i++) { if ($Bytes[4 + $i] -ne $script:LnkClsid[$i]) { return $false } }
    $true
}

function Set-AVDTuneLnkRunAs {
    <#
        Sets "Run as administrator" in a .lnk: LinkFlags bit RunAsUser (0x00002000) of the ShellLinkHeader, i.e. byte 0x15 |= 0x20.
        Why a byte patch and not IShellLinkDataList::SetFlags(SLDF_RUNAS_USER): the COM interface needs C# compiled at run time (Add-Type),
        which application control on a hardened master can block and which leaves a temporary assembly; the header layout is fixed by the
        published format (MS-SHLLINK 2.1: HeaderSize 0x4C, LinkCLSID, LinkFlags at offset 0x14) and SLDF_RUNAS_USER is the same bit.
        The header is checked before (size and CLSID) and the flag is read back after the write.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if (-not (Test-AVDTuneLnkHeader $bytes)) { throw "$Path is not a shell link (header)." }
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [IO.File]::WriteAllBytes($Path, $bytes)
    if (-not (Test-AVDTuneLnkRunAs $Path)) { throw "Run as administrator could not be set in $Path." }
}

function Test-AVDTuneLnkRunAs([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    (Test-AVDTuneLnkHeader $bytes) -and (($bytes[0x15] -band 0x20) -ne 0)
}

function Get-AVDTuneDesktopShortcut {
    <# The AVDTune shortcut in a folder: Path, Target, Arguments, WorkingDirectory, Icon, RunAs, Matches (the spec of -InstallRoot); $null when there is none. #>
    param([string]$Folder = (Get-AVDTuneUserDesktop), [string]$InstallRoot)
    $path = Join-Path $Folder $script:ShortcutName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $shell = New-Object -ComObject WScript.Shell
    try {
        $l = $shell.CreateShortcut($path)
        $info = [pscustomobject]@{ Path = $path; Target = [string]$l.TargetPath; Arguments = [string]$l.Arguments; WorkingDirectory = [string]$l.WorkingDirectory; Icon = [string]$l.IconLocation; RunAs = (Test-AVDTuneLnkRunAs $path); Matches = $false }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($l)
    }
    finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    if ($InstallRoot) {
        $s = Get-AVDTuneShortcutSpec $InstallRoot
        $info.Matches = ($info.Target -ieq $s.Target -and $info.Arguments -ceq $s.Arguments -and $info.WorkingDirectory.TrimEnd('\') -ieq $s.WorkingDirectory -and $info.RunAs)
    }
    $info
}

function New-AVDTuneDesktopShortcut {
    <#
        Writes AVDTune.lnk into the desktop of the current user (or -Folder, used by the checks with a temporary folder). Refuses the Public
        Desktop and any folder of the Public or Default profile. An existing AVDTune.lnk there is replaced. Returns Get-AVDTuneDesktopShortcut.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallRoot, [string]$Folder = (Get-AVDTuneUserDesktop))
    if (-not $Folder) { throw 'The desktop folder of this account is not known.' }
    if (Test-AVDTunePublicDesktop $Folder) { throw "AVDTune never puts a shortcut on the Public Desktop ($Folder): it would be in the image for every user." }
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { throw "The desktop folder $Folder does not exist." }
    $spec = Get-AVDTuneShortcutSpec $InstallRoot
    $path = Join-Path $Folder $script:ShortcutName
    $shell = New-Object -ComObject WScript.Shell
    try {
        $l = $shell.CreateShortcut($path)
        $l.TargetPath = $spec.Target; $l.Arguments = $spec.Arguments; $l.WorkingDirectory = $spec.WorkingDirectory
        $l.IconLocation = $spec.Icon; $l.Description = $spec.Description; $l.WindowStyle = 1
        $l.Save()
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($l)
    }
    finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    Set-AVDTuneLnkRunAs $path
    Get-AVDTuneDesktopShortcut -Folder $Folder -InstallRoot $InstallRoot
}

function Remove-AVDTuneDesktopShortcut {
    <# Removes AVDTune.lnk from the desktop of the current user (or -Folder). Only that file; never the Public Desktop. Returns $true when one was removed. #>
    param([string]$Folder = (Get-AVDTuneUserDesktop))
    if (Test-AVDTunePublicDesktop $Folder) { throw "AVDTune does not change the Public Desktop ($Folder); remove a shortcut there by hand." }
    $path = Join-Path $Folder $script:ShortcutName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    Remove-Item -LiteralPath $path -Force
    $true
}

function Get-AVDTuneShortcutAnswer {
    <# The stored answer of an account: 'Yes', 'No' or '' (not asked yet). #>
    param([string]$Root = (Get-AVDTuneRoot), [string]$UserKey = (Get-AVDTuneUserKey))
    $all = Get-AVDTuneProp (Get-AVDTuneState $Root) 'DesktopShortcut'
    [string](Get-AVDTuneProp (Get-AVDTuneProp $all $UserKey) 'Answer')
}

function Set-AVDTuneShortcutAnswer {
    param([string]$Root = (Get-AVDTuneRoot), [string]$UserKey = (Get-AVDTuneUserKey), [Parameter(Mandatory)][ValidateSet('Yes', 'No')][string]$Answer)
    if ($UserKey -notmatch '^[A-Za-z0-9-]{1,184}$') { throw 'The account key is not valid.' }
    $all = [ordered]@{}
    $old = Get-AVDTuneProp (Get-AVDTuneState $Root) 'DesktopShortcut'
    if ($old) { foreach ($p in $old.PSObject.Properties) { $all[$p.Name] = $p.Value } }
    $all[$UserKey] = [ordered]@{ Answer = $Answer; At = (Get-Date).ToString('o') }
    [void](Set-AVDTuneState -Root $Root -Values @{ DesktopShortcut = [pscustomobject]$all })
}

function Get-AVDTuneShortcutOffer {
    <#
        What the first start shows: Ask (installed, not answered), Install (not installed: the hint to install first), None (answered).
        Mode: the mode of Get-AVDTuneInstallInfo (Installed, Unprotected, Development).
    #>
    param([string]$Root = (Get-AVDTuneRoot), [string]$UserKey = (Get-AVDTuneUserKey), [Parameter(Mandatory)][string]$Mode)
    if (Get-AVDTuneShortcutAnswer -Root $Root -UserKey $UserKey) { return 'None' }
    if ($Mode -eq 'Installed') { 'Ask' } else { 'Install' }
}

Export-ModuleMember -Function Get-AVDTuneShortcutName, Get-AVDTuneUserDesktop, Get-AVDTuneUserKey, Test-AVDTunePublicDesktop, Get-AVDTuneShortcutSpec, Set-AVDTuneLnkRunAs, Test-AVDTuneLnkRunAs,
    Get-AVDTuneDesktopShortcut, New-AVDTuneDesktopShortcut, Remove-AVDTuneDesktopShortcut, Get-AVDTuneShortcutAnswer, Set-AVDTuneShortcutAnswer, Get-AVDTuneShortcutOffer
