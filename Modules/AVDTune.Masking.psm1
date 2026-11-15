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
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]*[A-Za-z0-9_-]$' -and $Name -notmatch '^[A-Za-z0-9]$') { return $false }
    if ($Name.Split('.')[0].Trim().ToUpperInvariant() -in $script:Reserved) { return $false }
    $true
}

function Test-AVDTuneMaskingGroupName {
    # A group name (sAMAccountName, local group name): no characters that are special in a DN, a filter or an account name
    param([string]$Name)
    [bool]($Name -and $Name.Length -le 64 -and $Name -match '^[A-Za-z0-9]([A-Za-z0-9 ._-]{0,62}[A-Za-z0-9_-])?$')
}

function Test-AVDTuneMaskingPrefix([string]$Prefix) { [bool]($Prefix -match '^[A-Za-z0-9]{1,16}$') }

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
    if ($Folder -notmatch '^(%SystemDriveFolder%|[A-Za-z]:)(\\[^\\/:*?"<>|\x00-\x1F]+)*$') { return "The folder '$Folder' is not a valid local folder path (no wildcards, no control characters)." }
    if (@($Folder -split '\\') -contains '..' -or @($Folder -split '\\') -contains '.') { return "The folder '$Folder' contains '.' or '..'." }
    if (-not $Name -or $Name.Length -gt 200 -or $Name -notmatch '^[^\\/:*?"<>|\x00-\x1F]+$') { return "The file name '$Name' is not valid (no path, no wildcards, no control characters)." }
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
        if ($f.Count -ge 5 -and $f[4] -match '^0x[0-9A-Fa-f]{8}$') { $rule = [pscustomobject]@{ Folder = $f[0]; Name = $f[1]; Flags = $f[4] } }
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
        if ($f.Count -ge 6 -and $f[0] -match '^0x[0-9A-Fa-f]{8}$') { $code = [Convert]::ToInt32($f[0].Substring(2), 16); [void]$rows.Add([pscustomobject]@{ Code = $code; Name = $f[1]; Dn = $f[2]; Display = $f[3]; Time = $f[4]; Raw = $lines[$i] }) }
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
            if (-not $g.Account -or $g.Account -notmatch '^[^\\\x00-\x1F\t]+\\[^\\\x00-\x1F\t]+$') { throw "The group account '$($g.Account)' is not of the form DOMAIN\Group." }
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

function Get-AVDTuneAdGroup {
    <# The group with this sAMAccountName in the domain: Dn, Sid, Description, Security, MemberCount; $null when there is none. #>
    param([Parameter(Mandatory)]$Ldap, [Parameter(Mandatory)]$Conn, [Parameter(Mandatory)][string]$BaseDn, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-AVDTuneMaskingGroupName $Name)) { throw "'$Name' is not a valid group name." }
    $r = @(& $Ldap.Search $Conn $BaseDn "(&(objectClass=group)(sAMAccountName=$(ConvertTo-AVDTuneLdapFilterValue $Name)))" 'Subtree' @('distinguishedName', 'objectSid', 'description', 'groupType', 'member'))
    if ($r.Count -eq 0) { return $null }
    if ($r.Count -gt 1) { throw "More than one group is named '$Name'." }
    $e = $r[0]; $gt = Get-AVDTuneMaskAttr $e 'groupType'
    [pscustomobject]@{
        Dn = [string]$(if (Get-AVDTuneMaskAttr $e 'distinguishedName') { Get-AVDTuneMaskAttr $e 'distinguishedName' } else { $e.Dn }); Sid = (ConvertTo-AVDTuneSid (Get-AVDTuneMaskAttr $e 'objectSid'))
        Description = [string](Get-AVDTuneMaskAttr $e 'description'); Security = $(if ($null -ne $gt) { ([int]$gt) -lt 0 } else { $true }); MemberCount = @(@($e.Attributes['member']) | Where-Object { $_ }).Count
    }
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

#endregion

#region changing rule sets

function Test-AVDTuneMaskingNeedsChange {
    # True when at least one step would change something: only then an undo record is written (a call that changes nothing must not replace the record of the last real change)
    param([object[]]$Steps, $Machine)
    foreach ($s in @($Steps)) { if (-not (ConvertTo-AVDTuneTestResult (& $s.Test $Machine)).Compliant) { return $true } }
    $false
}

