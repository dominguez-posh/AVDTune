using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;

namespace AVDTune.Bench;

/// <summary>Folder helpers for places that a started program can write to (round 2 follow-up review, N2 and N3): atomic creation with the final ACL, a search for links, and a delete that never
/// follows a link (the C# counterpart of Remove-AVDTuneFolderNoFollow).</summary>
public static class FolderTools
{
    [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes { public int Length; public IntPtr Descriptor; public int InheritHandle; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool CreateDirectoryW(string path, ref SecurityAttributes attributes);

    /// <summary>Makes ONE folder (the parent must exist) with the given security descriptor in a single CreateDirectory call. An existing folder, file or link of that name is an error (ERROR_ALREADY_EXISTS):
    /// there is no gap between "does it exist" and "make it" in which someone could prepare the folder.</summary>
    public static void CreateExclusive(string path, DirectorySecurity security)
    {
        byte[] sd = security.GetSecurityDescriptorBinaryForm();
        var pin = GCHandle.Alloc(sd, GCHandleType.Pinned);
        try
        {
            var sa = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), Descriptor = pin.AddrOfPinnedObject(), InheritHandle = 0 };
            if (!CreateDirectoryW(path, ref sa))
            {
                int e = Marshal.GetLastWin32Error();
                if (e == 183 || e == 80) throw new IOException("the folder exists already: " + path);   // ERROR_ALREADY_EXISTS / ERROR_FILE_EXISTS
                throw new Win32Exception(e, "CreateDirectory failed for " + path);
            }
        }
        finally { pin.Free(); }
    }

    /// <summary>The first link (junction, symbolic link, any reparse point) below the folder, or null. Links are reported, never followed.</summary>
    public static string? FindLink(string dir)
    {
        var root = new DirectoryInfo(dir);
        if (!root.Exists) return null;
        if ((root.Attributes & FileAttributes.ReparsePoint) != 0) return root.FullName;
        foreach (var e in root.EnumerateFileSystemInfos())
        {
            if ((e.Attributes & FileAttributes.ReparsePoint) != 0) return e.FullName;
            if (e is DirectoryInfo d && FindLink(d.FullName) is { } inner) return inner;
        }
        return null;
    }

    private static void GrantSelf(DirectoryInfo dir)
    {
        try
        {
            var me = System.Security.Principal.WindowsIdentity.GetCurrent().User;
            if (me == null) return;
            var s = dir.GetAccessControl();
            s.AddAccessRule(new FileSystemAccessRule(me, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            dir.SetAccessControl(s);
        }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException or InvalidOperationException) { }   // not the owner: the delete below reports what is not possible
    }

    /// <summary>Deletes a folder tree without ever entering a link: every element is looked at on its own (FindFirstFile data, which does not follow); a link is removed itself (RemoveDirectory or DeleteFile
    /// on the link, which acts on the reparse point and not on its target), a folder is emptied first, read-only flags are cleared. A missing path is fine.</summary>
    public static void RemoveNoFollow(string path)
    {
        var dir = new DirectoryInfo(path);
        if (!dir.Exists)
        {
            var f = new FileInfo(path);
            if (f.Exists) { try { f.Attributes = FileAttributes.Normal; } catch { } f.Delete(); }
            return;
        }
        if ((dir.Attributes & FileAttributes.ReparsePoint) != 0) { dir.Delete(); return; }   // the link itself, not its content
        GrantSelf(dir);   // a folder that was tightened to read-only for the user of the programs: its owner may still change its DACL, so a run without the Administrators group can clean up
        foreach (var e in dir.EnumerateFileSystemInfos().ToList())
        {
            if ((e.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                if (e is DirectoryInfo ld) ld.Delete(); else { try { e.Attributes = FileAttributes.Normal; } catch { } e.Delete(); }
            }
            else if (e is DirectoryInfo d) RemoveNoFollow(d.FullName);
            else { try { e.Attributes = FileAttributes.Normal; } catch { } e.Delete(); }
        }
        try { dir.Attributes = FileAttributes.Directory; } catch { }
        dir.Delete(false);
    }
}
