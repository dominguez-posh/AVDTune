// Native libraries are only loaded from System32 (issue #19): a DLL placed next to the exe or in the current folder is never picked up.
using System.Runtime.InteropServices;

[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
