<#
    AVDTune Office side (docs\plans\avdtune.md, sections 3, 3c, 9, 11 phase 6; issue 35; docs\office.md): Microsoft 365 Apps on the master with the
    Office Deployment Tool (ODT): configuration, detection of the actual state, install or reconfigure, remove, undo, and the HKLM update UI policies.

      * Every access to the master goes through the machine adapter ($m: registry) and the Office adapter ($O: ODT page, download, signature, files, run).
        Tests\Fakes\FakeOffice.ps1 has the fake; New-AVDTuneOfficeAdapter is the real one and is NOT exercised by the checks (no download, no install).
      * The ODT comes only from fixed Microsoft hosts over https: the download page www.microsoft.com (id 49117) names the package, the package comes from
        download.microsoft.com; no redirect is followed. It lands in a new folder below the protected state folder (Administrators and SYSTEM only), is checked
        (Authenticode: Microsoft Corporation, Microsoft code signing CA), extracted there, and setup.exe is checked by full path (subject, issuer, original file
        name setup.exe, product and description of the ODT: trust key odt-setup, held open until its process ended) directly before it starts. The configuration.xml is written into the same folder; it is built from validated data only.
      * Changes are recorded (run record, LastChange, change log) and sit behind the write gate. Undo goes back to the state found before the first change
        (kept in config\office-undo.json, never overwritten by a later change): remove when Office was not there, the earlier configuration when it is known.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Updates.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.UpdateBlock.psm1')   # status of the update block and the maintenance record (Undo of the updates fix must not take a value the block owns)
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Trust.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Benchmark.psm1')   # the measure program helpers; Invoke-AVDTuneChildProcess (allowlist environment, job object) is in AVDTune.psm1 (#76)

$script:Learn = 'https://learn.microsoft.com'
$script:OdtPageUrl = 'https://www.microsoft.com/en-us/download/details.aspx?id=49117'
$script:OdtPageHost = 'www.microsoft.com'
$script:OdtFileHost = 'download.microsoft.com'
$script:MaxOdtBytes = 100MB
$script:MaxPageChars = 3MB
$script:ClickToRun = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun'
$script:PolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'
$script:Src = @{
    Avd = "$script:Learn/en-us/azure/virtual-desktop/install-office-on-wvd-master-image"
    Shared = "$script:Learn/en-us/microsoft-365-apps/licensing-activation/overview-shared-computer-activation"
    Odt = "$script:Learn/en-us/microsoft-365-apps/deploy/overview-office-deployment-tool"
    Options = "$script:Learn/en-us/microsoft-365-apps/deploy/office-deployment-tool-configuration-options"
    Channels = "$script:Learn/en-us/microsoft-365-apps/updates/overview-update-channels"
    UpdateSettings = "$script:Learn/en-us/microsoft-365-apps/updates/configure-update-settings-microsoft-365-apps"
    UpdateKb = 'https://support.microsoft.com/kb/2753538'
    OutlookVdi = "$script:Learn/en-us/microsoft-365-apps/outlook/get-started/virtualized-desktop-infrastructure"
    OutlookDeploy = "$script:Learn/en-us/microsoft-365-apps/outlook/get-started/deployment-new-outlook"
}

#region catalog

# Channel names are the values of the ODT attribute Channel; the GUID is the end of the CDNBaseUrl that Office writes (same table as the Overview).
$script:Channels = @(
    [pscustomobject]@{ Key = 'MonthlyEnterprise'; Name = 'Monthly Enterprise Channel'; Guid = '55336b82-a18d-4dd6-b5f6-9e5095c314a6' }
    [pscustomobject]@{ Key = 'Current'; Name = 'Current Channel'; Guid = '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' }
    [pscustomobject]@{ Key = 'SemiAnnual'; Name = 'Semi-Annual Enterprise Channel'; Guid = '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' }
    [pscustomobject]@{ Key = 'CurrentPreview'; Name = 'Current Channel (Preview)'; Guid = '64256afe-f5d9-4f86-8936-8840a6a4f5be' }
    [pscustomobject]@{ Key = 'BetaChannel'; Name = 'Beta Channel'; Guid = 'b8f9b850-328d-4355-9145-c59439a0c4cf' }
)
# Windows 11 multi-session supports only these two products (Learn, install-office-on-wvd-master-image): Microsoft 365 Apps for enterprise and Apps for business of Business Premium.
# The page shows them as the licence; the ODT product ID ("Retail" is only the Click-to-Run name) stays the internal value.
$script:Licenses = @(
    [pscustomobject]@{ Key = 'O365ProPlusRetail'; Name = 'Microsoft 365 E3/E5 (Apps for enterprise)'; Text = 'Choose this when the users have a Microsoft 365 or Office 365 E3, E5 (or A3/A5) licence. "Retail" in O365ProPlusRetail is only the Click-to-Run name, not a retail licence.' }
    [pscustomobject]@{ Key = 'O365BusinessRetail'; Name = 'Microsoft 365 Business Premium (Apps for business)'; Text = 'Choose this when the users have Microsoft 365 Business Premium: it is the only business plan with shared computer activation. Other business plans (Standard, Basic) do not work on a multi-user host.' }
)
$script:Products = @($script:Licenses | ForEach-Object Key)
# What the page offers as a tick box (ODT ExcludeApp IDs). Groove is the old OneDrive sync client, Lync is Skype for Business. Word, Excel, PowerPoint and OneNote are the best-practice default; Outlook has its own choice.
$script:InstallApps = @('Word', 'Excel', 'PowerPoint', 'OneNote', 'Access', 'Publisher', 'Groove', 'Lync', 'Bing')
$script:DefaultInstallApps = @('Word', 'Excel', 'PowerPoint', 'OneNote')
# Never offered as a tick: they come as their own VDI packages (issue 56) and are always excluded from the ODT run
$script:AlwaysExcluded = @('OneDrive', 'Teams')
$script:ExcludableApps = @(@($script:InstallApps) + @($script:AlwaysExcluded) | Sort-Object)
# Classic Outlook = ODT app "Outlook", new Outlook = ODT app "OutlookForWindows" (ExcludeApp IDs of the Learn page)
$script:OutlookChoices = @(
    [pscustomobject]@{ Key = 'both'; Name = 'Both, side by side (recommended by Microsoft)' }
    [pscustomobject]@{ Key = 'classic'; Name = 'Outlook (classic) only' }
    [pscustomobject]@{ Key = 'new'; Name = 'Outlook (new) only' }
)
# The common languages of the page (issue 61); MatchOS = the display language of Windows. Any other valid language ID in a saved file is still accepted.
$script:Languages = @('MatchOS', 'en-US', 'de-DE', 'en-GB', 'fr-FR', 'it-IT', 'es-ES', 'nl-NL', 'pl-PL', 'pt-PT', 'pt-BR', 'sv-SE', 'da-DK', 'nb-NO', 'fi-FI', 'cs-CZ', 'tr-TR', 'ja-JP', 'zh-CN')

function Get-AVDTuneOfficeChannels { @($script:Channels) }
function Get-AVDTuneOfficeProducts { @($script:Products) }
function Get-AVDTuneOfficeLicenses { @($script:Licenses) }
function Get-AVDTuneOfficeLicenseName([string]$Product) { $l = @($script:Licenses | Where-Object { $_.Key -ceq $Product }); if ($l.Count -gt 0) { $l[0].Name } else { $Product } }
function Get-AVDTuneOfficeExcludableApps { @($script:ExcludableApps) }
function Get-AVDTuneOfficeInstallApps { @($script:InstallApps) }
function Get-AVDTuneOfficeDefaultInstallApps { @($script:DefaultInstallApps) }
function Get-AVDTuneOfficeOutlookChoices { @($script:OutlookChoices) }
function Get-AVDTuneOfficeLanguages { @($script:Languages) }

function ConvertTo-AVDTuneOfficeExcludes {
    # The apps that are ticked (to install) as the ExcludeApp list of the configuration: every offered app that is not ticked, plus OneDrive and Teams (own VDI packages, never from the ODT).
    param([string[]]$Install = @())
    $bad = @($Install | Where-Object { $_ -cnotin $script:InstallApps })
    if ($bad.Count -gt 0) { throw "'$($bad -join ', ')' is not an app of the install list." }
    @(@($script:InstallApps | Where-Object { $_ -cnotin $Install }) + @($script:AlwaysExcluded) | Sort-Object -Unique)
}

function ConvertTo-AVDTuneOfficeLanguageList {
    # Ticked languages in the order for the ODT: the first language is the shell UI language, so en-US (when ticked) and the other IDs come first and MatchOS last (the sample of the AVD article).
    param([string[]]$Selected = @())
    $sel = @($Selected | Where-Object { $_ })
    @(@($script:Languages | Where-Object { $_ -ne 'MatchOS' -and $_ -cin $sel }) + @($sel | Where-Object { $_ -cnotin $script:Languages -and $_ -ne 'MatchOS' }) + @($sel | Where-Object { $_ -ceq 'MatchOS' }))
}

function Get-AVDTuneOfficeDefaults {
    # The sample of the AVD article (Monthly Enterprise, 64 bit, en-US plus the language of Windows) with the best-practice apps (issue 61): Word, Excel, PowerPoint, OneNote and both Outlooks; no Access, Publisher, Groove, Skype, Bing; OneDrive and Teams come with the VDI components
    [pscustomobject][ordered]@{ Channel = 'MonthlyEnterprise'; Edition = '64'; Product = 'O365ProPlusRetail'; Languages = @('en-US', 'MatchOS'); Outlook = 'both'; ExcludeApps = @(ConvertTo-AVDTuneOfficeExcludes $script:DefaultInstallApps); RemoveMSI = $true }
}

#endregion

#region configuration (data, validated)

