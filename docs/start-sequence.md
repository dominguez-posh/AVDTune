# Start sequence

Nothing changes the master before these four stages on the Overview are done. Plan: `docs/plans/avdtune.md`, sections 1a and 1b.

1. **First-run questions** (identity model, domain controller, profiles, network, tenant and client ID of the app registration). Saved in `C:\ProgramData\AVDTune\environment.json`, never a secret. The answers decide what follows: no domain controller means no domain step (groups come from Microsoft Entra ID); no FSLogix hides the FSLogix and App Masking pages. A later change goes into the change log.
2. **Microsoft 365 and Azure sign-in.** One sign-in through the shared sign-in module (`Shared\Modules\Keevault.psm1`, account from Keevault, embedded sign-in, authorization code with PKCE). The refresh token gives three access tokens, each with only its own permission. Tokens are kept in memory as SecureStrings, never written, removed when the window closes and by "Sign out"; `Test-AVDTuneSessionClear` proves it before seal.
3. **Domain controller** (only with a domain controller). IP or name and a domain account; LDAPS 636 first. The first contact shows the certificate (SHA-256 and SHA-1 thumbprint) and sends nothing until it is pinned for this environment. A changed certificate stops the connection (no fallback); replacing a pin is a separate confirmed action in the change log. LDAP 389 is used only when 636 does not answer and the server was never seen with LDAPS, and only with Negotiate signing and sealing. A simple bind in clear text does not exist in the code. AVDTune reads RootDSE (DNS name, NetBIOS name, naming contexts, functional levels), the site of the DC, the OU tree and groups with their SIDs. The password stays in a SecureString and is cleared after the read.
4. **Snapshot gate.** The VM finds itself through the instance metadata service (subscription, resource group, VM, OS disk). "Create snapshot now" makes an incremental snapshot `<vm>-avdtune-<image version>-<yyyyMMdd-HHmm>` with tags ImageVersion, CreatedBy and CreatedWith=AVDTune. A finished snapshot of this OS disk from today is confirmed by typing the full name (it must match the signed-in account). Name, time, snapshot ID and "created by AVDTune: yes/no" go into the protocol, the change log and `state.json` (`SnapshotGate`). The engine refuses every change of the master (Apply and Undo, not dry runs) until the gate is open; it is held in memory only, so every start begins closed.

## Permissions of the app registration

The app registration is the one PackTune uses (public client, redirect `http://localhost`); AVDTune does not create or change it. These delegated permissions need admin consent:

| Token | Resource | Delegated permissions |
|---|---|---|
| Graph | Microsoft Graph | `Group.Read.All`, `DeviceManagementApps.Read.All` |
| Sites | Microsoft Graph | `Sites.Selected` (plus the one-time site grant as in PackTune) |
| Arm | Azure Service Management (`797f4846-ba00-4fd7-ba43-dac1f8f63013`) | `user_impersonation` |

`offline_access` is needed for the refresh token. `Group.ReadWrite.All` (Entra groups) comes in phase 3 and only for that action. In Azure the signed-in account needs, on the resource group of the VM, a role with `Microsoft.Compute/snapshots/read` and `write` and `Microsoft.Compute/disks/read` (for example Disk Snapshot Contributor on the resource group, plus Reader on the disk). A missing role or consent is named in the message.

The embedded sign-in loads the WebView2 SDK, downloaded once from NuGet by the shared module (Microsoft signature checked) into `C:\ProgramData\AVDTune\WebView2` (Administrators and SYSTEM only).

## Checks

`Tests\Check-Start.ps1` runs the whole sequence against fakes (`Tests\Fakes\FakeServices.ps1`): no network, 403 (missing role), consent missing, tenant mismatch, changed LDAPS certificate, no downgrade of a pinned DC, no snapshot of today, snapshot that fails. `Tests\Invoke-GuiSmoke.ps1` drives the window through all four stages and writes screenshots.