function New-AVDTuneMaskingFileStep {
    # A file of the rules folder: compliant when the bytes equal; Apply writes (the adapter refuses an unsafe folder), nothing replaces an old ACL
    param([string]$Id, [string]$Title, $M, [string]$Path, [byte[]]$Bytes)
    $test = { param($mach) $cur = & $M.ReadBytes $Path; $same = (Test-AVDTuneMaskBytesEqual $cur $Bytes); @{ Compliant = [bool]$same; State = $(if ($null -eq $cur) { 'absent' } else { "$($cur.Length) bytes" }) } }.GetNewClosure()
    $apply = { param($mach) & $M.WriteBytes $Path $Bytes }.GetNewClosure()
    New-AVDTuneStep -Id $Id -Section AppMasking -Title $Title -Why 'FSLogix uses rule files in this folder immediately.' -SourceUrl "$script:Learn/tutorial-application-rule-sets" -Risk Medium -Test $test -Apply $apply
}

function Save-AVDTuneRuleSet {
    <#
        Creates a rule set or adds to an existing one: -Entries (@{ Folder; Name }) become hiding rules (existing rules and unknown lines stay, an existing entry is not doubled),
        the assignment becomes -Visibility with -Groups (@{ Account = 'DOMAIN\Group' or 'HOST\group'; Dn }). -CreateGroup (@{ Kind = 'Ad'|'Local'; Name; OuDn; Description })
        creates the group first: AD only with -Confirmed, with $Ldap/$Conn/$Directory (OU tree and naming context from the DC), the OU must be one of the DC's. The group then
        is the released group. Validated first (nothing is written when something is invalid), undo record before the run, run through Invoke-AVDTune. -WhatIf changes nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$M, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][object[]]$Entries,
        [ValidateSet('Hidden', 'HiddenExceptGroups')][string]$Visibility = 'Hidden', [object[]]$Groups = @(), $CreateGroup, $Ldap, $Conn, $Directory,
        [switch]$Confirmed, [string]$User, [string]$SnapshotId, [switch]$WhatIf
    )
    if (-not (Test-AVDTuneMaskingName $Name)) { throw "'$Name' is not a valid rule set name (letters, digits, space, '.', '_', '-', up to 64 characters)." }
    if (@($Entries).Count -eq 0) { throw 'No file to hide.' }
    foreach ($e in @($Entries)) { $why = Test-AVDTuneMaskingRulePath ([string]$e.Folder) ([string]$e.Name); if ($why) { throw $why } }
    $grpRows = @(@($Groups) | Where-Object { $_ })
    $steps = New-Object System.Collections.ArrayList
    $undo = [ordered]@{ At = (& $Machine.Now).ToString('o'); Name = $Name; Files = @(); Groups = @(); Shortcuts = @() }

    # --- group
    $adminDn = ''
    if ($CreateGroup) {
        $gk = [string]$CreateGroup.Kind; $gn = [string]$CreateGroup.Name
        if ($gk -notin 'Ad', 'Local') { throw "Unknown group kind '$gk'." }
        if (-not (Test-AVDTuneMaskingGroupName $gn)) { throw "'$gn' is not a valid group name." }
        if ($Visibility -ne 'HiddenExceptGroups') { throw 'A group is only created for the visibility HiddenExceptGroups.' }
        $desc = $script:GroupDescription + $Name
        if ($gk -eq 'Ad') {
            if (-not ($Ldap -and $Conn -and $Directory)) { throw 'A group in AD needs the connection to the domain controller (start sequence).' }
            $nc = [string]$Directory.DefaultNamingContext
            if (-not (Test-AVDTuneOuDn ([string]$CreateGroup.OuDn) @($Directory.OuTree))) { throw 'The OU is not one of the OUs the domain controller returned.' }
            $dn = "CN=$gn,$([string]$CreateGroup.OuDn)"
            $w = New-AVDTuneLdapWriter -Ldap $Ldap
            $existing = Get-AVDTuneAdGroup -Ldap $w -Conn $Conn -BaseDn $nc -Name $gn
            if ($existing) { throw "The group '$gn' exists already ($($existing.Dn)). Choose it as an existing group instead." }
            if (-not $WhatIf -and -not $Confirmed) { throw 'Creating a group in Active Directory needs your confirmation.' }
            $test = { param($mach) $g = Get-AVDTuneAdGroup -Ldap $w -Conn $Conn -BaseDn $nc -Name $gn; @{ Compliant = [bool]$g; State = $(if ($g) { $g.Dn } else { 'absent' }) } }.GetNewClosure()
            $apply = {
                param($mach)
                & $w.Add $Conn $dn ([ordered]@{ objectClass = 'group'; sAMAccountName = $gn; groupType = '-2147483646'; description = $desc })
            }.GetNewClosure()
            [void]$steps.Add((New-AVDTuneStep -Id 'appmasking.group.create' -Section AppMasking -Title "AD group $gn in $([string]$CreateGroup.OuDn)" -Why 'The group is the switch: members see the hidden items. Membership stays in AD.' -SourceUrl "$script:Learn/concepts-fslogix-apps-rule-editor-rule-sets" -Risk High -Test $test -Apply $apply))
            $undo.Groups = @(@{ Kind = 'Ad'; Name = $gn; Dn = $dn; NamingContext = $nc })
            $account = "$([string]$Directory.NetBiosName)\$gn"
            if (-not [string]$Directory.NetBiosName) { throw 'The NetBIOS name of the domain is not known; read the directory in the start sequence first.' }
            $grpRows = @($grpRows) + [pscustomobject]@{ Account = $account; Dn = $dn }
            $adminDn = Get-AVDTuneBuiltinAdminDn -Ldap $w -Conn $Conn -DefaultNc $nc
        }
        else {
            if (-not $WhatIf -and -not $Confirmed) { throw 'Creating a local group needs your confirmation.' }
            $test = { param($mach) $e = & $M.LocalGroupExists $gn; @{ Compliant = [bool]$e; State = $(if ($e) { 'exists' } else { 'absent' }) } }.GetNewClosure()
            $apply = { param($mach) & $M.LocalGroupCreate $gn $desc }.GetNewClosure()
            [void]$steps.Add((New-AVDTuneStep -Id 'appmasking.group.create' -Section AppMasking -Title "Local group $gn" -Why 'The local group is the switch; its members are set on the session hosts (not verified on a VM).' -SourceUrl "$script:Learn/concepts-fslogix-apps-rule-editor-rule-sets" -Risk Medium -Test $test -Apply $apply))
            $undo.Groups = @(@{ Kind = 'Local'; Name = $gn })
            $grpRows = @($grpRows) + [pscustomobject]@{ Account = "$(& $Machine.ComputerName)\$gn"; Dn = '' }
        }
    }
    elseif ($Directory -and $Ldap -and $Conn) { $adminDn = Get-AVDTuneBuiltinAdminDn -Ldap (New-AVDTuneLdapWriter -Ldap $Ldap) -Conn $Conn -DefaultNc ([string]$Directory.DefaultNamingContext) }
    if ($Visibility -eq 'HiddenExceptGroups' -and $grpRows.Count -eq 0) { throw 'Choose at least one group, or create one.' }
    foreach ($g in $grpRows) { if (-not $g.Account -or [string]$g.Account -notmatch '^[^\\\x00-\x1F\t]+\\[^\\\x00-\x1F\t]+$') { throw "The group account '$($g.Account)' is not of the form DOMAIN\Group." } }

    # --- files: keep what is there, add what is missing; the assignment is ours
    $fxrPath = Join-Path $M.RulesFolder "$Name.fxr"; $fxaPath = Join-Path $M.RulesFolder "$Name.fxa"
    $oldFxr = & $M.ReadBytes $fxrPath; $oldFxa = & $M.ReadBytes $fxaPath
    $fxr = if ($null -ne $oldFxr) { ConvertFrom-AVDTuneFxrText (ConvertFrom-AVDTuneRuleBytes $oldFxr) } else { ConvertFrom-AVDTuneFxrText "1`r`n" }
    $list = New-Object System.Collections.ArrayList; foreach ($x in @($fxr.Entries)) { [void]$list.Add($x) }
    foreach ($e in @($Entries)) {
        $dupe = @($list | Where-Object { $_.Rule -and $_.Rule.Folder -ieq [string]$e.Folder -and $_.Rule.Name -ieq [string]$e.Name }).Count -gt 0
        if (-not $dupe) { [void]$list.Add([pscustomobject]@{ Pre = @('##'); Line = (ConvertTo-AVDTuneFxrRuleLine ([string]$e.Folder) ([string]$e.Name)); Rule = $null }) }
    }
    $fxr.Entries = @($list)
    $adminName = & $M.ResolveAccountName $script:AdminsSid
    $rows = ConvertTo-AVDTuneFxaRows -Visibility $Visibility -Groups $grpRows -AdminDn $adminDn -AdminName $adminName -Time ([string]((& $Machine.Now).ToUniversalTime().ToFileTimeUtc()))
    $fxa = [pscustomobject]@{ Header = "1`t"; Rows = @($rows) }
    $fxrBytes = ConvertTo-AVDTuneRuleBytes (ConvertTo-AVDTuneFxrText $fxr); $fxaBytes = ConvertTo-AVDTuneRuleBytes (ConvertTo-AVDTuneFxaText $fxa)
    [void]$steps.Add((New-AVDTuneMaskingFileStep -Id 'appmasking.rules.fxr' -Title "Rule set ${Name}: $(@($Entries).Count) hiding rule(s)" -M $M -Path $fxrPath -Bytes $fxrBytes))
    [void]$steps.Add((New-AVDTuneMaskingFileStep -Id 'appmasking.rules.fxa' -Title "Rule set ${Name}: assignment ($Visibility)" -M $M -Path $fxaPath -Bytes $fxaBytes))
    $undo.Files = @(
        @{ Path = $fxrPath; Before = $(if ($null -ne $oldFxr) { [Convert]::ToBase64String($oldFxr) } else { $null }) }
        @{ Path = $fxaPath; Before = $(if ($null -ne $oldFxa) { [Convert]::ToBase64String($oldFxa) } else { $null }) })
    if (-not $WhatIf -and (Test-AVDTuneWriteAllowed) -and (Test-AVDTuneMaskingNeedsChange $steps $Machine)) { Write-AVDTuneUndoFile (Get-AVDTuneMaskingUndoPath $Root) ($undo | ConvertTo-Json -Depth 6) }
    Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'App Masking'; Steps = @($steps | ForEach-Object { $_.Id }) }) -Catalog @($steps) -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf
}