function Test-AVDTuneOfficeConfig {
    # Problems of a configuration as a list of texts; empty = valid. Strict types: "true" is not $true.
    param($Config)
    $p = New-Object System.Collections.ArrayList
    if ($null -eq $Config) { return @('There is no configuration.') }
    $get = { param($n) Get-AVDTuneProp $Config $n }
    $channel = & $get 'Channel'
    if ($channel -isnot [string] -or $channel -cnotin @($script:Channels | ForEach-Object Key)) { [void]$p.Add("Channel must be one of $((@($script:Channels | ForEach-Object Key)) -join ', ').") }
    $edition = & $get 'Edition'
    if ($edition -isnot [string] -or $edition -cnotin '32', '64') { [void]$p.Add('Edition must be "32" or "64" (Microsoft recommends 64).') }
    $product = & $get 'Product'
    if ($product -isnot [string] -or $product -cnotin $script:Products) { [void]$p.Add("The licence must be Microsoft 365 E3/E5 (O365ProPlusRetail) or Business Premium (O365BusinessRetail): multi-session supports only these.") }
    $langs = & $get 'Languages'
    if ($null -eq $langs -or @($langs).Count -eq 0) { [void]$p.Add('At least one language (or MatchOS) is needed.') }
    elseif (@($langs).Count -gt 20) { [void]$p.Add('At most 20 languages.') }
    else {
        $seen = @{}
        foreach ($l in @($langs)) {
            if ($l -isnot [string] -or $l.Length -gt 20 -or -not ([regex]::IsMatch($l, '^(MatchOS|[A-Za-z]{2,3}-[A-Za-z]{2,4}(-[A-Za-z0-9]{2,8})?)\z', 'None', [TimeSpan]::FromMilliseconds(200)))) { [void]$p.Add("'$l' is not a language ID (like de-DE) or MatchOS."); continue }
            if ($seen.ContainsKey($l.ToLowerInvariant())) { [void]$p.Add("Language '$l' appears twice.") }
            $seen[$l.ToLowerInvariant()] = $true
        }
    }
    $ex = & $get 'ExcludeApps'
    foreach ($e in @($ex)) { if ($null -ne $e -and ($e -isnot [string] -or $e -cnotin $script:ExcludableApps)) { [void]$p.Add("'$e' is not an app ID that can be excluded (Outlook is chosen with the Outlook setting).") } }
    $outlook = & $get 'Outlook'
    $outlookRaw = $Config.PSObject.Properties['Outlook']   # a one-element list unrolls in the call above; "strict types" refuses it
    if ($outlook -isnot [string] -or ($outlookRaw -and $outlookRaw.Value -is [array]) -or $outlook -cnotin @($script:OutlookChoices | ForEach-Object Key)) { [void]$p.Add("Outlook must be one of $((@($script:OutlookChoices | ForEach-Object Key)) -join ', ').") }
    $msi = & $get 'RemoveMSI'
    if ($msi -isnot [bool]) { [void]$p.Add('RemoveMSI must be true or false.') }
    @($p)
}

function ConvertTo-AVDTuneOfficeConfig {
    # Normalizes a validated configuration (order of the apps, canonical case of the channel/product)
    param([Parameter(Mandatory)]$Config)
    $problems = @(Test-AVDTuneOfficeConfig $Config)
    if ($problems.Count -gt 0) { throw "The Office configuration is not valid: $($problems -join ' ')" }
    [pscustomobject][ordered]@{
        Channel = [string]$Config.Channel; Edition = [string]$Config.Edition; Product = [string]$Config.Product
        Languages = @(@($Config.Languages) | ForEach-Object { [string]$_ }); Outlook = [string]$Config.Outlook; ExcludeApps = @(@(@($Config.ExcludeApps) | Where-Object { $_ } | ForEach-Object { [string]$_ }) + @($script:AlwaysExcluded) | Sort-Object -Unique); RemoveMSI = [bool]$Config.RemoveMSI   # OneDrive and Teams are always excluded, also in a saved or converted configuration (own VDI packages, issue 56)
    }
}

function ConvertFrom-AVDTuneOfficeStored {
    # A configuration file or record written before issue 61 has no Outlook setting and names Outlook / OutlookForWindows in ExcludeApps instead. Only such a file is converted: Outlook
    # excluded gives 'new', OutlookForWindows excluded gives 'classic', none gives 'both', both excluded stays invalid ($null). A file with an Outlook setting is left alone.
    param($Stored)
    if ($null -eq $Stored -or $Stored -isnot [System.Management.Automation.PSCustomObject]) { return $Stored }
    if ($null -ne (Get-AVDTuneProp $Stored 'Outlook')) { return $Stored }
    $ex = @(@(Get-AVDTuneProp $Stored 'ExcludeApps') | Where-Object { $null -ne $_ })
    $classicOut = 'Outlook' -cin $ex; $newOut = 'OutlookForWindows' -cin $ex
    $choice = if ($classicOut -and $newOut) { $null } elseif ($classicOut) { 'new' } elseif ($newOut) { 'classic' } else { 'both' }
    $o = [ordered]@{}
    foreach ($pr in $Stored.PSObject.Properties) { $o[$pr.Name] = $pr.Value }
    $o['Outlook'] = $choice
    $o['ExcludeApps'] = @($ex | Where-Object { $_ -cnotin 'Outlook', 'OutlookForWindows' })
    [pscustomobject]$o
}

