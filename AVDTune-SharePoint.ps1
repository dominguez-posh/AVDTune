# The SharePoint card of the Protocol page (dot-sourced by Start-AVDTune.ps1 after the Finish page; plan 7, 8 and phase 3/4, issue #89). Logic: Modules\AVDTune.SharePoint.psm1.
# Shown with the change log view: the site of the environment (config\sharepoint.json), the upload of the change log, of the software list and of the environment
# document, the option "upload at the finish" and the removal of local records whose upload is confirmed. Without a site the card says so and the document is made
# locally only. Uploads change nothing on the master, but they are long runs: the job is a writer job (SpJob in WriterJobVariables) and starts after
# Assert-NoOtherWriter -AllowSealed (a finished version can still be uploaded). The removal of records changes AVDTune's state: not after the finish, as the same writer job (Assert-NoOtherWriter without -AllowSealed), after SharePoint confirms its copy again.
# The token is taken on the UI thread (the sign-in belongs to it), handed to the one job as a string and dropped. Every text comes from the language files (T 'sp.*').
# Test mode: the fake Graph of Tests\Fakes\FakeSharePoint.ps1 (shared with the runspace) and the window's fake machine; nothing goes to the network.

$script:SpJob = $null
$script:SpLast = ''
$script:SpAfter = $null   # a scriptblock run when the job has ended (the finish after the upload at the finish), with $true when it went well
$script:SpUiBuilt = $false
$script:SpFake = $null
if ($script:TestMode) { . (Get-TestScript 'FakeSharePoint.ps1'); $script:SpFake = New-AVDTuneFakeSharePoint }

# ---------------------------------------------------------------- the job
$script:SpWorkerText = @'
param($AppRoot, $Root, $Kind, $Token, $SiteUrl, $Sync, $User, $Computer, $SharedSp, $SharedMachine)
$ErrorActionPreference = 'Stop'
foreach ($n in 'AVDTune', 'AVDTune.SharePoint') { Import-Module (Join-Path $AppRoot "Modules\$n.psm1") -Force }
$ctx = $null
try {
    if ($SiteUrl) {
        if ($SharedSp) { $ctx = New-AVDTuneSpContext -Token $SharedSp.Token -SiteUrl $SiteUrl -Transport $SharedSp.Transport -Sleep $SharedSp.Sleep }
        elseif ($Token) { $ctx = New-AVDTuneSpContext -Token $Token -SiteUrl $SiteUrl }
    }
    $version = [string](Get-AVDTuneProp (Get-AVDTuneState $Root) 'ImageVersion')
    $recorded = { foreach ($n in 'AVDTune.Updates', 'AVDTune.Software', 'AVDTune.FSLogix', 'AVDTune.Directory', 'AVDTune.Masking', 'AVDTune.Custom', 'AVDTune.Recording') { Import-Module (Join-Path $AppRoot "Modules\$n.psm1") -Force }; Get-AVDTuneRecordedApps -Root $Root }
    switch ($Kind) {
        'ChangeLog' {
            if (-not $ctx) { throw 'No SharePoint site or no sign-in.' }
            Send-AVDTuneSpChangeLog -Context $ctx -Root $Root -Computer $Computer -Progress $Sync
        }
        'Software' {
            if (-not $ctx) { throw 'No SharePoint site or no sign-in.' }
            if (-not $version) { throw 'No image version is started.' }
            $Sync.Text = 'read'
            $rec = & $recorded
            $m = if ($SharedMachine) { $SharedMachine } else { New-AVDTuneMachine }
            $r = Send-AVDTuneSpSoftware -Context $ctx -Root $Root -ImageVersion $version -Recorded $rec.Apps -Installed (Get-AVDTuneInstalledSoftware -Machine $m) -Computer $Computer -Progress $Sync
            $r | Add-Member -NotePropertyName Notes -NotePropertyValue @($rec.Notes) -PassThru
        }
        'Remove' {
            if (-not $ctx) { throw 'No SharePoint site or no sign-in.' }
            $Sync.Text = 'verify'
            $rec = & $recorded
            Remove-AVDTuneSpUploadedRecords -Context $ctx -Root $Root -Recorded $rec.Apps -User $User
        }
        'Document' {
            $Sync.Text = 'read'
            $rec = & $recorded
            $bench = @(); try { Import-Module (Join-Path $AppRoot 'Modules\AVDTune.Benchmark.psm1') -Force; $bench = @((Get-AVDTuneBenchmarkVersionComparison -Root $Root).Rows) } catch { }
            $m = if ($SharedMachine) { $SharedMachine } else { New-AVDTuneMachine }
            $data = Get-AVDTuneEnvironmentDocumentData -Root $Root -Machine $m -Recorded $rec.Apps -Benchmark $bench -Computer $Computer
            $doc = Save-AVDTuneEnvironmentDocument -Root $Root -Data $data
            $up = $null; $err = ''
            if ($ctx) { $Sync.Text = 'files'; try { $up = Send-AVDTuneSpEnvironmentDocument -Context $ctx -Root $Root -Document $doc } catch { $err = $_.Exception.Message } }
            [pscustomobject]@{ Document = $doc; Upload = $up; UploadError = $err }
        }
    }
}
finally { if ($ctx) { Close-AVDTuneSpContext $ctx }; $Token = $null }
'@

