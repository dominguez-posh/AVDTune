#requires -Version 5.1
<#
.SYNOPSIS
    Checks AVDTune-UiText.ps1 and the language files UI\Strings.en.json / UI\Strings.de.json (issue #70): the files are data and typed (flat object, keys
    \A[a-z0-9.]+\z, string values), both have the same keys and the same placeholders, every key that the shell code or the XAML asks for exists, the lookup
    falls back to English and then to the key, and the shell code has no fixed text left for the translated areas (sample). No window is shown.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'AVDTune-UiText.ps1')
$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Test-Throws([scriptblock]$Block) { try { & $Block; $false } catch { $true } }

$work = Join-Path ([IO.Path]::GetTempPath()) ("avdtune-lang-check-" + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
try {
    # ---------------------------------------------------------------- the real files
    $init = Initialize-AVDTuneLanguage -Folder (Join-Path $repo 'UI')
    Test-Check 'both language files load (typed JSON)' ($init.Problems.Count -eq 0 -and $init.Keys.en -gt 100) ($init.Problems -join '; ')
    $en = Get-AVDTuneTextTable 'en'; $de = Get-AVDTuneTextTable 'de'
    $missing = Get-AVDTuneMissingTexts
    Test-Check 'no key is missing in German' ($missing.MissingInGerman.Count -eq 0) ($missing.MissingInGerman -join ', ')
    Test-Check 'no key is missing in English' ($missing.MissingInEnglish.Count -eq 0) ($missing.MissingInEnglish -join ', ')
    foreach ($lang in 'en', 'de') {
        $raw = [IO.File]::ReadAllText((Join-Path $repo "UI\Strings.$lang.json"), [Text.Encoding]::UTF8)
        $names = @([regex]::Matches($raw, '(?m)^\s*"([^"]+)"\s*:') | ForEach-Object { $_.Groups[1].Value })
        Test-Check "Strings.$lang.json: no key twice" ($names.Count -eq @($names | Select-Object -Unique).Count -and $names.Count -eq $(if ($lang -eq 'en') { $en.Count } else { $de.Count })) "$($names.Count) lines"
        Test-Check "Strings.$lang.json: every key matches the pattern, every text is a non-empty string" (@((Get-AVDTuneTextTable $lang).GetEnumerator() | Where-Object { -not (Test-AVDTuneTextKey $_.Key) -or [string]::IsNullOrWhiteSpace($_.Value) }).Count -eq 0) $null
    }
    $placeholderDiff = @($en.Keys | Where-Object {
            $de.ContainsKey($_) -and ((@([regex]::Matches($en[$_], '\{(\d+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ',') -ne (@([regex]::Matches($de[$_], '\{(\d+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ','))
        })
    Test-Check 'English and German use the same placeholders {0} {1} ... in every text' ($placeholderDiff.Count -eq 0) ($placeholderDiff -join ', ')
    $untranslated = @($en.Keys | Where-Object { $en[$_].Length -ge 25 -and $en[$_] -ceq $de[$_] })
    Test-Check 'no long text is the English text in the German file' ($untranslated.Count -eq 0) ($untranslated -join ', ')

    # ---------------------------------------------------------------- the loader refuses what is not data
    $bad = [ordered]@{
        'a nested object'      = '{"a.b":{"c":"d"}}'
        'a number'             = '{"a.b":5}'
        'a boolean'            = '{"a.b":true}'
        'a null'               = '{"a.b":null}'
        'an array value'       = '{"a.b":["x"]}'
        'an upper case key'    = '{"A.b":"x"}'
        'a key with a space'   = '{"a b":"x"}'
        'a key with a hyphen'  = '{"a-b":"x"}'
        'a key with a path'    = '{"..\\x":"x"}'
        'an array as the file' = '["a"]'
        'a string as the file' = '"a"'
        'broken JSON'          = '{"a.b":"x"'
    }
    foreach ($case in $bad.Keys) {
        $file = Join-Path $work 'bad.json'
        [IO.File]::WriteAllText($file, $bad[$case], (New-Object Text.UTF8Encoding $false))
        Test-Check "the loader refuses $case" (Test-Throws { [void](Read-AVDTuneStringFile $file) }) $null
    }
    $big = Join-Path $work 'big.json'
    [IO.File]::WriteAllText($big, ('{"a.b":"' + ('x' * 600KB) + '"}'), (New-Object Text.UTF8Encoding $false))
    Test-Check 'the loader refuses a file that is too big' (Test-Throws { [void](Read-AVDTuneStringFile $big) }) $null
    $long = Join-Path $work 'long.json'
    [IO.File]::WriteAllText($long, ('{"a.b":"' + ('x' * 5000) + '"}'), (New-Object Text.UTF8Encoding $false))
    Test-Check 'the loader refuses a text that is too long' (Test-Throws { [void](Read-AVDTuneStringFile $long) }) $null
    $good = Join-Path $work 'good.json'
    [IO.File]::WriteAllText($good, "{`"a.b`":`"Gr$([char]0x00FC)n {0}`",`"c`":`"d`"}", (New-Object Text.UTF8Encoding $false))
    $table = Read-AVDTuneStringFile $good
    Test-Check 'the loader reads a valid file (UTF-8, umlauts kept)' ($table.Count -eq 2 -and $table['a.b'] -ceq "Gr$([char]0x00FC)n {0}") $null
    Test-Check 'a text is never run: a text that looks like code stays a string' ((@('{"a.b":"$(Get-Date)"}') | ForEach-Object { [IO.File]::WriteAllText($good, $_, (New-Object Text.UTF8Encoding $false)); (Read-AVDTuneStringFile $good)['a.b'] }) -ceq '$(Get-Date)') $null
    Test-Check 'an invalid file is not used: Initialize keeps English alone and names the problem' ((Initialize-AVDTuneLanguage -Folder $work).Problems.Count -eq 2) $null
    # the whole file is dropped, the start goes on: broken en and de files -> hard English text for the security messages, never the bare key
    $longKey = '{"' + ('a' * 101) + '":"x"}'
    foreach ($case in @(@('broken JSON', '{"a.b":"x"'), @('a non-string value', '{"shell.err.admin":5}'), @('a nested object', '{"shell.err.admin":{"x":"y"}}'), @('a key that is too long', $longKey), @('a value that is too long', ('{"shell.err.admin":"' + ('x' * 5000) + '"}')), @('a file that is too big', ('{"a.b":"' + ('x' * 600KB) + '"}')))) {
        foreach ($l in 'en', 'de') { [IO.File]::WriteAllText((Join-Path $work "Strings.$l.json"), $case[1], (New-Object Text.UTF8Encoding $false)) }
        $r = Initialize-AVDTuneLanguage -Folder $work
        Set-AVDTuneLanguage 'de'
        $admin = Get-AVDTuneText 'shell.err.admin'
        Test-Check "both files with $($case[0]): discarded as a whole, start goes on, hard English message for administrator, aside and read-only" ($r.Problems.Count -eq 2 -and $r.Keys.en -eq 0 -and $r.Keys.de -eq 0 -and $admin -like 'AVDTune changes the Golden Master*' -and (T 'shell.aside' 'C:\s' 'p' 'q') -like 'The state folder C:\s had been prepared*' -and (T 'shell.readonly') -like 'Read only:*' -and (T 'nav.overview') -ceq 'nav.overview') ($r.Problems -join '; ')
    }
    [void](Initialize-AVDTuneLanguage -Folder (Join-Path $repo 'UI'))

    # ---------------------------------------------------------------- the lookup
    Set-AVDTuneLanguage 'en'
    Test-Check 'lookup in English' ((Get-AVDTuneText 'nav.overview') -ceq 'Overview') $null
    Set-AVDTuneLanguage 'de'
    Test-Check 'lookup in German' ((Get-AVDTuneText 'nav.overview') -ceq "$([char]0x00DC)bersicht" -and (T 'nav.updateblock') -ceq 'Update-Sperre') $null
    Test-Check 'format arguments fill {0} {1}' ((T 'rel.install.in' '1.2.3' 'C:\x') -ceq '1.2.3 in C:\x installieren') (T 'rel.install.in' '1.2.3' 'C:\x')
    Test-Check 'without arguments braces stay as they are' ((T 'stage.env.snapname') -like '*{OsDisk}*') $null
    Test-Check 'a wrong format string does not throw' ((T 'rel.install.in' '1.2.3') -is [string]) $null
    Test-Check 'a list argument is joined with spaces (as in "$list"), a missing one stays empty in its place' ((T 'rel.install.in' @('a', 'b') 'C:\x') -ceq 'a b in C:\x installieren' -and (T 'rel.install.in' $(if ($false) { 'x' }) 'C:\x') -ceq ' in C:\x installieren') (T 'rel.install.in' @('a', 'b') 'C:\x')
    $saved = $script:LangTexts.de['nav.overview']; [void]$script:LangTexts.de.Remove('nav.overview')
    Test-Check 'a key that German lacks falls back to English' ((Get-AVDTuneText 'nav.overview') -ceq 'Overview') $null
    $script:LangTexts.de['nav.overview'] = $saved
    Test-Check 'a key that no language has shows the key' ((Get-AVDTuneText 'no.such.key') -ceq 'no.such.key') $null
    Test-Check 'engine text: a fixed English message is shown in German, a message with data stays' ((Convert-AVDTuneEngineText 'health.detail.' 'No restart is waiting.') -ceq 'Es wartet kein Neustart.' -and (Convert-AVDTuneEngineText 'health.detail.' 'Waiting for a restart: servicing.') -ceq 'Waiting for a restart: servicing.' -and (Get-AVDTuneEngineText 'task.status.succeeded' 'Done') -ceq 'Fertig') $null
    Set-AVDTuneLanguage 'en'
    Test-Check 'engine text in English is returned as it is' ((Convert-AVDTuneEngineText 'health.detail.' 'No restart is waiting.') -ceq 'No restart is waiting.') $null

    # ---------------------------------------------------------------- the shell asks only for keys that exist
    $shellFiles = 'Start-AVDTune.ps1', 'AVDTune-Start.ps1', 'AVDTune-Release.ps1', 'AVDTune-Readiness.ps1', 'AVDTune-TaskBar.ps1'
    $nonKey = '\.(json|ps1|psm1|xaml|txt|md|exe|zip|html|lnk)\z'
    $asked = New-Object System.Collections.Generic.HashSet[string]
    foreach ($f in $shellFiles) {
        $code = [IO.File]::ReadAllText((Join-Path $repo $f))
        foreach ($m in [regex]::Matches($code, "'([a-z][a-z0-9]*(?:\.[a-z0-9]+)+)'")) { if ($m.Groups[1].Value -notmatch $nonKey) { [void]$asked.Add($m.Groups[1].Value) } }
    }
    $unknown = @($asked | Where-Object { -not $en.ContainsKey($_) -and $_ -notmatch '^(microsoft|ov|readiness)\.' } | Sort-Object)
    Test-Check 'every key that the shell code asks for exists in the language files' ($unknown.Count -eq 0 -and $asked.Count -gt 150) (($unknown -join ', ') + " ($($asked.Count) keys asked)")
    $dynamic = @('nav.', 'status.', 'task.status.', 'stage.pill.', 'stage.btn.', 'ready.pill.', 'rel.pill.', 'ov.row.')
    foreach ($prefix in $dynamic) { Test-Check "keys of the pattern $prefix* exist" (@($en.Keys | Where-Object { $_.StartsWith($prefix) }).Count -ge 3) $null }
    $pages = @('Overview', 'Setup', 'Updates', 'Software', 'Office', 'Optimization', 'FSLogix', 'Environment', 'AppMasking', 'VdiComponents', 'UserExperience', 'UpdateBlock', 'Benchmark', 'Seal', 'Protocol')
    Test-Check 'every page of the navigation has a title in both languages' (@($pages | Where-Object { -not $en.ContainsKey("nav.$($_.ToLowerInvariant())") -or -not $de.ContainsKey("nav.$($_.ToLowerInvariant())") }).Count -eq 0) $null

    # ---------------------------------------------------------------- the XAML: Uid elements and no fixed text in the translated areas
    [xml]$xaml = [IO.File]::ReadAllText((Join-Path $repo 'UI\AVDTune.xaml'))
    $uids = @($xaml.SelectNodes("//*[@*[local-name()='Uid']]"))
    $uidMissing = @($uids | ForEach-Object { $u = $_.GetAttribute('Uid'); if (-not ($en.ContainsKey($u) -or $en.ContainsKey("$u.name") -or $en.ContainsKey("$u.tip"))) { $u } })
    Test-Check 'every Uid of the XAML has a text, a name or a tooltip in the language files' ($uids.Count -gt 50 -and $uidMissing.Count -eq 0) ($uidMissing -join ', ')
    $uidBadPattern = @($uids | Where-Object { -not ((Test-AVDTuneTextKey $_.GetAttribute('Uid')) -and $_.GetAttribute('Uid').Contains('.')) })
    Test-Check 'every Uid is a key (lower case, dotted)' ($uidBadPattern.Count -eq 0) $null
    $literal = { param($node) foreach ($a in 'Text', 'Content', 'ToolTip', 'AutomationProperties.Name') { $v = $node.GetAttribute($a); if ($v -and $v -match '\p{L}' -and $v -ne 'AVDTune') { "$($node.LocalName)[$($node.GetAttribute('Name'))] $a=$v" } } }
    $uidLiterals = @($uids | ForEach-Object { & $literal $_ })
    Test-Check 'elements with a Uid carry no fixed text in the XAML' ($uidLiterals.Count -eq 0) ($uidLiterals -join '; ')
    $regions = @($xaml.SelectNodes("//*[@*[local-name()='Name']='PageOverview' or @*[local-name()='Name']='PageProtocol' or @*[local-name()='Name']='BoxTaskBar' or @*[local-name()='Name']='BoxTaskList' or @*[local-name()='Name']='BoxReadOnly' or @*[local-name()='Name']='NavList']"))
    $regions += @($xaml.SelectNodes("//*[@*[local-name()='Name']='RootGrid']/*/*[@Grid.Row='0']") | Where-Object { $_ })
    $regionLiterals = @($regions | ForEach-Object { $_.SelectNodes('descendant-or-self::*') } | ForEach-Object { & $literal $_ })
    Test-Check 'the translated regions of the XAML (title row, overview, protocol, task bar and list, banner) have no fixed text' ($regions.Count -ge 6 -and $regionLiterals.Count -eq 0) (($regionLiterals | Select-Object -First 5) -join '; ')

    # ---------------------------------------------------------------- the shell code: no fixed text of a translated key (sample)
    $literals = @($shellFiles | ForEach-Object { [System.Management.Automation.PSParser]::Tokenize([IO.File]::ReadAllText((Join-Path $repo $_)), [ref]$null) } | Where-Object { $_.Type -eq 'String' } | ForEach-Object { $_.Content })   # string literals only: comments may name a card
    $engineKept = '^(health\.|stage\.detail\.|stage\.title\.)'   # these are compared with the English text of the engine modules
    $sample = @($en.GetEnumerator() | Where-Object { $_.Value.Length -ge 24 -and $_.Value -notmatch '[{}\r\n]' -and $_.Key -notmatch $engineKept -and $_.Key -notmatch '^(nav\.|ready\.group\.)' })   # nav.*: the English titles of the page table are the fallback; ready.group.*: the engine's group names
    $stillFixed = @($sample | Where-Object { $v = $_.Value; @($literals | Where-Object { $_.Contains($v) }).Count -gt 0 } | ForEach-Object { $_.Key })
    Test-Check 'no English text of a key is left as fixed text in the shell code' ($sample.Count -gt 80 -and $stillFixed.Count -eq 0) (($stillFixed | Select-Object -First 8) -join ', ')
    $page = [IO.File]::ReadAllText((Join-Path $repo 'Start-AVDTune.ps1'))
    Test-Check 'ProtocolLanguage follows the one switch (no separate protocol language box any more)' ($page -notmatch 'CmbProtocolLanguage' -and $page -match 'ProtocolLanguage = \$script:Settings\.Language' -and $page -match 'Add-Click \$ui\.BtnLang') $null
    Test-Check 'the settings file keeps ProtocolLanguage for older versions and gets Language' ($page -match 'Language = \$script:Settings\.Language; ProtocolLanguage = \$script:Settings\.Language') $null
    Test-Check 'a switch registers the tree again (pages with their own XAML or made in code) before it sets the texts' ($page -match '(?s)function Update-Localized \{.{0,400}Register-AVDTuneLocalized \$window\)\s+Update-AVDTuneLocalized' -and $page -match "AVDTune-Language\.ps1'\)[^\r\n]*\r?\n\[void\]\(Register-AVDTuneLocalized \`$window\); Update-AVDTuneLocalized") $null

    # ---------------------------------------------------------------- the pages (#70 step 2): every key asked exists, no fixed UI text left (AST), no fixed text in any XAML
    $pageFiles = 'AVDTune-AppMasking.ps1', 'AVDTune-Benchmark.ps1', 'AVDTune-Custom.ps1', 'AVDTune-CustomSoftware.ps1', 'AVDTune-Environment.ps1', 'AVDTune-FSLogix.ps1', 'AVDTune-Language.ps1', 'AVDTune-Office.ps1',
        'AVDTune-Optimization.ps1', 'AVDTune-Printers.ps1', 'AVDTune-Seal.ps1', 'AVDTune-Software.ps1', 'AVDTune-Updates.ps1', 'AVDTune-UserExperience.ps1', 'AVDTune-Vdi.ps1', 'AVDTune-SharePoint.ps1', 'AVDTune-Protocol.ps1'
    $textCommands = 'T', 'Get-AVDTuneText', 'Set-AVDTuneUid', 'Get-AVDTuneEngineText'
    $uiProps = 'Text', 'Content', 'ToolTip', 'Header', 'Title'
    $uiHelper = '\A(New-(?!Object\z|Item\z|AVDTune)[A-Za-z]+|Confirm-Action|Show-[A-Za-z]*(Dialog|Message)[A-Za-z]*)\z'
    $prose = '[A-Za-z]{2,}[ ,.:;!?()''/-]+[A-Za-z]{2,}'
    $staticOf = {
        # the fixed part of a string: a constant as it is, an expandable string without its $variables and $( ) parts
        param($ast)
        if ($ast -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $ast.Value }
        $v = $ast.Extent.Text; $base = $ast.Extent.StartOffset
        foreach ($n in @($ast.NestedExpressions | Sort-Object { $_.Extent.StartOffset } -Descending)) { $v = $v.Remove($n.Extent.StartOffset - $base, $n.Extent.EndOffset - $n.Extent.StartOffset).Insert($n.Extent.StartOffset - $base, ' ') }
        $v
    }
    $isString = { param($ast) ($ast -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $ast.StringConstantType -ne 'BareWord') -or $ast -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }   # bare words are member and key names
    $pageAsked = New-Object System.Collections.Generic.HashSet[string]
    foreach ($f in $pageFiles) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $f), [ref]$null, [ref]$null)
        $found = New-Object System.Collections.Generic.List[string]
        foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $cmd.GetCommandName()
            $args1 = @($cmd.CommandElements | Select-Object -Skip 1)
            if ($name -in $textCommands) { foreach ($e in $args1) { if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $e.Value -match '\A[a-z0-9]+(\.[a-z0-9]+)+\z') { [void]$pageAsked.Add($e.Value) } }; continue }
            $helper = ($name -and $name -match $uiHelper) -or ($cmd.InvocationOperator -eq 'Ampersand' -and $cmd.CommandElements[0] -is [System.Management.Automation.Language.VariableExpressionAst])
            if ($helper) { foreach ($e in $args1) { if ((& $isString $e) -and (& $staticOf $e) -match $prose) { $found.Add("$($e.Extent.StartLineNumber): $($e.Extent.Text)") } } }
        }
        foreach ($as in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.MemberExpressionAst] }, $true)) {
            if ([string]$as.Left.Member.Value -notin $uiProps) { continue }
            foreach ($s in $as.Right.FindAll({ param($n) (& $isString $n) }, $true)) {
                $p = $s.Parent; $inCommand = $false
                # not a text of its own: an argument of a command or of a method (ToString('yyyy-MM-dd')), an operand of a comparison
                while ($p -and $p -ne $as) { if ($p -is [System.Management.Automation.Language.CommandAst] -or $p -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -or ($p -is [System.Management.Automation.Language.BinaryExpressionAst] -and $p.Operator -notin 'Format', 'Plus')) { $inCommand = $true; break }; $p = $p.Parent }
                if (-not $inCommand -and (& $staticOf $s) -match '[A-Za-z]{3,}') { $found.Add("$($s.Extent.StartLineNumber): $($s.Extent.Text)") }
            }
        }
        foreach ($im in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -match '(MessageBox|AutomationProperties)\]\z' -and [string]$n.Member.Value -in 'Show', 'SetName' }, $true)) {   # message boxes and automation names
            foreach ($e in @($im.Arguments)) { if ((& $isString $e) -and (& $staticOf $e) -match $prose) { $found.Add("$($e.Extent.StartLineNumber): $($e.Extent.Text)") } }
        }
        Test-Check "$f has no fixed UI text left (texts of elements, helpers that make elements, message boxes)" ($found.Count -eq 0) ((@($found) | Select-Object -First 6) -join ' | ')
    }
    $pageUnknown = @($pageAsked | Where-Object { -not ($en.ContainsKey($_) -or $en.ContainsKey("$_.tip") -or $en.ContainsKey("$_.name")) } | Sort-Object)
    Test-Check 'every key that the pages ask for (T, Set-AVDTuneUid, Get-AVDTuneEngineText) exists in the language files' ($pageUnknown.Count -eq 0 -and $pageAsked.Count -gt 300) (($pageUnknown -join ', ') + " ($($pageAsked.Count) keys asked)")
    $pageLiterals = @($pageFiles | ForEach-Object { [System.Management.Automation.PSParser]::Tokenize([IO.File]::ReadAllText((Join-Path $repo $_)), [ref]$null) } | Where-Object { $_.Type -eq 'String' } | ForEach-Object { $_.Content })
    $pageSample = @($en.GetEnumerator() | Where-Object { $_.Value.Length -ge 24 -and $_.Value -notmatch '[{}\r\n]' -and $_.Key -notmatch '^(health\.|stage\.|nav\.|ready\.group\.)' })
    $logicValues = 'Nobody except administrators', 'Custom (set in the Rule Editor)'   # the visibility modes of the App Masking module: values in the code, shown through cust.vis.* and mask.vis.*
    $pageStill = @($pageSample | Where-Object { $v = $_.Value; $v -notin $logicValues -and @($pageLiterals | Where-Object { $_.Contains($v) }).Count -gt 0 } | ForEach-Object { $_.Key })
    Test-Check 'no English text of a key is left as fixed text in the page code' ($pageStill.Count -eq 0) (($pageStill | Select-Object -First 8) -join ', ')
    foreach ($xf in 'AVDTune.xaml', 'Software.xaml', 'Vdi.xaml', 'AVDTune.Environment.xaml') {
        [xml]$px = [IO.File]::ReadAllText((Join-Path $repo "UI\$xf"))
        $fixed = @($px.SelectNodes('//*') | ForEach-Object { $n = $_; foreach ($a in 'Text', 'Content', 'ToolTip', 'Header', 'Title', 'AutomationProperties.Name') { $v = $n.GetAttribute($a); if ($v -and $v -notmatch '\A\{' -and $v -match '[A-Za-z]{2,}' -and $v -cne 'AVDTune') { "$($n.LocalName)[$($n.GetAttribute('Name'))] $a=$v" } } })
        Test-Check "UI\$xf has no fixed text (every text through a Uid key)" ($fixed.Count -eq 0) ((@($fixed) | Select-Object -First 6) -join '; ')
        $pu = @($px.SelectNodes("//*[@*[local-name()='Uid']]") | ForEach-Object { $u = $_.GetAttribute('Uid'); if (-not ((Test-AVDTuneTextKey $u) -and $u.Contains('.') -and ($en.ContainsKey($u) -or $en.ContainsKey("$u.name") -or $en.ContainsKey("$u.tip")))) { $u } })
        Test-Check "UI\$xf : every Uid is a key with a text" ($pu.Count -eq 0) ($pu -join ', ')
    }

    # ---------------------------------------------------------------- Uid elements in WPF (STA runspace: WPF needs it)
    $wpf = {
        param($Repo)
        $ErrorActionPreference = 'Stop'
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        . (Join-Path $Repo 'AVDTune-UiText.ps1')
        [void](Initialize-AVDTuneLanguage -Folder (Join-Path $Repo 'UI'))
        $x = '<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><TextBlock x:Name="A" Uid="ov.title" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"/><Button Uid="ov.refresh"/><Button Uid="title.close" Content="X"/><TextBlock Uid="plain"/><TextBlock Uid="12"/></StackPanel>'
        $root = [Windows.Markup.XamlReader]::Load([System.Xml.XmlReader]::Create([IO.StringReader]::new($x)))
        $count = Register-AVDTuneLocalized $root
        $out = @{}
        $out.Count = $count
        Set-AVDTuneLanguage 'en'; Update-AVDTuneLocalized
        $out.En = @($root.Children[0].Text, $root.Children[1].Content, $root.Children[1].ToolTip, [Windows.Automation.AutomationProperties]::GetName($root.Children[1]), $root.Children[2].ToolTip, [Windows.Automation.AutomationProperties]::GetName($root.Children[2]))
        Set-AVDTuneLanguage 'de'; Update-AVDTuneLocalized
        $out.De = @($root.Children[0].Text, $root.Children[1].Content, $root.Children[1].ToolTip, [Windows.Automation.AutomationProperties]::GetName($root.Children[1]), $root.Children[2].ToolTip, [Windows.Automation.AutomationProperties]::GetName($root.Children[2]))
        $out.Plain = @($root.Children[3].Text, $root.Children[4].Text)
        $out
    }
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
    try {
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($wpf.ToString()).AddArgument($repo)
        $r = @($ps.Invoke()) | Select-Object -Last 1
        if ($ps.HadErrors) { throw $ps.Streams.Error[0].Exception.Message }
        Test-Check 'Register finds the elements with a dotted Uid (not "plain" or a number)' ($r.Count -eq 3) $r.Count
        Test-Check 'Update sets Text, Content, ToolTip and automation name in English' ($r.En[0] -ceq 'Overview' -and $r.En[1] -ceq 'Refresh' -and $r.En[3] -ceq 'Refresh the overview' -and $r.En[4] -ceq 'Close' -and $r.En[5] -ceq 'Close') ($r.En -join ' | ')
        Test-Check 'Update sets them again in German (switch without restart)' ($r.De[0] -ceq "$([char]0x00DC)bersicht" -and $r.De[1] -ceq 'Aktualisieren' -and $r.De[3] -ceq "$([char]0x00DC)bersicht aktualisieren" -and $r.De[4] -ceq "Schlie$([char]0x00DF)en") ($r.De -join ' | ')
        Test-Check 'an element with an unknown Uid keeps what it has' ([string]::IsNullOrEmpty($r.Plain[0]) -and [string]::IsNullOrEmpty($r.Plain[1])) $null
    }
    finally { $rs.Dispose() }
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
# #25 (2): the confirmation of the app setup names what it creates in the tenant (service principals of Azure Service Management and Azure Storage) and the
# Storage permission, in both languages, and the window shows exactly this key before the setup
$conf = @{}
foreach ($l in 'en', 'de') { $conf[$l] = [string]([IO.File]::ReadAllText((Join-Path $repo "UI\Strings.$l.json"), [Text.Encoding]::UTF8) | ConvertFrom-Json).'stage.signin.confirm' }
$startPage = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Start.ps1'))
Test-Check 'confirmation of the setup (#25): names the service principals of Azure Service Management and Azure Storage and Azure Storage user_impersonation (en, de); shown before the setup' ($conf.en -like '*creates the service principals*Azure Service Management and Azure Storage*' -and $conf.en -like '*Azure Storage user_impersonation*' -and $conf.de -like '*Dienstprinzipale*Azure Service Management und Azure Storage*' -and $conf.de -like '*Azure Storage user_impersonation*' -and $startPage -match "\`$setup -and -not \(Confirm-Action \(T 'stage\.signin\.confirm'") $null
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-UiText: all checks passed.'