function Get-AVDTuneOfficeEffectiveExcludes {
    # The ExcludeApp IDs of the ODT run: the unticked apps plus what the Outlook choice leaves out (classic = ODT app Outlook, new = OutlookForWindows)
    param([Parameter(Mandatory)]$Config)
    $x = @(@($Config.ExcludeApps) + @($script:AlwaysExcluded))
    switch ([string]$Config.Outlook) { 'classic' { $x += 'OutlookForWindows' } 'new' { $x += 'Outlook' } }
    @($x | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-AVDTuneOfficeConfigPath([string]$Root) { Join-Path $Root 'config\office.json' }

function Get-AVDTuneOfficeConfig {
    # The saved configuration, the defaults when none is saved. A saved file that is not valid is an error (fail closed): nothing is built from it.
    param([string]$Root = (Get-AVDTuneRoot))
    $o = ConvertFrom-AVDTuneOfficeStored (Read-AVDTuneJson (Get-AVDTuneOfficeConfigPath $Root))
    if ($null -eq $o) { return Get-AVDTuneOfficeDefaults }
    try { ConvertTo-AVDTuneOfficeConfig $o } catch { throw "config\office.json is not usable: $($_.Exception.Message)" }
}

function Set-AVDTuneOfficeConfig {
    # Saves the settings of the form (no change of the master, no gate needed)
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Config)
    $c = ConvertTo-AVDTuneOfficeConfig $Config
    Write-AVDTuneFile (Get-AVDTuneOfficeConfigPath $Root) ($c | ConvertTo-Json -Depth 4)
    $c
}

function Test-AVDTuneOfficeLogPath([string]$Path) { [bool]($Path -match '^[A-Za-z]:\\[^"<>|*?\x00-\x1F]+\z' -and $Path -notmatch '\.\.') }

function New-AVDTuneOfficeXml {
    <#
        configuration.xml text for the ODT. Mode Install builds the Add block (Learn sample: channel, edition, product, languages, excluded apps, RemoveMSI,
        Updates Enabled FALSE, no UI, EULA, logging, FORCEAPPSHUTDOWN, SharedComputerLicensing 1); Mode Remove builds <Remove All="TRUE"/>. Built with XmlWriter
        from validated values only (everything is escaped), never by joining text.
    #>
    param([Parameter(Mandatory)]$Config, [ValidateSet('Install', 'Remove')][string]$Mode = 'Install', [Parameter(Mandatory)][string]$LogPath)
    if (-not (Test-AVDTuneOfficeLogPath $LogPath)) { throw 'The log folder of the ODT is not a plain local path.' }
    $c = ConvertTo-AVDTuneOfficeConfig $Config
    $sb = New-Object System.Text.StringBuilder
    $ws = New-Object System.Xml.XmlWriterSettings; $ws.Indent = $true; $ws.OmitXmlDeclaration = $true; $ws.IndentChars = '  '
    $w = [System.Xml.XmlWriter]::Create($sb, $ws)
    try {
        $w.WriteStartElement('Configuration')
        if ($Mode -eq 'Install') {
            $w.WriteStartElement('Add'); $w.WriteAttributeString('OfficeClientEdition', $c.Edition); $w.WriteAttributeString('Channel', $c.Channel)
            $w.WriteStartElement('Product'); $w.WriteAttributeString('ID', $c.Product)
            foreach ($l in $c.Languages) { $w.WriteStartElement('Language'); $w.WriteAttributeString('ID', $l); $w.WriteEndElement() }
            foreach ($a in (Get-AVDTuneOfficeEffectiveExcludes $c)) { $w.WriteStartElement('ExcludeApp'); $w.WriteAttributeString('ID', $a); $w.WriteEndElement() }
            $w.WriteEndElement(); $w.WriteEndElement()
            if ($c.RemoveMSI) { $w.WriteStartElement('RemoveMSI'); $w.WriteEndElement() }
            $w.WriteStartElement('Updates'); $w.WriteAttributeString('Enabled', 'FALSE'); $w.WriteEndElement()
        }
        else { $w.WriteStartElement('Remove'); $w.WriteAttributeString('All', 'TRUE'); $w.WriteEndElement() }
        $w.WriteStartElement('Display'); $w.WriteAttributeString('Level', 'None'); $w.WriteAttributeString('AcceptEULA', 'TRUE'); $w.WriteEndElement()
        $w.WriteStartElement('Logging'); $w.WriteAttributeString('Level', 'Standard'); $w.WriteAttributeString('Path', $LogPath); $w.WriteEndElement()
        if ($Mode -eq 'Install') {
            $w.WriteStartElement('Property'); $w.WriteAttributeString('Name', 'FORCEAPPSHUTDOWN'); $w.WriteAttributeString('Value', 'TRUE'); $w.WriteEndElement()
            $w.WriteStartElement('Property'); $w.WriteAttributeString('Name', 'SharedComputerLicensing'); $w.WriteAttributeString('Value', '1'); $w.WriteEndElement()
        }
        $w.WriteEndElement()
    }
    finally { $w.Dispose() }
    $sb.ToString()
}

function Test-AVDTuneOfficeXml {
    # Reads a configuration.xml back (no DTD, no resolver) and returns @{ Ok; Problems; Channel; Edition; Product; Languages; ExcludeApps; Shared; UpdatesEnabled; Remove }
    param([string]$Xml)
    $problems = New-Object System.Collections.ArrayList
    $doc = New-Object System.Xml.XmlDocument; $doc.XmlResolver = $null
    $rs = New-Object System.Xml.XmlReaderSettings; $rs.DtdProcessing = 'Prohibit'; $rs.XmlResolver = $null
    try { $r = [System.Xml.XmlReader]::Create((New-Object IO.StringReader $Xml), $rs); try { $doc.Load($r) } finally { $r.Dispose() } }
    catch { return [pscustomobject]@{ Ok = $false; Problems = @("not well formed: $($_.Exception.Message)") } }
    $root = $doc.DocumentElement
    if ($root.Name -ne 'Configuration') { [void]$problems.Add('The root element must be Configuration.') }
    $add = $root.SelectSingleNode('Add'); $remove = $root.SelectSingleNode('Remove')
    $prop = { param($n) $x = $root.SelectSingleNode("Property[@Name='$n']"); if ($x) { $x.GetAttribute('Value') } else { $null } }
    $upd = $root.SelectSingleNode('Updates')
    [pscustomobject]@{
        Ok = ($problems.Count -eq 0); Problems = @($problems); Remove = [bool]$remove
        Channel = $(if ($add) { $add.GetAttribute('Channel') } else { '' }); Edition = $(if ($add) { $add.GetAttribute('OfficeClientEdition') } else { '' })
        Product = $(if ($add -and $add.SelectSingleNode('Product')) { $add.SelectSingleNode('Product').GetAttribute('ID') } else { '' })
        Languages = @(if ($add) { $add.SelectNodes('Product/Language') | ForEach-Object { $_.GetAttribute('ID') } }); ExcludeApps = @(if ($add) { $add.SelectNodes('Product/ExcludeApp') | ForEach-Object { $_.GetAttribute('ID') } })
        Shared = (& $prop 'SharedComputerLicensing'); UpdatesEnabled = $(if ($upd) { $upd.GetAttribute('Enabled') } else { $null })
    }
}

#endregion

#region detection of the actual state

function Get-AVDTuneOfficeState {
    # What is on the master now (read only). Languages come from the product release key; Learn does not document it, so it is Verified=false in the rows.
    param([Parameter(Mandatory)]$Machine)
    $info = Get-AVDTuneOfficeInfo $Machine
    $key = "$script:ClickToRun\Configuration"
    $ids = [string](& $Machine.RegGet $key 'ProductReleaseIds')
    $products = @($ids -split '[,;\s]+' | Where-Object { $_ })
    # Installed languages (issue 61). Learn documents none of these places, so every one is tried and the result is Verified=false in the rows: the culture keys of the product below
    # ProductReleaseIDs\Active\<product> (where Click-to-Run keeps them), the same below ProductReleaseIDs\<product> (older layout and the first guess of this page), and the
    # uninstall entries "<product> - <culture>" (named in a Microsoft Tech Community thread), 64 and 32 bit view. x-none and other non-culture names do not match.
    $cultureRx = '^[a-z]{2,3}-[a-z]{2,4}(-[a-z0-9]{2,8})?\z'
    $langs = @()
    $uninstall = @()
    foreach ($u in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') { $uninstall += @(& $Machine.RegSubKeys $u) }
    foreach ($p in $products) {
        if ($p -notmatch '^[A-Za-z0-9]+\z') { continue }
        foreach ($base in "$script:ClickToRun\ProductReleaseIDs\Active\$p", "$script:ClickToRun\ProductReleaseIDs\$p") {
            foreach ($sub in @(& $Machine.RegSubKeys $base)) { if ($sub -match $cultureRx) { $langs += $sub.ToLowerInvariant() } }
        }
        $rx = '^' + [regex]::Escape($p) + ' - (' + $cultureRx.Substring(1, $cultureRx.Length - 3) + ')\z'
        foreach ($sub in $uninstall) { if ($sub -match $rx) { $langs += $Matches[1].ToLowerInvariant() } }
    }
    # the effective setting of automatic updates: the policy (Learn: Group Policy wins over the ODT) when it is there, otherwise what the ODT wrote
    $autoPolicy = & $Machine.RegGet $script:PolicyKey 'enableautomaticupdates'
    $updatesEnabled = $info.UpdatesEnabled
    if ($null -ne $autoPolicy -and [string]$autoPolicy -eq '0') { $updatesEnabled = $false } elseif ($null -ne $autoPolicy -and [string]$autoPolicy -eq '1') { $updatesEnabled = $true }
    $channelKey = ''
    $cdn = [string](& $Machine.RegGet $key 'CDNBaseUrl')
    if ($cdn -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\s*\z') { $c = @($script:Channels | Where-Object { $_.Guid -eq $Matches[1].ToLowerInvariant() }); if ($c.Count -gt 0) { $channelKey = $c[0].Key } }
    $edition = [string](& $Machine.RegGet 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'EditionID')
    $policy = @{}; foreach ($n in 'hideupdatenotifications', 'hideenabledisableupdates') { $policy[$n] = & $Machine.RegGet $script:PolicyKey $n }
    [pscustomobject]@{
        Installed = $info.Installed; Build = $info.Build; Channel = $info.Channel; ChannelKey = $channelKey; Platform = $info.Platform; SharedLicensing = $info.SharedLicensing; UpdatesEnabled = $updatesEnabled; UpdatePolicy = $autoPolicy
        Products = $products; Languages = @($langs | Select-Object -Unique); MultiSession = ($edition -eq 'ServerRdsh'); Policy = $policy
    }
}

function New-AVDTuneOfficeRow([string]$Id, [string]$Title, [string]$Status, [string]$Reason, [string]$Fix, [string]$Source, [bool]$Verified, [string]$Note = '', [string]$FixAction = '') {
    # FixAction: the one-click fix of the row ('' = none); only a red row can carry one (issue 61)
    if ($FixAction -and $Status -ne 'red') { throw 'Only a red row can have a one-click fix.' }
    [pscustomobject]@{ Id = $Id; Title = $Title; Status = $Status; Reason = $Reason; Fix = $Fix; Source = $Source; Verified = $Verified; Note = $Note; FixAction = $FixAction }
}

function Get-AVDTuneOfficeRows {
    <#
        The test of the Office page: the state found against the configuration of the form and against what Learn requires for multi-session.
        Status green | yellow | red | info (the pills of the FSLogix page). Read only.
    #>
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$Config)
    $s = Get-AVDTuneOfficeState $Machine
    $rows = New-Object System.Collections.ArrayList
    $add = { param($r) [void]$rows.Add($r) }
    if (-not $s.Installed) {
        & $add (New-AVDTuneOfficeRow 'office.installed' 'Microsoft 365 Apps' 'red' 'Not installed on this master.' 'Press Install or reconfigure.' $script:Src.Avd $true)
        return @($rows)
    }
    & $add (New-AVDTuneOfficeRow 'office.installed' 'Microsoft 365 Apps' 'green' "Build $($s.Build), $($s.Channel)." '' $script:Src.Avd $true)
    $wantCh = @($script:Channels | Where-Object Key -eq $Config.Channel)[0]
    if (-not $s.ChannelKey) { & $add (New-AVDTuneOfficeRow 'office.channel' 'Update channel' 'yellow' 'The channel could not be read from the CDN address.' 'Look at the Office build info.' $script:Src.Channels $false 'The CDNBaseUrl GUIDs are those of the Overview.') }
    elseif ($s.ChannelKey -eq $Config.Channel) { & $add (New-AVDTuneOfficeRow 'office.channel' 'Update channel' 'green' "$($wantCh.Name), as configured." '' $script:Src.Channels $true) }
    else { & $add (New-AVDTuneOfficeRow 'office.channel' 'Update channel' 'yellow' "Installed: $($s.Channel). Configured: $($wantCh.Name)." 'Install or reconfigure applies the configured channel.' $script:Src.Channels $true) }
    $wantPlat = if ($Config.Edition -eq '64') { 'x64' } else { 'x86' }
    if ($s.Platform -eq $wantPlat) { & $add (New-AVDTuneOfficeRow 'office.platform' '32 or 64 bit' 'green' "$($s.Platform), as configured." '' $script:Src.Avd $true) }
    else { & $add (New-AVDTuneOfficeRow 'office.platform' '32 or 64 bit' 'yellow' "Installed: $($s.Platform). Configured: $wantPlat." 'Microsoft recommends 64 bit. Switching needs the reinstall (Install or reconfigure).' $script:Src.Avd $true) }
    $names = { param($ids) ($ids | ForEach-Object { Get-AVDTuneOfficeLicenseName $_ }) -join ', ' }
    if ($s.Products.Count -gt 0 -and $Config.Product -cin $s.Products) { & $add (New-AVDTuneOfficeRow 'office.product' 'Licence (apps)' 'green' (& $names $s.Products) '' $script:Src.Avd $true) }
    else { & $add (New-AVDTuneOfficeRow 'office.product' 'Licence (apps)' $(if ($s.MultiSession -and @($s.Products | Where-Object { $_ -in $script:Products }).Count -eq 0) { 'red' } else { 'yellow' }) "Installed: $(if ($s.Products.Count) { & $names $s.Products } else { 'not readable' }). Configured: $(Get-AVDTuneOfficeLicenseName $Config.Product)." 'Multi-session supports only Microsoft 365 Apps for enterprise (E3/E5) or for business (Business Premium).' $script:Src.Avd $true) }
    if ($s.SharedLicensing) { & $add (New-AVDTuneOfficeRow 'office.shared' 'Shared Computer Activation' 'green' 'On (SharedComputerLicensing = 1).' '' $script:Src.Shared $true) }
    else { & $add (New-AVDTuneOfficeRow 'office.shared' 'Shared Computer Activation' 'red' 'Off. Every user would need an own activation on a multi-user host.' 'Sets SharedComputerLicensing = 1 (Learn, registry option; restart needed), or Install or reconfigure does it with the ODT.' $script:Src.Shared $true '' 'shared') }
    if ($s.UpdatesEnabled -eq $false) { & $add (New-AVDTuneOfficeRow 'office.updates' 'Automatic updates' 'green' ($(if ($null -ne $s.UpdatePolicy -and [string]$s.UpdatePolicy -eq '0') { 'Off (policy enableautomaticupdates = 0)' } else { 'Off (Updates Enabled = FALSE)' }) + ': updates come with the Updates page in maintenance mode or a new image.') '' $script:Src.Avd $true) }
    elseif ($s.UpdatesEnabled -eq $true) { & $add (New-AVDTuneOfficeRow 'office.updates' 'Automatic updates' 'red' $(if ($null -ne $s.UpdatePolicy -and [string]$s.UpdatePolicy -eq '1') { 'On: the policy enableautomaticupdates = 1 lets Office update itself while users work.' } else { 'On: Office would update itself while users work.' }) 'Sets the policy enableautomaticupdates = 0 (it wins over the ODT setting), or Install or reconfigure sets Updates Enabled = FALSE.' $script:Src.UpdateSettings $true 'The registry value name of the policy is from Microsoft KB 2753538; the Learn page names the Group Policy setting "Enable automatic updates".' 'updates') }
    else { & $add (New-AVDTuneOfficeRow 'office.updates' 'Automatic updates' 'info' 'Not readable.' '' $script:Src.Avd $true) }
    $wantL = @($Config.Languages | Where-Object { $_ -ne 'MatchOS' })
    if ($s.Languages.Count -eq 0) { & $add (New-AVDTuneOfficeRow 'office.languages' 'Languages' 'info' 'The installed languages could not be read (looked at ProductReleaseIDs\Active\<product>, ProductReleaseIDs\<product> and the uninstall entries "<product> - <culture>").' '' $script:Src.Options $false 'None of these registry places is documented on Learn; see docs\office.md.') }
    else {
        $miss = @($wantL | Where-Object { $_ -notin $s.Languages })
        if ($miss.Count -eq 0) { & $add (New-AVDTuneOfficeRow 'office.languages' 'Languages' 'green' "Installed: $($s.Languages -join ', ')." '' $script:Src.Options $false 'The registry places of the languages are not documented on Learn; see docs\office.md.') }
        else { & $add (New-AVDTuneOfficeRow 'office.languages' 'Languages' 'yellow' "Missing: $($miss -join ', '). Installed: $($s.Languages -join ', ')." 'Install or reconfigure adds the configured languages.' $script:Src.Options $false 'The registry places of the languages are not documented on Learn; see docs\office.md.') }
    }
    $p = $s.Policy
    if ([string]$p.hideupdatenotifications -eq '1' -and [string]$p.hideenabledisableupdates -eq '1') { & $add (New-AVDTuneOfficeRow 'office.updateui' 'Update notifications and the update button' 'green' 'Hidden for users (policy).' '' $script:Src.Avd $true) }
    else { & $add (New-AVDTuneOfficeRow 'office.updateui' 'Update notifications and the update button' 'yellow' 'Users still see the Office update notifications and the "Update options" button.' ($(if ([string]$p.hideupdatenotifications -ne '1') { 'Press "Set update policies" (hideupdatenotifications of the AVD article).' } else { '' }) + $(if ([string]$p.hideenabledisableupdates -ne '1') { ' Turn the update block on: it sets hideenabledisableupdates (one owner, #101).' } else { '' })) $script:Src.Avd $true) }
    & $add (New-AVDTuneOfficeRow 'office.multisession' 'Windows edition' 'info' $(if ($s.MultiSession) { 'Windows multi-session (EditionID ServerRdsh).' } else { 'Not Windows multi-session: the AVD article rules apply to multi-session hosts.' }) '' $script:Src.Avd $false 'ServerRdsh as the edition id of multi-session is from experience, not from Learn.')
    @($rows)
}

#endregion

#region the ODT package

function Get-AVDTuneOdtLink {
    <#
        Pure: the package link in the text of the Microsoft download page. Exactly one different link that is https, host download.microsoft.com, without
        port, user info or query, and a file name officedeploymenttool_<build>-<build>.exe. Returns @{ Ok; Url; FileName; Error }.
    #>
    param([string]$PageText)
    $none = { param($e) [pscustomobject]@{ Ok = $false; Url = ''; FileName = ''; Error = $e } }
    if (-not $PageText -or $PageText.Length -gt $script:MaxPageChars) { return & $none 'The download page is empty or too large.' }
    # The page can carry the link inside JSON, with escaped slashes (https:\/\/...) or /: unescape first, then the same strict rules apply to every candidate.
    $text = $PageText -replace '\\/', '/' -replace '(?i)\\u002f', '/'
    $found = @()
    try {
        $candidates = @([regex]::Matches($text, 'https://download\.microsoft\.com/[^\s"''<>\\]{1,300}', 'IgnoreCase', [TimeSpan]::FromSeconds(2)) | ForEach-Object { $_.Value })
        $found = @($candidates | Where-Object { [regex]::IsMatch($_, '\Ahttps://download\.microsoft\.com/download/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/officedeploymenttool_\d{4,6}-\d{4,6}\.exe\z', 'IgnoreCase', [TimeSpan]::FromSeconds(1)) } | Select-Object -Unique)
    }
    catch { return & $none 'The download page could not be searched.' }
    if ($found.Count -eq 0) { return & $none 'The download page names no Office Deployment Tool package.' }
    if ($found.Count -gt 1) { return & $none 'The download page names more than one package; it is not clear which is meant.' }
    $uri = $null
    if (-not [Uri]::TryCreate($found[0], [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -ne $script:OdtFileHost -or -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { return & $none 'The link does not point to download.microsoft.com over https.' }
    [pscustomobject]@{ Ok = $true; Url = $uri.AbsoluteUri; FileName = [IO.Path]::GetFileName($uri.AbsolutePath); Error = '' }
}

function Test-AVDTuneOdtFolderNames {
    # Pure: the unpacked ODT holds exactly setup.exe (once) and configuration-*.xml samples, nothing else (no extra program or DLL next to setup.exe)
    param([string[]]$Names)
    $n = @($Names)
    if (@($n | Where-Object { $_ -ceq 'setup.exe' }).Count -ne 1) { return $false }
    foreach ($x in $n) { if ($x -cne 'setup.exe' -and -not [regex]::IsMatch($x, '^configuration-[A-Za-z0-9._-]{1,80}\.xml\z', 'None', [TimeSpan]::FromMilliseconds(200))) { return $false } }
    $true
}

function Test-AVDTuneOdtPackageTrust {
    # The self-extracting package: signed by Microsoft (subject and issuer as for every Microsoft tool), the original file name is not checked exactly because it carries a build number
    param($Signature)
    Test-AVDTuneToolTrust -Signature $Signature -Name 'officedeploymenttool.exe' -OriginalFilenamePattern '^officedeploymenttool(_\d{4,6}-\d{4,6})?\.exe\z'
}

#endregion

#region install, reconfigure, remove

function Invoke-AVDTuneOfficeSetup {
    <#
        Mode Install (install or reconfigure with the saved configuration) or Remove. The ODT page -> link -> download into a new protected folder -> signature of
        the package -> extract -> signature of setup.exe by full path -> configuration.xml into the same folder -> signature again right before the start ->
        setup.exe /configure -> check the result in the registry. The folder is removed at the end. Never throws for expected problems.
        Returns @{ Status Changed|Unchanged|Failed; Message; Code; Before; After; Reboot; Xml }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$O, [Parameter(Mandatory)]$Config, [ValidateSet('Install', 'Remove')][string]$Mode = 'Install', [string]$Root = (Get-AVDTuneRoot), [scriptblock]$Progress)
    $say = { param($t) if ($Progress) { & $Progress $t } }
    $before = Get-AVDTuneOfficeInfo $Machine
    $out = { param($s, $msg, $code, $reboot, $xml) [pscustomobject]@{ Status = $s; Message = $msg; Code = $code; Before = $before; After = (Get-AVDTuneOfficeInfo $Machine); Reboot = [bool]$reboot; Xml = $xml } }
    if ($Mode -eq 'Remove' -and -not $before.Installed) { return & $out 'Unchanged' 'Microsoft 365 Apps is not installed.' '' $false '' }
    $xml = ''
    try {
        $problems = @(Test-AVDTuneOfficeConfig $Config)
        if ($Mode -eq 'Install' -and $problems.Count -gt 0) { return & $out 'Failed' "The configuration is not valid: $($problems -join ' ')" 'BadConfig' $false '' }
        $logPath = Join-Path $Root 'logs\office'
        $xml = New-AVDTuneOfficeXml -Config $(if ($Mode -eq 'Install') { $Config } else { Get-AVDTuneOfficeDefaults }) -Mode $Mode -LogPath $logPath
    }
    catch { return & $out 'Failed' $_.Exception.Message 'BadConfig' $false '' }
    $dir = $null
    try {
        & $say 'Looking up the Office Deployment Tool ...'
        $page = & $O.OdtPage
        if (-not $page.Ok) { return & $out 'Failed' "The download page could not be read: $($page.Error)" 'NoPage' $false $xml }
        $link = Get-AVDTuneOdtLink -PageText ([string]$page.Text)
        if (-not $link.Ok) { return & $out 'Failed' $link.Error 'NoLink' $false $xml }
        $dir = & $O.NewTempFolder $Root
        if (-not $dir -or -not (& $O.IsProtectedFolder $dir $Root)) { return & $out 'Failed' 'The download folder is not protected (Administrators and SYSTEM only): nothing was downloaded.' 'NotProtected' $false $xml }
        & $say "Downloading $($link.FileName) ..."
        $pkg = Join-Path $dir 'odt-package.exe'
        $dl = & $O.Download $link.Url $pkg $script:MaxOdtBytes
        if (-not $dl.Ok) { return & $out 'Failed' "The download failed: $($dl.Error)" 'Download' $false $xml }
        $trust = Test-AVDTuneOdtPackageTrust -Signature (& $O.VerifySignature $pkg)
        if (-not $trust.Ok) { return & $out 'Failed' "$($trust.Reason): it is not started." 'BadSignature' $false $xml }
        & $say 'Unpacking the Office Deployment Tool ...'
        $ex = & $O.Run $pkg @('/quiet', "/extract:$(Join-Path $dir 'odt')") 300
        if ($ex.ExitCode -ne 0) { return & $out 'Failed' "The package could not be unpacked (exit code $($ex.ExitCode))." 'Unpack' $false $xml }
        $odtDir = Join-Path $dir 'odt'
        if (-not (& $O.IsProtectedFolder $odtDir $Root)) { return & $out 'Failed' 'The folder the package was unpacked into is not protected (Administrators and SYSTEM only): setup.exe is not started.' 'NotProtected' $false $xml }
        $setup = & $O.FindSetup $odtDir
        if (-not $setup) { return & $out 'Failed' 'setup.exe is not in the package.' 'NoSetup' $false $xml }
        # setup.exe is held open (read share only) from the first check until its process has ended: nobody can write to it, delete it or rename it in between
        try { $hold = & $O.HoldFile $setup } catch { return & $out 'Failed' "setup.exe cannot be held for the check: $($_.Exception.Message)" 'NoSetup' $false $xml }
        try {
            $names = @(& $O.ListFolder $odtDir)
            if (-not (Test-AVDTuneOdtFolderNames $names)) { return & $out 'Failed' "The unpacked folder holds more than setup.exe and configuration-*.xml ($($names -join ', ')): setup.exe is not started." 'BadContents' $false $xml }
            $trust = Test-AVDTuneToolTrust -Signature (& $O.VerifySignature $setup) -Name 'odt-setup'
            if (-not $trust.Ok) { return & $out 'Failed' "$($trust.Reason): it is not started." 'BadSignature' $false $xml }
            $cfg = Join-Path $dir 'configuration.xml'
            & $O.WriteText $cfg $xml
            & $say $(if ($Mode -eq 'Remove') { 'Removing Microsoft 365 Apps (this takes a few minutes) ...' } else { 'Installing Microsoft 365 Apps (this takes a while) ...' })
            $trust = Test-AVDTuneToolTrust -Signature (& $O.VerifySignature $setup) -Name 'odt-setup'   # again, right before the start
            if (-not $trust.Ok) { return & $out 'Failed' "$($trust.Reason): it is not started." 'BadSignature' $false $xml }
            $r = & $O.Run $setup @('/configure', $cfg) 3600
        }
        finally { if ($hold) { $hold.Dispose() } }
        $reboot = $r.ExitCode -in 3010, 1641
        if ($r.ExitCode -notin 0, 3010, 1641) { return & $out 'Failed' "setup.exe returned $($r.ExitCode). Look at the logs in $(Join-Path $Root 'logs\office')." "Exit$($r.ExitCode)" $false $xml }
        $after = Get-AVDTuneOfficeInfo $Machine
        if ($Mode -eq 'Remove') {
            if ($after.Installed) { return & $out 'Failed' 'setup.exe finished but Microsoft 365 Apps is still registered.' 'StillInstalled' $reboot $xml }
            return & $out 'Changed' "Removed (was $($before.Build))." '' $reboot $xml
        }
        if (-not $after.Installed) { return & $out 'Failed' 'setup.exe finished but Microsoft 365 Apps is not registered.' 'NotRegistered' $reboot $xml }
        if (-not $after.SharedLicensing) { return & $out 'Failed' 'Installed, but Shared Computer Activation is not on (SharedComputerLicensing is not 1).' 'NoShared' $reboot $xml }
        $msg = if ($before.Installed) { "Reconfigured: $($before.Build) -> $($after.Build), $($after.Channel)." } else { "Installed $($after.Build), $($after.Channel), $($after.Platform)." }
        & $out 'Changed' $msg '' $reboot $xml
    }
    catch { & $out 'Failed' $_.Exception.Message 'Error' $false $xml }
    finally { if ($dir) { try { & $O.RemoveFolder $dir } catch { } } }
}

function Get-AVDTuneOfficeUndoPath([string]$Root) { Join-Path $Root 'config\office-undo.json' }
function Get-AVDTuneOfficeAppliedPath([string]$Root) { Join-Path $Root 'config\office-applied.json' }

function Invoke-AVDTuneOfficeRecorded {
    <#
        Install/reconfigure or remove behind the write gate with run record (Plan 'Office install' / 'Office remove'), LastChange (also on failure) and a change
        log entry. Before the first change the state found is kept for Undo (never overwritten). Returns @{ Result; Setup; Run }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$O, [string]$Root = (Get-AVDTuneRoot), [ValidateSet('Install', 'Remove')][string]$Mode = 'Install', $Config, [string]$User, [string]$SnapshotId, [scriptblock]$Progress, [string]$PlanName)
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot newer than its last change is confirmed on the Overview.' }
    if (-not $Config) { $Config = Get-AVDTuneOfficeConfig -Root $Root }
    $started = & $Machine.Now
    $pre = Get-AVDTuneOfficeInfo $Machine
    # the early analysis exits of the setup (nothing to remove, configuration not valid) change nothing: no LastChange, no undo record for them
    $analysisExit = ($Mode -eq 'Remove' -and -not $pre.Installed) -or ($Mode -eq 'Install' -and @(Test-AVDTuneOfficeConfig $Config).Count -gt 0)
    $createdUndo = $false
    # marker while the master is written (snapshot gate, #27/#81): set before the first write, cleared in finally (Stop stamps LastChange, also after an abort)
    $changeOwner = $false; if (-not $analysisExit) { $changeOwner = Start-AVDTuneChange -Root $Root }
    try {
    if (-not $analysisExit) {
        [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = $started.ToString('o') })
        if (-not (Test-Path -LiteralPath (Get-AVDTuneOfficeUndoPath $Root))) {
            $prev = Read-AVDTuneJson (Get-AVDTuneOfficeAppliedPath $Root)
            Write-AVDTuneFile (Get-AVDTuneOfficeUndoPath $Root) ([ordered]@{ At = $started.ToString('o'); BeforeInstalled = [bool]$pre.Installed; BeforeBuild = [string]$pre.Build; PreviousConfig = $prev } | ConvertTo-Json -Depth 6)
            $createdUndo = $true
        }
    }
    $r = Invoke-AVDTuneOfficeSetup -Machine $Machine -O $O -Config $Config -Mode $Mode -Root $Root -Progress $Progress
    if ($r.Status -eq 'Changed' -and $Mode -eq 'Install') { Write-AVDTuneFile (Get-AVDTuneOfficeAppliedPath $Root) ((ConvertTo-AVDTuneOfficeConfig $Config) | ConvertTo-Json -Depth 4) }
    if ($r.Status -eq 'Changed' -and $Mode -eq 'Remove') { Remove-Item -LiteralPath (Get-AVDTuneOfficeAppliedPath $Root) -Force -ErrorAction SilentlyContinue }
    $noEffect = ($r.Status -eq 'Unchanged') -or ($r.Status -eq 'Failed' -and $r.Code -cin 'NoPage', 'NoLink', 'Download', 'BadSignature', 'NotProtected', 'Unpack', 'NoSetup', 'BadContents')
    if ($noEffect -and $createdUndo) { Remove-Item -LiteralPath (Get-AVDTuneOfficeUndoPath $Root) -Force -ErrorAction SilentlyContinue }   # only the record this call wrote: an older one is the way back
    $id = if ($Mode -eq 'Remove') { 'office.remove' } else { 'office.install' }
    $title = if ($PlanName) { $PlanName } elseif ($Mode -eq 'Remove') { 'Microsoft 365 Apps removal' } else { 'Microsoft 365 Apps' }
    $res = [pscustomobject][ordered]@{ Id = $id; Section = 'Office'; Title = $title; Mode = 'Apply'; Status = $r.Status; Before = $pre.Build; After = $r.After.Build; Message = $r.Message; Reboot = ([bool]$r.Reboot -and $r.Status -eq 'Changed'); WhatIf = $false; At = $started.ToString('o'); Code = $r.Code }
    $state = Get-AVDTuneState $Root
    $run = [pscustomobject][ordered]@{ Id = $null; Plan = $(if ($Mode -eq 'Remove') { 'Office remove' } else { 'Office install' }); Started = $started.ToString('o'); Ended = (& $Machine.Now).ToString('o'); User = $User; SnapshotId = $SnapshotId; WhatIf = $false; ImageVersion = $state.ImageVersion; Reboot = $res.Reboot; Results = @($res) }
    [void](Add-AVDTuneRun -Root $Root -Run $run)
    if ($r.Status -eq 'Changed' -or ($r.Status -eq 'Failed' -and -not $analysisExit)) { [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = (& $Machine.Now).ToString('o') }) }
    if ($state.ImageVersion -and $r.Status -in 'Changed', 'Failed') {
        $c = $null; if ($Mode -eq 'Install' -and @(Test-AVDTuneOfficeConfig $Config).Count -eq 0) { $c = ConvertTo-AVDTuneOfficeConfig $Config }
        $detail = if ($c) { " [$($c.Channel), $($c.Edition) bit, $($c.Product), Outlook $($c.Outlook), languages $($c.Languages -join '/'), excluded $(if ($c.ExcludeApps.Count) { $c.ExcludeApps -join '/' } else { 'none' })]" } else { '' }
        $text = if ($r.Status -eq 'Changed') { "Microsoft 365 Apps: $($r.Message)$detail" } else { "Microsoft 365 Apps: $Mode FAILED ($($r.Code)) - $($r.Message)" }
        $type = if ($r.Status -ne 'Changed') { 'Note' } elseif ($Mode -eq 'Remove') { 'Removed' } elseif ($pre.Installed) { 'Changed' } else { 'Added' }
        [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'Office' -Component 'Microsoft 365 Apps' -ChangeType $type -Text $text -User $User -SnapshotId $SnapshotId -RunId ([string]$run.Id) -Source Step)
    }
    # the ODT now decides the Office values: the undo records of the one-click fixes describe a state that is gone (an Undo would put back an outdated value)
    $discarded = @(); if ($r.Status -eq 'Changed' -and $Mode -eq 'Install') { $discarded = @(Remove-AVDTuneOfficeFixRecords -Root $Root -User $User -SnapshotId $SnapshotId -RunId ([string]$run.Id) -Why 'Office was installed or reconfigured afterwards, the earlier value is outdated.') }
    [pscustomobject]@{ Result = $res; Setup = $r; Run = $run; FixRecordsDiscarded = $discarded }
    }
    finally { Stop-AVDTuneChange -Root $Root -Owner $changeOwner }
}

function Get-AVDTuneOfficeRemoveText {
    <# The confirmation text of Remove: <Remove All="TRUE"/> takes every Click-to-Run product off the master, so it names all of them (ProductReleaseIds) and what Undo can not do. #>
    param([Parameter(Mandatory)]$Machine)
    $s = Get-AVDTuneOfficeState $Machine
    $what = if ($s.Products.Count -gt 0) { $s.Products -join ', ' } else { 'all Click-to-Run products (the list could not be read)' }
    "Remove ALL Microsoft 365 / Office Click-to-Run products from this master? Found: $what. Every Click-to-Run product is removed, not only the one of the form. $(Get-AVDTuneOfficeUndoLimits)"
}

function Get-AVDTuneOfficeUndoLimits {
    'Undo only goes back to the configuration (product, channel, bit) that AVDTune saved before its first change and installs it again: the build is then the current one of the channel, not the earlier build; languages that were installed but are not in the saved configuration, and Office versions that RemoveMSI removed, do not come back.'
}

function Get-AVDTuneOfficeUndoText {
    param([string]$Root = (Get-AVDTuneRoot))
    $u = Read-AVDTuneJson (Get-AVDTuneOfficeUndoPath $Root)
    $b = if ($u) { Get-AVDTuneProp $u 'BeforeInstalled' } else { $null }
    $goal = if ($b -is [bool] -and -not $b) { 'Microsoft 365 Apps is removed again (it was not there before)' } elseif ($b -is [bool]) { 'Microsoft 365 Apps is installed again with the saved earlier configuration' } else { 'There is no usable record of the state before the first change' }
    "Reinstall or remove to the saved earlier configuration: $goal. $(Get-AVDTuneOfficeUndoLimits)"
}

function Get-AVDTuneOfficeUndoDrift {
    <# $null when Office is as AVDTune left it (or not installed); otherwise a text: Office is installed differently now (other product, channel or bit than AVDTune applied, or not installed by AVDTune), so Undo would remove or replace something else. #>
    param([Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot))
    $s = Get-AVDTuneOfficeState $Machine
    if (-not $s.Installed) { return $null }
    $a = ConvertFrom-AVDTuneOfficeStored (Read-AVDTuneJson (Get-AVDTuneOfficeAppliedPath $Root))
    $ok = $false
    if ($a -and @(Test-AVDTuneOfficeConfig $a).Count -eq 0) {
        $ok = ($a.Product -cin $s.Products) -and $s.ChannelKey -ceq $a.Channel -and $s.Platform -ceq $(if ($a.Edition -ceq '64') { 'x64' } else { 'x86' })
    }
    if ($ok) { return $null }
    "Office is installed differently now than AVDTune left it (found: $(if ($s.Products.Count) { $s.Products -join ', ' } else { 'unknown product' }), $($s.Channel), $($s.Platform), build $($s.Build)). Undo would replace or remove that installation."
}

function Invoke-AVDTuneOfficeUndo {
    <# Back to the state found before the first change: remove when Office was not there; the earlier configuration when it is known; otherwise no undo (the record says why). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$O, [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId, [scriptblock]$Progress, [switch]$AcceptDrift)
    $u = Read-AVDTuneJson (Get-AVDTuneOfficeUndoPath $Root)
    if (-not $u) { throw 'There is nothing to undo: no Office change was recorded.' }
    $beforeInstalled = Get-AVDTuneProp $u 'BeforeInstalled'
    if ($beforeInstalled -isnot [bool]) { throw 'The undo record of Office (config\office-undo.json) is not usable: BeforeInstalled must be true or false. Nothing was changed.' }
    if (-not $AcceptDrift) { $drift = Get-AVDTuneOfficeUndoDrift -Machine $Machine -Root $Root; if ($drift) { throw "OFFICE-DRIFT: $drift Confirm it to go on. Nothing was changed." } }
    $run = $null
    if (-not $beforeInstalled) { $run = Invoke-AVDTuneOfficeRecorded -Machine $Machine -O $O -Root $Root -Mode Remove -User $User -SnapshotId $SnapshotId -Progress $Progress -PlanName 'Undo: Microsoft 365 Apps' }
    else {
        $prev = ConvertFrom-AVDTuneOfficeStored (Get-AVDTuneProp $u 'PreviousConfig')
        if ($null -eq $prev -or @(Test-AVDTuneOfficeConfig $prev).Count -gt 0) { throw 'There is no undo: Office was there before AVDTune changed it and the earlier configuration is not known. Set the earlier values in the form and press Install or reconfigure.' }
        $run = Invoke-AVDTuneOfficeRecorded -Machine $Machine -O $O -Root $Root -Mode Install -Config (ConvertTo-AVDTuneOfficeConfig $prev) -User $User -SnapshotId $SnapshotId -Progress $Progress -PlanName 'Undo: Microsoft 365 Apps'
    }
    if ($run.Setup.Status -in 'Changed', 'Unchanged') { Remove-Item -LiteralPath (Get-AVDTuneOfficeUndoPath $Root) -Force -ErrorAction SilentlyContinue }   # the undo itself worked (Unchanged: Office was already gone)
    $run
}

#endregion

#region update UI policies (registry steps)

# The values the Office page owns (audit #101): hideenabledisableupdates belongs to the update block (updateblock.office-hide), which sets it in its end state; two owners undid each other.
$script:PolicyNames = @('hideupdatenotifications')

function Get-AVDTuneOfficePolicySteps {
    # The HKLM value of the AVD article that the Office page owns (hideupdatenotifications; the update button value is the update block's, #101); steps with Test/Apply/Undo
    # (Undo puts back what was found, with its registry type). $Previous: name -> @{ Value; Type } (Type DWord, QWord or String). -Names: only these (the undo of what was changed).
    param([hashtable]$Previous = @{}, [string[]]$Names = $script:PolicyNames)
    foreach ($n in @($script:PolicyNames | Where-Object { $_ -in $Names })) {
        $name = $n; $prev = $Previous[$name]; $key = $script:PolicyKey; $src = $script:Src.Avd   # $script: does not resolve inside a closure
        $test = { param($m) $v = & $m.RegGet $key $name; @{ Compliant = ($null -ne $v -and [string]$v -eq '1'); State = $v } }.GetNewClosure()
        $apply = { param($m) & $m.RegSet $key $name 1 'DWord' }.GetNewClosure()
        $undo = { param($m) if ($null -ne $prev) { & $m.RegSet $key $name $prev.Value $prev.Type } else { & $m.RegRemove $key $name } }.GetNewClosure()
        New-AVDTuneStep -Id "office.policy.$name" -Section Office -Title "Office policy $name = 1" -Why 'Users must not start Office updates on a multi-user host (AVD article).' -SourceUrl $src -Test $test -Apply $apply -Undo $undo
    }
}

function Get-AVDTunePolicyRegType($Value) {
    # Fallback when the adapter has no RegGetRaw: the registry type from the .NET value. UInt32 is a DWord (stored as the Int32 with the same bits).
    if ($Value -is [int] -or $Value -is [uint32]) { return 'DWord' }
    if ($Value -is [long]) { return 'QWord' }
    if ($Value -is [string]) { return 'String' }
    throw "The earlier value has a type ($($Value.GetType().Name)) that AVDTune cannot put back; nothing was changed."
}

function ConvertTo-AVDTunePolicyDword($Value) {
    # Int32 with the bits of a DWord: 4294967295 (or a UInt32) becomes -1
    $l = [int64]$Value
    if ($l -gt [int]::MaxValue) { $l -= 4294967296 }
    [int]$l
}

function Get-AVDTunePolicyPrevious {
    # @{ Value; Type } of the value as stored (kind from GetValueKind, REG_EXPAND_SZ not expanded), $null when absent
    param($Machine, [string]$Name, [string]$Key = $script:PolicyKey)
    $raw = $null
    if ($Machine.PSObject.Properties['RegGetRaw'] -and $Machine.RegGetRaw) { $raw = & $Machine.RegGetRaw $Key $Name }
    if ($raw) {
        $kind = [string]$raw.Kind
        if ($kind -cnotin 'DWord', 'QWord', 'String', 'ExpandString') { throw "The earlier value of $Name has the registry type $kind, which AVDTune cannot put back; nothing was changed." }
        $v = $raw.Value; if ($kind -ceq 'DWord') { $v = ConvertTo-AVDTunePolicyDword $v }
        return @{ Value = $v; Type = $kind }
    }
    $v = & $Machine.RegGet $Key $Name
    if ($null -eq $v) { return $null }
    $type = Get-AVDTunePolicyRegType $v
    if ($type -ceq 'DWord') { $v = ConvertTo-AVDTunePolicyDword $v }
    @{ Value = $v; Type = $type }
}
function Read-AVDTuneOfficePolicyUndo {
    <# config\office-policies-undo.json typed: Names (what the Office page changed) and Previous (name -> @{ Value; Type }). Missing file: empty. An older record without Names names every value in it and every value that was absent (#101). #>
    param([Parameter(Mandatory)][string]$Root)
    $u = Read-AVDTuneJson (Join-Path $Root 'config\office-policies-undo.json')
    if (-not $u) { return [pscustomobject]@{ Names = @(); Previous = @{} } }
    # typed read: a record that is not exactly what Set wrote changes nothing ("1" is not 1, an unknown type is not put back)
    $prev = @{}; $pp = Get-AVDTuneProp $u 'Previous'
    if ($null -ne $pp) {
        if ($pp -isnot [System.Management.Automation.PSCustomObject]) { throw 'The undo record of the Office policies (config\office-policies-undo.json) is not usable. Nothing was changed.' }
        foreach ($p in $pp.PSObject.Properties) {
            $e = $p.Value; $type = Get-AVDTuneProp $e 'Type'; $val = Get-AVDTuneProp $e 'Value'
            $ok = ($p.Name -cin 'hideupdatenotifications', 'hideenabledisableupdates') -and $type -is [string] -and (
                ($type -ceq 'DWord' -and ($val -is [int] -or ($val -is [long] -and $val -ge [int]::MinValue -and $val -le [uint32]::MaxValue))) -or
                ($type -ceq 'QWord' -and ($val -is [int] -or $val -is [long])) -or ($type -cin 'String', 'ExpandString' -and $val -is [string]))
            if (-not $ok) { throw "The undo record of the Office policies (config\office-policies-undo.json) is not usable: '$($p.Name)' has no typed value. Nothing was changed." }
            if ($type -ceq 'DWord') { $val = ConvertTo-AVDTunePolicyDword $val }
            $prev[$p.Name] = @{ Value = $val; Type = $type }
        }
    }
    $nm = Get-AVDTuneProp $u 'Names'
    if ($null -eq $nm) { $names = @('hideupdatenotifications', 'hideenabledisableupdates') }
    else { $names = @(foreach ($x in @($nm)) { if ($x -isnot [string] -or $x -cnotin 'hideupdatenotifications', 'hideenabledisableupdates') { throw 'The undo record of the Office policies (config\office-policies-undo.json) names an unknown value. Nothing was changed.' }; $x }) }
    [pscustomobject]@{ Names = @($names); Previous = $prev }
}
function Set-AVDTuneOfficePolicies {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    $prev = @{}; foreach ($n in $script:PolicyNames) { $p = Get-AVDTunePolicyPrevious -Machine $Machine -Name $n; if ($null -ne $p) { $prev[$n] = $p } }
    $undoPath = Join-Path $Root 'config\office-policies-undo.json'
    if (-not $WhatIf -and (Test-AVDTuneWriteAllowed)) {
        Assert-AVDTuneNotSealed -Root $Root
        # #101: recorded only for the values that change (already 1 is nothing to put back), the first value found per name stays
        $old = Read-AVDTuneOfficePolicyUndo -Root $Root
        $names = @(@($old.Names) | Where-Object { $_ }); $keep = $old.Previous
        foreach ($n in $script:PolicyNames) {
            if ($n -in $names) { continue }
            $c = $prev[$n]; if ($c -and [string]$c.Type -ceq 'DWord' -and [int]$c.Value -eq 1) { continue }
            $names += $n; if ($null -ne $c) { $keep[$n] = $c }
        }
        if ($names.Count -gt @($old.Names).Count) { Write-AVDTuneFile $undoPath ([ordered]@{ At = (& $Machine.Now).ToString('o'); Names = @($names); Previous = $keep } | ConvertTo-Json -Depth 4) }
    }
    $steps = @(Get-AVDTuneOfficePolicySteps -Previous $prev)
    Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'Office policies'; Steps = @($steps | ForEach-Object { $_.Id }) }) -Catalog $steps -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf
}