function Get-SpToken {
    # On the UI thread: the Sites token of the sign-in as a plain string for one job; nothing is kept here
    if ($script:TestMode) { return '' }
    $s = $script:StartContext.Session
    if (-not $s -or -not $s.Connected) { throw (T 'sp.err.signin') }
    [string](Get-AVDTuneAccessToken -Session $s -Audience Sites)
}

function Start-SpJob([string]$Kind, [scriptblock]$After) {
    if ($script:SpJob) { throw (T 'sp.err.busy') }
    # uploads change nothing on the master; the central list keeps them apart from the runs that do (#49). The removal of records is refused after the finish.
    if ($Kind -eq 'Remove') { Assert-NoOtherWriter } else { Assert-NoOtherWriter -AllowSealed }
    $settings = Get-AVDTuneSpSettings -Root $script:StateRoot
    if (-not $settings.SiteUrl -and $Kind -ne 'Document') { throw (T 'sp.err.nosite') }
    $token = if ($settings.SiteUrl) { Get-SpToken } else { '' }
    $sync = [hashtable]::Synchronized(@{ Text = ''; Done = 0; Total = 0 })
    $ps = New-AVDTunePowerShell
    [void]$ps.AddScript($script:SpWorkerText).AddArgument($script:AppRoot).AddArgument($script:StateRoot).AddArgument($Kind).AddArgument($token).AddArgument([string]$settings.SiteUrl).AddArgument($sync).AddArgument([string]$env:USERNAME).AddArgument([string](& $script:Machine.ComputerName)).AddArgument($script:SpFake).AddArgument($(if ($script:TestMode) { $script:Machine } else { $null }))
    $task = Start-AVDTuneUiTask -Kind "sharepoint-$($Kind.ToLower())" -Title (T "sp.task.$($Kind.ToLower())") -Step (T 'sp.task.start')
    $script:SpJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Kind = $Kind; Sync = $sync; Task = $task }
    $script:SpAfter = $After
    $token = $null
    Set-SpBusy $true
}

function Set-SpBusy([bool]$Busy) {
    if (-not $script:SpUiBuilt) { return }
    foreach ($b in $ui.BtnSpChangeLog, $ui.BtnSpSoftware, $ui.BtnSpDocument, $ui.BtnSpRemove, $ui.BtnSpSave) { $b.IsEnabled = -not $Busy }
}

