<#
    AVDTune web apps (PWA) (docs\plans\avdtune.md, section 3a; issue #88). Pure helpers for the customization kind 'WebApp' (Modules\AVDTune.Custom.psm1):

      * Start URL and manifest id: https only, no user name or password, no space, quote or control character, at most 2048 characters; the manifest id has the
        origin of the start URL.
      * Edge policy HKLM\SOFTWARE\Policies\Microsoft\Edge, value WebAppInstallForceList (REG_SZ, a JSON list of objects as Microsoft documents it for Edge).
        AVDTune owns only the entries whose url is the start URL of one of its web apps; every other entry is kept as it is (order too).
      * The shortcut starts the installed app (msedge_proxy.exe --profile-directory=Default --app-id=<id>) only when the app id is known: entered by hand (from
        edge://apps of the master) or computed once the spike has verified the scheme. Otherwise msedge.exe --app=<url> with an own AppUserModelID on the shortcut:
        that window is not the installed app, so the taskbar may still group it under Edge with the Edge icon (the icon problem of plan 3a stays in that case).
      * Startup boost and background mode of Edge are NOT switched on (one Edge process per session on a multi-session host).

    The spike on a Windows 11 multi-session VM (plan 3a) decides what is still marked "not verified" in $script:Spike; its results are entered there and nowhere else.
    Later the same fields become a PackTune package of the kind 'webapp' (the store format is changed in PackTune first, then synced).
#>

Set-StrictMode -Version 2.0

# ---- the results of the spike (docs\plans\avdtune.md 3a). Everything $false/'' = not verified; the code then takes the safe way.
$script:Spike = [ordered]@{
    AppIdSchemeVerified = $false   # Edge's app id = the Chromium scheme (SHA256 of the manifest id or start URL, first 32 hex digits mapped 0-f -> a-p)
    CustomName          = $false   # Edge honours custom_name in WebAppInstallForceList on Windows
    CustomIcon          = $false   # Edge honours custom_icon (url + hash) with a file:/// url of the icon copy in C:\ProgramData\AVDTune-Public\Icons
    ProxyAumid          = ''       # the AppUserModelID Edge gives the window of an installed app, with {0} for the app id (empty: the shortcut gets none)
}
$script:PolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$script:PolicyValue = 'WebAppInstallForceList'
$script:WindowModes = @('Window', 'Tab')

function Get-AVDTuneWebAppSpike { [pscustomobject]$script:Spike }
function Get-AVDTuneWebAppPolicyLocation { [pscustomobject]@{ Key = $script:PolicyKey; Value = $script:PolicyValue } }
function Get-AVDTuneWebAppWindowModes { @($script:WindowModes) }

function Test-AVDTuneWebAppUrl {
    # '' when the URL may be used, else the reason. Only https, absolute, a host, no user info, nothing a command line or JSON would read differently.
    param([string]$Url, [string]$Label = 'Start URL')
    if (-not $Url) { return "$Label`: required." }
    if ($Url.Length -gt 2048) { return "$Label`: at most 2048 characters." }
    foreach ($ch in $Url.ToCharArray()) { if ([int]$ch -le 32 -or [int]$ch -ge 127 -or $ch -in '"', '^', '`', '\', '<', '>', '|', '{', '}') { return "$Label`: no space, quote, backslash, control or non-ASCII character (encode it)." } }
    $u = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) { return "$Label`: not a valid URL." }
    if ($u.Scheme -cne 'https' -or -not $Url.StartsWith('https://', [StringComparison]::Ordinal)) { return "$Label`: https:// only." }
    if ($u.UserInfo -or $Url.Substring(8).Split('/')[0].Contains('@')) { return "$Label`: no user name or password in the URL." }
    if (-not $u.Host -or $u.HostNameType -notin 'Dns', 'IPv4', 'IPv6') { return "$Label`: a host is required." }
    ''
}

function Get-AVDTuneWebAppOrigin([string]$Url) { $u = [Uri]$Url; "https://$($u.Authority)".ToLowerInvariant() }

function Get-AVDTuneWebAppIdGuess {
    <# The app id Chromium computes for a web app: SHA256 of the manifest id (the start URL when there is none), first 16 bytes as 32 hex digits mapped 0-f -> a-p.
       NOT verified for Edge (spike); used for the shortcut only when $script:Spike.AppIdSchemeVerified is set. #>
    param([Parameter(Mandatory)][string]$StartUrl, [string]$ManifestId)
    $src = if ($ManifestId) { $ManifestId } else { $StartUrl }
    $h = [Security.Cryptography.SHA256]::Create()
    try { $b = $h.ComputeHash([Text.Encoding]::UTF8.GetBytes($src)) } finally { $h.Dispose() }
    -join @(for ($i = 0; $i -lt 16; $i++) { [char](97 + ($b[$i] -shr 4)); [char](97 + ($b[$i] -band 15)) })
}

function Get-AVDTuneWebAppId {
    # The app id the shortcut uses: the one entered, else the computed one when the scheme is verified, else ''
    param([Parameter(Mandatory)]$Item)
    if ($Item.AppId) { return [string]$Item.AppId }
    if ($script:Spike.AppIdSchemeVerified) { return (Get-AVDTuneWebAppIdGuess -StartUrl $Item.StartUrl -ManifestId $Item.ManifestId) }
    ''
}

function Get-AVDTuneWebAppLaunch {
    # Target, arguments and AppUserModelID of the shortcut of a web app; -EdgeFolder is the Edge application folder (adapter, from the system folders)
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][string]$EdgeFolder)
    $id = Get-AVDTuneWebAppId -Item $Item
    if ($id) {
        $aumid = if ($script:Spike.ProxyAumid) { $script:Spike.ProxyAumid -f $id } else { '' }
        return [pscustomobject]@{ Target = (Join-Path $EdgeFolder 'msedge_proxy.exe'); Arguments = "--profile-directory=Default --app-id=$id"; AppUserModelId = $aumid; Installed = $true }
    }
    $arg = if ($Item.WindowMode -eq 'Tab') { $Item.StartUrl } else { "--app=$($Item.StartUrl)" }
    [pscustomobject]@{ Target = (Join-Path $EdgeFolder 'msedge.exe'); Arguments = $arg; AppUserModelId = $(if ($Item.WindowMode -eq 'Tab') { '' } else { "AVDTune.WebApp.$($Item.Id)" }); Installed = $false }
}

function New-AVDTuneWebAppPolicyEntry {
    # The entry of one web app in WebAppInstallForceList. Edge makes no shortcut of its own (AVDTune makes them where the item says).
    param([Parameter(Mandatory)]$Item, [string]$IconPath)
    $e = [ordered]@{ url = $Item.StartUrl; default_launch_container = $(if ($Item.WindowMode -eq 'Tab') { 'tab' } else { 'window' }); create_desktop_shortcut = $false; fallback_app_name = $Item.Name }
    if ($script:Spike.CustomName) { $e.custom_name = $Item.Name }
    if ($script:Spike.CustomIcon -and $IconPath -and $Item.IconSha256) { $e.custom_icon = [ordered]@{ url = ('file:///' + ($IconPath -replace '\\', '/')); hash = $Item.IconSha256 } }
    [pscustomobject]$e
}

function ConvertFrom-AVDTuneWebAppPolicy {
    <#
        The value as its entries, each as the exact text it has in the value (Raw) and its url (review #88: foreign entries are never serialized anew, so nothing
        of them is lost). $null or '' = no list. Anything that is not a JSON list of objects with a url text throws (it is not changed then).
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if (-not $Text -or -not $Text.Trim()) { return , @() }
    if ($Text.Length -gt 262144) { throw 'WebAppInstallForceList is larger than 256 KB: not changed.' }
    $bad = 'WebAppInstallForceList is not a JSON list of entries: not changed.'
    $n = $Text.Length; $i = 0
    $skip = { while ($i -lt $n -and [char]::IsWhiteSpace($Text[$i])) { $i++ } }
    . $skip
    if ($i -ge $n -or $Text[$i] -ne '[') { throw $bad }
    $i++; . $skip
    $out = New-Object System.Collections.ArrayList
    if ($i -lt $n -and $Text[$i] -eq ']') { $i++ }
    else {
        while ($true) {
            . $skip
            if ($i -ge $n -or $Text[$i] -ne '{') { throw $bad }
            # one object: brackets counted outside strings, escapes inside strings skipped
            $start = $i; $depth = 0; $inStr = $false
            while ($i -lt $n) {
                $ch = $Text[$i]
                if ($inStr) { if ($ch -eq '\') { $i++ } elseif ($ch -eq '"') { $inStr = $false } }
                elseif ($ch -eq '"') { $inStr = $true }
                elseif ($ch -eq '{' -or $ch -eq '[') { $depth++ }
                elseif ($ch -eq '}' -or $ch -eq ']') { $depth--; if ($depth -eq 0) { break } }
                $i++
            }
            if ($i -ge $n) { throw $bad }
            $raw = $Text.Substring($start, $i - $start + 1); $i++
            try { $o = ConvertFrom-Json -InputObject $raw } catch { throw $bad }
            if ($o -isnot [pscustomobject] -or -not ($o.PSObject.Properties['url'] -and $o.url -is [string])) { throw 'WebAppInstallForceList has an entry without a url: not changed.' }
            [void]$out.Add([pscustomobject]@{ Raw = $raw; Url = [string]$o.url })
            . $skip
            if ($i -lt $n -and $Text[$i] -eq ',') { $i++; continue }
            if ($i -lt $n -and $Text[$i] -eq ']') { $i++; break }
            throw $bad
        }
    }
    . $skip
    if ($i -lt $n) { throw $bad }
    , @($out)
}

function ConvertTo-AVDTuneWebAppPolicyText([object[]]$Entries) { if (@($Entries).Count -eq 0) { return '' }; '[' + (@($Entries | ForEach-Object { $_.Raw }) -join ',') + ']' }

function Get-AVDTuneWebAppEntryText($Entry) { ConvertTo-Json -InputObject $Entry -Depth 5 -Compress }   # AVDTune's own entry (two levels at most)

function Test-AVDTuneWebAppSameUrl([string]$A, [string]$B) { $A.TrimEnd('/') -ieq $B.TrimEnd('/') }

function Find-AVDTuneWebAppPolicyEntry {
    # The entries of a URL in a list (all of them)
    param([object[]]$Entries, [Parameter(Mandatory)][string]$Url)
    , @(@($Entries) | Where-Object { $_ -and (Test-AVDTuneWebAppSameUrl $_.Url $Url) })
}

function Merge-AVDTuneWebAppPolicy {
    <#
        The new value with the own entry added at the end; every other entry stays as its exact text. An entry of the same URL that is not exactly AVDTune's entry
        (someone else's, or several) stops it: nothing is replaced or deleted (review #88). The own entry already in place: the value is returned unchanged.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Current, [Parameter(Mandatory)]$Entry)
    $list = ConvertFrom-AVDTuneWebAppPolicy $Current
    $own = Get-AVDTuneWebAppEntryText $Entry
    $same = Find-AVDTuneWebAppPolicyEntry -Entries $list -Url $Entry.url
    if ($same.Count -gt 1) { throw "WebAppInstallForceList has $($same.Count) entries for $($Entry.url): not changed (remove the extra ones by hand)." }
    if ($same.Count -eq 1) {
        if ($same[0].Raw -ceq $own) { return [string]$Current }
        throw "WebAppInstallForceList has an entry for $($Entry.url) that AVDTune did not write: not replaced."
    }
    ConvertTo-AVDTuneWebAppPolicyText (@($list) + [pscustomobject]@{ Raw = $own; Url = $Entry.url })
}

function Test-AVDTuneWebAppPolicyHas {
    # In place: exactly one entry of the URL, and it is AVDTune's entry as it would write it now
    param([AllowNull()][AllowEmptyString()][string]$Current, [Parameter(Mandatory)]$Entry)
    $same = Find-AVDTuneWebAppPolicyEntry -Entries (ConvertFrom-AVDTuneWebAppPolicy $Current) -Url $Entry.url
    [bool]($same.Count -eq 1 -and $same[0].Raw -ceq (Get-AVDTuneWebAppEntryText $Entry))
}

function Get-AVDTuneWebAppPolicyUndo {
    <#
        What undo writes: only AVDTune's own entry (exact text -Own) is taken out, foreign entries of any URL stay as they are. When the result is the list from before
        (-OldText, -OldExisted), the old value comes back exactly as it was (same text, or no value). Returns @{ Remove = bool; Text = string }.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Current, [Parameter(Mandatory)][string]$Own, [bool]$OldExisted, [AllowNull()][AllowEmptyString()][string]$OldText)
    $list = ConvertFrom-AVDTuneWebAppPolicy $Current
    $out = @($list | Where-Object { $_.Raw -cne $Own })
    $text = ConvertTo-AVDTuneWebAppPolicyText $out
    $oldList = $null; try { $oldList = ConvertTo-AVDTuneWebAppPolicyText (ConvertFrom-AVDTuneWebAppPolicy $OldText) } catch { }
    if ($null -ne $oldList -and $text -ceq $oldList) { return [pscustomobject]@{ Remove = (-not $OldExisted); Text = [string]$OldText } }
    [pscustomobject]@{ Remove = ($out.Count -eq 0); Text = $text }
}

function Initialize-AVDTuneLinkPropertyType {
    # IPropertyStore of a .lnk (PKEY_AppUserModel_ID). Real adapter only; NOT exercised by the checks beyond compiling (to be tried on the VM).
    if ('AVDTune.Native.LinkAumid' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
namespace AVDTune.Native {
    [StructLayout(LayoutKind.Sequential, Pack = 4)] public struct PropertyKey { public Guid fmtid; public uint pid; }
    [StructLayout(LayoutKind.Explicit, Size = 24)] public struct PropVariant { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        [PreserveSig] int GetCount(out uint c);
        [PreserveSig] int GetAt(uint i, out PropertyKey k);
        [PreserveSig] int GetValue(ref PropertyKey k, out PropVariant v);
        [PreserveSig] int SetValue(ref PropertyKey k, ref PropVariant v);
        [PreserveSig] int Commit();
    }
    public static class LinkAumid {
        [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant v);
        static PropertyKey Key() { PropertyKey k = new PropertyKey(); k.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); k.pid = 5; return k; }
        static object Open(string path, int mode) { object l = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046"))); ((IPersistFile)l).Load(path, mode); return l; }
        public static string Get(string path) {
            object l = Open(path, 0);
            try { PropertyKey k = Key(); PropVariant v; Marshal.ThrowExceptionForHR(((IPropertyStore)l).GetValue(ref k, out v)); try { return v.vt == 31 ? Marshal.PtrToStringUni(v.p) : ""; } finally { PropVariantClear(ref v); } }
            finally { Marshal.ReleaseComObject(l); }
        }
        public static void Set(string path, string id) {
            object l = Open(path, 2);
            try {
                PropertyKey k = Key(); PropVariant v = new PropVariant(); v.vt = 31; v.p = Marshal.StringToCoTaskMemUni(id);
                try { Marshal.ThrowExceptionForHR(((IPropertyStore)l).SetValue(ref k, ref v)); Marshal.ThrowExceptionForHR(((IPropertyStore)l).Commit()); } finally { PropVariantClear(ref v); }
                ((IPersistFile)l).Save(path, true);
            }
            finally { Marshal.ReleaseComObject(l); }
        }
    }
}
'@
}

function Get-AVDTuneLinkAumid([string]$Path) { Initialize-AVDTuneLinkPropertyType; [AVDTune.Native.LinkAumid]::Get($Path) }
function Set-AVDTuneLinkAumid([string]$Path, [string]$Id) { Initialize-AVDTuneLinkPropertyType; [AVDTune.Native.LinkAumid]::Set($Path, $Id) }

Export-ModuleMember -Function Get-AVDTuneWebAppSpike, Get-AVDTuneWebAppPolicyLocation, Get-AVDTuneWebAppWindowModes, Test-AVDTuneWebAppUrl, Get-AVDTuneWebAppOrigin, Get-AVDTuneWebAppIdGuess,
    Get-AVDTuneWebAppId, Get-AVDTuneWebAppLaunch, New-AVDTuneWebAppPolicyEntry, ConvertFrom-AVDTuneWebAppPolicy, ConvertTo-AVDTuneWebAppPolicyText, Test-AVDTuneWebAppSameUrl,
    Find-AVDTuneWebAppPolicyEntry, Merge-AVDTuneWebAppPolicy, Test-AVDTuneWebAppPolicyHas, Get-AVDTuneWebAppPolicyUndo, Get-AVDTuneWebAppEntryText, Initialize-AVDTuneLinkPropertyType, Get-AVDTuneLinkAumid, Set-AVDTuneLinkAumid