function Undo-AVDTuneOfficePolicies {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    $undoPath = Join-Path $Root 'config\office-policies-undo.json'
    if (-not (Test-Path -LiteralPath $undoPath)) { throw 'There is nothing to undo: no Office policy change was recorded.' }
    $rec = Read-AVDTuneOfficePolicyUndo -Root $Root
    $prev = $rec.Previous
    # #101: only what the Office page changed; a value that was already 1 is done (an older record without Names: every owned name whose value was not 1)
    $names = @(@($rec.Names) | Where-Object { $_ -in $script:PolicyNames -and -not ($prev[$_] -and [string]$prev[$_].Type -ceq 'DWord' -and [int]$prev[$_].Value -eq 1) })
    $changeOwner = $false
    if (-not $WhatIf) {
        if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot newer than its last change is confirmed on the Overview.' }
        $changeOwner = Start-AVDTuneChange -Root $Root   # marker while the master is written (snapshot gate, #27)
    }
    try {
        if (-not $WhatIf) { [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = (& $Machine.Now).ToString('o') }) }   # before the attempt: a failed undo may have changed the master
        $steps = @(Get-AVDTuneOfficePolicySteps -Previous $prev -Names $names)   # Mode Undo of a step puts back the value found before
        $results = foreach ($s in $steps) { Invoke-AVDTuneStep -Step $s -Machine $Machine -Mode Undo -WhatIf:$WhatIf }
        $run = [pscustomobject]@{ Plan = 'Office policies undo'; WhatIf = [bool]$WhatIf; Results = @($results) }
        if (-not $WhatIf) {
            $state = Get-AVDTuneState $Root
            $ended = (& $Machine.Now).ToString('o')
            [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = $ended })   # also when a step failed
            $saved = [pscustomobject][ordered]@{ Id = $null; Plan = 'Office policies undo'; Started = $ended; Ended = $ended; User = $User; SnapshotId = $SnapshotId; WhatIf = $false; ImageVersion = $state.ImageVersion; Reboot = $false; Results = @($results) }
            [void](Add-AVDTuneRun -Root $Root -Run $saved)
            foreach ($r in @($results | Where-Object { $_.Status -eq 'Reverted' })) {
                if ($state.ImageVersion) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'Office' -Component $r.Id -ChangeType Changed -Text "Undo: $($r.Title)" -User $User -SnapshotId $SnapshotId -RunId ([string]$saved.Id) -Source Step) }
            }
            if (@($results | Where-Object { $_.Status -eq 'Failed' }).Count -eq 0) { Remove-Item -LiteralPath $undoPath -Force -ErrorAction SilentlyContinue }
        }
        $run
    }
    finally { Stop-AVDTuneChange -Root $Root -Owner $changeOwner }
}

