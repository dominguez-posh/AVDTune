# Test on a throwaway VM

Everything in AVDTune is checked against fakes first. This guide is for the real runs on a throwaway VM. Never run it on a real Golden Master or a developer machine. Write down what you see; the result goes back into the issues.

## 1. The VM

- Azure, a test subscription and resource group.
- Image: Windows 11 Enterprise multi-session 25H2 + Microsoft 365 Apps from the Marketplace (`microsoftwindowsdesktop` / `office-365` / the current `win11-25h2-avd-m365` SKU), Generation 2, Trusted Launch.
- Size: a current v6 or v7 size with NVMe if available in the region (tests the readiness check), otherwise any D-size.
- Not joined to a domain or to Microsoft Entra ID (like a real master). Connect through Azure Bastion with the local admin.
- Optional for later tests: a reachable domain controller (LDAPS on 636 with a certificate) and an Azure Files share for FSLogix.
- Make one snapshot of the OS disk right after the deployment, so the VM can be reset.

## 2. Rights for the test

- The app registration that PackTune uses, with the delegated permissions of `docs/start-sequence.md` and admin consent.
- The account you sign in with in AVDTune: on the resource group of the VM a role with snapshot read/write and disk read (e.g. Disk Snapshot Contributor plus Reader).

## 3. Get AVDTune onto the VM

1. On the VM, download the repository as ZIP from GitHub (`main`), right click > Properties > Unblock, unpack to `C:\Program Files\AVDTune` (admin-only folder).
2. Start Windows PowerShell 5.1 **as administrator**: `powershell -ExecutionPolicy Bypass -File "C:\Program Files\AVDTune\Start-AVDTune.ps1"`.
3. Do not set `AVDTUNE_FAKE` or `AVDTUNE_ROOT`.

## 4. What to test and what to expect

| # | Step | Expected |
|---|---|---|
| 1 | First start | Window opens, first-run questions open by themselves; everything else read only. `C:\ProgramData\AVDTune` exists, owner Administrators, only Administrators and SYSTEM have rights. |
| 2 | Questions: Entra ID only, no DC, FSLogix on Azure Files | Domain step shows "skipped". |
| 3 | Sign in | Microsoft sign-in window, no password filled in by any tool. After sign-in no `PackTuneSignIn-*` folder left in `%TEMP%` of the admin. `C:\ProgramData\AVDTune\WebView2` holds only the three DLLs and `webview2-sdk.json`. |
| 4 | Snapshot gate: "Create snapshot now" | A snapshot `<OS disk>-DD.MM.YYYY-1` appears in the resource group with the tags. Confirm with first and last name; the pages unlock. Protocol and change log show typed name, Microsoft account and Windows account. |
| 5 | Overview | Source image, VM size, region, Windows build, Office build correct. Readiness card (once #3 is merged): NVMe, MANA, temp disk, Trusted Launch match the VM. |
| 6 | Update block: switch on | Settings > Windows Update shows no update page for a normal user; Office shows no update options; Edge update tasks disabled. Overview "Update block: on". |
| 7 | Updates: Search, then "Update all" | Windows, Office, Edge, Teams, OneDrive, Defender updated; results with KB and code in the change log. During the run: closing the window and signing out are blocked with a reason. After the run the update block is on again. |
| 8 | Crash test | Start an update run and end the PowerShell process in Task Manager. Start AVDTune again: it reports the open maintenance mode and repairs the update block. |
| 9 | Snapshot after changes | Try to confirm with the snapshot from step 4: refused (older than the last change). A new snapshot (10 minutes after the last change) is accepted. |
| 10 | Manipulated folder (optional, after a VM reset) | As a normal user create `C:\ProgramData\AVDTune` before the first start. AVDTune sets it aside as `AVDTune.untrusted-...`, says so, and starts fresh. |

## 5. What to send back

- Export of the protocol and the change log (page "Protocol and change log").
- `C:\ProgramData\AVDTune\logs\` (no secrets inside; check before sending).
- Screenshots of anything unexpected, with the step number.

After the test: delete the VM, its disks and snapshots.
