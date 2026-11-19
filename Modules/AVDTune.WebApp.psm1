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

#region icons (issue #88, follow-up): a multi-size .ico from a .png; every image is untrusted input

$script:IconSizes = @(16, 24, 32, 48, 64, 128, 256)
$script:ImageMaxBytes = 5242880    # 5 MB
$script:ImageMaxSide = 4096

function Get-AVDTuneWebAppImageLimits { [pscustomobject]@{ MaxBytes = $script:ImageMaxBytes; MaxSide = $script:ImageMaxSide; Sizes = @($script:IconSizes); ManifestMaxBytes = 262144; HtmlMaxBytes = 524288; ImportMaxBytes = 16777216; ImportMaxEntries = 200 } }

function Get-AVDTuneWebAppHash([byte[]]$Bytes) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($h.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() } finally { $h.Dispose() }
}

function Get-AVDTuneWebAppImageInfo {
    <#
        Reads only the header (nothing is decoded): Format ('png' or 'ico'), Width and Height (of the largest entry of an .ico). Throws for everything else: larger than
        5 MB, no PNG signature / IHDR or ICONDIR, a side of 0 or more than 4096 pixels, an .ico entry that points outside the file. The size is checked here BEFORE
        the decoder sees the image (a small file can claim a huge picture).
    #>
    param([AllowNull()][byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -lt 6) { throw 'The image is empty or too short: not used.' }
    if ($Bytes.Length -gt $script:ImageMaxBytes) { throw "The image is larger than 5 MB ($($Bytes.Length) bytes): not used." }
    $png = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
    $isPng = $Bytes.Length -ge 8; for ($k = 0; $isPng -and $k -lt 8; $k++) { if ($Bytes[$k] -ne $png[$k]) { $isPng = $false } }
    if ($isPng) {
        if ($Bytes.Length -lt 33 -or $Bytes[12] -ne 0x49 -or $Bytes[13] -ne 0x48 -or $Bytes[14] -ne 0x44 -or $Bytes[15] -ne 0x52 -or $Bytes[8] -ne 0 -or $Bytes[9] -ne 0 -or $Bytes[10] -ne 0 -or $Bytes[11] -ne 13) { throw 'The image has a PNG signature but no IHDR header: not used.' }
        $w = ([int64]$Bytes[16] -shl 24) -bor ([int64]$Bytes[17] -shl 16) -bor ([int64]$Bytes[18] -shl 8) -bor [int64]$Bytes[19]
        $h = ([int64]$Bytes[20] -shl 24) -bor ([int64]$Bytes[21] -shl 16) -bor ([int64]$Bytes[22] -shl 8) -bor [int64]$Bytes[23]
        if ($w -lt 1 -or $h -lt 1 -or $w -gt $script:ImageMaxSide -or $h -gt $script:ImageMaxSide) { throw "The image is $w x $h pixels (at most $($script:ImageMaxSide) x $($script:ImageMaxSide)): not used." }
        return [pscustomobject]@{ Format = 'png'; Width = [int]$w; Height = [int]$h }
    }
    if ($Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 1 -and $Bytes[3] -eq 0) {
        $count = [int]$Bytes[4] -bor ([int]$Bytes[5] -shl 8)
        if ($count -lt 1 -or $count -gt 64 -or $Bytes.Length -lt 6 + 16 * $count) { throw 'The .ico has no entries, more than 64 or a cut directory: not used.' }
        $max = 0
        for ($e = 0; $e -lt $count; $e++) {
            $o = 6 + 16 * $e
            $w = if ($Bytes[$o] -eq 0) { 256 } else { [int]$Bytes[$o] }; $h = if ($Bytes[$o + 1] -eq 0) { 256 } else { [int]$Bytes[$o + 1] }
            $size = [BitConverter]::ToUInt32($Bytes, $o + 8); $at = [BitConverter]::ToUInt32($Bytes, $o + 12)
            if ($size -lt 1 -or $at -lt (6 + 16 * $count) -or ([int64]$at + [int64]$size) -gt $Bytes.Length) { throw 'The .ico has an entry that points outside the file: not used.' }
            if ($w -gt $max) { $max = $w }; if ($h -gt $max) { $max = $h }
        }
        return [pscustomobject]@{ Format = 'ico'; Width = $max; Height = $max }
    }
    throw 'The image is neither a PNG nor an .ico (checked by its first bytes): not used.'
}

function New-AVDTuneWebAppSquare {
    # Private. A new 32 bit bitmap Size x Size with the image drawn into it (aspect kept, centred, transparent around). The caller disposes it.
    param([Parameter(Mandatory)]$Image, [Parameter(Mandatory)][int]$Size)
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $done = $false; $g = $null; $attr = $null
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $g.Clear([System.Drawing.Color]::Transparent)
        $scale = [Math]::Min($Size / [double]$Image.Width, $Size / [double]$Image.Height)
        $w = [Math]::Max(1, [int][Math]::Round($Image.Width * $scale)); $h = [Math]::Max(1, [int][Math]::Round($Image.Height * $scale))
        $attr = New-Object System.Drawing.Imaging.ImageAttributes
        $attr.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)   # no dark edge from pixels outside the image
        $rect = New-Object System.Drawing.Rectangle([int](($Size - $w) / 2), [int](($Size - $h) / 2), $w, $h)
        $g.DrawImage($Image, $rect, 0, 0, $Image.Width, $Image.Height, [System.Drawing.GraphicsUnit]::Pixel, $attr)
        $done = $true
        , $bmp
    }
    finally { if ($attr) { $attr.Dispose() }; if ($g) { $g.Dispose() }; if (-not $done) { $bmp.Dispose() } }
}

