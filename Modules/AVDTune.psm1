<#
    AVDTune engine: no UI. Used by Start-AVDTune.ps1, by the command line (Invoke-AVDTune -Plan x.json -WhatIf) and by the checks.

    Parts
      1. Machine adapters (registry, services, tasks, native commands, instance metadata). Every access to the machine goes through
         one adapter object, so the checks run against a fake (Tests\Fakes\FakeMachine.ps1) and never touch a real system.
      2. State under C:\ProgramData\AVDTune (override: environment variable AVDTUNE_ROOT, used by checks and the smoke test):
         state.json (current), runs\ (one record per run, append only), changelog.json, protocols\, config\, benchmark\, logs\.
         Written atomically, ACL Administrators/SYSTEM. No secrets, no tokens.
      3. Step contract: Id, Section, Title, Why, Risk, Reboot, SourceUrl, Test, Apply, Undo. Idempotent; WhatIf changes nothing.
      4. Change log per image version (YYYY.MM.NNN) with export to Markdown and HTML.
      5. Overview data: image identity (source image from the instance metadata), builds, health checks.
#>

Set-StrictMode -Version 2.0

$script:StateSchema = 1
$script:ImageVersionPattern = '^\d{4}\.(0[1-9]|1[0-2])\.\d{3}$'
$script:ChangeTypes = @('Added', 'Changed', 'Updated', 'Removed', 'Note')
# The version of the tool (file VERSION next to Modules\) is part of every change log entry
$script:ToolVersion = ''
try { $versionFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'VERSION'; if (Test-Path -LiteralPath $versionFile) { $script:ToolVersion = ([IO.File]::ReadAllText($versionFile)).Trim() } } catch { }
$script:StepSections = @('Setup', 'Updates', 'Software', 'Office', 'Optimization', 'FSLogix', 'AppMasking', 'VdiComponents', 'UserExperience', 'UpdateBlock', 'Benchmark', 'Seal', 'Language', 'Customizations', 'Printers')
$script:StepModes = @('Test', 'Apply', 'Undo')

#region elevation, root

