# AD DS identity of the storage account (design)

Issue 43, plan section 1b step 4. Azure Files with AD DS authentication needs an AD object that represents the storage account. Microsoft's AzFilesHybrid module (`Join-AzStorageAccount`) creates it from a domain joined client. The master is not domain joined and AVDTune loads no foreign module, so the environment wizard does the same steps itself: Azure Resource Manager through the ARM adapter, the domain controller through the pinned LDAPS connection of `Modules\AVDTune.Directory.psm1`.

Every statement below is marked **verified** (source, date the page was read) or **not verified** (written from knowledge; the value stands in one place in the code and is tried on the test VM, see the list at the end). All pages were read on 2026-11-18.

Sources:

| Key | Page | Page date |
|---|---|---|
| L-enable | learn.microsoft.com/azure/storage/files/storage-files-identity-ad-ds-enable, "Option two: Manually perform the enablement actions" | 2026-04-03 |
| L-pwd | learn.microsoft.com/azure/storage/files/storage-files-identity-ad-ds-update-password | 2026-02-25 |
| R-list | REST reference Storage Accounts - List Keys, api 2026-09-01 | |
| R-regen | REST reference Storage Accounts - Regenerate Key, api 2026-09-01 | |
| R-update | REST reference Storage Accounts - Update, api 2026-09-01 | |
| ADTS | MS-ADTS 3.1.1.3.1.5.1 unicodePwd | 2026-05-21 |
| KILE | MS-KILE 2.2.7 Supported Encryption Types Bit Flags | 2026-04-27 |
| UAC | learn.microsoft.com/troubleshoot/windows-server/active-directory/useraccountcontrol-manipulate-account-properties | 2026-02-12 |
| PS-AD | learn.microsoft.com/powershell/module/activedirectory/set-adcomputer | 2016-12-27 |

## 1. The steps

The plan of the wizard gets three steps for the identity model AD DS, in this order, after the account, the SMB settings and the share:

| Step | Type | What |
|---|---|---|
| `env.adds-key` | `kerbkey` | Regenerate the Kerberos key `kerb1` of the account (ARM POST) |
| `env.adds-object` | `adobject` | Create the AD object in the chosen OU and set the key as its password (LDAPS) |
| `env.identity` | `identity` | PATCH of the account: `directoryServiceOptions = AD` with `activeDirectoryProperties` |

They exist only when the account has no identity source yet (`directoryServiceOptions` missing or `None`). `AD` already set: the three steps are "None" (nothing is regenerated: a new `kerb1` would break the working identity). Another source: Blocked, as today.

### 1.1 Kerberos key

| Statement | Status |
|---|---|
| `POST .../storageAccounts/{account}/regenerateKey?api-version=...` with the body `{ "keyName": "kerb1" }`; allowed names are `key1`, `key2`, `kerb1`, `kerb2` | verified (R-regen) |
| The answer is a `StorageAccountListKeysResult`: `keys[]` with `keyName`, `value` ("Base 64-encoded value of the key"), `permissions`, `creationTime` | verified (R-regen, R-list) |
| The answer to regenerating `kerb1` contains the `kerb1` entry | verified only by the sample "StorageAccountRegenerateKerbKey" of R-regen (keys `key1`, `key2`, `kerb1`); not stated as a rule. AVDTune takes `kerb1` from the answer and, if it is missing, asks `POST .../listKeys?api-version=...&$expand=kerb` (verified, R-list: `$expand` has the one value `kerb`) |
| The portal steps are `New-AzStorageAccountKey -KeyName kerb1`, then `Get-AzStorageAccountKey -ListKerbKey`; "Use this key only during setup. You can't use it for any control or data plane operations against the storage account." | verified (L-enable) |
| The module uses api version `2024-01-01` for storage (`$script:StorageApi`); the pages read are the 2026-09-01 reference | **not verified** that `kerb1` and `$expand=kerb` behave the same in 2024-01-01 |
| The call works on an account with `allowSharedKeyAccess = false` (what the wizard sets on a new account) | **not verified** |
| Length of the key (88 base64 characters for 64 bytes) | **not verified**; AVDTune only requires base64 text of 40 to 200 characters |

The plan never asks for the key (the plan is GET only). The answer of regenerateKey also carries `key1` and `key2`: AVDTune reads only the `kerb1` entry and drops the answer.

