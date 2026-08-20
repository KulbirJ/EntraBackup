# Entra Tenant Backup ( Current Repo is public for demo tenant and demo purposes)

This tool takes a daily snapshot of how your Microsoft Entra ID tenant is configured and
saves it to a private GitHub repository. Think of it as a photograph of your identity
settings, taken every night and kept forever.

If someone changes a security policy, deletes a group, or grants an application access to
your data, you will be able to see exactly what changed, when, and what it looked like
before.

---

## The problem this solves

Microsoft keeps deleted users and groups for about 30 days. After that they are gone for
good. Microsoft keeps no history of your *settings* at all.

That leaves some ordinary questions impossible to answer:

- What did this security policy look like three months ago?
- Who was given administrator access last week?
- Which application was allowed to read our mail, and when was that approved?
- Something broke overnight. What changed?

Today those questions have no answer. With a nightly snapshot in version control, all of
them do.

---

## What it does

Every night at 3am UTC, an automated job signs in to your tenant, reads the configuration,
and saves it as a set of text files. If anything has changed since the previous night, the
change is recorded permanently with a date stamp.

It currently captures 549 items across 21 areas of your tenant, including:

- All users and their details
- All groups, who is in them and who owns them
- Administrator role assignments
- Conditional Access policies (your sign-in security rules)
- Registered applications and what they have been given access to
- Licensing and domain configuration

The whole run takes about 25 seconds.

When something security-sensitive changes, such as a sign-in policy being switched off or
someone being made an administrator, the system opens a ticket so a person actually looks
at it. Routine changes, like a new starter joining a group, are recorded quietly without
raising an alarm.

---

## What it cannot do

This matters more than the feature list, so it is worth being direct about it.

**This is not a restore button.** It is a detailed record of how things were set up, which
makes rebuilding possible and much faster. It does not put the tenant back by itself.

Three tiers, in plain terms:

**Things we can rebuild from this record.** Security policies, groups and their membership,
application registrations, device management policies. We have everything needed to
recreate them.

**Things recoverable only within 30 days.** Deleted users, groups and applications. Inside
that window Microsoft can restore them properly, keeping all their existing access. After
30 days we can recreate the account, but it will be treated as a brand new person by every
other system, so all its access must be granted again by hand.

**Things nobody can back up.** Passwords, multi-factor authentication registrations, and
application secrets. Microsoft never makes these readable to any tool, deliberately, for
security reasons. After a disaster every user needs a new password and has to re-register
their authentication app. No product on the market changes this.

If a vendor claims to offer complete Entra restore, that third row is the part they are
glossing over.

---

## Privacy: this repository must stay private

The snapshot contains full staff records. Names, email addresses, phone numbers, job
titles, departments, employee IDs.

Two things follow from that:

1. **The repository must never be made public.** Exposing it exposes the entire staff
   directory.
2. **The history cannot be quietly cleaned later.** Version control keeps everything.
   Removing a field today does not remove it from last month's snapshot. That requires
   rewriting the whole history.

If there are fields we would rather not store at all, the time to decide is now, while the
history is a day old. It is a small configuration change today and a painful one in a
year. See [SCOPE.md](docs/SCOPE.md) for what is captured.

Depending on where you operate, storing this may carry data protection obligations.

---

## What it costs

Nothing, in practice.

It runs on GitHub's free automation allowance and uses roughly 15 minutes of it per month
against a much larger monthly quota. It reads from Microsoft Graph, which is included with
your existing licences. It cannot change anything in the tenant, because the account it
uses has read-only access and no write permissions of any kind.

There is no server to maintain and no software to install.

---

## Is it working?

Two ways to check, neither of which needs technical knowledge.

**Look at the repository.** Every night's run appears as an entry with a message like
`backup: 2026-08-19 (+3 ~12 -1)`. That reads as: 3 items added, 12 changed, 1 removed.
A quiet night shows `(+0 ~1 -0)`, because one internal file always records the time the
job ran.

**Watch for failures.** If a run fails, GitHub emails the repository owner. Silence means
it is working.

The system is built to stop rather than record something wrong. If it can only read part
of the tenant, because of a network problem or a permissions change, it refuses to save
anything at all. A partial snapshot would look like a mass deletion and would corrupt the
history, which is worse than missing one night.

---

## If you need to recover something

Start with [RESTORE.md](docs/RESTORE.md). The short version:

**Someone deleted recently, within 30 days.** Use the restore script. The account comes
back intact with all its previous access. This is the good case and takes minutes.

**A policy or group was changed or deleted.** The snapshot has the old version. It can be
recreated from the record. Security policies are deliberately restored switched off, so
they can be reviewed before being made live again.

**A serious incident affecting the whole tenant.** This is a rebuild measured in days, not
a button press. [ARCHITECTURE.md section 5](docs/ARCHITECTURE.md#5-recovering-from-a-disaster) has
the step-by-step runbook, in the correct order, along with an honest account of what has
to be redone by hand.

---

## How it stays trustworthy

A backup that quietly stops working is worse than no backup, because you believe you are
covered. Three things guard against that.

**It refuses partial saves.** Described above. Better to skip a night than record a lie.

**It checks itself before every run.** 22 automated checks run first. If the tool has been
broken by a change, the run stops before it can write anything.

**Repeat runs produce identical files.** When nothing has changed in the tenant, the
snapshot is byte-for-byte identical to yesterday's. That property is what makes the change
history meaningful. If snapshots drifted slightly every night, real changes would be lost
in the noise and nobody would read them. We verified this against your live tenant: the
second run changed two lines, both of them the timestamp recording when the job ran.

---

## Documentation

| Document | Who it is for | Covers |
|---|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Everyone, then maintainers | How it works in plain terms, then the full technical reference and the tenant rebuild runbook |
| [SETUP.md](docs/SETUP.md) | Whoever sets it up | First-time configuration |
| [SCOPE.md](docs/SCOPE.md) | Security and compliance | Exactly what is captured, and the limits of what Microsoft exposes |
| [RESTORE.md](docs/RESTORE.md) | Whoever is recovering something | Recovery steps and how to search the history |

---

## Setup, in brief

Already done for this tenant. Recorded here for reference, and for anyone setting it up
elsewhere. Full detail in [SETUP.md](docs/SETUP.md).

1. Register an application in Entra and give it read-only permissions.
2. Run the **OIDC Probe** job once, which prints an identifier that must be copied exactly.
3. Set up trust between GitHub and Entra using that identifier.
4. Record the tenant and application IDs in the repository settings.
5. Run the backup once by hand to confirm, then leave the nightly schedule to it.

Step 2 is not a formality. GitHub changed the format of that identifier in July 2026, and
guessing it produces an error message that does not explain what is wrong.

The connection between GitHub and Entra uses no password or secret key. GitHub proves its
identity cryptographically each time. Nothing needs to be rotated, and there is no
credential that could be stolen from the repository.
