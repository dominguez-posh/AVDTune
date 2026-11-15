<#
    AVDTune Updates: one list for everything that can be updated on the master, and the run that updates it (docs\plans\avdtune.md, sections 3, 3c, 4).

      Windows              WUA COM API (Microsoft.Update.Session), Microsoft Update service registered (so .NET and other Microsoft products come),
                           drivers and previews off by default, KB exclude list, result code per update with an explanation, retry
      Microsoft 365 Apps   build and channel from ClickToRun\Configuration; update with OfficeC2RClient.exe /update (Updates Enabled stays FALSE in the image)
      Edge, Teams, OneDrive, Defender signatures; FSLogix is only detected here (the update comes with the FSLogix page, phase 3)
      winget / Chocolatey  every call inside the mutex Global\PackTune (and, in the transition, Global\IntuneChocolateyDeployment)
      Repair               DISM /Online /Cleanup-Image /RestoreHealth and sfc /scannow, offered after a failure, run on a click

    Every access to the machine goes through two adapters: the machine adapter of AVDTune.psm1 (registry, services, tasks) and the update adapter
    $U of this file (WUA, native tools, files, Defender, the lock). New-AVDTuneUpdateAdapter is the real one; Tests\Fakes\FakeUpdates.ps1 has the fake.
    A run needs the open write gate and runs inside the maintenance mode of AVDTune.UpdateBlock.psm1: the block is lifted for the run and put back
    in the finally block.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.UpdateBlock.psm1')

$script:MicrosoftUpdateServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'
$script:LockNames = @('Global\PackTune', 'Global\IntuneChocolateyDeployment')
$script:TransientHResults = @('0x8024402C', '0x80072EE7', '0x80072EFD', '0x80072EE2', '0x80244022', '0x80240438', '0x8024001E', '0x800705B4', '0x80248007')

#region settings

function Get-AVDTuneUpdateSettings {
    # config\updates.json: drivers and previews off by default, KB exclude list, retries, Microsoft Update on
    param([string]$Root = (Get-AVDTuneRoot))
    $s = $null
    try { $s = Read-AVDTuneJson (Join-Path $Root 'config\updates.json') } catch { }
    $kbs = @(); if ($s -and (Get-AVDTuneProp $s 'ExcludedKbs')) { $kbs = @(@($s.ExcludedKbs) | ForEach-Object { ([string]$_).ToUpperInvariant() } | Where-Object { $_ -match '^KB\d{6,8}$' } | Select-Object -Unique) }
    $retries = 1; if ($s -and $null -ne (Get-AVDTuneProp $s 'Retries')) { $retries = [Math]::Max(0, [Math]::Min(3, [int]$s.Retries)) }
    [pscustomobject]@{
        IncludeDrivers = [bool]($s -and (Get-AVDTuneProp $s 'IncludeDrivers'))
        IncludePreviews = [bool]($s -and (Get-AVDTuneProp $s 'IncludePreviews'))
        ExcludedKbs = $kbs
        Retries = $retries
        MicrosoftUpdate = $(if ($s -and $null -ne (Get-AVDTuneProp $s 'MicrosoftUpdate')) { [bool]$s.MicrosoftUpdate } else { $true })
    }
}

function ConvertTo-AVDTuneKbList([string]$Text) {
    # "KB5034441, 5034442;kb123456" -> KB numbers; anything that is not a KB number is an error (no free text goes further)
    $out = New-Object System.Collections.ArrayList
    foreach ($part in ($Text -split '[,;\s]+' | Where-Object { $_ })) {
        $p = $part.Trim().ToUpperInvariant(); if ($p -match '^\d{6,8}$') { $p = "KB$p" }
        if ($p -notmatch '^KB\d{6,8}$') { throw "'$part' is not a KB number (KB and 6 to 8 digits)." }
        if ($p -notin $out) { [void]$out.Add($p) }
    }
    @($out)
}

function Set-AVDTuneUpdateSettings {
    param([string]$Root = (Get-AVDTuneRoot), [bool]$IncludeDrivers = $false, [bool]$IncludePreviews = $false, [string[]]$ExcludedKbs = @(), [int]$Retries = 1, [bool]$MicrosoftUpdate = $true)
    $kbs = ConvertTo-AVDTuneKbList ($ExcludedKbs -join ',')
    $o = [ordered]@{ IncludeDrivers = $IncludeDrivers; IncludePreviews = $IncludePreviews; ExcludedKbs = @($kbs); Retries = [Math]::Max(0, [Math]::Min(3, $Retries)); MicrosoftUpdate = $MicrosoftUpdate }
    Write-AVDTuneFile (Join-Path $Root 'config\updates.json') ($o | ConvertTo-Json)
    Get-AVDTuneUpdateSettings $Root
}

#endregion

#region explanations

function ConvertTo-AVDTuneHResultText($Code) {
    if ($null -eq $Code -or [string]$Code -eq '') { return '' }
    '0x{0:X8}' -f ([uint32]([int64]$Code -band 0xFFFFFFFFL))
}

# Meaning and advice for the common Windows Update codes. Repair = DISM /RestoreHealth and sfc are worth a try. From the Windows Update error code
# documentation and experience; not checked against a live system (reported in the handover).
$script:WuaErrors = @{
    '0x80073712' = @{ Repair = $true; Text = 'A file that the update needs is missing or damaged in the component store.'; Fix = 'Run DISM /RestoreHealth and sfc, then try again.' }
    '0x800F081F' = @{ Repair = $true; Text = 'Windows could not find the source files for the update (component store).'; Fix = 'Run DISM /RestoreHealth (Windows Update is the source), then try again.' }
    '0x800F0831' = @{ Repair = $true; Text = 'A package that this update builds on is missing in the component store.'; Fix = 'Run DISM /RestoreHealth and sfc, install the missing earlier update, then try again.' }
    '0x80070002' = @{ Repair = $true; Text = 'A file was not found while installing.'; Fix = 'Run DISM /RestoreHealth and sfc, then try again.' }
    '0x80070003' = @{ Repair = $true; Text = 'A path was not found while installing.'; Fix = 'Run DISM /RestoreHealth and sfc, then try again.' }
    '0x8024200B' = @{ Repair = $true; Text = 'The installer of the update failed.'; Fix = 'Look at C:\Windows\Logs\CBS\CBS.log, run DISM /RestoreHealth and sfc, then try again.' }
    '0x800F0922' = @{ Repair = $false; Text = 'The installation was rolled back (servicing stack problem, too little space on the system partition, or a VPN).'; Fix = 'Check free disk space, restart the master, try again.' }
    '0x80070005' = @{ Repair = $false; Text = 'Access denied.'; Fix = 'AVDTune must run as administrator; look for a virus scanner or another installer that blocks the update.' }
    '0x80070070' = @{ Repair = $false; Text = 'Not enough disk space.'; Fix = 'Free space on C: (component cleanup comes with Cleanup and finish), then try again.' }
    '0x80070422' = @{ Repair = $false; Text = 'The Windows Update service is disabled.'; Fix = 'Set the service back to Manual (never disable it: policies block the users, see Update block). Then try again.' }
    '0x8024402C' = @{ Repair = $false; Text = 'The update service could not be reached (name could not be resolved).'; Fix = 'Check the network, DNS and the proxy of the master, then try again.' }
    '0x80072EE7' = @{ Repair = $false; Text = 'The name of the update server could not be resolved (no network).'; Fix = 'Check the network, DNS and the proxy of the master, then try again.' }
    '0x80072EFD' = @{ Repair = $false; Text = 'No connection to the update server.'; Fix = 'Check the network, firewall and proxy of the master, then try again.' }
    '0x80072EE2' = @{ Repair = $false; Text = 'The connection to the update server timed out.'; Fix = 'Check the network and the proxy, then try again.' }
    '0x80244022' = @{ Repair = $false; Text = 'The update service is busy (HTTP 503).'; Fix = 'Try again later.' }
    '0x80240438' = @{ Repair = $false; Text = 'No connection to the update service.'; Fix = 'Check the network and the proxy, then try again.' }
    '0x8024001E' = @{ Repair = $false; Text = 'The Windows Update service was stopped during the operation.'; Fix = 'Try again; restart the master if it happens again.' }
    '0x800705B4' = @{ Repair = $false; Text = 'The operation timed out.'; Fix = 'Try again.' }
    '0x80248007' = @{ Repair = $false; Text = 'The update information is missing (metadata).'; Fix = 'Try again; if it stays, reset the Windows Update components.' }
    '0x80240022' = @{ Repair = $false; Text = 'All updates of the batch failed.'; Fix = 'Look at the single updates.' }
    '0x80242016' = @{ Repair = $false; Text = 'The update is waiting for a restart of an earlier update.'; Fix = 'Restart the master, then try again.' }
    '0x80070BC9' = @{ Repair = $false; Text = 'A restart is needed before this update can install.'; Fix = 'Restart the master, then try again.' }
}
$script:WuaResultText = @{ 0 = 'not started'; 1 = 'in progress'; 2 = 'succeeded'; 3 = 'succeeded with errors'; 4 = 'failed'; 5 = 'aborted' }   # OperationResultCode of the WUA API

