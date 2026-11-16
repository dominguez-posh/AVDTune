# Fakes for App Masking (Modules\AVDTune.Masking.psm1, issue 29): the masking adapter (rules folder, Public Desktop, shortcuts, local groups, name lookup) and an LDAP
# adapter with Search, Add and Delete for groups, all in memory. Nothing touches this computer, FSLogix or a domain controller. Names and SIDs are made up.
#   New-AVDTuneFakeMasking [-Seed @{ Files (path -> byte[]); Desktop (array of @{ Name; Target; Arguments; Icon; IsShortcut }); Unsafe ($true: every write is refused like an
#     unsafe folder); AdminName; LocalGroups (name -> description); Shortcuts (path -> @{ Target; Arguments; Icon; Description }) }]
#   New-AVDTuneFakeMaskingLdap [-Seed @{ Groups (list of @{ Name; Dn; Sid; Description; Members }); AddFails; BuiltinDn }]
$script:FakeRulesFolder = 'C:\Program Files\FSLogix\Apps\Rules'

function New-AVDTuneFakeMasking {
    param([hashtable]$Seed = @{})
    $s = @{
        Files = @{}; Desktop = @(); Unsafe = $false; AdminName = 'BUILTIN\Administrators'; LocalGroups = @{}; LocalGroupSids = @{}; LocalGroupMembers = @{}; Shortcuts = @{}; Log = (New-Object System.Collections.ArrayList)
        PublicDesktop = 'C:\Users\Public\Desktop'; SystemFolder = 'C:\Windows\System32'; DesktopWarnings = @(); DesktopProblems = @()
    }
    foreach ($e in $Seed.GetEnumerator()) { $s[$e.Key] = $e.Value }
    $a = [ordered]@{ Kind = 'Fake'; Store = $s; Log = $s.Log; RulesFolder = $script:FakeRulesFolder }
    $a.SystemDrive = { 'C:' }.GetNewClosure()
    $a.SystemFolder = { $s.SystemFolder }.GetNewClosure()
    $a.PublicDesktopFolder = { $s.PublicDesktop }.GetNewClosure()
    $a.ListRuleFiles = { @($s.Files.Keys | ForEach-Object { Split-Path $_ -Leaf }) }.GetNewClosure()
    $a.ReadBytes = { param($Path) if ($s.Files.ContainsKey($Path)) { , $s.Files[$Path] } else { $null } }.GetNewClosure()
    $a.WriteBytes = {
        param($Path, [byte[]]$Bytes)
        [void]$s.Log.Add("WriteBytes $Path")
        if ($s.Unsafe) { throw "$(Split-Path $Path -Parent) is not safe (write access for S-1-5-32-545). Nothing was written." }
        $s.Files[$Path] = $Bytes
    }.GetNewClosure()
    $a.DeleteFile = { param($Path) [void]$s.Log.Add("DeleteFile $Path"); $s.Files.Remove($Path) }.GetNewClosure()
    $a.ResolveAccountName = { param($Sid) if ($Sid -eq 'S-1-5-32-544') { $s.AdminName } else { $Sid } }.GetNewClosure()
    $a.ListPublicDesktop = { @($s.Desktop | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = (Join-Path $s.PublicDesktop $_.Name); Target = [string]$_.Target; Arguments = [string]$_.Arguments; Icon = [string]$_.Icon; IsShortcut = [bool]$_.IsShortcut } }) }.GetNewClosure()
    $a.ReadShortcut = { param($Path) if ($s.Shortcuts.ContainsKey($Path)) { $x = $s.Shortcuts[$Path]; [pscustomobject]@{ Target = [string]$x.Target; Arguments = [string]$x.Arguments; Icon = [string]$x.Icon; Description = [string]$x.Description; WorkingDirectory = [string]$x.WorkingDirectory; AclProblems = @($x.AclProblems) } } else { $null } }.GetNewClosure()
    $a.ShortcutExists = { param($Path) $s.Shortcuts.ContainsKey($Path) }.GetNewClosure()
    $a.CreateShortcut = {
        param($Path, $Target, $Arguments, $Icon, $Description, $WorkingDirectory)
        [void]$s.Log.Add("CreateShortcut $Path -> $Target $Arguments")
        if ($s.Unsafe) { throw 'fake: the Public Desktop is a link' }
        $s.Shortcuts[$Path] = @{ Target = $Target; Arguments = $Arguments; Icon = $Icon; Description = $Description; WorkingDirectory = $WorkingDirectory; AclProblems = @() }
    }.GetNewClosure()
    $a.ShortcutFolderFindings = { param($Path) [pscustomobject]@{ Problems = @($s.DesktopProblems); Warnings = @($s.DesktopWarnings) } }.GetNewClosure()   # what the real adapter reads from the Public Desktop ACL (seed DesktopWarnings, DesktopProblems)
    $a.DeleteShortcut = { param($Path) [void]$s.Log.Add("DeleteShortcut $Path"); $s.Shortcuts.Remove($Path) }.GetNewClosure()
    $a.LocalGroupExists = { param($Name) $s.LocalGroups.ContainsKey($Name) }.GetNewClosure()
    $a.LocalGroupCreate = { param($Name, $Description) [void]$s.Log.Add("LocalGroupCreate $Name"); $s.LocalGroups[$Name] = $Description }.GetNewClosure()
    $a.LocalGroupInfo = { param($Name) if ($s.LocalGroups.ContainsKey($Name)) { @{ Exists = $true; Sid = $(if ($s.LocalGroupSids.ContainsKey($Name)) { $s.LocalGroupSids[$Name] } else { 'S-1-5-21-1-2-3-' + (2000 + $s.LocalGroups.Count) }); Description = [string]$s.LocalGroups[$Name]; MemberCount = $(if ($s.LocalGroupMembers.ContainsKey($Name)) { @($s.LocalGroupMembers[$Name]).Count } else { 0 }) } } else { @{ Exists = $false; Sid = ''; Description = ''; MemberCount = 0 } } }.GetNewClosure()
    $a.LocalGroupDelete = { param($Name) [void]$s.Log.Add("LocalGroupDelete $Name"); $s.LocalGroups.Remove($Name) }.GetNewClosure()
    [pscustomobject]$a
}

