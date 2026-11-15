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
$script:StepSections = @('Setup', 'Updates', 'Software', 'Office', 'Optimization', 'FSLogix', 'AppMasking', 'VdiComponents', 'UserExperience', 'UpdateBlock', 'Benchmark', 'Seal')
$script:StepModes = @('Test', 'Apply', 'Undo')

#region elevation, root

function Get-AVDTuneProp($Object, [string]$Name) {
    # Optional property of parsed json: $null when it is not there (strict mode would throw)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

function Test-AVDTuneElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$script:RootWarned = $false
function Get-AVDTuneRoot {
    [CmdletBinding()] param()
    # AVDTUNE_ROOT is a test hook: honoured only together with AVDTUNE_FAKE (fake machine). Alone it is ignored with a warning, so an
    # environment variable set by someone else cannot move the state (and the WebView2 DLLs) of the elevated tool to a folder he controls.
    $default = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'AVDTune'
    if ($env:AVDTUNE_ROOT) {
        if ($env:AVDTUNE_FAKE) { return $env:AVDTUNE_ROOT }
        if (-not $script:RootWarned) { $script:RootWarned = $true; Write-Warning "AVDTUNE_ROOT is ignored without AVDTUNE_FAKE (test mode only); the state stays in $default." }
    }
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
        Protected, Rules = allow rules with Sid, Write (any right that changes content, permissions or owner) and Inherited. A missing path
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
                [pscustomobject]@{ Sid = [string]$_.IdentityReference.Value; Write = ((([int]$_.FileSystemRights) -band $writeMask) -ne 0); Inherited = [bool]$_.IsInherited }
            })
    }
}

function Get-AVDTuneAclProblems {
    # Why a path is not safe for something that users read or run: a link, an owner other than Administrators/SYSTEM/TrustedInstaller, write access for anyone else. Empty = fine.
    param($Report, [string[]]$ExtraTrusted = @())
    $p = New-Object System.Collections.ArrayList
    if (-not $Report -or -not $Report.Exists) { return @() }
    $trusted = @($script:TrustedWriterSids) + @($ExtraTrusted)
    if ($Report.Link) { [void]$p.Add('is a link') }
    if ($Report.Owner -and $Report.Owner -notin $trusted) { [void]$p.Add("owner is $($Report.Owner)") }
    $other = @($Report.Rules | Where-Object { $_.Write -and $_.Sid -notin $trusted } | ForEach-Object { $_.Sid } | Sort-Object -Unique)
    if ($other.Count -gt 0) { [void]$p.Add("write access for $($other -join ', ')") }
    @($p)
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
        (CreateNew, temp name) with the explicit protected ACL of New-AVDTuneFileSecurity, an existing file is deleted and the new one moved
        into place, and the result is checked again with Get-AVDTuneAclProblems (a file that fails is removed again and the call throws).
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
    $temp = "$Path.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($Text)
    try {
        $stream = New-Object IO.FileStream($temp, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]'Write, ReadPermissions', [IO.FileShare]::None, 4096, [IO.FileOptions]::None, (New-AVDTuneFileSecurity))
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        if ($Access -eq 'AdminNew') { [IO.File]::Move($temp, $Path) }
        else { if (Test-Path -LiteralPath $Path) { [IO.File]::Delete($Path) }; [IO.File]::Move($temp, $Path) }
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
        $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $s) { return $null }
        [pscustomobject]@{ Name = $s.Name; Status = [string]$s.Status; StartType = [string]$s.StartType }
    }
    $m.ServiceSetStartup = { param($Name, $Startup) Set-Service -Name $Name -StartupType $Startup }
    $m.ServiceStop = { param($Name) Stop-Service -Name $Name -Force }
    $m.ServiceStart = { param($Name) Start-Service -Name $Name }
    $m.TaskGet = {
        param($Path, $Name)
        $t = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction SilentlyContinue
        if (-not $t) { return $null }
        [pscustomobject]@{ Path = $t.TaskPath; Name = $t.TaskName; Enabled = ($t.State -ne 'Disabled') }
    }
    $m.TaskList = {
        # Names of the tasks directly in a folder (for tasks whose name carries a GUID, like the Edge update tasks)
        param($Path)
        @(Get-ScheduledTask -TaskPath $Path -ErrorAction SilentlyContinue | ForEach-Object { $_.TaskName })
    }
    $m.TaskSetEnabled = {
        param($Path, $Name, $Enabled)
        if ($Enabled) { Enable-ScheduledTask -TaskPath $Path -TaskName $Name | Out-Null } else { Disable-ScheduledTask -TaskPath $Path -TaskName $Name | Out-Null }
    }
    $m.Run = {
        # File and arguments are separate; the command line is built here with quoting per argument, never from free text
        param($File, [string[]]$Arguments, [int]$TimeoutSeconds = 120)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $File
        $psi.Arguments = (@($Arguments | ForEach-Object { ConvertTo-AVDTuneArgument ([string]$_) }) -join ' ')
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) { try { $p.Kill() } catch { }; return [pscustomobject]@{ ExitCode = -1; Output = 'timeout' } }
        [pscustomobject]@{ ExitCode = $p.ExitCode; Output = ($out.Result + $err.Result) }
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
    $m.FileRemove = { param($Path) if (Test-Path -LiteralPath $Path -PathType Leaf) { Remove-Item -LiteralPath $Path -Force } }
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
    [pscustomobject]$m
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