function Resolve-AVDTuneWuaError {
    # HResult and result code of an update -> Code (hex), Text (what happened), Fix (what to do), Repair (offer DISM/sfc), Transient (worth a retry)
    param($HResult, [int]$ResultCode = 4)
    $hex = ConvertTo-AVDTuneHResultText $HResult
    $known = $null; if ($hex) { $known = $script:WuaErrors[$hex.ToUpperInvariant().Replace('0X', '0x')] }
    if ($known) { return [pscustomobject]@{ Code = $hex; Text = $known.Text; Fix = $known.Fix; Repair = [bool]$known.Repair; Transient = ($hex -in $script:TransientHResults) } }
    $rc = $script:WuaResultText[$ResultCode]; if (-not $rc) { $rc = 'unknown' }
    $text = if ($hex -and $hex -ne '0x00000000') { "Windows Update reported $rc with the code $hex, which AVDTune does not know." } else { "Windows Update reported $rc without an error code." }
    [pscustomobject]@{ Code = $hex; Text = $text; Fix = 'Look at the Windows Update log (Get-WindowsUpdateLog) and C:\Windows\Logs\CBS\CBS.log; DISM /RestoreHealth and sfc can be tried.'; Repair = $true; Transient = $false }
}

function Resolve-AVDTuneSoftwareError {
    # winget or choco exit code -> short text; the winget codes are those of winget-cli doc/windows/package-manager/winget/returnCodes.md
    param([string]$Source, [int]$Code, [string]$Output)
    if ($Source -eq 'winget') {
        switch ($Code) {
            -1978335224 { return 'The download of the installer failed.' }
            -1978335217 { return 'The package source cannot be reached.' }
            -1978335216 { return 'The package has no installer for all users of this computer (machine scope).' }
            -1978335215 { return 'The installer does not match its hash.' }
            -1978335212 { return 'The package was not found in the source.' }
            -1978335189 { return 'No newer version applies.' }
        }
    }
    if ($Code -eq 1618) { return 'Another installation is running on this computer.' }
    if ($Output -match '(?i)Unable to connect|remote name could not be resolved|No such host') { return 'The package source cannot be reached (no network?).' }
    "$Source returned the exit code $Code."
}

#endregion

#region parsers (pure)

function ConvertFrom-AVDTuneWingetUpgrade {
    # Text table of "winget upgrade": header with Name, Id, Version, Available (and Source), a dashed line, the rows. Columns by the positions of the header.
    param([string]$Text)
    $lines = @($Text -split "`r?`n")
    $h = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*Name\s+Id\s+Version\s+Available') { $h = $i; break } }
    if ($h -lt 0) { return @() }
    $head = $lines[$h]
    $pId = $head.IndexOf('Id'); $pVer = $head.IndexOf('Version'); $pAvail = $head.IndexOf('Available'); $pSrc = $head.IndexOf('Source')
    $rows = New-Object System.Collections.ArrayList
    for ($i = $h + 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^\s*-{5,}\s*$' -or -not $l.Trim()) { if ($l.Trim()) { continue } else { break } }
        if ($l -match '^\d+\s+upgrades?\s+available' -or $l.Length -le $pAvail) { break }
        $name = $l.Substring(0, $pId).Trim()
        $id = $l.Substring($pId, $pVer - $pId).Trim()
        $ver = $l.Substring($pVer, $pAvail - $pVer).Trim()
        $availEnd = if ($pSrc -gt 0 -and $l.Length -gt $pSrc) { $pSrc } else { $l.Length }
        $avail = $l.Substring($pAvail, $availEnd - $pAvail).Trim()
        $src = if ($pSrc -gt 0 -and $l.Length -gt $pSrc) { $l.Substring($pSrc).Trim() } else { '' }
        if ($id -match '^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$') { [void]$rows.Add([pscustomobject]@{ Name = $name; Id = $id; Installed = ($ver -replace '^[<>~]\s*', ''); Available = $avail; Source = $src }) }
    }
    @($rows)
}

function ConvertFrom-AVDTuneChocoOutdated {
    # "choco outdated -r": id|installed|available|pinned
    param([string]$Text)
    $rows = New-Object System.Collections.ArrayList
    foreach ($l in ($Text -split "`r?`n")) {
        $p = $l.Trim() -split '\|'
        if ($p.Count -ge 3 -and $p[0] -match '^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$' -and $p[1] -match '^\d' -and $p[2] -match '^\d') {
            if ($p.Count -ge 4 -and $p[3] -eq 'true') { continue }
            [void]$rows.Add([pscustomobject]@{ Name = $p[0]; Id = $p[0]; Installed = $p[1]; Available = $p[2]; Source = 'chocolatey' })
        }
    }
    @($rows)
}

#endregion

#region the lock

function Invoke-AVDTuneLocked {
    # One choco or winget operation at a time: the whole block runs inside the lock. Returns @{ Ok; Error; Value }.
    param([Parameter(Mandatory)]$U, [Parameter(Mandatory)][scriptblock]$Script)
    $l = & $U.LockEnter
    if (-not $l.Ok) { return [pscustomobject]@{ Ok = $false; Error = [string]$l.Error; Value = $null } }
    try { $v = & $Script; [pscustomobject]@{ Ok = $true; Error = ''; Value = $v } }
    finally { & $U.LockExit }
}

#endregion

#region trusted tools

# Every native tool AVDTune starts elevated: who must have signed it and the original file name it must carry (VersionInfo; '.mui' is ignored).
$script:ToolTrust = @{
    'winget.exe' = 'Microsoft'; 'teamsbootstrapper.exe' = 'Microsoft'; 'OfficeC2RClient.exe' = 'Microsoft'; 'MicrosoftEdgeUpdate.exe' = 'Microsoft'
    'Dism.exe' = 'Microsoft'; 'sfc.exe' = 'Microsoft'; 'choco.exe' = 'Chocolatey'; 'FSLogixAppsSetup.exe' = 'Microsoft'; 'frx.exe' = 'Microsoft'
}

function Get-AVDTuneDnPart([string]$Dn, [string]$Key) {
    <#
        One part of a distinguished name, parsed by Windows (X500DistinguishedName), quotes removed: Get-AVDTuneDnPart 'CN=x, O="A, Inc"' 'O'
        -> 'A, Inc'. '' when the name cannot be parsed, the part is missing or appears more than once.
    #>
    if (-not $Dn) { return '' }
    try { $lines = (New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName($Dn)).Decode([System.Security.Cryptography.X509Certificates.X500DistinguishedNameFlags]::UseNewLines) -split "\r?\n" }
    catch { return '' }
    $values = @(foreach ($l in $lines) {
            $i = $l.IndexOf('=')
            if ($i -gt 0 -and $l.Substring(0, $i).Trim() -ceq $Key) {
                $v = $l.Substring($i + 1).Trim()
                if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length - 2).Replace('""', '"') }
                $v
            }
        })
    if ($values.Count -ne 1) { return '' }
    $values[0]
}

