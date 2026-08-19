<#
    Tunables for the backup run. Everything here is safe to edit without touching code.
#>
@{
    # Above this many objects in a collection, switch from one-file-per-object to
    # sharded newline-delimited JSON. A directory holding 20,000 individual files makes
    # git operations slow and the GitHub UI unusable; NDJSON shards keep diffs readable
    # while staying manageable. Detected per collection via $count on the first run.
    ShardThreshold = 2000

    # Number of NDJSON shards used once ShardThreshold is exceeded. Objects are assigned
    # by the first hex digits of their GUID, so an object stays in the same shard for
    # its whole life and a change touches exactly one shard.
    ShardCount = 16

    # Mass-deletion tripwire. If any collection shrinks by more than this fraction
    # compared with the previous run, the backup aborts WITHOUT committing.
    #
    # This exists because the dangerous failure mode is not a crash -- it is a partial
    # success. A throttled or half-permissioned run that silently returns 20 users
    # instead of 2,000 would otherwise commit "1,980 users deleted" and bury the real
    # history under a fictional mass deletion.
    #
    # Confirm a genuine bulk deletion by re-running with -AcceptShrink.
    MaxShrinkFraction = 0.20

    # A collection going from "had objects" to "returned zero" is always treated as
    # suspicious, regardless of MaxShrinkFraction.
    FailOnEmptyCollection = $true

    # Graph retry ceiling per request. Throttling waits obey Retry-After when Graph
    # sends it, so this is a backstop rather than the primary mechanism.
    MaxRetries = 6

    # Skip per-object child collections (group members, role members) when a collection
    # is very large -- these are N+1 requests and dominate runtime on big tenants.
    # 0 disables the limit.
    MaxChildFetchParents = 5000

    # Categories collected when -Category is not specified.
    DefaultCategories = @('directory', 'policies', 'applications', 'governance', 'intune')

    # Changes that should raise a GitHub issue rather than sit silently in a commit.
    # Consumed by scripts/Test-HighRiskChange.ps1 in the workflow.
    HighRiskPaths = @(
        'backup/policies/conditionalAccessPolicies/'
        'backup/policies/authorizationPolicy'
        'backup/policies/authenticationMethodsPolicy'
        'backup/governance/roleAssignments/'
        'backup/governance/roleEligibilitySchedules/'
        'backup/directory/directoryRoles/'
        'backup/applications/oauth2PermissionGrants/'
    )

    # Directory role template IDs treated as privileged for change alerting.
    # Global Administrator, Privileged Role Administrator, Security Administrator,
    # Application Administrator, Cloud Application Administrator, User Administrator,
    # Exchange Administrator, Privileged Authentication Administrator.
    PrivilegedRoleTemplateIds = @(
        '62e90394-69f5-4237-9190-012177145e10'
        'e8611ab8-c189-46e8-94e1-60213ab1f814'
        '194ae4cb-b126-40b2-bd5b-6091b380977d'
        '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3'
        '158c047a-c907-4556-b7ef-446551a6b5f7'
        'fe930be7-5e62-47db-91af-98c3a49a38b1'
        '29232cdf-9323-42fd-ade2-1d097af3e4de'
        '7be44c8a-adaf-4e2a-84d6-ab2649e08a13'
    )
}
