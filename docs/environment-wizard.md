# Environment wizard: automatic FSLogix storage setup

Issue 32, plan section 1b (phase 3). Code: `Modules\AVDTune.Environment.psm1`, page `AVDTune-Environment.ps1` with `UI\AVDTune.Environment.xaml`. Fake: `Tests\Fakes\FakeEnvArm.ps1`. Check: `Tests\Check-Environment.ps1`. The first-run questions themselves (`AVDTune.Start.psm1`, `docs\start-sequence.md`) are unchanged; this page takes their answers (identity model, endpoint, DNS) and plans the Azure side.

## What it does

1. **Identity model** (`Get-AVDTuneEnvIdentityModel`, from `AzureFilesAuth` of the first-run answers):

   | Model | ARM value | AVDTune | By hand (listed as steps, with the reason) |
   |---|---|---|---|
   | Microsoft Entra Kerberos (cloud-only or synchronized) | `AADKERB` | sets it on the account; hybrid identities: domain name and GUID | admin consent of the storage account app, Conditional Access exclusion (MFA gives error 1327), the cloud-only groups tag in the app manifest (cloud-only identities only) |
   | Microsoft Entra Domain Services | `AADDS` | sets it on the account | hosts must be joined to the managed domain |
   | AD DS | `AD` | nothing yet | computer account, Kerberos key, SPN, `activeDirectoryProperties` (no LDAP write path exists; issue 32, question 1) |

2. **Plan** (`Get-AVDTuneEnvPlan`): reads every resource with GET and compares it with the wish. Steps, in this order: storage account, SMB settings, share, private DNS zone, VNet link, private endpoint, DNS zone group, identity source, role assignment for the user group, role assignment for the admin group; then the deferred steps NTFS ACL, FSLogix on the master and test. Each step is Create, Update, None, Manual, Blocked or Deferred, carries the exact request body, the Learn source and whether Learn states it. The plan has a hash over what would be sent. Before it, the rights are checked (`Microsoft.Authorization/permissions` of the resource group: storage, network, DNS, `roleAssignments/write`, `subnets/join/action`); a missing action blocks the plan and names the action and why it is needed. A Contributor, for example, cannot write role assignments.
3. **Create** (`Invoke-AVDTuneEnvApply`): needs the open snapshot gate. The plan is built again and must have the hash the administrator confirmed; otherwise nothing is written. Resource by resource; an asynchronous operation is awaited (`Azure-AsyncOperation`, `Location`, `Retry-After`; without headers the resource is polled); first failure stops, the rest is Skipped. Existing resources are never replaced; an existing account that deviates gets a PATCH of only the deviating values (secure transfer, TLS 1.2, no blob public access, public network access), the old values are recorded. Kind and SKU of an existing account are never changed (a Standard account only gets the "not recommended for FSLogix" warning).
4. **Undo** (`Get-AVDTuneEnvUndoPlan`, `Invoke-AVDTuneEnvUndo`): works only from the journal `config\azure-setup.json`. A resource is deleted only if AVDTune created it in this journal, it still exists and (where Azure allows tags) carries `CreatedWith=AVDTune`. Reverse order. The share and the account only when the share is verified empty over the data plane (needs the storage token); no token or a profile folder in the share means Keep. The private DNS zone stays when it holds other record sets. Updates of an existing account are restored from the recorded values; settings of an account that is deleted are covered by that. A new confirmation of the undo plan hash is needed.
5. **Master and test**: `Set-AVDTuneEnvMaster` writes `Enabled=1` and `VHDLocations` through the existing FSLogix settings steps (gate, run record, change log, undo of the FSLogix page) and, for Entra Kerberos, `CloudKerberosTicketRetrievalEnabled=1` (`HKLM\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters`, Learn: Entra Kerberos, registry key tab). `Get-AVDTuneEnvAclDiff` shows the NTFS diff with the existing ACL logic (group object IDs become `S-1-12-1-...`); setting it stays `Set-AVDTuneStorageRootAcl` with its confirmed hash. `Invoke-AVDTuneEnvVerify` runs the existing storage check for the new share.