function Test-AVDTuneToolTrust {
    <#
        Pure: is this signature (from the adapter's VerifySignature: Valid, Status, Subject, Issuer, OriginalFilename) the one of the named tool?
        Microsoft: subject O and CN exactly Microsoft Corporation (or Microsoft Windows for Windows files), issued by a Microsoft code signing or
        Windows production CA. Chocolatey: subject O and CN exactly Chocolatey Software, Inc, issued by a DigiCert code signing CA.
        Returns @{ Ok; Reason }.
    #>
    param($Signature, [Parameter(Mandatory)][string]$Name)
    $leaf = Split-Path $Name -Leaf
    $publisher = $null
    foreach ($k in $script:ToolTrust.Keys) { if ($k -eq $leaf) { $publisher = $script:ToolTrust[$k] } }
    if (-not $publisher) { return @{ Ok = $false; Reason = "$leaf is not a known tool" } }
    if (-not $Signature -or -not $Signature.Valid) { return @{ Ok = $false; Reason = "$leaf has no valid signature ($(if ($Signature) { $Signature.Status } else { 'none' }))" } }
    $sO = Get-AVDTuneDnPart $Signature.Subject 'O'; $sCN = Get-AVDTuneDnPart $Signature.Subject 'CN'
    $iO = Get-AVDTuneDnPart (Get-AVDTuneProp $Signature 'Issuer') 'O'; $iCN = Get-AVDTuneDnPart (Get-AVDTuneProp $Signature 'Issuer') 'CN'
    $ok = switch ($publisher) {
        'Microsoft' { $sO -ceq 'Microsoft Corporation' -and $sCN -cin 'Microsoft Corporation', 'Microsoft Windows' -and $iO -ceq 'Microsoft Corporation' -and $iCN -cmatch '^Microsoft (Windows )?(Code Signing|Production) PCA( |$)' }
        'Chocolatey' { $sO -ceq 'Chocolatey Software, Inc' -and $sCN -ceq 'Chocolatey Software, Inc' -and $iO -ceq 'DigiCert, Inc.' -and $iCN -cmatch '^DigiCert .*Code Signing' }
    }
    if (-not $ok) { return @{ Ok = $false; Reason = "$leaf is not signed by $publisher (signer '$($Signature.Subject)', issuer '$(Get-AVDTuneProp $Signature 'Issuer')')" } }
    $orig = ([string](Get-AVDTuneProp $Signature 'OriginalFilename')) -replace '(?i)\.mui$', ''
    if ($orig -ne $leaf) { return @{ Ok = $false; Reason = "$leaf carries the original file name '$orig'" } }
    @{ Ok = $true; Reason = '' }
}

function Test-AVDTuneAdminOnlyAcl {
    <#
        Pure: only SYSTEM, Administrators and TrustedInstaller own the object and may write, delete or change its permissions. $Rules are
        @{ Sid; Allow; Rights (int); InheritOnly }. Read and execute for others is fine.
    #>
    param([string]$Owner, [object[]]$Rules)
    $admin = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    if ($Owner -notin $admin) { return $false }
    $write = 0x2 -bor 0x4 -bor 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x40000000 -bor 0x10000000   # data, append, delete child, delete, DAC, owner, generic write/all
    foreach ($r in @($Rules)) {
        if (-not $r -or -not $r.Allow -or $r.InheritOnly -or $r.Sid -in $admin) { continue }
        if (([int64]$r.Rights -band $write) -ne 0) { return $false }
    }
    $true
}

function Resolve-AVDTuneTool {
    <#
        Finds a native tool and checks it before it is started elevated: only fixed admin-only places (the adapter's FindTool or Path, no PATH),
        and the signature of the tool's publisher (Test-AVDTuneToolTrust). -Stage copies it into a private folder first and checks the copy
        (the file that runs is the file that was checked); the caller removes it with $U.Unstage. Returns @{ Path; Code (ToolMissing | BadSignature); Error; Staged }.
    #>
    param([Parameter(Mandatory)]$U, [Parameter(Mandatory)][string]$Name, [string]$PathName, [string]$ExtraFolder, [string]$Root, [switch]$Stage)
    $path = if ($PathName) { & $U.Path $PathName } else { & $U.FindTool $Name $ExtraFolder }
    if (-not $path -or -not (& $U.Exists $path)) { return @{ Path = $null; Code = 'ToolMissing'; Error = "$Name was not found."; Staged = $false } }
    $staged = $false
    if ($Stage) { $path = & $U.Stage $path $Root; $staged = $true }
    $trust = Test-AVDTuneToolTrust -Signature (& $U.VerifySignature $path) -Name $Name
    if (-not $trust.Ok) {
        if ($staged) { & $U.Unstage $path }
        return @{ Path = $null; Code = 'BadSignature'; Error = "$($trust.Reason): it is not started."; Staged = $false }
    }
    @{ Path = $path; Code = ''; Error = ''; Staged = $staged }
}

#endregion

#region the list

function New-AVDTuneUpdateItem {
    param([string]$Id, [string]$Group, [string]$Title, [string]$Installed = '', [string]$Available = '', [string]$Status, [string]$Detail = '', [string]$Kb = '', [bool]$Reboot = $false)
    # Status: Available, Check (known only when the update runs), UpToDate, Excluded, DetectOnly, Missing, Error
    [pscustomobject]@{ Id = $Id; Group = $Group; Title = $Title; Installed = $Installed; Available = $Available; Status = $Status; Detail = $Detail; Kb = $Kb; Reboot = $Reboot; Selectable = ($Status -in 'Available', 'Check') }
}

function Test-AVDTunePreviewTitle([string]$Title) { $Title -match '(?i)\bpreview\b' }

function Get-AVDTuneUpdateList {
    <#
        Reads what can be updated. Read only (the Microsoft Update registration and every install happen in the run). Returns
        @{ Items; Notes } with Items sorted by group. A source that cannot be read (no network, lock held) is one item with Status Error and the
        explanation, never an exception.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$U, [string]$Root = (Get-AVDTuneRoot), $Settings, [scriptblock]$Progress)
    if (-not $Settings) { $Settings = Get-AVDTuneUpdateSettings $Root }
    $items = New-Object System.Collections.ArrayList
    $notes = New-Object System.Collections.ArrayList
    function Say([string]$t) { if ($Progress) { & $Progress $t } }

    # ---- Windows (WUA)
    Say 'Searching Windows Update ...'
    $mu = [bool](& $U.WuaMicrosoftUpdateRegistered)
    if (-not $mu) { [void]$notes.Add($(if ($Settings.MicrosoftUpdate) { 'Microsoft Update is not registered yet: .NET and other Microsoft products are not offered. It is registered at the start of the next run.' } else { 'Microsoft Update is switched off in the settings: .NET and other Microsoft products are not offered.' })) }
    $search = & $U.WuaSearch ($mu -and $Settings.MicrosoftUpdate)
    if (-not $search.Ok) {
        $e = Resolve-AVDTuneWuaError $search.HResult 4
        [void]$items.Add((New-AVDTuneUpdateItem -Id 'windows:error' -Group 'Windows' -Title 'Windows Update' -Status 'Error' -Detail "Could not search: $($e.Text) $($e.Fix)$(if ($e.Code) { " ($($e.Code))" })"))
    }
    else {
        $count = 0
        foreach ($up in @($search.Updates)) {
            $count++
            $kbs = @($up.Kbs | ForEach-Object { "KB$($_ -replace '^KB', '')" })
            $status = 'Available'; $detail = ''
            $excluded = @($kbs | Where-Object { $_ -in $Settings.ExcludedKbs })
            if ($excluded.Count -gt 0) { $status = 'Excluded'; $detail = "On the exclude list ($($excluded -join ', '))." }
            elseif ($up.IsDriver -and -not $Settings.IncludeDrivers) { $status = 'Excluded'; $detail = 'Driver: drivers are off (setting).' }
            elseif ((Test-AVDTunePreviewTitle $up.Title) -and -not $Settings.IncludePreviews) { $status = 'Excluded'; $detail = 'Preview: previews are off (setting).' }
            elseif ($up.SizeMB) { $detail = "$([Math]::Round([double]$up.SizeMB, 1)) MB" }
            [void]$items.Add((New-AVDTuneUpdateItem -Id "windows:$($up.Id)" -Group 'Windows' -Title ([string]$up.Title) -Available 'new' -Status $status -Detail $detail -Kb ($kbs -join ', ') -Reboot ([bool]$up.Reboot)))
        }
        if ($count -eq 0) { [void]$items.Add((New-AVDTuneUpdateItem -Id 'windows:none' -Group 'Windows' -Title 'Windows' -Status 'UpToDate' -Detail 'No update is offered.')) }
    }

    # ---- Microsoft 365 Apps
    $office = Get-AVDTuneOfficeInfo $Machine
    if ($office.Installed) {
        $d = "$($office.Channel). The newest build is known when the update runs (OfficeC2RClient /update)."
        if ($office.UpdatesEnabled -eq $true) { $d += ' Updates Enabled is TRUE: it must be FALSE in the image.' }
        [void]$items.Add((New-AVDTuneUpdateItem -Id 'm365' -Group 'Microsoft 365 Apps' -Title 'Microsoft 365 Apps' -Installed $office.Build -Status 'Check' -Detail $d))
    }
    else { [void]$items.Add((New-AVDTuneUpdateItem -Id 'm365' -Group 'Microsoft 365 Apps' -Title 'Microsoft 365 Apps' -Status 'Missing' -Detail 'Not installed (Office page, phase 6).')) }

    # ---- Edge, Teams, OneDrive
    $edge = [string](& $Machine.RegGet 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' 'pv')
    if ($edge) { [void]$items.Add((New-AVDTuneUpdateItem -Id 'edge' -Group 'Edge' -Title 'Microsoft Edge' -Installed $edge -Status 'Check' -Detail 'Updated by Edge Update (the update policies and tasks are lifted in maintenance mode).')) }
    else { [void]$items.Add((New-AVDTuneUpdateItem -Id 'edge' -Group 'Edge' -Title 'Microsoft Edge' -Status 'Missing' -Detail 'Not found.')) }
    $teams = [string](& $U.AppxVersion 'MSTeams')
    if ($teams) { [void]$items.Add((New-AVDTuneUpdateItem -Id 'teams' -Group 'Teams' -Title 'Microsoft Teams (new)' -Installed $teams -Status 'Check' -Detail 'Update with teamsbootstrapper.exe -p (Microsoft-signed file in the AVDTune tools folder).')) }
    else { [void]$items.Add((New-AVDTuneUpdateItem -Id 'teams' -Group 'Teams' -Title 'Microsoft Teams (new)' -Status 'Missing' -Detail 'Not installed (VDI components, phase 6).')) }
    $od = [string](& $U.FileVersion (& $U.Path 'OneDrive'))
    if ($od) { [void]$items.Add((New-AVDTuneUpdateItem -Id 'onedrive' -Group 'OneDrive' -Title 'OneDrive (per machine)' -Installed $od -Status 'Check' -Detail 'Updated with winget (Microsoft.OneDrive, machine scope).')) }
    else { [void]$items.Add((New-AVDTuneUpdateItem -Id 'onedrive' -Group 'OneDrive' -Title 'OneDrive (per machine)' -Status 'Missing' -Detail 'Not installed per machine.')) }

    # ---- FSLogix: detect only
    $fs = [string](& $Machine.RegGet 'HKLM:\SOFTWARE\FSLogix\Apps' 'InstallVersion')
    if ($fs) { [void]$items.Add((New-AVDTuneUpdateItem -Id 'fslogix' -Group 'FSLogix' -Title 'FSLogix Apps' -Installed $fs -Status 'DetectOnly' -Detail 'Only detected here. The update comes with the FSLogix page (phase 3).')) }
    else { [void]$items.Add((New-AVDTuneUpdateItem -Id 'fslogix' -Group 'FSLogix' -Title 'FSLogix Apps' -Status 'Missing' -Detail 'Not installed.')) }

    # ---- Defender signatures
    $def = & $U.DefenderStatus
    if ($def -and $def.Version) {
        $age = if ($def.LastUpdated) { [Math]::Round(((& $Machine.Now) - [datetime]$def.LastUpdated).TotalHours, 0) } else { $null }
        $st = if ($null -ne $age -and $age -le 24) { 'UpToDate' } else { 'Check' }
        $dd = if ($null -ne $age) { "Signatures are $age hour(s) old." } else { 'Age of the signatures unknown.' }
        [void]$items.Add((New-AVDTuneUpdateItem -Id 'defender' -Group 'Defender' -Title 'Defender signatures' -Installed ([string]$def.Version) -Status $st -Detail $dd))
    }
    else { [void]$items.Add((New-AVDTuneUpdateItem -Id 'defender' -Group 'Defender' -Title 'Defender signatures' -Status 'Missing' -Detail 'Defender status is not available.')) }

    # ---- winget and Chocolatey (inside the lock)
    Say 'Reading winget and Chocolatey ...'
    $tw = Resolve-AVDTuneTool -U $U -Name 'winget.exe'; $winget = $tw.Path
    $tc = Resolve-AVDTuneTool -U $U -Name 'choco.exe'; $choco = $tc.Path
    if (-not $winget) { [void]$notes.Add($(if ($tw.Code -eq 'BadSignature') { "winget is not used: $($tw.Error)" } else { 'winget was not found: no winget apps are listed.' })) }
    if (-not $choco) { [void]$notes.Add($(if ($tc.Code -eq 'BadSignature') { "Chocolatey is not used: $($tc.Error)" } else { 'Chocolatey was not found: no Chocolatey apps are listed.' })) }
    if ($winget -or $choco) {
        $got = Invoke-AVDTuneLocked -U $U -Script {
            $r = @{}
            if ($winget) { $r.Winget = & $U.Run $winget @('upgrade', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity') 300 }
            if ($choco) { $r.Choco = & $U.Run $choco @('outdated', '-r', '--ignore-unfound') 300 }
            $r
        }
        if (-not $got.Ok) { [void]$items.Add((New-AVDTuneUpdateItem -Id 'software:error' -Group 'Software' -Title 'winget and Chocolatey' -Status 'Error' -Detail "Not read: $($got.Error)")) }
        else {
            if ($winget) {
                $w = $got.Value.Winget
                if ($w.ExitCode -ne 0 -and $w.ExitCode -ne -1978335189) { [void]$items.Add((New-AVDTuneUpdateItem -Id 'software:winget-error' -Group 'Software' -Title 'winget' -Status 'Error' -Detail (Resolve-AVDTuneSoftwareError 'winget' $w.ExitCode $w.Output))) }
                else { foreach ($p in ConvertFrom-AVDTuneWingetUpgrade $w.Output) { if ($p.Source -and $p.Source -ne 'winget') { continue }; [void]$items.Add((New-AVDTuneUpdateItem -Id "winget:$($p.Id)" -Group 'Software' -Title "$($p.Name) (winget)" -Installed $p.Installed -Available $p.Available -Status 'Available')) } }
            }
            if ($choco) {
                $c = $got.Value.Choco
                if ($c.ExitCode -ne 0) { [void]$items.Add((New-AVDTuneUpdateItem -Id 'software:choco-error' -Group 'Software' -Title 'Chocolatey' -Status 'Error' -Detail (Resolve-AVDTuneSoftwareError 'choco' $c.ExitCode $c.Output))) }
                else { foreach ($p in ConvertFrom-AVDTuneChocoOutdated $c.Output) { [void]$items.Add((New-AVDTuneUpdateItem -Id "choco:$($p.Id)" -Group 'Software' -Title "$($p.Name) (Chocolatey)" -Installed $p.Installed -Available $p.Available -Status 'Available')) } }
            }
        }
    }
    [pscustomobject]@{ Items = @($items); Notes = @($notes); At = (& $Machine.Now).ToString('o') }
}

#endregion

#region the run

function New-AVDTuneUpdateResult {
    # Same shape as a step result (so the protocol hook works) plus Group, Code, Attempts, Fix, Repair
    param($Item, [string]$Status, [string]$Message = '', [string]$Code = '', [int]$Attempts = 1, [string]$Fix = '', [bool]$Repair = $false, [bool]$Reboot = $false, [string]$After = '', $Machine)
    [pscustomobject][ordered]@{
        Id = [string]$Item.Id; Section = 'Updates'; Title = [string]$Item.Title; Mode = 'Apply'; Status = $Status; Before = [string]$Item.Installed; After = $After; Message = $Message
        Reboot = $Reboot; WhatIf = $false; At = (& $Machine.Now).ToString('o'); Group = [string]$Item.Group; Code = $Code; Attempts = $Attempts; Fix = $Fix; Repair = $Repair; Kb = [string]$Item.Kb
    }
}

function Update-AVDTuneWindowsItem {
    param($Machine, $U, $Item, $Settings, [scriptblock]$Progress)
    $id = $Item.Id -replace '^windows:', ''
    $attempt = 0; $last = $null; $explain = $null
    $max = 1 + $Settings.Retries
    while ($attempt -lt $max) {
        $attempt++
        if ($Progress) { & $Progress "Installing $($Item.Title)$(if ($attempt -gt 1) { " (attempt $attempt)" }) ..." }
        $last = & $U.WuaInstall $id
        if ($last.Ok -and $last.ResultCode -in 2, 3) { break }
        $explain = Resolve-AVDTuneWuaError $last.HResult ([int]$last.ResultCode)
        if ($attempt -lt $max) { & $U.Sleep 5 }
    }
    if ($last.Ok -and $last.ResultCode -in 2, 3) {
        $msg = if ($last.ResultCode -eq 3) { 'Installed, but Windows Update reported errors.' } else { 'Installed.' }
        if ($last.RebootRequired) { $msg += ' A restart is needed.' }
        return New-AVDTuneUpdateResult -Machine $Machine -Item $Item -Status 'Changed' -Message $msg -Attempts $attempt -Reboot ([bool]$last.RebootRequired) -After 'installed'
    }
    New-AVDTuneUpdateResult -Machine $Machine -Item $Item -Status 'Failed' -Message "$($explain.Text) $($explain.Fix)" -Code $explain.Code -Attempts $attempt -Fix $explain.Fix -Repair $explain.Repair
}

function Update-AVDTuneNativeItem {
    <# m365, edge, teams, onedrive, defender, winget:*, choco:* #>
    param($Machine, $U, $Item, $Root, $Settings, [scriptblock]$Progress)
    $say = { param($t) if ($Progress) { & $Progress $t } }
    $new = { param($status, $msg, $code, $after, $reboot, $fix) New-AVDTuneUpdateResult -Machine $Machine -Item $Item -Status $status -Message $msg -Code ([string]$code) -After ([string]$after) -Reboot ([bool]$reboot) -Fix ([string]$fix) }
    $kind = ($Item.Id -split ':')[0]
    & $say "Updating $($Item.Title) ..."
    switch ($kind) {
        'm365' {
            $before = [string](Get-AVDTuneOfficeInfo $Machine).Build
            $t = Resolve-AVDTuneTool -U $U -Name 'OfficeC2RClient.exe' -PathName 'C2R'
            if (-not $t.Path) { return & $new 'Failed' $t.Error $t.Code '' $false 'Repair or reinstall Microsoft 365 Apps (Office page).' }
            $r = & $U.Run $t.Path @('/update', 'user', 'displaylevel=false', 'forceappshutdown=true') 600
            if ($r.ExitCode -ne 0) { return & $new 'Failed' "OfficeC2RClient returned $($r.ExitCode). $($r.Output)".Trim() $r.ExitCode '' $false 'Check that Office is installed and the CDN is reachable (Office page).' }
            # the update runs in the background service: wait for a new build, up to the limit
            $tries = 0
            do { & $U.Sleep 20; $now = [string](Get-AVDTuneOfficeInfo $Machine).Build; $tries++ } while ($now -eq $before -and $tries -lt 30)
            if ($now -ne $before) { return & $new 'Changed' "Updated from $before to $now." '' $now $false '' }
            return & $new 'Unchanged' 'No newer build appeared within 10 minutes (up to date, or the update is still running in the background).' '' $before $false ''
        }
        'edge' {
            $key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'
            $before = [string](& $Machine.RegGet $key 'pv')
            $t = Resolve-AVDTuneTool -U $U -Name 'MicrosoftEdgeUpdate.exe' -PathName 'EdgeUpdate'
            if (-not $t.Path) { return & $new 'Failed' $t.Error $t.Code '' $false 'Repair Microsoft Edge (Software page or the Edge installer).' }
            $r = & $U.Run $t.Path @('/ua', '/installsource', 'scheduler') 600
            if ($r.ExitCode -ne 0) { return & $new 'Failed' "Edge Update returned $($r.ExitCode). $($r.Output)".Trim() $r.ExitCode '' $false 'Check that the Edge update policies and tasks are lifted (maintenance mode) and the network is reachable.' }
            $tries = 0
            do { & $U.Sleep 10; $now = [string](& $Machine.RegGet $key 'pv'); $tries++ } while ($now -eq $before -and $tries -lt 12)
            if ($now -ne $before) { return & $new 'Changed' "Updated from $before to $now." '' $now $false '' }
            return & $new 'Unchanged' 'No newer version appeared (up to date).' '' $before $false ''
        }
        'teams' {
            # only from config\tools; it runs as a copy in a private folder that is checked right before it starts (no swap between check and start)
            $tools = Join-Path $Root 'config\tools'
            if (-not (& $U.FindTool 'teamsbootstrapper.exe' $tools)) { return & $new 'Failed' 'teamsbootstrapper.exe was not found.' 'ToolMissing' '' $false "Download it from Microsoft (Teams bulk install page) into ${tools}; AVDTune checks the signature before it runs it." }
            $t = Resolve-AVDTuneTool -U $U -Name 'teamsbootstrapper.exe' -ExtraFolder $tools -Root $Root -Stage
            if (-not $t.Path) { return & $new 'Failed' "teamsbootstrapper.exe is not signed by Microsoft Corporation ($($t.Error))" $t.Code '' $false 'Download the file again from Microsoft.' }
            $before = [string](& $U.AppxVersion 'MSTeams')
            try { $r = & $U.Run $t.Path @('-p') 900 }
            finally { & $U.Unstage $t.Path }
            if ($r.ExitCode -ne 0) { return & $new 'Failed' "teamsbootstrapper returned $($r.ExitCode). $($r.Output)".Trim() $r.ExitCode '' $false 'See the HRESULT list in the Teams bulk install article.' }
            $now = [string](& $U.AppxVersion 'MSTeams')
            if ($now -ne $before) { return & $new 'Changed' "Updated from $before to $now." '' $now $false '' }
            return & $new 'Unchanged' 'Teams is up to date.' '' $before $false ''
        }
        'defender' {
            $before = [string](& $U.DefenderStatus).Version
            $r = & $U.DefenderUpdate
            if (-not $r.Ok) { return & $new 'Failed' "Signature update failed: $($r.Error)" '' '' $false 'Check the network and the Defender service.' }
            $now = [string](& $U.DefenderStatus).Version
            if ($now -ne $before) { return & $new 'Changed' "Signatures updated from $before to $now." '' $now $false '' }
            return & $new 'Unchanged' 'Signatures are up to date.' '' $before $false ''
        }
        default {
            # onedrive (winget), winget:<id>, choco:<id>: inside the lock
            $source = $kind; $pkg = ''
            if ($kind -eq 'onedrive') { $source = 'winget'; $pkg = 'Microsoft.OneDrive' } else { $pkg = ($Item.Id -split ':', 2)[1] }
            if ($pkg -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$') { return & $new 'Failed' 'The package id is not valid.' 'BadId' '' $false '' }
            $t = Resolve-AVDTuneTool -U $U -Name $(if ($source -eq 'winget') { 'winget.exe' } else { 'choco.exe' })
            if (-not $t.Path) { return & $new 'Failed' $(if ($t.Code -eq 'ToolMissing') { "$source was not found." } else { $t.Error }) $t.Code '' $false '' }
            $tool = $t.Path
            $cmdArgs = if ($source -eq 'winget') { @('upgrade', '--id', $pkg, '--exact', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') + $(if ($kind -eq 'onedrive') { @('--scope', 'machine') } else { @() }) } else { @('upgrade', $pkg, '-y', '--no-progress') }
            $got = Invoke-AVDTuneLocked -U $U -Script { & $U.Run $tool $cmdArgs 3600 }
            if (-not $got.Ok) { return & $new 'Failed' "Not started: $($got.Error)" 'Lock' '' $false 'Wait until the other winget or Chocolatey operation is done, then try again.' }
            $r = $got.Value
            if ($r.ExitCode -in 0, 3010, 1641) { return & $new 'Changed' $(if ($r.ExitCode -eq 0) { 'Updated.' } else { 'Updated, a restart is needed.' }) '' 'updated' ($r.ExitCode -ne 0) '' }
            if ($source -eq 'winget' -and $r.ExitCode -eq -1978335189) { return & $new 'Unchanged' 'No newer version applies.' $r.ExitCode '' $false '' }
            return & $new 'Failed' (Resolve-AVDTuneSoftwareError $source $r.ExitCode $r.Output) $r.ExitCode '' $false ''
        }
    }
}

function Invoke-AVDTuneUpdateRun {
    <#
        Updates the given list items (Get-AVDTuneUpdateList). Needs the open write gate. Runs in maintenance mode: the update block is lifted for the run
        and put back in the finally block (state.json holds before and after, so a crash is found at the next start). One result per item, with the
        code and an explanation; Windows updates are retried. A run record (Plan 'Updates'), a change log entry per updated item and LastUpdate in the
        state are written even when the restore of the block fails (that is thrown afterwards).
        -WhatIf lists what would be updated and changes nothing (no maintenance mode).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$U, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][object[]]$Items,
        $Settings, [string]$User, [string]$SnapshotId, [scriptblock]$Progress, [switch]$WhatIf
    )
    if (-not $Settings) { $Settings = Get-AVDTuneUpdateSettings $Root }
    $selected = @($Items | Where-Object { $_ -and $_.Selectable })
    if ($WhatIf) { return [pscustomobject]@{ WhatIf = $true; Results = @($selected | ForEach-Object { New-AVDTuneUpdateResult -Machine $Machine -Item $_ -Status 'WhatIf' -Message 'Would update.' }); Run = $null; RepairOffered = $false; Reboot = $false } }
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot of today is confirmed on the Overview.' }
    if ($selected.Count -eq 0) { return [pscustomobject]@{ WhatIf = $false; Results = @(); Run = $null; RepairOffered = $false; Reboot = $false } }
    $started = & $Machine.Now
    # LastChange for the snapshot gate before the first item (also when the block was already off and the maintenance mode lifts nothing)
    [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = $started.ToString('o') })
    $results = New-Object System.Collections.ArrayList
    $maintError = $null
    try {
        [void](Invoke-AVDTuneMaintenance -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -Script {
                param($ctx)
                if ($Settings.MicrosoftUpdate -and @($selected | Where-Object { $_.Id -like 'windows:*' }).Count -gt 0 -and -not [bool](& $U.WuaMicrosoftUpdateRegistered)) {
                    if ($Progress) { & $Progress 'Registering Microsoft Update (.NET and other Microsoft products) ...' }
                    $reg = & $U.WuaRegisterMicrosoftUpdate
                    if (-not $reg.Ok) { [void]$results.Add((New-AVDTuneUpdateResult -Machine $Machine -Item ([pscustomobject]@{ Id = 'windows:microsoft-update'; Title = 'Register Microsoft Update'; Group = 'Windows'; Installed = ''; Kb = '' }) -Status 'Failed' -Message "Microsoft Update could not be registered: $($reg.Error)" -Fix 'Check the network. Windows updates are still installed; .NET and other Microsoft products are not offered.')) }
                    else { [void]$results.Add((New-AVDTuneUpdateResult -Machine $Machine -Item ([pscustomobject]@{ Id = 'windows:microsoft-update'; Title = 'Register Microsoft Update'; Group = 'Windows'; Installed = ''; Kb = '' }) -Status 'Changed' -Message 'Microsoft Update service registered.' -After 'registered')) }
                }
                foreach ($item in $selected) {
                    try {
                        if ($item.Id -like 'windows:*') { [void]$results.Add((Update-AVDTuneWindowsItem -Machine $Machine -U $U -Item $item -Settings $Settings -Progress $Progress)) }
                        else { [void]$results.Add((Update-AVDTuneNativeItem -Machine $Machine -U $U -Item $item -Root $Root -Settings $Settings -Progress $Progress)) }
                    }
                    catch { [void]$results.Add((New-AVDTuneUpdateResult -Machine $Machine -Item $item -Status 'Failed' -Message "Unexpected error: $($_.Exception.Message)" -Code 'Exception')) }
                }
            })
    }
    catch { $maintError = $_ }
    $state = Get-AVDTuneState $Root
    $run = [pscustomobject][ordered]@{
        Id = $null; Plan = 'Updates'; Started = $started.ToString('o'); Ended = (& $Machine.Now).ToString('o'); User = $User; SnapshotId = $SnapshotId; WhatIf = $false
        ImageVersion = $state.ImageVersion; Reboot = [bool](@($results | Where-Object { $_.Reboot }).Count); Results = @($results)
    }
    [void](Add-AVDTuneRun -Root $Root -Run $run)
    $changed = @($results | Where-Object { $_.Status -eq 'Changed' })
    if ($changed.Count -gt 0) { [void](Set-AVDTuneState -Root $Root -Values @{ LastUpdate = $started.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) }) }
    # LastChange for the snapshot gate: an item that changed or failed (a failed install can leave changes behind)
    if (@($results | Where-Object { $_.Status -in 'Changed', 'Failed' }).Count -gt 0) { [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = (& $Machine.Now).ToString('o') }) }
    if ($state.ImageVersion) {
        foreach ($r in $results) {
            if ($r.Status -notin 'Changed', 'Failed') { continue }
            $cat = switch ($r.Group) { 'Windows' { 'Windows' } 'Microsoft 365 Apps' { 'Office' } 'Software' { 'Software' } default { 'Software' } }
            $text = if ($r.Status -eq 'Changed') { "$($r.Title): updated$(if ($r.Kb) { " ($($r.Kb))" })$(if ($r.Message) { ' - ' + $r.Message })" } else { "$($r.Title): update FAILED$(if ($r.Code) { " ($($r.Code))" }) - $($r.Message)" }
            [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category $cat -Component ([string]$r.Group) -ChangeType $(if ($r.Status -eq 'Changed') { 'Updated' } else { 'Note' }) -Text $text -User $User -SnapshotId $SnapshotId -RunId $run.Id -Source Step)
        }
    }
    $summary = [pscustomobject]@{
        WhatIf = $false; Results = @($results); Run = $run; Reboot = $run.Reboot
        RepairOffered = [bool](@($results | Where-Object { $_.Status -eq 'Failed' -and $_.Repair }).Count)
    }
    if ($maintError) { throw $maintError }
    $summary
}

#endregion

#region repair and history

function Invoke-AVDTuneRepair {
    <# DISM /RestoreHealth or sfc /scannow, on a click after a failed update. Needs the open write gate. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$U, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][ValidateSet('Dism', 'Sfc')][string]$Kind, [string]$User, [string]$SnapshotId, [scriptblock]$Progress)
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot of today is confirmed on the Overview.' }
    $title = if ($Kind -eq 'Dism') { 'DISM /Online /Cleanup-Image /RestoreHealth' } else { 'sfc /scannow' }
    if ($Progress) { & $Progress "Running $title (this takes a while) ..." }
    $started = & $Machine.Now
    $t = Resolve-AVDTuneTool -U $U -Name $(if ($Kind -eq 'Dism') { 'Dism.exe' } else { 'sfc.exe' }) -PathName $Kind
    # LastChange for the snapshot gate before the repair starts (DISM and sfc change system files, also when they end with an error)
    if ($t.Path) { [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = $started.ToString('o') }) }
    $r = if (-not $t.Path) { [pscustomobject]@{ ExitCode = -1; Output = $t.Error } } elseif ($Kind -eq 'Dism') { & $U.Run $t.Path @('/Online', '/Cleanup-Image', '/RestoreHealth') 7200 } else { & $U.Run $t.Path @('/scannow') 7200 }
    $ok = ($r.ExitCode -eq 0)
    $msg = if ($ok) { 'Finished without errors.' } else { "Exit code $($r.ExitCode). $(([string]$r.Output).Trim() -replace '\s+', ' ')" }
    if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 297) + '...' }
    $result = [pscustomobject][ordered]@{
        Id = "repair.$($Kind.ToLower())"; Section = 'Updates'; Title = $title; Mode = 'Apply'; Status = $(if ($ok) { 'Changed' } else { 'Failed' }); Before = ''; After = ''; Message = $msg
        Reboot = $false; WhatIf = $false; At = $started.ToString('o'); Group = 'Windows'; Code = [string]$r.ExitCode; Attempts = 1; Fix = ''; Repair = $false; Kb = ''
    }
    $state = Get-AVDTuneState $Root
    $run = [pscustomobject][ordered]@{
        Id = $null; Plan = 'Updates repair'; Started = $started.ToString('o'); Ended = (& $Machine.Now).ToString('o'); User = $User; SnapshotId = $SnapshotId; WhatIf = $false
        ImageVersion = $state.ImageVersion; Reboot = $false; Results = @($result)
    }
    [void](Add-AVDTuneRun -Root $Root -Run $run)
    if ($state.ImageVersion) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'Windows' -Component 'Repair' -ChangeType Note -Text "${title}: $(if ($ok) { 'finished without errors' } else { 'FAILED (exit code ' + $r.ExitCode + ')' })" -User $User -SnapshotId $SnapshotId -RunId $run.Id -Source Step) }
    $result
}

