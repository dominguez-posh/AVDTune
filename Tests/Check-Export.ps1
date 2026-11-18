#requires -Version 5.1
<#
.SYNOPSIS
    Checks phase 7 (issue #91): the export ZIP (Modules\AVDTune.Export.psm1: contents, the shared secret table, path without links, atomic write) and the
    snapshot housekeeping and gallery versions (Modules\AVDTune.Snapshot.psm1) against the fake ARM of Tests\Fakes\FakeServices.ps1 and a temporary state folder:
    what is kept (confirmed, running version, foreign, newest N, too young, no newer gallery version), the deletion only after the confirmation by name, with the
    open gate, not after the finish, the 403 reported with the missing right, a change log entry per snapshot, and the page wiring.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
foreach ($m in 'AVDTune', 'AVDTune.Snapshot', 'AVDTune.SharePoint', 'AVDTune.Export') { Import-Module (Join-Path $repo "Modules\$m.psm1") -Force }
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeServices.ps1')
Add-Type -AssemblyName System.IO.Compression

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }
function Read-Zip([string]$Path) {
    $z = [IO.Compression.ZipFile]::OpenRead($Path)
    try { $h = @{}; foreach ($e in $z.Entries) { $r = New-Object IO.StreamReader($e.Open()); try { $h[$e.FullName] = $r.ReadToEnd() } finally { $r.Dispose() } }; $h } finally { $z.Dispose() }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-export-' + [guid]::NewGuid().ToString('N'))
$jwt = 'eyJhbGciOiJSUzI1NiJ9.eyJhdWQiOiJodHRwczovL2dyYXBoIn0.c2lnbmF0dXJlLW5vdC1yZWFs'
$storageKey = ('Ab1+' * 21) + 'Ab1+=='

try {
    $env:AVDTUNE_ROOT = $tmp
    [void](Initialize-AVDTuneState -Root $tmp)
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-18') -User 'admin1')
    $ver = [string](Get-AVDTuneState $tmp).ImageVersion
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- export: contents and the secret filter
    [IO.File]::WriteAllText((Join-Path $tmp 'environment.json'), (@{ Schema = 1; Answers = @{ IdentityModel = 'Hybrid'; Domain = 'example.local'; StorageKey = $storageKey; Note = "sig=$jwt" }; SignIn = @{ ClientId = '11111111-2222-3333-4444-555555555555'; RefreshToken = 'abc' } } | ConvertTo-Json -Depth 5))
    New-Item -ItemType Directory -Path (Join-Path $tmp 'config') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $tmp 'config\customizations.json'), '{"Items":[{"Kind":"Shortcut","Name":"Example","Arguments":"-Password Secr3t!"}]}')
    [IO.File]::WriteAllText((Join-Path $tmp 'config\printers.json'), '{"Servers":["print01.example.local"],"Drivers":[{"Name":"Example PCL6"}]}')
    [IO.File]::WriteAllText((Join-Path $tmp 'config\masking.json'), '{"Rules":[{"App":"Example App","Groups":["AVD-Example"]}]}')
    [void](Add-AVDTuneChangeLogEntry -Root $tmp -Version $ver -Category 'Software' -ChangeType 'Added' -Text "Example App 1.0 installed, key $storageKey" -User 'admin1')
    $cmp = [pscustomobject]@{ Rows = @([pscustomobject]@{ ImageVersion = $ver; HostScore = 81.5; FslogixScore = $null; GpuScore = $null; CapacityUsers = 12; Mode = 'Full'; VsPrevious = $null }) }
    $ex = Get-AVDTuneExportEntries -Root $tmp -Computer 'GM-TEST01' -Comparison $cmp -ComparisonCsv "ImageVersion,HostScore`r`n$ver,81.5" -ComparisonJson '{"schemaVersion":1}'
    $names = @($ex.Entries | ForEach-Object Name)
    $want = @('README.txt', 'environment.html', 'settings/environment.json', 'settings/customizations.json', 'settings/printers.json', 'settings/masking.json', 'changelog/changelog.json', "changelog/$ver.md", 'benchmark/comparison.csv', 'benchmark/comparison.json')
    Test-Check 'export: environment document, environment.json, customizations, printers, App Masking, change log (JSON and per version), benchmark comparison, README' (@($want | Where-Object { $names -notcontains $_ }).Count -eq 0) ($names -join ', ')
    $all = (@($ex.Entries | ForEach-Object Text) -join "`n")
    Test-Check 'export: no storage key, token, refresh token or password in any file (the shared secret table of AVDTune.SharePoint)' ($all -notlike "*$storageKey*" -and $all -notlike "*$jwt*" -and $all -notmatch '"abc"' -and $all -notlike '*Secr3t*' -and @($ex.Entries | Where-Object { -not (Test-AVDTuneSpSecretFree $_.Text) }).Count -eq 0) $null
    $envJson = ($ex.Entries | Where-Object Name -eq 'settings/environment.json').Text | ConvertFrom-Json
    Test-Check 'export: a value whose name sounds secret is left out with its name, the other answers stay, the JSON stays valid' (-not $envJson.Answers.PSObject.Properties['StorageKey'] -and -not $envJson.SignIn.PSObject.Properties['RefreshToken'] -and $envJson.Answers.Note -like 'sig=(*removed)' -and $envJson.Answers.Domain -eq 'example.local' -and $envJson.SignIn.ClientId -eq '11111111-2222-3333-4444-555555555555') ($envJson | ConvertTo-Json -Compress -Depth 4)
    $flagged = Get-AVDTuneExportEntries -Root $tmp -ComparisonCsv "a`r`npassword=Secr3t!" -ComparisonJson '{"Text":"password=Secr3t!"}'
    $csv = ($flagged.Entries | Where-Object Name -eq 'benchmark/comparison.csv').Text; $js = ($flagged.Entries | Where-Object Name -eq 'benchmark/comparison.json')
    Test-Check 'export (counter-test): a text file is filtered, a JSON file in which the table still finds a secret is left out and named' ($csv -like '*password=(removed)*' -and -not $js -and @($flagged.Skipped | Where-Object { $_ -like 'benchmark/comparison.json:*password, key or token*' }).Count -eq 1 -and ($flagged.Entries | Where-Object Name -eq 'README.txt').Text -like '*Left out:*comparison.json*') ($flagged.Skipped -join ' | ')
    $deep = @{ a = @{ b = @{ c = @{ d = @{ e = @{ f = @{ g = @{ h = @{ i = 'x' } } } } } } } } }
    Test-Check 'export: nesting deeper than 8 levels is not followed' ((ConvertTo-AVDTuneExportJson $deep) -like '*too deep*') $null
    Test-Check 'export: the README names the files and says what is left out' (($ex.Entries | Where-Object Name -eq 'README.txt').Text -like '*settings/environment.json*' -and ($ex.Entries | Where-Object Name -eq 'README.txt').Text -like '*administrators*') $null

    # ---------------------------------------------------------------- export: the ZIP, the path, atomic
    $folder = Get-AVDTuneExportFolder -Root $tmp
    Test-Check 'export folder: <state>\exports, created as AVDTune''s own folder' ($folder -eq (Join-Path $tmp 'exports') -and (Test-Path -LiteralPath $folder)) $folder
    $name = Get-AVDTuneExportFileName -Version $ver -Now ([datetime]'2026-11-18 14:05')
    Test-Check 'export file name: avdtune-export-<version>-<date>.zip' ($name -eq "avdtune-export-$ver-20261118-1405.zip") $name
    $zipPath = Join-Path $folder $name
    $r = Export-AVDTuneBundle -Export $ex -Path $zipPath
    $content = Read-Zip $zipPath
    Test-Check 'export: the ZIP holds every file with its text, size and SHA256 returned' ($content.Count -eq @($ex.Entries).Count -and $content['settings/printers.json'] -like '*Example PCL6*' -and $r.Size -eq (Get-Item $zipPath).Length -and $r.Sha256 -match '^[0-9A-F]{64}$') "$($content.Count) $($r.Size)"
    Test-Check 'export: no temp file is left next to the ZIP' (@(Get-ChildItem -LiteralPath $folder -Force -Filter '*.tmp').Count -eq 0) $null
    $r2 = Export-AVDTuneBundle -Export $ex -Path $zipPath
    Test-Check 'export: a second export to the same file replaces it in one step' ((Read-Zip $zipPath).Count -eq $content.Count -and $r2.Path -eq $zipPath) $null
    $badNames = @('../evil.txt', 'a/../../b', 'C:/x', '\\server\x', '', 'a b.txt')
    $okRefused = @($badNames | Where-Object { Get-ThrownText { Export-AVDTuneBundle -Export ([pscustomobject]@{ Entries = @([pscustomobject]@{ Name = $_; Text = 'x' }); Skipped = @() }) -Path (Join-Path $folder 'n.zip') } })
    Test-Check 'export (counter-test): names that climb, are absolute or have spaces are refused' ($okRefused.Count -eq $badNames.Count -and -not (Test-Path -LiteralPath (Join-Path $folder 'n.zip'))) ($okRefused -join ' | ')
    $twice = Get-ThrownText { Export-AVDTuneBundle -Export ([pscustomobject]@{ Entries = @([pscustomobject]@{ Name = 'a.txt'; Text = 'x' }, [pscustomobject]@{ Name = 'A.txt'; Text = 'y' }); Skipped = @() }) -Path (Join-Path $folder 'n.zip') }
    Test-Check 'export (counter-test): a name twice is refused' ($twice -like '*twice*') $twice
    Test-Check 'export (counter-test): only .zip, no network path, folder must exist' ((Get-ThrownText { Assert-AVDTuneExportPath (Join-Path $folder 'x.txt') }) -like '*.zip*' -and (Get-ThrownText { Assert-AVDTuneExportPath '\\server\share\x.zip' }) -like '*network*' -and (Get-ThrownText { Assert-AVDTuneExportPath (Join-Path $tmp 'missing\x.zip') }) -like '*does not exist*') $null
    $real = Join-Path $tmp 'real'; New-Item -ItemType Directory -Path $real | Out-Null
    $link = Join-Path $tmp 'link'
    $junction = $false; try { cmd.exe /c mklink /J "$link" "$real" 2>&1 | Out-Null; $junction = Test-Path -LiteralPath $link } catch { }
    if ($junction) {
        $deepLink = Join-Path $link 'sub'; New-Item -ItemType Directory -Path (Join-Path $real 'sub') | Out-Null
        $e1 = Get-ThrownText { Export-AVDTuneBundle -Export $ex -Path (Join-Path $link 'x.zip') }
        $e2 = Get-ThrownText { Export-AVDTuneBundle -Export $ex -Path (Join-Path $deepLink 'x.zip') }
        Test-Check 'export (counter-test): a junction in the folder or higher up the path is refused, nothing is written behind it' ($e1 -like '*is a link*' -and $e2 -like '*is a link*' -and @(Get-ChildItem -LiteralPath $real -Recurse -File).Count -eq 0) "$e1 | $e2"
        [IO.Directory]::Delete($link)
    }
    else { Test-Check 'export (counter-test): junction could not be created here (mklink)' $false $null }

    # ---------------------------------------------------------------- snapshot housekeeping: the plan (pure)
    $now = [datetime]'2026-11-18 12:00'
    $mk = { param($name, $days, [bool]$by = $true, [string]$iv = '2026.10.001', [bool]$fin = $true) [pscustomobject]@{ Name = $name; Id = "/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/rg-example/providers/Microsoft.Compute/snapshots/$name"; Created = $now.AddDays(-$days); Finished = $fin; ByAVDTune = $by; ImageVersion = $iv } }
    $snaps = @((& $mk 'gm-test01_osdisk-17.11.2026-1' 1 $true $ver), (& $mk 'gm-test01_osdisk-01.11.2026-1' 17), (& $mk 'gm-test01_osdisk-20.10.2026-1' 29), (& $mk 'gm-test01_osdisk-10.10.2026-1' 39), (& $mk 'manual-backup' 60 $false ''),
        (& $mk 'gm-test01_osdisk-01.09.2026-1' 78 $false ''), (& $mk 'gm-test01_osdisk-02.09.2026-1' 77 $true '2026.08.001' $false), (& $mk 'gm-test01_osdisk-05.11.2026-1' 13))
    $state = [pscustomobject]@{ ImageVersion = $ver; SnapshotGate = [pscustomobject]@{ SnapshotId = $snaps[1].Id }; FirstChangeSnapshotId = $null }
    $gallery = @([pscustomobject]@{ Name = '1.0.2'; Published = $now.AddDays(-15); Regions = @('westeurope') }, [pscustomobject]@{ Name = '1.0.1'; Published = $now.AddDays(-35); Regions = @() })
    $plan = @(Get-AVDTuneSnapshotCleanupPlan -Snapshots $snaps -State $state -GalleryVersions $gallery -Keep 2 -MinAgeDays 7 -OsDiskName 'gm-test01_osdisk' -VmName 'gm-test01' -Now $now)
    $row = { param($n) @($plan | Where-Object Name -eq $n)[0] }
    Test-Check 'plan: the snapshot of the running image version is kept' (-not (& $row 'gm-test01_osdisk-17.11.2026-1').Delete -and (& $row 'gm-test01_osdisk-17.11.2026-1').Reason -like '*running image version*') (& $row 'gm-test01_osdisk-17.11.2026-1').Reason
    Test-Check 'plan: the confirmed snapshot of the gate is kept' (-not (& $row 'gm-test01_osdisk-01.11.2026-1').Delete -and (& $row 'gm-test01_osdisk-01.11.2026-1').Reason -like '*confirmed*') (& $row 'gm-test01_osdisk-01.11.2026-1').Reason
    Test-Check 'plan: one of the newest N is kept' (-not (& $row 'gm-test01_osdisk-05.11.2026-1').Delete -and (& $row 'gm-test01_osdisk-05.11.2026-1').Reason -like '*newest 2*') (& $row 'gm-test01_osdisk-05.11.2026-1').Reason
    Test-Check 'plan: older than the newest gallery version, by AVDTune: offered for deletion with the gallery version named' ((& $row 'gm-test01_osdisk-20.10.2026-1').Delete -and (& $row 'gm-test01_osdisk-20.10.2026-1').Reason -like '*1.0.2*' -and (& $row 'gm-test01_osdisk-10.10.2026-1').Delete) (& $row 'gm-test01_osdisk-20.10.2026-1').Reason
    Test-Check 'plan: a snapshot neither tagged nor named by the pattern is never offered' (-not (& $row 'manual-backup').Delete -and (& $row 'manual-backup').Reason -like '*does not delete*') (& $row 'manual-backup').Reason
    Test-Check 'plan: a snapshot named by the pattern without the tag is offered (made by the administrators'' own process)' ((& $row 'gm-test01_osdisk-01.09.2026-1').Delete) (& $row 'gm-test01_osdisk-01.09.2026-1').Reason
    Test-Check 'plan: an unfinished snapshot is kept' (-not (& $row 'gm-test01_osdisk-02.09.2026-1').Delete) (& $row 'gm-test01_osdisk-02.09.2026-1').Reason
    $planNoGal = @(Get-AVDTuneSnapshotCleanupPlan -Snapshots $snaps -State $state -GalleryVersions @() -GalleryProblem 'no gallery image definition chosen' -Keep 2 -MinAgeDays 7 -OsDiskName 'gm-test01_osdisk' -VmName 'gm-test01' -Now $now)
    Test-Check 'plan (counter-test): without a known gallery version nothing is offered, the reason says why' (@($planNoGal | Where-Object Delete).Count -eq 0 -and (@($planNoGal | Where-Object Name -eq 'gm-test01_osdisk-10.10.2026-1')[0].Reason -like '*no gallery image definition chosen*')) $null
    $planOld = @(Get-AVDTuneSnapshotCleanupPlan -Snapshots $snaps -State $state -GalleryVersions @($gallery[1]) -Keep 2 -MinAgeDays 7 -OsDiskName 'gm-test01_osdisk' -VmName 'gm-test01' -Now $now)
    Test-Check 'plan (counter-test): a snapshot newer than every gallery version is kept' (-not @($planOld | Where-Object Name -eq 'gm-test01_osdisk-20.10.2026-1')[0].Delete -and @($planOld | Where-Object Name -eq 'gm-test01_osdisk-10.10.2026-1')[0].Delete) $null
    $planAge = @(Get-AVDTuneSnapshotCleanupPlan -Snapshots $snaps -State $state -GalleryVersions $gallery -Keep 1 -MinAgeDays 35 -OsDiskName 'gm-test01_osdisk' -VmName 'gm-test01' -Now $now)
    Test-Check 'plan: the minimum age is a setting (35 days keeps the 29 days old one)' (-not @($planAge | Where-Object Name -eq 'gm-test01_osdisk-20.10.2026-1')[0].Delete -and @($planAge | Where-Object Name -eq 'gm-test01_osdisk-10.10.2026-1')[0].Delete) $null
    $gateOnly = @(Get-AVDTuneSnapshotCleanupPlan -Snapshots $snaps -State ([pscustomobject]@{ ImageVersion = $ver }) -GalleryVersions $gallery -Keep 1 -MinAgeDays 0 -OsDiskName 'gm-test01_osdisk' -VmName 'gm-test01' -GateSnapshotId $snaps[3].Id -Now $now)
    Test-Check 'plan: the snapshot of the open write gate is kept as well' (-not @($gateOnly | Where-Object Name -eq 'gm-test01_osdisk-10.10.2026-1')[0].Delete) $null
    $rx = ConvertTo-AVDTuneSnapshotNameRegex -Pattern '{VM}-{ImageVersion}-{N}' -OsDiskName 'd' -VmName 'gm.test'
    Test-Check 'name pattern regex: tokens filled, dots escaped, anchored' ('gm.test-2026.11.001-3' -match $rx -and 'gmXtest-2026.11.001-3' -notmatch $rx -and 'x-gm.test-2026.11.001-3' -notmatch $rx -and (ConvertTo-AVDTuneSnapshotNameRegex -Pattern 'no-counter' -OsDiskName 'd' -VmName 'v') -eq '') $rx

    $def0 = Get-AVDTuneSnapshotCleanupSettings -Root $tmp
    $set = Set-AVDTuneSnapshotCleanupSettings -Root $tmp -Keep 3 -MinAgeDays 14
    [IO.File]::WriteAllText((Join-Path $tmp 'config\snapshot-cleanup.json'), '{"Keep":"3","MinAgeDays":99999}')
    $bad = Get-AVDTuneSnapshotCleanupSettings -Root $tmp
    Test-Check 'housekeeping settings: default 2 and 7 days, saved, a string or a value out of range is the default' ($def0.Keep -eq 2 -and $def0.MinAgeDays -eq 7 -and $set.Keep -eq 3 -and $set.MinAgeDays -eq 14 -and $bad.Keep -eq 2 -and $bad.MinAgeDays -eq 7 -and (Get-ThrownText { Set-AVDTuneSnapshotCleanupSettings -Root $tmp -Keep 0 -MinAgeDays 1 })) "$($bad.Keep) $($bad.MinAgeDays)"

    # ---------------------------------------------------------------- gallery versions and the change log (Hydra or another imaging tool)
    $galleryDef = "/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/rg-gallery/providers/Microsoft.Compute/galleries/galExample/images/avd-gm"
    $seedSnaps = @(foreach ($s in $snaps) { @{ Name = $s.Name; Created = $s.Created; Tags = $(if ($s.ByAVDTune) { @{ CreatedWith = 'AVDTune'; ImageVersion = $s.ImageVersion } } else { @{} }); State = $(if ($s.Finished) { 'Succeeded' } else { 'Creating' }) } })
    $arm = New-AVDTuneFakeArm -Seed @{ Snapshots = $seedSnaps; Search = @{ Subscriptions = @(@{ Id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; Name = 'Example' }); Galleries = @(@{ Sub = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; Rg = 'rg-gallery'; Name = 'galExample'; Images = @(@{ Name = 'avd-gm'; Versions = @(@{ Name = '1.0.2'; Published = $now.AddDays(-15); Regions = @('westeurope', 'northeurope') }, @{ Name = '1.0.1'; Published = $now.AddDays(-35) }, @{ Name = 'latest'; Published = $now }) }) }) } }
    $tok = 'fake-arm-token-value'
    $gv = @(Get-AVDTuneGalleryVersions -Arm $arm -Token $tok -DefinitionId $galleryDef)
    Test-Check 'gallery versions: read only, newest first, regions, names that are no version left out' ($gv.Count -eq 2 -and $gv[0].Name -eq '1.0.2' -and (@($gv[0].Regions) -join ',') -eq 'westeurope,northeurope' -and @($arm.Log | Where-Object { $_ -notlike 'GET *' }).Count -eq 0) (($gv | ForEach-Object Name) -join ',')
    Test-Check 'gallery versions (counter-test): not a definition ID is refused before any request' ((Get-ThrownText { Get-AVDTuneGalleryVersions -Arm $arm -Token $tok -DefinitionId '/subscriptions/x/../images/y' }) -like '*not the Resource ID*') $null
    $arm.Store.GalleryForbidden = $true
    $gf = Get-ThrownText { Get-AVDTuneGalleryVersions -Arm $arm -Token $tok -DefinitionId $galleryDef }
    $arm.Store.GalleryForbidden = $false
    Test-Check 'gallery versions: a 403 names the missing right' ($gf -like '*403*Microsoft.Compute/galleries/images/versions/read*') $gf
    # the finished version 2026.10.001 (finished 20 days ago) gets the gallery versions made after it
    $st = Get-AVDTuneState $tmp
    $vlist = @([pscustomobject]@{ Version = '2026.10.001'; Started = $now.AddDays(-40).ToString('o'); Finished = $now.AddDays(-20).ToString('o') }) + @($st.Versions)
    [void](Set-AVDTuneState -Root $tmp -Values @{ Versions = $vlist })
    $added = @(Add-AVDTuneGalleryVersionEntries -Root $tmp -GalleryVersions $gv -User 'admin1')
    $again = @(Add-AVDTuneGalleryVersionEntries -Root $tmp -GalleryVersions $gv -User 'admin1')
    Test-Check 'gallery versions: one change log entry for the version published after a finish (version, date, regions), in the version it belongs to; not twice' ($added.Count -eq 1 -and $added[0].Version -eq '2026.10.001' -and $added[0].Text -like '*1.0.2*westeurope, northeurope*' -and $again.Count -eq 0) ($added | ConvertTo-Json -Compress)

    # ---------------------------------------------------------------- snapshot housekeeping: the deletion
    $vm = Get-AVDTuneVmIdentity (New-AVDTuneFakeMachine)
    $vm.ResourceGroup = 'rg-example'; $vm.OsDiskName = 'gm-test01_osdisk'; $vm.VmName = 'gm-test01'; $vm.OsDiskId = $arm.Store.DiskId
    [void](Set-AVDTuneState -Root $tmp -Values @{ SnapshotGate = [pscustomobject]@{ SnapshotId = $snaps[1].Id } })
    $live = @(Get-AVDTuneOsDiskSnapshots -Arm $arm -Token $tok -Vm $vm)
    $plan2 = @(Get-AVDTuneSnapshotCleanupPlan -Snapshots $live -State (Get-AVDTuneState $tmp) -GalleryVersions $gv -Keep 2 -MinAgeDays 7 -OsDiskName $vm.OsDiskName -VmName $vm.VmName -Now (Get-Date))
    $offer = @($plan2 | Where-Object Delete | ForEach-Object Name)
    $args0 = @{ Arm = $arm; Token = $tok; Vm = $vm; Root = $tmp; GalleryDefinitionId = $galleryDef; Keep = 2; MinAgeDays = 7; User = 'Alex Example' }
    $noGate = Get-ThrownText { Remove-AVDTuneOldSnapshots @args0 -ConfirmedNames $offer }
    Test-Check 'delete (counter-test): without the open snapshot gate nothing is deleted' ($noGate -like 'Read only*' -and $arm.Store.Deleted.Count -eq 0) $noGate
    Open-AVDTuneWriteGate -SnapshotId $snaps[1].Id -ConfirmedBy 'Alex Example'
    $notOffered = Get-ThrownText { Remove-AVDTuneOldSnapshots @args0 -ConfirmedNames @($offer + 'manual-backup') }
    Test-Check 'delete (counter-test): a confirmed name that is not offered (foreign snapshot) stops everything, nothing is deleted' ($notOffered -like '*manual-backup is no longer offered*' -and $arm.Store.Deleted.Count -eq 0) $notOffered
    $current = Get-ThrownText { Remove-AVDTuneOldSnapshots @args0 -ConfirmedNames @('gm-test01_osdisk-01.11.2026-1') }
    Test-Check 'delete (counter-test): the confirmed snapshot of the gate cannot be deleted by name' ($current -like '*no longer offered*confirmed*' -and $arm.Store.Deleted.Count -eq 0) $current
    [void](Set-AVDTuneState -Root $tmp -Values @{ Sealed = $true })
    $sealedErr = Get-ThrownText { Remove-AVDTuneOldSnapshots @args0 -ConfirmedNames $offer }
    [void](Set-AVDTuneState -Root $tmp -Values @{ Sealed = $false })
    Test-Check 'delete (counter-test): not while the image version is finished' ($sealedErr -like '*is finished*' -and $arm.Store.Deleted.Count -eq 0) $sealedErr
    $arm.Store.DeleteForbidden = $true
    $forb = Remove-AVDTuneOldSnapshots @args0 -ConfirmedNames $offer
    $arm.Store.DeleteForbidden = $false
    Test-Check 'delete: without the right the 403 is reported with Microsoft.Compute/snapshots/delete and the role, the rest is not tried' ($forb.Deleted.Count -eq 0 -and $forb.Failed.Count -eq 1 -and $forb.Message -like '*403*Microsoft.Compute/snapshots/delete*Disk Snapshot Contributor*' -and @($arm.Log | Where-Object { $_ -like 'DELETE *' }).Count -eq 1) $forb.Message
    $logBefore = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Snapshot' -and $_.ChangeType -eq 'Removed' }).Count
    $lastBefore = (Get-AVDTuneState $tmp).LastChange
    $res = Remove-AVDTuneOldSnapshots @args0 -ConfirmedNames $offer
    $removedLog = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Snapshot' -and $_.ChangeType -eq 'Removed' })
    Test-Check 'delete: exactly the confirmed snapshots are deleted (DELETE per ID after a read of each), one change log entry each with the snapshot ID' ($res.Deleted.Count -eq $offer.Count -and $offer.Count -ge 2 -and $arm.Store.Deleted.Count -eq $offer.Count -and ($removedLog.Count - $logBefore) -eq $offer.Count -and @($removedLog | Where-Object { -not $_.SnapshotId }).Count -eq 0 -and $logBefore -eq 0) "$($offer -join ',') deleted=$($res.Deleted -join ',')"
    $left = @(Get-AVDTuneOsDiskSnapshots -Arm $arm -Token $tok -Vm $vm | ForEach-Object Name)
    Test-Check 'delete: the confirmed, the running version''s, the newest and the foreign snapshots are still there' ($left -contains 'gm-test01_osdisk-01.11.2026-1' -and $left -contains 'gm-test01_osdisk-17.11.2026-1' -and $left -contains 'gm-test01_osdisk-05.11.2026-1' -and $left -contains 'manual-backup') ($left -join ',')
    Test-Check 'delete: an Azure change, not a change of the master: LastChange is not set (the snapshot window stays)' ((Get-AVDTuneState $tmp).LastChange -eq $lastBefore) $null
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- the page
    $page = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Export.ps1'))
    Test-Check 'page: the deletion asks with the list of names, runs under Enter-AVDTuneWriter (no -AllowSealed), with the gate check, texts from the language files, no GetNewClosure' ($page -match 'Confirm-Action \(T ''exp\.snap\.ask''' -and $page -match "Enter-AVDTuneWriter -Kind 'SnapshotCleanup'" -and $page -match 'Exit-AVDTuneWriter' -and $page -match 'Remove-AVDTuneOldSnapshots' -and $page -notmatch 'AllowSealed' -and $page -notmatch 'GetNewClosure' -and $page -match "T 'exp\.") $null
    $start = [IO.File]::ReadAllText((Join-Path $repo 'Start-AVDTune.ps1'))
    Test-Check 'page: the window loads the export module and the card, the protocol page shows it' ($start -match "'AVDTune\.Export\.psm1'|Modules\\AVDTune\.Export\.psm1" -and $start -match "AVDTune-Export\.ps1" -and $start -match 'Show-ExportCard') $null
    $en = Get-Content -Raw (Join-Path $repo 'UI\Strings.en.json') | ConvertFrom-Json
    $used = @([regex]::Matches($page, "T '(exp\.[a-z0-9.]+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $missing = @($used | Where-Object { -not $en.PSObject.Properties[$_] })
    Test-Check 'page: every text key it uses is in the language files' ($used.Count -gt 10 -and $missing.Count -eq 0) ($missing -join ', ')
}
finally {
    Close-AVDTuneWriteGate
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tmp) { try { [void](Remove-AVDTuneTreeSafe -Path $tmp) } catch { } }
}
if ($script:failed -gt 0) { "$script:failed check(s) failed."; exit 1 }
'All export and snapshot housekeeping checks passed.'
