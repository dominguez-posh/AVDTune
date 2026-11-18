# Fakes that more than one runspace uses at the same time (#80): the GUI hands the fake machine and fake adapters to background workers in test mode.
# A closure from GetNewClosure() is bound to the session state of the runspace that made it; called from a worker at the same time it saw its
# variables as $null or hung (a cmdlet inside it ran in the other runspace). ConvertTo-AVDTuneFakeShared replaces every script block of a fake
# (members, nested tables, captured helpers) by an unbound one: it runs in the runspace of its caller, gets the values it captured from a static
# table ([AVDTuneFakeHub], same for all runspaces of the process) and runs under one process-wide lock, so two threads never change the store at once.
# Dot-sourced by every fake file; the factories end with ConvertTo-AVDTuneFakeShared.

if (-not ('AVDTuneFakeHub' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
public static class AVDTuneFakeHub {
    public static readonly object Gate = new object();
    static readonly ConcurrentDictionary<string, object> values = new ConcurrentDictionary<string, object>();
    public static string Put(object value) { string id = System.Guid.NewGuid().ToString("N"); values[id] = value; return id; }
    public static object Get(string id) { object v; return values.TryGetValue(id, out v) ? v : null; }
}
public sealed class AVDTuneFakeRef : IEqualityComparer<object> {
    public new bool Equals(object a, object b) { return ReferenceEquals(a, b); }
    public int GetHashCode(object o) { return RuntimeHelpers.GetHashCode(o); }
}
'@
}

$script:AVDTuneFakeSkipNames = @('_', 'PSItem', 'args', 'input', 'this', 'true', 'false', 'null', 'MyInvocation', 'PSBoundParameters', 'PSCmdlet', 'PSScriptRoot', 'PSCommandPath', 'ExecutionContext', 'Host', 'PID', 'Matches', 'LASTEXITCODE', 'Error', 'foreach', 'switch', 'sender', 'EventArgs', 'Event')

function ConvertTo-AVDTuneFakeSharedBlock {
    param([scriptblock]$Block, $Memo)
    $text = $Block.ToString()
    if ($text.Contains('[AVDTuneFakeHub]::Get(')) { return $Block }   # converted already
    $ast = $Block.Ast
    if ($ast.BeginBlock -or $ast.ProcessBlock -or $ast.DynamicParamBlock -or ($ast.EndBlock -and -not $ast.EndBlock.Unnamed)) { throw "fake: a script block with begin/process/dynamicparam cannot be shared: $text" }
    $src = $ast.Extent.Text; $start = $ast.Extent.StartOffset
    $braced = $null -ne $ast.Parent   # a literal { ... }: the extent has the braces
    $open = if ($braced) { 1 } else { 0 }; $close = if ($braced) { 1 } else { 0 }
    $paramEnd = if ($ast.ParamBlock) { $ast.ParamBlock.Extent.EndOffset - $start } else { $open }
    $paramText = $src.Substring($open, $paramEnd - $open)
    $body = $src.Substring($paramEnd, $src.Length - $close - $paramEnd)
    # the values the closure captured: every unqualified variable it reads that its module holds (not its parameters, not automatic ones)
    $params = @{}; if ($ast.ParamBlock) { foreach ($p in $ast.ParamBlock.Parameters) { $params[$p.Name.VariablePath.UserPath] = $true } }
    $vars = @{}
    if ($Block.Module) {
        foreach ($v in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            $path = $v.VariablePath
            if (-not $path.IsUnqualified -and -not $path.IsLocal) { continue }
            $name = $path.UserPath; if ($path.IsLocal) { $name = $name.Substring(6) }
            if ($vars.ContainsKey($name) -or $params.ContainsKey($name) -or $name -in $script:AVDTuneFakeSkipNames) { continue }
            $pv = $Block.Module.SessionState.PSVariable.Get($name)
            if (-not $pv) { continue }
            if (($pv.Options -band ([System.Management.Automation.ScopedItemOptions]::AllScope -bor [System.Management.Automation.ScopedItemOptions]::Constant)) -ne 0) { continue }
            $vars[$name] = ConvertTo-AVDTuneFakeSharedValue $pv.Value $Memo 0
        }
    }
    $id = [AVDTuneFakeHub]::Put($vars)
    # like a closure: no strict mode and the preferences of the global scope, not those of the caller (a module with Set-StrictMode, a check with Stop)
    $code = $paramText + "`r`n" +
    "Set-StrictMode -Off; `$ErrorActionPreference = `$global:ErrorActionPreference; `$WarningPreference = `$global:WarningPreference; `$VerbosePreference = `$global:VerbosePreference; `$DebugPreference = `$global:DebugPreference; `$ProgressPreference = `$global:ProgressPreference`r`n" +
    "`$__fakeVars = [AVDTuneFakeHub]::Get('$id'); foreach (`$__fakeName in `$__fakeVars.Keys) { `$ExecutionContext.SessionState.PSVariable.Set(`$__fakeName, `$__fakeVars[`$__fakeName]) }`r`n" +
    "[System.Threading.Monitor]::Enter([AVDTuneFakeHub]::Gate)`r`ntry {`r`n" + $body + "`r`n}`r`nfinally { [System.Threading.Monitor]::Exit([AVDTuneFakeHub]::Gate) }"
    [scriptblock]::Create($code)
}

function ConvertTo-AVDTuneFakeSharedValue {
    param($Value, $Memo, [int]$Depth)
    if ($null -eq $Value -or $Depth -gt 6) { return , $Value }
    $base = if ($Value -is [psobject]) { $Value.PSObject.BaseObject } else { $Value }
    if ($null -eq $base -or $base -is [string] -or $base -is [ValueType]) { return , $Value }
    if ($base -is [System.Management.Automation.PSCustomObject]) { $base = $Value }   # every PSCustomObject has the same BaseObject: the object itself is the key
    if ($Memo.ContainsKey($base)) { return , $Memo[$base] }
    if ($base -is [scriptblock]) { $Memo[$base] = $base; $new = ConvertTo-AVDTuneFakeSharedBlock $base $Memo; $Memo[$base] = $new; return $new }
    $Memo[$base] = $Value
    if ($base -is [System.Collections.IDictionary]) {
        foreach ($k in @($base.Keys)) { $old = $base[$k]; $new = ConvertTo-AVDTuneFakeSharedValue $old $Memo ($Depth + 1); if (-not [object]::ReferenceEquals($old, $new)) { $base[$k] = $new } }
    }
    elseif ($base -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in @($Value.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' })) { $old = $p.Value; $new = ConvertTo-AVDTuneFakeSharedValue $old $Memo ($Depth + 1); if (-not [object]::ReferenceEquals($old, $new)) { $p.Value = $new } }
    }
    elseif ($base -is [System.Collections.IList] -and -not $base.IsReadOnly) {
        for ($i = 0; $i -lt $base.Count; $i++) { $old = $base[$i]; if ($old -is [scriptblock] -or $old -is [System.Collections.IDictionary] -or $old -is [System.Management.Automation.PSCustomObject]) { $new = ConvertTo-AVDTuneFakeSharedValue $old $Memo ($Depth + 1); if (-not [object]::ReferenceEquals($old, $new)) { $base[$i] = $new } } }
    }
    , $Value
}

function ConvertTo-AVDTuneFakeShared {
    # Makes a fake usable from several runspaces at once (in place) and returns it.
    param($InputObject)
    $memo = New-Object 'System.Collections.Generic.Dictionary[object,object]' ([AVDTuneFakeRef]::new())
    ConvertTo-AVDTuneFakeSharedValue $InputObject $memo 0
}