function Get-AVDTuneUpdateHistory {
    # The results of all update runs and repairs, newest first
    param([string]$Root = (Get-AVDTuneRoot), [int]$Last = 50)
    $rows = New-Object System.Collections.ArrayList
    foreach ($run in @(Get-AVDTuneRun -Root $Root)) {
        if (-not $run -or [string](Get-AVDTuneProp $run 'Plan') -notlike 'Updates*') { continue }
        foreach ($r in @($run.Results)) {
            if (-not $r) { continue }
            [void]$rows.Add([pscustomobject]@{ At = [string]$r.At; Group = [string](Get-AVDTuneProp $r 'Group'); Title = [string]$r.Title; Status = [string]$r.Status; Code = [string](Get-AVDTuneProp $r 'Code'); Message = [string]$r.Message; RunId = [string]$run.Id })
        }
    }
    @($rows | Sort-Object { [datetime]$_.At } -Descending | Select-Object -First $Last)
}

#endregion

#region the real adapter

function Get-AVDTuneSystemFolder {
    # Fixed system folders from Windows itself, never from environment variables (a user can set those in HKCU\Environment)
    param([Parameter(Mandatory)][ValidateSet('Windows', 'System', 'ProgramFiles', 'ProgramFilesX86', 'CommonProgramFiles', 'ProgramData')][string]$Name)
    $special = switch ($Name) {
        'Windows' { 'Windows' } 'System' { 'System' } 'ProgramFiles' { 'ProgramFiles' } 'ProgramFilesX86' { 'ProgramFilesX86' }
        'CommonProgramFiles' { 'CommonProgramFiles' } 'ProgramData' { 'CommonApplicationData' }
    }
    $path = [Environment]::GetFolderPath([Environment+SpecialFolder]$special)
    if (-not $path) { throw "The system folder $Name is not known." }
    $path
}