function Remove-AVDTuneRuleSet {
    <# Deletes both files of a rule set (the old content goes into the undo record). The group, if any, stays: it may be used elsewhere. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$M, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Name, [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    if (-not (Test-AVDTuneMaskingName $Name)) { throw "'$Name' is not a valid rule set name." }
    $paths = @((Join-Path $M.RulesFolder "$Name.fxr"), (Join-Path $M.RulesFolder "$Name.fxa"))
    $old = @($paths | ForEach-Object { $b = & $M.ReadBytes $_; @{ Path = $_; Before = $(if ($null -ne $b) { [Convert]::ToBase64String($b) } else { $null }) } })
    if (@($old | Where-Object { $_.Before }).Count -eq 0) { throw "The rule set '$Name' does not exist." }
    $steps = @(foreach ($p in $paths) {
            $pp = $p
            New-AVDTuneStep -Id "appmasking.remove.$([IO.Path]::GetExtension($pp).TrimStart('.'))" -Section AppMasking -Title "Remove $([IO.Path]::GetFileName($pp))" -Risk Medium `
                -Test ({ param($mach) @{ Compliant = ($null -eq (& $M.ReadBytes $pp)); State = '' } }.GetNewClosure()) -Apply ({ param($mach) & $M.DeleteFile $pp }.GetNewClosure())
        })
    if (-not $WhatIf -and (Test-AVDTuneWriteAllowed)) { Write-AVDTuneUndoFile (Get-AVDTuneMaskingUndoPath $Root) ([ordered]@{ At = (& $Machine.Now).ToString('o'); Name = $Name; Files = $old; Groups = @(); Shortcuts = @() } | ConvertTo-Json -Depth 6) }
    Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'App Masking remove'; Steps = @($steps | ForEach-Object { $_.Id }) }) -Catalog $steps -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf
}

function Undo-AVDTuneMaskingChange {
    <#
        Puts back what the last change found: files as they were (a file that was not there is deleted), shortcuts AVDTune made are removed, a group AVDTune created is
        deleted again only when it still carries AVDTune's description and has no members. Needs the same connection as the change for an AD group.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$M, [string]$Root = (Get-AVDTuneRoot), $Ldap, $Conn, [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    $u = Read-AVDTuneMaskingUndo $Root
    if (-not $u) { throw 'There is nothing to undo: no App Masking change was recorded.' }
    $steps = New-Object System.Collections.ArrayList
    $i = 0; $gd = $script:GroupDescription
    foreach ($f in @($u.Files)) {
        $path = [string]$f.Path; $before = Get-AVDTuneProp $f 'Before'
        $bytes = if ($before) { [Convert]::FromBase64String([string]$before) } else { $null }
        if (-not $path.StartsWith($M.RulesFolder.TrimEnd([char]92) + [char]92, [StringComparison]::OrdinalIgnoreCase) -or @($path -split '\\') -contains '..') { throw "The undo record names a path outside the rules folder ($path)." }
        $i++
        $test = { param($mach) $cur = & $M.ReadBytes $path; $ok = (Test-AVDTuneMaskBytesEqual $cur $bytes); @{ Compliant = [bool]$ok; State = '' } }.GetNewClosure()
        $apply = { param($mach) if ($null -eq $bytes) { & $M.DeleteFile $path } else { & $M.WriteBytes $path $bytes } }.GetNewClosure()
        [void]$steps.Add((New-AVDTuneStep -Id "appmasking.undo.file$i" -Section AppMasking -Title "Undo: $([IO.Path]::GetFileName($path))" -Test $test -Apply $apply))
    }
    foreach ($s in @(Get-AVDTuneProp $u 'Shortcuts')) {
        if (-not $s) { continue }
        $path = [string]$s.Path; $i++
        if (-not $path.StartsWith(((& $M.PublicDesktopFolder).TrimEnd([char]92) + [char]92), [StringComparison]::OrdinalIgnoreCase)) { throw "The undo record names a shortcut outside the Public Desktop ($path)." }
        $test = { param($mach) @{ Compliant = (-not (& $M.ShortcutExists $path)); State = '' } }.GetNewClosure()
        $apply = { param($mach) & $M.DeleteShortcut $path }.GetNewClosure()
        [void]$steps.Add((New-AVDTuneStep -Id "appmasking.undo.shortcut$i" -Section AppMasking -Title "Undo: shortcut $([IO.Path]::GetFileName($path))" -Test $test -Apply $apply))
    }
    foreach ($g in @(Get-AVDTuneProp $u 'Groups')) {
        if (-not $g) { continue }
        $gn = [string]$g.Name; $i++
        if (-not (Test-AVDTuneMaskingGroupName $gn)) { throw "The undo record names an invalid group '$gn'." }
        if ([string]$g.Kind -eq 'Ad') {
            if (-not ($Ldap -and $Conn)) { throw 'Undoing the AD group needs the connection to the domain controller (start sequence).' }
            $w = New-AVDTuneLdapWriter -Ldap $Ldap; $nc = [string]$g.NamingContext; $dn = [string]$g.Dn
            $test = { param($mach) $x = Get-AVDTuneAdGroup -Ldap $w -Conn $Conn -BaseDn $nc -Name $gn; @{ Compliant = (-not $x); State = '' } }.GetNewClosure()
            $apply = {
                param($m)
                $x = Get-AVDTuneAdGroup -Ldap $w -Conn $Conn -BaseDn $nc -Name $gn
                if (-not $x) { return }
                if (-not $x.Description.StartsWith($gd)) { throw "The group $gn does not carry AVDTune's description any more: it is not deleted." }
                if ($x.MemberCount -gt 0) { throw "The group $gn has $($x.MemberCount) member(s): it is not deleted. Remove the members in AD first." }
                if ($x.Dn -ine $dn) { throw "The group $gn is at another place now ($($x.Dn)): it is not deleted." }
                & $w.Delete $Conn $dn
            }.GetNewClosure()
        }
        else {
            $test = { param($mach) @{ Compliant = (-not (& $M.LocalGroupExists $gn)); State = '' } }.GetNewClosure()
            $apply = { param($mach) if ((& $M.LocalGroupDescription $gn) -notlike "$gd*") { throw "The local group $gn does not carry AVDTune's description: it is not deleted." }; & $M.LocalGroupDelete $gn }.GetNewClosure()
        }
        [void]$steps.Add((New-AVDTuneStep -Id "appmasking.undo.group$i" -Section AppMasking -Title "Undo: group $gn" -Risk High -Test $test -Apply $apply))
    }
    if ($steps.Count -eq 0) { throw 'The undo record is empty.' }
    $run = Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'App Masking undo'; Steps = @($steps | ForEach-Object { $_.Id }) }) -Catalog @($steps) -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf
    if (-not $WhatIf -and @($run.Results | Where-Object { $_.Status -eq 'Failed' }).Count -eq 0) { Remove-Item -LiteralPath (Get-AVDTuneMaskingUndoPath $Root) -Force -ErrorAction SilentlyContinue }
    $run
}

#endregion

#region comfort shortcuts (5c)

function Get-AVDTuneComfortShortcuts {
    <# The shortcuts AVDTune can put on the Public Desktop. Targets come from Windows' own folders (never PATH or environment variables). #>
    param([Parameter(Mandatory)]$M)
    $sys = & $M.SystemFolder
    @([pscustomobject]@{
            Id = 'logoff'; Name = 'Abmelden.lnk'; Title = 'Abmelden (sign out)'; Target = (Join-Path $sys 'shutdown.exe'); Arguments = '/l'; Icon = (Join-Path $sys 'shell32.dll') + ',44'
            Description = "${script:ShortcutMarker}: signs the user out without a confirmation dialog"; Verified = $false
            Note = 'shutdown.exe /l signs the current user out. The icon index in shell32.dll is not documented by Microsoft (not verified on a VM).'
        })
}

function Add-AVDTuneComfortShortcut {
    <# Creates a comfort shortcut on the Public Desktop (read only for users; the file has the protected ACL). An existing file of that name that is not ours is never replaced. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$M, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][ValidateSet('logoff')][string]$Id, [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    $s = @(Get-AVDTuneComfortShortcuts -M $M | Where-Object Id -eq $Id)[0]
    $path = Join-Path (& $M.PublicDesktopFolder) $s.Name
    $cur = & $M.ReadShortcut $path
    if ($cur -and -not ([string]$cur.Description).StartsWith($script:ShortcutMarker)) { throw "$($s.Name) exists on the Public Desktop and was not made by AVDTune: it is not replaced." }
    $test = { param($mach) $c = & $M.ReadShortcut $path; @{ Compliant = [bool]($c -and $c.Target -ieq $s.Target -and $c.Arguments -ceq $s.Arguments -and $c.Icon -ieq $s.Icon); State = $(if ($c) { $c.Target } else { 'absent' }) } }.GetNewClosure()
    $apply = { param($mach) & $M.CreateShortcut $path $s.Target $s.Arguments $s.Icon $s.Description }.GetNewClosure()
    $step = New-AVDTuneStep -Id "appmasking.comfort.$Id" -Section AppMasking -Title "Public Desktop shortcut $($s.Title)" -Why 'A comfort shortcut for all users.' -Risk Low -Test $test -Apply $apply
    if (-not $WhatIf -and (Test-AVDTuneWriteAllowed) -and (Test-AVDTuneMaskingNeedsChange @($step) $Machine)) { Write-AVDTuneUndoFile (Get-AVDTuneMaskingUndoPath $Root) ([ordered]@{ At = (& $Machine.Now).ToString('o'); Name = $s.Name; Files = @(); Groups = @(); Shortcuts = @(@{ Path = $path }) } | ConvertTo-Json -Depth 6) }
    Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'App Masking comfort shortcut'; Steps = @($step.Id) }) -Catalog @($step) -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf
}

#endregion

#region real adapter

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
        foreach ($c in @((Split-Path $folder -Parent), $folder) + $(if (Test-Path -LiteralPath $Path) { @($Path) } else { @() })) {
            $problems = @(Get-AVDTuneAclProblems (Read-AVDTuneAclReport $c))
            if ($problems.Count -gt 0) { throw "$c is not safe ($($problems -join '; ')). Nothing was written. Check it as administrator." }
        }
        $temp = "$Path.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
        try {
            $stream = New-Object IO.FileStream($temp, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]'Write, ReadPermissions', [IO.FileShare]::None, 4096, [IO.FileOptions]::None, (New-AVDTuneFileSecurity))
            try { $stream.Write($Bytes, 0, $Bytes.Length) } finally { $stream.Dispose() }
            if (Test-Path -LiteralPath $Path) { [IO.File]::Delete($Path) }
            [IO.File]::Move($temp, $Path)
        }
        finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
        $after = @(Get-AVDTuneAclProblems (Read-AVDTuneAclReport $Path))
        if ($after.Count -gt 0) { try { [IO.File]::Delete($Path) } catch { }; throw "$Path got an unsafe ACL ($($after -join '; ')) and was removed again." }
    }
    $a.DeleteFile = {
        param($Path)
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $r = Read-AVDTuneAclReport $Path
        if ($r.Link) { throw "$Path is a link: not deleted." }
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
        $shell = New-Object -ComObject WScript.Shell
        try { $l = $shell.CreateShortcut($Path); $o = [pscustomobject]@{ Target = [string]$l.TargetPath; Arguments = [string]$l.Arguments; Icon = [string]$l.IconLocation; Description = [string]$l.Description }; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($l); $o }
        finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
    $a.ShortcutExists = { param($Path) Test-Path -LiteralPath $Path -PathType Leaf }
    $a.CreateShortcut = {
        # Created in the admin-only state folder first, then moved: the Public Desktop file never exists with the folder's default ACL; the protected ACL is set before the move
        param($Path, $Target, $Arguments, $Icon, $Description)
        $desk = Split-Path $Path -Parent
        $rep = Read-AVDTuneAclReport $desk
        if (-not $rep.Exists -or $rep.Link) { throw "$desk is missing or a link: no shortcut was written." }
        if (Test-Path -LiteralPath $Path) { $old = Read-AVDTuneAclReport $Path; if ($old.Link) { throw "$Path is a link." } }
        $temp = Join-Path $desk ([guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp.lnk')
        $shell = New-Object -ComObject WScript.Shell
        try {
            $l = $shell.CreateShortcut($temp); $l.TargetPath = $Target; $l.Arguments = $Arguments; $l.IconLocation = $Icon; $l.Description = $Description; $l.Save(); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($l)
            $fi = New-Object IO.FileInfo $temp
            $acl = New-AVDTuneFileSecurity
            $fi.SetAccessControl($acl)
            if (Test-Path -LiteralPath $Path) { [IO.File]::Delete($Path) }
            [IO.File]::Move($temp, $Path)
        }
        finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell); if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
    }
    $a.DeleteShortcut = { param($Path) if (Test-Path -LiteralPath $Path) { $r = Read-AVDTuneAclReport $Path; if ($r.Link) { throw "$Path is a link." }; [IO.File]::Delete($Path) } }
    $a.LocalGroupExists = { param($Name) try { $g = [ADSI]"WinNT://./$Name,group"; [bool]$g.Path } catch { $false } }
    $a.LocalGroupCreate = { param($Name, $Description) $c = [ADSI]'WinNT://.,computer'; $g = $c.Create('group', $Name); $g.SetInfo(); $g.Description = $Description; $g.SetInfo() }
    $a.LocalGroupDescription = { param($Name) try { [string]([ADSI]"WinNT://./$Name,group").Description } catch { '' } }
    $a.LocalGroupDelete = { param($Name) ([ADSI]'WinNT://.,computer').Delete('group', $Name) }
    [pscustomobject]$a
}

#endregion

Export-ModuleMember -Function Test-AVDTuneMaskBytesEqual, Test-AVDTuneMaskingNeedsChange, Get-AVDTuneMaskAttr, Test-AVDTuneMaskingName, Test-AVDTuneMaskingGroupName, Test-AVDTuneMaskingPrefix, Get-AVDTuneAppGroupName, Test-AVDTuneMaskingRulePath, Test-AVDTuneOuDn,
    ConvertTo-AVDTuneRuleBytes, ConvertFrom-AVDTuneRuleBytes, ConvertFrom-AVDTuneFxrText, ConvertTo-AVDTuneFxrText, ConvertTo-AVDTuneFxrRuleLine, New-AVDTuneFxaRow,
    ConvertFrom-AVDTuneFxaText, ConvertTo-AVDTuneFxaText, ConvertTo-AVDTuneFxaRows, Get-AVDTuneRuleVisibility, Get-AVDTuneMaskingSettings, Set-AVDTuneMaskingSettings,
    Get-AVDTuneMaskingCapabilities, New-AVDTuneLdapWriter, Get-AVDTuneAdGroup, Get-AVDTuneBuiltinAdminDn, Get-AVDTuneRuleSets, Get-AVDTunePublicDesktopList,
    Get-AVDTuneMaskingOverview, Get-AVDTuneMaskingUndoPath, Save-AVDTuneRuleSet, Remove-AVDTuneRuleSet, Undo-AVDTuneMaskingChange, Get-AVDTuneComfortShortcuts,
    Add-AVDTuneComfortShortcut, New-AVDTuneMaskingAdapter
