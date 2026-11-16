<#
    AVDTune App Masking and Public Desktop (docs\plans\avdtune.md sections 5b and 5c; issue 29; sources and what is not verified: docs\app-masking.md).

      * Rule sets are two files in C:\Program Files\FSLogix\Apps\Rules: .fxr (hiding rules) and .fxa (assignments). The byte format is the one the Rule Editor
        writes (UTF-16 LE with BOM, CRLF, '##' before every rule, flags 0x00000222; Everyone applies, then Administrators and released groups do not apply).
        Reading keeps every line AVDTune does not understand and writes it back unchanged.
      * Every access to the master goes through the masking adapter ($M: files of the rules folder, the Public Desktop, shortcuts, local groups, name lookup).
        Tests\Fakes\FakeMasking.ps1 has the fake; New-AVDTuneMaskingAdapter is the real one and is NOT exercised by the checks beyond construction.
        Groups in AD are created and deleted through the LDAP adapter of AVDTune.Directory.psm1 (members Search, Add, Delete); the real adapter has no Add and
        Delete, so New-AVDTuneLdapWriter adds them (AddRequest and DeleteRequest on the pinned LDAPS connection). A group is only created with -Confirmed.
      * Every change is a plan of steps through Invoke-AVDTune (write gate, run record, LastChange, change log) with an undo record in config\masking-undo.json;
        older records are kept under a versioned name. Names, OUs and paths are validated before anything is written.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Updates.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.FSLogix.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Directory.psm1')

$script:Learn = 'https://learn.microsoft.com/en-us/fslogix'
$script:PublicDesktopRuleFolder = '%SystemDriveFolder%\Users\Public\Desktop'
$script:AdminsSid = 'S-1-5-32-544'
$script:EveryoneSid = 'S-1-1-0'
$script:AdminsSidFilter = '\01\02\00\00\00\00\00\05\20\00\00\00\20\02\00\00'   # the binary SID S-1-5-32-544 as an LDAP filter value
$script:GroupDescription = 'AVDTune App Masking: '
$script:ShortcutMarker = 'AVDTune comfort shortcut'
$script:FileFlags = '0x00000222'   # file, hiding, persistent (plan 5b, as the Rule Editor writes it)
$script:Reserved = @('CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9', 'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9')

#region validation

function Test-AVDTuneMaskingName {
    <# A rule set name: file name in the rules folder. Letters, digits, space, '.', '_', '-', 1 to 64 characters, no device name, no leading or trailing blank or dot. #>
    param([string]$Name)
    if (-not $Name -or $Name.Length -gt 64) { return $false }
    if ($Name -notmatch '\A[A-Za-z0-9][A-Za-z0-9 ._-]*[A-Za-z0-9_-]\z' -and $Name -notmatch '\A[A-Za-z0-9]\z') { return $false }
    if ($Name.Split('.')[0].Trim().ToUpperInvariant() -in $script:Reserved) { return $false }
    $true
}

function Test-AVDTuneMaskingGroupName {
    # A group name (sAMAccountName, local group name): no characters that are special in a DN, a filter or an account name
    param([string]$Name)
    [bool]($Name -and $Name.Length -le 64 -and $Name -match '\A[A-Za-z0-9]([A-Za-z0-9 ._-]{0,62}[A-Za-z0-9_-])?\z')
}

function Test-AVDTuneAdExistingGroupName {
    <#
        The name of a group that ALREADY exists in AD (sAMAccountName as the DC returned it, e.g. 'Vertrieb-Sued', 'Sales Team (EU)', 'HR$'): only length (1 to 256) and control characters are checked.
        That is enough because the name only reaches an LDAP filter (escaped by ConvertTo-AVDTuneLdapFilterValue) and the .fxa as DOMAIN\name (a tab or line feed would break the row); no DN is built from it.
        The strict Test-AVDTuneMaskingGroupName stays for names AVDTune creates.
    #>
    param([string]$Name)
    [bool]($Name -and $Name.Length -le 256 -and $Name -notmatch '[\x00-\x1F\x7F\\]' -and $Name -ceq $Name.Trim())
}

function Test-AVDTuneMaskingPrefix([string]$Prefix) { [bool]($Prefix -match '\A[A-Za-z0-9]{1,16}\z') }

function Get-AVDTuneAppGroupName {
    <# <prefix>-App-<name> (plan 5b); spaces in the rule set name become '-'. Throws when the result is not a valid group name. #>
    param([Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-AVDTuneMaskingPrefix $Prefix)) { throw "The group prefix '$Prefix' is not valid (letters and digits, 1 to 16)." }
    $g = "$Prefix-App-" + (($Name.Trim() -replace '\s+', '-') -replace '[^A-Za-z0-9._-]', '')
    if (-not (Test-AVDTuneMaskingGroupName $g)) { throw "'$g' is not a valid group name." }
    $g
}

function Test-AVDTuneMaskingRulePath {
    <# Returns an error text, or '' when folder and file name are fine: no '..', no wildcards, no control characters, no stream or device names. #>
    param([string]$Folder, [string]$Name)
    if ($Folder.Length -gt 260 -or $Folder -notmatch '\A(%SystemDriveFolder%|[A-Za-z]:)(\\[^\\/:*?"<>|\x00-\x1F]+)*\z') { return "The folder '$Folder' is not a valid local folder path (no wildcards, no control characters)." }
    if (@($Folder -split '\\') -contains '..' -or @($Folder -split '\\') -contains '.') { return "The folder '$Folder' contains '.' or '..'." }
    if (-not $Name -or $Name.Length -gt 200 -or $Name -notmatch '\A[^\\/:*?"<>|\x00-\x1F]+\z') { return "The file name '$Name' is not valid (no path, no wildcards, no control characters)." }
    if ($Name -in '.', '..' -or $Name -match '[. ]$') { return "The file name '$Name' is not valid." }
    if ($Name.Split('.')[0].Trim().ToUpperInvariant() -in $script:Reserved) { return "The file name '$Name' is a device name." }
    ''
}

function Test-AVDTuneOuDn {
    <# The OU for a new group must be one that the domain controller returned (exact distinguished name, case-insensitive): never free text. #>
    param([string]$Dn, [object[]]$Known)
    if (-not $Dn -or $Dn -match '[\x00-\x1F]') { return $false }
    $flat = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = { param($nodes) foreach ($n in @($nodes)) { if ($n) { [void]$flat.Add([string]$n.Dn); & $walk @($n.Children) } } }
    & $walk $Known
    [bool](@($flat | Where-Object { $_ -ieq $Dn }).Count -gt 0)
}

#endregion

#region file formats (.fxr and .fxa)

function ConvertTo-AVDTuneRuleBytes([string]$Text) {
    # UTF-16 LE with BOM (FF FE), as the Rule Editor writes it
    $enc = New-Object System.Text.UnicodeEncoding($false, $false)
    $body = $enc.GetBytes($Text)
    $bytes = New-Object byte[] ($body.Length + 2)
    $bytes[0] = 0xFF; $bytes[1] = 0xFE
    [Array]::Copy($body, 0, $bytes, 2, $body.Length)
    , $bytes
}

function ConvertFrom-AVDTuneRuleBytes {
    <# Text of a rule file. Throws when the BOM is missing (UTF-8 or UTF-16 without BOM is what the hand-made files had) or the length is odd. #>
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -lt 2 -or $Bytes[0] -ne 0xFF -or $Bytes[1] -ne 0xFE) { throw 'The file is not UTF-16 LE with a byte order mark (FF FE).' }
    if (($Bytes.Length % 2) -ne 0) { throw 'The file has an odd number of bytes: not UTF-16.' }
    (New-Object System.Text.UnicodeEncoding($false, $false)).GetString($Bytes, 2, $Bytes.Length - 2)
}

function Split-AVDTuneRuleLines([string]$Text) {
    # CRLF terminated lines; the last empty piece after the final CRLF is not a line
    $parts = [regex]::Split($Text, "\r\n")
    if ($parts.Count -gt 0 -and $parts[$parts.Count - 1] -eq '') { $parts = $parts[0..($parts.Count - 2)] }
    $parts
}

function ConvertFrom-AVDTuneFxrText {
    <#
        .fxr: line 1 is the format ('1'), then rule lines, each preceded by '##'. Entries keep the lines before a rule (Pre) and the rule line (Line) raw, so what is
        not understood is written back unchanged. Rule (when the line is a file rule): Folder, Name, Flags.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $lines = @(Split-AVDTuneRuleLines $Text)
    $problems = New-Object System.Collections.ArrayList
    if ($lines.Count -eq 0 -or $lines[0].Trim() -ne '1') { [void]$problems.Add('The first line is not the format number 1.') }
    $entries = New-Object System.Collections.ArrayList
    $pre = New-Object System.Collections.ArrayList
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l.StartsWith('##')) { [void]$pre.Add($l); continue }
        $rule = $null
        $f = $l -split "`t"
        if ($f.Count -ge 5 -and $f[4] -ieq $script:FileFlags) { $rule = [pscustomobject]@{ Folder = $f[0]; Name = $f[1]; Flags = $f[4] } }
        [void]$entries.Add([pscustomobject]@{ Pre = @($pre); Line = $l; Rule = $rule })
        $pre = New-Object System.Collections.ArrayList
    }
    [pscustomobject]@{ Header = $(if ($lines.Count -gt 0) { $lines[0] } else { '1' }); Entries = @($entries); Trailing = @($pre); Problems = @($problems) }
}

function ConvertTo-AVDTuneFxrRuleLine([string]$Folder, [string]$Name) { "$Folder`t$Name`t`t`t$script:FileFlags`t" }

function ConvertTo-AVDTuneFxrText {
    # Header, then ('##' + line) per entry; an entry without a Pre line gets '##' (the Rule Editor writes it before every rule)
    param([Parameter(Mandatory)]$Fxr)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append([string]$Fxr.Header + "`r`n")
    foreach ($e in @($Fxr.Entries)) {
        $pre = @($e.Pre); if ($pre.Count -eq 0) { $pre = @('##') }
        foreach ($p in $pre) { [void]$sb.Append($p + "`r`n") }
        [void]$sb.Append([string]$e.Line + "`r`n")
    }
    foreach ($t in @($Fxr.Trailing)) { [void]$sb.Append($t + "`r`n") }
    $sb.ToString()
}