### 1.2 AD object

| Statement | Status |
|---|---|
| The object is "either a computer account or service logon account in AD DS under your OU", "use the key as the password for the AD identity"; computer account is the default | verified (L-enable) |
| SPN `cifs/<account>.file.core.windows.net` | verified (L-enable) |
| "Set the AD account password to the value of the kerb1 key": the base64 text itself is the password (`Set-ADAccountPassword ... -NewPassword (ConvertTo-SecureString -AsPlainText "kerb1_key_value_here")`) | verified (L-enable) |
| Type User: the UPN must be `cifs/<account>.file.core.windows.net@<UPN suffix>`, else error 1396 / KRB_AP_ERR_MODIFIED | verified (L-enable) |
| SamAccountName in Azure "without the trailing '$'"; 20 characters for a SAM name, 15 for a NetBIOS (computer) name | verified (L-enable; the limits stand only in the comments of the option one script) |
| Computer account passwords "don't expire in AD"; service logon account passwords can expire; an OU without password expiry is recommended | verified (L-enable, L-pwd) |
| `unicodePwd` over LDAP needs a connection with 128 bit TLS (or SASL sealing); the value is the password in double quotes, UTF-16 little endian, as an octet string; an administrative reset is a single **replace** | verified (ADTS) |
| `unicodePwd` inside the **Add** request | **not verified** (ADTS does not state it). AVDTune therefore does not use it: Add disabled, replace `unicodePwd`, enable |
| `userAccountControl`: ACCOUNTDISABLE 2, NORMAL_ACCOUNT 512, WORKSTATION_TRUST_ACCOUNT 4096, DONT_EXPIRE_PASSWORD 65536 | verified (UAC) |
| Computer: Add with 4098 (4096 + 2), enabled with 4096. User: Add with 514 (512 + 2), enabled with 66048 (512 + 65536) | values verified (UAC); **not verified** that a domain controller accepts exactly this sequence for a delegated account, and that DONT_EXPIRE_PASSWORD is what AzFilesHybrid sets for a service logon account |
| `-KerberosEncryptionType AES256` "sets the encryption types supported flags of the Active Directory msDS-SupportedEncryptionTypes attribute" | verified (PS-AD) |
| AES256-CTS-HMAC-SHA1-96 is bit E = 0x10 = 16 | **not verified** as a number: KILE gives bit letters, 16 is derived from the table layout (A = bit 0). One constant `AesEncryptionTypes = 16` |
| After `AES256` the key is regenerated and the password set again | verified for an existing object (L-enable). AVDTune sets `msDS-SupportedEncryptionTypes` in the Add, before the password, so the first password is set with it. **Not verified** that this order is enough (the storage check row `ad.enctype` and a mount on the test VM show it) |
| The July 2026 Windows update makes AES-256 the default instead of RC4 | verified (L-enable) |
| Rights in AD: "permissions to create a computer account or service logon account in the target AD (such as domain admin)" | verified (L-enable). **Not verified**: the smallest delegation in the OU (create and delete computer or user objects, reset password, write `userAccountControl`, `servicePrincipalName`, `msDS-SupportedEncryptionTypes`, `userPrincipalName`) |

The requests, all on one pinned LDAPS connection, in this order:

1. Search (subtree of the default naming context): an object with `sAMAccountName` = name or name + `$`, or with the SPN, or with the planned distinguished name. A hit ends the step: the name belongs to someone else (section 3, T6).
2. Add `CN=<sam>,<OU>`: `objectClass` (`computer` or `user`), `sAMAccountName` (`<sam>$` for a computer, `<sam>` for a user), `userAccountControl` (disabled), `servicePrincipalName`, `msDS-SupportedEncryptionTypes`, `description` ("Azure Files storage account <account> (AVDTune)"), for a user `userPrincipalName`. An Add never replaces: an object made by someone else in between gives `entryAlreadyExists` and nothing is changed.
3. Search (base, the new DN): `objectGUID`, `objectSid`, `whenCreated`, `sAMAccountName`. They go into the journal at once (section 4).
4. Modify: replace `unicodePwd` with the key.
5. Modify: replace `userAccountControl` (enabled).

The SAM name is the storage account name when it has at most 15 characters, else the administrator enters one (computer: 1 to 15, user: 1 to 20 characters, letters, digits and hyphen). The OU is one of the OUs read from the domain controller.