## Rules this code keeps (docs\security-checklist.md)

| Point | How |
|---|---|
| Path segments from data validated | Names go through `Test-AVDTuneEnvSpec` (`[A-Za-z0-9._()-]`, storage and share name rules, GUIDs); `Assert-AVDTuneEnvArmPath` checks again at the request: one `?`, no `#`, no `..`, only `api-version` for writes |
| ARM only through the adapter, allowlist | Every request goes through `New-AVDTuneArmAdapter` (host fixed, no redirects). This module allows PUT, PATCH, DELETE only for eight resource types with their api version; POST (listKeys, regenerateKey) never |
| Tokens only to their host, no redirects followed | Polling links are absolute URLs: only `https://management.azure.com/subscriptions/...` is followed (`ConvertTo-AVDTuneArmPath`), anything else fails the step |
| Secrets | The module has no key call, no HTTP client; the token is a parameter, never in the plan, journal, change log, run record or a message (checked by scanning the files) |
| Write gate and LastChange | Apply and undo throw without the gate and need the confirmed plan hash. Azure resources do not set `LastChange` (not in the OS disk snapshot; their way back is the journal undo, user decision, issue 32); the master part (`Set-AVDTuneEnvMaster`: Enabled, VHDLocations, CloudKerberosTicketRetrievalEnabled) sets it before writing, also when a write fails. Change log entries of Azure steps have the category Azure, which `Get-AVDTuneLastChange` ignores |
| Change log and undo | One entry per step (also for undo); undo works only on what the journal says AVDTune created, and never deletes data |
| Crash safety | The journal is written before and after every write (`Started`, `Done`, `Failed`) |
| Data is data | A journal entry that names another resource type produces no step and no request |

## Not verified (to try on a test tenant)

- The request shapes are written from the REST reference and not tried against Azure: storage account (api 2024-01-01, `networkAcls`, `defaultToOAuthAuthentication`), file service SMB settings by PUT (whether properties that are not sent stay unchanged is not stated; only the `smb` block is sent), share (`accessTier` Premium), private endpoint and zone group (api 2023-11-01), private DNS zone and link (2020-06-01), role assignments (2022-04-01). The fake gives the answers Azure gave in earlier work (201/202, `Azure-AsyncOperation` for network and DNS, `Location` for the storage account, 400, 403, 409), but it is a fake.
- Premium IOPS and throughput (3000 + 1 per GiB, 100 + 0.1 MiB/s per GiB) are the formula of the Learn billing page and shown as an estimate.
- Role propagation after the role assignments can take minutes; the NTFS step is separate for that reason.
- `LoadCredKeyFromProfile` from plan section 1b is not on the Entra Kerberos page of Learn and is not set.
- The page runs plan, create and undo on the window thread behind a task in the bar (like the changes of the FSLogix page): the window waits while Azure works. A background runspace is a follow-up.

## Real test (throwaway tenant, after docs\test-vm.md steps 1 to 4)

| # | Step | Expected |
|---|---|---|
| E1 | Environment page: fill in the fields, "Make the plan" | Rows as in the plan above; no resource exists in the portal yet; rights problems named |
| E2 | "Create the resources" after the snapshot gate | Account (Premium FileStorage, TLS 1.2, tag CreatedWith=AVDTune), SMB 3.1.1 settings, share with the quota, zone, link, endpoint with A record, identity AADKERB, two role assignments; change log entries; the second plan shows only "Exists" |
| E3 | Wrong name, name taken, Contributor only, subnet in another region | Readable message per case, nothing half written without a journal entry |
| E4 | Storage check of the FSLogix page for the new share | Identity, SMB, private endpoint and DNS rows green; ACL rows need the storage token (issue 18) |
| E5 | "Show what can be taken back", "Take it back" | Endpoint, link, roles, zone group and (empty share, storage token) share and account are gone; a share with a folder stays |