function New-AVDTuneFxaRow {
    # One assignment row: code (0x01 applies, 0x02 does not apply, 0x10 group), name, DN, display name, FILETIME of the row, last field
    param([int]$Code, [string]$Name, [string]$Dn = '', [string]$Display, [string]$Time = '0')
    [pscustomobject]@{ Code = $Code; Name = $Name; Dn = $Dn; Display = $Display; Time = $Time; Raw = ('0x{0:X8}' -f $Code) + "`t$Name`t$Dn`t$Display`t$Time`t0" }
}

function ConvertFrom-AVDTuneFxaText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $lines = @(Split-AVDTuneRuleLines $Text)
    $problems = New-Object System.Collections.ArrayList
    if ($lines.Count -eq 0 -or $lines[0] -ne "1`t") { [void]$problems.Add('The first line is not "1" followed by a tab.') }
    $rows = New-Object System.Collections.ArrayList
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $f = $lines[$i] -split "`t"
        $code = 0
        if ($f.Count -ge 6 -and $f[0] -match '\A0x[0-9A-Fa-f]{8}\z') { $code = [Convert]::ToInt32($f[0].Substring(2), 16); [void]$rows.Add([pscustomobject]@{ Code = $code; Name = $f[1]; Dn = $f[2]; Display = $f[3]; Time = $f[4]; Raw = $lines[$i] }) }
        else { [void]$rows.Add([pscustomobject]@{ Code = 0; Name = ''; Dn = ''; Display = ''; Time = ''; Raw = $lines[$i] }); [void]$problems.Add("Line $($i + 1) is not an assignment row; kept as it is.") }
    }
    [pscustomobject]@{ Header = $(if ($lines.Count -gt 0) { $lines[0] } else { "1`t" }); Rows = @($rows); Problems = @($problems) }
}

function ConvertTo-AVDTuneFxaText {
    param([Parameter(Mandatory)]$Fxa)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("1`t`r`n")
    foreach ($r in @($Fxa.Rows)) { [void]$sb.Append([string]$r.Raw + "`r`n") }
    $sb.ToString()
}

function ConvertTo-AVDTuneFxaRows {
    <#
        Visibility 'Hidden': hidden for everyone except Administrators (Everyone applies, Administrators do not).
        Visibility 'HiddenExceptGroups': the same, and every released group does not apply either (it sees the item).
        Rows apply top to bottom, later rows win (Learn: concepts-fslogix-apps-rule-editor-rule-sets). Groups are written by NAME with their DN, as the Rule Editor does.
        -AdminDn and -AdminName come from the domain controller and the machine (localized); -Time is the FILETIME of the write.
    #>
    param([ValidateSet('Hidden', 'HiddenExceptGroups')][string]$Visibility = 'Hidden', [object[]]$Groups = @(), [string]$AdminDn = '', [Parameter(Mandatory)][string]$AdminName, [Parameter(Mandatory)][string]$Time)
    $rows = New-Object System.Collections.ArrayList
    [void]$rows.Add((New-AVDTuneFxaRow -Code 0x11 -Name $script:EveryoneSid -Dn '' -Display 'Everyone' -Time '0'))
    [void]$rows.Add((New-AVDTuneFxaRow -Code 0x12 -Name $script:AdminsSid -Dn $AdminDn -Display $AdminName -Time '0'))
    if ($Visibility -eq 'HiddenExceptGroups') {
        if (@($Groups).Count -eq 0) { throw 'Visibility HiddenExceptGroups needs at least one group.' }
        foreach ($g in @($Groups)) {
            if (-not $g.Account -or $g.Account -notmatch '\A[^\\\x00-\x1F\t]+\\[^\\\x00-\x1F\t]+\z') { throw "The group account '$($g.Account)' is not of the form DOMAIN\Group." }
            if ($g.Dn -and $g.Dn -match '[\x00-\x1F]') { throw 'A distinguished name contains control characters.' }
            [void]$rows.Add((New-AVDTuneFxaRow -Code 0x12 -Name $g.Account -Dn ([string]$g.Dn) -Display $g.Account -Time $Time))
        }
    }
    , @($rows)
}

function Get-AVDTuneRuleVisibility {
    <# What the assignment rows mean (top to bottom, later rows win): Effect Hidden (Everyone applies first), HiddenFor (named rows apply only) or NoEffect; ShownFor lists the rows that do not apply after Everyone applied. #>
    param($Fxa)
    $rows = @($Fxa.Rows | Where-Object { $_.Name })
    $hidden = $false; $shown = New-Object System.Collections.ArrayList; $hiddenFor = New-Object System.Collections.ArrayList; $everyoneApplies = $false
    foreach ($r in $rows) {
        $applies = (($r.Code -band 0x01) -ne 0); $not = (($r.Code -band 0x02) -ne 0)
        $label = $(if ($r.Display) { $r.Display } else { $r.Name })
        if ($r.Name -eq $script:EveryoneSid) { $everyoneApplies = $applies -and -not $not; if ($everyoneApplies) { $hidden = $true; $shown.Clear() } else { $hidden = $false; $hiddenFor.Clear() }; continue }
        if ($applies -and -not $not) { if (-not $hidden) { [void]$hiddenFor.Add($label) } else { [void]$shown.Remove($label) } }
        elseif ($not) { if ($hidden) { [void]$shown.Add($label) } else { [void]$hiddenFor.Remove($label) } }
    }
    $effect = if ($hidden) { 'Hidden' } elseif ($hiddenFor.Count -gt 0) { 'HiddenFor' } else { 'NoEffect' }
    $text = switch ($effect) {
        'Hidden' { if ($shown.Count -gt 0) { 'Hidden for everyone except: ' + ($shown -join ', ') } else { 'Hidden for everyone' } }
        'HiddenFor' { 'Hidden only for: ' + ($hiddenFor -join ', ') }
        default { 'Not hidden for anybody (the assignment has no effect)' }
    }
    [pscustomobject]@{ Effect = $effect; ShownFor = @($shown); HiddenFor = @($hiddenFor); Text = $text }
}

#endregion

#region settings

function Get-AVDTuneMaskingSettingsPath([string]$Root) { Join-Path $Root 'config\masking.json' }

function Get-AVDTuneMaskingSettings {
    # Prefix of the group names (default AVD); the file lives in the protected state folder
    param([string]$Root = (Get-AVDTuneRoot))
    $j = Read-AVDTuneJson (Get-AVDTuneMaskingSettingsPath $Root)
    $p = if ($j -and (Get-AVDTuneProp $j 'Prefix')) { [string]$j.Prefix } else { 'AVD' }
    if (-not (Test-AVDTuneMaskingPrefix $p)) { $p = 'AVD' }
    [pscustomobject]@{ Prefix = $p }
}

function Set-AVDTuneMaskingSettings {
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Prefix)
    if (-not (Test-AVDTuneMaskingPrefix $Prefix)) { throw "The group prefix '$Prefix' is not valid (letters and digits, 1 to 16)." }
    Write-AVDTuneFile (Get-AVDTuneMaskingSettingsPath $Root) ([ordered]@{ Prefix = $Prefix } | ConvertTo-Json)
}

function Get-AVDTuneMaskingCapabilities {
    <# Which group kinds the environment allows (Learn: assignments do not support Entra cloud-only accounts; they need a domain controller). #>
    param($Answers)
    $dc = $Answers -and [string](Get-AVDTuneProp $Answers 'DomainController') -notin '', 'None'
    [pscustomobject]@{
        AdGroups = [bool]$dc; LocalGroups = $true; Everyone = $true
        Note = $(if ($dc) { 'AD groups (created in an OU you choose, after your confirmation) or a local group of the master (not verified on a VM).' } else { 'No domain controller in this environment: Microsoft states that rule set assignments do not support Entra ID cloud-only accounts. Only "hidden for everyone" is offered; a local group is possible but not verified on a VM.' })
    }
}

#endregion

#region LDAP write (groups in AD)
function Get-AVDTuneMaskAttr($Entry, [string]$Name) {
    # First value of an attribute of a search entry (a byte array such as objectSid stays in one piece)
    $v = $Entry.Attributes[$Name]
    if ($null -eq $v) { return $null }
    , (@($v)[0])
}