### 1.3 Storage account

| Statement | Status |
|---|---|
| `PATCH .../storageAccounts/{account}` with `properties.azureFilesIdentityBasedAuthentication` = `{ directoryServiceOptions: "AD", activeDirectoryProperties: { domainName, netBiosDomainName, forestName, domainGuid, domainSid, azureStorageSid, samAccountName, accountType } }` | verified (R-update, sample "StorageAccountEnableAD") |
| `directoryServiceOptions`: `None`, `AADDS`, `AD`, `AADKERB`; `accountType`: `User`, `Computer` | verified (R-update) |
| For AD the first six are required; `samAccountName` and `accountType` are optional and go together | verified (R-update) |
| `samAccountName` without `$` | verified for the cmdlet (L-enable); the REST page does not say it |
| Disable: `Set-AzStorageAccount -EnableActiveDirectoryDomainServicesForFile $false`; "consider deleting the AD DS identity ... it remains as an orphaned object" | verified (L-enable) |
| The REST form of the disable is `directoryServiceOptions = None` | **not verified** (the enum value is verified, the mapping of the cmdlet is not) |

Where the values come from (all read from the domain controller, none typed): `domainName` from `defaultNamingContext`, `forestName` from `rootDomainNamingContext`, `netBiosDomainName` from the crossRef in `CN=Partitions`, `domainGuid` and `domainSid` from `objectGUID` and `objectSid` of the domain object, `azureStorageSid` from `objectSid` of the new object (it must be the domain SID plus one RID, else nothing is sent).

## 2. Plan, hash, confirmation, journal

- The plan reads the account (GET) and the domain (LDAP searches) and shows the three steps with what would be sent: OU, CN, SAM name, type, SPN, UPN, `userAccountControl`, encryption types, the PATCH body. `azureStorageSid` does not exist before the object does; the plan shows a placeholder for it.
- The plan hash covers all of it and the domain controller with its pinned certificate hash. Apply builds the plan again and writes only with the confirmed hash, like every other step of the wizard. Another OU, name, type, domain controller or certificate is another hash.
- Apply needs the open snapshot gate and an unsealed version; the page takes the writer lock (`Enter-AVDTuneWriter`, `Assert-NoOtherWriter`) and runs it in a runspace of `New-AVDTunePowerShell`. Like the other Azure steps these three do not set `LastChange` (nothing on the master changes); each has a change log entry (category Azure) and a journal entry in `config\azure-setup.json`, written before and after the write.
- The three steps run as one unit inside the apply, because the key must not leave memory between them. If the key step fails, the other two are skipped. If the object step fails, the PATCH is skipped.
- Journal of the object step: distinguished name, SAM name, type, domain controller, and after the Add `ObjectGuid`, `Sid`, `WhenCreated` and `Created = true`. They are saved right after the Add, before the password is set, so a later failure still leaves an object the undo can prove to be its own. The journal has no key, no password, no token.

## 3. Threat model