#endregion

#region one-click fixes (issue 61)

# The two red rows of the page that can be fixed with one registry value (Test/Apply/Undo through the write gate; no ODT run):
#   shared  = Shared Computer Activation: String SharedComputerLicensing = "1" under HKLM\SOFTWARE\Microsoft\Office\ClickToRun\Configuration (Learn, shared computer activation, option 2 "Registry Editor"; restart needed)
#   updates = Automatic updates off: DWord enableautomaticupdates = 0 under the officeupdate policy key (Group Policy "Enable automatic updates"; the value name is from Microsoft KB 2753538; Learn: Group Policy wins over the ODT)
function Get-AVDTuneOfficeFixDefs {
    [ordered]@{
        shared = @{ Id = 'office.fix.shared'; Key = "$script:ClickToRun\Configuration"; Name = 'SharedComputerLicensing'; Value = '1'; Type = 'String'; Title = 'Office shared computer activation on (SharedComputerLicensing = 1)'; Why = 'Several users share this host: every user needs an own activation token (Learn, shared computer activation).'; Reboot = $true; Source = $script:Src.Shared }
        updates = @{ Id = 'office.fix.updates'; Key = $script:PolicyKey; Name = 'enableautomaticupdates'; Value = 0; Type = 'DWord'; Title = 'Office automatic updates off (policy enableautomaticupdates = 0)'; Why = 'Office must not update itself while users work; updates come with the image (AVD article).'; Reboot = $false; Source = $script:Src.UpdateSettings }
    }
}
function Get-AVDTuneOfficeFixNames { @((Get-AVDTuneOfficeFixDefs).Keys) }
function Get-AVDTuneOfficeFixUndoPath([string]$Root, [string]$Name) {
    if ($Name -cnotin @(Get-AVDTuneOfficeFixNames)) { throw "'$Name' is not a fix of the Office page." }
    Join-Path $Root "config\office-fix-$Name-undo.json"
}

