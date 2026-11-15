#requires -Version 5.1
<#
.SYNOPSIS
    Checks AVDTune-Protocol.ps1: the shared PackTune protocol code with AVDTune's groups and texts (DE/EN), the hook from step
    results, secret cleaning, atomic saving and reading back. Writes only into a temporary folder.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-protocol-' + [guid]::NewGuid().ToString('N'))
$script:WorkRoot = $tmp
. (Join-Path $repo 'AVDTune-Protocol.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Test-Throws([scriptblock]$Block) { try { & $Block | Out-Null; $false } catch { $true } }
function New-Result($Section, $Title, $Status, $Message) { [pscustomobject]@{ Id = 'x.y'; Section = $Section; Title = $Title; Status = $Status; Message = $Message; At = '2026-11-20T10:05:00' } }

try {
    $p = New-PackTuneProtocol -Admin 'Admin One' -Account 'admin1' -Tenant 'GM-TEST01 2026.11.001' -Started ([datetime]'2026-11-20T10:00:00')
    Test-Check 'protocol folder is under the work root' ((Get-PackTuneProtocolFolder) -eq (Join-Path $tmp 'Protocols')) (Get-PackTuneProtocolFolder)
    Test-Check 'groups are AVDTune groups' ($script:ProtocolCategories -contains 'updateblock' -and $script:ProtocolCategories -notcontains 'deploy') $null
    $a1 = Add-AVDTuneProtocolFromResult -Protocol $p -Result (New-Result 'Optimization' 'Widgets off' 'Changed' '')
    $a2 = Add-AVDTuneProtocolFromResult -Protocol $p -Result (New-Result 'Updates' 'Windows updates' 'Failed' 'Download failed')
    $a3 = Add-AVDTuneProtocolFromResult -Protocol $p -Result (New-Result 'Office' 'Office channel' 'Unchanged' '')
    $a4 = Add-AVDTuneProtocolFromResult -Protocol $p -Result (New-Result 'Seal' 'Seal check' 'WhatIf' '')
    $a5 = Add-AVDTuneProtocolFromResult -Protocol $p -Result (New-Result 'Optimization' 'Read only' 'Compliant' '')
    Test-Check 'results map to groups and outcomes; reads are not recorded' ($a1.Category -eq 'optimization' -and $a1.Result -eq 'ok' -and $a2.Category -eq 'update' -and $a2.Result -eq 'failed' -and $a2.Note -eq 'Download failed' -and $a3.Category -eq 'software' -and $a3.Result -eq 'skipped' -and $a4.Category -eq 'seal' -and $a4.Note -eq 'dry run' -and $null -eq $a5 -and $p.Actions.Count -eq 4) $p.Actions.Count
    $unknown = Add-AVDTuneProtocolFromResult -Protocol $p -Result (New-Result 'Mystery' 'Odd' 'Changed' '')
    Test-Check 'an unknown section lands in "other"' ($unknown.Category -eq 'other') $null
    Test-Check 'a PackTune group is refused' (Test-Throws { Add-PackTuneProtocolAction -Protocol $p -Category 'deploy' -Subject 'x' }) $null
    $note = Add-AVDTuneProtocolNote -Protocol $p -Group 'setup' -Subject 'Image version 2026.11.001 started'
    Test-Check 'a manual note is recorded' ($note.Category -eq 'setup' -and $note.Result -eq 'ok') $null
    $secret = Add-AVDTuneProtocolNote -Protocol $p -Subject 'login' -Note 'password=hunter2 and Bearer abcdefghijklmnop'
    Test-Check 'secrets are removed from texts' ($secret.Note -notlike '*hunter2*' -and $secret.Note -notlike '*abcdefghijklmnop*') $secret.Note

    $en = ConvertTo-PackTuneProtocolText -Protocol $p -Language en -Format Text -End ([datetime]'2026-11-20T10:30:00')
    Test-Check 'English text: AVDTune title, image label, groups' ($en -like 'AVDTune session protocol*' -and $en -like '*Image: GM-TEST01 2026.11.001*' -and $en -like '*Optimization:*' -and $en -like '*Windows updates: failed (Download failed)*' -and $en -notlike '*PackTune*') $en
    $de = ConvertTo-PackTuneProtocolText -Protocol $p -Language de -Format Markdown -End ([datetime]'2026-11-20T10:30:00')
    $ue = [string][char]0xFC; $ae = [string][char]0xE4
    Test-Check 'German markdown: umlauts, groups, Datum' ($de -like '# AVDTune-Sitzungsprotokoll*' -and $de -like "*Aufr*umen und Versiegeln*" -and (Get-PackTuneProtocolLabels "de").updateblock -eq "Update-Sperre f${ue}r Benutzer" -and $de -like "*Optimierung*" -and $de -like '*20.11.2026*' -and $de -like "*${ue}bersprungen*") $de
    Test-Check 'German texts are plain ASCII in the script file' (-not ([IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Protocol.ps1')) -match '[^\x00-\x7F]')) $null

    $json = Save-PackTuneProtocol -Protocol $p -Language en
    Test-Check 'saved as json and md in <root>\Protocols, no temp files' ((Test-Path $json) -and (Test-Path ([IO.Path]::ChangeExtension($json, '.md'))) -and @(Get-ChildItem (Get-PackTuneProtocolFolder) -Filter '*.tmp').Count -eq 0) $json
    $back = Read-PackTuneProtocolJson -Text ([IO.File]::ReadAllText($json))
    Test-Check 'read back: same actions, AVDTune groups kept' ($back -and $back.Actions.Count -eq $p.Actions.Count -and @($back.Actions | Where-Object { $_.Category -eq 'update' }).Count -eq 1) $null
    $hist = @(Get-PackTuneProtocolHistory)
    Test-Check 'history lists the saved protocol' ($hist.Count -eq 1 -and $hist[0].Where -eq 'Local') $hist.Count
}
finally { if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-Protocol: all checks passed.'