| # | Threat | Answer |
|---|---|---|
| T1 | The Kerberos key leaks (file, journal, protocol, change log, run record, error text, UI) | The key exists only inside one function call. From the ARM answer it is turned at once into the `unicodePwd` byte array, which is overwritten with zeros in `finally`. No result object, journal entry, plan or message contains it; error texts of the key and password steps are fixed texts plus the LDAP result code, never the message of the server or the request. A check runs the whole flow and scans every file of the state folder, every result and every log of the fakes for the key (as text, as base64 of its bytes and as UTF-16). **Limit:** the ARM adapter returns parsed JSON, so the key exists once as a .NET string that cannot be overwritten; it is unreachable after the call and goes with the garbage collector. A SecureString would not change that (it would be built from that same string). |
| T2 | The key or the object goes to a machine that is not the domain controller | Writes exist only on a connection opened by `Open-AVDTuneDirectoryWriteSession`: LDAPS 636 with the pinned certificate. First contact (no pin), a changed certificate, LDAPS not answering and LDAP 389 (also the confirmed one) end with an error before anything is sent. The Directory module remembers the connections it opened this way; Add, Modify and Delete refuse every other handle. |
| T3 | AVDTune deletes an AD object that is not its own | Delete only for a journal entry with `Created = true` and an `ObjectGuid`. The object is looked up by that GUID, and it must still have the recorded SID, SAM name and creation time and carry the SPN of the storage account of that run. Anything else: kept, with the reason. An entry without a GUID (crash between Add and journal) is kept. |
| T4 | A forged journal makes the undo delete something | The journal is input. The conditions of T3 bind the delete to an object that is, by its own attributes on the domain controller, the identity of exactly this storage account; the distinguished name in the journal is never used for the delete. |
| T5 | An existing identity is broken | `kerb1` is regenerated only when the account has no identity source. With `AD` set nothing is written. |
| T6 | An object with the same name, SPN or DN exists | Plan: Blocked. Apply: the search runs again right before the Add; a hit ends the step, nothing is written to that object (no password reset, no SPN change). |
| T7 | Data from the domain controller or the journal ends up in a filter, a DN or a path | OU: must be one of the OUs the domain controller returned, and is checked as a DN (length, no control characters). SAM name `[A-Za-z0-9-]`. Filter values through `ConvertTo-AVDTuneLdapFilterValue`. GUID filter built from parsed bytes. SIDs must match `S-1-5-21-a-b-c(-rid)`. ARM paths through the allowlist. |
| T8 | The new POST opens the ARM allowlist | Exactly two POST paths: `regenerateKey` (body must be `{ keyName: kerb1 }`) and `listKeys` with `$expand=kerb`, both on the storage account of the plan. Everything else stays refused. |
| T9 | A crash in the middle | Journal `Started` before each write. Key regenerated only: harmless (the key is not in use). Object added but no GUID recorded: kept, named for removal by hand. Object recorded but PATCH missing: the next plan is Blocked by T6 and says to take the run back first. |
| T10 | Undo of the account settings | `env.identity` restores `directoryServiceOptions = None` (existing restore of the wizard), before the object is deleted (newest first). A regenerated key cannot be taken back and needs none (not in use after the disable). |

Not in scope: rotating the password (`kerb2`, L-pwd). A computer account does not expire; the user type gets DONT_EXPIRE_PASSWORD; the storage check already warns about an expiring password. Reusing an object of an earlier, failed run is not built either: take the run back, plan again.

## 4. Undo

| Journal entry | Undo |
|---|---|
| `env.identity` (Update, before `None`) | Restore: PATCH `directoryServiceOptions = None` |
| `env.adds-object` (Create) | Delete under the conditions of T3, on a pinned LDAPS session. Without a session (no account of the start sequence, server not pinned): Keep, with the reason |
| `env.adds-key` | Keep: a regenerated key cannot be taken back |

The undo plan has its own hash and confirmation, as today.

## 5. Not verified (test VM, throwaway tenant and domain)

Each value stands in one place (`$script:AdDs` in `AVDTune.Environment.psm1`, `$script:AdObjectTypes` in `AVDTune.Directory.psm1`).

| # | What | Where | How to try |
|---|---|---|---|
| N1 | `regenerateKey kerb1` and `listKeys $expand=kerb` with api 2024-01-01 | `$script:StorageApi` | step `env.adds-key` succeeds |
| N2 | regenerateKey with shared key access off | account body | new account of the wizard, then the key step |
| N3 | The answer of regenerateKey carries `kerb1` | fallback listKeys | either path ends with a password set |
| N4 | Add disabled, replace `unicodePwd`, enable: accepted for computer and user | `AdObjectTypes` | step `env.adds-object`, both types |
| N5 | `msDS-SupportedEncryptionTypes = 16` means AES256, and setting it in the Add is enough | `AesEncryptionTypes` | storage check row `ad.enctype`, mount from a session host, `klist` shows AES256 |
| N6 | DONT_EXPIRE_PASSWORD for the user type | `AdObjectTypes.User.Enabled` | compare with an object made by AzFilesHybrid |
| N7 | `samAccountName` without `$` in the REST body | plan body | `Debug-AzStorageAccountAuth` or the storage check |
| N8 | `directoryServiceOptions = None` disables AD DS | undo | undo, then the portal shows no identity source |
| N9 | Smallest OU delegation | docs | a delegated account instead of a domain admin |
| N10 | Length and alphabet of the key | key check (40 to 200 base64 characters) | step succeeds |
| N11 | Only the default naming context is searched for a duplicate SPN, not the forest | search | a multi domain forest |