function Test-AVDTuneMaskBytesEqual($A, $B) {
    if ($null -eq $A -or $null -eq $B) { return ($null -eq $A -and $null -eq $B) }
    if ($A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    $true
}


function New-AVDTuneLdapWriter {
    <# The LDAP adapter with Add and Delete: a fake brings its own, the real adapter (Probe, Open, Search, Close) is extended with AddRequest and DeleteRequest. #>
    param([Parameter(Mandatory)]$Ldap)
    if ($Ldap.PSObject.Properties['Add'] -and $Ldap.PSObject.Properties['Delete']) { return $Ldap }
    Add-Type -AssemblyName System.DirectoryServices.Protocols
    $w = [ordered]@{ Kind = 'RealWriter'; Search = $Ldap.Search; Close = $Ldap.Close }
    $w.Add = {
        param($Conn, $Dn, $Attributes)
        $attrs = foreach ($k in $Attributes.Keys) { $a = New-Object System.DirectoryServices.Protocols.DirectoryAttribute; $a.Name = [string]$k; foreach ($v in @($Attributes[$k])) { [void]$a.Add([string]$v) }; $a }
        $req = New-Object System.DirectoryServices.Protocols.AddRequest($Dn, [System.DirectoryServices.Protocols.DirectoryAttribute[]]@($attrs))
        [void]$Conn.SendRequest($req)
    }
    $w.Delete = { param($Conn, $Dn) [void]$Conn.SendRequest((New-Object System.DirectoryServices.Protocols.DeleteRequest($Dn))) }
    [pscustomobject]$w
}

function ConvertTo-AVDTuneGuidHex($Value) {
    # objectGUID as lower case hex without separators, in the byte order of the attribute; a string GUID is converted to its byte array first
    $b = if ($Value -is [byte[]]) { $Value } else { ([guid][string]$Value).ToByteArray() }
    (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

function ConvertTo-AVDTuneLdapBinaryFilter([string]$Hex) {
    # A binary value in an LDAP filter: \xx per byte; only 16 bytes of hex are accepted (nothing else reaches a filter or a DN)
    if ($Hex -notmatch '\A[0-9a-f]{32}\z') { throw 'The object GUID is not 16 bytes of hex.' }
    (([regex]::Matches($Hex, '[0-9a-f]{2}') | ForEach-Object { '\' + $_.Value }) -join '')
}

function ConvertTo-AVDTuneAdGroupObject($E) {
    $gt = Get-AVDTuneMaskAttr $E 'groupType'
    $guid = Get-AVDTuneMaskAttr $E 'objectGUID'
    $members = 0; foreach ($k in @($E.Attributes.Keys)) { if ([string]$k -like 'member*') { $members += @(@($E.Attributes[$k]) | Where-Object { $_ }).Count } }   # also 'member;range=0-1499'
    [pscustomobject]@{
        Dn = [string]$(if (Get-AVDTuneMaskAttr $E 'distinguishedName') { Get-AVDTuneMaskAttr $E 'distinguishedName' } else { $E.Dn }); Sid = (ConvertTo-AVDTuneSid (Get-AVDTuneMaskAttr $E 'objectSid'))
        Sam = [string](Get-AVDTuneMaskAttr $E 'sAMAccountName'); Guid = $(if ($guid) { ConvertTo-AVDTuneGuidHex $guid } else { '' })
        Description = [string](Get-AVDTuneMaskAttr $E 'description'); Security = $(if ($null -ne $gt) { ([int]$gt) -lt 0 } else { $true }); MemberCount = $members
    }
}

function Get-AVDTuneAdGroup {
    <# The group with this sAMAccountName in the domain: Dn, Sid, Sam, Guid, Description, Security, MemberCount (informational: AD may return only a range of members); $null when there is none. #>
    param([Parameter(Mandatory)]$Ldap, [Parameter(Mandatory)]$Conn, [Parameter(Mandatory)][string]$BaseDn, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-AVDTuneAdExistingGroupName $Name)) { throw "'$Name' is not a valid group name (1 to 256 characters, no control characters or backslash)." }   # the filter value is escaped below; the strict name rule is for groups AVDTune creates
    $r = @(& $Ldap.Search $Conn $BaseDn "(&(objectClass=group)(sAMAccountName=$(ConvertTo-AVDTuneLdapFilterValue $Name)))" 'Subtree' @('distinguishedName', 'objectSid', 'objectGUID', 'sAMAccountName', 'description', 'groupType', 'member'))
    if ($r.Count -eq 0) { return $null }
    if ($r.Count -gt 1) { throw "More than one group is named '$Name'." }
    ConvertTo-AVDTuneAdGroupObject $r[0]
}

function Get-AVDTuneAdGroupByGuid {
    # The group with this objectGUID (hex): survives a move or rename; $null when there is none
    param([Parameter(Mandatory)]$Ldap, [Parameter(Mandatory)]$Conn, [Parameter(Mandatory)][string]$BaseDn, [Parameter(Mandatory)][string]$GuidHex)
    $r = @(& $Ldap.Search $Conn $BaseDn "(&(objectClass=group)(objectGUID=$(ConvertTo-AVDTuneLdapBinaryFilter $GuidHex)))" 'Subtree' @('distinguishedName', 'objectSid', 'objectGUID', 'sAMAccountName', 'description', 'groupType'))
    if ($r.Count -eq 0) { return $null }
    if ($r.Count -gt 1) { throw 'More than one group has this object GUID.' }
    ConvertTo-AVDTuneAdGroupObject $r[0]
}

function Test-AVDTuneAdGroupHasMembers {
    # Asked by a filter, not read from the entry: with ranged retrieval AD returns 'member;range=0-1499' and a count of the plain attribute would be 0
    param([Parameter(Mandatory)]$Ldap, [Parameter(Mandatory)]$Conn, [Parameter(Mandatory)][string]$BaseDn, [Parameter(Mandatory)][string]$GuidHex)
    @(& $Ldap.Search $Conn $BaseDn "(&(objectClass=group)(objectGUID=$(ConvertTo-AVDTuneLdapBinaryFilter $GuidHex))(member=*))" 'Subtree' @('distinguishedName')).Count -gt 0
}

function Get-AVDTuneBuiltinAdminDn {
    # The distinguished name of the Builtin Administrators group in the language of the domain, by its SID (never by name)
    param([Parameter(Mandatory)]$Ldap, [Parameter(Mandatory)]$Conn, [Parameter(Mandatory)][string]$DefaultNc)
    $r = @(& $Ldap.Search $Conn "CN=Builtin,$DefaultNc" "(objectSid=$script:AdminsSidFilter)" 'OneLevel' @('distinguishedName'))
    if ($r.Count -eq 0) { return '' }
    [string]$(if (Get-AVDTuneMaskAttr $r[0] 'distinguishedName') { Get-AVDTuneMaskAttr $r[0] 'distinguishedName' } else { $r[0].Dn })
}

#endregion

#region reading

function Get-AVDTuneRuleSets {
    <# Every rule set in the rules folder (by file name): Name, rules (hidden files), kept unknown lines, assignments, what the assignment means, problems. #>
    param([Parameter(Mandatory)]$M)
    $names = @(& $M.ListRuleFiles | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension([string]$_) } | Sort-Object -Unique)
    @(foreach ($n in $names) {
            $problems = New-Object System.Collections.ArrayList
            $fxr = $null; $fxa = $null
            $b = & $M.ReadBytes (Join-Path $M.RulesFolder "$n.fxr")
            if ($null -ne $b) { try { $fxr = ConvertFrom-AVDTuneFxrText (ConvertFrom-AVDTuneRuleBytes $b); foreach ($p in $fxr.Problems) { [void]$problems.Add(".fxr: $p") } } catch { [void]$problems.Add(".fxr: $($_.Exception.Message)") } } else { [void]$problems.Add('No .fxr file.') }
            $b = & $M.ReadBytes (Join-Path $M.RulesFolder "$n.fxa")
            if ($null -ne $b) { try { $fxa = ConvertFrom-AVDTuneFxaText (ConvertFrom-AVDTuneRuleBytes $b); foreach ($p in $fxa.Problems) { [void]$problems.Add(".fxa: $p") } } catch { [void]$problems.Add(".fxa: $($_.Exception.Message)") } } else { [void]$problems.Add('No .fxa file.') }
            $rules = @(); $other = 0
            if ($fxr) { $rules = @($fxr.Entries | Where-Object { $_.Rule } | ForEach-Object { $_.Rule }); $other = @($fxr.Entries | Where-Object { -not $_.Rule }).Count }
            [pscustomobject]@{
                Name = $n; Fxr = $fxr; Fxa = $fxa; Rules = $rules; OtherRules = $other; Rows = $(if ($fxa) { @($fxa.Rows) } else { @() })
                Visibility = $(if ($fxa) { Get-AVDTuneRuleVisibility $fxa } else { $null }); Problems = @($problems)
            }
        })
}

function Resolve-AVDTuneRuleFolder([string]$Folder, [string]$SystemDrive) {
    $f = $Folder -replace '^%SystemDriveFolder%', $SystemDrive
    $f.TrimEnd('\')
}

function Get-AVDTunePublicDesktopList {
    <# Every file on the Public Desktop with its state: Uncovered (no rule set hides it), Hidden (a rule set hides it; Visible says for whom) or NotHiding (a rule exists, the assignment hides nothing). #>
    param([Parameter(Mandatory)]$M, [object[]]$RuleSets = $null)
    if ($null -eq $RuleSets) { $RuleSets = @(Get-AVDTuneRuleSets -M $M) }
    $desk = (& $M.PublicDesktopFolder).TrimEnd('\')
    $drive = & $M.SystemDrive
    @(foreach ($f in @(& $M.ListPublicDesktop)) {
            $cover = @(foreach ($rs in $RuleSets) { foreach ($r in $rs.Rules) { if ((Resolve-AVDTuneRuleFolder $r.Folder $drive) -ieq $desk -and $r.Name -ieq $f.Name) { [pscustomobject]@{ Set = $rs.Name; Visibility = $rs.Visibility } } } })
            $state = 'Uncovered'; $text = 'Not covered: every user sees it'; $set = ''
            if ($cover.Count -gt 0) {
                $set = (@($cover | ForEach-Object { $_.Set }) -join ', ')
                $eff = @($cover | Where-Object { $_.Visibility -and $_.Visibility.Effect -in 'Hidden', 'HiddenFor' })
                if ($eff.Count -gt 0) { $state = 'Hidden'; $text = $eff[0].Visibility.Text } else { $state = 'NotHiding'; $text = 'A rule exists, but the assignment hides it from nobody' }
            }
            [pscustomobject]@{ Name = [string]$f.Name; Path = [string]$f.Path; Target = [string]$f.Target; Arguments = [string]$f.Arguments; Icon = [string]$f.Icon; IsShortcut = [bool]$f.IsShortcut; State = $state; Text = $text; RuleSet = $set }
        })
}

function Get-AVDTuneMaskingOverview {
    # For the page and for counters: rule sets, the Public Desktop list and how many entries no rule covers
    param([Parameter(Mandatory)]$M)
    $sets = @(Get-AVDTuneRuleSets -M $M)
    $list = @(Get-AVDTunePublicDesktopList -M $M -RuleSets $sets)
    [pscustomobject]@{ RuleSets = $sets; PublicDesktop = $list; Uncovered = @($list | Where-Object { $_.State -ne 'Hidden' }).Count }
}

#endregion

#region undo record

function Get-AVDTuneMaskingUndoPath([string]$Root) { Join-Path $Root 'config\masking-undo.json' }

function Read-AVDTuneMaskingUndo([string]$Root) { Read-AVDTuneJson (Get-AVDTuneMaskingUndoPath $Root) }

function Get-AVDTuneBytesSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}

function Save-AVDTuneMaskingUndo {
    <#
        The undo record is written AFTER the run and holds only what the run really changed (step status Changed): an item whose step failed, was skipped or found
        everything in place is not in it (undo must never delete what AVDTune did not create). An older record is kept under a versioned name (Write-AVDTuneUndoFile).
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Undo, [Parameter(Mandatory)]$Run)
    if ($Run.WhatIf) { return }
    $changed = @($Run.Results | Where-Object { $_.Status -eq 'Changed' } | ForEach-Object { $_.Id })
    $files = @(@($Undo.Files) | Where-Object { $_ -and $_.StepId -in $changed })
    $groups = @(@($Undo.Groups) | Where-Object { $_ -and ($_.StepId -in $changed -or (Get-AVDTuneProp $_ 'Provisional')) })   # a group that exists but could not be read back stays in the record with its DN (Provisional)
    $shortcuts = @(@($Undo.Shortcuts) | Where-Object { $_ -and $_.StepId -in $changed })
    if ($files.Count + $groups.Count + $shortcuts.Count -eq 0) { return }
    Write-AVDTuneUndoFile (Get-AVDTuneMaskingUndoPath $Root) ([ordered]@{ At = $Undo.At; Name = $Undo.Name; Files = $files; Groups = $groups; Shortcuts = $shortcuts } | ConvertTo-Json -Depth 6)
}

function Save-AVDTuneMaskingBackup {
    # What is about to be overwritten or deleted by an undo goes into config\masking-backups first (a failed backup stops the undo)
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$Bytes, [int]$Keep = 20)
    $name = '{0}-{1}-{2}.json' -f [datetime]::UtcNow.ToString('yyyyMMddHHmmssfff'), [guid]::NewGuid().ToString('N').Substring(0, 6), (Split-Path $Path -Leaf)
    $folder = Join-Path $Root 'config\masking-backups'
    Write-AVDTuneFile (Join-Path $folder $name) ([ordered]@{ Path = $Path; Sha256 = (Get-AVDTuneBytesSha256 $Bytes); Bytes = [Convert]::ToBase64String($Bytes) } | ConvertTo-Json)
    # retention: only the newest $Keep backups stay (the name starts with a UTC time stamp). Plain files of this folder only, no recursion, no links followed.
    try {
        $old = @([IO.Directory]::GetFiles($folder, '*.json') | Where-Object { (Split-Path $_ -Leaf) -match '\A\d{17}-[0-9a-f]{6}-' -and ((New-Object IO.FileInfo $_).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 } | Sort-Object { Split-Path $_ -Leaf } -Descending | Select-Object -Skip ([Math]::Max(1, $Keep)))
        foreach ($f in $old) { [IO.File]::Delete($f) }
    }
    catch { }   # a failed clean-up never stops the undo that needs the backup
}

#endregion

#region changing rule sets

function Test-AVDTuneMaskingNeedsChange {
    # True when at least one step would change something
    param([object[]]$Steps, $Machine)
    foreach ($s in @($Steps)) { if (-not (ConvertTo-AVDTuneTestResult (& $s.Test $Machine)).Compliant) { return $true } }
    $false
}

function New-AVDTuneMaskingFileStep {
    # A file of the rules folder: compliant when the bytes equal; Apply writes (the adapter refuses an unsafe folder and replaces atomically)
    param([string]$Id, [string]$Title, $M, [string]$Path, [byte[]]$Bytes)
    $test = { param($mach) $cur = & $M.ReadBytes $Path; $same = (Test-AVDTuneMaskBytesEqual $cur $Bytes); @{ Compliant = [bool]$same; State = $(if ($null -eq $cur) { 'absent' } else { "$($cur.Length) bytes" }) } }.GetNewClosure()
    $apply = { param($mach) & $M.WriteBytes $Path $Bytes }.GetNewClosure()
    New-AVDTuneStep -Id $Id -Section AppMasking -Title $Title -Why 'FSLogix uses rule files in this folder immediately.' -SourceUrl "$script:Learn/tutorial-application-rule-sets" -Risk Medium -Test $test -Apply $apply
}

function Get-AVDTuneRuleSetAssignment {
    <# What the existing assignment of a rule set means now (Text, Effect), or $null when there is none. For the confirmation on the page. #>
    param([Parameter(Mandatory)]$M, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-AVDTuneMaskingName $Name)) { throw "'$Name' is not a valid rule set name." }
    $b = & $M.ReadBytes (Join-Path $M.RulesFolder "$Name.fxa")
    if ($null -eq $b) { return $null }
    Get-AVDTuneRuleVisibility (ConvertFrom-AVDTuneFxaText (ConvertFrom-AVDTuneRuleBytes $b))
}

function Save-AVDTuneRuleSet {
    <#
        Creates a rule set or adds to an existing one: -Entries (@{ Folder; Name }) become hiding rules (existing rules stay, an existing entry is not doubled),
        the assignment becomes -Visibility with -Groups (@{ Account = 'DOMAIN\Group'; Dn; Sid; Sam }; a group with Sid is checked against the domain controller by sAMAccountName and
        SID, the DN is taken from the DC). -CreateGroup (@{ Kind = 'Ad'|'Local'; Name; OuDn }) creates the group first: AD only with -Confirmed, with $Ldap/$Conn/$Directory, the OU must be
        one of the DC's; a group that exists is refused. An existing rule set that has parse problems or rules of another type (registry, printers ...) is not changed. An existing
        assignment that would mean something else needs -ExpectedChange (@{ Old; New }, taken from the .AssignmentChange of the preview run and confirmed by the administrator): the module compares it
        with the real Old and New and refuses on any difference (also when the rule set changed since the preview). A group in -Groups without Sid is refused when a domain controller is given.
        Validated first, then Invoke-AVDTune; the undo record is written after the run with what changed. -WhatIf changes nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$M, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][object[]]$Entries,
        [ValidateSet('Hidden', 'HiddenExceptGroups')][string]$Visibility = 'Hidden', [object[]]$Groups = @(), $CreateGroup, $Ldap, $Conn, $Directory,
        [switch]$Confirmed, $ExpectedChange, [string]$User, [string]$SnapshotId, [switch]$WhatIf
    )
    if (-not (Test-AVDTuneMaskingName $Name)) { throw "'$Name' is not a valid rule set name (letters, digits, space, '.', '_', '-', up to 64 characters)." }
    if (@($Entries).Count -eq 0) { throw 'No file to hide.' }
    foreach ($e in @($Entries)) { $why = Test-AVDTuneMaskingRulePath ([string]$e.Folder) ([string]$e.Name); if ($why) { throw $why } }
    $grpRows = New-Object System.Collections.ArrayList
    $steps = New-Object System.Collections.ArrayList
    $undo = [ordered]@{ At = (& $Machine.Now).ToString('o'); Name = $Name; Files = @(); Groups = @(); Shortcuts = @() }
    $haveLdap = [bool]($Ldap -and $Conn -and $Directory)
    $w = if ($Ldap) { New-AVDTuneLdapWriter -Ldap $Ldap } else { $null }

    # --- existing rule set first: nothing is changed that AVDTune does not understand completely
    $fxrPath = Join-Path $M.RulesFolder "$Name.fxr"; $fxaPath = Join-Path $M.RulesFolder "$Name.fxa"
    $oldFxr = & $M.ReadBytes $fxrPath; $oldFxa = & $M.ReadBytes $fxaPath
    $fxr = $null; $oldFxaParsed = $null
    if ($null -ne $oldFxr) {
        $fxr = ConvertFrom-AVDTuneFxrText (ConvertFrom-AVDTuneRuleBytes $oldFxr)
        if (@($fxr.Problems).Count -gt 0) { throw "The rule set '$Name' is not changed: its .fxr has problems ($(@($fxr.Problems) -join ' '))." }
        if (@($fxr.Entries | Where-Object { -not $_.Rule }).Count -gt 0) { throw "The rule set '$Name' contains rules of another type than hiding a file (registry, printers ...). It is not changed: the new assignment would apply to those rules too. Use another name." }
    }
    if ($null -ne $oldFxa) {
        $oldFxaParsed = ConvertFrom-AVDTuneFxaText (ConvertFrom-AVDTuneRuleBytes $oldFxa)
        if (@($oldFxaParsed.Problems).Count -gt 0) { throw "The rule set '$Name' is not changed: its .fxa has problems ($(@($oldFxaParsed.Problems) -join ' '))." }
    }
    if ($null -eq $fxr) { $fxr = ConvertFrom-AVDTuneFxrText "1`r`n" }

    # --- groups given by the caller (existing ones): bound by sAMAccountName and SID against the domain controller
    foreach ($g in @(@($Groups) | Where-Object { $_ })) {
        $sid = [string](Get-AVDTuneProp $g 'Sid')
        if ($sid) {
            if (-not $haveLdap) { throw 'An AD group is checked against the domain controller: connect to it first (start sequence).' }
            $sam = [string](Get-AVDTuneProp $g 'Sam'); if (-not $sam) { throw 'The group has no sAMAccountName.' }
            $x = Get-AVDTuneAdGroup -Ldap $w -Conn $Conn -BaseDn ([string]$Directory.DefaultNamingContext) -Name $sam
            if (-not $x) { throw "The group '$sam' is not in the domain." }
            if ($x.Sid -ne $sid) { throw "The group '$sam' has another SID in the domain than the one chosen. Choose it again." }
            if (-not $x.Security) { throw "The group '$sam' is not a security group." }
            [void]$grpRows.Add([pscustomobject]@{ Account = "$([string]$Directory.NetBiosName)\$($x.Sam)"; Dn = $x.Dn })
        }
        else {
            if ($Ldap -or $Conn -or $Directory) { throw "The group '$([string](Get-AVDTuneProp $g 'Account'))' has no SID: with a domain controller every group is bound by sAMAccountName and SID, not taken from the caller's account and DN." }
            [void]$grpRows.Add([pscustomobject]@{ Account = [string]$g.Account; Dn = [string](Get-AVDTuneProp $g 'Dn') })
        }
    }

    # --- group to create
    $adminDn = ''
    if ($CreateGroup) {
        $gk = [string]$CreateGroup.Kind; $gn = [string]$CreateGroup.Name
        if ($gk -notin 'Ad', 'Local') { throw "Unknown group kind '$gk'." }
        if (-not (Test-AVDTuneMaskingGroupName $gn)) { throw "'$gn' is not a valid group name." }
        if ($Visibility -ne 'HiddenExceptGroups') { throw 'A group is only created for the visibility HiddenExceptGroups.' }
        $desc = $script:GroupDescription + $Name
        $item = @{ StepId = 'appmasking.group.create'; Kind = $gk; Name = $gn; Dn = ''; NamingContext = ''; Guid = ''; Sid = '' }
        if ($gk -eq 'Ad') {
            if (-not $haveLdap) { throw 'A group in AD needs the connection to the domain controller (start sequence).' }
            $nc = [string]$Directory.DefaultNamingContext
            if (-not [string]$Directory.NetBiosName) { throw 'The NetBIOS name of the domain is not known; read the directory in the start sequence first.' }
            if (-not (Test-AVDTuneOuDn ([string]$CreateGroup.OuDn) @($Directory.OuTree))) { throw 'The OU is not one of the OUs the domain controller returned.' }
            $dn = "CN=$gn,$([string]$CreateGroup.OuDn)"
            $existing = Get-AVDTuneAdGroup -Ldap $w -Conn $Conn -BaseDn $nc -Name $gn
            if ($existing) { throw "The group '$gn' exists already ($($existing.Dn)). Choose it as an existing group instead." }
            if (-not $WhatIf -and -not $Confirmed) { throw 'Creating a group in Active Directory needs your confirmation.' }
            $test = { param($mach) $g = Get-AVDTuneAdGroup -Ldap $w -Conn $Conn -BaseDn $nc -Name $gn; @{ Compliant = [bool]$g; State = $(if ($g) { $g.Dn } else { 'absent' }) } }.GetNewClosure()
            $apply = {
                param($mach)
                & $w.Add $Conn $dn ([ordered]@{ objectClass = 'group'; sAMAccountName = $gn; groupType = '-2147483646'; description = $desc })
                $made = $null; $readErr = ''
                try { $made = Get-AVDTuneAdGroup -Ldap $w -Conn $Conn -BaseDn $nc -Name $gn } catch { $readErr = $_.Exception.Message }   # read back: the undo finds the group by its GUID and checks its SID
                if (-not $made -or -not $made.Guid -or -not $made.Sid) {
                    # the group exists but the record cannot be complete: a provisional record with the DN (no GUID and SID: undo will not delete it by itself), the DN in the error
                    $item.Provisional = $true; $item.Dn = $dn
                    $prov = [ordered]@{ At = $undo.At; Name = $undo.Name; Files = @(); Shortcuts = @(); Groups = @(@{ StepId = 'appmasking.group.create'; Kind = 'Ad'; Name = $gn; Dn = $dn; NamingContext = $nc; Guid = ''; Sid = ''; Provisional = $true }) }
                    try { Write-AVDTuneUndoFile (Get-AVDTuneMaskingUndoPath $Root) ($prov | ConvertTo-Json -Depth 6) } catch { }
                    throw "The group $gn was created ($dn) but its object GUID and SID could not be read back$(if ($readErr) { " ($readErr)" }). It was not recorded completely: check it in AD and delete it by hand if it is not needed."
                }
                $item.Dn = $made.Dn; $item.Guid = $made.Guid; $item.Sid = $made.Sid
            }.GetNewClosure()
            [void]$steps.Add((New-AVDTuneStep -Id 'appmasking.group.create' -Section AppMasking -Title "AD group $gn in $([string]$CreateGroup.OuDn)" -Why 'The group is the switch: members see the hidden items. Membership stays in AD.' -SourceUrl "$script:Learn/concepts-fslogix-apps-rule-editor-rule-sets" -Risk High -Test $test -Apply $apply))
            $item.Dn = $dn; $item.NamingContext = $nc
            [void]$grpRows.Add([pscustomobject]@{ Account = "$([string]$Directory.NetBiosName)\$gn"; Dn = $dn })
        }
        else {
            if (& $M.LocalGroupExists $gn) { throw "The local group '$gn' exists already. It is not taken over: choose another name." }
            if (-not $WhatIf -and -not $Confirmed) { throw 'Creating a local group needs your confirmation.' }
            $test = { param($mach) $e = & $M.LocalGroupExists $gn; @{ Compliant = [bool]$e; State = $(if ($e) { 'exists' } else { 'absent' }) } }.GetNewClosure()
            $apply = { param($mach) & $M.LocalGroupCreate $gn $desc; $i = & $M.LocalGroupInfo $gn; if (-not $i.Exists -or -not $i.Sid) { throw "The local group $gn was created but its SID could not be read." }; $item.Sid = [string]$i.Sid }.GetNewClosure()
            [void]$steps.Add((New-AVDTuneStep -Id 'appmasking.group.create' -Section AppMasking -Title "Local group $gn" -Why 'The local group is the switch; its members are set on the session hosts (not verified on a VM).' -SourceUrl "$script:Learn/concepts-fslogix-apps-rule-editor-rule-sets" -Risk Medium -Test $test -Apply $apply))
            [void]$grpRows.Add([pscustomobject]@{ Account = "$(& $Machine.ComputerName)\$gn"; Dn = '' })
        }
        $undo.Groups = @($item)
    }
    if ($haveLdap -and $Visibility -eq 'HiddenExceptGroups') { $adminDn = Get-AVDTuneBuiltinAdminDn -Ldap $w -Conn $Conn -DefaultNc ([string]$Directory.DefaultNamingContext) }
    if ($Visibility -eq 'HiddenExceptGroups' -and $grpRows.Count -eq 0) { throw 'Choose at least one group, or create one.' }
    foreach ($g in $grpRows) { if (-not $g.Account -or [string]$g.Account -notmatch '\A[^\\\x00-\x1F\t]+\\[^\\\x00-\x1F\t]+\z') { throw "The group account '$($g.Account)' is not of the form DOMAIN\Group." } }

    # --- files: keep what is there, add what is missing; the assignment is ours
    $list = New-Object System.Collections.ArrayList; foreach ($x in @($fxr.Entries)) { [void]$list.Add($x) }
    foreach ($e in @($Entries)) {
        $dupe = @($list | Where-Object { $_.Rule -and $_.Rule.Folder -ieq [string]$e.Folder -and $_.Rule.Name -ieq [string]$e.Name }).Count -gt 0
        if (-not $dupe) { [void]$list.Add([pscustomobject]@{ Pre = @('##'); Line = (ConvertTo-AVDTuneFxrRuleLine ([string]$e.Folder) ([string]$e.Name)); Rule = $null }) }
    }
    $fxr.Entries = @($list)
    $adminName = & $M.ResolveAccountName $script:AdminsSid
    $rows = ConvertTo-AVDTuneFxaRows -Visibility $Visibility -Groups @($grpRows) -AdminDn $adminDn -AdminName $adminName -Time ([string]((& $Machine.Now).ToUniversalTime().ToFileTimeUtc()))
    $fxa = [pscustomobject]@{ Header = "1`t"; Rows = @($rows) }
    $fxrBytes = ConvertTo-AVDTuneRuleBytes (ConvertTo-AVDTuneFxrText $fxr); $fxaBytes = ConvertTo-AVDTuneRuleBytes (ConvertTo-AVDTuneFxaText $fxa)
    $change = $null
    if ($oldFxaParsed) {
        $oldVis = Get-AVDTuneRuleVisibility $oldFxaParsed; $newVis = Get-AVDTuneRuleVisibility $fxa
        if (-not (Test-AVDTuneMaskBytesEqual $oldFxa $fxaBytes) -and $oldVis.Text -cne $newVis.Text) {
            $change = [pscustomobject]@{ Old = $oldVis.Text; New = $newVis.Text }
            if (-not $WhatIf -and -not $ExpectedChange) { throw "The assignment of the existing rule set '$Name' would change from '$($oldVis.Text)' to '$($newVis.Text)'. Confirm this change explicitly (pass Old and New of the preview as -ExpectedChange)." }
        }
    }
    # what the administrator confirmed (Old and New of the preview) must be exactly what is about to be written: a rule set that changed since the preview is not touched
    if (-not $WhatIf -and $ExpectedChange) {
        $isMap = $ExpectedChange -is [System.Collections.IDictionary]   # a hashtable (the page) or an object (parsed json)
        $eo = if ($isMap) { [string]$ExpectedChange['Old'] } else { [string](Get-AVDTuneProp $ExpectedChange 'Old') }
        $en = if ($isMap) { [string]$ExpectedChange['New'] } else { [string](Get-AVDTuneProp $ExpectedChange 'New') }
        $co = if ($change) { $change.Old } else { '(no change)' }; $cn = if ($change) { $change.New } else { '(no change)' }
        if (-not $change -or $eo -cne $co -or $en -cne $cn) { throw "The assignment of the rule set '$Name' is not what the preview showed (confirmed: '$eo' -> '$en'; now: '$co' -> '$cn'). Nothing was written; run the preview again." }
    }
    [void]$steps.Add((New-AVDTuneMaskingFileStep -Id 'appmasking.rules.fxr' -Title "Rule set ${Name}: $(@($Entries).Count) hiding rule(s)" -M $M -Path $fxrPath -Bytes $fxrBytes))
    [void]$steps.Add((New-AVDTuneMaskingFileStep -Id 'appmasking.rules.fxa' -Title "Rule set ${Name}: assignment ($Visibility)" -M $M -Path $fxaPath -Bytes $fxaBytes))
    $undo.Files = @(
        @{ StepId = 'appmasking.rules.fxr'; Path = $fxrPath; Before = $(if ($null -ne $oldFxr) { [Convert]::ToBase64String($oldFxr) } else { $null }); AfterSha = (Get-AVDTuneBytesSha256 $fxrBytes) }
        @{ StepId = 'appmasking.rules.fxa'; Path = $fxaPath; Before = $(if ($null -ne $oldFxa) { [Convert]::ToBase64String($oldFxa) } else { $null }); AfterSha = (Get-AVDTuneBytesSha256 $fxaBytes) })
    $run = Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'App Masking'; Steps = @($steps | ForEach-Object { $_.Id }) }) -Catalog @($steps) -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf
    Save-AVDTuneMaskingUndo -Root $Root -Undo ([pscustomobject]$undo) -Run $run
    $run | Add-Member -NotePropertyName AssignmentChange -NotePropertyValue $change -Force
    $run
}

