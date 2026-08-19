# Scope: what is captured, and what can actually be restored

"Backup" implies more than Entra can deliver, so this page is deliberately blunt about
the limits. Read it before relying on this repository in a recovery plan.

---

## The three tiers

### Tier 1 — Recreatable from these files

The snapshot holds everything needed to rebuild the object through Graph. Restore is a
create call with the stored JSON as the body.

Conditional Access policies · named locations · groups and their membership/ownership ·
app registrations · Intune device configuration and compliance policies · app protection
policies · administrative units · access packages and catalogs · directory role
assignments · authorization policy · authentication methods policy · cross-tenant access
settings.

### Tier 2 — Restorable only inside the soft-delete window

Entra keeps deleted objects for roughly **30 days**, after which they are gone
permanently. The snapshot records what the object *was*, which tells you exactly what to
recreate — but a true restore (preserving the object's GUID, and therefore every
reference to it) is only possible while it sits in `/directory/deletedItems`.

Users · groups · app registrations.

This distinction matters more than it first appears. Recreating a user with the same UPN
produces a *different* object ID, so every group membership, role assignment, ACL, and
file permission that referenced the original still points at nothing.

### Tier 3 — Not recoverable at all

Graph never returns this data, so no backup tool built on Graph can capture it.

| | Why |
|---|---|
| Passwords | Never exposed by any API |
| MFA / authentication method registrations | Read as metadata at best; the registered factors themselves cannot be exported or re-imported |
| Application client secrets and certificates | Write-only by design. `passwordCredentials` and `keyCredentials` record that a secret exists and when it expires — never the material |
| B2B guest redemption state | Recreating a guest re-triggers the invitation flow |
| Per-user licence *purchase* | Assignment is captured; the underlying subscription is a commercial artefact, not directory config |
| Sign-in and audit logs | A separate retention concern; deliberately out of scope (see below) |

---

## Collected endpoints

All Graph `v1.0`. Endpoints marked **Optional** are skipped with a log entry when the
tenant lacks the licence or permission, rather than failing the run.

### `directory/`

| Collection | Endpoint | Notes |
|---|---|---|
| `users` | `/users` | Full objects, explicit `$select`. Contains personal data |
| `groups` | `/groups` | Membership and ownership folded into each group's file |
| `directoryRoles` | `/directoryRoles` | Only *activated* roles; `governance/roleDefinitions` is the full catalogue |
| `administrativeUnits` | `/directory/administrativeUnits` | Optional |
| `domains` | `/domains` | Verification state, federation config |
| `organization` | `/organization` | Branding, technical contacts, tenant features |
| `subscribedSkus` | `/subscribedSkus` | Licence inventory |

### `policies/`

| Collection | Notes |
|---|---|
| `conditionalAccessPolicies` | **Requires P1+.** The most valuable thing here |
| `namedLocations` | Optional |
| `authenticationMethodsPolicy` | Optional |
| `authorizationPolicy` | Default user permissions, guest access, self-service consent |
| `crossTenantAccessPolicyDefault` / `Partners` | Optional |
| `identitySecurityDefaults` | Optional |
| `adminConsentRequestPolicy`, `permissionGrantPolicies` | Optional |
| `identityProviders` | Optional |

### `applications/`

| Collection | Notes |
|---|---|
| `applications` | App registrations. Secret *metadata* only |
| `servicePrincipals` | Enterprise apps, including every Microsoft first-party principal — expect this to be the largest collection in the tenant |
| `oauth2PermissionGrants` | Delegated consent grants. New entries here are how most consent-phishing shows up |

### `governance/`

| Collection | Notes |
|---|---|
| `roleDefinitions`, `roleAssignments` | Always available |
| `roleEligibilitySchedules` | PIM eligibility. **P2** |
| `roleManagementPolicies` / `Assignments` | PIM activation rules. **P2** |
| `accessReviewDefinitions` | **P2** |
| `entitlementAccessPackages`, `entitlementCatalogs`, `entitlementPolicies` | **Governance / P2** |

### `intune/`

| Collection | Notes |
|---|---|
| `deviceConfigurations`, `deviceCompliancePolicies` | Requires Intune |
| `deviceEnrollmentConfigurations` | Requires Intune |
| `managedAppPolicies` | App protection (MAM) |
| `roleDefinitionsIntune` | Intune RBAC |

---

## Deliberate exclusions

**`signInActivity` on users.** Requires `AuditLog.Read.All`, slows the user query
considerably, and changes on every sign-in — it would dirty every user file on every run
and bury real changes under noise.

**Sign-in and audit logs.** These are append-only event streams, not configuration.
Committing them daily would balloon the repository without making anything more
recoverable. Route them to a Log Analytics workspace or SIEM instead.

**Devices.** Device objects churn constantly (compliance state, last check-in) and are
re-created by enrolment rather than restored from a backup. The Intune *policies* that
govern them are captured; the device records are not.

**Per-object volatile fields.** `onPremisesLastSyncDateTime`, `refreshTokensValidFromDateTime`,
`signInSessionsValidFromDateTime`, and the `@odata.*` response plumbing are stripped
during normalisation. See `$script:VolatileFields` in
[scripts/lib/Normalize.psm1](../scripts/lib/Normalize.psm1).

---

## Privacy

`backup/directory/users/` holds complete user records: display names, UPNs, email
addresses, phone numbers, job titles, departments, employee IDs, office locations, and
on-premises identifiers.

- The repository must remain **private**.
- Git history is effectively permanent. Removing a field later does not remove it from
  history; that requires rewriting history.
- Depending on jurisdiction, this may constitute a processing activity under GDPR or
  equivalent, with retention obligations attached.

To reduce exposure, drop unwanted fields from the `$select` clause on the `users` entry
in [config/endpoints.psd1](../config/endpoints.psd1). Doing that now costs nothing;
doing it after a year of history means rewriting the repository.