function ConvertTo-AVDTuneWebAppIco {
    <#
        A multi-size .ico (16, 24, 32, 48, 64, 128 and 256 pixels; 32 bit with alpha, the 256 entry PNG compressed) from the bytes of a PNG. The PNG is untrusted:
        header and size limits first (Get-AVDTuneWebAppImageInfo), decoding inside try/catch, every GDI object is disposed. Returns the bytes of the .ico.
    #>
    param([AllowNull()][byte[]]$Bytes)
    $info = Get-AVDTuneWebAppImageInfo $Bytes
    if ($info.Format -ne 'png') { throw 'Only a PNG is made into an .ico.' }
    Add-Type -AssemblyName System.Drawing
    $ms = New-Object IO.MemoryStream(, $Bytes); $src = $null
    $parts = New-Object System.Collections.ArrayList
    try {
        try { $src = New-Object System.Drawing.Bitmap($ms) } catch { throw 'The PNG cannot be decoded (damaged or not a picture): not used.' }
        if ($src.Width -lt 1 -or $src.Height -lt 1 -or $src.Width -gt $script:ImageMaxSide -or $src.Height -gt $script:ImageMaxSide) { throw "The image is $($src.Width) x $($src.Height) pixels (at most $($script:ImageMaxSide) x $($script:ImageMaxSide)): not used." }
        foreach ($s in $script:IconSizes) {
            $bmp = $null
            try {
                try { $bmp = New-AVDTuneWebAppSquare -Image $src -Size $s } catch { throw 'The PNG cannot be decoded (damaged or not a picture): not used.' }
                if ($s -ge 256) {
                    $o = New-Object IO.MemoryStream
                    try { $bmp.Save($o, [System.Drawing.Imaging.ImageFormat]::Png); [void]$parts.Add(@{ Size = $s; Data = $o.ToArray() }) } finally { $o.Dispose() }
                }
                else {
                    # a device independent bitmap: BITMAPINFOHEADER (height doubled for the mask), the pixels bottom-up as BGRA, then an empty AND mask (the alpha channel decides)
                    $lock = $bmp.LockBits((New-Object System.Drawing.Rectangle(0, 0, $s, $s)), [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                    try {
                        $stride = [Math]::Abs($lock.Stride); $px = New-Object byte[] ($stride * $s)
                        [Runtime.InteropServices.Marshal]::Copy($lock.Scan0, $px, 0, $px.Length)
                    }
                    finally { $bmp.UnlockBits($lock) }
                    $maskRow = [int]([Math]::Floor(($s + 31) / 32)) * 4
                    $o = New-Object IO.MemoryStream; $bw = New-Object IO.BinaryWriter($o)
                    try {
                        $bw.Write([int]40); $bw.Write([int]$s); $bw.Write([int]($s * 2)); $bw.Write([int16]1); $bw.Write([int16]32); $bw.Write([int]0); $bw.Write([int]($s * $s * 4 + $maskRow * $s))
                        $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
                        for ($y = $s - 1; $y -ge 0; $y--) { $bw.Write($px, $y * $stride, $s * 4) }
                        $bw.Write((New-Object byte[] ($maskRow * $s)))
                        $bw.Flush(); [void]$parts.Add(@{ Size = $s; Data = $o.ToArray() })
                    }
                    finally { $bw.Dispose(); $o.Dispose() }
                }
            }
            finally { if ($bmp) { $bmp.Dispose() } }
        }
    }
    finally { if ($src) { $src.Dispose() }; $ms.Dispose() }
    $out = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter($out)
    try {
        $w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$parts.Count)
        $at = 6 + 16 * $parts.Count
        foreach ($p in $parts) {
            $side = [byte]$(if ($p.Size -ge 256) { 0 } else { $p.Size })
            $w.Write($side); $w.Write($side); $w.Write([byte]0); $w.Write([byte]0); $w.Write([int16]1); $w.Write([int16]32); $w.Write([int]$p.Data.Length); $w.Write([int]$at)
            $at += $p.Data.Length
        }
        foreach ($p in $parts) { $w.Write([byte[]]$p.Data) }
        $w.Flush()
        , $out.ToArray()
    }
    finally { $w.Dispose(); $out.Dispose() }
}

function Get-AVDTuneWebAppIconPreview {
    <#
        The picture in taskbar size (24 pixels by default) as the bytes of a PNG that AVDTune encoded itself: the window only ever decodes this, never the file of
        the library or the site. From a PNG or an .ico (the entry Windows would take for that size). Same limits and try/catch as the conversion.
    #>
    param([AllowNull()][byte[]]$Bytes, [ValidateRange(16, 256)][int]$Size = 24)
    $info = Get-AVDTuneWebAppImageInfo $Bytes
    Add-Type -AssemblyName System.Drawing
    $ms = New-Object IO.MemoryStream(, $Bytes); $src = $null; $icon = $null; $bmp = $null
    try {
        try {
            if ($info.Format -eq 'ico') { $icon = New-Object System.Drawing.Icon($ms, $Size, $Size); $src = $icon.ToBitmap() } else { $src = New-Object System.Drawing.Bitmap($ms) }
            if ($src.Width -lt 1 -or $src.Height -lt 1 -or $src.Width -gt $script:ImageMaxSide -or $src.Height -gt $script:ImageMaxSide) { throw 'size' }
            $bmp = New-AVDTuneWebAppSquare -Image $src -Size $Size
        }
        catch { throw 'The image cannot be decoded (damaged or not a picture): not used.' }
        $o = New-Object IO.MemoryStream
        try { $bmp.Save($o, [System.Drawing.Imaging.ImageFormat]::Png); , $o.ToArray() } finally { $o.Dispose() }
    }
    finally { if ($bmp) { $bmp.Dispose() }; if ($src) { $src.Dispose() }; if ($icon) { $icon.Dispose() }; $ms.Dispose() }
}

#endregion

#region the icon of the site (web manifest): only on request, same origin, no private address, nothing executed

function Test-AVDTuneWebAppPublicAddress {
    <#
        '' when the address may be asked, else the reason. Refused: loopback, the private ranges, link-local (169.254.0.0/16 with the metadata service of Azure),
        carrier NAT, "this network", multicast, reserved and broadcast; IPv6 loopback, unspecified, unique local, link-local, multicast, and IPv4 inside IPv6
        (mapped, NAT64, 6to4) with a refused IPv4 address. Anything that is not an IP address is refused.
    #>
    param([string]$Address)
    $ip = $null
    if (-not $Address -or -not [Net.IPAddress]::TryParse($Address, [ref]$ip)) { return "'$Address' is not an IP address." }
    $b = $ip.GetAddressBytes()
    if ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
        $zero10 = $true; for ($k = 0; $k -lt 10; $k++) { if ($b[$k] -ne 0) { $zero10 = $false } }
        $v4 = $null
        if ($zero10 -and $b[10] -eq 0xFF -and $b[11] -eq 0xFF) { $v4 = $b[12..15] }                                                    # ::ffff:a.b.c.d
        elseif ($zero10 -and $b[10] -eq 0 -and $b[11] -eq 0) { if (($b[12..15] -join '.') -in '0.0.0.0', '0.0.0.1') { return "$Address is a local address." }; $v4 = $b[12..15] }   # ::, ::1, ::a.b.c.d
        elseif ($b[0] -eq 0 -and $b[1] -eq 0x64 -and $b[2] -eq 0xFF -and $b[3] -eq 0x9B) { $v4 = $b[12..15] }                          # 64:ff9b::/96 (NAT64)
        elseif ($b[0] -eq 0x20 -and $b[1] -eq 0x02) { $v4 = $b[2..5] }                                                                 # 2002::/16 (6to4)
        if ($null -ne $v4) { $inner = Test-AVDTuneWebAppPublicAddress (@($v4) -join '.'); if ($inner) { return "$Address carries an address that is refused ($inner)" }; return '' }
        if (($b[0] -band 0xFE) -eq 0xFC) { return "$Address is a private address (unique local)." }
        if ($b[0] -eq 0xFE -and ($b[1] -band 0xC0) -eq 0x80) { return "$Address is a link-local address." }
        if ($b[0] -eq 0xFE -and ($b[1] -band 0xC0) -eq 0xC0) { return "$Address is a site-local address." }
        if ($b[0] -eq 0xFF) { return "$Address is a multicast address." }
        return ''
    }
    if ($b[0] -eq 127) { return "$Address is a loopback address." }
    if ($b[0] -eq 10 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168)) { return "$Address is a private address." }
    if ($b[0] -eq 169 -and $b[1] -eq 254) { return "$Address is a link-local address." }
    if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { return "$Address is a shared (carrier NAT) address." }
    if ($b[0] -eq 0) { return "$Address is an address of 'this network'." }
    if ($b[0] -eq 192 -and $b[1] -eq 0 -and $b[2] -eq 0) { return "$Address is a protocol assignment address." }
    if ($b[0] -eq 198 -and ($b[1] -eq 18 -or $b[1] -eq 19)) { return "$Address is a benchmarking address." }
    if ($b[0] -ge 224) { return "$Address is a multicast or reserved address." }
    ''
}

