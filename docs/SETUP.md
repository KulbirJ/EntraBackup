# Setup

One-time configuration. Budget about 30 minutes, most of it in the Entra portal.

Everything here is read-only against the tenant. The app registration created below can
read directory configuration and nothing else — it has no write permissions.

---

## 1. Create the repository

The repository **must be private**. It will contain complete user records.

```powershell
cd c:\Users\user1-baseNaultha\EntraBackup
git init
git add -A
git commit -m "Initial commit: Entra backup tooling"
gh repo create EntraBackup --private --source=. --remote=origin --push
```

---

## 2. Register the Entra application

Entra portal → **Identity** → **Applications** → **App registrations** → **New registration**.

| Field | Value |
|---|---|
| Name | `entra-backup-ci` |
| Supported account types | Accounts in this organizational directory only |
| Redirect URI | *leave blank* |

Do **not** create a client secret. The whole point of the federated credential in step 4
is that no secret exists.

From the app's **Overview** page, record both of these — they are different values and
both are needed:

- **Application (client) ID** → used as the `AZURE_CLIENT_ID` repository variable
- **Directory (tenant) ID** → used as the `AZURE_TENANT_ID` repository variable
- **Object ID** → needed only if you create the federated credential via `az` CLI

---

## 3. Grant application permissions

**API permissions** → **Add a permission** → **Microsoft Graph** → **Application
permissions**. Application, not delegated — the workflow runs with no signed-in user.

Core, required:

| Permission | Covers |
|---|---|
| `Directory.Read.All` | Directory objects, administrative units, domains |
| `User.Read.All` | User objects |
| `Group.Read.All` | Groups, membership, ownership |
| `Organization.Read.All` | Tenant settings, subscribed SKUs |
| `Application.Read.All` | App registrations, service principals, consent grants |
| `Policy.Read.All` | Conditional Access, authorization, authentication methods, cross-tenant |
| `RoleManagement.Read.All` | Role definitions and assignments |

Optional — each unlocks a category that is otherwise skipped cleanly:

| Permission | Covers | Needs |
|---|---|---|
| `RoleManagementPolicy.Read.Directory` | PIM activation rules | Entra ID P2 |
| `EntitlementManagement.Read.All` | Access packages, catalogs | Governance / P2 |
| `AccessReview.Read.All` | Access review definitions | Entra ID P2 |
| `DeviceManagementConfiguration.Read.All` | Intune device and compliance policies | Intune |
| `DeviceManagementApps.Read.All` | App protection policies | Intune |
| `DeviceManagementServiceConfig.Read.All` | Enrollment configuration | Intune |

Then click **Grant admin consent for \<tenant\>**. This is easy to overlook, and without
it every permission stays in "Not granted" state and the backup fails at the first call.

> Missing an optional permission is not fatal. Endpoints marked `Optional` in
> `config/endpoints.psd1` log a skip and the run continues, so an unlicensed tenant does
> not fail — it just collects less.

---

## 4. Capture the OIDC subject, then create the federated credential

**Do this in order.** The subject must be read, not guessed.

Since **15 July 2026** GitHub issues the *immutable* subject format for repositories
that are newly created, renamed, or transferred:

```
repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:refs/heads/main
```

rather than the older `repo:<owner>/<repo>:ref:refs/heads/main`. A credential built from
the legacy format fails with `AADSTS70021` and no useful detail — the request simply
does not match any credential.

### 4a. Read the real subject

GitHub → **Actions** → **OIDC Probe** → **Run workflow**.

The run summary prints the exact `issuer`, `subject`, and `audience`. Copy the subject
verbatim, including the `@<numeric-id>` segments if present.

### 4b. Create the credential

> **A personal GitHub account is fine.** The portal's **Organization** field means the
> GitHub *account owner*, not a GitHub organization — for a personal account it is simply
> your username (`KulbirJ`). You do not need to belong to an organization.

**Use the "Other issuer" scenario, not the GitHub one.** The guided *GitHub Actions
deploying Azure resources* scenario builds the subject for you in the legacy name-based
format (`repo:KulbirJ/EntraBackup:ref:refs/heads/main`). This repository was created
after 15 July 2026, so GitHub issues the immutable format instead, and the guided
scenario's value will not match.

App registration → **Certificates & secrets** → **Federated credentials** →
**Add credential** → scenario **Other issuer**:

| Field | Value |
|---|---|
| Issuer | `https://token.actions.githubusercontent.com` |
| Subject identifier | **paste the `subject` from the probe, verbatim** |
| Name | `entra-backup-main` |
| Audience | `api://AzureADTokenExchange` |

