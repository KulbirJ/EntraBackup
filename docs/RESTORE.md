# Restore

> This is the quick reference. For the **full tenant-rebuild runbook** -- dependency
> ordering, ID remapping, and what must be accepted as lost -- see
> [ARCHITECTURE.md § 8](ARCHITECTURE.md#8-restoring-a-tenant).

Restore is deliberately **not** automated and **not** part of the scheduled workflow.
The backup identity holds read permissions only; every operation here runs locally under
your own admin sign-in, with an interactive device-code prompt.

Every restore script is a dry run by default. Add `-Confirm:$false` to actually act.

---

## Decide which path you need

```
Was the object deleted less than ~30 days ago?
├── Yes → Restore-DeletedObject.ps1        ← preserves the original id. Always prefer this.
└── No  → recreate from the snapshot file  ← new id; references do not follow.
```

That distinction is the single most important thing on this page.

Restoring from `deletedItems` returns the object with its **original GUID**. Every group
membership, directory role assignment, ACL, mailbox permission, SharePoint grant and
Teams membership that referenced it keeps working.

Recreating from a snapshot file produces a **new GUID**. The UPN and every attribute can
be identical, and the account will still be missing from every group and every
permission it once had, because those reference the id and not the name.

So: check `deletedItems` first, always.

---

## Restoring a deleted user, group, or app

```powershell
# What is still restorable, and how long is left on each?
.\scripts\Restore\Restore-DeletedObject.ps1 -Type users -List

# Restore one.
.\scripts\Restore\Restore-DeletedObject.ps1 -Type users -Id <guid> -Confirm:$false
```

The listing shows the remaining window per object. Once that reaches zero the object is
purged permanently and this path is closed.

**Not restored with the object:** the password (issue a reset), MFA registrations (the
user re-registers), and any application secrets.

---

## Recreating a Conditional Access policy

```powershell
# Dry run.
.\scripts\Restore\Restore-ConditionalAccessPolicy.ps1 `
    -Path .\backup\policies\conditionalAccessPolicies\<id>.json

# Create it, disabled.
.\scripts\Restore\Restore-ConditionalAccessPolicy.ps1 `
    -Path .\backup\policies\conditionalAccessPolicies\<id>.json -Confirm:$false
```

The policy is created **disabled** and renamed with a `(restored <date>)` suffix, even
when the snapshot recorded it as enabled. This is intentional: restoring a CA policy
directly into enforcement is one of the more reliable ways to lock an entire tenant out
of its own directory. Review it in the portal, then enable it.

`-EnableImmediately` overrides this. Have a break-glass account confirmed working first.

Group and user references inside the policy are stored as GUIDs. If the referenced
objects no longer exist, the create call fails — restore them first.

---

## Finding what changed, and when

This is what the git history is for, and it is the capability Entra itself does not
offer.

```powershell
# Every change to one policy, most recent first.
git log --follow -p -- backup/policies/conditionalAccessPolicies/<id>.json

# What changed across the tenant on one day?
git log --since=2026-08-01 --until=2026-08-02 -p -- backup/

# Which commit removed this user?
git log --diff-filter=D -- backup/directory/users/<id>.json

# What did the tenant look like on 1 August?
git show 'HEAD@{2026-08-01}:backup/policies/authorizationPolicy/settings.json'

# Who is in a role now versus a month ago?
git diff HEAD~30 HEAD -- backup/directory/directoryRoles/
```

Files are named by immutable id, so `--follow` tracks an object across renames. Use
`_index.json` in each directory to map a display name back to its id.

---

## Rebuilding other object types

No dedicated script yet; the pattern is the same in each case. Take the snapshot JSON,
strip the server-assigned fields, and POST it back:

```powershell
Import-Module .\scripts\lib\Auth.psm1        -Force -DisableNameChecking
Import-Module .\scripts\lib\GraphClient.psm1 -Force -DisableNameChecking

Initialize-GraphClient -TokenProvider (Get-EntraTokenProvider -Mode DeviceCode)

$obj = Get-Content .\backup\directory\groups\<id>.json -Raw | ConvertFrom-Json

$payload = @{}
foreach ($p in $obj.PSObject.Properties) {
    # Server-assigned and collector-added fields must not be sent back.
    if ($p.Name -in @('id','createdDateTime','modifiedDateTime','members','owners')) { continue }
    if ($p.Name.StartsWith('@')) { continue }
    $payload[$p.Name] = $p.Value
}

Invoke-GraphRequest -Uri '/v1.0/groups' -Method POST -Body ($payload | ConvertTo-Json -Depth 100)
```

Membership is stored under `members` in the group's own file and is added afterwards via
`POST /groups/{id}/members/$ref`.

Note that this needs write scopes, which the device-code sign-in requests based on the
`-Scopes` argument to `Get-EntraTokenFromDeviceCode` — the defaults are read-only, so
pass the write scopes explicitly for restore work.

---

## What cannot be restored by any means

Passwords · MFA and authentication-method registrations · application client secrets and
certificates · B2B guest redemption state.

Graph never returns these, so no Graph-based backup can capture them. See
[SCOPE.md](SCOPE.md).