function Read-AVDTuneWebAppHttpResponse {
    <#
        Reads one HTTP/1.1 answer from a stream (the request said Connection: close and Accept-Encoding: identity): status, headers (names in lower case) and the body
        by Content-Length, chunked or until the end. The head is at most 16 KB. A body over -MaxBytes throws, or is cut there with -Truncate (the page, of which only
        the head is searched). A redirect (3xx) is returned without its body. -TimeoutSeconds is the limit for the whole answer.
    #>
    param([Parameter(Mandatory)][IO.Stream]$Stream, [Parameter(Mandatory)][int]$MaxBytes, [switch]$Truncate, [int]$TimeoutSeconds = 20)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $late = { if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "The site did not answer within $TimeoutSeconds seconds." } }
    $readLine = {
        # one line of the head or of the chunk framing (ASCII, without CR LF); $null at the end of the stream
        $sb = New-Object Text.StringBuilder
        while ($true) {
            $x = $Stream.ReadByte()
            if ($x -lt 0) { if ($sb.Length -eq 0) { return $null }; break }
            if ($x -eq 10) { break }
            if ($x -ne 13) { [void]$sb.Append([char]$x) }
            $headCount++
            if ($headCount -gt 16384) { throw 'The answer of the site has a head or chunk framing of more than 16 KB: refused.' }
        }
        $sb.ToString()
    }
    $headCount = 0
    $first = . $readLine
    if ($null -eq $first) { throw 'The site closed the connection without an answer.' }
    $parts = $first.Split(' ')
    $status = 0
    if ($parts.Count -lt 2 -or $parts[0] -cnotin 'HTTP/1.1', 'HTTP/1.0' -or $parts[1].Length -ne 3 -or -not [int]::TryParse($parts[1], [ref]$status) -or $status -lt 100 -or $status -gt 599) { throw 'The answer of the site is not HTTP.' }
    $headers = @{}
    while ($true) {
        . $late
        $line = . $readLine
        if ($null -eq $line) { throw 'The answer of the site ended inside its head.' }
        if ($line -eq '') { break }
        $c = $line.IndexOf(':')
        if ($c -lt 1) { throw 'The answer of the site has a header line without a name.' }
        $name = $line.Substring(0, $c).Trim().ToLowerInvariant(); $value = $line.Substring($c + 1).Trim()
        if ($name -in 'content-length', 'transfer-encoding', 'location' -and $headers.ContainsKey($name)) { throw "The answer of the site names $name twice: refused." }
        $headers[$name] = $value
    }
    $body = New-Object IO.MemoryStream
    try {
        if ($status -ge 300 -and $status -lt 400 -or $status -in 204, 304 -or $status -lt 200) { return [pscustomobject]@{ Status = $status; Headers = $headers; Bytes = (New-Object byte[] 0); Truncated = $false } }
        $buf = New-Object byte[] 16384
        $take = {
            # up to $want bytes of the stream into the body ($want -lt 0: until the end); stops at -MaxBytes
            param([int64]$want)
            while ($want -ne 0) {
                . $late
                $n = $Stream.Read($buf, 0, $(if ($want -lt 0 -or $want -gt $buf.Length) { $buf.Length } else { [int]$want }))
                if ($n -le 0) { if ($want -gt 0) { throw 'The answer of the site ended before its announced length.' }; return }
                if ($body.Length + $n -gt $MaxBytes) {
                    if (-not $Truncate) { throw "The answer of the site is larger than $MaxBytes bytes: refused." }
                    $body.Write($buf, 0, [int]($MaxBytes - $body.Length)); $cut = $true; return
                }
                $body.Write($buf, 0, $n)
                if ($want -gt 0) { $want -= $n }
            }
        }
        $cut = $false
        $te = [string]$headers['transfer-encoding']
        if ($te) {
            if ($te -ine 'chunked') { throw "The answer of the site uses the transfer encoding '$te': refused." }
            while (-not $cut) {
                $headCount = 0
                $sizeLine = . $readLine
                if ($null -eq $sizeLine) { throw 'The answer of the site ended inside a chunk.' }
                $hex = $sizeLine.Split(';')[0].Trim()
                $size = [int64]0
                if ($hex.Length -lt 1 -or $hex.Length -gt 8 -or -not [int64]::TryParse($hex, [Globalization.NumberStyles]::AllowHexSpecifier, [Globalization.CultureInfo]::InvariantCulture, [ref]$size)) { throw 'The answer of the site has a chunk without a valid size.' }
                if ($size -eq 0) { break }
                . $take $size
                if (-not $cut) { [void](. $readLine) }
            }
        }
        elseif ($headers.ContainsKey('content-length')) {
            $len = [int64]0
            if (-not [int64]::TryParse([string]$headers['content-length'], [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$len)) { throw 'The answer of the site has a Content-Length that is not a number.' }
            if ($len -gt $MaxBytes -and -not $Truncate) { throw "The answer of the site is larger than $MaxBytes bytes ($len): refused." }
            . $take $len
        }
        else { . $take -1 }
        [pscustomobject]@{ Status = $status; Headers = $headers; Bytes = $body.ToArray(); Truncated = [bool]$cut }
    }
    finally { $body.Dispose() }
}