If you do use the guided GitHub scenario, compare its generated subject against the
probe output before saving, and switch to **Other issuer** if they differ.

#### Creating it without the portal

The Azure CLI route (`az ad app federated-credential create`) needs `az`, which is not
installed here. Federated credentials are also just a Graph resource, so this repo's own
modules can create one — run from the repository root:

```powershell
Import-Module .\scripts\lib\Auth.psm1        -Force -DisableNameChecking
Import-Module .\scripts\lib\GraphClient.psm1 -Force -DisableNameChecking

# Application.ReadWrite.All is a write scope, so it must be requested explicitly --
# the device-code defaults in Auth.psm1 are read-only.
$token = Get-EntraTokenFromDeviceCode -Scopes @('Application.ReadWrite.All')
Initialize-GraphClient -TokenProvider { $token }.GetNewClosure()

# The app's OBJECT id (Overview blade), not the client id.
$appObjectId = '<APP_OBJECT_ID>'

$credential = @{
    name      = 'entra-backup-main'
    issuer    = 'https://token.actions.githubusercontent.com'
    subject   = '<PASTE THE SUBJECT FROM THE PROBE>'
    audiences = @('api://AzureADTokenExchange')
} | ConvertTo-Json -Depth 10

Invoke-GraphRequest -Method POST -Body $credential `
    -Uri "/v1.0/applications/$appObjectId/federatedIdentityCredentials"
```

Verify what ended up on the app:

```powershell
(Invoke-GraphRequest -Uri "/v1.0/applications/$appObjectId/federatedIdentityCredentials").value |
    Select-Object name, subject, issuer
```

---

## 5. Set the repository variables

Variables, not secrets — both are non-sensitive identifiers, and no secret is involved
anywhere in this design.

Substitute the real GUIDs. Do **not** keep the angle brackets — they are placeholder
markers, not syntax, and a value like `<19a113ce-…>` produces a bare HTTP 400 from Entra
with no indication of which value is wrong. The workflows now check the format up front
and say so plainly, but it is easier not to hit it.

```powershell
gh variable set AZURE_TENANT_ID --body "19a113ce-a488-46f1-aedc-757a591bad61"
gh variable set AZURE_CLIENT_ID --body "9f47aa95-1148-4cf4-8514-b353b958de16"
```

Confirm they landed clean:

```powershell
gh api repos/OWNER/REPO/actions/variables --jq '.variables[] | "\(.name) = [\(.value)]"'
```

---

## 6. Verify

Re-run **OIDC Probe**. With the variables now set, its second step performs the real
token exchange and calls `/v1.0/organization`. Success prints your tenant's display name
— that is end-to-end proof that federation works, before any snapshot is attempted.

Then run **Entra Backup** manually (**Actions** → **Entra Backup** → **Run workflow**).
The first run has no baseline, so the safety guard passes automatically and everything
is committed as the initial snapshot.

Confirm the second run is clean:

```powershell
# Run it again with no tenant changes in between.
# A correct normaliser produces zero changed files.
```

If the second run commits a large diff, the normaliser needs tuning for something
specific to your tenant — add the offending field to `$script:VolatileFields` in
[scripts/lib/Normalize.psm1](../scripts/lib/Normalize.psm1). Expect one or two rounds of
this; some Graph fields churn in tenant-specific ways.

---

## Local runs

```powershell
.\tests\Test-Offline.ps1                              # no tenant needed
.\scripts\Invoke-EntraBackup.ps1 -Category directory  # device-code sign-in
.\scripts\Invoke-EntraBackup.ps1 -Verbose             # everything
```

Local runs use delegated permissions from your own admin sign-in, so they can only read
what you can read. Works on Windows PowerShell 5.1 and PowerShell 7 alike.

---

## Troubleshooting

**`AADSTS70021: No matching federated identity record found`**
The credential subject does not match the token. Re-run the OIDC Probe and compare
character for character — this is almost always the immutable-subject mismatch described
in step 4.

**`GitHub OIDC environment not present`**
The job is missing `permissions: id-token: write`. Without it GitHub does not populate
the token request variables at all.

**`Graph returned 403`**
A permission was not granted, or admin consent was never clicked. For an `Optional`
endpoint this is logged and skipped; for a required one the run fails deliberately rather
than record an incomplete snapshot.

**Safety guard trips (exit code 2)**
Usually a throttled or partially permissioned run, not a real deletion. Nothing is
committed. Check the reported counts, and if the drop is genuine re-run with
`accept_shrink` enabled.

**Second run produces a large diff**
A tenant-specific volatile field. Find it in the diff and add it to `$script:VolatileFields`.