function Complete-SpJob {
    $job = $script:SpJob
    if (-not $job) { return }
    if (-not $job.Handle.IsCompleted) { $t = [string]$job.Sync.Text; if ($t) { Update-AVDTuneUiTask $job.Task -Step (T "sp.step.$t" $job.Sync.Done $job.Sync.Total) }; return }
    $script:SpJob = $null
    $after = $script:SpAfter; $script:SpAfter = $null
    $result = $null; $err = ''
    try {
        $out = @($job.PS.EndInvoke($job.Handle))
        if ($job.PS.Streams.Error.Count -gt 0) { $err = $job.PS.Streams.Error[0].Exception.Message }
        $result = $out | Select-Object -Last 1
    }
    catch { $err = $_.Exception.Message }
    finally { $job.PS.Dispose() }
    Set-SpBusy $false
    $err = Remove-PackTuneProtocolSecrets $err 400
    $failed = [bool]($err -or -not $result)
    $summary = ''
    if ($failed) { $summary = T 'sp.failed' (T "sp.task.$($job.Kind.ToLower())") $(if ($err) { $err } else { '-' }) }
    else {
        switch ($job.Kind) {
            'ChangeLog' { $summary = T 'sp.done.changelog' $result.Sent $result.Skipped $result.List }
            'Software' {
                $summary = T 'sp.done.software' $result.Sent $result.Skipped $result.Files $result.Confirmed
                if (@($result.Problems).Count) { $failed = $true; $summary += ' ' + (T 'sp.problems' ((@($result.Problems) | ForEach-Object { Remove-PackTuneProtocolSecrets $_ 200 }) -join ' ')) }
            }
            'Remove' {
                $summary = T 'sp.remove.done' @($result.Removed).Count $(if (@($result.Failed).Count) { (@($result.Failed) | ForEach-Object { Remove-PackTuneProtocolSecrets $_ 200 }) -join ' ' } else { '-' })
                if (@($result.Failed).Count) { $failed = $true }
                $script:CswStatus = $null   # the custom software card reads its list again
            }
            'Document' {
                $summary = T 'sp.done.document' $result.Document.Path
                if ($result.Upload -and $result.Upload.Confirmed) { $summary += ' ' + (T 'sp.done.document.up' $result.Upload.Path) }
                elseif ($result.UploadError) { $failed = $true; $summary += ' ' + (T 'sp.failed.upload' (Remove-PackTuneProtocolSecrets $result.UploadError 300)) }
                elseif ($result.Upload) { $failed = $true; $summary += ' ' + (T 'sp.failed.confirm') }
                else { $summary += ' ' + (T 'sp.done.document.local') }
            }
        }
    }
    # #99: after the finish no sign-in stays after a SharePoint job (it was only signed in again for the upload)
    if ($script:StartContext.Session -and (Test-AVDTuneSealed -Root $script:StateRoot)) {
        try { Disconnect-AVDTuneSession $script:StartContext.Session; $summary += ' ' + (T 'sp.signedout.sealed') } catch { $failed = $true; $summary += ' ' + $_.Exception.Message }
        try { Update-StartView } catch { }
    }
    $script:SpLast = $summary
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'other' -Subject $summary)
    Save-Protocol
    Show-Toast $summary
    Complete-AVDTuneUiTask $job.Task -Failed:$failed -Summary $summary
    Update-SpView
    if ($after) {
        # the finish after the upload at the finish: on a failed upload the entries stay local (sent with the next upload) and the administrator decides
        if (-not $failed -or (Confirm-Action (T 'sp.finish.ask' $summary) (T 'sp.title'))) { & $after }
    }
}
$script:Timer.Add_Tick({ try { Complete-SpJob } catch { Show-Error $_.Exception.Message } })

# ---------------------------------------------------------------- the removal of uploaded records (asked on the window thread, done by the writer job SpJob)
function Remove-SpRecords {
    $rec = Get-AVDTuneRecordedApps -Root $script:StateRoot
    $list = @(Get-AVDTuneSpRemovableRecords -Root $script:StateRoot -Recorded $rec.Apps)
    if ($list.Count -eq 0) { Show-Toast (T 'sp.remove.none'); return }
    if (-not (Confirm-Action (T 'sp.remove.ask' $list.Count ((@($list | ForEach-Object { "$($_.Name) $($_.Version) ($($_.Key))" })) -join "`n")) (T 'sp.title'))) { return }
    # a writer job like the uploads (the central lock while it runs, #49): it reads both items in SharePoint again before a record goes (review B5)
    Start-SpJob 'Remove'
}