function Get-AVDTuneChocolateyRoot {
    # The machine value of ChocolateyInstall (HKLM, admins only), never the process environment; otherwise the default under ProgramData
    $v = $null
    try { $v = [string](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name ChocolateyInstall -ErrorAction Stop).ChocolateyInstall } catch { }
    if ($v -and $v -notmatch '%' -and [IO.Path]::IsPathRooted($v)) { return $v.TrimEnd('\') }
    Join-Path (Get-AVDTuneSystemFolder ProgramData) 'chocolatey'
}

function Select-AVDTuneNewestPackageFolder {
    # Pure: the folder name of the newest package version, by [version] (Microsoft.DesktopAppInstaller_1.29.380.0_x64__8wekyb3d8bbwe), not by text
    param([string[]]$Names)
    $best = $null; $bestVersion = $null
    foreach ($n in @($Names)) {
        $parts = ([string]$n) -split '_'
        if ($parts.Count -lt 2) { continue }
        $v = $null
        if (-not [version]::TryParse($parts[1], [ref]$v)) { continue }
        if (-not $bestVersion -or $v -gt $bestVersion) { $best = $n; $bestVersion = $v }
    }
    $best
}

function Test-AVDTuneAdminOnlyPath {
    <#
        Reads the permissions of $Path and of every folder above it up to (not including) $Base: each must be owned and writable only by
        SYSTEM, Administrators or TrustedInstaller (Test-AVDTuneAdminOnlyAcl). Without $Base only the file is checked. Unreadable = not admin-only.
    #>
    param([Parameter(Mandatory)][string]$Path, [string]$Base)
    $stop = if ($Base) { [IO.Path]::GetFullPath($Base).TrimEnd('\') } else { $null }
    $item = [IO.Path]::GetFullPath($Path)
    while ($item) {
        if ($stop -and $item.TrimEnd('\') -ieq $stop) { break }
        try { $acl = Get-Acl -LiteralPath $item -ErrorAction Stop } catch { return $false }
        $rules = @(foreach ($r in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
                @{ Sid = $r.IdentityReference.Value; Allow = ($r.AccessControlType -eq 'Allow'); Rights = [int64]$r.FileSystemRights.value__; InheritOnly = (($r.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) }
            })
        $owner = ''; try { $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value } catch { }
        if (-not (Test-AVDTuneAdminOnlyAcl -Owner $owner -Rules $rules)) { return $false }
        if (-not $stop) { break }
        $parent = [IO.Path]::GetDirectoryName($item)
        if (-not $parent -or $parent -eq $item) { return $false }   # reached the root without meeting $Base
        $item = $parent
    }
    $true
}

function Remove-AVDTuneStageDir {
    <#
        Removes one staging folder: its plain files, then the folder. Links are removed as links, never followed; a file that is still in use
        (the tool has just ended) is tried again for a few seconds. Returns $true when the folder is gone.
    #>
    param([Parameter(Mandatory)][string]$Dir, [int]$Tries = 15)
    $d = New-Object IO.DirectoryInfo $Dir
    for ($i = 0; $i -lt $Tries; $i++) {
        $d.Refresh()
        if (-not $d.Exists) { return $true }
        try {
            if (($d.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $d.Delete(); return $true }   # the link only
            foreach ($f in $d.GetFileSystemInfos()) {
                if ($f -is [IO.DirectoryInfo]) { if (($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $f.Delete() } }   # a link inside: the link only
                else { $f.Attributes = [IO.FileAttributes]::Normal; $f.Delete() }
            }
            $d.Delete($false)
            return $true
        }
        catch { Start-Sleep -Milliseconds 200 }
    }
    $d.Refresh()
    -not $d.Exists
}

function Clear-AVDTuneStageFolder {
    # At the start: staging folders left behind in <root>\temp (a crash during a Teams update) are removed. Returns the number removed.
    param([Parameter(Mandatory)][string]$Root)
    $temp = New-Object IO.DirectoryInfo (Join-Path $Root 'temp')
    if (-not $temp.Exists) { return 0 }
    if (($temp.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $temp.Delete(); return 0 }
    $n = 0
    foreach ($c in $temp.GetDirectories()) { if ($c.Name -match '^[0-9a-f]{32}$' -and (Remove-AVDTuneStageDir -Dir $c.FullName -Tries 3)) { $n++ } }
    $n
}

function Initialize-AVDTuneProcessTree {
    # A job object around a started tool, so a timeout ends the whole tree (installers started by winget or choco), not only the tool
    if ('AVDTune.ProcessTree' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace AVDTune {
    public static class ProcessTree {
        [StructLayout(LayoutKind.Sequential)]
        struct BasicAccounting { public long TotalUserTime, TotalKernelTime, PeriodUserTime, PeriodKernelTime; public uint PageFaults, TotalProcesses, ActiveProcesses, TerminatedProcesses; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateJobObject(IntPtr job, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(IntPtr job, int infoClass, out BasicAccounting info, int length, IntPtr returned);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
        public static IntPtr Create() { IntPtr j = CreateJobObject(IntPtr.Zero, null); if (j == IntPtr.Zero) throw new Win32Exception(); return j; }
        public static void Assign(IntPtr job, IntPtr process) { if (!AssignProcessToJobObject(job, process)) throw new Win32Exception(); }
        public static int Active(IntPtr job) { BasicAccounting i; if (!QueryInformationJobObject(job, 1, out i, Marshal.SizeOf(typeof(BasicAccounting)), IntPtr.Zero)) throw new Win32Exception(); return (int)i.ActiveProcesses; }
        public static void Terminate(IntPtr job) { TerminateJobObject(job, 0xFFFFFFFF); }
        public static void Close(IntPtr job) { CloseHandle(job); }
    }
}
"@
}

function New-AVDTuneUpdateAdapter {
    <#
        The real update adapter. Reads work everywhere; WuaRegisterMicrosoftUpdate, WuaInstall, Run, DefenderUpdate change the system and are only used by a run
        after the snapshot gate. NOT exercised by the checks beyond the read-only members (no real update, no real Windows Update call on a developer
        machine): the COM code of WuaSearch/WuaInstall is written from the WUA API documentation and has to be tried on a throw-away VM.
    #>
    $state = @{ Session = $null; Cache = @{} }
    $u = [ordered]@{ Kind = 'Real'; State = $state }
    $u.Sleep = { param($Seconds) Start-Sleep -Seconds $Seconds }
    $u.Path = {
        # full paths in fixed system folders (Get-AVDTuneSystemFolder), never from environment variables or PATH
        param($Name)
        switch ($Name) {
            'C2R' { Join-Path (Get-AVDTuneSystemFolder CommonProgramFiles) 'Microsoft Shared\ClickToRun\OfficeC2RClient.exe' }
            'EdgeUpdate' { Join-Path (Get-AVDTuneSystemFolder ProgramFilesX86) 'Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe' }
            'OneDrive' { Join-Path (Get-AVDTuneSystemFolder ProgramFiles) 'Microsoft OneDrive\OneDrive.exe' }
            'Dism' { Join-Path (Get-AVDTuneSystemFolder System) 'Dism.exe' }
            'Sfc' { Join-Path (Get-AVDTuneSystemFolder System) 'sfc.exe' }
            default { throw "Unknown path name $Name" }
        }
    }
    $u.Exists = { param($Path) [bool]($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) }
    $u.FileVersion = {
        param($Path)
        if ($Path -and (Test-Path -LiteralPath $Path)) { [string](Get-Item -LiteralPath $Path).VersionInfo.ProductVersion } else { $null }
    }
    $u.AppxVersion = {
        param($Name)
        $p = @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1)
        if ($p.Count -gt 0) { [string]$p[0].Version } else { $null }
    }
    $u.FindTool = {
        <#
            Only fixed places whose file and folders are writable by administrators only (Test-AVDTuneAdminOnlyPath): $ExtraFolder (config\tools),
            winget in WindowsApps (newest DesktopAppInstaller by version), choco in the machine's Chocolatey folder. No PATH, no environment variables.
        #>
        param($Name, $ExtraFolder)
        $candidates = @()
        if ($ExtraFolder) { $candidates += @{ Path = (Join-Path $ExtraFolder $Name); Base = (Split-Path $ExtraFolder -Parent) } }
        if ($Name -eq 'winget.exe') {
            $apps = Join-Path (Get-AVDTuneSystemFolder ProgramFiles) 'WindowsApps'
            $dirs = @(Get-ChildItem -LiteralPath $apps -Directory -Filter 'Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe' -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'winget.exe') -PathType Leaf } | ForEach-Object Name)
            $newest = Select-AVDTuneNewestPackageFolder $dirs
            if ($newest) { $candidates += @{ Path = (Join-Path (Join-Path $apps $newest) 'winget.exe'); Base = $apps } }
        }
        if ($Name -eq 'choco.exe') {
            $croot = Get-AVDTuneChocolateyRoot
            $candidates += @{ Path = (Join-Path $croot 'bin\choco.exe'); Base = (Split-Path $croot -Parent) }
        }
        foreach ($c in $candidates) {
            if ((Test-Path -LiteralPath $c.Path -PathType Leaf) -and (Test-AVDTuneAdminOnlyPath -Path $c.Path -Base $c.Base)) { return $c.Path }
        }
        $null
    }
    $u.VerifySignature = {
        param($Path)
        $s = Get-AuthenticodeSignature -LiteralPath $Path
        $orig = ''; $product = ''
        try { $vi = (Get-Item -LiteralPath $Path).VersionInfo; $orig = [string]$vi.OriginalFilename; $product = [string]$vi.ProductName } catch { }
        [pscustomobject]@{
            Valid = ($s.Status -eq 'Valid'); Status = [string]$s.Status
            Subject = $(if ($s.SignerCertificate) { [string]$s.SignerCertificate.Subject } else { '' })
            Issuer = $(if ($s.SignerCertificate) { [string]$s.SignerCertificate.Issuer } else { '' })
            OriginalFilename = $orig; ProductName = $product
        }
    }
    $u.Stage = {
        <#
            A copy of the tool in a new folder under <root>\temp; the copy is checked and run. The folder gets no rules of its own: it inherits
            those of the protected state folder (Administrators and SYSTEM only), so no unelevated process, not even of the same administrator,
            can swap the copy, and a folder left behind never looks prepared to the state folder check at the next start.
        #>
        param($Path, $Root)
        $dir = Join-Path (Join-Path $Root 'temp') ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($dir)
        $copy = Join-Path $dir (Split-Path $Path -Leaf)
        [IO.File]::Copy($Path, $copy)
        $copy
    }
    $u.Unstage = {
        param($Path)
        $dir = Split-Path $Path -Parent
        if ((Split-Path $dir -Leaf) -match '^[0-9a-f]{32}$' -and (Split-Path (Split-Path $dir -Parent) -Leaf) -eq 'temp') { [void](Remove-AVDTuneStageDir $dir) }
    }
    $u.Run = {
        <#
            Starts the tool in a job object: the timeout covers the whole process tree (installers started by winget or choco), and Run returns
            only when every process of the tree has ended, so the caller's lock (Global\PackTune) is held until then. On a timeout the tree is ended.
        #>
        param($File, [string[]]$Arguments, [int]$TimeoutSeconds = 600)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $File
        $psi.Arguments = (@($Arguments | ForEach-Object { ConvertTo-AVDTuneArgument ([string]$_) }) -join ' ')
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $job = [IntPtr]::Zero
        try { Initialize-AVDTuneProcessTree; $job = [AVDTune.ProcessTree]::Create() } catch { $job = [IntPtr]::Zero }
        try {
            try { $p = [System.Diagnostics.Process]::Start($psi) } catch { return [pscustomobject]@{ ExitCode = -1; Output = $_.Exception.Message } }
            $inJob = $false
            if ($job -ne [IntPtr]::Zero) { try { [AVDTune.ProcessTree]::Assign($job, $p.Handle); $inJob = $true } catch { } }
            $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            $exited = $p.WaitForExit($TimeoutSeconds * 1000)
            if ($exited -and $inJob) { while ([AVDTune.ProcessTree]::Active($job) -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 } }
            $treeDone = $exited -and (-not $inJob -or [AVDTune.ProcessTree]::Active($job) -eq 0)
            if (-not $treeDone) {
                if ($inJob) {
                    [AVDTune.ProcessTree]::Terminate($job)
                    $until = (Get-Date).AddSeconds(30)
                    while ([AVDTune.ProcessTree]::Active($job) -gt 0 -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 100 }
                }
                else { try { $p.Kill() } catch { } }
                return [pscustomobject]@{ ExitCode = -1; Output = 'timeout' }
            }
            [void]$out.Wait(5000); [void]$err.Wait(5000)
            $text = ''; if ($out.IsCompleted) { $text += $out.Result }; if ($err.IsCompleted) { $text += $err.Result }
            [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $text }
        }
        finally { if ($job -ne [IntPtr]::Zero) { [AVDTune.ProcessTree]::Close($job) } }
    }
    $u.WuaMicrosoftUpdateRegistered = {
        try {
            $sm = New-Object -ComObject Microsoft.Update.ServiceManager
            foreach ($s in $sm.Services) { if ([string]$s.ServiceID -eq $script:MicrosoftUpdateServiceId) { return $true } }
            $false
        }
        catch { $false }
    }
    $u.WuaRegisterMicrosoftUpdate = {
        try {
            $sm = New-Object -ComObject Microsoft.Update.ServiceManager
            [void]$sm.AddService2($script:MicrosoftUpdateServiceId, 7, '')   # asfAllowPendingRegistration + asfAllowOnlineRegistration + asfRegisterServiceWithAU
            @{ Ok = $true; Error = '' }
        }
        catch { @{ Ok = $false; Error = $_.Exception.Message } }
    }.GetNewClosure()
    $u.WuaSearch = {
        param($UseMicrosoftUpdate)
        try {
            $session = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            if ($UseMicrosoftUpdate) { $searcher.ServerSelection = 3; $searcher.ServiceID = $script:MicrosoftUpdateServiceId }   # ssOthers
            $found = $searcher.Search('IsInstalled=0 and IsHidden=0')
            $state.Session = $session; $state.Cache = @{}
            $list = @()
            foreach ($up in $found.Updates) {
                $id = [string]$up.Identity.UpdateID
                $state.Cache[$id] = $up
                $kbs = @(); foreach ($k in $up.KBArticleIDs) { $kbs += [string]$k }
                $list += [pscustomobject]@{ Id = $id; Title = [string]$up.Title; Kbs = $kbs; IsDriver = ([int]$up.Type -eq 2); SizeMB = [Math]::Round([double]$up.MaxDownloadSize / 1MB, 1); Reboot = ([int]$up.InstallationBehavior.RebootBehavior -ne 0) }
            }
            @{ Ok = $true; HResult = 0; Error = ''; Updates = $list }
        }
        catch { @{ Ok = $false; HResult = $_.Exception.HResult; Error = $_.Exception.Message; Updates = @() } }
    }.GetNewClosure()
    $u.WuaInstall = {
        param($Id)
        try {
            $up = $state.Cache[$Id]
            if (-not $up) { return @{ Ok = $false; ResultCode = 4; HResult = 0x80248007 - 0x100000000; RebootRequired = $false } }
            if (-not $up.EulaAccepted) { $up.AcceptEula() }
            $coll = New-Object -ComObject Microsoft.Update.UpdateColl
            [void]$coll.Add($up)
            $dl = $state.Session.CreateUpdateDownloader(); $dl.Updates = $coll
            $d = $dl.Download()
            if ([int]$d.ResultCode -notin 2, 3) { return @{ Ok = $false; ResultCode = [int]$d.ResultCode; HResult = [int]$d.HResult; RebootRequired = $false } }
            $inst = $state.Session.CreateUpdateInstaller(); $inst.Updates = $coll; $inst.AllowSourcePrompts = $false
            $r = $inst.Install()
            $one = $r.GetUpdateResult(0)
            @{ Ok = $true; ResultCode = [int]$one.ResultCode; HResult = [int]$one.HResult; RebootRequired = [bool]$r.RebootRequired }
        }
        catch { @{ Ok = $false; ResultCode = 4; HResult = $_.Exception.HResult; RebootRequired = $false } }
    }.GetNewClosure()
    $u.DefenderStatus = {
        try { $s = Get-MpComputerStatus -ErrorAction Stop; @{ Version = [string]$s.AntivirusSignatureVersion; LastUpdated = [datetime]$s.AntivirusSignatureLastUpdated } } catch { $null }
    }
    $u.DefenderUpdate = { try { Update-MpSignature -ErrorAction Stop; @{ Ok = $true; Error = '' } } catch { @{ Ok = $false; Error = $_.Exception.Message } } }
    $u.LockEnter = {
        # Mutexes with a security descriptor (SYSTEM and Administrators only). One that belongs to someone else was made by a user to steer installs: fail closed.
        $admin = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
        $opened = @()
        foreach ($name in $script:LockNames) {
            $sec = New-Object System.Security.AccessControl.MutexSecurity
            foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') { $sec.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule((New-Object System.Security.Principal.SecurityIdentifier $sid), [System.Security.AccessControl.MutexRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow))) }
            $created = $false
            try { $mx = [System.Threading.Mutex]::new($false, $name, [ref]$created, $sec) } catch { foreach ($o in $opened) { $o.Dispose() }; return @{ Ok = $false; Error = "the lock $name exists but cannot be opened, so it was not made by PackTune or AVDTune" } }
            if (-not $created) {
                $owner = ''; try { $owner = $mx.GetAccessControl().GetOwner([System.Security.Principal.SecurityIdentifier]).Value } catch { }
                if ($owner -notin $admin) { $mx.Dispose(); foreach ($o in $opened) { $o.Dispose() }; return @{ Ok = $false; Error = "the lock $name belongs to someone else (owner '$owner')" } }
            }
            $opened += $mx
        }
        $taken = @()
        foreach ($mx in $opened) {
            $got = $false
            try { $got = $mx.WaitOne([TimeSpan]::FromMinutes(30)) } catch [System.Threading.AbandonedMutexException] { $got = $true }
            if (-not $got) { foreach ($t in $taken) { $t.ReleaseMutex() }; foreach ($o in $opened) { $o.Dispose() }; return @{ Ok = $false; Error = 'another winget or Chocolatey operation has run for more than 30 minutes (lock Global\PackTune)' } }
            $taken += $mx
        }
        $state.Locks = $opened
        @{ Ok = $true; Error = '' }
    }.GetNewClosure()
    $u.LockExit = {
        $locks = @(); if ($state.ContainsKey('Locks')) { $locks = @($state.Locks) }
        for ($i = $locks.Count - 1; $i -ge 0; $i--) { try { $locks[$i].ReleaseMutex() } catch { }; $locks[$i].Dispose() }
        $state.Remove('Locks')
    }.GetNewClosure()
    [pscustomobject]$u
}

#endregion

Export-ModuleMember -Function Get-AVDTuneUpdateSettings, Set-AVDTuneUpdateSettings, ConvertTo-AVDTuneKbList, Resolve-AVDTuneWuaError, Resolve-AVDTuneSoftwareError,
    ConvertFrom-AVDTuneWingetUpgrade, ConvertFrom-AVDTuneChocoOutdated, Invoke-AVDTuneLocked, Test-AVDTuneToolTrust, Test-AVDTuneAdminOnlyAcl, Test-AVDTuneAdminOnlyPath,
    Select-AVDTuneNewestPackageFolder, Get-AVDTuneSystemFolder, Resolve-AVDTuneTool, Clear-AVDTuneStageFolder, Remove-AVDTuneStageDir, Get-AVDTuneUpdateList, Invoke-AVDTuneUpdateRun, Invoke-AVDTuneRepair,
    Get-AVDTuneUpdateHistory, New-AVDTuneUpdateAdapter
