# Fakes for App Masking (Modules\AVDTune.Masking.psm1, issue 29): the masking adapter (rules folder, Public Desktop, shortcuts, local groups, name lookup) and an LDAP
# adapter with Search, Add and Delete for groups, all in memory. Nothing touches this computer, FSLogix or a domain controller. Names and SIDs are made up.
#   New-AVDTuneFakeMasking [-Seed @{ Files (path -> byte[]); Desktop (array of @{ Name; Target; Arguments; Icon; IsShortcut }); Unsafe ($true: every write is refused like an
#     unsafe folder); AdminName; LocalGroups (name -> description); Shortcuts (path -> @{ Target; Arguments; Icon; Description }) }]
#   New-AVDTuneFakeMaskingLdap [-Seed @{ Groups (list of @{ Name; Dn; Sid; Description; Members }); AddFails; BuiltinDn }]
$script:FakeRulesFolder = 'C:\Program Files\FSLogix\Apps\Rules'

function New-AVDTuneFakeMasking {
    param([hashtable]$Seed = @{})
    $s = @{
        Files = @{}; Desktop = @(); Unsafe = $false; AdminName = 'BUILTIN\Administrators'; LocalGroups = @{}; Shortcuts = @{}; Log = (New-Object System.Collections.ArrayList)
        PublicDesktop = 'C:\Users\Public\Desktop'; SystemFolder = 'C:\Windows\System32'
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
    $a.ReadShortcut = { param($Path) if ($s.Shortcuts.ContainsKey($Path)) { [pscustomobject]$s.Shortcuts[$Path] } else { $null } }.GetNewClosure()
    $a.ShortcutExists = { param($Path) $s.Shortcuts.ContainsKey($Path) }.GetNewClosure()
    $a.CreateShortcut = {
        param($Path, $Target, $Arguments, $Icon, $Description)
        [void]$s.Log.Add("CreateShortcut $Path -> $Target $Arguments")
        if ($s.Unsafe) { throw 'fake: the Public Desktop is a link' }
        $s.Shortcuts[$Path] = @{ Target = $Target; Arguments = $Arguments; Icon = $Icon; Description = $Description }
    }.GetNewClosure()
    $a.DeleteShortcut = { param($Path) [void]$s.Log.Add("DeleteShortcut $Path"); $s.Shortcuts.Remove($Path) }.GetNewClosure()
    $a.LocalGroupExists = { param($Name) $s.LocalGroups.ContainsKey($Name) }.GetNewClosure()
    $a.LocalGroupCreate = { param($Name, $Description) [void]$s.Log.Add("LocalGroupCreate $Name"); $s.LocalGroups[$Name] = $Description }.GetNewClosure()
    $a.LocalGroupDescription = { param($Name) [string]$s.LocalGroups[$Name] }.GetNewClosure()
    $a.LocalGroupDelete = { param($Name) [void]$s.Log.Add("LocalGroupDelete $Name"); $s.LocalGroups.Remove($Name) }.GetNewClosure()
    [pscustomobject]$a
}

function New-AVDTuneFakeMaskingLdap {
    param([hashtable]$Seed = @{})
    $dn = 'DC=example,DC=test'
    $s = @{ Groups = (New-Object System.Collections.ArrayList); AddFails = $false; BuiltinDn = "CN=Administrators,CN=Builtin,$dn"; Added = (New-Object System.Collections.ArrayList); Deleted = (New-Object System.Collections.ArrayList); Log = (New-Object System.Collections.ArrayList); Next = 3000 }
    foreach ($e in $Seed.GetEnumerator()) { $s[$e.Key] = $e.Value }
    $sidBytes = { param($t) $b = New-Object byte[] 28; (New-Object Security.Principal.SecurityIdentifier $t).GetBinaryForm($b, 0); , $b }
    $mk = { param($d, $attrs) $t = New-Object 'System.Collections.Hashtable' $attrs, ([StringComparer]::OrdinalIgnoreCase); [pscustomobject]@{ Dn = $d; Attributes = $t } }
    $a = [ordered]@{ Kind = 'Fake'; Store = $s; Log = $s.Log }
    $a.Search = {
        param($Conn, $BaseDn, $Filter, $Scope, $Attributes)
        [void]$s.Log.Add("Search $Scope $BaseDn $Filter")
        if ($Filter -like '*objectSid=*' -and $BaseDn -like 'CN=Builtin,*') { return @(& $mk $s.BuiltinDn @{ distinguishedName = @($s.BuiltinDn) }) }
        if ($Filter -match 'sAMAccountName=([^)]*)\)') {
            $name = $Matches[1]
            $hit = @($s.Groups | Where-Object { $_.Name -eq $name })
            return @($hit | ForEach-Object {
                    $at = @{ distinguishedName = @($_.Dn); objectSid = @(, (& $sidBytes $_.Sid)); description = @([string]$_.Description); groupType = @('-2147483646') }
                    if (@($_.Members).Count -gt 0) { $at['member'] = @($_.Members) }
                    & $mk $_.Dn $at
                })
        }
        @()
    }.GetNewClosure()
    $a.Add = {
        param($Conn, $Dn, $Attributes)
        [void]$s.Log.Add("Add $Dn")
        if ($s.AddFails) { throw 'fake: insufficient access rights' }
        if (@($s.Groups | Where-Object { $_.Dn -ieq $Dn }).Count -gt 0) { throw 'fake: entry already exists' }
        if ($Attributes['objectClass'] -ne 'group') { throw 'fake: objectClass must be group' }
        [void]$s.Added.Add(@{ Dn = $Dn; Attributes = $Attributes })
        $s.Next++
        [void]$s.Groups.Add(@{ Name = [string]$Attributes['sAMAccountName']; Dn = $Dn; Sid = "S-1-5-21-1111111111-2222222222-333333333-$($s.Next)"; Description = [string]$Attributes['description']; Members = @() })
    }.GetNewClosure()
    $a.Delete = {
        param($Conn, $Dn)
        [void]$s.Log.Add("Delete $Dn")
        [void]$s.Deleted.Add($Dn)
        $keep = @($s.Groups | Where-Object { $_.Dn -ine $Dn }); $s.Groups.Clear(); foreach ($g in $keep) { [void]$s.Groups.Add($g) }
    }.GetNewClosure()
    $a.Close = { param($Conn) }.GetNewClosure()
    [pscustomobject]$a
}