function Remove-AVDTuneRuleSet {
    <# Deletes both files of a rule set (the old content goes into the undo record when the delete worked). The group, if any, stays: it may be used elsewhere. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$M, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Name, [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    if (-not (Test-AVDTuneMaskingName $Name)) { throw "'$Name' is not a valid rule set name." }
    $paths = @((Join-Path $M.RulesFolder "$Name.fxr"), (Join-Path $M.RulesFolder "$Name.fxa"))
    $old = @(foreach ($p in $paths) { $b = & $M.ReadBytes $p; @{ StepId = "appmasking.remove.$([IO.Path]::GetExtension($p).TrimStart('.'))"; Path = $p; Before = $(if ($null -ne $b) { [Convert]::ToBase64String($b) } else { $null }); AfterSha = $null } })
    if (@($old | Where-Object { $_.Before }).Count -eq 0) { throw "The rule set '$Name' does not exist." }
    $steps = @(foreach ($p in $paths) {
            $pp = $p
            New-AVDTuneStep -Id "appmasking.remove.$([IO.Path]::GetExtension($pp).TrimStart('.'))" -Section AppMasking -Title "Remove $([IO.Path]::GetFileName($pp))" -Risk Medium `
                -Test ({ param($mach) @{ Compliant = ($null -eq (& $M.ReadBytes $pp)); State = '' } }.GetNewClosure()) -Apply ({ param($mach) & $M.DeleteFile $pp }.GetNewClosure())
        })
    $run = Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'App Masking remove'; Steps = @($steps | ForEach-Object { $_.Id }) }) -Catalog $steps -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf
    Save-AVDTuneMaskingUndo -Root $Root -Undo ([pscustomobject]@{ At = (& $Machine.Now).ToString('o'); Name = $Name; Files = $old; Groups = @(); Shortcuts = @() }) -Run $run
    $run
}

function Undo-AVDTuneMaskingChange {
    <#
        Puts back what the last change did: files as they were (a file that was not there is deleted) but only while the file is still what AVDTune wrote (SHA256; -Force overrides) and
        after the current content went into config\masking-backups; shortcuts AVDTune made (marker checked) are removed; a group AVDTune created is deleted again only when it is found by its
        object GUID, still has AVDTune's description and the recorded SID, and has no members (asked by a filter). Remaining gap, not closable with LDAP: a member added between the check
        and the delete. An AD group needs the same kind of connection as the change.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$M, [string]$Root = (Get-AVDTuneRoot), $Ldap, $Conn, [switch]$Force, [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    $u = Read-AVDTuneMaskingUndo $Root
    if (-not $u) { throw 'There is nothing to undo: no App Masking change was recorded.' }
    $steps = New-Object System.Collections.ArrayList
    $i = 0; $gd = $script:GroupDescription
    foreach ($f in @($u.Files)) {
        $path = [string]$f.Path; $before = Get-AVDTuneProp $f 'Before'; $afterSha = [string](Get-AVDTuneProp $f 'AfterSha')
        $bytes = if ($before) { [Convert]::FromBase64String([string]$before) } else { $null }
        if (-not $path.StartsWith($M.RulesFolder.TrimEnd([char]92) + [char]92, [StringComparison]::OrdinalIgnoreCase) -or @($path -split '\\') -contains '..') { throw "The undo record names a path outside the rules folder ($path)." }
        $i++
        $test = { param($mach) $cur = & $M.ReadBytes $path; $ok = (Test-AVDTuneMaskBytesEqual $cur $bytes); @{ Compliant = [bool]$ok; State = '' } }.GetNewClosure()
        $apply = {
            param($mach)
            $cur = & $M.ReadBytes $path
            if (-not $Force -and $null -ne $cur) {
                if ($afterSha -and (Get-AVDTuneBytesSha256 $cur) -ne $afterSha) { throw "$path was changed after AVDTune wrote it: not overwritten. Look at it, or undo with -Force (the current content is saved first)." }
                if (-not $afterSha) { throw "$path was created after AVDTune removed it: not overwritten. Look at it, or undo with -Force (the current content is saved first)." }
            }
            if ($null -ne $cur) { Save-AVDTuneMaskingBackup -Root $Root -Path $path -Bytes $cur }
            if ($null -eq $bytes) { & $M.DeleteFile $path } else { & $M.WriteBytes $path $bytes }
        }.GetNewClosure()
        [void]$steps.Add((New-AVDTuneStep -Id "appmasking.undo.file$i" -Section AppMasking -Title "Undo: $([IO.Path]::GetFileName($path))" -Test $test -Apply $apply))
    }
    foreach ($s in @(Get-AVDTuneProp $u 'Shortcuts')) {
        if (-not $s) { continue }
        $path = [string]$s.Path; $i++
        if (-not $path.StartsWith(((& $M.PublicDesktopFolder).TrimEnd([char]92) + [char]92), [StringComparison]::OrdinalIgnoreCase)) { throw "The undo record names a shortcut outside the Public Desktop ($path)." }
        $marker = $script:ShortcutMarker
        $test = { param($mach) @{ Compliant = (-not (& $M.ShortcutExists $path)); State = '' } }.GetNewClosure()
        $apply = { param($mach) $c = & $M.ReadShortcut $path; if ($c -and -not ([string]$c.Description).StartsWith($marker)) { throw "$path does not carry AVDTune's marker any more: it is not deleted." }; & $M.DeleteShortcut $path }.GetNewClosure()
        [void]$steps.Add((New-AVDTuneStep -Id "appmasking.undo.shortcut$i" -Section AppMasking -Title "Undo: shortcut $([IO.Path]::GetFileName($path))" -Test $test -Apply $apply))
    }
    foreach ($g in @(Get-AVDTuneProp $u 'Groups')) {
        if (-not $g) { continue }
        $gn = [string]$g.Name; $i++
        if (-not (Test-AVDTuneMaskingGroupName $gn)) { throw "The undo record names an invalid group '$gn'." }
        $rsid = [string](Get-AVDTuneProp $g 'Sid'); $rguid = [string](Get-AVDTuneProp $g 'Guid')
        if ([string]$g.Kind -eq 'Ad') {
            if (-not $rguid -or -not $rsid) {
                # a group that was created but could not be read back (provisional record): nothing is deleted without GUID and SID; the step fails with the DN, the other undo steps still run
                $gdn = [string](Get-AVDTuneProp $g 'Dn')
                $why = "The undo record of the group $gn has no object GUID and SID: it is not deleted$(if ($gdn) { " (it was created as ${gdn}: check it in AD and delete it by hand if it is not needed)" })."
                [void]$steps.Add((New-AVDTuneStep -Id "appmasking.undo.group$i" -Section AppMasking -Title "Undo: group $gn" -Risk High -Test ({ param($mach) @{ Compliant = $false; State = 'not recorded completely' } }) -Apply ({ param($mach) throw $why }.GetNewClosure())))
                continue
            }
            if (-not ($Ldap -and $Conn)) { throw 'Undoing the AD group needs the connection to the domain controller (start sequence).' }
            $w = New-AVDTuneLdapWriter -Ldap $Ldap; $nc = [string]$g.NamingContext
            $test = { param($mach) $x = Get-AVDTuneAdGroupByGuid -Ldap $w -Conn $Conn -BaseDn $nc -GuidHex $rguid; @{ Compliant = (-not $x); State = $(if (-not $x) { 'group not found' } else { 'group exists' }) } }.GetNewClosure()
            $apply = {
                param($mach)
                $x = Get-AVDTuneAdGroupByGuid -Ldap $w -Conn $Conn -BaseDn $nc -GuidHex $rguid
                if (-not $x) { return }
                if (-not $x.Description.StartsWith($gd)) { throw "The group $gn does not carry AVDTune's description any more: it is not deleted." }
                if ($x.Sid -ne $rsid) { throw "The group $gn has another SID than the one AVDTune created: it is not deleted." }
                if ($x.MemberCount -gt 0 -or (Test-AVDTuneAdGroupHasMembers -Ldap $w -Conn $Conn -BaseDn $nc -GuidHex $rguid)) { throw "The group $gn has members: it is not deleted. Remove the members in AD first." }
                & $w.Delete $Conn "<GUID=$rguid>"
            }.GetNewClosure()
        }
        else {
            if (-not $rsid) { throw "The undo record of the local group $gn has no SID: it is not deleted." }
            $test = { param($mach) @{ Compliant = (-not (& $M.LocalGroupInfo $gn).Exists); State = $(if (-not (& $M.LocalGroupInfo $gn).Exists) { 'group not found' } else { 'group exists' }) } }.GetNewClosure()
            $apply = {
                param($mach)
                $x = & $M.LocalGroupInfo $gn
                if (-not $x.Exists) { return }
                if ([string]$x.Description -notlike "$gd*") { throw "The local group $gn does not carry AVDTune's description: it is not deleted." }
                if ([string]$x.Sid -ne $rsid) { throw "The local group $gn has another SID than the one AVDTune created: it is not deleted." }
                if ([int]$x.MemberCount -gt 0) { throw "The local group $gn has members: it is not deleted." }
                & $M.LocalGroupDelete $gn
            }.GetNewClosure()
        }
        [void]$steps.Add((New-AVDTuneStep -Id "appmasking.undo.group$i" -Section AppMasking -Title "Undo: group $gn" -Risk High -Test $test -Apply $apply))
    }
    if ($steps.Count -eq 0) { throw 'The undo record is empty.' }
    $run = Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'App Masking undo'; Steps = @($steps | ForEach-Object { $_.Id }) }) -Catalog @($steps) -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf
    foreach ($r in @($run.Results | Where-Object { $_.Id -like 'appmasking.undo.group*' -and $_.Status -eq 'Unchanged' -and $_.Before -eq 'group not found' })) { $r.Message = 'group not found, nothing deleted' }   # said in the result: nothing was deleted because the group was not there
    if (-not $WhatIf -and @($run.Results | Where-Object { $_.Status -eq 'Failed' }).Count -eq 0) { Remove-Item -LiteralPath (Get-AVDTuneMaskingUndoPath $Root) -Force -ErrorAction SilentlyContinue }
    $run
}

#endregion

#region comfort shortcuts (5c)

function Get-AVDTuneComfortShortcuts {
    <# The shortcuts AVDTune can put on the Public Desktop. Targets and the working folder come from Windows' own folders (never PATH or environment variables). #>
    param([Parameter(Mandatory)]$M)
    $sys = & $M.SystemFolder
    @([pscustomobject]@{
            Id = 'logoff'; Name = 'Abmelden.lnk'; Title = 'Abmelden (sign out)'; Target = (Join-Path $sys 'shutdown.exe'); Arguments = '/l'; Icon = (Join-Path $sys 'shell32.dll') + ',44'; WorkingDirectory = $sys
            Description = "${script:ShortcutMarker}: signs the user out without a confirmation dialog"; Verified = $false
            Note = 'shutdown.exe /l signs the current user out. The icon index in shell32.dll is not documented by Microsoft (not verified on a VM).'
        })
}

function Add-AVDTuneComfortShortcut {
    <# Creates a comfort shortcut on the Public Desktop (read only for users). An existing file of that name that is not ours is never replaced; one of ours with another target, icon or ACL is made right. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$M, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][ValidateSet('logoff')][string]$Id, [string[]]$ExpectedWarnings, [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    $s = @(Get-AVDTuneComfortShortcuts -M $M | Where-Object Id -eq $Id)[0]
    $path = Join-Path (& $M.PublicDesktopFolder) $s.Name
    $cur = & $M.ReadShortcut $path
    if ($cur -and -not ([string]$cur.Description).StartsWith($script:ShortcutMarker)) { throw "$($s.Name) exists on the Public Desktop and was not made by AVDTune: it is not replaced." }
    # the folder: a link, a foreign owner or write access of anyone but the Windows default groups stops; that default (Authenticated Users/Users/Interactive with Modify) is a warning that the
    # administrator must confirm explicitly: -ExpectedWarnings carries the texts of the preview (.DesktopWarnings of the -WhatIf run) and must equal the current ones. The file ACL of the shortcut stays strict.
    $folder = if ($M.PSObject.Properties['ShortcutFolderFindings']) { & $M.ShortcutFolderFindings $path } else { [pscustomobject]@{ Problems = @(); Warnings = @() } }
    if (@($folder.Problems).Count -gt 0) { throw "The Public Desktop is not safe ($(@($folder.Problems) -join '; ')): no shortcut was written." }
    $warnings = @($folder.Warnings)
    if (-not $WhatIf -and $warnings.Count -gt 0 -and (@($ExpectedWarnings) -join "`n") -cne ($warnings -join "`n")) { throw "The Public Desktop folder can be changed by users ($($warnings -join '; ')). That is the Windows default, but anybody could replace or delete the shortcut: confirm this explicitly (the preview shows it)." }
    $stepId = "appmasking.comfort.$Id"
    $test = { param($mach) $c = & $M.ReadShortcut $path; @{ Compliant = [bool]($c -and $c.Target -ieq $s.Target -and $c.Arguments -ceq $s.Arguments -and $c.Icon -ieq $s.Icon -and [string]$c.WorkingDirectory -ieq $s.WorkingDirectory -and @($c.AclProblems).Count -eq 0); State = $(if ($c) { $c.Target } else { 'absent' }) } }.GetNewClosure()
    $apply = { param($mach) & $M.CreateShortcut $path $s.Target $s.Arguments $s.Icon $s.Description $s.WorkingDirectory }.GetNewClosure()
    $step = New-AVDTuneStep -Id $stepId -Section AppMasking -Title "Public Desktop shortcut $($s.Title)" -Why 'A comfort shortcut for all users.' -Risk Low -Test $test -Apply $apply
    $run = Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'App Masking comfort shortcut'; Steps = @($step.Id) }) -Catalog @($step) -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf
    Save-AVDTuneMaskingUndo -Root $Root -Undo ([pscustomobject]@{ At = (& $Machine.Now).ToString('o'); Name = $s.Name; Files = @(); Groups = @(); Shortcuts = @(@{ StepId = $stepId; Path = $path }) }) -Run $run
    $run | Add-Member -NotePropertyName DesktopWarnings -NotePropertyValue @($warnings) -Force
    $run
}

#endregion

#region real adapter

function Get-AVDTuneWriteChainFindings {
    <#
        Every component of a path from the drive root down: none may be a link; every component below -AclBelow (default: the drive root, which keeps the Windows default) must pass
        Get-AVDTuneAclFindings (owner Administrators/SYSTEM/TrustedInstaller, no write for others; inherit-only entries do not count). -AllowMissingLeaf: the file itself does not exist yet.
        -WarnComponent (one folder of the chain) with -WarnWriteSids: write access of exactly these SIDs on that folder is a Warning, not a Problem (the Public Desktop, where Windows gives
        Authenticated Users, Users and Interactive Modify); a link, a foreign owner and write access of anyone else on it, and every problem of every other component stay Problems.
        Returns @{ Problems; Warnings }. $ReadReport is Read-AVDTuneAclReport (a fake in the checks).
    #>
    param([Parameter(Mandatory)][string]$Path, [string]$AclBelow, [switch]$AllowMissingLeaf, [scriptblock]$ReadReport = { param($p) Read-AVDTuneAclReport $p }, [string]$WarnComponent, [string[]]$WarnWriteSids = @())
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($full).TrimEnd('\')
    $skip = if ($AclBelow) { [IO.Path]::GetFullPath($AclBelow).TrimEnd('\') } else { $root }
    $warnAt = if ($WarnComponent) { [IO.Path]::GetFullPath($WarnComponent).TrimEnd('\') } else { $null }
    $parts = @($full.Substring($root.Length).Split([char]92) | Where-Object { $_ })
    $components = New-Object System.Collections.ArrayList; [void]$components.Add($root + '\')
    $cur = $root; foreach ($p in $parts) { $cur = "$cur\$p"; [void]$components.Add($cur) }
    $problems = New-Object System.Collections.ArrayList; $warnings = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $components.Count; $i++) {
        $c = [string]$components[$i]
        $r = & $ReadReport $c
        if (-not $r.Exists) { if ($AllowMissingLeaf -and $i -eq $components.Count - 1) { continue }; [void]$problems.Add("$c does not exist"); continue }
        if ($r.Link) { [void]$problems.Add("$c is a link"); continue }
        $below = $c.TrimEnd('\').Length -gt $skip.Length -and $c.StartsWith($skip, [StringComparison]::OrdinalIgnoreCase)
        if ($below) {
            $sids = if ($warnAt -and [string]::Equals($c.TrimEnd('\'), $warnAt, [StringComparison]::OrdinalIgnoreCase)) { $WarnWriteSids } else { @() }
            $f = Get-AVDTuneAclFindings -Report $r -WarnWriteSids $sids
            foreach ($x in @($f.Problems)) { [void]$problems.Add("${c}: $x") }
            foreach ($x in @($f.Warnings)) { [void]$warnings.Add("${c}: $x") }
        }
    }
    [pscustomobject]@{ Problems = @($problems); Warnings = @($warnings) }
}

function Get-AVDTuneWriteChainProblems {
    # The stops of Get-AVDTuneWriteChainFindings without any warning rule (every write access of others is a problem). Used for the rules folder and every other caller.
    param([Parameter(Mandatory)][string]$Path, [string]$AclBelow, [switch]$AllowMissingLeaf, [scriptblock]$ReadReport = { param($p) Read-AVDTuneAclReport $p })
    @((Get-AVDTuneWriteChainFindings -Path $Path -AclBelow $AclBelow -AllowMissingLeaf:$AllowMissingLeaf -ReadReport $ReadReport).Problems)
}

function Get-AVDTunePublicDesktopFindings {
    # Problems and Warnings for a shortcut path on the Public Desktop: Authenticated Users / Users / Interactive with Modify on the folder is the Windows default and only a Warning
    # (confirmed explicitly); a link, a foreign owner or write access of anyone else on the folder, or a link above it, is a stop.
    param([Parameter(Mandatory)][string]$Path, [scriptblock]$ReadReport = { param($p) Read-AVDTuneAclReport $p })
    $desk = Split-Path $Path -Parent
    Get-AVDTuneWriteChainFindings -Path $Path -AllowMissingLeaf -AclBelow (Split-Path $desk -Parent) -ReadReport $ReadReport -WarnComponent $desk -WarnWriteSids @('S-1-5-11', 'S-1-5-32-545', 'S-1-5-4')
}

function New-AVDTuneMaskingAdapter {
    <# The real adapter. NOT exercised by the checks beyond construction: written from the documentation, to be tried on a throw-away VM (docs\app-masking.md). #>
    $a = [ordered]@{ Kind = 'Real' }
    $a.RulesFolder = Join-Path (Get-AVDTuneSystemFolder ProgramFiles) 'FSLogix\Apps\Rules'
    $a.SystemDrive = { [IO.Path]::GetPathRoot((Get-AVDTuneSystemFolder Windows)).TrimEnd('\') }
    $a.SystemFolder = { Get-AVDTuneSystemFolder System }
    $a.PublicDesktopFolder = { [Environment]::GetFolderPath('CommonDesktopDirectory') }
    $a.ListRuleFiles = { $d = Join-Path (Get-AVDTuneSystemFolder ProgramFiles) 'FSLogix\Apps\Rules'; if (-not (Test-Path -LiteralPath $d -PathType Container)) { return @() }; @([IO.Directory]::GetFiles($d) | Where-Object { $_ -match '\.(fxr|fxa)$' } | ForEach-Object { [IO.Path]::GetFileName($_) }) }
    $a.ReadBytes = {
        param($Path)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $info = New-Object IO.FileInfo $Path
        if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Path is a link: not read." }
        if ($info.Length -gt 4MB) { throw "$Path is larger than 4 MB: not read." }
        , [IO.File]::ReadAllBytes($Path)
    }
    $a.WriteBytes = {
        param($Path, [byte[]]$Bytes)
        $folder = Split-Path $Path -Parent
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "The folder $folder does not exist: FSLogix Apps is not installed." }
        $problems = @(Get-AVDTuneWriteChainProblems -Path $Path -AllowMissingLeaf)   # every component from the drive root: no link, below the root admin-only
        if ($problems.Count -gt 0) { throw "The path of $Path is not safe ($($problems -join '; ')). Nothing was written. Check it as administrator." }
        $temp = "$Path.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
        try {
            $stream = New-Object IO.FileStream($temp, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]'Write, ReadPermissions', [IO.FileShare]::None, 4096, [IO.FileOptions]::None, (New-AVDTuneFileSecurity))
            try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
            Move-AVDTuneFileReplace $temp $Path   # atomic: the target is the old or the new file at every moment
        }
        finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
        $after = @(Get-AVDTuneAclProblems (Read-AVDTuneAclReport $Path))
        if ($after.Count -gt 0) { try { [IO.File]::Delete($Path) } catch { }; throw "$Path got an unsafe ACL ($($after -join '; ')) and was removed again." }
    }
    $a.DeleteFile = {
        param($Path)
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $problems = @(Get-AVDTuneWriteChainProblems -Path $Path)
        if ($problems.Count -gt 0) { throw "The path of $Path is not safe ($($problems -join '; ')): not deleted." }
        [IO.File]::Delete($Path)
    }
    $a.ResolveAccountName = { param($Sid) (New-Object Security.Principal.SecurityIdentifier $Sid).Translate([Security.Principal.NTAccount]).Value }
    $a.ListPublicDesktop = {
        $d = [Environment]::GetFolderPath('CommonDesktopDirectory')
        $shell = New-Object -ComObject WScript.Shell
        try {
            @(foreach ($f in (New-Object IO.DirectoryInfo $d).GetFiles()) {
                    if (($f.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System)) -ne 0) { continue }
                    $o = @{ Name = $f.Name; Path = $f.FullName; Target = ''; Arguments = ''; Icon = ''; IsShortcut = ($f.Extension -ieq '.lnk') }
                    if ($o.IsShortcut) { try { $l = $shell.CreateShortcut($f.FullName); $o.Target = [string]$l.TargetPath; $o.Arguments = [string]$l.Arguments; $o.Icon = [string]$l.IconLocation; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($l) } catch { } }
                    [pscustomobject]$o
                })
        }
        finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
    $a.ReadShortcut = {
        param($Path)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $acl = @(Get-AVDTuneAclProblems (Read-AVDTuneAclReport $Path))
        $shell = New-Object -ComObject WScript.Shell
        try { $l = $shell.CreateShortcut($Path); $o = [pscustomobject]@{ Target = [string]$l.TargetPath; Arguments = [string]$l.Arguments; Icon = [string]$l.IconLocation; Description = [string]$l.Description; WorkingDirectory = [string]$l.WorkingDirectory; AclProblems = $acl }; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($l); $o }
        finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
    $a.ShortcutExists = { param($Path) Test-Path -LiteralPath $Path -PathType Leaf }
    $a.CreateShortcut = {
        # Made in the admin-only state folder, the ACL set and checked there, then moved atomically onto the Public Desktop: the file never exists there with another ACL.
        # The Public Desktop itself (and its owner) must be admin-only for writing, and no component from the drive root may be a link.
        param($Path, $Target, $Arguments, $Icon, $Description, $WorkingDirectory)
        $desk = Split-Path $Path -Parent
        # write access of Authenticated Users/Users/Interactive on the folder is the Windows default: only a warning here (the module made the administrator confirm it); everything else stops
        $deskProblems = @((Get-AVDTunePublicDesktopFindings -Path $Path).Problems)
        if ($deskProblems.Count -gt 0) { throw "The Public Desktop is not safe ($($deskProblems -join '; ')): no shortcut was written." }
        $tempDir = Join-Path (Get-AVDTuneRoot) 'temp'
        [void][IO.Directory]::CreateDirectory($tempDir)
        $tdProblems = @(Get-AVDTuneAclProblems (Read-AVDTuneAclReport $tempDir)); if ($tdProblems.Count -gt 0) { throw "$tempDir is not safe ($($tdProblems -join '; '))." }
        $temp = Join-Path $tempDir ([guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp.lnk')
        $shell = New-Object -ComObject WScript.Shell
        try {
            $l = $shell.CreateShortcut($temp); $l.TargetPath = $Target; $l.Arguments = $Arguments; $l.IconLocation = $Icon; $l.Description = $Description; $l.WorkingDirectory = $WorkingDirectory; $l.Save(); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($l)
            (New-Object IO.FileInfo $temp).SetAccessControl((New-AVDTuneFileSecurity))
            $tp = @(Get-AVDTuneAclProblems (Read-AVDTuneAclReport $temp)); if ($tp.Count -gt 0) { throw "The new shortcut has an unsafe ACL ($($tp -join '; '))." }
            Move-AVDTuneFileReplace $temp $Path
        }
        finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell); if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
        $after = @(Get-AVDTuneAclProblems (Read-AVDTuneAclReport $Path)); if ($after.Count -gt 0) { try { [IO.File]::Delete($Path) } catch { }; throw "$Path got an unsafe ACL ($($after -join '; ')) and was removed again." }
    }
    $a.ShortcutFolderFindings = { param($Path) Get-AVDTunePublicDesktopFindings -Path $Path }
    $a.DeleteShortcut = { param($Path) if (Test-Path -LiteralPath $Path) { $r = Read-AVDTuneAclReport $Path; if ($r.Link) { throw "$Path is a link." }; [IO.File]::Delete($Path) } }
    $a.LocalGroupExists = { param($Name) try { $g = [ADSI]"WinNT://./$Name,group"; [bool]$g.Path } catch { $false } }
    $a.LocalGroupCreate = { param($Name, $Description) $c = [ADSI]'WinNT://.,computer'; $g = $c.Create('group', $Name); $g.SetInfo(); $g.Description = $Description; $g.SetInfo() }
    $a.LocalGroupInfo = {
        param($Name)
        try {
            $g = [ADSI]"WinNT://./$Name,group"; if (-not $g.Path) { return @{ Exists = $false; Sid = ''; Description = ''; MemberCount = 0 } }
            @{ Exists = $true; Sid = (New-Object Security.Principal.SecurityIdentifier(([byte[]]$g.InvokeGet('objectSid')), 0)).Value; Description = [string]$g.Description; MemberCount = @($g.Invoke('Members')).Count }
        }
        catch { @{ Exists = $false; Sid = ''; Description = ''; MemberCount = 0 } }
    }
    $a.LocalGroupDelete = { param($Name) ([ADSI]'WinNT://.,computer').Delete('group', $Name) }
    [pscustomobject]$a
}

#endregion

Export-ModuleMember -Function Save-AVDTuneMaskingBackup, Get-AVDTuneWriteChainProblems, Get-AVDTuneWriteChainFindings, Get-AVDTunePublicDesktopFindings, Get-AVDTuneRuleSetAssignment, Get-AVDTuneBytesSha256, Save-AVDTuneMaskingUndo, ConvertTo-AVDTuneGuidHex, ConvertTo-AVDTuneLdapBinaryFilter, Get-AVDTuneAdGroupByGuid, Test-AVDTuneAdGroupHasMembers, Test-AVDTuneMaskBytesEqual, Test-AVDTuneMaskingNeedsChange, Get-AVDTuneMaskAttr, Test-AVDTuneMaskingName, Test-AVDTuneMaskingGroupName, Test-AVDTuneAdExistingGroupName, Test-AVDTuneMaskingPrefix, Get-AVDTuneAppGroupName, Test-AVDTuneMaskingRulePath, Test-AVDTuneOuDn,
    ConvertTo-AVDTuneRuleBytes, ConvertFrom-AVDTuneRuleBytes, ConvertFrom-AVDTuneFxrText, ConvertTo-AVDTuneFxrText, ConvertTo-AVDTuneFxrRuleLine, New-AVDTuneFxaRow,
    ConvertFrom-AVDTuneFxaText, ConvertTo-AVDTuneFxaText, ConvertTo-AVDTuneFxaRows, Get-AVDTuneRuleVisibility, Get-AVDTuneMaskingSettings, Set-AVDTuneMaskingSettings,
    Get-AVDTuneMaskingCapabilities, New-AVDTuneLdapWriter, Get-AVDTuneAdGroup, Get-AVDTuneBuiltinAdminDn, Get-AVDTuneRuleSets, Get-AVDTunePublicDesktopList,
    Get-AVDTuneMaskingOverview, Get-AVDTuneMaskingUndoPath, Save-AVDTuneRuleSet, Remove-AVDTuneRuleSet, Undo-AVDTuneMaskingChange, Get-AVDTuneComfortShortcuts,
    Add-AVDTuneComfortShortcut, New-AVDTuneMaskingAdapter