function Write-AVDTuneFile {
    # Written next to the target with an explicit protected admin-only ACL (CreateNew), then moved over it: a crash leaves the old or the new file,
    # never half of one, and the file never keeps an ACL that was there before (File.Replace would keep it)
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $folder = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $temp = "$Path.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($Text)
    try {
        $stream = New-Object IO.FileStream($temp, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]'Write, ReadPermissions', [IO.FileShare]::None, 4096, [IO.FileOptions]::None, (New-AVDTuneFileSecurity -AdminOnly))
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        if (Test-Path -LiteralPath $Path) { [IO.File]::Delete($Path) }
        [IO.File]::Move($temp, $Path)
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
        [string]$AdminSid = $(if (Test-AVDTuneElevated) { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } else { '' }))
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
        if ($isDir) {
            try { foreach ($child in $item.GetFileSystemInfos()) { $queue.Enqueue($child) } }
            catch { [void]$problems.Add([pscustomobject]@{ Path = $item.FullName; Problem = "content cannot be listed: $($_.Exception.Message)" }) }
        }
    }
    @($problems)
}

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
    $icacls = Join-Path ([Environment]::SystemDirectory) 'icacls.exe'
    $ErrorActionPreference = 'Continue'   # icacls writes its refusal to stderr; that must not stop the quarantine
    try { [void](& $icacls $Root '/setowner' '*S-1-5-32-544' '/C' '/L' '/Q' 2>&1) } catch { }   # root only; a failure is fine, the rename below decides
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

function Set-AVDTuneState {
    # Changes single values of state.json: Set-AVDTuneState -Values @{ UpdateBlock = 'On' }
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][hashtable]$Values)
    $state = Get-AVDTuneState $Root
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
    $version = Get-AVDTuneNextImageVersion -Root $Root -Date $Date
    $state = Get-AVDTuneState $Root
    $list = @(@($state.Versions) | Where-Object { $_ }) + [pscustomobject]@{ Version = $version; Started = $Date.ToString('o'); User = $User }
    [void](Set-AVDTuneState -Root $Root -Values @{ ImageVersion = $version; Versions = $list; Sealed = $false })
    $version
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