function Get-AVDTuneOfficeFixRecorded {
    # The fixes that have an undo record (applied by AVDTune and not undone yet)
    param([string]$Root = (Get-AVDTuneRoot))
    @(Get-AVDTuneOfficeFixNames | Where-Object { Test-Path -LiteralPath (Get-AVDTuneOfficeFixUndoPath $Root $_) })
}

function Get-AVDTuneOfficeOutlookHint {
    # Shown on the page and kept in docs\office.md (sources: Learn, deployment of new Outlook, new Outlook on VDI)
    "Microsoft recommends running classic and new Outlook side by side; new deployments of Microsoft 365 Apps include both since version 2502. Features such as .pst files, mail merge in Word, people cards and Share to Windows still rely on classic Outlook. New Outlook on AVD needs Windows App 2.0.285.0 or newer, WebView2 and .NET Framework 4.7.2; it is a per-user package whose data FSLogix can roam. Whether the ODT provides new Outlook to every user of a multi-session host is not verified: try it on the test VM."
}

function Get-AVDTuneOfficeAppsHint {
    'OneDrive and Teams are never installed by this run: they come as their own VDI packages (issue 56). Groove is the old OneDrive sync client, Lync is Skype for Business (not supported on Azure Virtual Desktop). Microsoft is retiring Publisher. Access, Publisher, Groove, Lync and Bing are not installed by default.'
}