# ---------------------------------------------------------------- the card
function Build-SpCard {
    if ($script:SpUiBuilt) { return }
    $c = New-MaskCard (T 'sp.title') (T 'sp.hint')
    $c.Card.Margin = '0'
    $ui.TxtSpSite = New-Object System.Windows.Controls.TextBox; $ui.TxtSpSite.Padding = '8,6'; $ui.TxtSpSite.MaxLength = 300
    [System.Windows.Automation.AutomationProperties]::SetName($ui.TxtSpSite, (T 'sp.site'))
    [void]$c.Panel.Children.Add((New-MaskLabeled (T 'sp.site') $ui.TxtSpSite))
    $ui.ChkSpFinish = New-Object System.Windows.Controls.CheckBox; $ui.ChkSpFinish.Content = T 'sp.atfinish'; $ui.ChkSpFinish.Margin = '0,4,0,4'
    [void]$c.Panel.Children.Add($ui.ChkSpFinish)
    $row = New-Object System.Windows.Controls.WrapPanel; $row.Margin = '0,8,0,0'
    $ui.BtnSpSave = New-MaskButton (T 'sp.btn.save') (T 'sp.btn.save')
    $ui.BtnSpChangeLog = New-MaskButton (T 'sp.btn.changelog') (T 'sp.btn.changelog') $true
    $ui.BtnSpSoftware = New-MaskButton (T 'sp.btn.software') (T 'sp.btn.software')
    $ui.BtnSpDocument = New-MaskButton (T 'sp.btn.document') (T 'sp.btn.document')
    $ui.BtnSpRemove = New-MaskButton (T 'sp.btn.remove') (T 'sp.btn.remove')
    foreach ($b in $ui.BtnSpSave, $ui.BtnSpChangeLog, $ui.BtnSpSoftware, $ui.BtnSpDocument, $ui.BtnSpRemove) { $b.Margin = '0,0,8,6'; [void]$row.Children.Add($b) }
    [void]$c.Panel.Children.Add($row)
    $ui.TxtSpState = New-MaskText '' 'Hint' '0,6,0,0'; [void]$c.Panel.Children.Add($ui.TxtSpState)
    $ui.HostSp.Content = $c.Card
    Add-Click $ui.BtnSpSave {
        $s = Set-AVDTuneSpSettings -Root $script:StateRoot -SiteUrl ([string]$ui.TxtSpSite.Text) -UploadAtFinish ([bool]$ui.ChkSpFinish.IsChecked)
        $script:SpLast = T 'sp.saved' $(if ($s.SiteUrl) { $s.SiteUrl } else { T 'sp.local' })
        Update-SpView; Show-Toast $script:SpLast
    }
    Add-Click $ui.BtnSpChangeLog { Start-SpJob 'ChangeLog' }
    Add-Click $ui.BtnSpSoftware { Start-SpJob 'Software' }
    Add-Click $ui.BtnSpDocument { Start-SpJob 'Document' }
    Add-Click $ui.BtnSpRemove { Remove-SpRecords }
    $script:SpUiBuilt = $true
    $s = Get-AVDTuneSpSettings -Root $script:StateRoot
    $ui.TxtSpSite.Text = $s.SiteUrl; $ui.ChkSpFinish.IsChecked = $s.UploadAtFinish
}

function Update-SpView {
    if (-not $script:SpUiBuilt) { return }
    $s = Get-AVDTuneSpSettings -Root $script:StateRoot
    $p = Get-AVDTuneSpPending -Root $script:StateRoot
    $lines = @()
    if (-not $s.SiteUrl) { $lines += T 'sp.nosite' }
    else { $lines += T 'sp.state' $s.SiteUrl $p.Pending $p.Total $(if ($p.Last) { $p.Last } else { '-' }) }
    if ($script:SpLast) { $lines += $script:SpLast }
    $ui.TxtSpState.Text = $lines -join "`r`n"
    foreach ($b in $ui.BtnSpChangeLog, $ui.BtnSpSoftware) { $b.IsEnabled = [bool]($s.SiteUrl -and -not $script:SpJob) }
    $ui.BtnSpRemove.IsEnabled = [bool]($s.SiteUrl -and -not $script:SpJob -and -not (Test-AVDTuneSealed -Root $script:StateRoot))
}

function Show-SpCard([bool]$Visible) {
    # called by Update-ProtocolView: the card belongs to the change log view
    $ui.HostSp.Visibility = ConvertTo-Vis $Visible
    if (-not $Visible) { return }
    Build-SpCard
    Update-SpView
}

function Test-SpUploadAtFinish {
    # the finish uploads the change log first when the option is on and a site is set
    $s = Get-AVDTuneSpSettings -Root $script:StateRoot
    [bool]($s.SiteUrl -and $s.UploadAtFinish)
}
$script:SpReady = $true