function Get-AVDTuneLastChange {
    <#
        When AVDTune last changed the master (Apply or Undo that changed something), as a local [datetime], or $null when it never did.
        The newest of: state.json LastChange, the end of every run record with a Changed/Reverted result, every automatic change log
        entry (Source Step) except the snapshot confirmations, the readiness analyses and confirmations and the benchmarks (a measurement is no change) (analysis is no change; a fix has the category "Readiness fix").
    #>
    param([string]$Root = (Get-AVDTuneRoot))
    $times = New-Object System.Collections.ArrayList
    $parse = { param($v) if ($v) { try { [void]$times.Add(([datetime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()) } catch { } } }
    $state = Read-AVDTuneJson (Join-Path $Root 'state.json')
    & $parse (Get-AVDTuneProp $state 'LastChange')
    foreach ($run in @(Get-AVDTuneRun -Root $Root)) {
        if (-not $run -or (Get-AVDTuneProp $run 'WhatIf')) { continue }
        if (@(@(Get-AVDTuneProp $run 'Results') | Where-Object { $_ -and $_.Status -in 'Changed', 'Reverted' }).Count -gt 0) { & $parse (Get-AVDTuneProp $run 'Ended') }
    }
    foreach ($e in @(Get-AVDTuneChangeLog -Root $Root)) { if ($e.Source -eq 'Step' -and $e.Category -notin 'Snapshot', 'Readiness', 'Benchmark') { & $parse $e.At } }
    if ($times.Count -eq 0) { return $null }
    (@($times | Sort-Object)[-1]).ToLocalTime()
}

function Get-AVDTuneRun {
    param([string]$Root = (Get-AVDTuneRoot), [string]$Id)
    $folder = Join-Path $Root 'runs'
    if (-not (Test-Path -LiteralPath $folder)) { return @() }
    $files = Get-ChildItem -LiteralPath $folder -Filter '*.json' -File | Sort-Object Name
    if ($Id) { $files = @($files | Where-Object { $_.BaseName -eq $Id }) }
    @($files | ForEach-Object { Read-AVDTuneJson $_.FullName })
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
    param([Parameter(Mandatory)][string]$SnapshotId, [Parameter(Mandatory)][string]$ConfirmedBy)
    if ($script:WriteBlock) { throw "AVDTune is read only: $($script:WriteBlock)" }
    $script:WriteGate = [pscustomobject]@{ SnapshotId = $SnapshotId; ConfirmedBy = $ConfirmedBy; At = (Get-Date).ToString('o') }
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
        if (@($results | Where-Object { $_.Status -in 'Changed', 'Reverted' }).Count -gt 0) { [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = $run.Ended }) }
        foreach ($r in @($results | Where-Object { $_.Status -eq 'Changed' })) {
            $step = $byId[$r.Id]
            if ($state.ImageVersion) {
                [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category $step.Section -Component $step.Id -ChangeType Changed -Text $step.Title -User $User -SnapshotId $SnapshotId -RunId $run.Id -Source Step)
            }
        }
    }
    $run
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
    try { $dsreg = & $Machine.Run 'dsregcmd.exe' @('/status') } catch { }
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
        Health = @(@(Get-AVDTuneHealth $Machine $state $UpdateBlock) + @(Get-AVDTuneBenchmarkHealthRow $Root))
        UpdateBlock = $(if ($UpdateBlock) { [string]$UpdateBlock.State } else { [string]$state.UpdateBlock })
        Sealed = [bool]$state.Sealed
    }
}

#endregion

Export-ModuleMember -Function Get-AVDTuneProp, Test-AVDTuneElevated, Get-AVDTuneRoot, Test-AVDTuneDefaultRoot, ConvertTo-AVDTuneArgument, New-AVDTuneMachine, Invoke-AVDTuneMachine,
    New-AVDTuneStateSecurity, Initialize-AVDTuneState, Read-AVDTuneAclInfo, Get-AVDTuneStateSecurityProblems, Move-AVDTuneStateToQuarantine, New-AVDTuneProtectedFolder, Assert-AVDTuneStateSecurity, Get-AVDTuneStateSecurityReport, Get-AVDTuneState, Set-AVDTuneState, Test-AVDTuneImageVersion, Get-AVDTuneNextImageVersion, Start-AVDTuneImageVersion,
    Add-AVDTuneRun, Get-AVDTuneRun, Get-AVDTuneLastChange, New-AVDTuneStep, Invoke-AVDTuneStep, New-AVDTuneStepFromData, Get-AVDTuneStepCatalog, Invoke-AVDTune,
    Add-AVDTuneChangeLogEntry, Get-AVDTuneChangeLog, Get-AVDTuneChangeLogVersions, ConvertTo-AVDTuneChangeLogDocument, Export-AVDTuneChangeLog,
    Get-AVDTuneWindowsInfo, Get-AVDTuneOfficeInfo, Get-AVDTuneSourceImage, Get-AVDTuneHealth, Get-AVDTuneOverview, Write-AVDTuneFile, Read-AVDTuneJson,
    Open-AVDTuneWriteGate, Close-AVDTuneWriteGate, Set-AVDTuneWriteBlock, Clear-AVDTuneWriteBlock, Get-AVDTuneWriteBlock, Get-AVDTuneWriteGate, Test-AVDTuneWriteAllowed, Remove-AVDTuneControlCharacters, ConvertTo-AVDTuneTestResult,
    Read-AVDTuneAclReport, Get-AVDTuneAclProblems, New-AVDTuneUsersReadSecurity, New-AVDTuneFileSecurity, Write-AVDTuneAccessFile, Get-AVDTuneTaskInfoFromXml
