# M365 User Lifecycle

![PowerShell 5.1 | 7.x](https://img.shields.io/badge/PowerShell-5.1%20%7C%207.x-5391FE?logo=powershell&logoColor=white)
![Microsoft Graph SDK](https://img.shields.io/badge/Microsoft%20Graph-PowerShell%20SDK-0078D4)
![Pester 5](https://img.shields.io/badge/tests-Pester%205-2ea44f)
![PSScriptAnalyzer clean](https://img.shields.io/badge/PSScriptAnalyzer-0%20findings-2ea44f)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

Joiner and leaver automation for Microsoft 365, driven by CSV, built on the **Microsoft Graph PowerShell SDK** and Exchange Online. It is a **dry run by default**, supports `-WhatIf`/`-Confirm`, is safe to re-run, and writes a per-step audit report.

## The problem

Onboarding and offboarding by hand is slow and inconsistent, and the mistakes cost real money. A new hire might start without the right groups, or a leaver's sessions might stay valid for days. A mailbox can get deleted because someone removed the license before converting it to shared. Or nobody remembers to give the manager the person's OneDrive. These steps are the same every time, so they belong in a script that shows you exactly what it will do before it does it.

## What it does

**Joiner** (`Invoke-MulJoiner`), per CSV row:

1. **Pre-flight (read-only):** resolves the license group, the extra groups, and the manager. If anything is missing, the row stops before any change is made.
2. **Create the user** (cloud-only) with a cryptographically random initial password that is never logged or returned. `ForceChangePasswordNextSignIn` is set. Hand out first sign-in through your usual process (for example a Temporary Access Pass).
3. **License via group:** adds the user to the license group (group-based licensing), then to the extra groups.
4. **Manager:** sets the manager reference.
5. **Mailbox settings:** sets the time zone and language. If the mailbox is still being provisioned after licensing, the step is marked `Pending`. Run the same CSV again later.

**Leaver** (`Invoke-MulLeaver`), per CSV row, in this order:

1. **Pre-flight:** user, delegate, and mailbox must resolve.
2. **Block sign-in.**
3. **Revoke sessions** (refresh tokens).
4. **Convert the mailbox to shared.**
5. **Auto-reply:** internal and external. A default message naming the delegate is built if the CSV doesn't supply one.
6. **Delegate access:** Full Access to the mailbox.
7. **OneDrive hand-off:** shares the OneDrive root with the delegate (edit rights, sign-in required).
8. **Remove licenses:** group-based licenses by removing the user from the licensing groups (found through `licenseAssignmentStates`), and direct assignments with `Set-MgUserLicense`.

**Idempotent:** if a user already exists, they're already in a group, sign-in is already blocked, or the mailbox is already shared, that step is `Skipped`. Re-running a CSV finishes what's left and doesn't duplicate anything. That also means the joiner can finish setup for accounts synced from on-premises AD: create the account in AD, let Entra Connect sync it, then run the same CSV.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.x
- Microsoft Graph PowerShell SDK: `Microsoft.Graph.Authentication`, `.Users`, `.Users.Actions`, `.Groups`, `.Files`
- `ExchangeOnlineManagement` (leaver only: shared mailbox, auto-reply, mailbox permission)
- Graph permissions. Delegated or application; review against least privilege:

  | Task | Permission |
  |---|---|
  | Create/update users, block sign-in, revoke sessions, manager | `User.ReadWrite.All` |
  | Group membership (license and access groups) | `GroupMember.ReadWrite.All` (or `Group.ReadWrite.All`) |
  | Direct license removal | `LicenseAssignment.ReadWrite.All` or `User.ReadWrite.All` |
  | Mailbox settings | `MailboxSettings.ReadWrite` |
  | OneDrive hand-off | `Files.ReadWrite.All` (app-only may also need `Sites.FullControl.All`) |

- Exchange Online: Recipient Management (or equivalent) for `Set-Mailbox`, `Set-MailboxAutoReplyConfiguration`, `Add-MailboxPermission`
- Group-based licensing configured on the license groups (requires Entra ID P1 or a license that includes it)

## Install

```powershell
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Users.Actions, Microsoft.Graph.Groups, Microsoft.Graph.Files -Scope CurrentUser
Install-Module ExchangeOnlineManagement -Scope CurrentUser
git clone https://github.com/john-harrington-it/m365-user-lifecycle.git
Import-Module ./m365-user-lifecycle/src/M365UserLifecycle/M365UserLifecycle.psd1
```

## CSV format

`joiners.csv` ([sample](examples/joiners.sample.csv))

| Column | Required | Notes |
|---|---|---|
| FirstName, LastName | yes | |
| UserPrincipalName | yes | validated format, no duplicates in the file |
| UsageLocation | yes | 2-letter country code (needed for licensing) |
| LicenseGroup | yes | display name of the group-based licensing group |
| DisplayName, MailNickname | no | default `First Last` / UPN prefix |
| Department, JobTitle, OfficeLocation | no | |
| Manager | no | manager UPN |
| Groups | no | semicolon-separated group display names |
| TimeZone, Locale | no | for example `Central Standard Time`, `en-US` |

`leavers.csv` ([sample](examples/leavers.sample.csv))

| Column | Required | Notes |
|---|---|---|
| UserPrincipalName | yes | |
| DelegateTo | no | receives mailbox Full Access and the OneDrive share; used in the default auto-reply |
| AutoReplyMessage | no | overrides the default auto-reply text |

Validate a file offline, without connecting: `Import-MulJoinerCsv -Path .\joiners.csv`. All row errors are reported at once.

## Usage

```powershell
Connect-MgGraph -Scopes User.ReadWrite.All, GroupMember.ReadWrite.All, MailboxSettings.ReadWrite, Files.ReadWrite.All
Connect-ExchangeOnline

# 1) Dry run (default): every lookup runs, nothing changes
Invoke-MulJoiner -Path .\joiners.csv
Invoke-MulLeaver -Path .\leavers.csv

# 2) Apply. Joiner prompts per step at ConfirmImpact Medium, leaver at High
Invoke-MulJoiner -Path .\joiners.csv -Apply
Invoke-MulLeaver -Path .\leavers.csv -Apply

# Unattended, after reviewing the dry-run report
Invoke-MulLeaver -Path .\leavers.csv -Apply -Confirm:$false

# Standard -WhatIf also works with -Apply
Invoke-MulLeaver -Path .\leavers.csv -Apply -WhatIf

# Pipeline input
Import-MulJoinerCsv -Path .\joiners.csv | Where-Object Department -eq 'IT' | Invoke-MulJoiner -Apply
```

[`examples/offboard-with-app-auth.ps1`](examples/offboard-with-app-auth.ps1) shows unattended offboarding with certificate-based app-only authentication for Graph and Exchange Online, so no passwords are stored.

Each run writes `mul-joiner-<timestamp>.csv` / `mul-leaver-<timestamp>.csv` (one row per step) and a `.log`. Override them with `-ReportPath` and `-LogPath`.

## Sample output

Dry run against **synthetic data** ([`docs/sample-dry-run.txt`](docs/sample-dry-run.txt)):

```text
PS> Invoke-MulLeaver -Path .\examples\leavers.sample.csv

UserPrincipalName        Step            Status Message
-----------------        ----            ------ -------
jordan.doe@contoso.com   BlockSignIn     DryRun Block sign-in
jordan.doe@contoso.com   RevokeSessions  DryRun Revoke refresh tokens and sign-in sessions
jordan.doe@contoso.com   ConvertToShared DryRun Convert mailbox to shared
jordan.doe@contoso.com   AutoReply       DryRun Enable internal and external auto-reply
jordan.doe@contoso.com   MailboxDelegate DryRun Grant pat.lee@contoso.com Full Access to the mailbox
jordan.doe@contoso.com   OneDriveHandoff DryRun Share OneDrive with pat.lee@contoso.com (edit, sign-in required)
jordan.doe@contoso.com   RemoveLicenses  DryRun Remove from licensing group 5e6f7a8b-0000-4c1d-9e2f-3a4b5c6d7e8f
```

Possible step statuses: `DryRun`, `Success`, `Skipped`, `Pending`, `WhatIf`, `Declined`, `Blocked`, `Failed`.

## Safety notes

- **Dry run by default.** You have to pass `-Apply` before anything changes. `-WhatIf` and `-Confirm` work as normal on top of that.
- **Validate first, change second.** CSV rows are validated before the run starts, and each user's lookups finish before that user's first change.
- **License removal is guarded.** It's `Blocked` automatically unless the mailbox conversion succeeded or the mailbox was already shared. Removing the license from a user mailbox starts the clock on deleting it.
- **No deletions.** Accounts are blocked, never deleted. Pair this with your retention policy.
- **No secrets in output.** The initial password is generated in memory, sent once to Graph, and never logged, returned, or written to the report. A test enforces this.
- **Audit trail.** Every step lands in the CSV report and the log, including dry runs and skips.
- **OneDrive:** if your tenant's OneDrive retention already gives the manager access when an account is deleted, use `-SkipOneDriveHandoff`.

## Testing

All Graph and Exchange Online cmdlets are stubbed and mocked, so no tenant is needed:

```powershell
./build.ps1   # PSScriptAnalyzer (0 findings required) + Pester with code coverage
```

The tests cover CSV validation (every error reported together), dry-run behavior (no write cmdlets called), apply behavior with the exact Graph parameters, `-WhatIf` with `-Apply`, pre-flight failures that make no changes, idempotent re-runs, `Pending` mailbox settings, leaver step order, the license-removal guard, group-based vs direct license removal, the password never appearing in logs, and help for every exported command.

## Layout

```text
src/M365UserLifecycle/   manifest, loader, Public/ (Import-*, Invoke-*) and Private/ helpers
tests/                   Pester 5 tests with mocked Graph/EXO cmdlets + quality gates
examples/                sample CSVs and an app-only unattended script
docs/                    sample dry-run output (synthetic data)
```

## Author

**John Harrington**, Systems Engineer. [LinkedIn](https://www.linkedin.com/in/john-harrington-9022649a)

## License

[MIT](LICENSE)