function Get-AVDTuneOfficeFixStep {
    # The step of a fix. $Previous: @{ Value; Type } found before (Undo puts it back with its registry type), $null = the value was absent (Undo removes it).
    param([Parameter(Mandatory)][string]$Name, $Previous)
    if ($Name -cnotin @(Get-AVDTuneOfficeFixNames)) { throw "'$Name' is not a fix of the Office page." }
    $d = (Get-AVDTuneOfficeFixDefs)[$Name]
    $key = $d.Key; $vname = $d.Name; $want = $d.Value; $type = $d.Type; $prev = $Previous
    $test = { param($m) $v = & $m.RegGet $key $vname; @{ Compliant = ($null -ne $v -and [string]$v -eq [string]$want); State = $v } }.GetNewClosure()
    $apply = { param($m) & $m.RegSet $key $vname $want $type }.GetNewClosure()
    $undo = { param($m) if ($null -ne $prev) { & $m.RegSet $key $vname $prev.Value $prev.Type } else { & $m.RegRemove $key $vname } }.GetNewClosure()
    New-AVDTuneStep -Id $d.Id -Section Office -Title $d.Title -Why $d.Why -Reboot $d.Reboot -SourceUrl $d.Source -Test $test -Apply $apply -Undo $undo
}

function Get-AVDTuneOfficeFixText {
    # The confirmation before the write: what is set, where, and what Undo can not do
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -cnotin @(Get-AVDTuneOfficeFixNames)) { throw "'$Name' is not a fix of the Office page." }
    $d = (Get-AVDTuneOfficeFixDefs)[$Name]
    $reg = $d.Key.Replace('HKLM:', 'HKLM')
    $extra = if ($Name -ceq 'shared') { ' Microsoft says the device must be restarted for it, and activations that users made before need a reset (Learn, reset activation).' } else { ' The setting wins over the Updates Enabled value of the ODT.' }
    "Set $($d.Name) = $($d.Value) ($($d.Type)) in $reg ?$extra The earlier value is kept and Undo puts it back; Undo does not restart the master and does not restore reset activations."
}

function Test-AVDTuneOfficeFixPrevious {
    # The typed undo record of a fix: $null (value was absent) or @{ Value; Type }; anything else is refused (a "1" string is not a DWord 1, an unknown type is not put back)
    param($Entry, [string]$Name)
    if ($null -eq $Entry) { return $null }
    if ($Entry -isnot [System.Management.Automation.PSCustomObject]) { throw "The undo record of the Office fix $Name is not usable. Nothing was changed." }
    $type = Get-AVDTuneProp $Entry 'Type'; $val = Get-AVDTuneProp $Entry 'Value'
    $ok = $type -is [string] -and (
        ($type -ceq 'DWord' -and ($val -is [int] -or ($val -is [long] -and $val -ge [int]::MinValue -and $val -le [uint32]::MaxValue))) -or
        ($type -ceq 'QWord' -and ($val -is [int] -or $val -is [long])) -or ($type -cin 'String', 'ExpandString' -and $val -is [string]))
    if (-not $ok) { throw "The undo record of the Office fix $Name is not usable: it has no typed earlier value. Nothing was changed." }
    # only the registry type the value of this fix has (updates: DWord, shared: String); key and name always come from the fix, never from the record
    if ($Name -cin @(Get-AVDTuneOfficeFixNames) -and $type -cne (Get-AVDTuneOfficeFixDefs)[$Name].Type) { throw "The undo record of the Office fix $Name is not usable: the earlier value has the type $type, the value of this fix is $((Get-AVDTuneOfficeFixDefs)[$Name].Type). Nothing was changed." }
    if ($type -ceq 'DWord') { $val = ConvertTo-AVDTunePolicyDword $val }
    @{ Value = $val; Type = $type }
}

function Test-AVDTuneOfficeUpdateBlockOwns {
    # $true when the update block (On or Partial, by settings other than the fix's own value) or a maintenance mode holds the value of the "updates" fix (officeupdate policy enableautomaticupdates): Undo of the fix must not touch it
    param([Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot))
    $mr = Get-AVDTuneProp (Get-AVDTuneState $Root) 'Maintenance'
    if ($mr -and (Get-AVDTuneProp $mr 'Active')) { return $true }
    # The block is On or Partial when any of its settings is in place. The fix itself sets the block's own Office item (updateblock.office-auto), so that item alone does not count: right after the fix the block reads Partial.
    if ((Get-AVDTuneProp (Get-AVDTuneState $Root) 'UpdateBlock') -cin 'On', 'Partial', 'Maintenance') { return $true }   # the block was switched on (also when some of its settings failed): the value is its, not the fix's
    $st = Get-AVDTuneUpdateBlockStatus $Machine
    @($st.Items | Where-Object { $_.Applicable -and $_.Compliant -and $_.Id -cne 'updateblock.office-auto' }).Count -gt 0
}

function Remove-AVDTuneOfficeFixRecords {
    # Discards the fix records (after an install or reconfigure the state of the registry is the ODT's, not the one the records describe); one change log entry names them. Returns the names.
    param([string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId, [string]$RunId, [string]$Why)
    $names = @(Get-AVDTuneOfficeFixRecorded -Root $Root)
    foreach ($n in $names) { Remove-Item -LiteralPath (Get-AVDTuneOfficeFixUndoPath $Root $n) -Force -ErrorAction SilentlyContinue }
    $state = Get-AVDTuneState $Root
    if ($names.Count -gt 0 -and $state.ImageVersion) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'Office' -Component 'office.fix' -ChangeType Note -Text "Undo record of the one-click fix(es) $($names -join ', ') discarded: $Why" -User $User -SnapshotId $SnapshotId -RunId $RunId -Source Step) }
    $names
}

function Set-AVDTuneOfficeFix {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)][string]$Name, [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    $undoPath = Get-AVDTuneOfficeFixUndoPath $Root $Name   # also refuses a name that is not a fix
    $d = (Get-AVDTuneOfficeFixDefs)[$Name]
    $prev = Get-AVDTunePolicyPrevious -Machine $Machine -Name $d.Name -Key $d.Key
    $step = Get-AVDTuneOfficeFixStep -Name $Name -Previous $prev
    $already = [bool](& $step.Test $Machine).Compliant
    # an earlier value of another registry type than this fix writes could not be put back by Undo: refuse before anything is changed
    if (-not $already -and $null -ne $prev -and $prev.Type -cne $d.Type) { throw "The earlier value of $($d.Name) has the registry type $($prev.Type), the fix writes $($d.Type) and Undo would not put it back. Nothing was changed." }
    # the record of the earlier value is written once and never overwritten (an older record is the way back); nothing is written when there is nothing to change
    $created = $false
    if (-not $WhatIf -and -not $already -and (Test-AVDTuneWriteAllowed) -and -not (Test-Path -LiteralPath $undoPath)) { Assert-AVDTuneNotSealed -Root $Root; Write-AVDTuneFile $undoPath ([ordered]@{ At = (& $Machine.Now).ToString('o'); Previous = $prev } | ConvertTo-Json -Depth 4); $created = $true }
    $run = $null
    try { $run = Invoke-AVDTune -Plan ([pscustomobject]@{ Name = "Office fix: $Name"; Steps = @($step.Id) }) -Catalog @($step) -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf }
    finally {
        # a record this call wrote goes again when the run threw or changed nothing (an older record is the way back and stays); a Failed step keeps it: the master may have changed
        if ($created -and (-not $run -or @($run.Results | Where-Object { $_.Status -in 'Changed', 'Failed' }).Count -eq 0)) { Remove-Item -LiteralPath $undoPath -Force -ErrorAction SilentlyContinue }
    }
    $run
}