function Invoke-AVDTuneWebAppHttpGet {
    <#
        The real request (NOT exercised by the checks: they use the fake). One GET over TLS 1.2 to the address that was checked before (-Address), so the name
        cannot resolve to another address between the check and the connection; the certificate is checked by Windows for the host name of the URL. No proxy, no
        cookies, no credentials of the administrator, no redirect is followed here (the caller checks every hop). The answer is read by Read-AVDTuneWebAppHttpResponse.
    #>
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Address, [Parameter(Mandatory)][int]$MaxBytes, [switch]$Truncate, [int]$TimeoutSeconds = 20)
    $bad = Test-AVDTuneWebAppUrl $Url 'URL'; if ($bad) { throw $bad }
    $refused = Test-AVDTuneWebAppPublicAddress $Address; if ($refused) { throw "Not asked: $refused" }
    $u = [Uri]$Url
    $ip = [Net.IPAddress]::Parse($Address)
    $tcp = New-Object Net.Sockets.TcpClient($ip.AddressFamily); $ssl = $null
    try {
        $ar = $tcp.BeginConnect($ip, $u.Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutSeconds * 1000)) { throw "No connection to $($u.Host) within $TimeoutSeconds seconds." }
        $tcp.EndConnect($ar)
        $tcp.ReceiveTimeout = $TimeoutSeconds * 1000; $tcp.SendTimeout = $TimeoutSeconds * 1000
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false)   # no own callback: Windows checks the chain and the name
        $ssl.AuthenticateAsClient($u.DnsSafeHost, $null, [Security.Authentication.SslProtocols]::Tls12, $false)
        $hostHeader = if ($u.IsDefaultPort) { $u.Host } else { "$($u.Host):$($u.Port)" }
        $req = [Text.Encoding]::ASCII.GetBytes("GET $($u.PathAndQuery) HTTP/1.1`r`nHost: $hostHeader`r`nUser-Agent: AVDTune`r`nAccept: */*`r`nAccept-Encoding: identity`r`nConnection: close`r`n`r`n")
        $ssl.Write($req, 0, $req.Length); $ssl.Flush()
        Read-AVDTuneWebAppHttpResponse -Stream $ssl -MaxBytes $MaxBytes -Truncate:$Truncate -TimeoutSeconds $TimeoutSeconds
    }
    finally { if ($ssl) { $ssl.Dispose() }; $tcp.Close() }
}