function New-AVDTuneFakeMaskingLdap {
    # Groups: @{ Name; Dn; Sid; Description; Members; Guid (hex, optional) }. A group with members is returned like real AD does for a big group: the attribute comes as 'member;range=0-1499',
    # never as plain 'member' (a count of 'member' would be 0). Filters understood: sAMAccountName=, objectGUID=\xx..., and (member=*) (only groups with members).
    param([hashtable]$Seed = @{})
    $dn = 'DC=example,DC=test'
    $s = @{ Groups = (New-Object System.Collections.ArrayList); AddFails = $false; BuiltinDn = "CN=Administrators,CN=Builtin,$dn"; Added = (New-Object System.Collections.ArrayList); Deleted = (New-Object System.Collections.ArrayList); Log = (New-Object System.Collections.ArrayList); Next = 3000 }
    foreach ($e in $Seed.GetEnumerator()) { $s[$e.Key] = $e.Value }
    $sidBytes = { param($t) $b = New-Object byte[] 28; (New-Object Security.Principal.SecurityIdentifier $t).GetBinaryForm($b, 0); , $b }
    $mk = { param($d, $attrs) $t = New-Object 'System.Collections.Hashtable' $attrs, ([StringComparer]::OrdinalIgnoreCase); [pscustomobject]@{ Dn = $d; Attributes = $t } }
    $guidOf = { param($g) if ($g.ContainsKey('Guid') -and $g.Guid) { [string]$g.Guid } else { $md5 = [Security.Cryptography.MD5]::Create(); try { ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$g.Sid)) | ForEach-Object { $_.ToString('x2') }) -join '' } finally { $md5.Dispose() } } }
    $a = [ordered]@{ Kind = 'Fake'; Store = $s; Log = $s.Log }
    $a.Search = {
        param($Conn, $BaseDn, $Filter, $Scope, $Attributes)
        [void]$s.Log.Add("Search $Scope $BaseDn $Filter")
        if ($Filter -like '*objectSid=*' -and $BaseDn -like 'CN=Builtin,*') { return @(& $mk $s.BuiltinDn @{ distinguishedName = @($s.BuiltinDn) }) }
        $hit = $null
        if ($Filter -match 'sAMAccountName=([^)]*)\)') { $name = [regex]::Replace($Matches[1], '\\([0-9a-fA-F]{2})', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) }); $hit =@($s.Groups | Where-Object { $_.Name -eq $name }) }
        elseif ($Filter -match 'objectGUID=((?:\\[0-9a-f]{2})+)\)') { $hex = $Matches[1].Replace([string][char]92, '');$hit = @($s.Groups | Where-Object { (& $guidOf $_) -eq $hex }) }
        if ($null -eq $hit) { return @() }
        if ($Filter -like '*(member=*)*') { $hit = @($hit | Where-Object { @($_.Members).Count -gt 0 }) }
        @($hit | ForEach-Object {
                $gb = [byte[]]@(for ($i = 0; $i -lt 32; $i += 2) { [Convert]::ToByte((& $guidOf $_).Substring($i, 2), 16) })
                $at = @{ distinguishedName = @($_.Dn); objectSid = @(, (& $sidBytes $_.Sid)); objectGUID = @(, $gb); sAMAccountName = @($_.Name); description = @([string]$_.Description); groupType = @('-2147483646') }
                if (@($_.Members).Count -gt 0) { $at['member;range=0-1499'] = @($_.Members) }
                & $mk $_.Dn $at
            })
    }.GetNewClosure()
    $a.Add = {
        param($Conn, $Dn, $Attributes)
        [void]$s.Log.Add("Add $Dn")
        if ($s.AddFails) { throw 'fake: insufficient access rights' }
        if (@($s.Groups | Where-Object { $_.Dn -ieq $Dn }).Count -gt 0) { throw 'fake: entry already exists' }
        if ($Attributes['objectClass'] -ne 'group') { throw 'fake: objectClass must be group' }
        [void]$s.Added.Add(@{ Dn = $Dn; Attributes = $Attributes })
        $s.Next++
        $newSid = "S-1-5-21-1111111111-2222222222-333333333-$($s.Next)"
        $newGroup = @{ Name = [string]$Attributes['sAMAccountName']; Dn = $Dn; Sid = $newSid; Description = [string]$Attributes['description']; Members = @() }
        $newGroup.Guid = & $guidOf $newGroup   # the GUID is fixed at creation and does not follow later changes of the SID
        [void]$s.Groups.Add($newGroup)
    }.GetNewClosure()
    $a.Delete = {
        param($Conn, $Dn)
        [void]$s.Log.Add("Delete $Dn")
        $target = $Dn
        if ($Dn -match '^<GUID=([0-9a-f]{32})>$') { $hex = $Matches[1]; $g = @($s.Groups | Where-Object { (& $guidOf $_) -eq $hex }); if ($g.Count -eq 0) { throw 'fake: no such object' }; $target = $g[0].Dn }
        [void]$s.Deleted.Add($Dn)
        $keep = @($s.Groups | Where-Object { $_.Dn -ine $target }); $s.Groups.Clear(); foreach ($g in $keep) { [void]$s.Groups.Add($g) }
    }.GetNewClosure()
    $a.Close = { param($Conn) }.GetNewClosure()
    [pscustomobject]$a
}