function Undo-AVDTuneOfficeFix {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)][string]$Name, [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    $undoPath = Get-AVDTuneOfficeFixUndoPath $Root $Name
    $u = Read-AVDTuneJson $undoPath
    if (-not $u) { throw 'There is nothing to undo: this fix was not recorded.' }
    $prev = Test-AVDTuneOfficeFixPrevious (Get-AVDTuneProp $u 'Previous') $Name
    # an Office install or reconfigure after the fix made the record outdated: its earlier value is not what the ODT left behind
    $applied = Get-AVDTuneOfficeAppliedPath $Root; $at = ConvertTo-AVDTuneUtc (Get-AVDTuneProp $u 'At')
    if (-not $at) { throw "The undo record of the Office fix $Name has no readable time (At). Nothing was changed." }
    if ((Test-Path -LiteralPath $applied -PathType Leaf) -and (Get-Item -LiteralPath $applied -Force).LastWriteTimeUtc -gt $at) { throw "The undo record of the Office fix $Name is older than the last Office install or reconfigure: its earlier value is outdated. Nothing was changed." }
    if ($at -gt (& $Machine.Now).ToUniversalTime().AddMinutes(5)) { throw "The undo record of the Office fix $Name has a time in the future (At). Nothing was changed." }
    # any Office run (install, reconfigure, remove, whatever its status) after the record also makes it outdated
    $later = @(Get-AVDTuneRun -Root $Root | Where-Object { $_.Plan -cin 'Office install', 'Office remove' -and (-not (ConvertTo-AVDTuneUtc $_.Started) -or (ConvertTo-AVDTuneUtc $_.Started) -gt $at) })   # an unreadable start counts as later (fail closed)
    if ($later.Count -gt 0) { throw "The undo record of the Office fix $Name is older than a later Office run ($($later[0].Plan)): its earlier value is outdated. Nothing was changed." }
    if (-not $WhatIf) {
        if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot newer than its last change is confirmed on the Overview.' }
    }
    $step = Get-AVDTuneOfficeFixStep -Name $Name -Previous $prev
    # the update block (or a maintenance mode) owns the value of the updates fix: Undo must not take it away, only the fix record goes
    if ($Name -ceq 'updates' -and (Test-AVDTuneOfficeUpdateBlockOwns -Machine $Machine -Root $Root)) {
        $msg = 'The value now belongs to the update block (or a running maintenance mode): it was not touched, only the record of the fix was discarded.'
        $r = [pscustomobject][ordered]@{ Id = $step.Id; Section = $step.Section; Title = $step.Title; Mode = 'Undo'; Status = 'Unchanged'; Before = $null; After = $null; Message = $msg; Reboot = $false; WhatIf = [bool]$WhatIf; At = (& $Machine.Now).ToString('o') }
        if ($WhatIf) { return [pscustomobject]@{ Plan = "Office fix undo: $Name"; WhatIf = $true; Results = @($r) } }
        $state = Get-AVDTuneState $Root
        $ended = (& $Machine.Now).ToString('o')
        $saved = [pscustomobject][ordered]@{ Id = $null; Plan = "Office fix undo: $Name"; Started = $ended; Ended = $ended; User = $User; SnapshotId = $SnapshotId; WhatIf = $false; ImageVersion = $state.ImageVersion; Reboot = $false; Results = @($r) }   # no LastChange: the master was not changed
        [void](Add-AVDTuneRun -Root $Root -Run $saved)
        if ($state.ImageVersion) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'Office' -Component $r.Id -ChangeType Note -Text "Undo of the fix discarded: value now belongs to the update block ($($step.Title))" -User $User -SnapshotId $SnapshotId -RunId ([string]$saved.Id) -Source Step) }
        Remove-Item -LiteralPath $undoPath -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Plan = "Office fix undo: $Name"; WhatIf = $false; Results = @($r) }
    }
    if ($WhatIf) { return [pscustomobject]@{ Plan = "Office fix undo: $Name"; WhatIf = $true; Results = @(Invoke-AVDTuneStep -Step $step -Machine $Machine -Mode Undo -WhatIf) } }
    $changeOwner = Start-AVDTuneChange -Root $Root   # marker while the master is written (snapshot gate, #27)
    try {
        [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = (& $Machine.Now).ToString('o') })   # before the attempt: a failed undo may have changed the master
        $r = Invoke-AVDTuneStep -Step $step -Machine $Machine -Mode Undo
        $state = Get-AVDTuneState $Root
        $ended = (& $Machine.Now).ToString('o')
        [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = $ended })   # also when the step failed
        $saved = [pscustomobject][ordered]@{ Id = $null; Plan = "Office fix undo: $Name"; Started = $ended; Ended = $ended; User = $User; SnapshotId = $SnapshotId; WhatIf = $false; ImageVersion = $state.ImageVersion; Reboot = $false; Results = @($r) }
        [void](Add-AVDTuneRun -Root $Root -Run $saved)
        if ($r.Status -eq 'Reverted' -and $state.ImageVersion) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'Office' -Component $r.Id -ChangeType Changed -Text "Undo: $($r.Title)" -User $User -SnapshotId $SnapshotId -RunId ([string]$saved.Id) -Source Step) }
        if ($r.Status -ne 'Failed') { Remove-Item -LiteralPath $undoPath -Force -ErrorAction SilentlyContinue }
        [pscustomobject]@{ Plan = "Office fix undo: $Name"; WhatIf = $false; Results = @($r) }
    }
    finally { Stop-AVDTuneChange -Root $Root -Owner $changeOwner }
}

#endregion

#region real adapter

function New-AVDTuneOfficeAdapter {
    <#
        The real adapter. NOT exercised by the checks beyond construction: the page, the download, the extraction and setup.exe are written from the
        documentation and have to be tried on a throw-away VM (docs\office.md, "not verified"). Hosts: www.microsoft.com (page) and download.microsoft.com (file),
        https only, no redirect followed.
    #>
    $u = New-AVDTuneUpdateAdapter   # its VerifySignature
    $a = [ordered]@{ Kind = 'Real' }
    $a.OdtPage = {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $uri = [Uri]$script:OdtPageUrl
            if ($uri.Scheme -ne 'https' -or $uri.Host -ne $script:OdtPageHost) { return @{ Ok = $false; Text = ''; Error = 'The page address is not the fixed Microsoft address.' } }
            $req = [System.Net.HttpWebRequest]::Create($uri); $req.AllowAutoRedirect = $false; $req.Timeout = 30000; $req.ReadWriteTimeout = 30000
            $resp = $req.GetResponse()
            try {
                if ([int]$resp.StatusCode -ne 200) { return @{ Ok = $false; Text = ''; Error = "HTTP $([int]$resp.StatusCode)" } }
                $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
                $buf = New-Object char[] 65536; $sb = New-Object Text.StringBuilder
                while (($n = $sr.Read($buf, 0, $buf.Length)) -gt 0) { [void]$sb.Append($buf, 0, $n); if ($sb.Length -gt $script:MaxPageChars) { return @{ Ok = $false; Text = ''; Error = 'The page is larger than expected.' } } }
                @{ Ok = $true; Text = $sb.ToString(); Error = '' }
            }
            finally { $resp.Close() }
        }
        catch { @{ Ok = $false; Text = ''; Error = $_.Exception.Message } }
    }
    $a.NewTempFolder = { param($Root) New-AVDTuneDownloadFolder -Root $Root -Prefix office }   # created with its protected ACL in one step (#79)
    $a.IsProtectedFolder = { param($Dir, $Root) Test-AVDTuneAdminOnlyPath -Path $Dir -Base (Split-Path $Root -Parent) }
    $a.Download = {
        param($Url, $Dest, $MaxBytes)
        try {
            $uri = [Uri]$Url
            if ($uri.Scheme -ne 'https' -or $uri.Host -ne $script:OdtFileHost) { return @{ Ok = $false; Error = "Only https://$script:OdtFileHost is allowed." } }
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $req = [System.Net.HttpWebRequest]::Create($uri); $req.AllowAutoRedirect = $false; $req.Timeout = 120000; $req.ReadWriteTimeout = 120000
            $resp = $req.GetResponse()
            try {
                if ([int]$resp.StatusCode -ne 200) { return @{ Ok = $false; Error = "HTTP $([int]$resp.StatusCode)" } }
                if ($resp.ContentLength -gt $MaxBytes) { return @{ Ok = $false; Error = 'The file is larger than expected.' } }
                $in = $resp.GetResponseStream(); $out = New-AVDTuneAdminFile -Path $Dest; $total = 0   # CreateNew with an explicit admin-only ACL (#79)
                try { $buf = New-Object byte[] 81920; while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $total += $n; if ($total -gt $MaxBytes) { throw 'The download is larger than expected.' }; $out.Write($buf, 0, $n) } } finally { $out.Dispose(); $in.Dispose() }
            }
            finally { $resp.Close() }
            @{ Ok = $true; Error = ''; Bytes = $total }
        }
        catch { @{ Ok = $false; Error = $_.Exception.Message } }
    }
    $a.VerifySignature = $u.VerifySignature
    $a.Run = {
        # No shell, no window, a clean allowlist environment (TEMP = the protected work folder of the file), the whole process tree in a job object, timeout ends the tree
        param($File, [string[]]$Arguments, [int]$TimeoutSeconds = 600)
        $r = Invoke-AVDTuneChildProcess -FileName $File -Arguments (($Arguments | ForEach-Object { ConvertTo-AVDTuneArgument ([string]$_) }) -join ' ') -TimeoutMs ($TimeoutSeconds * 1000) -CleanEnvironment -Tool office -TempDir (Split-Path $File -Parent)
        [pscustomobject]@{ ExitCode = $r.ExitCode; Output = ([string]$r.Output + [string]$r.Error) }
    }
    $a.FindSetup = {
        param($Dir)
        $p = Join-Path $Dir 'setup.exe'
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
        if (((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
        $p
    }
    $a.HoldFile = { param($Path) [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read) }   # nobody can write to it, delete it or rename it while it is held (Open-AVDTuneVerifiedBenchExe does the same)
    $a.ListFolder = { param($Dir) @([IO.Directory]::GetFileSystemEntries($Dir) | ForEach-Object { [IO.Path]::GetFileName($_) }) }
    $a.WriteText = { param($Path, $Text) Write-AVDTuneFile $Path $Text }
    $a.RemoveFolder = { param($Dir) Remove-AVDTuneFolderNoFollow $Dir }
    [pscustomobject]$a
}

#endregion

Export-ModuleMember -Function Get-AVDTuneOfficeChannels, Get-AVDTuneOfficeProducts, Get-AVDTuneOfficeExcludableApps, Get-AVDTuneOfficeDefaults, Test-AVDTuneOfficeConfig,
    ConvertTo-AVDTuneOfficeConfig, Get-AVDTuneOfficeConfig, Set-AVDTuneOfficeConfig, New-AVDTuneOfficeXml, Test-AVDTuneOfficeXml, Get-AVDTuneOfficeState, Get-AVDTuneOfficeRows,
    Get-AVDTuneOdtLink, Test-AVDTuneOdtPackageTrust, Test-AVDTuneOdtFolderNames, Get-AVDTuneOfficeUndoDrift, Get-AVDTuneOfficeRemoveText, Get-AVDTuneOfficeUndoText, Get-AVDTuneOfficeUndoLimits, Invoke-AVDTuneOfficeSetup, Invoke-AVDTuneOfficeRecorded, Invoke-AVDTuneOfficeUndo, Set-AVDTuneOfficePolicies,
    Undo-AVDTuneOfficePolicies, Get-AVDTuneOfficeFixNames, Get-AVDTuneOfficeFixRecorded, Get-AVDTuneOfficeOutlookHint, Get-AVDTuneOfficeAppsHint, Get-AVDTuneOfficeFixText, Get-AVDTuneOfficeFixStep, Set-AVDTuneOfficeFix, Undo-AVDTuneOfficeFix, Get-AVDTuneOfficeLicenses, Get-AVDTuneOfficeLicenseName, Get-AVDTuneOfficeInstallApps, Get-AVDTuneOfficeDefaultInstallApps, Get-AVDTuneOfficeOutlookChoices, Get-AVDTuneOfficeLanguages, ConvertTo-AVDTuneOfficeExcludes, ConvertTo-AVDTuneOfficeLanguageList, ConvertFrom-AVDTuneOfficeStored, Get-AVDTuneOfficeEffectiveExcludes, New-AVDTuneOfficeAdapter
