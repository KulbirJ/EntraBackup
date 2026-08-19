# Entra Tenant Backup

Daily configuration snapshots of a Microsoft Entra ID tenant, committed to git so that
history becomes the audit trail and the diff becomes the change-detection system.

> **This repository must stay private.** It contains complete user records — names,
> email addresses, phone numbers, job titles, employee IDs, on-premises identifiers.
> Git history is effectively permanent, so exposure of the repo is exposure of the
> entire directory.

## Why

Entra keeps deleted objects for roughly 30 days and keeps no configuration history at
all. There is no built-in way to answer:

- What did this Conditional Access policy look like last quarter?
- Who was added to Global Administrator, and when?
- Which app was granted that consent scope, and by whom?
- What changed in the tenant last night?

A daily snapshot in git answers all four.

## What this is, and is not

It is a **point-in-time configuration record, an audit trail, and a selective-recreate
toolkit**. It is not one-click tenant restore, because Entra does not expose the data
that would require.

| | |
|---|---|
| **Recreatable from these files** | Conditional Access policies, named locations, groups and membership, app registrations, Intune configuration and compliance policies, administrative units, access packages, role assignments |
| **Restorable only within ~30 days** | Users, groups, app registrations — via `/directory/deletedItems`. The snapshot records what they *were*; the restore itself is a Graph call |
| **Not recoverable at all** | Passwords, MFA and authentication-method registrations, application client secrets and certificates (write-only in Graph by design), B2B redemption state |

See [docs/SCOPE.md](docs/SCOPE.md) for the endpoint-by-endpoint breakdown, and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design reference, component
guide, and tenant-rebuild runbook.

## How it works

A scheduled GitHub Actions workflow authenticates to Graph using **workload identity
federation** — GitHub mints a short-lived token proving which repository and branch is
running, and Entra exchanges it for a Graph token. No client secret exists anywhere, so
there is nothing to rotate and nothing to leak.

The collector walks [config/endpoints.psd1](config/endpoints.psd1), normalises every
object, and writes deterministic JSON. Adding a backup target is an edit to that
manifest, not a code change.

### Determinism is the whole game

Collecting the data is easy. Making run N+1 produce *byte-identical* files when nothing
changed is what decides whether this is useful or a wall of noise. So:

- object keys are sorted recursively;
- self-churning fields are stripped (`onPremisesLastSyncDateTime` alone moves every
  ~30 minutes on a synced tenant and would dirty every user file on every run);
- unordered arrays are sorted by a stable key, while genuinely ordered ones are left
  alone;
- files are named by immutable GUID, so a rename is a one-line change in `_index.json`
  rather than a delete plus an add;
- JSON is serialised by [a hand-written writer](scripts/lib/Normalize.psm1) rather than
  `ConvertTo-Json`, whose depth handling and non-ASCII escaping differ between
  PowerShell 5.1 and 7 and would otherwise make the snapshot depend on which host ran it.

### The safety guard

The dangerous failure is not a crash — a crash commits nothing. It is the *partial
success*: throttling or a revoked permission returns 20 users where there were 2,000,
and the run commits a fictional mass deletion on top of real history.

So before anything is committed, object counts are compared against the previous run.
Any collection that shrinks more than 20%, or empties out entirely, **aborts the run**.
Growth is never blocked. A genuine bulk deletion is confirmed by re-running with
`-AcceptShrink`.

## Layout

```
config/endpoints.psd1     what gets backed up  (edit this to add targets)
config/settings.psd1      thresholds and tunables
scripts/lib/              Normalize · GraphClient · Collector · SafetyGuard · Auth
scripts/Invoke-EntraBackup.ps1
backup/                   the committed snapshot
  _meta/run.json          tenant, timestamp, per-collection counts
  directory/ policies/ applications/ governance/ intune/
tests/Test-Offline.ps1    regression tests — no tenant or network needed
```

Collections under `ShardThreshold` (default 2,000) are written one file per object.
Larger ones switch to sharded newline-delimited JSON, because a directory holding tens
of thousands of files makes git slow and the GitHub UI unusable.

## Documentation

| Document | Covers |
|---|---|
| [SETUP.md](docs/SETUP.md) | First-time configuration: app registration, OIDC federation, permissions |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Design rationale, every component and script, how-to guide, full tenant-rebuild runbook |
| [SCOPE.md](docs/SCOPE.md) | Endpoint-by-endpoint coverage and the limits of what Entra exposes |
| [RESTORE.md](docs/RESTORE.md) | Restore cheat-sheet and history-querying recipes |

## Getting started

Full instructions in **[docs/SETUP.md](docs/SETUP.md)**. In short:

1. Register an Entra app, grant it read-only application permissions, admin-consent them.
2. Run the **OIDC Probe** workflow once and copy the `sub` claim it prints.
3. Create a federated credential on the app using that subject *verbatim*.
4. Set the `AZURE_TENANT_ID` and `AZURE_CLIENT_ID` repository variables.
5. Run **Entra Backup** manually to verify, then let the daily schedule take over.

Step 2 is not optional ceremony. Since 15 July 2026 GitHub issues an *immutable* subject
format for new repositories, and a credential built from the older name-based format
fails with an unhelpful error.

### Trying it locally first

```powershell
.\scripts\Invoke-EntraBackup.ps1 -Category directory
```

Signs in interactively with device code, so the collector can be exercised against a
real tenant before any of the CI setup exists. Runs on Windows PowerShell 5.1 as well as
PowerShell 7.

```powershell
.\tests\Test-Offline.ps1     # regression tests, no tenant required
```

## Change alerting

After each commit the workflow inspects the diff and raises a GitHub issue when a change
touches Conditional Access, tenant authorization policy, authentication methods,
directory role assignments, PIM eligibility, or OAuth consent grants — separating those
from the routine churn of people joining and leaving. Configure the watched paths in
`HighRiskPaths` in [config/settings.psd1](config/settings.psd1).
