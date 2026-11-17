#requires -Version 5.1
<#
.SYNOPSIS
    Repository hygiene for the public repo (docs\plans\avdtune.md, section 9a). Fails on:
      - GUIDs (also inside Tests\) that are not on the allowlist of public IDs below or obvious fake values (one repeated digit, like 11111111-1111-...),
      - host names *.file.core.windows.net, *.blob.core.windows.net, *.vault.azure.net, *.onmicrosoft.com and *.sharepoint.com with a real name
        (placeholders like contoso, example, fabrikam and privatelink are fine),
      - e-mail addresses and UPNs (placeholder domains: example.*, contoso.*, fabrikam.*, *.invalid),
      - IPv6 addresses other than the documentation range 2001:db8::/32 and ::1,
      - IPv4 addresses outside the documentation ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) and a few well-known public ones
        (private ranges 10/8, 172.16/12, 192.168/16 only inside Tests\, where the fakes use them),
      - names from the local deny list %LOCALAPPDATA%\AVDTune\deny-list.txt (one name per line, # comments). The list lives outside the repo and is never
        committed; without it the check only notes that it was not run (no failure). The output never prints a deny-list name, only the entry number.
    A line that carries the marker "public-content-ok: <reason>" is skipped (a documented exception); a marker without a reason is a finding.
    Not covered, by design of a text scan: images (screenshots, the animated preview) and commit messages. Look at those by hand before they go public.
    Run before every commit and in the release workflow. Reads files only.
.PARAMETER Root
    Folder to scan (default: the repo). Tracked files are scanned when it is a git checkout, otherwise every text file below it.
.PARAMETER DenyListPath
    Deny list (default %LOCALAPPDATA%\AVDTune\deny-list.txt).
#>
[CmdletBinding()]
param([string]$Root, [string]$DenyListPath)

# GUIDs that are public and may appear in code and docs (lower case). Every entry says what it is.
$script:AllowedGuids = @{
    '86ca1aa0-34aa-4e8b-a509-50c905bae2a2' = 'Windows 11 shell CLSID whose empty InprocServer32 brings back the classic context menu (Microsoft Q&A, optimization list #40)'
    'ae6d2014-e692-45fa-a88b-ee552567cdc1' = 'Path of the public FSLogix download on download.microsoft.com (target of aka.ms/fslogix_download), used by the network benchmark'
    'ec984aec-a0f9-47e9-901f-71415a66345b' = 'VIRTUAL_STORAGE_TYPE_VENDOR_MICROSOFT (virtdisk.h), vendor of the VHDX type for the profile container test'
    '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb' = 'Azure built-in role Storage File Data SMB Share Contributor (Microsoft Learn, built-in roles)'
    'a7264617-510b-434b-a828-9731dc254ea7' = 'Azure built-in role Storage File Data SMB Share Elevated Contributor'
    '69566ab7-960f-475b-8e7c-b3118f30c6bd' = 'Azure built-in role Storage File Data Privileged Contributor'
    'b8eda974-7b85-4f76-af95-65846b26df6d' = 'Azure built-in role Storage File Data Privileged Reader'
    '7971f918-a847-4430-9279-4a52d1efe18d' = 'Microsoft Update service ID (Windows Update Agent)'
    '56eb18f8-b008-4cbd-b6d2-8c97fe7e9062' = 'Microsoft Edge product ID (EdgeUpdate registry key)'
    '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Microsoft 365 Apps update channel: Current Channel'
    '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Microsoft 365 Apps update channel: Current Channel (Preview)'
    '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Microsoft 365 Apps update channel: Monthly Enterprise Channel'
    '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Microsoft 365 Apps update channel: Semi-Annual Enterprise Channel'
    'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Microsoft 365 Apps update channel: Semi-Annual Enterprise Channel (Preview)'
    '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Microsoft 365 Apps update channel: Beta Channel'
    '04b07795-8ddb-461a-bbee-02f9e1bf7b46' = 'Microsoft client ID: Azure CLI (public client)'
    '1950a258-227b-4e31-a9cf-717495945fc2' = 'Microsoft client ID: Azure PowerShell (public client)'
    '14d82eec-204b-4c2f-b7e8-296a70dab67e' = 'Microsoft client ID: Microsoft Graph Command Line Tools (public client)'
    '00000003-0000-0000-c000-000000000000' = 'Microsoft Graph resource ID'
    '797f4846-ba00-4fd7-ba43-dac1f8f63013' = 'Azure Service Management resource ID'
    'e406a681-f3d4-42a8-90b6-c2b029497af1' = 'Azure Storage resource ID'
}
$script:DocIpPrefixes = @('192.0.2.', '198.51.100.', '203.0.113.')
$script:PublicIps = @{ '169.254.169.254' = 'Azure instance metadata service (link-local, same everywhere)'; '168.63.129.16' = 'Azure wire server / platform DNS (same everywhere)'; '51.5.0.0' = 'Microsoft AVD relay network 51.5.0.0/16 (UDP 3478), publicly documented in the required FQDN and endpoint list of Azure Virtual Desktop on Microsoft Learn (learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint)'; '0.0.0.0' = 'any'; '255.255.255.255' = 'broadcast' }
$script:HostSuffixes = 'file\.core\.windows\.net|blob\.core\.windows\.net|vault\.azure\.net|onmicrosoft\.com|sharepoint\.com'
$script:HostPlaceholders = '^(example|contoso[\w-]*|fabrikam[\w-]*|account|accountname|storageaccount|yourstorageaccount|mystorageaccount|sample|privatelink|tenant|yourtenant|vaultname|yourvault|myvault|name)$'
$script:MailPlaceholderDomain = '(?i)(^|\.)(example\.(com|org|net|invalid)|contoso\.[a-z.]+|fabrikam\.[a-z.]+|[a-z0-9-]+\.invalid|[a-z0-9.-]*\.(example|test|localhost)|odata\.bind)$'
$script:TextExtensions = '\.(ps1|psm1|psd1|json|md|xaml|xml|yml|yaml|txt|cmd|bat|html|css|csv|gitignore|gitattributes)$'

function Get-ScanFiles([string]$Folder) {
    $files = @()
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git -and (Test-Path -LiteralPath (Join-Path $Folder '.git'))) {
        $listed = & git -C $Folder ls-files -z 2>$null
        if ($LASTEXITCODE -eq 0 -and $listed) { $files = @(($listed -join '') -split "`0" | Where-Object { $_ }) }
    }
    if ($files.Count -eq 0) {
        $base = (Resolve-Path -LiteralPath $Folder).Path.TrimEnd('\')
        $files = @(Get-ChildItem -LiteralPath $Folder -Recurse -File -Force | Where-Object { $_.FullName -notmatch '\\\.git\\' } | ForEach-Object { $_.FullName.Substring($base.Length + 1).Replace('\', '/') })
    }
    @($files | Where-Object { $_ -match $script:TextExtensions -or [IO.Path]::GetFileName($_) -like '.git*' })
}

function Test-FakeGuid([string]$Guid) {
    # An obvious fake: every group is one repeated character (aaaaaaaa-bbbb-..., 11111111-2222-...), the last group may end in a counter (000000000001)
    $g = $Guid.Split('-')
    for ($i = 0; $i -lt 5; $i++) {
        if ($g[$i] -match '^([0-9a-f])\1*$') { continue }
        if ($i -eq 4 -and $g[$i] -match '^0{11}[0-9a-f]$') { continue }
        return $false
    }
    $true
}

function Read-DenyList([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $entries = @(Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    , $entries
}

function Find-PublicContentFindings {
    # Returns objects with Rule, File, Line, Detail. Reads only.
    param([Parameter(Mandatory)][string]$Folder, [string[]]$Deny = @())
    $findings = New-Object System.Collections.ArrayList
    $base = (Resolve-Path -LiteralPath $Folder).Path
    $guidPattern = '(?i)(?<![0-9a-f])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-f])'
    $hostPattern = "(?i)\b([a-z0-9][a-z0-9-]*)\.($($script:HostSuffixes))\b"
    $mailPattern = '(?i)(?<![\w.%+-])[a-z0-9][a-z0-9._%+-]*@([a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,})\b'
    $v6Pattern = '(?i)(?<![\w:.])(?:(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}:){1,7}:(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,6})?|::(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){1,6}))(?![\w:.])'
    $v4Pattern = '(?<![\w.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\w]|\.\d)'
    foreach ($rel in (Get-ScanFiles $Folder)) {
        if ($rel -eq 'Tests/Check-PublicContent.ps1') { continue }   # its own patterns and placeholders
        $full = Join-Path $base ($rel.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $inTests = $rel -like 'Tests/*'
        $n = 0
        foreach ($line in [IO.File]::ReadAllLines($full)) {
            $n++
            if ($line -match 'public-content-ok') {
                if ($line -notmatch 'public-content-ok:\s*\S') { [void]$findings.Add([pscustomobject]@{ Rule = 'marker'; File = $rel; Line = $n; Detail = 'the marker public-content-ok needs a reason after it (public-content-ok: reason)' }) }
                continue
            }
            foreach ($m in [regex]::Matches($line, $guidPattern)) {
                $g = $m.Value.ToLowerInvariant()
                if ($script:AllowedGuids.ContainsKey($g) -or (Test-FakeGuid $g)) { continue }
                [void]$findings.Add([pscustomobject]@{ Rule = 'guid'; File = $rel; Line = $n; Detail = $m.Value })
            }
            foreach ($m in [regex]::Matches($line, $hostPattern)) {
                if ($m.Groups[1].Value -notmatch $script:HostPlaceholders) { [void]$findings.Add([pscustomobject]@{ Rule = 'storage-host'; File = $rel; Line = $n; Detail = $m.Value }) }
            }
            foreach ($m in [regex]::Matches($line, $mailPattern)) {
                if ($m.Groups[1].Value -notmatch $script:MailPlaceholderDomain) { [void]$findings.Add([pscustomobject]@{ Rule = 'mail'; File = $rel; Line = $n; Detail = $m.Value }) }
            }
            foreach ($m in [regex]::Matches($line, $v6Pattern)) {
                $v6 = $m.Value.ToLowerInvariant()
                if ($v6 -match '^2001:0?db8:' -or $v6 -eq '::1') { continue }
                [void]$findings.Add([pscustomobject]@{ Rule = 'ipv6'; File = $rel; Line = $n; Detail = $m.Value })
            }
            foreach ($m in [regex]::Matches($line, $v4Pattern)) {
                $octets = 1..4 | ForEach-Object { [int]$m.Groups[$_].Value }
                if (($octets | Where-Object { $_ -gt 255 }).Count -gt 0) { continue }
                $ip = $m.Value
                $isDoc = $false; foreach ($p in $script:DocIpPrefixes) { if ($ip.StartsWith($p)) { $isDoc = $true } }
                if ($inTests -and ($octets[0] -eq 10 -or ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or ($octets[0] -eq 192 -and $octets[1] -eq 168))) { continue }   # fake addresses of the fixtures
                if ($isDoc -or $script:PublicIps.ContainsKey($ip) -or $octets[0] -eq 127 -or $octets[0] -eq 255) { continue }
                [void]$findings.Add([pscustomobject]@{ Rule = 'ip'; File = $rel; Line = $n; Detail = $ip })
            }
            for ($i = 0; $i -lt $Deny.Count; $i++) {
                if ($line.IndexOf($Deny[$i], [StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$findings.Add([pscustomobject]@{ Rule = 'deny-list'; File = $rel; Line = $n; Detail = "entry $($i + 1) of the deny list" }) }
            }
        }
    }
    @($findings)
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
    if (-not $DenyListPath) { $DenyListPath = Join-Path $env:LOCALAPPDATA 'AVDTune\deny-list.txt' }
    $deny = Read-DenyList $DenyListPath
    $found = @(Find-PublicContentFindings -Folder $Root -Deny $(if ($null -ne $deny) { $deny } else { @() }))
    foreach ($rule in 'guid', 'storage-host', 'mail', 'ipv6', 'ip', 'marker', 'deny-list') {
        $hits = @($found | Where-Object { $_.Rule -eq $rule })
        if ($rule -eq 'deny-list' -and $null -eq $deny) { 'NOTE deny list not found, names not checked (create it to check names: one per line)'; continue }
        if ($hits.Count -eq 0) { "PASS public content: no $rule findings" }
        else { foreach ($h in $hits) { "FAIL public content ($rule) $($h.File):$($h.Line)  $($h.Detail)" } }
    }
    if ($found.Count -gt 0) { exit 1 }
}