function Get-AVDTuneProp($Object, [string]$Name) {
    # Optional property of parsed json: $null when it is not there (strict mode would throw)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

function Get-AVDTuneWebResponse($Exception) {
    # The HTTP response behind a failed GetResponse(): PowerShell wraps the WebException in a MethodInvocationException, so the
    # response (status code and Azure's error body) sits on an inner exception. $null when there was no answer (no connection).
    $e = $Exception; $depth = 0
    while ($null -ne $e -and $depth -lt 8) {
        if ($e -is [System.Net.WebException] -and $null -ne $e.Response) { return $e.Response }
        $e = $e.InnerException; $depth++
    }
    $null
}

function Test-AVDTuneElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-AVDTunePrivateIp([string]$Ip) {
    # RFC 1918 (10/8, 172.16/12, 192.168/16); what a private endpoint or a file server inside the network gets. Loopback and public addresses are not private.
    # Shared by the storage check and the share input of the optimization list (#41 review F1); every octet 0..255.
    if ($Ip -notmatch '\A(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\z') { return $false }
    if (@(1..4 | Where-Object { [int]$Matches[$_] -gt 255 }).Count -gt 0) { return $false }
    $a = [int]$Matches[1]; $b = [int]$Matches[2]
    ($a -eq 10) -or ($a -eq 172 -and $b -ge 16 -and $b -le 31) -or ($a -eq 192 -and $b -eq 168)
}

function Test-AVDTuneUnderPath([string]$Path, [string]$Folder) {
    $f = [IO.Path]::GetFullPath($Folder).TrimEnd('\') + '\'
    [IO.Path]::GetFullPath($Path).StartsWith($f, [StringComparison]::OrdinalIgnoreCase)
}

function Get-AVDTuneLongPath([string]$Path) {
    # Full path without 8.3 short names (C:\PROGRA~1 is Program Files): the longest existing part is expanded by Windows, the rest is appended as given
    if (-not ('AVDTune.LongPath' -as [type])) {
        Add-Type -Namespace AVDTune -Name LongPath -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern uint GetLongPathName(string shortPath, System.Text.StringBuilder longPath, uint bufferSize);
'@
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $rest = New-Object System.Collections.ArrayList
    $cur = $full
    while ($cur -and -not (Test-Path -LiteralPath $cur)) {
        $parent = Split-Path $cur -Parent
        if (-not $parent -or $parent -eq $cur) { return $full }
        [void]$rest.Insert(0, (Split-Path $cur -Leaf)); $cur = $parent
    }
    $sb = New-Object System.Text.StringBuilder 1024
    $n = [AVDTune.LongPath]::GetLongPathName($cur, $sb, 1024)
    $long = $(if ($n -gt 0 -and $n -lt 1024) { $sb.ToString() } else { $cur })
    foreach ($r in $rest) { $long = Join-Path $long $r }
    $long.TrimEnd('\')
}

function Resolve-AVDTuneTestScript {
    <#
        The one gate for a test script that is dot-sourced (fake machine, fake services, smoke driver ...): the long path (no 8.3 names) must be a file below
        <AppRoot>\Tests, and no part of the chain from AppRoot down to the file may be a link. Returns the full path or $null.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$AppRoot)
    try {
        $app = Get-AVDTuneLongPath $AppRoot
        $tests = Join-Path $app 'Tests'
        $full = Get-AVDTuneLongPath $Path
        if (-not (Test-AVDTuneUnderPath $full $tests)) { return $null }
        if (-not [IO.File]::Exists($full)) { return $null }
        $cur = $app
        if ([IO.File]::GetAttributes($cur) -band [IO.FileAttributes]::ReparsePoint) { return $null }
        foreach ($p in @($full.Substring($app.Length).Trim('\').Split([char]92))) {
            $cur = Join-Path $cur $p
            if ([IO.File]::GetAttributes($cur) -band [IO.FileAttributes]::ReparsePoint) { return $null }
        }
        $full
    } catch { $null }
}

$script:TestModeWarned = @{}
$script:TestModeRefusals = New-Object System.Collections.ArrayList
function Get-AVDTuneTestModeRefusal {
    # The refused test mode requests of this process (Time, Reason; never a value), for the protocol after the state is initialised
    @($script:TestModeRefusals)
}

function Test-AVDTuneTestMode {
    <#
        The one decision about the test mode (AVDTUNE_FAKE + AVDTUNE_ROOT, and AVDTUNE_SMOKE which only counts inside it). The test mode skips the elevation check and
        dot-sources scripts, so an environment variable set by someone else (HKCU\Environment is read by an elevated process started from the same user's session)
        must never switch it on:
          - not an installed copy (long path, no 8.3 names): not below Program Files, and Get-AVDTuneInstallInfo does not say Installed,
          - the variables come from the process environment only: the User and Machine values are empty,
          - the fake script (and the smoke script) is a file below <AppRoot>\Tests (long path, no links from AppRoot down).
        EnvReader: scriptblock (name, scope) for the User/Machine environment, injectable for checks. InstallRoot and ProgramFilesFolder are injectable too.
        Returns Enabled, Smoke (test mode and AVDTUNE_SMOKE), FakeScript, FakeDir, SmokeScript, Root (AVDTUNE_ROOT, only when enabled), Reason.
        Without any variable it is quiet; a refused request writes a warning (once per reason), is remembered (Get-AVDTuneTestModeRefusal) and the normal start follows.
    #>
    [CmdletBinding()]
    param([string]$AppRoot = (Split-Path $PSScriptRoot -Parent), [scriptblock]$EnvReader = { param($n, $s) [Environment]::GetEnvironmentVariable($n, $s) },
        [string]$InstallRoot = (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'AVDTune'),
        [string[]]$ProgramFilesFolder = @([Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86')))
    $fake = [string]$env:AVDTUNE_FAKE; $root = [string]$env:AVDTUNE_ROOT; $smoke = [string]$env:AVDTUNE_SMOKE
    $result = { param($ok, $why, $script, $smokeScript)
        [pscustomobject]@{ Enabled = $ok; Smoke = [bool]($ok -and $smokeScript); FakeScript = $script; FakeDir = $(if ($script) { Split-Path $script -Parent } else { '' }); SmokeScript = $smokeScript; Root = $(if ($ok) { $root } else { '' }); Reason = $why } }
    if (-not $fake -and -not $root -and -not $smoke) { return (& $result $false '' $null $null) }
    $why = ''; $script = $null; $smokeScript = $null
    if (-not $fake -and -not $root) { $why = 'AVDTUNE_SMOKE is ignored without the test mode' }
    elseif (-not $fake) { $why = 'AVDTUNE_ROOT is ignored without AVDTUNE_FAKE (test mode only)' }
    elseif (-not $root) { $why = 'AVDTUNE_FAKE is ignored without AVDTUNE_ROOT (test mode only)' }
    else {
        $app = Get-AVDTuneLongPath $AppRoot
        $installed = $false
        foreach ($p in @($ProgramFilesFolder | Where-Object { $_ })) { if (Test-AVDTuneUnderPath $app (Get-AVDTuneLongPath $p)) { $installed = $true } }
        try {
            if ([string]::Equals((Split-Path $app -Parent).TrimEnd('\'), (Get-AVDTuneLongPath $InstallRoot), [StringComparison]::OrdinalIgnoreCase)) { $installed = $true }
            if (-not $installed -and (Get-Command Get-AVDTuneInstallInfo -ErrorAction SilentlyContinue)) {
                if ((Get-AVDTuneInstallInfo -AppRoot $app -InstallRoot (Get-AVDTuneLongPath $InstallRoot)).Mode -eq 'Installed') { $installed = $true }
            }
        } catch { $installed = $true }
        $fromEnv = $false
        foreach ($n in 'AVDTUNE_FAKE', 'AVDTUNE_ROOT', 'AVDTUNE_SMOKE') { foreach ($s in 'User', 'Machine') { if ([string](& $EnvReader $n $s)) { $fromEnv = $true } } }
        if ($installed) { $why = 'AVDTUNE_FAKE/AVDTUNE_ROOT/AVDTUNE_SMOKE are ignored in an installed copy' }
        elseif ($fromEnv) { $why = 'AVDTUNE_FAKE/AVDTUNE_ROOT/AVDTUNE_SMOKE are ignored because they are set in the user or machine environment, not only in this process' }
        else {
            $script = Resolve-AVDTuneTestScript -Path $fake -AppRoot $app
            if (-not $script) { $why = 'AVDTUNE_FAKE is ignored: it is not a file below the Tests folder of this copy' }
            elseif ($smoke) {
                $smokeScript = Resolve-AVDTuneTestScript -Path $smoke -AppRoot $app
                if (-not $smokeScript) { $why = 'AVDTUNE_SMOKE is ignored: it is not a file below the Tests folder of this copy' }
            }
        }
    }
    if ($why) {
        $script = $null; $smokeScript = $null
        if (-not $script:TestModeWarned[$why]) {
            $script:TestModeWarned[$why] = $true
            [void]$script:TestModeRefusals.Add([pscustomobject]@{ Time = [DateTime]::UtcNow.ToString('o'); Reason = $why })
            Write-Warning "$why; normal start."
        }
    }
    & $result (-not $why) $why $script $smokeScript
}

function Confirm-AVDTuneAction {
    # A yes/no question. In the smoke run (Auto: test mode and AVDTUNE_SMOKE, from Test-AVDTuneTestMode) it answers yes without a dialog; otherwise Dialog shows it
    # (injectable for checks; the window passes the message box).
    param([Parameter(Mandatory)][string]$Text, [string]$Title = 'AVDTune', [bool]$Auto, [Parameter(Mandatory)][scriptblock]$Dialog)
    if ($Auto) { return $true }
    [bool](& $Dialog $Text $Title)
}

function Get-AVDTuneRoot {
    [CmdletBinding()] param()
    # AVDTUNE_ROOT is a test hook: honoured only inside the test mode (Test-AVDTuneTestMode, the one place that reads it). Otherwise it is ignored (the refusal is
    # warned there), so an environment variable set by someone else cannot move the state (and the WebView2 DLLs) of the elevated tool to a folder he controls.
    $default = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'AVDTune'
    $mode = Test-AVDTuneTestMode
    if ($mode.Enabled -and $mode.Root) { return $mode.Root }
    $default
}

function Test-AVDTuneDefaultRoot([string]$Root) {
    # True for the real state folder: the only place where the ACL is enforced
    $default = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'AVDTune'
    [string]::Equals($Root.TrimEnd('\'), $default.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}

#endregion

#region machine adapters

function ConvertTo-AVDTuneArgument([string]$Value) {
    # One argument of a command line, quoted the way CommandLineToArgvW reads it. Arguments are data: never joined by hand elsewhere.
    if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    '"' + $escaped + '"'
}

$script:TrustedWriterSids = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464', 'S-1-3-0')   # Administrators, SYSTEM, TrustedInstaller, CREATOR OWNER

function Read-AVDTuneAclReport {
    <#
        What can be said about the ACL of a file or folder, for the checks of the watermark steps: Exists, Link (reparse point), Owner (SID),
        Protected, Rules = allow rules with Sid, Write (any right that changes content, permissions or owner), Inherited and InheritOnly. A missing path
        gives Exists = $false.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $dir = New-Object IO.DirectoryInfo $Path
    $file = New-Object IO.FileInfo $Path
    if (-not $dir.Exists -and -not $file.Exists) { return [pscustomobject]@{ Exists = $false; Link = $false; Owner = ''; Protected = $false; Rules = @() } }
    $item = if ($dir.Exists) { $dir } else { $file }
    $acl = $item.GetAccessControl()
    $writeMask = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x40000000 -bor 0x10000000   # WriteData, AppendData, WriteEA, DeleteChild, WriteAttributes, Delete, ChangePermissions, TakeOwnership, GENERIC_WRITE, GENERIC_ALL
    [pscustomobject]@{
        Exists = $true; Link = (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        Owner = [string]$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value; Protected = [bool]$acl.AreAccessRulesProtected
        Rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Allow' } | ForEach-Object {
                [pscustomobject]@{ Sid = [string]$_.IdentityReference.Value; Write = ((([int]$_.FileSystemRights) -band $writeMask) -ne 0); Inherited = [bool]$_.IsInherited; InheritOnly = (([int]$_.PropagationFlags -band 2) -ne 0) }
            })
    }
}

function Get-AVDTuneAclFindings {
    <#
        Problems (stops) and Warnings of an ACL report. By default every write entry counts, also an inherit-only one (IO): in an admin-only folder it makes every new file writable for that SID. -IgnoreInheritOnly (only the Public Desktop check) leaves IO entries out of the question "may users write to the folder itself".
        -WarnWriteSids: write access of exactly these SIDs is a Warning instead of a Problem (for the Public Desktop, where Windows gives them Modify); any other SID, a foreign owner and a link stay Problems.
    #>
    param($Report, [string[]]$ExtraTrusted = @(), [string[]]$WarnWriteSids = @(), [switch]$IgnoreInheritOnly)
    $p = New-Object System.Collections.ArrayList; $w = New-Object System.Collections.ArrayList
    if (-not $Report -or -not $Report.Exists) { return [pscustomobject]@{ Problems = @(); Warnings = @() } }
    $trusted = @($script:TrustedWriterSids) + @($ExtraTrusted)
    if ($Report.Link) { [void]$p.Add('is a link') }
    if ($Report.Owner -and $Report.Owner -notin $trusted) { [void]$p.Add("owner is $($Report.Owner)") }
    $other = @($Report.Rules | Where-Object { $_.Write -and $_.Sid -notin $trusted -and -not ($IgnoreInheritOnly -and (Get-AVDTuneProp $_ 'InheritOnly')) } | ForEach-Object { $_.Sid } | Sort-Object -Unique)
    $stop = @($other | Where-Object { $_ -notin $WarnWriteSids }); $warn = @($other | Where-Object { $_ -in $WarnWriteSids })
    if ($stop.Count -gt 0) { [void]$p.Add("write access for $($stop -join ', ')") }
    if ($warn.Count -gt 0) { [void]$w.Add("write access for $($warn -join ', ')") }
    [pscustomobject]@{ Problems = @($p); Warnings = @($w) }
}

function Get-AVDTuneAclProblems {
    # Why a path is not safe for something that users read or run: a link, an owner other than Administrators/SYSTEM/TrustedInstaller, write access for anyone else. Empty = fine.
    param($Report, [string[]]$ExtraTrusted = @())
    @((Get-AVDTuneAclFindings -Report $Report -ExtraTrusted $ExtraTrusted).Problems)
}

function New-AVDTuneUsersReadSecurity {
    # Folder that everybody may read and only Administrators/SYSTEM may change; no inheritance from ProgramData (which lets users create files there)
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner((New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
    foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
        $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier $sid), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-545'), 'ReadAndExecute', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    $security
}

function New-AVDTuneFileSecurity {
    # A file that everybody may read and run and only Administrators/SYSTEM may change; protected (no inheritance), owner Administrators when elevated
    # -AdminOnly: nobody else may even read it (state files)
    param([switch]$AdminOnly)
    $security = New-Object System.Security.AccessControl.FileSecurity
    $security.SetAccessRuleProtection($true, $false)
    if (Test-AVDTuneElevated) { $security.SetOwner((New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544')) }
    foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
        $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier $sid), 'FullControl', 'Allow')))
    }
    # AVDTune runs elevated; only a check run (not elevated) needs its own user as well, or it could not move its own file
    if ($AdminOnly -and -not (Test-AVDTuneElevated)) { $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'Allow'))) }
    if (-not $AdminOnly) { $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-545'), 'ReadAndExecute', 'Allow'))) }
    $security
}

function Write-AVDTuneAccessFile {
    <#
        The real FileWrite of the machine adapter. The file never keeps an ACL that was there before (File.Replace would): it is created new
        (CreateNew, temp name) with the explicit protected ACL of New-AVDTuneFileSecurity, an existing file is replaced atomically
        (MoveFileEx) by the new one, and the result is checked again with Get-AVDTuneAclProblems (a file that fails is removed again and the call throws).
          Admin      folder created with the ACL it inherits (Program Files); its parent folder, the folder and an existing target must pass the check first
          UsersRead  folder created in one step with New-AVDTuneUsersReadSecurity; an existing folder and target must pass the check first
          AdminNew   only a file that is not there yet (restore of the old launcher in ProgramData: the folder is shared, so only the new file is checked)
        -ExtraTrusted is for the checks (a SID that may own the result when the test is not elevated).
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text, [ValidateSet('Admin', 'UsersRead', 'AdminNew')][string]$Access = 'Admin', [string[]]$ExtraTrusted = @())
    $folder = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $folder)) {
        if ($Access -eq 'UsersRead') { (New-Object IO.DirectoryInfo $folder).Create((New-AVDTuneUsersReadSecurity)) } else { [void](New-Item -ItemType Directory -Path $folder -Force) }
    }
    $check = switch ($Access) { 'Admin' { @((Split-Path $folder -Parent), $folder, $Path) } 'UsersRead' { @($folder, $Path) } default { @() } }
    foreach ($c in $check) {
        $problems = @(Get-AVDTuneAclProblems (Read-AVDTuneAclReport $c) -ExtraTrusted $ExtraTrusted)
        if ($problems.Count -gt 0) { throw "$c is not safe ($($problems -join '; ')). Nothing was written. Check it as administrator." }
    }
    if ($Access -eq 'AdminNew' -and (Test-Path -LiteralPath $Path)) { throw "$Path exists already. It is not overwritten." }
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($Text)
    try {
        $stream = New-Object IO.FileStream($temp, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]'Write, ReadPermissions', [IO.FileShare]::None, 4096, [IO.FileOptions]::None, (New-AVDTuneFileSecurity))
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ($Access -eq 'AdminNew') { [IO.File]::Move($temp, $Path) }
        else { Move-AVDTuneFileReplace $temp $Path }
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
    $after = @(Get-AVDTuneAclProblems (Read-AVDTuneAclReport $Path) -ExtraTrusted $ExtraTrusted)
    if ($after.Count -gt 0) {
        try { [IO.File]::Delete($Path) } catch { }
        throw "$Path got an unsafe ACL ($($after -join '; ')) and was removed again."
    }
}
function Get-AVDTuneTaskInfoFromXml {
    # What matters of a scheduled task definition: first action, principal (group or user, as SID), logon trigger, enabled
    param([Parameter(Mandatory)][string]$Xml)
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($Xml)
    $one = { param($xp) $n = $doc.SelectSingleNode($xp); if ($n) { [string]$n.InnerText } else { '' } }
    $toSid = { param($v) if (-not $v) { return '' }; if ($v -match '^S-1-') { return $v }; if ($v -match '^(BUILTIN\\)?Users$') { return 'S-1-5-32-545' }; if ($v -match '^(BUILTIN\\)?Administrators$') { return 'S-1-5-32-544' }; try { ([Security.Principal.NTAccount]$v).Translate([Security.Principal.SecurityIdentifier]).Value } catch { $v } }
    $enabled = & $one "//*[local-name()='Settings']/*[local-name()='Enabled']"
    [pscustomobject]@{
        Execute = (& $one "//*[local-name()='Actions']/*[local-name()='Exec'][1]/*[local-name()='Command']")
        Arguments = (& $one "//*[local-name()='Actions']/*[local-name()='Exec'][1]/*[local-name()='Arguments']")
        GroupSid = (& $toSid (& $one "//*[local-name()='Principal']/*[local-name()='GroupId']"))
        UserSid = (& $toSid (& $one "//*[local-name()='Principal']/*[local-name()='UserId']"))
        Logon = ($doc.SelectNodes("//*[local-name()='Triggers']/*[local-name()='LogonTrigger']").Count -gt 0)
        Enabled = ($enabled -ne 'false')
    }
}

function Get-AVDTuneDcFromNtDomain {
    # Win32_NTDomain rows (the answer of the DC locator as WMI gives it) -> @{ Name; Address; Site } for a domain, or $null. WMI gives the names with two leading
    # backslashes (\\dc.example.test, \\192.0.2.10): they are cut here, the rest is data (length limited) that Get-AVDTuneJoinState validates.
    param($Rows, [string]$Domain)
    $first = $Domain.Split('.')[0]
    $row = @(@($Rows) | Where-Object { $_ -and ($_.DomainControllerName -or $_.DomainControllerAddress) } | Where-Object { [string]$_.DnsForestName -ieq $Domain -or [string]$_.DomainName -ieq $first }) | Select-Object -First 1
    if (-not $row) { return $null }
    $cut = { param($v) $t = ([string]$v).Trim().TrimStart([char]92); if ($t.Length -gt 255) { $t = $t.Substring(0, 255) }; $t }
    $site = [string]$row.DcSiteName; if (-not $site) { $site = [string]$row.ClientSiteName }
    [pscustomobject]@{ Name = (& $cut $row.DomainControllerName); Address = (& $cut $row.DomainControllerAddress); Site = (& $cut $site) }
}

function New-AVDTuneMachine {
    <#
        The real machine. Registry paths use the PowerShell form (HKLM:\SOFTWARE\...). Reads work everywhere; the writing members change
        the system and are only used by Apply of a step after a visible selection. Tests use New-AVDTuneFakeMachine instead.
    #>
    $m = [ordered]@{ Kind = 'Real' }
    $m.ComputerName = { [Environment]::MachineName }
    $m.Now = { Get-Date }
    $m.RegKeyExists = { param($Path) Test-Path -LiteralPath $Path }
    $m.RegGet = {
        param($Path, $Name)
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($null -eq $item) { return $null }
        $prop = $item.PSObject.Properties[$Name]
        if ($prop) { $prop.Value } else { $null }
    }
    $m.RegGetRaw = {
        # The value as stored: kind from GetValueKind, the text of REG_EXPAND_SZ not expanded (DoNotExpandEnvironmentNames). @{ Value; Kind } or $null. Kind: DWord, QWord, String, ExpandString, MultiString, Binary.
        param($Path, $Name)
        if ($Path -notmatch '^(HKLM|HKCU):\\(.+)$') { throw "RegGetRaw: unsupported path $Path" }
        $hive = if ($Matches[1] -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
        $key = $hive.OpenSubKey($Matches[2], $false)
        if ($null -eq $key) { return $null }
        try {
            if (@($key.GetValueNames()) -cnotcontains $Name -and @($key.GetValueNames() | Where-Object { $_ -ieq $Name }).Count -eq 0) { return $null }
            $kind = $key.GetValueKind($Name)
            @{ Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); Kind = [string]$kind }
        }
        finally { $key.Dispose() }
    }
    $m.RegSet = {
        param($Path, $Name, $Value, $Type)
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type $Type
    }
    $m.RegRemove = {
        param($Path, $Name)
        if (Test-Path -LiteralPath $Path) { Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue }
    }
    $m.ServiceGet = {
        param($Name)
        # only "there is no such service" means absent; any other error (access, service control manager) is thrown, so the row says "cannot be read" instead of "not on this host" (#66)
        $s = $null
        try { $s = Get-Service -Name $Name -ErrorAction Stop } catch { if ([string]$_.FullyQualifiedErrorId -notlike 'NoServiceFoundForGivenName*') { throw } }
        if (-not $s) { return $null }
        [pscustomobject]@{ Name = $s.Name; Status = [string]$s.Status; StartType = [string]$s.StartType }
    }
    $m.ServiceSetStartup = { param($Name, $Startup) Set-Service -Name $Name -StartupType $Startup }
    $m.ServiceStop = { param($Name) Stop-Service -Name $Name -Force }
    $m.ServiceStart = { param($Name) Start-Service -Name $Name }
    $m.TaskGet = {
        param($Path, $Name)
        $t = $null
        try { $t = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop } catch { if ([string]$_.FullyQualifiedErrorId -notlike 'CmdletizationQuery_NotFound*') { throw } }   # only "not found" means absent (#66)
        if (-not $t) { return $null }
        [pscustomobject]@{ Path = $t.TaskPath; Name = $t.TaskName; Enabled = ($t.State -ne 'Disabled') }
    }
    $m.TaskList = {
        # Names of the tasks directly in a folder (for tasks whose name carries a GUID, like the Edge update tasks)
        param($Path)
        try { @(Get-ScheduledTask -TaskPath $Path -ErrorAction Stop | ForEach-Object { $_.TaskName }) } catch { if ([string]$_.FullyQualifiedErrorId -notlike 'CmdletizationQuery_NotFound*') { throw }; @() }
    }
    $m.TaskSetEnabled = {
        param($Path, $Name, $Enabled)
        if ($Enabled) { Enable-ScheduledTask -TaskPath $Path -TaskName $Name | Out-Null } else { Disable-ScheduledTask -TaskPath $Path -TaskName $Name | Out-Null }
    }
    $m.Run = {
        # File and arguments are separate; the command line is built here with quoting per argument, never from free text
        param($File, [string[]]$Arguments, [int]$TimeoutSeconds = 120)
        # environment and TEMP from Windows, not from this process (issue #47): New-AVDTuneChildStartInfo
        # Windows programs only with their Windows signature, held until they end (#71); the whole tree in a job object (#76)
        Invoke-AVDTuneProgram -File $File -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    }
    $m.Imds = {
        # Azure instance metadata: only reachable inside Azure; $null elsewhere
        try {
            $request = [System.Net.HttpWebRequest]::Create('http://169.254.169.254/metadata/instance?api-version=2021-02-01')
            $request.Headers.Add('Metadata', 'true'); $request.Timeout = 2500; $request.Proxy = $null
            $response = $request.GetResponse()
            try { (New-Object IO.StreamReader($response.GetResponseStream())).ReadToEnd() | ConvertFrom-Json } finally { $response.Close() }
        }
        catch { $null }
    }
    $m.ComputerSystem = {
        # Win32_ComputerSystem, read only (start sequence, issue #64): PartOfDomain, Domain (the domain, or the workgroup name when not part of one), DomainRole. $null when it cannot be read.
        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            [pscustomobject]@{ PartOfDomain = [bool]$cs.PartOfDomain; Domain = [string]$cs.Domain; DomainRole = [int]$cs.DomainRole }
        }
        catch { $null }
    }
    $m.DcLocate = {
        # The DC the Windows locator (DsGetDcName) found for a domain name, read from Win32_NTDomain (WMI, local, read only). No AD or LDAP object is used here: they
        # bind to the found server with the administrator's credentials, before anything is pinned (finding of the security review).
        # @{ Name; Address; Site } or $null. Values are data: length limited, shaped by Get-AVDTuneJoinState before use.
        param($Domain)
        try {
            Get-AVDTuneDcFromNtDomain -Rows @(Get-CimInstance -ClassName Win32_NTDomain -ErrorAction Stop) -Domain $Domain
        }
        catch { $null }
    }
    # Read-only members of the readiness analysis (docs\plans\avdtune.md, section 2a)
    $m.RegSubKeys = {
        param($Path)
        if (-not (Test-Path -LiteralPath $Path)) { return @() }
        @(Get-ChildItem -LiteralPath $Path -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
    }
    $m.RegNames = {
        # Names of the values directly in a key (FSLogix typo check); empty when the key is not there
        param($Path)
        if (-not (Test-Path -LiteralPath $Path)) { return @() }
        $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($null -eq $item) { return @() }
        @($item.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { $_.Name })
    }
    $m.PathExists = { param($Path) Test-Path -LiteralPath $Path }
    $m.DirList = {
        # Names of the files and folders directly in a folder; empty when the folder is not there
        param($Path, $Filter = '*')
        if (-not (Test-Path -LiteralPath $Path)) { return @() }
        @(Get-ChildItem -LiteralPath $Path -Filter $Filter -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }
    $m.Hotfixes = {
        # Installed updates with the date: @{ Id; InstalledOn } (InstalledOn can be $null)
        @(Get-CimInstance -ClassName Win32_QuickFixEngineering -ErrorAction Stop | ForEach-Object {
                $on = $null; if ($_.InstalledOn) { try { $on = [datetime]$_.InstalledOn } catch { } }
                [pscustomobject]@{ Id = [string]$_.HotFixID; InstalledOn = $on }
            })
    }
    $m.NetAdapters = {
        @(Get-NetAdapter -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Description = $_.InterfaceDescription; Status = [string]$_.Status } })
    }
    $m.PnpPresent = {
        # True when a present PnP device has an instance ID that matches the regular expression
        param($Pattern)
        $found = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.InstanceId -match $Pattern })
        $found.Count -gt 0
    }
    $m.OsArchitecture = {
        $a = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
        [string]$a
    }
    $m.TpmPresent = {
        # $true / $false, $null when the TPM provider cannot be asked
        try {
            $t = @(Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop)
            ($t.Count -gt 0 -and [bool]$t[0].IsEnabled_InitialValue)
        }
        catch { $null }
    }
    $m.FirmwareType = {
        # 'UEFI' / 'BIOS' from kernel32 GetFirmwareType (FirmwareTypeBios = 1, FirmwareTypeUefi = 2); $null when it cannot be asked.
        # (The registry value PEFirmwareType exists only in Windows PE, not on an installed Windows.)
        try {
            if (-not ('AVDTune.Native.Firmware' -as [type])) {
                Add-Type -Namespace 'AVDTune.Native' -Name 'Firmware' -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetFirmwareType(out uint firmwareType);' -ErrorAction Stop
            }
            $type = [uint32]0
            if (-not [AVDTune.Native.Firmware]::GetFirmwareType([ref]$type)) { return $null }
            switch ($type) { 1 { 'BIOS' } 2 { 'UEFI' } default { $null } }
        }
        catch { $null }
    }
    # Members of the watermark (docs\plans\avdtune.md, section 5): folders, files, ACL report and tasks with their definition
    $m.KnownFolder = {
        param($Name)
        switch ($Name) {
            'ProgramFiles' { [Environment]::GetFolderPath('ProgramFiles') }
            'CommonAppData' { [Environment]::GetFolderPath('CommonApplicationData') }
            'System' { [Environment]::GetFolderPath('System') }
            default { throw "Unknown folder '$Name'." }
        }
    }
    $m.FileText = { param($Path) if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF) } else { $null } }
    $m.FileWrite = { param($Path, $Text, $Access = 'Admin') Write-AVDTuneAccessFile -Path $Path -Text $Text -Access $Access }
    $m.FileRemove = { param($Path) if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not (Remove-AVDTuneTreeSafe -Path $Path).Gone) { throw "$Path could not be deleted (in use)." } }   # by handle (#48): a name swapped for a link is removed as a link (the legacy file sits in the ProgramData root, where users create files)
    $m.DirRemoveEmpty = { param($Path) if ((Test-Path -LiteralPath $Path -PathType Container) -and @(Get-ChildItem -LiteralPath $Path -Force).Count -eq 0) { Remove-Item -LiteralPath $Path -Force } }
    $m.AclReport = { param($Path) Read-AVDTuneAclReport -Path $Path }
    $m.TaskDetail = {
        param($Path, $Name)
        $t = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction SilentlyContinue
        if (-not $t) { return $null }
        $xml = [string](Export-ScheduledTask -TaskPath $Path -TaskName $Name)
        $info = Get-AVDTuneTaskInfoFromXml $xml
        $info | Add-Member -NotePropertyName Path -NotePropertyValue $t.TaskPath -PassThru | Add-Member -NotePropertyName Name -NotePropertyValue $t.TaskName -PassThru | Add-Member -NotePropertyName Xml -NotePropertyValue $xml -PassThru
    }
    $m.TaskRegisterXml = { param($Path, $Name, $Xml) [void](Register-ScheduledTask -TaskPath $Path -TaskName $Name -Xml $Xml -Force) }
    $m.TaskRemove = { param($Path, $Name) Unregister-ScheduledTask -TaskPath $Path -TaskName $Name -Confirm:$false }
    # The default user profile that the optimization list loads (#40): is HKU\AVDTune_DefaultUser loaded, and one unload attempt (reg.exe by full path, exit code)
    $m.HiveLoaded = { $k = [Microsoft.Win32.Registry]::Users.OpenSubKey('AVDTune_DefaultUser'); if ($k) { $k.Close(); $true } else { $false } }
    $run = $m.Run   # the one program start of the adapter (child environment, timeout)
    $m.HiveUnload = { [int](& $run (Join-Path (Get-AVDTuneSystemFolder System) 'reg.exe') @('unload', 'HKU\AVDTune_DefaultUser') 60).ExitCode }.GetNewClosure()
    # Temporary standard users of the benchmark that a crash left behind (#92, Finn M1): found and removed before the finish
    $m.BenchUsers = { Get-AVDTuneBenchUserLeftovers }
    $m.BenchUserRemove = { param($Sid) Remove-AVDTuneBenchUserLeftover -Sid $Sid }
    [pscustomobject]$m
}

$script:BenchUserMarker = 'AVDTune benchmark: temporary standard user, removed after the run'   # the description AVDTune.Bench.exe gives the account (Bench\src\IsolatedUser.cs, Marker)

function Get-AVDTuneBenchUserLeftovers {
    <#
        Accounts of the benchmark's temporary standard user (#92) that are still there: local accounts named avdtb-<12 hex digits> WITH AVDTune's marker as description (an account of that
        name without the marker is not AVDTune's and is never listed), and profiles of that folder name whose account is gone. Name, Sid, Profile (folder or ''), Account (exists).
    #>
    $pat = '\Aavdtb-[0-9a-f]{12}\z'
    $users = @(Get-LocalUser -ErrorAction Stop | Where-Object { [string]$_.Name -cmatch $pat -and [string]$_.Description -ceq $script:BenchUserMarker })
    $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop)
    $known = @($users | ForEach-Object { $_.SID.Value })
    $out = @(foreach ($u in $users) {
            $sid = $u.SID.Value; $pr = @($profiles | Where-Object { [string]$_.SID -eq $sid })[0]
            [pscustomobject]@{ Name = [string]$u.Name; Sid = $sid; Profile = $(if ($pr) { [string]$pr.LocalPath } else { '' }); Account = $true }
        })
    foreach ($pr in $profiles) {
        $leaf = Split-Path ([string]$pr.LocalPath) -Leaf
        if ($leaf -cnotmatch '\Aavdtb-[0-9a-f]{12}(\.[A-Za-z0-9_-]{1,32})?\z' -or [string]$pr.SID -in $known) { continue }
        $acct = $null; try { $acct = (New-Object System.Security.Principal.SecurityIdentifier ([string]$pr.SID)).Translate([System.Security.Principal.NTAccount]) } catch { }
        if ($acct) { continue }   # the account exists without the marker: not AVDTune's
        $out += [pscustomobject]@{ Name = $leaf; Sid = [string]$pr.SID; Profile = [string]$pr.LocalPath; Account = $false }
    }
    @($out)
}

function Remove-AVDTuneBenchUserLeftover {
    <# Removes one of Get-AVDTuneBenchUserLeftovers by SID (read again: only what is still listed): the profile (Win32_UserProfile, folder and registry), then the account. A loaded profile stops it. #>
    param([Parameter(Mandatory)][string]$Sid)
    if ($Sid -cnotmatch '\AS-1-5-21-[0-9]{1,10}-[0-9]{1,10}-[0-9]{1,10}-[0-9]{1,10}\z') { throw "'$Sid' is not a local account SID." }
    $item = @(Get-AVDTuneBenchUserLeftovers | Where-Object { $_.Sid -ceq $Sid })[0]
    if (-not $item) { return }
    $pr = @(Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$Sid'" -ErrorAction Stop)[0]
    if ($pr) {
        if ([bool]$pr.Loaded) { throw "The profile of $($item.Name) is in use: restart the master, then remove it." }
        Remove-CimInstance -InputObject $pr -ErrorAction Stop
    }
    if ($item.Account) { Remove-LocalUser -SID $Sid -ErrorAction Stop }
}

function Invoke-AVDTuneDefaultHiveUnload {
    <#
        Unloads HKU\AVDTune_DefaultUser when a crash left it loaded (#40): at the start of AVDTune and as the readiness fix before Finish/Sysprep. Open handles of
        this process are released first (garbage collection), up to -Tries attempts. Returns WasLoaded and Unloaded. Unloading writes nothing into the profile
        that AVDTune did not write before; it does not set LastChange on its own (the readiness fix does, as every fix).
    #>
    param([Parameter(Mandatory)]$Machine, [ValidateRange(1, 10)][int]$Tries = 5, [ValidateRange(0, 5000)][int]$DelayMs = 500)
    if (-not (& $Machine.HiveLoaded)) { return [pscustomobject]@{ WasLoaded = $false; Unloaded = $true; ExitCode = $null } }
    $code = $null
    for ($i = 0; $i -lt $Tries; $i++) {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        $code = & $Machine.HiveUnload
        if (-not (& $Machine.HiveLoaded)) { return [pscustomobject]@{ WasLoaded = $true; Unloaded = $true; ExitCode = $code } }
        if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    }
    [pscustomobject]@{ WasLoaded = $true; Unloaded = $false; ExitCode = $code }
}

function Invoke-AVDTuneMachine {
    # Calls a member of the adapter: Invoke-AVDTuneMachine $m RegGet 'HKLM:\...' 'Name'
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)][string]$Member, [Parameter(ValueFromRemainingArguments)]$Arguments)
    $block = $Machine.$Member
    if ($null -eq $block) { throw "The machine adapter has no member '$Member'." }
    & $block @Arguments
}

#endregion

#region state

function New-AVDTuneStateSecurity {
    # Administrators and SYSTEM only, no inheritance from ProgramData (which lets every user read). -WithOwner: owner Administrators too
    # (for creating the folder in one step; needs an elevated token).
    param([switch]$WithOwner)
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    if ($WithOwner) { $security.SetOwner((New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544')) }
    foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
        $account = New-Object System.Security.Principal.SecurityIdentifier $sid
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($account, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $security.AddAccessRule($rule)
    }
    $security
}

# The native type is created once at import (not at the first write), a second runspace that created it first is fine
try { Add-Type -Namespace AVDTune -Name NativeMove -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern bool MoveFileEx(string existing, string target, int flags);' -ErrorAction Stop }
catch { if (-not ('AVDTune.NativeMove' -as [type])) { throw } }

function Move-AVDTuneFileReplace {
    # Atomic replace: MoveFileEx(REPLACE_EXISTING | WRITE_THROUGH) on the same volume. The target exists at every moment (old or new file) and the new file
    # keeps the ACL of the temp file; the old ACL is gone. Throws when the move fails (the target is then unchanged).
    # A virus scanner (Defender) briefly holds a fresh file or the target: ERROR_ACCESS_DENIED (5) and ERROR_SHARING_VIOLATION (32) are tried again a few
    # times (about 2 s in all, #58/#65); any other error, or the same one after the last try, throws.
    param([Parameter(Mandatory)][string]$Temp, [Parameter(Mandatory)][string]$Target, [int]$Tries = 6, [int]$WaitMs = 100)
    for ($i = 1; ; $i++) {
        if ([AVDTune.NativeMove]::MoveFileEx($Temp, $Target, 0x1 -bor 0x8)) { return }
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if (($err -ne 5 -and $err -ne 32) -or $i -ge $Tries) { throw (New-Object ComponentModel.Win32Exception($err)) }
        Start-Sleep -Milliseconds ($WaitMs * $i)
    }
}

function Write-AVDTuneFile {
    # Written next to the target with an explicit protected admin-only ACL (CreateNew), then moved over it atomically: a crash leaves the old or the new file,
    # never half of one, and the file never keeps an ACL that was there before (File.Replace would keep it)
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $folder = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($Text)
    try {
        $stream = New-Object IO.FileStream($temp, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]'Write, ReadPermissions', [IO.FileShare]::None, 4096, [IO.FileOptions]::None, (New-AVDTuneFileSecurity -AdminOnly))
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        Move-AVDTuneFileReplace $temp $Path
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}

function Read-AVDTuneJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    if (-not $text.Trim()) { return $null }
    $text | ConvertFrom-Json
}

$script:TrustedOwnerSids = @('S-1-5-32-544', 'S-1-5-18')   # Administrators, SYSTEM
$script:StateSecurityReport = $null

function Read-AVDTuneAclInfo {
    # Owner, protection and allow rules (SID, inherited) of a file or folder; the real reader of Get-AVDTuneStateSecurityProblems
    param([string]$Path, [bool]$IsDirectory)
    $acl = if ($IsDirectory) { (New-Object IO.DirectoryInfo $Path).GetAccessControl() } else { (New-Object IO.FileInfo $Path).GetAccessControl() }
    [pscustomobject]@{
        Owner = [string]$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value; Protected = [bool]$acl.AreAccessRulesProtected
        Rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Allow' } | ForEach-Object { [pscustomobject]@{ Sid = [string]$_.IdentityReference.Value; Inherited = [bool]$_.IsInherited } })
    }
}

function Get-AVDTuneStateSecurityProblems {
    <#
        Walks the state folder (links are reported, never followed) and lists what a user without admin rights could have prepared there:
        an owner other than Administrators/SYSTEM, explicit allow rules for anyone else, links (junctions, symlinks), an ACL that cannot be read.
        -Final also requires the root to be protected (no inheritance from ProgramData) with allow rules for Administrators/SYSTEM only.
    #>
    param([Parameter(Mandatory)][string]$Root, [switch]$Final, [scriptblock]$ReadAcl = { param($Path, $IsDirectory) Read-AVDTuneAclInfo -Path $Path -IsDirectory $IsDirectory },
        # SID of the elevated administrator running AVDTune (files he creates below the root may carry it); '' when not elevated
        [string]$AdminSid = $(if (Test-AVDTuneElevated) { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } else { '' }),
        # only the folder itself (its owner and rules), not what is inside (a download cache can be large)
        [switch]$NoRecurse)
    $problems = New-Object System.Collections.ArrayList
    # Owners that are fine: the root only Administrators or SYSTEM (the admin's own SID could also come from an unelevated process of him);
    # below the root also the elevated administrator running AVDTune
    $owners = @($script:TrustedOwnerSids)
    if ($AdminSid) { $owners += $AdminSid }
    $rootInfo = New-Object IO.DirectoryInfo $Root
    if (-not $rootInfo.Exists) {
        $f = New-Object IO.FileInfo $Root
        if ($f.Exists) { return @([pscustomobject]@{ Path = $Root; Problem = 'a file, not a folder' }) }
        return @()
    }
    $tempRoot = (Join-Path $rootInfo.FullName 'temp').TrimEnd('\')
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($rootInfo)
    $count = 0
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $count++
        if ($count -gt 100000) { [void]$problems.Add([pscustomobject]@{ Path = $Root; Problem = 'too many entries' }); break }
        $isDir = $item -is [IO.DirectoryInfo]
        $isRoot = $item.FullName.TrimEnd('\') -eq $rootInfo.FullName.TrimEnd('\')
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { [void]$problems.Add([pscustomobject]@{ Path = $item.FullName; Problem = 'link (junction or symbolic link)' }); continue }
        try { $acl = & $ReadAcl $item.FullName $isDir }
        catch { [void]$problems.Add([pscustomobject]@{ Path = $item.FullName; Problem = "ACL cannot be read: $($_.Exception.Message)" }); $acl = $null }
        if ($acl) {
            if ($acl.Owner -notin $(if ($isRoot) { $script:TrustedOwnerSids } else { $owners })) { [void]$problems.Add([pscustomobject]@{ Path = $item.FullName; Problem = "owner $($acl.Owner)" }) }
            # Explicit rules anywhere; on the root in the final check also the inherited ones (the root must not inherit from ProgramData)
            $foreign = @($acl.Rules | Where-Object { $_.Sid -notin $script:TrustedOwnerSids -and (-not $_.Inherited -or ($Final -and $isRoot)) } | ForEach-Object { $_.Sid } | Sort-Object -Unique)
            if ($foreign.Count -gt 0) { [void]$problems.Add([pscustomobject]@{ Path = $item.FullName; Problem = "access for $($foreign -join ', ')" }) }
            if ($Final -and $isRoot -and -not $acl.Protected) { [void]$problems.Add([pscustomobject]@{ Path = $item.FullName; Problem = 'inherits rules from ProgramData' }) }
        }
        # The content of a tool's TEMP folder (<root>\temp\<tool>) is not walked: the started program sets its own ACLs there (winget gives the elevated admin an
        # explicit rule on its WinGet folder, #65). The tool folder itself is checked like everything else, and Initialize-AVDTuneToolTemp gives every run a fresh one.
        $isToolTemp = $isDir -and $item.Parent -and $item.Parent.FullName.TrimEnd('\') -ieq $tempRoot
        if ($isDir -and -not $NoRecurse -and -not $isToolTemp) {
            try { foreach ($child in $item.GetFileSystemInfos()) { $queue.Enqueue($child) } }
            catch { [void]$problems.Add([pscustomobject]@{ Path = $item.FullName; Problem = "content cannot be listed: $($_.Exception.Message)" }) }
        }
    }
    @($problems)
}

#region child environment (issue #47)

$script:ChildEnvHooks = @{ Root = ''; AclReader = $null }   # for the checks: a state folder of their own and a fake ACL reader (they run unelevated); only honoured inside the test mode (Test-AVDTuneTestMode), set from the module scope only
$script:ChildEnvHooks.Machine = $null   # test hook: scriptblock (name) -> raw HKLM environment value
$script:ChildEnvHooks.Windows = ''   # test hook: the Windows folder for Test-AVDTuneSystemProgramPath (a copy of a program counts as a Windows program, #71)

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

#region module path (issue #73)
# Windows PowerShell autoloads system cmdlets (Get-AppxPackage, ScheduledTasks, Get-InstalledLanguage, Storage, ...) through $env:PSModulePath, and the
# default value starts with Documents\WindowsPowerShell\Modules of the admin and whatever HKCU\Environment adds: a process of the same admin that is not
# elevated can put a module of the same name there. AVDTune therefore loads modules only from the system folders.
# Why both folders and in this order: on every runspace open Windows PowerShell 5.1 recomputes the path (ModuleIntrinsics.SetModulePath). It always adds
# Program Files\WindowsPowerShell\Modules when it is missing, and when the value then equals the machine value (Program Files first) it adds the personal
# Documents folder again. System32 first, then Program Files is a value that it keeps as it is; System32 alone would become the user path after two opens.
# Also Microsoft.PowerShell.Utility and .Management (Join-Path, New-Object, Add-Type, Get-Content, ConvertFrom-Json, ...) are modules below $PSHOME\Modules that
# are autoloaded through this path, and any module earlier in the path that exports a command of the same name wins. So the launcher and Start-AVDTune.ps1
# set the path with .NET alone as their first statement, before any cmdlet runs (the same expression as Get-AVDTuneSystemModulePath; Tests\Check-AVDTune.ps1).

function Get-AVDTuneSystemModulePath {
    # The module path of AVDTune: Windows PowerShell's own modules (System32), then Program Files (admin-only, checked by Get-AVDTuneModulePathProblems).
    # From the Windows folders (GetFolderPath), never from $env:SystemRoot or $env:ProgramFiles.
    [IO.Path]::Combine((Get-AVDTuneSystemFolder Windows), 'System32\WindowsPowerShell\v1.0\Modules') + ';' + [IO.Path]::Combine((Get-AVDTuneSystemFolder ProgramFiles), 'WindowsPowerShell\Modules')
}

function Set-AVDTuneSafeModulePath {
    # Sets $env:PSModulePath of this process to Get-AVDTuneSystemModulePath and returns it. Called first in Start-AVDTune.ps1 and by New-AVDTunePowerShell /
    # New-AVDTuneRunspacePool before each worker, so every runspace of the process gets the same path (children: Get-AVDTuneChildEnvironment).
    $value = Get-AVDTuneSystemModulePath
    [Environment]::SetEnvironmentVariable('PSModulePath', $value, [EnvironmentVariableTarget]::Process)
    $value
}

function Test-AVDTuneModulePathStable {
    <#
        $true when Windows PowerShell keeps $Value as it is when a runspace opens: the same computation it runs then (ModuleIntrinsics.GetModulePath with the
        machine and the user value of PSModulePath). It would change it, for example, when the machine value equals our value (then it puts the Documents
        folder in front). -Machine / -User are for the checks; by default the values of the registry as Windows PowerShell reads them.
    #>
    param([string]$Value = (Get-AVDTuneSystemModulePath),
        [AllowNull()][string]$Machine = [Environment]::GetEnvironmentVariable('PSModulePath', [EnvironmentVariableTarget]::Machine),
        [AllowNull()][string]$User = [Environment]::GetEnvironmentVariable('PSModulePath', [EnvironmentVariableTarget]::User))
    if ($Machine -eq '') { $Machine = $null }; if ($User -eq '') { $User = $null }
    $next = [System.Management.Automation.ModuleIntrinsics]::GetModulePath($Value, $Machine, $User)
    [string]::Equals([string]$next, $Value, [StringComparison]::OrdinalIgnoreCase)
}

$script:ModuleFileTypes = @('.psd1', '.psm1', '.ps1', '.ps1xml', '.cdxml', '.dll')   # what Windows PowerShell loads from a module folder

function Get-AVDTuneModulePathProblems {
    <#
        Why a module could come from someone without admin rights (fail closed, Start-AVDTune.ps1 does not start then):
          * each folder of the module path and every folder above it up to the Windows or Program Files folder;
          * everything below each folder of the path (module folders, version folders, sub folders like bin\ and en-US\, recursively): every folder, and the
            files of the types in $script:ModuleFileTypes. Links are reported, never followed. At most -MaxEntries entries per folder of the path: more is a
            problem too (not everything could be checked);
          * Windows PowerShell would change the path when a runspace opens (Test-AVDTuneModulePathStable).
        A problem is a link, a foreign owner or write access for others (Get-AVDTuneAclProblems). A missing folder is fine (nothing to load). Empty = fine.
        -ReadAcl (path -> object like Read-AVDTuneAclReport), -List (folder -> its FileSystemInfos) and -TestStable are for the checks.
    #>
    param([scriptblock]$ReadAcl = { param($Path) Read-AVDTuneAclReport -Path $Path },
        [scriptblock]$List = { param($Path) (New-Object IO.DirectoryInfo $Path).GetFileSystemInfos() },
        [scriptblock]$TestStable = { Test-AVDTuneModulePathStable },
        [int]$MaxEntries = 5000)
    $out = New-Object System.Collections.ArrayList
    $bases = @((Get-AVDTuneSystemFolder Windows), (Get-AVDTuneSystemFolder ProgramFiles))
    $folders = @((Get-AVDTuneSystemModulePath) -split ';')
    $check = { param($Path) foreach ($p in @(Get-AVDTuneAclProblems -Report (& $ReadAcl $Path))) { [void]$out.Add("${Path}: $p") } }
    for ($i = 0; $i -lt $folders.Count; $i++) {
        $stop = $bases[$i].TrimEnd('\')
        $cur = $folders[$i].TrimEnd('\')
        while ($cur) {
            & $check $cur
            if ($cur -ieq $stop) { break }
            $parent = [IO.Path]::GetDirectoryName($cur)
            if (-not $parent -or $parent -eq $cur) { break }
            $cur = $parent
        }
        # the whole content, recursively; a link is a problem and is not entered; more than -MaxEntries entries is a problem and ends the walk of this folder
        $root = $folders[$i].TrimEnd('\')
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue($root)
        $seen = 0
        while ($queue.Count -gt 0) {
            $dir = $queue.Dequeue()
            $items = @(); try { $items = @(& $List $dir) } catch { if ($dir -ne $root -or [IO.Directory]::Exists($dir)) { [void]$out.Add("${dir}: content cannot be listed: $($_.Exception.Message)") }; continue }
            $seen += $items.Count
            if ($seen -gt $MaxEntries) { [void]$out.Add("${root}: more than $MaxEntries entries in the module folder, not every module file was checked"); break }
            foreach ($item in $items) {
                $isLink = (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
                $isDir = (($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0)
                if ($isLink) { [void]$out.Add("$($item.FullName): is a link"); continue }
                if ($isDir) { & $check $item.FullName; $queue.Enqueue($item.FullName) }
                elseif ([IO.Path]::GetExtension($item.Name).ToLowerInvariant() -in $script:ModuleFileTypes) { & $check $item.FullName }
            }
        }
    }
    if (-not (& $TestStable)) {
        $machineValue = [Environment]::GetEnvironmentVariable('PSModulePath', [EnvironmentVariableTarget]::Machine); $userValue = [Environment]::GetEnvironmentVariable('PSModulePath', [EnvironmentVariableTarget]::User)
        [void]$out.Add("PSModulePath: Windows PowerShell would change the module path when a runspace opens (checked value: $(Get-AVDTuneSystemModulePath); machine value: $machineValue; user value: $userValue)")
    }
    @($out)
}

function Assert-AVDTuneModulePathStable {
    # Fail closed before a worker opens: the path is set again and must stay as it is when the runspace opens (#73)
    [void](Set-AVDTuneSafeModulePath)
    if (-not (Test-AVDTuneModulePathStable)) { throw 'Windows PowerShell would change the module path when the worker opens (machine or user value of PSModulePath). Nothing is started.' }
}

function New-AVDTunePowerShell {
    # The one way to create a worker ([powershell]::Create()): the module path of the process is set to the system folders first and must stay so (#73);
    # the runspace that opens with BeginInvoke inherits it. Tests\Check-AVDTune.ps1 makes sure no other place calls [powershell]::Create() or [runspacefactory].
    Assert-AVDTuneModulePathStable
    [powershell]::Create()
}

function New-AVDTuneRunspacePool {
    # A runspace pool for parallel workers, after the same module path step as New-AVDTunePowerShell. Not opened yet.
    param([Parameter(Mandatory)][int]$Min, [Parameter(Mandatory)][int]$Max)
    Assert-AVDTuneModulePathStable
    [runspacefactory]::CreateRunspacePool($Min, $Max)
}

#endregion

function Get-AVDTuneMachineEnvironmentValue {
    # A value of the machine environment (HKLM, writable by administrators only); $null when it is not there. Never the process environment.
    param([Parameter(Mandatory)][string]$Name)
    if ($script:ChildEnvHooks.Machine -and (Test-AVDTuneTestMode).Enabled) { return (& $script:ChildEnvHooks.Machine $Name) }
    # Raw: Get-ItemProperty would expand a REG_EXPAND_SZ value (%ProgramData%) with the environment of this process
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment')
        if (-not $key) { return $null }
        try { $v = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } finally { $key.Close() }
        if ($null -eq $v) { $null } else { [string]$v }
    }
    catch { $null }
}

function Get-AVDTuneChocolateyRoot {
    # The machine value of ChocolateyInstall (HKLM, admins only), never the process environment; otherwise the default under ProgramData
    $v = Get-AVDTuneMachineEnvironmentValue -Name ChocolateyInstall
    if ($v -and $v -notmatch '%' -and [IO.Path]::IsPathRooted($v)) { return $v.TrimEnd('\') }
    Join-Path (Get-AVDTuneSystemFolder ProgramData) 'chocolatey'
}

function Get-AVDTuneChildTool {
    # The environment profile for a program, by its file name: winget, choco, msiexec, bench (AVDTune.Bench.exe); everything else is base
    param([Parameter(Mandatory)][string]$File)
    switch -Regex ([IO.Path]::GetFileName($File).ToLowerInvariant()) {
        '^winget\.exe$' { return 'winget' }
        '^choco\.exe$' { return 'choco' }
        '^msiexec\.exe$' { return 'msiexec' }
        '^avdtune\.bench\.exe$' { return 'bench' }
        default { return 'base' }
    }
}

function Initialize-AVDTuneToolTemp {
    <#
        TEMP of a program AVDTune starts: <state>\temp\<tool>, administrators only. An existing folder is trusted only when it is no link (the folder and the ones above it)
        and has no owner or rule of someone else (Get-AVDTuneStateSecurityProblems on the folder itself); otherwise it is set aside (renamed to <tool>.untrusted-<stamp>, never
        repaired or deleted in place) and a new one is created in one step with the protected ACL. Returns the path.
    #>
    param([Parameter(Mandatory)][ValidateSet('base', 'winget', 'choco', 'msiexec', 'bench', 'office', 'apps', 'host')][string]$Tool, [Parameter(Mandatory)][string]$StateRoot, [scriptblock]$ReadAcl)
    $parent = Initialize-AVDTuneTempParent -StateRoot $StateRoot   # no link on the way, temp created with its protected ACL (#79)
    $dir = Join-Path $parent $Tool
    $info = New-Object IO.DirectoryInfo $dir
    $file = New-Object IO.FileInfo $dir
    if ($info.Exists -or $file.Exists) {
        $bad = $file.Exists -or (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        if (-not $bad) {
            $p = @{ Root = $dir; NoRecurse = $true }
            if ($ReadAcl -and (Test-AVDTuneTestMode).Enabled) { $p.ReadAcl = $ReadAcl; $p.AdminSid = '' }
            $bad = @(Get-AVDTuneStateSecurityProblems @p).Count -gt 0
        }
        # Every run gets a fresh, empty folder (#65): a program may leave rules for the user in it (winget's WinGet folder), which a later elevated run must not
        # inherit. A good folder is renamed to <tool>.used-<stamp> and removed below; a bad one to <tool>.untrusted-<stamp> and kept for a look.
        $kind = if ($bad) { 'untrusted' } else { 'used' }
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
        $aside = Join-Path $parent "$Tool.$kind-$stamp"
        for ($n = 2; (Test-Path -LiteralPath $aside); $n++) { $aside = Join-Path $parent "$Tool.$kind-$stamp-$n" }
        try { if ($file.Exists) { [IO.File]::Move($dir, $aside) } else { [IO.Directory]::Move($dir, $aside) } }   # a rename: nothing inside is opened or followed
        catch { if (-not $bad) { return $dir }; throw }   # in use by a running program of the same tool: that folder was checked and stays admin-only
    }
    Remove-AVDTuneChildTempLeftovers -Parent $parent -Tool $Tool
    New-AVDTuneOwnFolder -Path $dir
    $dir
}

function New-AVDTuneOwnFolderSecurity {
    # The ACL of a folder AVDTune creates for itself: Administrators and SYSTEM only, protected, owner Administrators when elevated. AVDTune runs elevated;
    # a non-elevated process (the checks) also gets its own user, so it does not lock itself out of its own folder.
    $elevated = Test-AVDTuneElevated
    $security = New-AVDTuneStateSecurity -WithOwner:$elevated
    if (-not $elevated) { $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))) }
    $security
}

function Test-AVDTuneOwnFolder {
    <#
        Pure: is this the ACL of a folder AVDTune made for itself (New-AVDTuneOwnFolderSecurity)? Owner $Owner, protected, only allow rules for the SIDs in $Allowed, none inherited,
        not a link. $Acl: Owner (SID), Protected, Rules (@{ Sid; Allow; Inherited }), Link. Returns the problems ('' each), empty when it is ours.
    #>
    param([Parameter(Mandatory)]$Acl, [Parameter(Mandatory)][string]$Owner, [Parameter(Mandatory)][string[]]$Allowed)
    $p = New-Object System.Collections.ArrayList
    if ($Acl.Link) { [void]$p.Add('it is a link') }
    if ($Acl.Owner -ne $Owner) { [void]$p.Add("owner $($Acl.Owner)") }
    if (-not $Acl.Protected) { [void]$p.Add('rules inherited from above') }
    foreach ($r in @($Acl.Rules)) {
        if ($r.Inherited) { [void]$p.Add("inherited rule for $($r.Sid)") }
        elseif (-not $r.Allow) { [void]$p.Add("deny rule for $($r.Sid)") }
        elseif ($Allowed -notcontains $r.Sid) { [void]$p.Add("rule for $($r.Sid)") }
    }
    @($p)
}

function New-AVDTuneOwnFolder {
    <#
        Creates a folder in one step with New-AVDTuneOwnFolderSecurity and reads it back (#54/#79 review B5): DirectoryInfo.Create keeps a folder that someone made first, with his
        owner and rules. Anything but the asked owner (Administrators when elevated, else this user), protection and the own rules throws: stopped, nothing is put into it.
    #>
    param([Parameter(Mandatory)][string]$Path)
    (New-Object IO.DirectoryInfo $Path).Create((New-AVDTuneOwnFolderSecurity))
    $elevated = Test-AVDTuneElevated
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $sec = [IO.Directory]::GetAccessControl($Path)
    $acl = [pscustomobject]@{
        Owner = $sec.GetOwner([Security.Principal.SecurityIdentifier]).Value; Protected = $sec.AreAccessRulesProtected
        Link = (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        Rules = @(foreach ($r in $sec.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) { @{ Sid = $r.IdentityReference.Value; Allow = ($r.AccessControlType -eq 'Allow'); Inherited = $r.IsInherited } })
    }
    $problems = @(Test-AVDTuneOwnFolder -Acl $acl -Owner $(if ($elevated) { 'S-1-5-32-544' } else { $me }) -Allowed $(if ($elevated) { @('S-1-5-32-544', 'S-1-5-18') } else { @('S-1-5-32-544', 'S-1-5-18', $me) }))
    if ($problems.Count -gt 0) { throw "$Path is not AVDTune's own folder after it was created ($($problems -join '; ')): stopped." }
}

function Initialize-AVDTuneTempParent {
    # <state>\temp: the state folder and temp must be no links (throws), temp is created in one step with the protected ACL when missing (#79). Returns the path.
    param([Parameter(Mandatory)][string]$StateRoot)
    $parent = Join-Path $StateRoot 'temp'
    foreach ($c in @($StateRoot, $parent)) {
        $attr = $null; try { $attr = [IO.File]::GetAttributes($c) } catch { continue }
        if ($attr -band [IO.FileAttributes]::ReparsePoint) { throw "A part of the path $c is a link: stopped." }
    }
    if (-not (Test-Path -LiteralPath $parent)) { New-AVDTuneOwnFolder -Path $parent }
    $parent
}

function New-AVDTuneDownloadFolder {
    <#
        A new work folder for downloads and staged copies (#79): <Root>\temp\<Prefix>-<guid> (without -Prefix: <guid>, the staging folder of the updates), created in one
        step with the protected ACL (New-AVDTuneOwnFolderSecurity), never with inherited rights. <Root> and <Root>\temp must be no links. Returns the path.
    #>
    param([Parameter(Mandatory)][string]$Root, [ValidatePattern('^[a-z]{0,20}$')][string]$Prefix = '')
    $parent = Initialize-AVDTuneTempParent -StateRoot $Root
    $name = [guid]::NewGuid().ToString('N'); if ($Prefix) { $name = "$Prefix-$name" }
    $dir = Join-Path $parent $name
    if (Test-Path -LiteralPath $dir) { throw "$dir exists already: stopped." }
    New-AVDTuneOwnFolder -Path $dir
    $dir
}

function New-AVDTuneAdminFile {
    # A new file (CreateNew: an existing one throws) with an explicit admin-only ACL (New-AVDTuneFileSecurity -AdminOnly, #79), open for writing; the caller disposes the stream.
    param([Parameter(Mandatory)][string]$Path)
    New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]'Write, ReadPermissions', [IO.FileShare]::None, 65536, [IO.FileOptions]::None, (New-AVDTuneFileSecurity -AdminOnly))
}

function Set-AVDTuneProcessTemp {
    <#
        TEMP and TMP of this process itself (#54): the elevated AVDTune inherits them from HKCU\Environment, which a non-elevated process of the same administrator
        can set, and [IO.Path]::GetTempPath() and Add-Type (csc writes its sources and the compiled DLL there and loads it) use them. Start-AVDTune.ps1 sets them first to
        the Windows TEMP folder (from GetFolderPath, before any module loads) and, once the state folder is verified, to <state>\temp\host (admin-only, fresh per start,
        Initialize-AVDTuneToolTemp). Returns the path.
    #>
    param([Parameter(Mandatory)][string]$StateRoot)
    $dir = Initialize-AVDTuneToolTemp -Tool host -StateRoot $StateRoot -ReadAcl $(if ((Test-AVDTuneTestMode).Enabled) { $script:ChildEnvHooks.AclReader })
    foreach ($n in 'TEMP', 'TMP') { [Environment]::SetEnvironmentVariable($n, $dir, [EnvironmentVariableTarget]::Process) }
    $dir
}

#region delete through handles (#48)

function Initialize-AVDTuneSafeTree {
    <#
        AVDTune.Native.SafeTree: deletes a tree through handles, never through paths below the root. Why: a path-based delete checks "no link" and then
        deletes by name; in a tree that users can write to (C:\Windows\Temp, WER\ReportQueue, the admin's %TEMP%, folders a tool left with rules for users)
        a user can swap a checked folder for a junction (oplock + \RPC Control symlink) between the check and the delete and turn the elevated delete onto
        any file. Here:
          * the root is opened once (FILE_OPEN_REPARSE_POINT: a link is opened itself) and GetFinalPathNameByHandle must give the same long path: a link
            further up the path refuses the whole call;
          * each entry is opened RELATIVE to the handle of its folder (NtCreateFile with RootDirectory, one name, FILE_OPEN_REPARSE_POINT), so no path is
            parsed again below the root; a folder is held without FILE_SHARE_DELETE (nobody can rename or replace it while it is open);
          * kind, link and link count come from the opened handle (GetFileInformationByHandle), the children are listed through the handle
            (GetFileInformationByHandleEx, FileFullDirectoryInfo);
          * the delete goes through the same handle (SetFileInformationByHandle FileDispositionInfoEx: POSIX semantics, read-only ignored, so no attribute
            of a hard-linked file elsewhere is changed); without POSIX delete (older Windows, other file systems) FileDispositionInfo, and a read-only mark
            is removed only from a file with exactly one link (otherwise Skipped), through a second handle reopened from the first (FILE_WRITE_ATTRIBUTES
            is asked for only there). Known gap of that fallback: the link count can grow after it was read; adding a link needs write access to that
            file, so the cleared mark then reaches only a file its creator could change anyway (docs\safe-delete.md);
          * a link (junction, symlink, any reparse point) is deleted itself and never entered; a folder deeper than MaxDepth levels is left (no stack
            exhaustion by a prepared tree), a folder with more than MaxEntries entries too (TooMany, no unbounded list); an oplock someone holds is not
            waited for (FILE_COMPLETE_IF_OPLOCKED: that entry is left); an entry in use or refused is left and counted.
        Hook (tests only): called with ('listed', folder) after a folder was listed and before its entries are opened, and with ('opened', path) after an
        entry was opened and checked and before it is entered or deleted. A test swaps folders for junctions there.
    #>
    if ('AVDTune.Native.SafeTree' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace AVDTune.Native {
    public sealed class SafeTreeResult { public int Removed; public int Left; public int Skipped; public int TooMany; public bool Gone; }
    public static class SafeTree {
        public static Action<string, string> Hook;
        public static int MaxDepth = 256;
        public static int MaxEntries = 200000;   // per folder; a folder with more is left (TooMany), no unbounded list in memory
        public static bool TestNoPosixDelete;     // tests only: take the path for file systems without POSIX delete

        const uint DELETE = 0x00010000, SYNCHRONIZE = 0x00100000, READ_ATTRIBUTES = 0x80, WRITE_ATTRIBUTES = 0x100, LIST_DIRECTORY = 0x1;
        const uint SHARE_READ = 1, SHARE_WRITE = 2, SHARE_DELETE = 4;
        const uint ATTR_READONLY = 0x1, ATTR_DIRECTORY = 0x10, ATTR_REPARSE = 0x400;
        const uint OPT_DIRECTORY = 0x1, OPT_SYNC = 0x20, OPT_NON_DIRECTORY = 0x40, OPT_COMPLETE_IF_OPLOCKED = 0x100, OPT_OPEN_REPARSE = 0x00200000;
        const uint OBJ_CASE_INSENSITIVE = 0x40, FILE_OPEN = 1;
        const int ST_NOT_A_DIRECTORY = unchecked((int)0xC0000103), ST_FILE_IS_A_DIRECTORY = unchecked((int)0xC00000BA);
        const int ST_OPLOCK_BREAK_IN_PROGRESS = 0x00000108;
        const int ST_NAME_NOT_FOUND = unchecked((int)0xC0000034), ST_PATH_NOT_FOUND = unchecked((int)0xC000003A), ST_DELETE_PENDING = unchecked((int)0xC0000056);

        [StructLayout(LayoutKind.Sequential)] struct UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
        [StructLayout(LayoutKind.Sequential)] struct OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
        [StructLayout(LayoutKind.Sequential)] struct IO_STATUS_BLOCK { public IntPtr Status; public IntPtr Information; }
        [StructLayout(LayoutKind.Sequential)] struct BY_HANDLE_FILE_INFORMATION { public uint FileAttributes; public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime, LastAccessTime, LastWriteTime; public uint VolumeSerialNumber, FileSizeHigh, FileSizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow; }
        [StructLayout(LayoutKind.Sequential)] struct FILE_BASIC_INFO { public long CreationTime, LastAccessTime, LastWriteTime, ChangeTime; public uint FileAttributes, Padding; }
        struct Entry { public string Name; public uint Attributes; }

        [DllImport("ntdll.dll")] static extern int NtCreateFile(out SafeFileHandle handle, uint access, ref OBJECT_ATTRIBUTES oa, out IO_STATUS_BLOCK iosb, IntPtr allocationSize, uint fileAttributes, uint share, uint disposition, uint options, IntPtr eaBuffer, uint eaLength);
        [DllImport("ntdll.dll")] static extern int RtlNtStatusToDosError(int status);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetFileInformationByHandle(SafeFileHandle h, out BY_HANDLE_FILE_INFORMATION info);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetFileInformationByHandleEx(SafeFileHandle h, int infoClass, IntPtr buffer, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetFileInformationByHandle(SafeFileHandle h, int infoClass, ref uint flags, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetFileInformationByHandle(SafeFileHandle h, int infoClass, ref byte delete, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetFileInformationByHandle(SafeFileHandle h, int infoClass, ref FILE_BASIC_INFO info, uint size);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern uint GetFinalPathNameByHandleW(SafeFileHandle h, StringBuilder path, uint size, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern uint GetLongPathNameW(string shortPath, StringBuilder longPath, uint size);

        static void Fire(string stage, string path) { Action<string, string> h = Hook; if (h != null) h(stage, path); }

        // One name, relative to an open folder (root == null: an absolute NT path, used for the root only). An oplock someone holds is not waited for
        // (FILE_COMPLETE_IF_OPLOCKED: no thread of ours stalls in a break an attacker controls); the entry then counts as left.
        static int Open(SafeFileHandle root, string name, bool dir, bool withDelete, out SafeFileHandle h) {
            int st = OpenRaw(root, name, READ_ATTRIBUTES | SYNCHRONIZE | (withDelete ? DELETE : 0) | (dir ? LIST_DIRECTORY : 0),
                // a folder we delete cannot be renamed or replaced while we hold it; a root that is only emptied (C:\Windows\Temp) and every file are shared
                // fully (others may hold them with delete access; everything below is reached through our handle either way)
                (dir && withDelete) ? (SHARE_READ | SHARE_WRITE) : (SHARE_READ | SHARE_WRITE | SHARE_DELETE),
                OPT_SYNC | OPT_OPEN_REPARSE | OPT_COMPLETE_IF_OPLOCKED | (dir ? OPT_DIRECTORY : OPT_NON_DIRECTORY), out h);
            if (st == ST_OPLOCK_BREAK_IN_PROGRESS) { h.Dispose(); h = new SafeFileHandle(IntPtr.Zero, true); }
            return st;
        }

        // The same file once more, with FILE_WRITE_ATTRIBUTES (only for the read-only mark without POSIX delete): an empty name relative to the open handle
        // reopens exactly that object, no path is parsed again
        static int ReopenForAttributes(SafeFileHandle h, out SafeFileHandle w) {
            return OpenRaw(h, "", READ_ATTRIBUTES | WRITE_ATTRIBUTES | SYNCHRONIZE, SHARE_READ | SHARE_WRITE | SHARE_DELETE, OPT_SYNC | OPT_OPEN_REPARSE | OPT_NON_DIRECTORY, out w);
        }

        static int OpenRaw(SafeFileHandle root, string name, uint access, uint share, uint options, out SafeFileHandle h) {
            IntPtr buf = Marshal.StringToHGlobalUni(name);
            IntPtr us = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UNICODE_STRING)));
            bool added = false;
            try {
                UNICODE_STRING u = new UNICODE_STRING(); u.Length = (ushort)(name.Length * 2); u.MaximumLength = (ushort)(name.Length * 2 + 2); u.Buffer = buf;
                Marshal.StructureToPtr(u, us, false);
                if (root != null) root.DangerousAddRef(ref added);
                OBJECT_ATTRIBUTES oa = new OBJECT_ATTRIBUTES();
                oa.Length = Marshal.SizeOf(typeof(OBJECT_ATTRIBUTES)); oa.RootDirectory = root == null ? IntPtr.Zero : root.DangerousGetHandle(); oa.ObjectName = us; oa.Attributes = OBJ_CASE_INSENSITIVE;
                IO_STATUS_BLOCK io;
                return NtCreateFile(out h, access, ref oa, out io, IntPtr.Zero, 0, share, FILE_OPEN, options, IntPtr.Zero, 0);
            }
            finally { if (added) root.DangerousRelease(); Marshal.FreeHGlobal(us); Marshal.FreeHGlobal(buf); }
        }

        static int OpenEntry(SafeFileHandle root, string name, bool asDir, bool withDelete, out SafeFileHandle h) {
            int st = Open(root, name, asDir, withDelete, out h);
            if (st == ST_NOT_A_DIRECTORY || st == ST_FILE_IS_A_DIRECTORY) { h.Dispose(); st = Open(root, name, !asDir, withDelete, out h); }
            return st;
        }

        static List<Entry> List(SafeFileHandle dir, out bool tooMany) {
            tooMany = false;
            List<Entry> list = new List<Entry>();
            const int size = 64 * 1024;
            IntPtr buf = Marshal.AllocHGlobal(size);
            try {
                int infoClass = 15;   // FileFullDirectoryRestartInfo, then FileFullDirectoryInfo
                while (true) {
                    if (!GetFileInformationByHandleEx(dir, infoClass, buf, size)) {
                        int e = Marshal.GetLastWin32Error();
                        if (e == 18) break;   // ERROR_NO_MORE_FILES
                        throw new Win32Exception(e);
                    }
                    infoClass = 14;
                    long off = 0;
                    while (true) {
                        IntPtr p = new IntPtr(buf.ToInt64() + off);
                        int next = Marshal.ReadInt32(p, 0);
                        uint attr = (uint)Marshal.ReadInt32(p, 56);
                        int nameBytes = Marshal.ReadInt32(p, 60);
                        string name = Marshal.PtrToStringUni(new IntPtr(p.ToInt64() + 68), nameBytes / 2);
                        if (name != "." && name != "..") {
                            if (list.Count >= MaxEntries) { tooMany = true; return list; }
                            Entry en = new Entry(); en.Name = name; en.Attributes = attr; list.Add(en);
                        }
                        if (next == 0) break;
                        off += next;
                    }
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
            return list;
        }

        static bool DeleteByHandle(SafeFileHandle h, BY_HANDLE_FILE_INFORMATION info, SafeTreeResult r) {
            if (!TestNoPosixDelete) {
                uint flags = 0x1 | 0x2 | 0x10;   // FILE_DISPOSITION_FLAG_DELETE | POSIX_SEMANTICS | IGNORE_READONLY_ATTRIBUTE
                if (SetFileInformationByHandle(h, 21, ref flags, 4)) return true;
                int e = Marshal.GetLastWin32Error();
                if (e != 87 && e != 50 && e != 1 && e != 124) return false;   // a real refusal (in use, not empty, access denied): not tried another way
            }
            if ((info.FileAttributes & ATTR_READONLY) != 0) {
                // Without POSIX delete the read-only mark must go first, and the mark belongs to every name of the file: only with exactly one link.
                // Known gap (review of #48): the count is read when the entry is opened; a hard link added after that needs write access to this very file,
                // so the cleared mark then only reaches a file its creator could change anyway. With POSIX delete (Windows 10 1809 and later, NTFS) no
                // attribute is changed at all.
                if (info.NumberOfLinks != 1 || (info.FileAttributes & ATTR_DIRECTORY) != 0) { r.Skipped++; return false; }
                SafeFileHandle w;
                if (ReopenForAttributes(h, out w) != 0) { w.Dispose(); return false; }
                using (w) {
                    FILE_BASIC_INFO b = new FILE_BASIC_INFO(); b.FileAttributes = info.FileAttributes & ~ATTR_READONLY; if (b.FileAttributes == 0) b.FileAttributes = 0x80;
                    if (!SetFileInformationByHandle(w, 0, ref b, (uint)Marshal.SizeOf(typeof(FILE_BASIC_INFO)))) return false;
                }
            }
            byte d = 1;
            return SetFileInformationByHandle(h, 4, ref d, 1);
        }

        // Removes what is in an open folder; returns the number of entries still there. depth: level of the folder (0 = root).
        static int ClearDir(SafeFileHandle dir, string display, int depth, SafeTreeResult r) {
            for (int round = 0; round < 3; round++) {
                List<Entry> entries; bool tooMany;
                try { entries = List(dir, out tooMany); } catch (Win32Exception) { if (depth == 0) r.Left++; return 1; }
                if (tooMany) r.TooMany++;
                if (entries.Count == 0) return 0;
                Fire("listed", display);
                int left = 0;
                foreach (Entry e in entries) {
                    bool gone = RemoveEntry(dir, e, display + "\\" + e.Name, depth + 1, r);
                    if (depth == 0) { if (gone) r.Removed++; else r.Left++; }
                    if (!gone) left++;
                }
                if (left > 0) return left;
                if (tooMany) { if (depth == 0) r.Left++; return 1; }   // the rest beyond the limit stays (counted once)
            }
            bool more; int rest; try { rest = List(dir, out more).Count; } catch (Win32Exception) { rest = 1; }   // entries keep coming: leave them
            if (depth == 0) r.Left += rest;
            return rest;
        }

        static bool RemoveEntry(SafeFileHandle parent, Entry e, string display, int depth, SafeTreeResult r) {
            if (depth > MaxDepth) return false;
            SafeFileHandle h;
            int st = OpenEntry(parent, e.Name, (e.Attributes & ATTR_DIRECTORY) != 0, true, out h);
            using (h) {
                if (st == ST_NAME_NOT_FOUND || st == ST_PATH_NOT_FOUND || st == ST_DELETE_PENDING) return true;
                if (st != 0) return false;
                return RemoveOpened(h, display, depth, r);
            }
        }

        static bool RemoveOpened(SafeFileHandle h, string display, int depth, SafeTreeResult r) {
            BY_HANDLE_FILE_INFORMATION info;
            if (!GetFileInformationByHandle(h, out info)) return false;
            bool link = (info.FileAttributes & ATTR_REPARSE) != 0, dir = (info.FileAttributes & ATTR_DIRECTORY) != 0;
            Fire("opened", display);
            if (dir && !link && ClearDir(h, display, depth, r) > 0) return false;
            return DeleteByHandle(h, info, r);
        }

        static string StripPrefix(string s) {
            if (s.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) return @"\\" + s.Substring(8);
            if (s.StartsWith(@"\\?\")) return s.Substring(4);
            return s;
        }

        static string FinalPath(SafeFileHandle h) {
            StringBuilder sb = new StringBuilder(1024);
            uint n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
            if (n >= sb.Capacity) { sb = new StringBuilder((int)n + 1); n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0); }
            if (n == 0) throw new Win32Exception();
            return StripPrefix(sb.ToString());
        }

        static string LongPath(string full) {
            string ext = full.StartsWith(@"\\") ? @"\\?\UNC\" + full.Substring(2) : @"\\?\" + full;
            StringBuilder sb = new StringBuilder(1024);
            uint n = GetLongPathNameW(ext, sb, (uint)sb.Capacity);
            if (n >= sb.Capacity) { sb = new StringBuilder((int)n + 1); n = GetLongPathNameW(ext, sb, (uint)sb.Capacity); }
            return n == 0 ? full : StripPrefix(sb.ToString());
        }

        // contentsOnly: what is IN the folder goes, the folder stays (Removed/Left count its direct entries). Otherwise the folder, file or link itself goes too (Gone).
        public static SafeTreeResult Remove(string path, bool contentsOnly) {
            if (String.IsNullOrEmpty(path)) throw new ArgumentException("No path given.");
            if (path.StartsWith(@"\\?\") || path.StartsWith(@"\\.\") || path.StartsWith(@"\??\")) throw new ArgumentException("Device paths are not accepted: " + path);
            string full = Path.GetFullPath(path).TrimEnd('\\');
            string driveRoot = (Path.GetPathRoot(full) ?? "").TrimEnd('\\');
            if (full.Length <= 3 || String.Equals(full, driveRoot, StringComparison.OrdinalIgnoreCase)) throw new IOException("A drive root is never deleted or cleared: " + path);
            string nt = full.StartsWith(@"\\") ? @"\??\UNC\" + full.Substring(2) : @"\??\" + full;
            SafeTreeResult r = new SafeTreeResult();
            SafeFileHandle h;
            int st = Open(null, nt, true, !contentsOnly, out h);
            if (st == ST_NOT_A_DIRECTORY) {
                h.Dispose();
                if (contentsOnly) throw new IOException(path + " is not a folder.");
                st = Open(null, nt, false, true, out h);
            }
            using (h) {
                if (st == ST_NAME_NOT_FOUND || st == ST_PATH_NOT_FOUND) { r.Gone = !contentsOnly; return r; }
                if (st == ST_OPLOCK_BREAK_IN_PROGRESS) throw new IOException("Cannot open " + path + ": someone holds an oplock on it. Nothing was deleted; try again later.");
                if (st != 0) throw new Win32Exception(RtlNtStatusToDosError(st), "Cannot open " + path + ": " + new Win32Exception(RtlNtStatusToDosError(st)).Message);
                string final = FinalPath(h), expected = LongPath(full);
                if (!String.Equals(final, expected, StringComparison.OrdinalIgnoreCase)) throw new IOException("The path " + path + " has a link in it (it leads to " + final + "): nothing is deleted.");
                BY_HANDLE_FILE_INFORMATION info;
                if (!GetFileInformationByHandle(h, out info)) throw new Win32Exception();
                if (contentsOnly) {
                    if ((info.FileAttributes & ATTR_REPARSE) != 0) throw new IOException("The folder " + path + " is a link: nothing is deleted.");
                    ClearDir(h, full, 0, r);
                    return r;
                }
                r.Gone = RemoveOpened(h, full, 0, r);
                return r;
            }
        }
    }
}
'@
}

function Remove-AVDTuneTreeSafe {
    <#
        Deletes a folder tree, a file or a link through handles (Initialize-AVDTuneSafeTree, #48): a link is removed itself and never followed, nothing below
        the root is opened by path, a link further up the path refuses the call (throws). -ContentsOnly keeps the folder itself (and throws for a link).
        Returns Removed and Left (direct entries of the root), Skipped (read-only files with more than one link, only without POSIX delete), TooMany
        (folders over the entry limit, left) and Gone (the
        root is not there any more). An entry in use stays and counts as Left; it does not throw. The one way to delete in a tree that is not admin-only.
    #>
    param([Parameter(Mandatory)][string]$Path, [switch]$ContentsOnly)
    Initialize-AVDTuneSafeTree
    try { $r = [AVDTune.Native.SafeTree]::Remove($Path, [bool]$ContentsOnly) }
    catch [Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }   # the message of the delete itself, not the wrapper of the call
    [pscustomobject]@{ Removed = $r.Removed; Left = $r.Left; Skipped = $r.Skipped; TooMany = $r.TooMany; Gone = $r.Gone }
}

function Remove-AVDTuneTreeNoFollow {
    # Deletes a folder tree (Remove-AVDTuneTreeSafe: through handles, a link removed as a link, never followed). Returns $true when it is gone.
    param([Parameter(Mandatory)][string]$Path)
    try { (Remove-AVDTuneTreeSafe -Path $Path).Gone } catch { $false }
}

#endregion

function Remove-AVDTuneChildTempLeftovers {
    # Bounded clean-up in <state>\temp: set-aside folders <tool>.untrusted-* beyond the newest two, and (by name, not followed) entries of the tool's own folder
    # not touched for 3 days (download caches and installer leftovers). Failures are ignored (a file in use stays until the next start).
    param([Parameter(Mandatory)][string]$Parent, [Parameter(Mandatory)][string]$Tool, [int]$KeepAside = 2, [int]$StaleDays = 3)
    try {
        $aside = @((New-Object IO.DirectoryInfo $Parent).GetDirectories("$Tool.untrusted-*") | Sort-Object LastWriteTimeUtc -Descending)
        for ($i = $KeepAside; $i -lt $aside.Count; $i++) { [void](Remove-AVDTuneTreeNoFollow -Path $aside[$i].FullName) }
        # folders of earlier runs (Initialize-AVDTuneToolTemp, #65): all removed, a link inside as a link only
        foreach ($u in @((New-Object IO.DirectoryInfo $Parent).GetDirectories("$Tool.used-*"))) { [void](Remove-AVDTuneTreeNoFollow -Path $u.FullName) }
        $own = New-Object IO.DirectoryInfo (Join-Path $Parent $Tool)
        if ($own.Exists -and -not ($own.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $limit = (Get-Date).AddDays(-$StaleDays); $n = 0
            foreach ($c in $own.GetFileSystemInfos()) {
                if (++$n -gt 500) { break }
                if ($c.LastWriteTime -ge $limit) { continue }
                [void](Remove-AVDTuneTreeNoFollow -Path $c.FullName)   # files too: through a handle, no attribute change by name (a hard link would carry it elsewhere)
            }
        }
    }
    catch { }
}

function Get-AVDTuneProfilePath {
    # Profile folder of the user of this token, from HKLM ProfileList (never from user-controlled settings or the environment); the folder API only when the key is missing
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    try { $v = [string](Get-ItemProperty -LiteralPath ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $sid) -ErrorAction Stop).ProfileImagePath; if ($v) { return [Environment]::ExpandEnvironmentVariables($v) } } catch { }
    [Environment]::GetFolderPath('UserProfile')
}

function Get-AVDTuneHklmValue([string]$Name) {
    # ProgramFilesDir / CommonFilesDir (64-bit view) from HKLM
    try { [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion' -Name $Name -ErrorAction Stop).$Name } catch { [Environment]::GetFolderPath('ProgramFiles') }
}

function Get-AVDTuneChildEnvironment {
    <#
        The complete environment of a program AVDTune starts (allowlist; ProcessStartInfo gets it after Clear(), so nothing else is passed on: no DOTNET_*, COR*, __COMPAT_LAYER,
        no variable of the user's profile). Every value comes from Windows (GetFolderPath, HKLM, .NET), never from $env: a process of the same administrator that is not elevated can set
        HKCU\Environment, which an elevated process started from his session inherits (ChocolateyInstall, TEMP, windir, SystemRoot, PATH).
        Profiles by -Tool: base (all), winget (+ USERPROFILE, LOCALAPPDATA, APPDATA, HOMEDRIVE/HOMEPATH from the known folders), choco (+ ChocolateyInstall from HKLM, PATH also has the
        Windows PowerShell folder), msiexec, bench and office (as base; office = the Office Deployment Tool setup.exe, #35), apps (benchmark application starts, #14: Word, Excel and Edge need a profile:
        USERPROFILE from ProfileList in HKLM by the SID of the token, APPDATA and LOCALAPPDATA derived from it, USERNAME, USERDOMAIN, COMPUTERNAME, HOMEDRIVE/HOMEPATH, ProgramW6432, CommonProgramW6432, ALLUSERSPROFILE, PUBLIC). TEMP and TMP are -TempDir (Initialize-AVDTuneToolTemp).
    #>
    param([Parameter(Mandatory)][ValidateSet('base', 'winget', 'choco', 'msiexec', 'bench', 'office', 'apps')][string]$Tool, [Parameter(Mandatory)][string]$TempDir)
    $windows = Get-AVDTuneSystemFolder Windows; $system = Get-AVDTuneSystemFolder System
    $e = [ordered]@{}
    $e['SystemRoot'] = $windows; $e['windir'] = $windows; $e['SystemDrive'] = [IO.Path]::GetPathRoot($windows).TrimEnd('\')
    $e['ProgramData'] = Get-AVDTuneSystemFolder ProgramData
    $e['ProgramFiles'] = Get-AVDTuneSystemFolder ProgramFiles
    $x86 = [Environment]::GetFolderPath('ProgramFilesX86'); if ($x86) { $e['ProgramFiles(x86)'] = $x86 }
    $e['CommonProgramFiles'] = Get-AVDTuneSystemFolder CommonProgramFiles
    $e['COMSPEC'] = Join-Path $system 'cmd.exe'
    $e['PATH'] = $system
    $e['PSModulePath'] = Get-AVDTuneSystemModulePath   # #73: a Windows PowerShell child would otherwise start with the admin's Documents module folder first
    $e['OS'] = 'Windows_NT'
    $cpus = Get-AVDTuneMachineEnvironmentValue -Name NUMBER_OF_PROCESSORS
    $e['NUMBER_OF_PROCESSORS'] = $(if ($cpus -match '^\d{1,4}$') { $cpus } else { [string][Environment]::ProcessorCount })
    foreach ($n in 'PROCESSOR_ARCHITECTURE', 'PROCESSOR_IDENTIFIER', 'PROCESSOR_LEVEL', 'PROCESSOR_REVISION') {
        $v = Get-AVDTuneMachineEnvironmentValue -Name $n
        if ($v) { $e[$n] = $v }
    }
    if (-not $e.Contains('PROCESSOR_ARCHITECTURE')) { $e['PROCESSOR_ARCHITECTURE'] = $(if ([Environment]::Is64BitOperatingSystem) { 'AMD64' } else { 'x86' }) }
    $e['TEMP'] = $TempDir; $e['TMP'] = $TempDir
    if ($Tool -eq 'winget') {
        $profileDir = [Environment]::GetFolderPath('UserProfile')
        $driveRoot = [IO.Path]::GetPathRoot($profileDir).TrimEnd('\')
        $e['USERPROFILE'] = $profileDir
        # derived from the profile folder (from the token), not from the shell folder values in HKCU that a non-elevated process of the same user can change
        $e['LOCALAPPDATA'] = Join-Path $profileDir 'AppData\Local'
        $e['APPDATA'] = Join-Path $profileDir 'AppData\Roaming'
        $e['HOMEDRIVE'] = $driveRoot; $e['HOMEPATH'] = $profileDir.Substring($driveRoot.Length)
    }
    if ($Tool -eq 'apps') {
        $profileDir = Get-AVDTuneProfilePath
        $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $e['USERPROFILE'] = $profileDir
        $e['APPDATA'] = Join-Path $profileDir 'AppData\Roaming'; $e['LOCALAPPDATA'] = Join-Path $profileDir 'AppData\Local'
        $e['ProgramW6432'] = Get-AVDTuneHklmValue 'ProgramFilesDir'; $e['CommonProgramW6432'] = Get-AVDTuneHklmValue 'CommonFilesDir'
        $e['ALLUSERSPROFILE'] = [Environment]::GetFolderPath('CommonApplicationData'); $e['PUBLIC'] = ([Environment]::GetFolderPath('CommonDocuments') -replace '\Documents$', '')
        $bs = [string][char]92
        $at = $who.IndexOf($bs)
        $e['USERNAME'] = $(if ($at -ge 0) { $who.Substring($at + 1) } else { $who }); $e['USERDOMAIN'] = $(if ($at -ge 0) { $who.Substring(0, $at) } else { [Environment]::MachineName })
        $e['COMPUTERNAME'] = [Environment]::MachineName
        $pathRoot = [IO.Path]::GetPathRoot($profileDir)
        $e['HOMEDRIVE'] = $pathRoot.TrimEnd([char]92); $e['HOMEPATH'] = $profileDir.Substring($pathRoot.Length - 1)
    }
    if ($Tool -eq 'choco') {
        $e['ChocolateyInstall'] = Get-AVDTuneChocolateyRoot
        $e['PATH'] = $system + ';' + (Join-Path $system 'WindowsPowerShell\v1.0')
    }
    $e
}

function New-AVDTuneChildStartInfo {
    <#
        The one place that builds the start of a program for AVDTune (issue #47): File and Arguments as data (quoted per argument), UseShellExecute false, no window, redirected output,
        the environment from Get-AVDTuneChildEnvironment (profile by file name) with TEMP/TMP in <state>\temp\<tool> (admin-only, no links). choco also gets --cache-location in that folder.
    #>
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @(), [string]$Tool, [string]$StateRoot)
    if (-not [IO.Path]::IsPathRooted($File)) { throw "A program is started with its full path, not through PATH: $File" }
    if (-not $Tool) { $Tool = Get-AVDTuneChildTool -File $File }
    if (-not $StateRoot) { $StateRoot = $(if ($script:ChildEnvHooks.Root -and (Test-AVDTuneTestMode).Enabled) { $script:ChildEnvHooks.Root } else { Get-AVDTuneRoot }) }
    $temp = Initialize-AVDTuneToolTemp -Tool $Tool -StateRoot $StateRoot -ReadAcl $(if ((Test-AVDTuneTestMode).Enabled) { $script:ChildEnvHooks.AclReader })
    $list = @($Arguments | ForEach-Object { [string]$_ })
    if ($Tool -eq 'choco') { $list += "--cache-location=$temp" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = (@($list | ForEach-Object { ConvertTo-AVDTuneArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables.Clear()
    $clean = Get-AVDTuneChildEnvironment -Tool $Tool -TempDir $temp
    foreach ($k in $clean.Keys) { $psi.EnvironmentVariables[$k] = [string]$clean[$k] }
    $psi
}

function Initialize-AVDTuneProcessJob {
    <#
        AVDTune.Native.ChildJob (#26, #76): a program started inside a job object from its first instruction. CreateProcess with PROC_THREAD_ATTRIBUTE_JOB_LIST (in the job when it is
        made); where Windows refuses the list: made suspended, put into the job, then resumed (it has run no code outside the job). Its own pipes for stdout and stderr, stdin an empty
        pipe, only these three handles inherited (PROC_THREAD_ATTRIBUTE_HANDLE_LIST). The job ends every process of the tree when its last handle is closed (also when AVDTune dies).
    #>
    if ('AVDTune.Native.ChildJob' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System; using System.ComponentModel; using System.IO; using System.Text; using System.Threading; using System.Threading.Tasks; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
namespace AVDTune.Native {
  public sealed class ChildResult { public int ExitCode; public string Output = ""; public string Error = ""; public bool TimedOut; public int ProcessId; public string JobMode = ""; }
  public static class ChildJob {
    [StructLayout(LayoutKind.Sequential)] struct BasicLimit { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinWs, MaxWs; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong a, b, c, d, e, f; }
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimit { public BasicLimit Basic; public IoCounters Io; public UIntPtr ProcessMemory, JobMemory, PeakProcess, PeakJob; }
    [StructLayout(LayoutKind.Sequential)] struct BasicAccounting { public long TotalUserTime, TotalKernelTime, PeriodUserTime, PeriodKernelTime; public uint PageFaults, TotalProcesses, ActiveProcesses, TerminatedProcesses; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct StartupInfo { public int cb; public string lpReserved, lpDesktop, lpTitle; public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags; public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
    [StructLayout(LayoutKind.Sequential)] struct StartupInfoEx { public StartupInfo StartupInfo; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInformation { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int nLength; public IntPtr lpSecurityDescriptor; public int bInheritHandle; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimit info, int length);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(IntPtr job, int infoClass, out BasicAccounting info, int length, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CreatePipe(out IntPtr read, out IntPtr write, ref SecurityAttributes sa, int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetHandleInformation(IntPtr handle, int mask, int flags);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, int flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returnSize);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, string env, string cwd, ref StartupInfoEx si, out ProcessInformation pi);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr handle, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    const uint CREATE_SUSPENDED = 0x4, CREATE_UNICODE_ENVIRONMENT = 0x400, EXTENDED_STARTUPINFO_PRESENT = 0x80000, CREATE_NO_WINDOW = 0x08000000;
    static readonly IntPtr AttrHandleList = (IntPtr)0x20002, AttrJobList = (IntPtr)0x2000D;
    // test hook of the checks: the job list counts as refused, so the second way (suspended, assign, resume) runs
    public static bool ForceSuspendedPath;
    public static IntPtr Create() {
      IntPtr j = CreateJobObject(IntPtr.Zero, null); if (j == IntPtr.Zero) throw new Win32Exception();
      ExtendedLimit l = new ExtendedLimit(); l.Basic.LimitFlags = 0x2000;   // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
      if (!SetInformationJobObject(j, 9, ref l, Marshal.SizeOf(typeof(ExtendedLimit)))) { int e = Marshal.GetLastWin32Error(); CloseHandle(j); throw new Win32Exception(e); }
      return j;
    }
    public static int Active(IntPtr job) { BasicAccounting i; if (!QueryInformationJobObject(job, 1, out i, Marshal.SizeOf(typeof(BasicAccounting)), IntPtr.Zero)) throw new Win32Exception(); return (int)i.ActiveProcesses; }
    public static void Terminate(IntPtr job) { TerminateJobObject(job, 0xFFFFFFFF); }
    public static void Close(IntPtr job) { CloseHandle(job); }
    static void Pipe(out IntPtr ours, out IntPtr theirs, bool theirsWrites) {
      SecurityAttributes sa = new SecurityAttributes(); sa.nLength = Marshal.SizeOf(typeof(SecurityAttributes)); sa.bInheritHandle = 1;
      IntPtr r, w; if (!CreatePipe(out r, out w, ref sa, 0)) throw new Win32Exception();
      ours = theirsWrites ? r : w; theirs = theirsWrites ? w : r;
      if (!SetHandleInformation(ours, 1, 0)) { int e = Marshal.GetLastWin32Error(); CloseHandle(r); CloseHandle(w); throw new Win32Exception(e); }   // our end is not inherited
    }
    static bool TryCreate(string file, string commandLine, string environment, string workDir, IntPtr job, IntPtr[] inherit, bool jobList, out ProcessInformation pi, out int error) {
      pi = new ProcessInformation(); error = 0;
      IntPtr size = IntPtr.Zero; int count = jobList ? 2 : 1;
      InitializeProcThreadAttributeList(IntPtr.Zero, count, 0, ref size);
      IntPtr list = Marshal.AllocHGlobal(size), handles = Marshal.AllocHGlobal(IntPtr.Size * inherit.Length), jobs = Marshal.AllocHGlobal(IntPtr.Size);
      bool made = false;
      try {
        if (!InitializeProcThreadAttributeList(list, count, 0, ref size)) { error = Marshal.GetLastWin32Error(); return false; }
        made = true;
        for (int i = 0; i < inherit.Length; i++) Marshal.WriteIntPtr(handles, i * IntPtr.Size, inherit[i]);
        if (!UpdateProcThreadAttribute(list, 0, AttrHandleList, handles, (IntPtr)(IntPtr.Size * inherit.Length), IntPtr.Zero, IntPtr.Zero)) { error = Marshal.GetLastWin32Error(); return false; }
        if (jobList) {
          Marshal.WriteIntPtr(jobs, job);
          if (!UpdateProcThreadAttribute(list, 0, AttrJobList, jobs, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero)) { error = Marshal.GetLastWin32Error(); return false; }
        }
        StartupInfoEx si = new StartupInfoEx(); si.StartupInfo.cb = Marshal.SizeOf(typeof(StartupInfoEx)); si.StartupInfo.dwFlags = 0x100;   // STARTF_USESTDHANDLES
        si.StartupInfo.hStdInput = inherit[0]; si.StartupInfo.hStdOutput = inherit[1]; si.StartupInfo.hStdError = inherit[2]; si.lpAttributeList = list;
        StringBuilder cmd = new StringBuilder(commandLine);
        if (!CreateProcessW(file, cmd, IntPtr.Zero, IntPtr.Zero, true, CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW, environment, string.IsNullOrEmpty(workDir) ? null : workDir, ref si, out pi)) { error = Marshal.GetLastWin32Error(); return false; }
        return true;
      }
      finally { if (made) DeleteProcThreadAttributeList(list); Marshal.FreeHGlobal(list); Marshal.FreeHGlobal(handles); Marshal.FreeHGlobal(jobs); }
    }
    // Starts file (full path; commandLine starts with the quoted file) with exactly this environment block (k=v\0...\0\0) inside job and waits: for the program, with waitForTree
    // also for every process of the job, at most timeoutMs in all. A timeout ends the whole job; without waitForTree what the program left behind ends with it. Throws when nothing ran.
    public static ChildResult Run(IntPtr job, string file, string commandLine, string environment, string workDir, int timeoutMs, bool waitForTree, Encoding encoding) {
      IntPtr inR = IntPtr.Zero, inW = IntPtr.Zero, outR = IntPtr.Zero, outW = IntPtr.Zero, errR = IntPtr.Zero, errW = IntPtr.Zero;
      ProcessInformation pi = new ProcessInformation(); ChildResult res = new ChildResult();
      try {
        Pipe(out inW, out inR, false); Pipe(out outR, out outW, true); Pipe(out errR, out errW, true);
        IntPtr[] inherit = new IntPtr[] { inR, outW, errW };
        int error;
        if (!ForceSuspendedPath && TryCreate(file, commandLine, environment, workDir, job, inherit, true, out pi, out error)) res.JobMode = "joblist";
        else {
          if (!TryCreate(file, commandLine, environment, workDir, job, inherit, false, out pi, out error)) throw new Win32Exception(error, "The program could not be started: " + new Win32Exception(error).Message);
          if (!AssignProcessToJobObject(job, pi.hProcess)) { int e = Marshal.GetLastWin32Error(); TerminateProcess(pi.hProcess, 0xFFFFFFFF); throw new Win32Exception(e, "The program could not be put into a job object and was ended before it ran: " + new Win32Exception(e).Message); }
          res.JobMode = "suspended";
        }
        res.ProcessId = pi.dwProcessId;
        CloseHandle(inR); inR = IntPtr.Zero; CloseHandle(outW); outW = IntPtr.Zero; CloseHandle(errW); errW = IntPtr.Zero; CloseHandle(inW); inW = IntPtr.Zero;   // stdin: end of file at once
        Encoding enc = encoding ?? Encoding.Default;
        FileStream os = new FileStream(new SafeFileHandle(outR, true), FileAccess.Read, 4096, false); outR = IntPtr.Zero;
        FileStream es = new FileStream(new SafeFileHandle(errR, true), FileAccess.Read, 4096, false); errR = IntPtr.Zero;
        Task<string> outTask = Task.Run(() => { using (StreamReader r = new StreamReader(os, enc)) return r.ReadToEnd(); });
        Task<string> errTask = Task.Run(() => { using (StreamReader r = new StreamReader(es, enc)) return r.ReadToEnd(); });
        if (ResumeThread(pi.hThread) == 0xFFFFFFFF) { int e = Marshal.GetLastWin32Error(); TerminateJobObject(job, 0xFFFFFFFF); throw new Win32Exception(e); }
        System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();
        bool timedOut = WaitForSingleObject(pi.hProcess, (uint)Math.Max(0, timeoutMs)) != 0;
        if (!timedOut && waitForTree) {
          while (Active(job) > 0) { if (clock.ElapsedMilliseconds >= timeoutMs) { timedOut = true; break; } Thread.Sleep(250); }
        }
        if (!timedOut && !waitForTree) { Task.WaitAll(new Task[] { outTask, errTask }, 2000); TerminateJobObject(job, 0xFFFFFFFF); }   // what it left behind ends now (and with it its copies of the pipes)
        if (timedOut) {
          TerminateJobObject(job, 0xFFFFFFFF);
          System.Diagnostics.Stopwatch until = System.Diagnostics.Stopwatch.StartNew();
          while (Active(job) > 0 && until.ElapsedMilliseconds < 30000) Thread.Sleep(100);
          WaitForSingleObject(pi.hProcess, 10000);
        }
        Task.WaitAll(new Task[] { outTask, errTask }, 10000);
        uint code; GetExitCodeProcess(pi.hProcess, out code);
        res.TimedOut = timedOut; res.ExitCode = timedOut ? -1 : unchecked((int)code);
        res.Output = outTask.IsCompleted ? outTask.Result : ""; res.Error = errTask.IsCompleted ? errTask.Result : "";
        return res;
      }
      finally { foreach (IntPtr h in new IntPtr[] { inR, inW, outR, outW, errR, errW, pi.hThread, pi.hProcess }) if (h != IntPtr.Zero) CloseHandle(h); }
    }
  }
}
"@
}

function Invoke-AVDTuneChildProcess {
    <#
        The one place that starts a program and waits for it (#76; Benchmark, Updates/Language, Office, the machine adapter): no shell, no window, output read asynchronously
        (stdout and stderr, so neither pipe can fill up and block it), a timeout, and the process in a job object (kill on close): on a timeout, or when this function ends,
        the whole tree is ended. Fail closed: a job that cannot be made or a process that cannot be put into it means no run (the process is ended).
        -StartInfo: a start built by New-AVDTuneChildStartInfo. Otherwise -FileName (full path) and -Arguments (already quoted); -CleanEnvironment passes only the allowlist
        of Get-AVDTuneChildEnvironment (-Tool) with TEMP/TMP in -TempDir. -WaitForTree: returns only when every process of the tree has ended (a lock held by the caller,
        Global\PackTune for winget and choco, stays held until then); the timeout covers the whole tree. Returns ExitCode (-1 on a timeout), Output, Error, TimedOut.
    #>
    param([Diagnostics.ProcessStartInfo]$StartInfo, [string]$FileName, [string]$Arguments = '', [int]$TimeoutMs = 600000, [switch]$CleanEnvironment, [string]$TempDir,
        [ValidateSet('base', 'bench', 'office', 'apps')][string]$Tool = 'bench', [switch]$WaitForTree)
    if ($StartInfo) { $psi = $StartInfo }
    else {
        if (-not [IO.Path]::IsPathRooted($FileName)) { throw "A program is started with its full path, not through PATH: $FileName" }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FileName; $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        if ($CleanEnvironment) {
            if (-not $TempDir) { throw 'A clean environment needs a TEMP folder.' }
            $psi.EnvironmentVariables.Clear()
            $clean = Get-AVDTuneChildEnvironment -Tool $Tool -TempDir $TempDir
            foreach ($k in $clean.Keys) { $psi.EnvironmentVariables[$k] = [string]$clean[$k] }
        }
    }
    if ($psi.UseShellExecute -or -not $psi.CreateNoWindow -or -not $psi.RedirectStandardOutput -or -not $psi.RedirectStandardError) { throw 'A program is started without shell and window, with its output read.' }
    if (-not [IO.Path]::IsPathRooted($psi.FileName)) { throw "A program is started with its full path, not through PATH: $($psi.FileName)" }
    # the start as Process.Start would make it (quoted file, then the arguments; exactly the environment of the start info), but inside the job from the first instruction (#26)
    $cmdLine = '"' + $psi.FileName + '"' + $(if ($psi.Arguments) { ' ' + $psi.Arguments } else { '' })
    $envBlock = (@(@($psi.EnvironmentVariables.Keys) | Sort-Object | ForEach-Object { "$_=$($psi.EnvironmentVariables[$_])" }) -join "`0") + "`0`0"
    $encoding = $(if ($psi.StandardOutputEncoding) { $psi.StandardOutputEncoding } else { [Console]::OutputEncoding })
    Initialize-AVDTuneProcessJob
    $job = [AVDTune.Native.ChildJob]::Create()
    try {
        $r = [AVDTune.Native.ChildJob]::Run($job, $psi.FileName, $cmdLine, $envBlock, $psi.WorkingDirectory, $TimeoutMs, [bool]$WaitForTree, $encoding)
        [pscustomobject]@{ ExitCode = $r.ExitCode; Output = $r.Output; Error = $r.Error; TimedOut = $r.TimedOut; JobMode = $r.JobMode }
    }
    catch [Management.Automation.MethodInvocationException] { throw "$([IO.Path]::GetFileName($psi.FileName)): $($_.Exception.InnerException.Message)" }
    finally { [AVDTune.Native.ChildJob]::Terminate($job); [AVDTune.Native.ChildJob]::Close($job) }   # nothing of the tree outlives the call
}

function Test-AVDTuneWindowsSignature {
    <#
        Pure: is this the signature of a program of Windows itself (#71)? Valid (Windows programs are catalog-signed: Get-AuthenticodeSignature finds the catalog), signer
        O and CN exactly Microsoft Corporation / Microsoft Windows, issuer O Microsoft Corporation and CN Microsoft Windows Production PCA <year>, and the original file name
        (without .mui) is the file name. $Signature: Status, Subject, Issuer, OriginalFilename. Returns @{ Ok; Reason }.
    #>
    param($Signature, [Parameter(Mandatory)][string]$Name)
    $part = {
        param([string]$Dn, [string]$Key)
        if (-not $Dn) { return '' }
        try { $lines = (New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName($Dn)).Decode([System.Security.Cryptography.X509Certificates.X500DistinguishedNameFlags]::UseNewLines) -split "\r?\n" } catch { return '' }
        $v = @(foreach ($l in $lines) { $i = $l.IndexOf('='); if ($i -gt 0 -and $l.Substring(0, $i).Trim() -ceq $Key) { $l.Substring($i + 1).Trim() } })
        if ($v.Count -eq 1) { $v[0] } else { '' }
    }
    if (-not $Signature -or [string]$Signature.Status -ne 'Valid') { return @{ Ok = $false; Reason = "$Name has no valid signature ($(if ($Signature) { $Signature.Status } else { 'none' }))" } }
    $ok = (& $part $Signature.Subject 'O') -ceq 'Microsoft Corporation' -and (& $part $Signature.Subject 'CN') -ceq 'Microsoft Windows' -and
        (& $part $Signature.Issuer 'O') -ceq 'Microsoft Corporation' -and (& $part $Signature.Issuer 'CN') -cmatch '^Microsoft Windows Production PCA \d{4}( |$)'
    if (-not $ok) { return @{ Ok = $false; Reason = "$Name is not signed by Microsoft Windows (signer '$($Signature.Subject)', issuer '$($Signature.Issuer)')" } }
    $orig = ([string]$Signature.OriginalFilename) -replace '(?i)\.mui$', ''
    if ($orig -ine $Name) { return @{ Ok = $false; Reason = "$Name carries the original file name '$orig'" } }
    @{ Ok = $true; Reason = '' }
}

function Open-AVDTuneSystemProgram {
    <#
        A program of the Windows folder before its start (#71): no link, Windows signature (Test-AVDTuneWindowsSignature), and the file held open for reading without write
        and delete sharing from before the check until the caller disposes the returned stream after the run (no swap in between). Throws with the reason: nothing is started.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $name = [IO.Path]::GetFileName($Path)
    $stream = $null
    try {
        if (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$name is a link" }
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $s = Get-AuthenticodeSignature -LiteralPath $Path
        $orig = ''; try { $orig = [string](Get-Item -LiteralPath $Path).VersionInfo.OriginalFilename } catch { }
        $trust = Test-AVDTuneWindowsSignature -Name $name -Signature ([pscustomobject]@{
                Status = [string]$s.Status; OriginalFilename = $orig
                Subject = $(if ($s.SignerCertificate) { [string]$s.SignerCertificate.Subject } else { '' }); Issuer = $(if ($s.SignerCertificate) { [string]$s.SignerCertificate.Issuer } else { '' })
            })
        if (-not $trust.Ok) { throw $trust.Reason }
        $stream
    }
    catch {
        if ($stream) { $stream.Dispose() }
        throw "$($_.Exception.Message): $name is not started."
    }
}

function Test-AVDTuneSystemProgramPath {
    # $true when $Path lies in the Windows folder (System32 and below): such a program is only started after Open-AVDTuneSystemProgram. The folder is a hook of the checks (test mode only).
    param([Parameter(Mandatory)][string]$Path)
    $win = $(if ($script:ChildEnvHooks.Windows -and (Test-AVDTuneTestMode).Enabled) { $script:ChildEnvHooks.Windows } else { Get-AVDTuneSystemFolder Windows })
    [IO.Path]::GetFullPath($Path).StartsWith(([IO.Path]::GetFullPath($win).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)
}

function Invoke-AVDTuneProgram {
    <#
        Starts a program by its full path with the clean start of New-AVDTuneChildStartInfo through Invoke-AVDTuneChildProcess (#53, #71, #76) and waits for it.
        A program of the Windows folder (dsregcmd, manage-bde, sc, fltmc, reg, klist, ...) is checked first (Open-AVDTuneSystemProgram) and held until it has ended; a failed
        check throws (fail closed). Any other program has been checked by the caller (Test-AVDTuneToolTrust right before). Returns ExitCode and Output (stdout + stderr);
        a timeout ends the whole tree and returns ExitCode -1, Output 'timeout'. Start errors throw.
    #>
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @(), [int]$TimeoutSeconds = 120, [switch]$WaitForTree)
    if (-not [IO.Path]::IsPathRooted($File)) { throw "A program is started with its full path, not through PATH: $File" }
    $full = [IO.Path]::GetFullPath($File)   # one spelling for the check, the hold and the start ('..', trailing dots and spaces resolved)
    $hold = $null
    if (Test-AVDTuneSystemProgramPath -Path $full) {
        # a Windows program only as an .exe (no .cmd/.bat/.com through the command interpreter or another loader), and the start is exactly the file that is held (#71 review B2)
        if ([IO.Path]::GetExtension($full) -ine '.exe') { throw "$([IO.Path]::GetFileName($full)) is not an .exe: a program of the Windows folder only starts as an .exe. It is not started." }
        $hold = Open-AVDTuneSystemProgram -Path $full
    }
    try {
        $psi = New-AVDTuneChildStartInfo -File $full -Arguments $Arguments
        if ($hold -and -not [string]::Equals([IO.Path]::GetFullPath($psi.FileName), $hold.Name, [StringComparison]::OrdinalIgnoreCase)) { throw "$([IO.Path]::GetFileName($full)) to start is not the file that was checked ($($hold.Name)): it is not started." }
        $r = Invoke-AVDTuneChildProcess -StartInfo $psi -TimeoutMs ($TimeoutSeconds * 1000) -WaitForTree:$WaitForTree
        if ($r.TimedOut) { return [pscustomobject]@{ ExitCode = -1; Output = 'timeout' } }
        [pscustomobject]@{ ExitCode = $r.ExitCode; Output = ([string]$r.Output + [string]$r.Error) }
    }
    finally { if ($hold) { $hold.Dispose() } }
}

#endregion

function Move-AVDTuneStateToQuarantine {
    <#
        The real handling of a state folder that someone else prepared. Nothing in that tree is repaired (an elevated recursive icacls follows
        junctions, also with /L, and the tree can change while it runs): a link in place of the root is removed as a link; otherwise the owner
        of the root alone is set to Administrators (no /T) and the root is renamed to AVDTune.untrusted-<yyyyMMdd-HHmmss> next to it. Its
        content is never read again. Returns the new path of the set-aside folder ('' when a link was removed).
    #>
    param([Parameter(Mandatory)][string]$Root, $Problems)
    $dir = New-Object IO.DirectoryInfo $Root
    $file = New-Object IO.FileInfo $Root
    if (-not $dir.Exists -and -not $file.Exists) { return '' }
    if ($dir.Exists -and ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $dir.Delete(); return '' }   # removes the link, not its target
    if ($file.Exists -and ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $file.Delete(); return '' }
    $icacls = Join-Path $(if ($script:ChildEnvHooks.Windows -and (Test-AVDTuneTestMode).Enabled) { Join-Path $script:ChildEnvHooks.Windows 'System32' } else { [Environment]::SystemDirectory }) 'icacls.exe'   # the Windows folder is a hook of the checks (test mode only)
    $ErrorActionPreference = 'Continue'   # icacls writes its refusal to stderr; that must not stop the quarantine
    # root only; a failure is fine, the rename below decides. icacls only after its Windows signature, held until it has ended (#71 review B3); a failed check skips it
    $held = $null
    try { $held = Open-AVDTuneSystemProgram -Path $icacls } catch { }
    if ($held) { try { [void](& $icacls $Root '/setowner' '*S-1-5-32-544' '/C' '/L' '/Q' 2>&1) } catch { } finally { $held.Dispose() } }
    $parent = Split-Path $Root -Parent
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
    $target = Join-Path $parent "$(Split-Path $Root -Leaf).untrusted-$stamp"
    for ($n = 2; Test-Path -LiteralPath $target; $n++) { $target = Join-Path $parent "$(Split-Path $Root -Leaf).untrusted-$stamp-$n" }
    if ($file.Exists) { [IO.File]::Move($Root, $target) }   # a file named like the folder is set aside the same way
    else { [IO.Directory]::Move($Root, $target) }   # a rename on the same volume: nothing inside is opened or followed
    $target
}

function New-AVDTuneProtectedFolder {
    # The real creation of the state folder: created in one step with its protected ACL and owner Administrators (no moment without them)
    param([Parameter(Mandatory)][string]$Root)
    (New-Object IO.DirectoryInfo $Root).Create((New-AVDTuneStateSecurity -WithOwner))
}

function Assert-AVDTuneStateSecurity {
    <#
        Makes sure the state folder is AVDTune's own before anything in it is trusted or loaded (finding 2 b, N1, N2):
          * missing: created in one step with the protected ACL;
          * any problem (foreign owner, foreign explicit rule, link, root not protected; Get-AVDTuneStateSecurityProblems -Final): the whole
            folder is set aside (Move-AVDTuneStateToQuarantine) and a new one is created; nothing of the old content is taken over, so the
            first run starts again. Up to 3 tries (someone may recreate the folder or a link between rename and create), then it throws:
            AVDTune must not start.
        A quarantine goes into logs\security.log of the new folder and is kept for the protocol and the warning (Get-AVDTuneStateSecurityReport).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,
        [scriptblock]$ReadAcl = { param($Path, $IsDirectory) Read-AVDTuneAclInfo -Path $Path -IsDirectory $IsDirectory },
        [scriptblock]$Quarantine = { param($Root, $Problems) Move-AVDTuneStateToQuarantine -Root $Root -Problems $Problems },
        [scriptblock]$CreateRoot = { param($Root) New-AVDTuneProtectedFolder -Root $Root })
    $found = New-Object System.Collections.ArrayList
    $moved = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $left = @()
    for ($try = 0; $try -lt 3; $try++) {
        if (-not (Test-Path -LiteralPath $Root)) {
            try { & $CreateRoot $Root } catch { [void]$errors.Add("create: $($_.Exception.Message)") }
        }
        $left = @(Get-AVDTuneStateSecurityProblems -Root $Root -Final -ReadAcl $ReadAcl)
        if (-not (Test-Path -LiteralPath $Root)) { $left = @([pscustomobject]@{ Path = $Root; Problem = 'could not be created' }) }
        if ($left.Count -eq 0) { break }
        foreach ($p in $left) { [void]$found.Add($p) }
        if (-not (Test-Path -LiteralPath $Root)) { continue }
        try { $q = & $Quarantine $Root $left; [void]$moved.Add($(if ($q) { [string]$q } else { 'link removed' })) } catch { [void]$errors.Add("set aside: $($_.Exception.Message)") }
    }
    if ($found.Count -eq 0) { return [pscustomobject]@{ Quarantined = @(); Problems = @() } }
    $ok = ($left.Count -eq 0)
    $report = [pscustomobject]@{ Repaired = $ok; Quarantined = @($moved); Problems = @($found); Left = @($left); At = (Get-Date).ToString('o'); User = "$env:USERDOMAIN\$env:USERNAME"; Error = ($errors -join '; ') }
    $script:StateSecurityReport = $report
    $text = @($found | Select-Object -First 20 | ForEach-Object { "$($_.Path): $($_.Problem)" }) -join '; '
    $line = '{0} {1} state folder prepared by someone else: {2} problem(s) ({3}); {4}' -f $report.At, $report.User, $found.Count, $text, $(if ($ok) { "set aside as $($moved -join ', '), new folder created, nothing taken over" } else { "NOT solved: $($report.Error)" })
    if ($ok) {
        try {
            $logs = Join-Path $Root 'logs'
            if (-not (Test-Path -LiteralPath $logs)) { New-Item -ItemType Directory -Path $logs -Force | Out-Null }
            [IO.File]::AppendAllText((Join-Path $logs 'security.log'), $line + "`r`n", (New-Object Text.UTF8Encoding $false))
        }
        catch { }
        return $report
    }
    throw "The state folder $Root was prepared by someone else and could not be set aside safely ($(@($left | Select-Object -First 5 | ForEach-Object { "$($_.Path): $($_.Problem)" }) -join '; ')$(if ($report.Error) { "; $($report.Error)" })). AVDTune does not start. Check the folder as administrator."
}

function Get-AVDTuneStateSecurityReport { $script:StateSecurityReport }

function Initialize-AVDTuneState {
    <#
        Creates the folders and the empty state.json / changelog.json when they are not there. With protection (the real folder, or -Protect)
        the folder is AVDTune's own first (Assert-AVDTuneStateSecurity: created with its ACL in one step, a prepared folder set aside), and
        only then anything in it is created or read. Test roots without protection are plain folders.
    #>
    [CmdletBinding()]
    param([string]$Root = (Get-AVDTuneRoot), [switch]$Protect, [scriptblock]$ReadAcl, [scriptblock]$Quarantine, [scriptblock]$CreateRoot)
    $protected = $Protect -or (Test-AVDTuneDefaultRoot $Root)
    if ($protected) {
        $assert = @{ Root = $Root }
        if ($ReadAcl) { $assert.ReadAcl = $ReadAcl }
        if ($Quarantine) { $assert.Quarantine = $Quarantine }
        if ($CreateRoot) { $assert.CreateRoot = $CreateRoot }
        [void](Assert-AVDTuneStateSecurity @assert)
    }
    elseif (-not (Test-Path -LiteralPath $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
    foreach ($sub in 'runs', 'protocols', 'config', 'benchmark', 'logs') {
        $path = Join-Path $Root $sub
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    }
    $statePath = Join-Path $Root 'state.json'
    if (-not (Test-Path -LiteralPath $statePath)) {
        Write-AVDTuneFile $statePath ([ordered]@{
                Schema = $script:StateSchema; ImageVersion = $null; Versions = @(); LastUpdate = $null; LastBenchmark = $null
                UpdateBlock = $null; Sealed = $false; Identity = $null; LastRunId = $null
            } | ConvertTo-Json -Depth 6)
    }
    $changePath = Join-Path $Root 'changelog.json'
    if (-not (Test-Path -LiteralPath $changePath)) {
        Write-AVDTuneFile $changePath ([ordered]@{ Schema = $script:StateSchema; Entries = @() } | ConvertTo-Json -Depth 6)
    }
    $Root
}

function Get-AVDTuneState([string]$Root = (Get-AVDTuneRoot)) {
    $state = Read-AVDTuneJson (Join-Path $Root 'state.json')
    if ($null -eq $state) { throw "No state in $Root (Initialize-AVDTuneState first)." }
    if ([int]$state.Schema -gt $script:StateSchema) { throw "The state in $Root is from a newer AVDTune (schema $($state.Schema))." }
    $state
}

$script:StateLockSeconds = 30   # how long a writer waits for the state lock (a check sets it low)
function Invoke-AVDTuneStateLock {
    # One lock for the whole process (all runspaces of the window and its background jobs): state.json is read, changed and written, and the marker of a change in progress
    # is counted, under it. A named mutex is re-entrant for the same thread, so the helpers below may call each other.
    param([Parameter(Mandatory)][scriptblock]$Block)
    $mutex = New-Object System.Threading.Mutex($false, 'Local\AVDTuneStateFile')
    $got = $false
    try {
        try { $got = $mutex.WaitOne([TimeSpan]::FromSeconds($script:StateLockSeconds)) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if (-not $got) { throw "The state file is in use by another operation of AVDTune for more than $($script:StateLockSeconds) seconds. Try again." }
        & $Block
    }
    finally { if ($got) { try { $mutex.ReleaseMutex() } catch { } }; $mutex.Dispose() }
}

function Get-AVDTuneHolderKey([string]$Root) { try { [IO.Path]::GetFullPath($Root).TrimEnd([char]92).ToLowerInvariant() } catch { $Root } }

function Get-AVDTuneChangeHolders {
    # Who holds the marker of a change in progress in THIS process: managed thread ids per state folder, in a table all runspaces of the process share (a module copy per runspace
    # would count on its own). Call only under Invoke-AVDTuneStateLock.
    $t = [AppDomain]::CurrentDomain.GetData('AVDTune.ChangeHolders')
    if (-not $t) { $t = [hashtable]::Synchronized(@{}); [AppDomain]::CurrentDomain.SetData('AVDTune.ChangeHolders', $t) }
    $t
}

function Set-AVDTuneState {
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][hashtable]$Values)
    Invoke-AVDTuneStateLock { Set-AVDTuneStateUnlocked -Root $Root -Values $Values }
}

function Set-AVDTuneStateUnlocked {
    # Changes single values of state.json: Set-AVDTuneState -Values @{ UpdateBlock = 'On' }
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][hashtable]$Values)
    $state = Get-AVDTuneState $Root
    # The first change of the image version (snapshot gate, #27): the first LastChange of a version also becomes FirstChange, with the snapshot that
    # was confirmed at that moment. A state.json without VersionBaseline is from before #27: the old LastChange then counts as the start of the version
    # (VersionBaseline), so no snapshot from before it becomes valid by mistake.
    $Values = $Values.Clone()
    if ($Values.ContainsKey('LastChange') -and $Values['LastChange']) {
        if (Get-AVDTuneProp $state 'FirstChange') { [void]$Values.Remove('FirstChange') }
        else {
            # the first change is the start of the operation (marker ChangeInProgress), not the moment the end is written (#27, #34)
            $candidate = ConvertTo-AVDTuneUtc $(if ($Values.ContainsKey('FirstChange') -and $Values['FirstChange']) { $Values['FirstChange'] } else { $Values['LastChange'] })
            $marker = ConvertTo-AVDTuneUtc (Get-AVDTuneProp (Get-AVDTuneProp $state 'ChangeInProgress') 'Started')
            if ($marker -and (-not $candidate -or $marker -lt $candidate)) { $candidate = $marker }
            if (-not $candidate) { $candidate = [datetime]::UtcNow }
            $Values['FirstChange'] = $candidate.ToString('o')
            # an older state.json (no VersionBaseline): everything known before the first change (state, run records, change log) is the end of the previous version
            if (-not $state.PSObject.Properties['VersionBaseline']) {
                $known = @(Get-AVDTuneChangeTimes -Root $Root -IgnoreMarker | Where-Object { $_ -lt $candidate })
                $Values['VersionBaseline'] = $(if ($known.Count -gt 0) { (@($known | Sort-Object)[-1]).ToString('o') } else { $null })
            }
            $openGate = Get-AVDTuneWriteGate
            $Values['FirstChangeSnapshotId'] = $(if ($openGate) { [string]$openGate.SnapshotId } else { $null })
            $Values['FirstChangeSnapshotCreated'] = $(if ($openGate -and $openGate.SnapshotCreated) { [string]$openGate.SnapshotCreated } else { $null })
        }
    }
    foreach ($key in $Values.Keys) {
        if ($state.PSObject.Properties[$key]) { $state.$key = $Values[$key] } else { Add-Member -InputObject $state -NotePropertyName $key -NotePropertyValue $Values[$key] }
    }
    Write-AVDTuneFile (Join-Path $Root 'state.json') ($state | ConvertTo-Json -Depth 6)
    $state
}

function Test-AVDTuneImageVersion([string]$Version) { $Version -match $script:ImageVersionPattern }

function Get-AVDTuneNextImageVersion {
    # YYYY.MM.NNN: NNN counts per month, starting at 001
    param([string]$Root = (Get-AVDTuneRoot), [datetime]$Date = (Get-Date))
    $prefix = $Date.ToString('yyyy.MM', [Globalization.CultureInfo]::InvariantCulture)
    $highest = 0
    $state = Get-AVDTuneState $Root
    foreach ($v in @($state.Versions)) {
        if ($v -and ([string]$v.Version) -like "$prefix.*") { $n = [int]($v.Version.Substring(8)); if ($n -gt $highest) { $highest = $n } }
    }
    '{0}.{1:000}' -f $prefix, ($highest + 1)
}

function Start-AVDTuneImageVersion {
    # "Start new version": raises the version, clears the finished mark, keeps the list of versions with their start time
    param([string]$Root = (Get-AVDTuneRoot), [datetime]$Date = (Get-Date), [string]$User)
    # the check of the marker and the write of the new version are one step under the state lock: no writer can start in between (#66)
    Invoke-AVDTuneStateLock {
        Resolve-AVDTuneStaleChange -Root $Root
        $running = Get-AVDTuneChangeMarker -Root $Root
        if ($running -and $running.Live) { throw "AVDTune is changing the master right now (started $($running.Started.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))). Start the new image version when it has finished: a snapshot and the first change of the version must not overlap." }
        $version = Get-AVDTuneNextImageVersion -Root $Root -Date $Date
        $state = Get-AVDTuneState $Root
        $list = @(@($state.Versions) | Where-Object { $_ }) + [pscustomobject]@{ Version = $version; Started = $Date.ToString('o'); User = $User }
        # Snapshot gate (#27): the last change of the version that ends here is the baseline of the new one; the first change of the new version is not there yet
        $baseline = Get-AVDTuneLastChange -Root $Root
        [void](Set-AVDTuneState -Root $Root -Values @{ ImageVersion = $version; Versions = $list; Sealed = $false; VersionBaseline = $(if ($baseline) { $baseline.ToUniversalTime().ToString('o') } else { $null }); FirstChange = $null; FirstChangeSnapshotId = $null })
        # An open gate stays open only when its snapshot is already valid for the new version (made after the last change of the old one); else new snapshot needed
        if (Test-AVDTuneWriteAllowed) {
            # the time comes from state.json (written by the confirmation), and only for the snapshot the open gate was opened with
            $confirmed = Get-AVDTuneProp (Get-AVDTuneState $Root) 'SnapshotGate'
            $created = ConvertTo-AVDTuneUtc (Get-AVDTuneProp $confirmed 'SnapshotCreated')
            $same = ([string](Get-AVDTuneProp $confirmed 'SnapshotId') -ieq [string](Get-AVDTuneWriteGate).SnapshotId)
            if (-not $same -or ($baseline -and (-not $created -or $created -le $baseline.ToUniversalTime().AddMinutes($script:SnapshotClockBufferMinutes)))) { Close-AVDTuneWriteGate }
        }
        $version
    }
}

function Add-AVDTuneRun {
    <#
        One record per run, append only: a record is created with CreateNew and never replaced. $Run needs Id (made here when missing),
        Started, Ended, User, SnapshotId, WhatIf, Results.
    #>
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Run)
    $folder = Join-Path $Root 'runs'
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $id = [string]$Run.Id
    if (-not $id) { $id = (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4); $Run.Id = $id }
    if ($id -notmatch '^[A-Za-z0-9._-]{1,60}$') { throw "Invalid run id '$id'." }
    $path = Join-Path $folder "$id.json"
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)   # throws when the record exists
    try {
        $bytes = (New-Object Text.UTF8Encoding $false).GetBytes(($Run | ConvertTo-Json -Depth 8))
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally { $stream.Dispose() }
    [void](Set-AVDTuneState -Root $Root -Values @{ LastRunId = $id })
    $path
}

function Get-AVDTuneChangeTimes {
    # Every known change of the master as UTC: state.json LastChange, run records (Changed, Reverted or Failed, no dry run), automatic change log entries; the marker of a change in progress counts unless -IgnoreMarker
    param([string]$Root = (Get-AVDTuneRoot), [switch]$IgnoreMarker)
    $times = New-Object System.Collections.ArrayList
    $parse = { param($v) $d = ConvertTo-AVDTuneUtc $v; if ($d) { [void]$times.Add($d) } }
    $state = Read-AVDTuneJson (Join-Path $Root 'state.json')
    & $parse (Get-AVDTuneProp $state 'LastChange')
    if (-not $IgnoreMarker) { & $parse (Get-AVDTuneProp (Get-AVDTuneProp $state 'ChangeInProgress') 'Started') }
    foreach ($run in @(Get-AVDTuneRun -Root $Root)) {
        if (-not $run -or (Get-AVDTuneProp $run 'WhatIf') -or (Get-AVDTuneProp $run 'Kind') -eq 'Environment-Azure') { continue }   # Azure resources have their own journal undo (docs\security-checklist.md)
        if (@(@(Get-AVDTuneProp $run 'Results') | Where-Object { $_ -and (($_.Status -in 'Changed', 'Reverted') -or ($_.Status -eq 'Failed' -and (Get-AVDTuneProp $_ 'Mode') -ne 'Test')) }).Count -gt 0) { & $parse (Get-AVDTuneProp $run 'Ended') }
    }
    foreach ($e in @(Get-AVDTuneChangeLog -Root $Root)) { if ($e.Source -eq 'Step' -and $e.Category -notin 'Snapshot', 'Readiness', 'Benchmark', 'Azure') { & $parse $e.At } }
    $times.ToArray()
}

function Get-AVDTuneChangeMarker {
    # The marker of a change in progress (state.json ChangeInProgress): Started (UTC), Pid, Live (the process still runs). $null when there is none.
    param([string]$Root = (Get-AVDTuneRoot))
    $state = Read-AVDTuneJson (Join-Path $Root 'state.json')
    $m = Get-AVDTuneProp $state 'ChangeInProgress'
    $started = ConvertTo-AVDTuneUtc (Get-AVDTuneProp $m 'Started')
    if (-not $started) { return $null }
    $pidValue = 0; [void][int]::TryParse([string](Get-AVDTuneProp $m 'Pid'), [ref]$pidValue)
    # Live only when it is still that process: PID, start time (a few seconds apart at most) and name match (a reused PID is another process), and the marker is
    # not older than 12 hours (no operation of AVDTune runs that long); a marker without ProcessStart is from nothing we can recognise and counts as gone
    $live = $false
    $pStart = ConvertTo-AVDTuneUtc (Get-AVDTuneProp $m 'ProcessStart'); $pName = [string](Get-AVDTuneProp $m 'ProcessName')
    if ($pidValue -gt 0 -and $pStart -and $pName -and ([datetime]::UtcNow - $started) -lt [TimeSpan]::FromHours(12)) {
        try { $proc = [Diagnostics.Process]::GetProcessById($pidValue); $live = ($proc -and -not $proc.HasExited -and $proc.ProcessName -ieq $pName -and [Math]::Abs(($proc.StartTime.ToUniversalTime() - $pStart).TotalSeconds) -lt 5) } catch { $live = $false }
    }
    [pscustomobject]@{ Started = $started; Pid = $pidValue; Live = $live }
}

function Test-AVDTuneChangeInProgress {
    param([string]$Root = (Get-AVDTuneRoot))
    $m = Get-AVDTuneChangeMarker -Root $Root
    [bool]($m -and $m.Live)
}

function Assert-AVDTuneNoForeignChange {
    # A repair at the start (interrupted finish, maintenance mode, benchmark) first asks the state lock: when another AVDTune process holds a live marker, its
    # operation still runs (it is no crash) and nothing is repaired under it (#49)
    param([string]$Root = (Get-AVDTuneRoot))
    Invoke-AVDTuneStateLock {
        $m = Get-AVDTuneChangeMarker -Root $Root
        if ($m -and $m.Live -and $m.Pid -ne $PID) { throw "Another AVDTune process (ID $($m.Pid), since $($m.Started.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))) is changing the master: its operation still runs. Repair only when it has ended." }
    }
}

function Resolve-AVDTuneStaleChange {
    # A marker whose process is gone (crash): the end of that change is unknown, so the time of this detection counts as its last change; the marker is cleared
    param([string]$Root = (Get-AVDTuneRoot))
    $m = Get-AVDTuneChangeMarker -Root $Root
    if ($m -and -not $m.Live) { [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = [datetime]::UtcNow.ToString('o'); ChangeInProgress = $null }) }
}

function Test-AVDTuneSealed {
    # The current image version is finished (Sealed in state.json, #50): no further change until "Start new version".
    # Fail closed: only a missing field or a real JSON false is open; any other value (a string, a number: written by hand) counts as finished, and a state.json
    # that cannot be read throws (the caller refuses).
    param([string]$Root = (Get-AVDTuneRoot))
    $state = Read-AVDTuneJson (Join-Path $Root 'state.json')
    $v = Get-AVDTuneProp $state 'Sealed'
    if ($null -eq $v) { return $false }
    if ($v -is [bool]) { return $v }
    $true
}

function Assert-AVDTuneNotSealed {
    param([string]$Root = (Get-AVDTuneRoot))
    if (Test-AVDTuneSealed -Root $Root) {
        $v = [string](Get-AVDTuneProp (Read-AVDTuneJson (Join-Path $Root 'state.json')) 'ImageVersion')
        throw "Image version $v is finished: further changes are locked. Start a new version on the Overview first."
    }
}

function Start-AVDTuneChange {
    <#
        Marks the start of an operation that changes the master (snapshot gate, #27/#34): the start becomes the first change of the version and
        a new image version or a snapshot cannot count while it runs. Returns $true when this call is a holder of the marker (pass it to Stop-AVDTuneChange
        in finally); $false for a nested call of the same thread (the outer call holds it). Operations on other threads of this process (the window thread and its
        background runspaces) are counted: the marker stays until the LAST holder has stopped.
        A finished version (Sealed, #50) takes no further change until a new version is started; only the repairs that put back what a crash left lifted
        pass -AllowSealed.
    #>
    param([string]$Root = (Get-AVDTuneRoot), [datetime]$At = (Get-Date), [switch]$AllowSealed)
    Invoke-AVDTuneStateLock {
        Resolve-AVDTuneStaleChange -Root $Root
        $holders = Get-AVDTuneChangeHolders
        $key = Get-AVDTuneHolderKey $Root
        $m = Get-AVDTuneChangeMarker -Root $Root
        $thread = [Threading.Thread]::CurrentThread.ManagedThreadId
        $sealedCheck = { if (-not $AllowSealed) { Assert-AVDTuneNotSealed -Root $Root } }
        if ($m -and $m.Live) {
            if ($m.Pid -ne $PID) { throw "Another AVDTune process (ID $($m.Pid), since $($m.Started.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))) is changing the master. Wait until it has finished." }
            $list = @(@($holders[$key]) | Where-Object { $null -ne $_ })
            if ($list -contains $thread) { return $false }          # nested call of the same thread: the outer one holds the marker
            . $sealedCheck
            $holders[$key] = $list + $thread                        # another thread of this process, or a marker of this process without a known holder: a holder too, the marker stays until it has stopped
            return $true
        }
        . $sealedCheck
        $me = [Diagnostics.Process]::GetCurrentProcess()
        [void](Set-AVDTuneState -Root $Root -Values @{ ChangeInProgress = [ordered]@{ Started = $At.ToUniversalTime().ToString('o'); Pid = $PID; ProcessStart = $me.StartTime.ToUniversalTime().ToString('o'); ProcessName = $me.ProcessName } })
        $holders[$key] = @($thread)
        $true
    }
}

function Stop-AVDTuneChange {
    param([string]$Root = (Get-AVDTuneRoot), [bool]$Owner = $true)
    if (-not $Owner) { return }
    # Stop runs in finally blocks: a lock that cannot be had must not replace the result of the operation. The error is kept for the window (Get-AVDTuneChangeStopError), the marker stays.
    try {
        Invoke-AVDTuneStateLock {
            $holders = Get-AVDTuneChangeHolders
            $key = Get-AVDTuneHolderKey $Root
            $thread = [Threading.Thread]::CurrentThread.ManagedThreadId
            $rest = @(@($holders[$key]) | Where-Object { $null -ne $_ -and $_ -ne $thread })
            if (@($holders[$key]) -contains $thread -and $rest.Count -gt 0) {
                # another holder still works: only the end of this one is stamped, the marker stays
                $holders[$key] = $rest
                [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = [datetime]::UtcNow.ToString('o') })
                return
            }
            # the end is stamped here (also after an abort: a change may have been half done), in the same write that clears the marker; FirstChange comes from the marker still in place.
            # A write that fails after the retries of Move-AVDTuneFileReplace (virus scanner, #58) is not swallowed: the holder of this process is released (a later start
            # takes the marker over), the error goes to the window below, and the marker stays in state.json (fail closed: no new version, no snapshot as the current state).
            try { [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = [datetime]::UtcNow.ToString('o'); ChangeInProgress = $null }) }
            finally { $holders.Remove($key) }
        }
    }
    catch { [AppDomain]::CurrentDomain.SetData('AVDTune.ChangeStopError', "The end of a change could not be recorded: $($_.Exception.Message)") }
}

function Get-AVDTuneChangeStopError {
    # The last error of Stop-AVDTuneChange (read once, then cleared), $null when there is none
    $e = [AppDomain]::CurrentDomain.GetData('AVDTune.ChangeStopError')
    if ($e) { [AppDomain]::CurrentDomain.SetData('AVDTune.ChangeStopError', $null) }
    $e
}

function Get-AVDTuneLastChange {
    <#
        When AVDTune last changed the master (Apply or Undo that changed something), as a local [datetime], or $null when it never did.
        The newest of: state.json LastChange, the end of every run record with a Changed/Reverted result, every automatic change log
        entry (Source Step) except the snapshot confirmations, the readiness analyses and confirmations and the benchmarks (a measurement is no change) (analysis is no change; a fix has the category "Readiness fix").
    #>
    param([string]$Root = (Get-AVDTuneRoot))
    $times = @(Get-AVDTuneChangeTimes -Root $Root)
    if ($times.Count -eq 0) { return $null }
    (@($times | Sort-Object)[-1]).ToLocalTime()
}

# Snapshot gate (#27): a snapshot counts for the current image version when it was made after the last change of the previous version and before the
# first change of this version (the state at the start of the version). The snapshot time comes from Azure, the changes from the clock of this VM:
# a snapshot must be at least this many minutes newer than the last change of the previous version (a VM clock that runs behind Azure cannot make
# an earlier snapshot count) and at least this many minutes older than the first change (a VM clock that runs ahead cannot make a later one count).
$script:SnapshotClockBufferMinutes = 10
function Get-AVDTuneSnapshotClockBufferMinutes { $script:SnapshotClockBufferMinutes }

function ConvertTo-AVDTuneUtc($Value) {
    # A date from state.json (string, or already a [datetime]) as UTC, $null when empty or not a date
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    try { ([datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime() } catch { $null }
}

function Get-AVDTuneSnapshotWindow {
    <#
        Where a snapshot may lie for the current version.
        Lower: the end of the previous version = the newest of VersionBaseline and every change known from before the first change (state, run
        records, change log); $null only when there is proof that nothing ever changed. Without a first change it is the newest change.
        FirstChange: the first change of this version (a change in progress counts from its start), $null as long as there is none.
        FirstChangeSnapshotId / FirstChangeSnapshotCreated: the snapshot confirmed when it began (the exception of the second margin, by ID and creation time).
        InProgress: a change runs right now (no snapshot counts as the current state then). Mode: VersionStart or Reconnect.
    #>
    param([string]$Root = (Get-AVDTuneRoot))
    Resolve-AVDTuneStaleChange -Root $Root
    $state = Get-AVDTuneState $Root
    $last = Get-AVDTuneLastChange -Root $Root
    $marker = Get-AVDTuneChangeMarker -Root $Root
    $first = ConvertTo-AVDTuneUtc (Get-AVDTuneProp $state 'FirstChange')
    if (-not $first -and $marker) { $first = $marker.Started }
    $base = ConvertTo-AVDTuneUtc (Get-AVDTuneProp $state 'VersionBaseline')
    $lastUtc = if ($last) { $last.ToUniversalTime() } else { $null }
    if ($first) {
        $before = @(Get-AVDTuneChangeTimes -Root $Root -IgnoreMarker | Where-Object { $_ -lt $first })
        $candidates = @($before) + $(if ($base) { @($base) } else { @() })
        $lower = if ($candidates.Count -gt 0) { @($candidates | Sort-Object)[-1] } else { $null }
    }
    else { $lower = if ($lastUtc -and $base) { @($lastUtc, $base | Sort-Object)[-1] } elseif ($lastUtc) { $lastUtc } else { $base } }
    $local = { param($d) if ($d) { $d.ToLocalTime() } else { $null } }
    [pscustomobject]@{
        Version = [string](Get-AVDTuneProp $state 'ImageVersion'); Mode = $(if ($first) { 'Reconnect' } else { 'VersionStart' })
        Lower = (& $local $lower); FirstChange = (& $local $first); LastChange = $last; InProgress = [bool]($marker -and $marker.Live)
        FirstChangeSnapshotId = [string](Get-AVDTuneProp $state 'FirstChangeSnapshotId'); FirstChangeSnapshotCreated = (& $local (ConvertTo-AVDTuneUtc (Get-AVDTuneProp $state 'FirstChangeSnapshotCreated')))
    }
}

function Test-AVDTuneSnapshotInWindow {
    <#
        Valid + Reason ('' when valid) + Kind for a finished snapshot (Created from Azure, Id) against Get-AVDTuneSnapshotWindow. Valid is
        (a) the start of the version (after the last change of the previous version plus margin, before the first change of this one minus margin;
        Kind VersionStart) or (b) the current state (after the last change plus the clock margin: it loses nothing; Kind CurrentState; never while
        a change is in progress). After a further change a (b) snapshot is invalid again. Snapshots between the changes of the version are invalid.
        The snapshot that was confirmed when the first change began is exempt from the second margin only: it must carry the same ID and creation
        time (a deleted snapshot whose name is used again does not inherit it) and it obeys the lower bound.
    #>
    param($Created, [string]$Id, $Window)
    $margin = $script:SnapshotClockBufferMinutes
    $no = { param($why) [pscustomobject]@{ Valid = $false; Reason = $why; Kind = '' } }
    $yes = { param($kind) [pscustomobject]@{ Valid = $true; Reason = ''; Kind = $kind } }
    if (-not $Created) { return (& $no 'Azure gave no creation time.') }
    if (-not $Window) { return (& $yes 'VersionStart') }
    $c = ([datetime]$Created).ToUniversalTime()
    if ($Window.Lower -and $c -le ([datetime]$Window.Lower).ToUniversalTime().AddMinutes($margin)) {
        return (& $no "Older than the last change before this version ($(([datetime]$Window.Lower).ToString('yyyy-MM-dd HH:mm'))) plus $margin minutes for clock differences between this VM and Azure: a rollback to it would lose that change.")
    }
    if (-not $Window.FirstChange) { return (& $yes 'VersionStart') }
    $first = ([datetime]$Window.FirstChange).ToUniversalTime()
    $exempt = [bool]($Id -and $Window.FirstChangeSnapshotId -and $Id -ieq $Window.FirstChangeSnapshotId -and $Window.FirstChangeSnapshotCreated -and
        [Math]::Abs(($c - ([datetime]$Window.FirstChangeSnapshotCreated).ToUniversalTime()).TotalSeconds) -lt 2)
    if ($exempt -and $c -lt $first) { return (& $yes 'VersionStart') }
    if ($c -lt $first.AddMinutes(-$margin)) { return (& $yes 'VersionStart') }
    if ($Window.InProgress) { return (& $no "AVDTune is changing the master right now (since $($first.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))): only a snapshot from before the first change of this version counts until it has finished.") }
    if ($Window.LastChange -and $c -gt ([datetime]$Window.LastChange).ToUniversalTime().AddMinutes($margin)) { return (& $yes 'CurrentState') }
    if ($c -lt $first) { return (& $no "Made less than $margin minutes before the first change of this version ($(([datetime]$Window.FirstChange).ToString('yyyy-MM-dd HH:mm'))): a VM clock that runs ahead of Azure could put it after the change.") }
    & $no "Between the changes of this version (first change $(([datetime]$Window.FirstChange).ToString('yyyy-MM-dd HH:mm'))$(if ($Window.LastChange) { ", last change $(([datetime]$Window.LastChange).ToString('yyyy-MM-dd HH:mm'))" })): a rollback to it would lose changes. Valid are snapshots from the start of the version (before the first change) or made after the last change."
}

function Get-AVDTuneRun {
    param([string]$Root = (Get-AVDTuneRoot), [string]$Id)
    $folder = Join-Path $Root 'runs'
    if (-not (Test-Path -LiteralPath $folder)) { return @() }
    $files = Get-ChildItem -LiteralPath $folder -Filter '*.json' -File | Sort-Object Name
    if ($Id) { $files = @($files | Where-Object { $_.BaseName -eq $Id }) }
    @($files | ForEach-Object { Read-AVDTuneJson $_.FullName })
}

$script:RunRecordNamePattern = '^(\d{8}-\d{6})-[0-9a-f]{4}\.json$'
function Remove-AVDTuneOldRuns {
    <#
        Housekeeping of runs\ (#52): every start adds a readiness record and nothing removed them. Only AVDTune's own analysis records are removed: a file named
        like a run id that AVDTune makes (yyyyMMdd-HHmmss-xxxx.json, no link) whose head says Kind Start, Manual or Healthcheck (pure analysis, no change of the
        master; Erstanalyse, fixes and every run with changes stay: they are the history of the versions and their change times). Records that the state
        names (LastRunId, the readiness record, the healthcheck of a version) stay. Of the rest the newest -Keep stay; older than -Days is removed as well.
        Deleted through Remove-AVDTuneTreeSafe (handles, a link is never followed). Returns the number removed; a change log note (no change of the master) when > 0.
    #>
    param([string]$Root = (Get-AVDTuneRoot), [int]$Keep = 200, [int]$Days = 180, [datetime]$Now = (Get-Date), [string]$User)
    $folder = Join-Path $Root 'runs'
    $dir = New-Object IO.DirectoryInfo $folder
    if (-not $dir.Exists -or ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return 0 }
    # under the state lock (#52 review): the names the state holds (LastRunId, readiness, healthchecks) cannot change while the records are chosen and removed
    Invoke-AVDTuneStateLock {
    $state = Read-AVDTuneJson (Join-Path $Root 'state.json')
    $named = @([string](Get-AVDTuneProp $state 'LastRunId'), [string](Get-AVDTuneProp (Get-AVDTuneProp $state 'Readiness') 'RunId')) + @(@(Get-AVDTuneProp $state 'Versions') | Where-Object { $_ } | ForEach-Object { [string](Get-AVDTuneProp $_ 'HealthcheckRunId') })
    $kindRx = New-Object Text.RegularExpressions.Regex('"Plan"\s*:\s*"Readiness analysis \((Start|Manual|Healthcheck)\)"\s*,\s*"Kind"\s*:\s*"(Start|Manual|Healthcheck)"', [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromMilliseconds(200))
    $nameRx = New-Object Text.RegularExpressions.Regex($script:RunRecordNamePattern, [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromMilliseconds(200))
    $candidates = New-Object System.Collections.ArrayList
    foreach ($f in $dir.GetFiles('*.json')) {
        $mName = $nameRx.Match($f.Name)
        if (-not $mName.Success -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $f.BaseName -in $named) { continue }
        $at = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($mName.Groups[1].Value, 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$at)) { continue }
        # only the head is read (Id, Plan and Kind come first): a full parse of hundreds of records would hold the start
        $head = ''
        try { $s = $f.OpenRead(); try { $buf = New-Object byte[] 400; $n = $s.Read($buf, 0, $buf.Length); $head = [Text.Encoding]::UTF8.GetString($buf, 0, $n) } finally { $s.Dispose() } } catch { continue }
        if (-not $kindRx.IsMatch($head)) { continue }
        [void]$candidates.Add([pscustomobject]@{ File = $f; At = $at })
    }
    $sorted = @($candidates | Sort-Object At -Descending)
    $cut = $Now.AddDays(-$Days)
    $removed = 0
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        if ($i -lt $Keep -and $sorted[$i].At -ge $cut) { continue }
        $f = $sorted[$i].File
        try { [void](Remove-AVDTuneTreeSafe -Path $f.FullName) } catch { }   # in use or a link further up: it stays, the next start tries again
        $f.Refresh(); if (-not $f.Exists) { $removed++ }
    }
    $version = [string](Get-AVDTuneProp $state 'ImageVersion')
    if ($removed -gt 0 -and (Test-AVDTuneImageVersion $version)) {
        [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $version -Category 'Housekeeping' -Component 'Run records' -ChangeType Note -Text "$removed old readiness analysis record(s) removed from runs (kept: the newest $Keep of the last $Days days, every record with changes and every record the state names)." -User $User)
    }
    $removed
    }
}

function Get-AVDTuneEnvInterrupted {
    <#
        #45: runs of the environment wizard (config\azure-setup.json) that stopped in the middle: AVDTune or the VM ended between the two journal writes of a step,
        so a step is still Started or the run has no end. The run that this process carries out right now (AppDomain 'AVDTune.EnvApplyRun') is not one.
        Returns RunId, Started and the open steps (Id, Type, Action, Path). Only reads.
    #>
    param([string]$Root = (Get-AVDTuneRoot))
    $j = $null; try { $j = Read-AVDTuneJson (Join-Path $Root 'config\azure-setup.json') } catch { return @() }
    $running = [string][AppDomain]::CurrentDomain.GetData('AVDTune.EnvApplyRun')
    @(foreach ($run in @(Get-AVDTuneProp $j 'Runs')) {
            if (-not $run -or ($running -and [string](Get-AVDTuneProp $run 'RunId') -eq $running)) { continue }
            $open = @(@(Get-AVDTuneProp $run 'Steps') | Where-Object { $_ -and [string](Get-AVDTuneProp $_ 'Status') -eq 'Started' })
            if ($open.Count -eq 0 -and (Get-AVDTuneProp $run 'Ended')) { continue }
            [pscustomobject]@{ RunId = [string](Get-AVDTuneProp $run 'RunId'); Started = [string](Get-AVDTuneProp $run 'Started')
                Steps = @($open | ForEach-Object { [pscustomobject]@{ Id = [string]$_.Id; Type = [string]$_.Type; Action = [string]$_.Action; Path = [string]$_.Path } }) }
        })
}

function Get-AVDTuneEnvHealthRow {
    # The Overview row for an interrupted run of the environment wizard (#45); nothing when there is none
    param([string]$Root = (Get-AVDTuneRoot))
    $runs = @(Get-AVDTuneEnvInterrupted -Root $Root)
    if ($runs.Count -eq 0) { return }
    $what = @($runs | ForEach-Object { $_.Steps } | ForEach-Object { "$($_.Action) $(($_.Path -split '/')[-1]) ($($_.Type))" })
    [pscustomobject]@{ Id = 'envinterrupted'; Title = 'Environment wizard'; Status = 'warn'
        Detail = "A run of the environment wizard stopped in the middle (run $(@($runs | ForEach-Object { $_.RunId }) -join ', '))$(if ($what.Count -gt 0) { ': not confirmed: ' + ($what -join '; ') }). Open the Environment page and make the plan or the undo plan: AVDTune reads the real state of these resources and closes the run; then run the plan again or take it back." }
}

#endregion

#region write gate

# The snapshot gate (AVDTune.Snapshot.psm1) opens this when a snapshot newer than the last change of AVDTune is confirmed by name. Until then the engine refuses every
# change of the master (Apply and Undo without -WhatIf); reading and dry runs always work. The gate is held in memory only: a new
# start of AVDTune starts closed.
$script:WriteGate = $null

# A block (integrity check of the tool failed, AVDTune.Release.psm1) keeps the gate shut and closes it when it is open: AVDTune is read only until the
# tool is repaired and started again. Only the integrity check sets it; there is no function that lifts it inside a running process on purpose.
$script:WriteBlock = $null
function Set-AVDTuneWriteBlock([string]$Reason) { $script:WriteBlock = $Reason; $script:WriteGate = $null }
function Clear-AVDTuneWriteBlock { $script:WriteBlock = $null }
function Get-AVDTuneWriteBlock { $script:WriteBlock }

function Open-AVDTuneWriteGate {
    param([Parameter(Mandatory)][string]$SnapshotId, [Parameter(Mandatory)][string]$ConfirmedBy, [string]$SnapshotCreated)
    if ($script:WriteBlock) { throw "AVDTune is read only: $($script:WriteBlock)" }
    $script:WriteGate = [pscustomobject]@{ SnapshotId = $SnapshotId; SnapshotCreated = $SnapshotCreated; ConfirmedBy = $ConfirmedBy; At = (Get-Date).ToString('o') }
}
function Close-AVDTuneWriteGate { $script:WriteGate = $null }
function Get-AVDTuneWriteGate { $script:WriteGate }
function Test-AVDTuneWriteAllowed { $null -ne $script:WriteGate -and -not $script:WriteBlock }

#endregion

#region steps

function New-AVDTuneStep {
    <#
        A step is data plus small scriptblocks that only talk to the machine adapter ($m).
          Test  { param($m) @{ Compliant = $true/$false; State = <what was found> } }   (a plain $true/$false works too)
          Apply { param($m) ... }       makes the machine compliant; the engine tests before and after
          Undo  { param($m) ... }       optional
    #>
    param(
        [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][string]$Title,
        [string]$Why, [ValidateSet('Low', 'Medium', 'High')][string]$Risk = 'Low', [bool]$Reboot = $false, [string]$SourceUrl,
        [Parameter(Mandatory)][scriptblock]$Test, [Parameter(Mandatory)][scriptblock]$Apply, [scriptblock]$Undo
    )
    if ($Id -notmatch '^[a-z0-9]+(\.[a-z0-9-]+)+$') { throw "Step id '$Id' must look like section.name (lower case)." }
    if ($Section -notin $script:StepSections) { throw "Unknown section '$Section'." }
    if ($SourceUrl -and $SourceUrl -notmatch '^https://') { throw "The source of step $Id must be an https URL." }
    [pscustomobject]@{ Id = $Id; Section = $Section; Title = $Title; Why = $Why; Risk = $Risk; Reboot = $Reboot; SourceUrl = $SourceUrl; Test = $Test; Apply = $Apply; Undo = $Undo }
}

function ConvertTo-AVDTuneTestResult($Raw) {
    if ($Raw -is [bool]) { return [pscustomobject]@{ Compliant = $Raw; State = $null } }
    if ($Raw -is [System.Collections.IDictionary]) { return [pscustomobject]@{ Compliant = [bool]$Raw['Compliant']; State = $Raw['State'] } }
    if ($null -ne $Raw -and $Raw.PSObject.Properties['Compliant']) { return [pscustomobject]@{ Compliant = [bool]$Raw.Compliant; State = $Raw.State } }
    throw 'A step test must return $true/$false or @{ Compliant; State }.'
}

function Invoke-AVDTuneStep {
    <#
        Mode Test:  Compliant | NonCompliant | Failed
        Mode Apply: Unchanged (already compliant) | Changed | Failed (after the change the test still fails) | WhatIf (would change)
        Mode Undo:  Reverted | Unchanged | NoUndo | Failed | WhatIf
        Before and After are the states found by the test. Nothing is changed with -WhatIf.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Step, [Parameter(Mandatory)]$Machine, [ValidateSet('Test', 'Apply', 'Undo')][string]$Mode = 'Test', [switch]$WhatIf)
    if (($Mode -in 'Apply', 'Undo') -and -not $WhatIf -and -not (Test-AVDTuneWriteAllowed)) {
        throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot newer than its last change is confirmed on the Overview.'
    }
    $started = & $Machine.Now
    $result = [ordered]@{
        Id = $Step.Id; Section = $Step.Section; Title = $Step.Title; Mode = $Mode; Status = 'Failed'; Before = $null; After = $null; Message = ''
        Reboot = $false; WhatIf = [bool]$WhatIf; At = $started.ToString('o')
    }
    try {
        $before = ConvertTo-AVDTuneTestResult (& $Step.Test $Machine)
        $result.Before = $before.State
        switch ($Mode) {
            'Test' { $result.Status = if ($before.Compliant) { 'Compliant' } else { 'NonCompliant' } }
            'Apply' {
                if ($before.Compliant) { $result.Status = 'Unchanged'; $result.After = $before.State }
                elseif ($WhatIf) { $result.Status = 'WhatIf'; $result.Message = 'Would change.' }
                else {
                    [void](& $Step.Apply $Machine)
                    $after = ConvertTo-AVDTuneTestResult (& $Step.Test $Machine)
                    $result.After = $after.State
                    if ($after.Compliant) { $result.Status = 'Changed'; $result.Reboot = [bool]$Step.Reboot }
                    else { $result.Status = 'Failed'; $result.Message = 'The test still fails after Apply.' }
                }
            }
            'Undo' {
                if (-not $Step.Undo) { $result.Status = 'NoUndo'; $result.Message = 'This step has no undo.' }
                elseif (-not $before.Compliant) { $result.Status = 'Unchanged'; $result.After = $before.State; $result.Message = 'The step was not applied.' }
                elseif ($WhatIf) { $result.Status = 'WhatIf'; $result.Message = 'Would undo.' }
                else {
                    [void](& $Step.Undo $Machine)
                    $after = ConvertTo-AVDTuneTestResult (& $Step.Test $Machine)
                    $result.After = $after.State
                    if (-not $after.Compliant) { $result.Status = 'Reverted'; $result.Reboot = [bool]$Step.Reboot }
                    else { $result.Status = 'Failed'; $result.Message = 'The test still passes after Undo.' }
                }
            }
        }
    }
    catch { $result.Status = 'Failed'; $result.Message = $_.Exception.Message }
    [pscustomobject]$result
}

function New-AVDTuneStepFromData {
    <#
        Declarative steps (AVDTune\steps\*.json) for the usual cases, so most steps need no scriptblock:
          Kind Registry        Path, Name, Value, Type (DWord/String/...)         Undo: Previous (value) or remove when absent
          Kind ServiceStartup  Name, Startup (Disabled/Manual/Automatic)
          Kind TaskDisabled    TaskPath, TaskName
    #>
    param([Parameter(Mandatory)]$Data)
    function P([string]$n) { Get-AVDTuneProp $Data $n }
    $common = @{ Id = [string](P Id); Section = [string](P Section); Title = [string](P Title); Why = [string](P Why); Risk = $(if (P Risk) { [string](P Risk) } else { 'Low' }); Reboot = [bool](P Reboot); SourceUrl = [string](P SourceUrl) }
    switch ([string](P Kind)) {
        'Registry' {
            $path = [string](P Path); $name = [string](P Name); $want = P Value; $type = $(if (P Type) { [string](P Type) } else { 'DWord' })
            if ($path -notmatch '^(HKLM|HKCU):[\\]') { throw "Step $(P Id): registry path must start with HKLM: or HKCU: and a backslash" }
            $previous = P Previous
            $test = { param($m) $v = & $m.RegGet $path $name; @{ Compliant = ($null -ne $v -and [string]$v -eq [string]$want); State = $v } }.GetNewClosure()
            $apply = { param($m) & $m.RegSet $path $name $want $type }.GetNewClosure()
            $undo = { param($m) if ($null -ne $previous) { & $m.RegSet $path $name $previous $type } else { & $m.RegRemove $path $name } }.GetNewClosure()
        }
        'ServiceStartup' {
            $name = [string](P Name); $startup = [string](P Startup); $previous = [string](P Previous)
            $test = { param($m) $s = & $m.ServiceGet $name; if (-not $s) { @{ Compliant = $true; State = 'absent' } } else { @{ Compliant = ($s.StartType -eq $startup); State = $s.StartType } } }.GetNewClosure()
            $apply = { param($m) & $m.ServiceSetStartup $name $startup }.GetNewClosure()
            $undo = { param($m) if ($previous) { & $m.ServiceSetStartup $name $previous } }.GetNewClosure()
        }
        'TaskDisabled' {
            $taskPath = [string](P TaskPath); $taskName = [string](P TaskName)
            $test = { param($m) $t = & $m.TaskGet $taskPath $taskName; if (-not $t) { @{ Compliant = $true; State = 'absent' } } else { @{ Compliant = (-not $t.Enabled); State = $(if ($t.Enabled) { 'enabled' } else { 'disabled' }) } } }.GetNewClosure()
            $apply = { param($m) & $m.TaskSetEnabled $taskPath $taskName $false }.GetNewClosure()
            $undo = { param($m) & $m.TaskSetEnabled $taskPath $taskName $true }.GetNewClosure()
        }
        default { throw "Step $(P Id): unknown kind '$($Data.Kind)'." }
    }
    New-AVDTuneStep @common -Test $test -Apply $apply -Undo $undo
}

function Get-AVDTuneStepCatalog {
    # All steps of a folder with *.json files (each a step or an array of steps); duplicate ids are an error
    param([Parameter(Mandatory)][string]$Path)
    $steps = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    foreach ($file in Get-ChildItem -LiteralPath $Path -Filter '*.json' -File | Sort-Object Name) {
        # PowerShell 5.1 hands a json array over as one object: flatten it
        foreach ($item in @(Read-AVDTuneJson $file.FullName)) {
            foreach ($data in @($item)) {
                $step = New-AVDTuneStepFromData $data
                if ($steps.Contains($step.Id)) { throw "Step id '$($step.Id)' is defined twice ($($file.Name))." }
                $steps[$step.Id] = $step
            }
        }
    }
    @($steps.Values)
}

function Invoke-AVDTune {
    <#
        Runs a plan (an object or a .json file: { Name, Steps = [ids] }) against a machine: dry run with -WhatIf, otherwise Apply.
        Stops at the first failed step (the rest is Skipped). Writes one run record, an automatic change log entry for every
        change, and returns the run. With -WhatIf nothing is written at all.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][object[]]$Catalog, $Machine = (New-AVDTuneMachine),
        [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId, [switch]$WhatIf
    )
    if ($Plan -is [string]) { $Plan = Read-AVDTuneJson $Plan }
    $byId = @{}; foreach ($s in $Catalog) { $byId[$s.Id] = $s }
    $selected = @(@($Plan.Steps) | ForEach-Object { [string]$_ })
    foreach ($id in $selected) { if (-not $byId.ContainsKey($id)) { throw "The plan names the unknown step '$id'." } }
    $started = & $Machine.Now
    $changeOwner = $false; if (-not $WhatIf) { $changeOwner = Start-AVDTuneChange -Root $Root }   # marker: the first change of the version starts here, no new version or snapshot counts while it runs (#27)
    try {
    $results = New-Object System.Collections.ArrayList
    $stopped = $false
    foreach ($id in $selected) {
        $step = $byId[$id]
        if ($stopped) {
            [void]$results.Add([pscustomobject]@{ Id = $id; Section = $step.Section; Title = $step.Title; Mode = 'Apply'; Status = 'Skipped'; Before = $null; After = $null; Message = 'An earlier step failed.'; Reboot = $false; WhatIf = [bool]$WhatIf; At = $null })
            continue
        }
        $r = Invoke-AVDTuneStep -Step $step -Machine $Machine -Mode Apply -WhatIf:$WhatIf
        [void]$results.Add($r)
        if ($r.Status -eq 'Failed') { $stopped = $true }
    }
    $run = [pscustomobject][ordered]@{
        Id = $null; Plan = [string]$Plan.Name; Started = $started.ToString('o'); Ended = ((& $Machine.Now).ToString('o')); User = $User; SnapshotId = $SnapshotId
        WhatIf = [bool]$WhatIf; ImageVersion = $null; Reboot = [bool](@($results | Where-Object { $_.Reboot }).Count); Results = @($results)
    }
    if (-not $WhatIf) {
        $state = Get-AVDTuneState $Root
        $run.ImageVersion = $state.ImageVersion
        [void](Add-AVDTuneRun -Root $Root -Run $run)
        # The last change AVDTune made on the master: a snapshot only counts when it is newer (snapshot gate)
        if (@($results | Where-Object { $_.Status -in 'Changed', 'Reverted', 'Failed' }).Count -gt 0) { [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = $run.Ended; FirstChange = $run.Started }) }   # a failed step may have changed part of it
        foreach ($r in @($results | Where-Object { $_.Status -eq 'Changed' })) {
            $step = $byId[$r.Id]
            if ($state.ImageVersion) {
                [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category $step.Section -Component $step.Id -ChangeType Changed -Text $step.Title -User $User -SnapshotId $SnapshotId -RunId $run.Id -Source Step)
            }
        }
    }
    $run
    }
    finally { Stop-AVDTuneChange -Root $Root -Owner $changeOwner }
}

#endregion

#region change log

function Remove-AVDTuneControlCharacters([string]$Text, [int]$MaxLength) {
    # Free text of the change log: single line, no control characters, limited length. Secrets are cleaned by the caller (protocol cleaner).
    if (-not $Text) { return '' }
    $clean = [regex]::Replace($Text, '[\x00-\x1F\x7F]+', ' ').Trim()
    if ($clean.Length -gt $MaxLength) { $clean = $clean.Substring(0, $MaxLength - 3) + '...' }
    $clean
}

function Add-AVDTuneChangeLogEntry {
    <#
        One entry of the change log (Version, date, category, component, change type, text, user, snapshot, run).
        Source is Step (automatic) or Note (free note of the administrator).
    #>
    [CmdletBinding()]
    param(
        [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Category, [string]$Component,
        [Parameter(Mandatory)][string]$ChangeType, [Parameter(Mandatory)][string]$Text, [string]$User, [string]$SnapshotId, [string]$RunId,
        [ValidateSet('Step', 'Note')][string]$Source = 'Note', [datetime]$At = (Get-Date)
    )
    if (-not (Test-AVDTuneImageVersion $Version)) { throw "Invalid image version '$Version' (YYYY.MM.NNN)." }
    if ($ChangeType -notin $script:ChangeTypes) { throw "Unknown change type '$ChangeType' ($($script:ChangeTypes -join ', '))." }
    $path = Join-Path $Root 'changelog.json'
    $log = Read-AVDTuneJson $path
    if ($null -eq $log) { $log = [pscustomobject]@{ Schema = $script:StateSchema; Entries = @() } }
    $entry = [pscustomobject][ordered]@{
        Id = [guid]::NewGuid().ToString('N').Substring(0, 12); Version = $Version; At = $At.ToString('o')
        Category = (Remove-AVDTuneControlCharacters $Category 40); Component = (Remove-AVDTuneControlCharacters $Component 80); ChangeType = $ChangeType
        Text = (Remove-AVDTuneControlCharacters $Text 500); User = (Remove-AVDTuneControlCharacters $User 80); SnapshotId = (Remove-AVDTuneControlCharacters $SnapshotId 300)
        RunId = (Remove-AVDTuneControlCharacters $RunId 60); Source = $Source; ToolVersion = $script:ToolVersion
    }
    $log.Entries = @(@($log.Entries) | Where-Object { $_ }) + $entry
    Write-AVDTuneFile $path ($log | ConvertTo-Json -Depth 6)
    $entry
}

function Get-AVDTuneChangeLog {
    param([string]$Root = (Get-AVDTuneRoot), [string]$Version)
    $log = Read-AVDTuneJson (Join-Path $Root 'changelog.json')
    if ($null -eq $log) { return @() }
    $entries = @(@($log.Entries) | Where-Object { $_ })
    if ($Version) { $entries = @($entries | Where-Object { $_.Version -eq $Version }) }
    @($entries | Sort-Object { [datetime]$_.At })
}

function Get-AVDTuneChangeLogVersions {
    # Versions that have entries or were started, newest first
    param([string]$Root = (Get-AVDTuneRoot))
    $names = @(@(Get-AVDTuneChangeLog -Root $Root) | ForEach-Object { [string]$_.Version })
    $state = Get-AVDTuneState $Root
    $names += @(@($state.Versions) | Where-Object { $_ } | ForEach-Object { [string]$_.Version })
    if ($state.ImageVersion) { $names += [string]$state.ImageVersion }
    @($names | Where-Object { $_ } | Sort-Object -Unique -Descending)
}

function ConvertTo-AVDTuneHtmlText([string]$Text) { [Net.WebUtility]::HtmlEncode($Text) }

function ConvertTo-AVDTuneChangeLogDocument {
    # The change log of one version as Markdown or as a self-contained HTML page (all text encoded)
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Version, [ValidateSet('Markdown', 'Html')][string]$Format = 'Markdown', [string]$ImageName)
    $entries = @(Get-AVDTuneChangeLog -Root $Root -Version $Version)
    $title = if ($ImageName) { "Change log $ImageName $Version" } else { "Change log $Version" }
    $header = 'Date', 'Category', 'Component', 'Change', 'Text', 'User'
    $rows = @($entries | ForEach-Object {
            , @(([datetime]$_.At).ToString('yyyy-MM-dd HH:mm'), [string]$_.Category, [string]$_.Component, [string]$_.ChangeType, [string]$_.Text, [string]$_.User)
        })
    if ($Format -eq 'Markdown') {
        $out = New-Object System.Collections.Generic.List[string]
        $out.Add("# $title"); $out.Add('')
        if ($rows.Count -eq 0) { $out.Add('No entries.') }
        else {
            $out.Add('| ' + ($header -join ' | ') + ' |'); $out.Add('|' + (('---|') * $header.Count))
            foreach ($row in $rows) { $out.Add('| ' + (@($row | ForEach-Object { ([string]$_).Replace('|', '\|') }) -join ' | ') + ' |') }
        }
        return (($out -join "`r`n") + "`r`n")
    }
    $html = New-Object System.Text.StringBuilder
    [void]$html.AppendLine('<!DOCTYPE html>')
    [void]$html.AppendLine('<html lang="en"><head><meta charset="utf-8"><title>' + (ConvertTo-AVDTuneHtmlText $title) + '</title>')
    [void]$html.AppendLine('<style>body{font-family:"Segoe UI",sans-serif;margin:32px;color:#1b1b1b}table{border-collapse:collapse;width:100%}th,td{border-bottom:1px solid #e5e5e5;padding:8px 10px;text-align:left;vertical-align:top}th{background:#f3f3f3}</style></head><body>')
    [void]$html.AppendLine('<h1>' + (ConvertTo-AVDTuneHtmlText $title) + '</h1>')
    if ($rows.Count -eq 0) { [void]$html.AppendLine('<p>No entries.</p>') }
    else {
        [void]$html.AppendLine('<table><thead><tr>' + (@($header | ForEach-Object { '<th>' + (ConvertTo-AVDTuneHtmlText $_) + '</th>' }) -join '') + '</tr></thead><tbody>')
        foreach ($row in $rows) { [void]$html.AppendLine('<tr>' + (@($row | ForEach-Object { '<td>' + (ConvertTo-AVDTuneHtmlText ([string]$_)) + '</td>' }) -join '') + '</tr>') }
        [void]$html.AppendLine('</tbody></table>')
    }
    [void]$html.AppendLine('</body></html>')
    $html.ToString()
}

function Export-AVDTuneChangeLog {
    # Writes the document (UTF-8 with BOM, opens in every editor) and returns the path
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Path, [ValidateSet('Markdown', 'Html')][string]$Format, [string]$ImageName)
    if (-not $Format) { $Format = if ($Path -match '\.html?$') { 'Html' } else { 'Markdown' } }
    $text = ConvertTo-AVDTuneChangeLogDocument -Root $Root -Version $Version -Format $Format -ImageName $ImageName
    $folder = Split-Path $Path -Parent
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding $true))
    $Path
}

#endregion

#region overview

$script:OfficeChannels = @{
    '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current Channel'
    '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Current Channel (Preview)'
    '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Monthly Enterprise Channel'
    '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Semi-Annual Enterprise Channel'
    'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Beta Channel'
}

function Get-AVDTuneWindowsInfo {
    param([Parameter(Mandatory)]$Machine)
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [string](& $Machine.RegGet $key 'CurrentBuildNumber')
    $ubr = & $Machine.RegGet $key 'UBR'
    $edition = [string](& $Machine.RegGet $key 'EditionID')
    $display = [string](& $Machine.RegGet $key 'DisplayVersion')
    $product = [string](& $Machine.RegGet $key 'ProductName')
    # ProductName still says "Windows 10" on Windows 11: the build number decides
    $family = 'Windows'
    if ($build -match '^\d+$') { $family = if ([int]$build -ge 22000) { 'Windows 11' } else { 'Windows 10' } }
    $kind = switch ($edition) { 'ServerRdsh' { 'Enterprise multi-session' } 'Enterprise' { 'Enterprise' } 'Professional' { 'Pro' } default { $edition } }
    $name = (@($family, $kind) | Where-Object { $_ }) -join ' '
    if (-not $name) { $name = $product }
    [pscustomobject]@{
        Name = $name; Edition = $edition; DisplayVersion = $display; Build = $build; Ubr = $(if ($null -ne $ubr) { [string]$ubr } else { '' })
        FullBuild = $(if ($build) { if ($null -ne $ubr) { "$build.$ubr" } else { $build } } else { '' })
        MultiSession = ($edition -eq 'ServerRdsh')
    }
}

function Get-AVDTuneOfficeInfo {
    param([Parameter(Mandatory)]$Machine)
    $key = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $version = & $Machine.RegGet $key 'VersionToReport'
    if (-not $version) { return [pscustomobject]@{ Installed = $false; Build = ''; Channel = ''; Platform = ''; SharedLicensing = $false; UpdatesEnabled = $null } }
    $cdn = [string](& $Machine.RegGet $key 'CDNBaseUrl')
    $channel = ''
    if ($cdn -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\s*$') { $channel = $script:OfficeChannels[$Matches[1].ToLowerInvariant()] }
    if (-not $channel) { $channel = 'unknown channel' }
    $updates = & $Machine.RegGet $key 'UpdatesEnabled'
    [pscustomobject]@{
        Installed = $true; Build = [string]$version; Channel = $channel; Platform = [string](& $Machine.RegGet $key 'Platform')
        SharedLicensing = ([string](& $Machine.RegGet $key 'SharedComputerLicensing') -eq '1'); UpdatesEnabled = $(if ($null -ne $updates) { ([string]$updates).ToUpperInvariant() -eq 'TRUE' } else { $null })
    }
}

function Get-AVDTuneSourceImage {
    <#
        The image this master was created from, read from the instance metadata (Azure only). A marketplace image shows
        publisher:offer:sku:version, a gallery or managed image its resource name.
    #>
    param([Parameter(Mandatory)]$Machine)
    $imds = & $Machine.Imds
    if (-not $imds -or -not (Get-AVDTuneProp $imds 'compute')) { return [pscustomobject]@{ Available = $false; Text = ''; VmName = ''; ResourceGroup = ''; Location = ''; VmSize = ''; OsDisk = '' } }
    $c = $imds.compute
    $profile = Get-AVDTuneProp $c 'storageProfile'
    $ref = Get-AVDTuneProp $profile 'imageReference'
    $text = ''
    if ($ref) {
        if ((Get-AVDTuneProp $ref 'publisher') -and (Get-AVDTuneProp $ref 'offer')) { $text = '{0}:{1}:{2}:{3}' -f $ref.publisher, $ref.offer, (Get-AVDTuneProp $ref 'sku'), (Get-AVDTuneProp $ref 'version') }
        elseif (Get-AVDTuneProp $ref 'id') { $text = [string]$ref.id; $parts = $text.TrimEnd('/') -split '/'; if ($parts.Count -ge 2) { $text = $parts[-1] } }
    }
    $disk = [string](Get-AVDTuneProp (Get-AVDTuneProp $profile 'osDisk') 'name')
    [pscustomobject]@{
        Available = $true; Text = $text; VmName = [string](Get-AVDTuneProp $c 'name'); ResourceGroup = [string](Get-AVDTuneProp $c 'resourceGroupName')
        Location = [string](Get-AVDTuneProp $c 'location'); VmSize = [string](Get-AVDTuneProp $c 'vmSize'); OsDisk = $disk
    }
}

function Get-AVDTuneHealth {
    <#
        Health checks of the Overview. Status: ok, warn, bad, info. "Must not be" items (AVD agent, join) are bad when present:
        a master with an agent or a join cannot be finished.
    #>
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$State, $UpdateBlock)
    $rows = New-Object System.Collections.ArrayList
    function Add-Health($Id, $Title, $Status, $Detail) { [void]$rows.Add([pscustomobject]@{ Id = $Id; Title = $Title; Status = $Status; Detail = $Detail }) }

    $pending = New-Object System.Collections.ArrayList
    if (& $Machine.RegKeyExists 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { [void]$pending.Add('servicing') }
    if (& $Machine.RegKeyExists 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { [void]$pending.Add('Windows Update') }
    $rename = & $Machine.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations'
    if ($rename -and @($rename).Count -gt 0) { [void]$pending.Add('file operations') }
    if ($pending.Count -gt 0) { Add-Health 'reboot' 'Restart pending' 'warn' ('Waiting for a restart: ' + ($pending -join ', ') + '.') } else { Add-Health 'reboot' 'Restart pending' 'ok' 'No restart is waiting.' }

    # UpdateBlock is the live status of Get-AVDTuneUpdateBlockStatus (AVDTune.UpdateBlock.psm1) when the caller has it, else only what the state remembers
    $maint = Get-AVDTuneProp $State 'Maintenance'
    if ($maint -and (Get-AVDTuneProp $maint 'Active')) {
        Add-Health 'updateblock' 'Update block for users' 'bad' 'Maintenance mode was interrupted: the update block is lifted or only partly back. Repair it on the Update block page.'
    }
    elseif ($UpdateBlock) {
        $expected = [string]$State.UpdateBlock
        if ($UpdateBlock.State -eq 'On') { Add-Health 'updateblock' 'Update block for users' 'ok' ('On: ' + $UpdateBlock.Compliant + ' of ' + $UpdateBlock.Applicable + ' settings are in place, users see and run no updates.') }
        elseif ($expected -eq 'On') { Add-Health 'updateblock' 'Update block for users' 'bad' ('Changed from outside: only ' + $UpdateBlock.Compliant + ' of ' + $UpdateBlock.Applicable + ' settings are in place (' + $UpdateBlock.Missing + '). Switch the block on again.') }
        elseif ($UpdateBlock.State -eq 'Partial') { Add-Health 'updateblock' 'Update block for users' 'warn' ('Partly on: ' + $UpdateBlock.Compliant + ' of ' + $UpdateBlock.Applicable + ' settings. Switch the block on before Finish.') }
        else { Add-Health 'updateblock' 'Update block for users' 'warn' 'Off: users can see and run updates. Switch the block on before Finish.' }
    }
    else {
        switch ([string]$State.UpdateBlock) {
            'On' { Add-Health 'updateblock' 'Update block for users' 'ok' 'On: users see and run no updates (maintenance mode off).' }
            'Off' { Add-Health 'updateblock' 'Update block for users' 'warn' 'Off: maintenance mode, updates are possible. Switch the block on before Finish.' }
            default { Add-Health 'updateblock' 'Update block for users' 'info' 'Not set up yet.' }
        }
    }
    if ($State.Sealed) { Add-Health 'sealed' 'Finish' 'info' 'Finished: the master is ready for capture.' } else { Add-Health 'sealed' 'Finish' 'info' 'Not finished.' }

    $agent = @('RDAgentBootLoader' | Where-Object { & $Machine.ServiceGet $_ })
    $agentKey = & $Machine.RegKeyExists 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent'
    if ($agent.Count -gt 0 -or $agentKey) { Add-Health 'avdagent' 'AVD agent' 'bad' 'The AVD agent is installed. It must not be on the master: the host pool installs it on the session hosts.' }
    else { Add-Health 'avdagent' 'AVD agent' 'ok' 'Not installed (as it should be on a master).' }

    $dsreg = $null
    try { $dsreg = & $Machine.Run (Join-Path (Get-AVDTuneSystemFolder System) 'dsregcmd.exe') @('/status') } catch { }
    if ($dsreg -and $dsreg.ExitCode -eq 0 -and $dsreg.Output) {
        $entra = $dsreg.Output -match '(?im)^\s*AzureAdJoined\s*:\s*YES'
        $domain = $dsreg.Output -match '(?im)^\s*DomainJoined\s*:\s*YES'
        $joined = @(); if ($entra) { $joined += 'Microsoft Entra ID' }; if ($domain) { $joined += 'a domain' }
        if ($joined.Count -gt 0) { Add-Health 'join' 'Join' 'bad' ('Joined to ' + ($joined -join ' and ') + '. A master must not be joined (sysprep).') }
        else { Add-Health 'join' 'Join' 'ok' 'Not joined to a domain or Microsoft Entra ID.' }
    }
    else { Add-Health 'join' 'Join' 'warn' 'The join state could not be read (dsregcmd).' }
    @($rows)
}

function Get-AVDTuneBenchmarkHealthRow([string]$Root) {
    # An open restore journal at the start: a benchmark was interrupted and Windows Update or the indexer may still be paused
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'benchmark\restore.json'))) { return @() }
    [pscustomobject]@{ Id = 'benchmark'; Title = 'Benchmark'; Status = 'bad'; Detail = 'A benchmark did not end properly: Windows Update or the indexer may still be paused. Restore them on the Benchmark page.' }
}

function Get-AVDTuneOverview {
    # Everything the Overview page shows, from the machine adapter and the state
    param([Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot), $UpdateBlock)
    $state = Get-AVDTuneState $Root
    $source = Get-AVDTuneSourceImage $Machine
    [pscustomobject]@{
        ComputerName = [string](& $Machine.ComputerName)
        ImageVersion = $(if ($state.ImageVersion) { [string]$state.ImageVersion } else { '' })
        SourceImage = $source
        Windows = Get-AVDTuneWindowsInfo $Machine
        Office = Get-AVDTuneOfficeInfo $Machine
        LastUpdate = $(if ($state.LastUpdate) { [string]$state.LastUpdate } else { '' })
        LastBenchmark = $(if ($state.LastBenchmark) { [string]$state.LastBenchmark } else { '' })
        Health = @(@(Get-AVDTuneHealth $Machine $state $UpdateBlock) + @(Get-AVDTuneBenchmarkHealthRow $Root) + @(Get-AVDTuneEnvHealthRow $Root))
        UpdateBlock = $(if ($UpdateBlock) { [string]$UpdateBlock.State } else { [string]$state.UpdateBlock })
        Sealed = [bool]$state.Sealed
    }
}

#endregion

Export-ModuleMember -Function Test-AVDTunePrivateIp, Get-AVDTuneBenchUserLeftovers, Remove-AVDTuneBenchUserLeftover, Move-AVDTuneFileReplace, Get-AVDTuneDcFromNtDomain, Get-AVDTuneSystemFolder, Get-AVDTuneSystemModulePath, Set-AVDTuneSafeModulePath, Test-AVDTuneModulePathStable, Assert-AVDTuneModulePathStable, Get-AVDTuneModulePathProblems, New-AVDTunePowerShell, New-AVDTuneRunspacePool, Get-AVDTuneChocolateyRoot, Get-AVDTuneChildTool, Initialize-AVDTuneToolTemp, Get-AVDTuneChildEnvironment, Get-AVDTuneProfilePath, Get-AVDTuneHklmValue, New-AVDTuneChildStartInfo, Invoke-AVDTuneChildProcess, Invoke-AVDTuneProgram, Open-AVDTuneSystemProgram, New-AVDTuneDownloadFolder, New-AVDTuneOwnFolder, Test-AVDTuneOwnFolder, New-AVDTuneAdminFile, Set-AVDTuneProcessTemp, Initialize-AVDTuneTempParent, Test-AVDTuneWindowsSignature, Test-AVDTuneSystemProgramPath, Get-AVDTuneProp, Get-AVDTuneWebResponse, Test-AVDTuneElevated, Get-AVDTuneRoot, Test-AVDTuneDefaultRoot, Test-AVDTuneTestMode, Resolve-AVDTuneTestScript, Get-AVDTuneLongPath, Get-AVDTuneTestModeRefusal, Confirm-AVDTuneAction, ConvertTo-AVDTuneArgument, New-AVDTuneMachine, Invoke-AVDTuneMachine, Invoke-AVDTuneDefaultHiveUnload, Remove-AVDTuneTreeSafe,
    New-AVDTuneStateSecurity, Initialize-AVDTuneState, Read-AVDTuneAclInfo, Get-AVDTuneStateSecurityProblems, Move-AVDTuneStateToQuarantine, New-AVDTuneProtectedFolder, Assert-AVDTuneStateSecurity, Get-AVDTuneStateSecurityReport, Get-AVDTuneState, Set-AVDTuneState, Test-AVDTuneImageVersion, Get-AVDTuneNextImageVersion, Start-AVDTuneImageVersion,
    Add-AVDTuneRun, Get-AVDTuneRun, Remove-AVDTuneOldRuns, Get-AVDTuneEnvInterrupted, Get-AVDTuneEnvHealthRow, Get-AVDTuneLastChange, Get-AVDTuneChangeTimes, Get-AVDTuneChangeMarker, Invoke-AVDTuneStateLock, Get-AVDTuneChangeStopError, Test-AVDTuneSealed, Assert-AVDTuneNotSealed, Test-AVDTuneChangeInProgress, Assert-AVDTuneNoForeignChange, Resolve-AVDTuneStaleChange, Start-AVDTuneChange, Stop-AVDTuneChange, Get-AVDTuneSnapshotClockBufferMinutes, ConvertTo-AVDTuneUtc, Get-AVDTuneSnapshotWindow, Test-AVDTuneSnapshotInWindow,New-AVDTuneStep, Invoke-AVDTuneStep, New-AVDTuneStepFromData, Get-AVDTuneStepCatalog, Invoke-AVDTune,
    Add-AVDTuneChangeLogEntry, Get-AVDTuneChangeLog, Get-AVDTuneChangeLogVersions, ConvertTo-AVDTuneChangeLogDocument, Export-AVDTuneChangeLog,
    Get-AVDTuneWindowsInfo, Get-AVDTuneOfficeInfo, Get-AVDTuneSourceImage, Get-AVDTuneHealth, Get-AVDTuneOverview, Write-AVDTuneFile, Read-AVDTuneJson,
    Open-AVDTuneWriteGate, Close-AVDTuneWriteGate, Set-AVDTuneWriteBlock, Clear-AVDTuneWriteBlock, Get-AVDTuneWriteBlock, Get-AVDTuneWriteGate, Test-AVDTuneWriteAllowed, Remove-AVDTuneControlCharacters, ConvertTo-AVDTuneTestResult,
    Read-AVDTuneAclReport, Get-AVDTuneAclProblems, Get-AVDTuneAclFindings, New-AVDTuneUsersReadSecurity, New-AVDTuneFileSecurity, Write-AVDTuneAccessFile, Get-AVDTuneTaskInfoFromXml