function Resolve-AVDTuneWebAppHost {
    # The real name lookup (NOT exercised by the checks): the addresses of a host as text. An IP address in the URL comes back as it is.
    param([Parameter(Mandatory)][string]$Name)
    @([Net.Dns]::GetHostAddresses($Name) | ForEach-Object { $_.ToString() })
}

function Get-AVDTuneWebAppMatches {
    # Private. The matches of a pattern with a time limit of two seconds on a text of limited length (a prepared page must not keep the window busy).
    param([string]$Text, [string]$Pattern, [int]$MaxLength)
    if (-not $Text) { return , @() }
    if ($Text.Length -gt $MaxLength) { $Text = $Text.Substring(0, $MaxLength) }
    $rx = New-Object regex($Pattern, ([Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant'), [TimeSpan]::FromSeconds(2))
    try { , @($rx.Matches($Text) | ForEach-Object { $_ }) } catch { throw 'The text could not be searched in time: refused.' }
}

function Get-AVDTuneWebAppManifestLink {
    <#
        The href of the first <link rel="manifest"> of a page, '' when there is none. The page is only searched as text (pattern with a time limit, at most 512 KB,
        at most 500 link tags); nothing of it is run, no other tag is looked at (also no <base>: a manifest that is not below the origin is refused later anyway).
    #>
    param([AllowNull()][AllowEmptyString()][string]$Html)
    $attr = { param($tag, $name)
        $m = Get-AVDTuneWebAppMatches $tag ('(?<![A-Za-z0-9_-])' + $name + '\s*=\s*(?:"(?<v>[^"]*)"|''(?<v>[^'']*)''|(?<v>[^\s"''<>]+))') 4096
        if ($m.Count) { [string]$m[0].Groups['v'].Value } else { $null }
    }
    $tags = Get-AVDTuneWebAppMatches $Html '<link(?=[\s/])[^<>]{1,4000}>' 524288
    foreach ($t in @($tags | Select-Object -First 500)) {
        $rel = & $attr $t.Value 'rel'
        if ($null -eq $rel -or @($rel.Split(@(' ', "`t", "`r", "`n"), [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { $_ -ieq 'manifest' }).Count -eq 0) { continue }
        $href = & $attr $t.Value 'href'
        if ($href) { return [Net.WebUtility]::HtmlDecode($href).Trim() }
    }
    ''
}

function ConvertFrom-AVDTuneWebAppJson {
    # Private. JSON as plain data (dictionaries, lists, text, numbers, true/false) with a length and depth limit; no type names are resolved.
    param([string]$Text, [int]$MaxLength, [int]$Depth = 16)
    if ($null -eq $Text -or $Text.Length -gt $MaxLength) { throw "The JSON text is larger than $MaxLength characters: refused." }
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = $MaxLength; $ser.RecursionLimit = $Depth
    try { , $ser.DeserializeObject($Text.TrimStart([char]0xFEFF)) } catch { throw 'The text is not valid JSON (or nested too deep): refused.' }
}

function Get-AVDTuneWebAppManifestIcons {
    <#
        The icons of a web manifest as typed rows (Src, Size = the largest side named in "sizes" or 0, Type, Maskable). The manifest must be a JSON object and
        "icons" a list of objects; an icon whose src is not text, or with a sizes/type/purpose that is not text, is left out. At most 64 icons are read.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $doc = ConvertFrom-AVDTuneWebAppJson -Text $Text -MaxLength 262144
    if ($doc -isnot [System.Collections.IDictionary]) { throw 'The web manifest is not a JSON object: refused.' }
    if (-not $doc.ContainsKey('icons')) { return , @() }
    $icons = $doc['icons']
    if ($icons -is [string] -or $icons -isnot [System.Collections.IList]) { throw 'The web manifest has an "icons" that is not a list: refused.' }
    $out = New-Object System.Collections.ArrayList
    foreach ($i in @($icons | Select-Object -First 64)) {
        if ($i -isnot [System.Collections.IDictionary] -or -not $i.ContainsKey('src') -or $i['src'] -isnot [string] -or -not $i['src'] -or $i['src'].Length -gt 2048) { continue }
        $bad = $false; foreach ($k in 'sizes', 'type', 'purpose') { if ($i.ContainsKey($k) -and $null -ne $i[$k] -and $i[$k] -isnot [string]) { $bad = $true } }
        if ($bad) { continue }
        $size = 0
        foreach ($m in (Get-AVDTuneWebAppMatches ([string]$i['sizes']) '(?<![0-9x])(?<w>[0-9]{1,5})x(?<h>[0-9]{1,5})(?![0-9x])' 200)) { $side = [Math]::Max([int]$m.Groups['w'].Value, [int]$m.Groups['h'].Value); if ($side -gt $size) { $size = $side } }
        $purpose = @(([string]$i['purpose']).Split(@(' '), [StringSplitOptions]::RemoveEmptyEntries))
        [void]$out.Add([pscustomobject]@{ Src = [string]$i['src']; Size = $size; Type = ([string]$i['type']).Trim().ToLowerInvariant(); Maskable = ($purpose.Count -gt 0 -and 'any' -notin $purpose) })
    }
    , @($out)
}

function Select-AVDTuneWebAppManifestIcon {
    <#
        The URL of the icon that is fetched: among the PNG icons (type image/png, or no type and a path ending in .png) of the SAME origin as the manifest the largest
        one; an icon meant only as a mask or monochrome comes after the others. Icons of another host are never asked. '' when there is none; the reason in -Why.
    #>
    param([object[]]$Icons, [Parameter(Mandatory)][string]$ManifestUrl, [ref]$Why)
    $origin = Get-AVDTuneWebAppOrigin $ManifestUrl
    $foreign = 0; $cands = New-Object System.Collections.ArrayList; $n = 0
    foreach ($i in @($Icons)) {
        $n++
        $abs = $null
        if (-not [Uri]::TryCreate([Uri]$ManifestUrl, [string]$i.Src, [ref]$abs)) { continue }
        $url = $abs.GetLeftPart([UriPartial]::Query)
        $isPng = ($i.Type -eq 'image/png') -or (-not $i.Type -and $abs.AbsolutePath.EndsWith('.png', [StringComparison]::OrdinalIgnoreCase))
        if (-not $isPng) { continue }
        if ((Test-AVDTuneWebAppUrl $url 'Icon') -or (Get-AVDTuneWebAppOrigin $url) -cne $origin) { $foreign++; continue }
        [void]$cands.Add([pscustomobject]@{ Url = $url; Size = [int]$i.Size; Maskable = [bool]$i.Maskable; Order = $n })
    }
    if ($cands.Count -eq 0) {
        if ($Why) { $Why.Value = $(if ($foreign) { "The web manifest names PNG icons only on another host or without https ($foreign): refused, nothing was asked there." } else { 'The web manifest names no PNG icon.' }) }
        return ''
    }
    [string]@($cands | Sort-Object @{ Expression = { [int]$_.Maskable } }, @{ Expression = { $_.Size }; Descending = $true }, Order)[0].Url
}

function Get-AVDTuneWebAppSiteIcon {
    <#
        Reads the icon of a site from its web manifest. Only called after the administrator pressed the button and confirmed the host. Every request (page, manifest,
        icon, and every redirect hop) must be https on the origin of the start URL, to an address that is not private or local (the name is resolved, every address
        is checked, the request goes to the checked address). At most 5 hops per file. Limits: page 512 KB (cut, only searched for <link rel="manifest">), manifest
        256 KB, icon 5 MB and 4096 pixels. The icon must be a PNG that decodes. Returns Bytes, Sha256, Url, ManifestUrl, Width, Height.
        -Resolve { param($Name) } gives the addresses of a host; -Get { param($Url, $Address, $MaxBytes, $Truncate) } gives Status, Headers and Bytes of one request.
    #>
    param([Parameter(Mandatory)][string]$StartUrl, [Parameter(Mandatory)][scriptblock]$Resolve, [Parameter(Mandatory)][scriptblock]$Get)
    $bad = Test-AVDTuneWebAppUrl $StartUrl 'Start URL'; if ($bad) { throw $bad }
    $origin = Get-AVDTuneWebAppOrigin $StartUrl
    $fetch = {
        param([string]$Url, [int]$MaxBytes, [bool]$Truncate, [string]$What)
        for ($hop = 0; $hop -lt 5; $hop++) {
            $e = Test-AVDTuneWebAppUrl $Url $What; if ($e) { throw "$e Refused." }
            if ((Get-AVDTuneWebAppOrigin $Url) -cne $origin) { throw "$What`: $(Get-AVDTuneWebAppOrigin $Url) is not the origin of the start URL ($origin): refused, nothing was asked there." }
            $name = ([Uri]$Url).DnsSafeHost
            $addresses = @(& $Resolve $name | Where-Object { $_ } | ForEach-Object { [string]$_ })
            if ($addresses.Count -eq 0) { throw "$What`: the host $name has no address." }
            foreach ($a in $addresses) { $r = Test-AVDTuneWebAppPublicAddress $a; if ($r) { throw "$What`: the host $name is not asked. $r" } }
            $res = & $Get $Url $addresses[0] $MaxBytes $Truncate
            $status = [int](Get-AVDTuneWebAppField $res 'Status')
            if ($status -in 301, 302, 303, 307, 308) {
                $loc = [string](Get-AVDTuneWebAppField (Get-AVDTuneWebAppField $res 'Headers') 'location')
                $next = $null
                if (-not $loc -or $loc.Length -gt 2048 -or -not [Uri]::TryCreate([Uri]$Url, $loc, [ref]$next)) { throw "$What`: the site redirects without a usable address: refused." }
                $Url = $next.GetLeftPart([UriPartial]::Query); continue
            }
            if ($status -ne 200) { throw "$What`: the site answered $status." }
            $bytes = [byte[]](Get-AVDTuneWebAppField $res 'Bytes')
            if ($null -eq $bytes) { $bytes = New-Object byte[] 0 }
            if ($bytes.Length -gt $MaxBytes) { if (-not $Truncate) { throw "$What`: larger than $MaxBytes bytes: refused." }; $bytes = [byte[]]$bytes[0..($MaxBytes - 1)] }
            return [pscustomobject]@{ Url = $Url; Bytes = $bytes }
        }
        throw "$What`: more than 5 redirects: refused."
    }
    $page = & $fetch $StartUrl 524288 $true 'Page'
    $href = Get-AVDTuneWebAppManifestLink ((New-Object Text.UTF8Encoding $false).GetString($page.Bytes))
    if (-not $href) { throw 'The page names no web manifest (<link rel="manifest">): there is no icon to read. Use an image of the library.' }
    $mu = $null
    if ($href.Length -gt 2048 -or -not [Uri]::TryCreate([Uri]$page.Url, $href, [ref]$mu)) { throw 'The page names a web manifest with an address that cannot be used: refused.' }
    $manifest = & $fetch $mu.GetLeftPart([UriPartial]::Query) 262144 $false 'Web manifest'
    $icons = Get-AVDTuneWebAppManifestIcons ((New-Object Text.UTF8Encoding $false).GetString($manifest.Bytes))
    $why = ''
    $iconUrl = Select-AVDTuneWebAppManifestIcon -Icons $icons -ManifestUrl $manifest.Url -Why ([ref]$why)
    if (-not $iconUrl) { throw $why }
    $icon = & $fetch $iconUrl $script:ImageMaxBytes $false 'Icon'
    $info = Get-AVDTuneWebAppImageInfo $icon.Bytes
    if ($info.Format -ne 'png') { throw 'The icon of the site is not a PNG: not used.' }
    [void](ConvertTo-AVDTuneWebAppIco $icon.Bytes)   # it decodes, completely
    [pscustomobject]@{ Bytes = $icon.Bytes; Sha256 = (Get-AVDTuneWebAppHash $icon.Bytes); Url = $icon.Url; ManifestUrl = $manifest.Url; Width = $info.Width; Height = $info.Height }
}

function Get-AVDTuneWebAppField($Object, [string]$Name) {
    # Private. A member of a table or an object, $null when it is missing.
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return , $Object[$Name] }; return $null }
    $p = $Object.PSObject.Properties[$Name]; if ($p) { , $p.Value } else { $null }
}

#endregion

#region import of an existing list (data only: JSON, CSV, or the data lines of the old script read as text)

function ConvertFrom-AVDTuneWebAppImport {
    <#
        Reads a list of web apps (name, URL, optional icon as base64) from text. Nothing is run: JSON and CSV are data, and of a .ps1 only lines of the form
        @{ Name = '...'; Url = '...'; Icon = '...' } are read as text with a pattern (never loaded, never dot-sourced; a value with a variable or a sub-expression
        is not taken). Formats: 'json' (a list of objects, or an object with a list "webApps" or "items"), 'csv' (a header line with Name and Url, optional Icon;
        comma or semicolon), 'ps1'. Names of the fields, any case: name | title | displayname, url | starturl | uri, icon | iconbase64 | base64.
        Limits: 16 MB text, 200 entries, an icon of at most 5 MB that is a PNG or .ico and decodes. Returns Entries (Name, Url, IconBytes, IconFormat, Note) and Errors.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][ValidateSet('json', 'csv', 'ps1')][string]$Format)
    if (-not $Text -or -not $Text.Trim()) { throw 'The file is empty.' }
    if ($Text.Length -gt 16777216) { throw 'The file is larger than 16 MB: not read.' }
    $names = @{ name = 'Name'; title = 'Name'; displayname = 'Name'; url = 'Url'; starturl = 'Url'; uri = 'Url'; icon = 'Icon'; iconbase64 = 'Icon'; base64 = 'Icon' }
    $rows = New-Object System.Collections.ArrayList; $errors = New-Object System.Collections.ArrayList
    $add = { param($pairs, [string]$where)
        # $pairs: a table field name -> value. Typed: every used value must be text.
        $row = @{ Name = $null; Url = $null; Icon = $null }; $typed = $true
        foreach ($k in @($pairs.Keys)) {
            $f = $names[([string]$k).Trim().ToLowerInvariant()]
            if (-not $f -or $null -ne $row[$f]) { continue }
            $v = $pairs[$k]
            if ($null -eq $v -or ($v -is [string] -and -not $v.Trim())) { continue }
            if ($v -isnot [string]) { $typed = $false; continue }
            $row[$f] = $v.Trim()
        }
        if (-not $typed) { [void]$errors.Add("$where`: a value is not text: left out."); return }
        if (-not $row.Name -or -not $row.Url) { [void]$errors.Add("$where`: name or URL is missing: left out."); return }
        if ($rows.Count -ge 200) { throw 'The file has more than 200 entries: nothing is imported.' }
        [void]$rows.Add($row)
    }
    switch ($Format) {
        'json' {
            $doc = ConvertFrom-AVDTuneWebAppJson -Text $Text -MaxLength 16777216 -Depth 6
            if ($doc -is [System.Collections.IDictionary]) { $list = $null; foreach ($k in @($doc.Keys)) { if ($k -in 'webApps', 'items') { $list = $doc[$k] } }; $doc = $list }
            if ($null -eq $doc -or $doc -is [string] -or $doc -isnot [System.Collections.IList]) { throw 'The JSON file is not a list of web apps (a list of objects, or an object with a list "webApps").' }
            $n = 0
            foreach ($e in @($doc)) { $n++; if ($e -isnot [System.Collections.IDictionary]) { [void]$errors.Add("Entry $n`: not an object: left out."); continue }; . $add $e "Entry $n" }
        }
        'csv' {
            $head = @($Text -split "`r?`n", 2)[0]
            $delimiter = if (@($head.ToCharArray() | Where-Object { $_ -eq ';' }).Count -gt @($head.ToCharArray() | Where-Object { $_ -eq ',' }).Count) { ';' } else { ',' }
            $heads = @($head.Split($delimiter) | ForEach-Object { $names[$_.Trim().Trim('"').ToLowerInvariant()] })
            if ('Name' -notin $heads -or 'Url' -notin $heads) { throw 'The CSV file needs a header line with the columns Name and Url (optional: Icon).' }
            $n = 1
            foreach ($e in @(ConvertFrom-Csv -InputObject $Text -Delimiter $delimiter)) {
                $n++
                $pairs = @{}; foreach ($p in $e.PSObject.Properties) { $pairs[$p.Name] = $p.Value }
                . $add $pairs "Line $n"
            }
        }
        'ps1' {
            $n = 0
            foreach ($line in ($Text -split "`r?`n")) {
                $n++
                if ($line.Length -gt 8388608 -or $line.IndexOf('@{') -lt 0) { continue }
                $pairs = @{}
                foreach ($m in (Get-AVDTuneWebAppMatches $line '(?<![A-Za-z0-9_$])(?<k>[A-Za-z][A-Za-z0-9]{0,30})\s*=\s*(?:''(?<v>[^'']*)''|"(?<v>[^"`$]*)")' 8388608)) { $key = $m.Groups['k'].Value; if (-not $pairs.ContainsKey($key)) { $pairs[$key] = [string]$m.Groups['v'].Value } }
                if (@($pairs.Keys | Where-Object { $names[$_.ToLowerInvariant()] -eq 'Url' }).Count -eq 0) { continue }   # not a data line
                . $add $pairs "Line $n"
            }
            if ($rows.Count -eq 0 -and $errors.Count -eq 0) { throw 'The script has no data lines of the form @{ Name = ''...''; Url = ''...'' }: nothing is imported (the script is never run).' }
        }
    }
    $entries = foreach ($r in $rows) {
        $bytes = $null; $fmt = ''; $note = ''
        if ($r.Icon) {
            try {
                $b64 = [string]$r.Icon
                if ($b64.Length -gt 7000000) { throw 'The icon is larger than 5 MB.' }
                if ($b64.StartsWith('data:', [StringComparison]::OrdinalIgnoreCase)) { $comma = $b64.IndexOf(','); if ($comma -lt 0 -or $comma -gt 100) { throw 'The icon is a data URL without data.' }; $b64 = $b64.Substring($comma + 1) }
                try { $raw = [Convert]::FromBase64String($b64) } catch { throw 'The icon is not base64.' }
                $info = Get-AVDTuneWebAppImageInfo $raw
                [void](Get-AVDTuneWebAppIconPreview -Bytes $raw)   # it decodes
                if ($info.Format -eq 'png') { [void](ConvertTo-AVDTuneWebAppIco $raw) }
                $bytes = $raw; $fmt = $info.Format
            }
            catch { $note = "Icon not used: $($_.Exception.Message)" }
        }
        [pscustomobject]@{ Name = [string]$r.Name; Url = [string]$r.Url; IconBytes = $bytes; IconFormat = $fmt; Note = $note }
    }
    [pscustomobject]@{ Entries = @($entries); Errors = @($errors) }
}

#endregion


Export-ModuleMember -Function Get-AVDTuneWebAppSpike, Get-AVDTuneWebAppPolicyLocation, Get-AVDTuneWebAppWindowModes, Test-AVDTuneWebAppUrl, Get-AVDTuneWebAppOrigin, Get-AVDTuneWebAppIdGuess,
    Get-AVDTuneWebAppId, Get-AVDTuneWebAppLaunch, New-AVDTuneWebAppPolicyEntry, ConvertFrom-AVDTuneWebAppPolicy, ConvertTo-AVDTuneWebAppPolicyText, Test-AVDTuneWebAppSameUrl,
    Find-AVDTuneWebAppPolicyEntry, Merge-AVDTuneWebAppPolicy, Test-AVDTuneWebAppPolicyHas, Get-AVDTuneWebAppPolicyUndo, Get-AVDTuneWebAppEntryText, Initialize-AVDTuneLinkPropertyType, Get-AVDTuneLinkAumid, Set-AVDTuneLinkAumid,
    Get-AVDTuneWebAppImageLimits, Get-AVDTuneWebAppHash, Get-AVDTuneWebAppImageInfo, ConvertTo-AVDTuneWebAppIco, Get-AVDTuneWebAppIconPreview, Test-AVDTuneWebAppPublicAddress, Read-AVDTuneWebAppHttpResponse,
    Invoke-AVDTuneWebAppHttpGet, Resolve-AVDTuneWebAppHost, Get-AVDTuneWebAppManifestLink, Get-AVDTuneWebAppManifestIcons, Select-AVDTuneWebAppManifestIcon, Get-AVDTuneWebAppSiteIcon, ConvertFrom-AVDTuneWebAppImport
