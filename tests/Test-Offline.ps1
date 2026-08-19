<#
.SYNOPSIS
    Offline regression tests. No tenant, no network, no credentials required.

.DESCRIPTION
    Covers the properties that make or break this tool:

      determinism  An unchanged tenant must produce byte-identical files, or the diff
                   fills with noise and stops being readable.
      pruning      A deleted object must disappear from the snapshot, or the backup
                   silently drifts out of step with the tenant.
      sharding     Shard assignment must be stable across processes, or every run
                   rewrites every shard.
      safety       A partially failed run must be blocked before it can commit a
                   fictional mass deletion over real history.

    Run: powershell -ExecutionPolicy Bypass -File .\tests\Test-Offline.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $testRoot
# Segments joined individually: a backslash is a legal filename character on Linux, so
# 'scripts\lib' would be one directory name there rather than two. CI runs on Ubuntu.
$libPath  = Join-Path (Join-Path $repoRoot 'scripts') 'lib'

# Collector is imported before its dependencies on purpose: it re-imports them with
# -Force, which drops them from this scope, so Normalize is imported after it.
Import-Module (Join-Path $libPath 'SafetyGuard.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $libPath 'Collector.psm1')   -Force -DisableNameChecking
Import-Module (Join-Path $libPath 'GraphClient.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $libPath 'Normalize.psm1')   -Force -DisableNameChecking

$script:Pass = 0
$script:Fail = 0

function Assert-That {
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][bool] $Condition, [string] $Detail)
    if ($Condition) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
        $script:Pass++
    }
    else {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkYellow }
        $script:Fail++
    }
}

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("entrabackup-test-" + [guid]::NewGuid().ToString('n').Substring(0,8))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

# Swap the real Graph call for a fixture feeder inside the Collector module's own scope,
# so the collector runs its genuine code path with no network involved.
$collectorModule = Get-Module Collector
& $collectorModule {
    # 'script:' is required here. A plain 'function Get-GraphCollection' inside this
    # block would live only for the duration of the block; script: puts it in the
    # module's own scope, where the collector's calls actually resolve.
    $script:MockData = @{}
    function script:Get-GraphCollection {
        param([string] $Uri, [hashtable] $AdditionalHeaders = @{}, [int] $MaxItems = 0)
        if ($script:MockData.ContainsKey($Uri)) { return , @($script:MockData[$Uri]) }
        return , @()
    }
}
function Set-Mock {
    param([string] $Uri, $Data)
    & $collectorModule { param($u, $d) $script:MockData[$u] = $d } $Uri $Data
}

$settings = @{ ShardThreshold = 2000; ShardCount = 16; MaxChildFetchParents = 5000 }

try {
    # ------------------------------------------------------------ determinism --
    Write-Host "`nDeterminism" -ForegroundColor Cyan

    $usersA = @(
        [pscustomobject]@{ id='aaaaaaaa-0000-0000-0000-000000000001'; displayName='Ann Lee'; userPrincipalName='ann@x.com'
                           '@odata.etag'='W/"1"'; onPremisesLastSyncDateTime='2026-08-18T01:00:00Z'
                           proxyAddresses=@('SMTP:ann@x.com','smtp:a.lee@x.com'); deletedDateTime=$null; accountEnabled=$true }
        [pscustomobject]@{ userPrincipalName='bob@x.com'; displayName='Bob Ray'; id='bbbbbbbb-0000-0000-0000-000000000002'
                           accountEnabled=$false; proxyAddresses=@('smtp:b@x.com'); '@odata.etag'='W/"2"'
                           onPremisesLastSyncDateTime='2026-08-18T01:00:00Z' }
    )
    $endpoint = @{ Name='users'; Category='directory'; Mode='Collection'; IdField='id'; NameField='userPrincipalName'
                   Uri='/v1.0/users' }
    Set-Mock -Uri '/v1.0/users' -Data $usersA

    $r1 = Invoke-EndpointCollection -Endpoint $endpoint -BackupRoot $sandbox -Settings $settings
    Assert-That -Name 'first run writes both objects' -Condition ($r1.Count -eq 2 -and $r1.Written -eq 2)

    $userDir = Join-Path (Join-Path $sandbox 'directory') 'users'
    Assert-That -Name 'files are named by immutable id' `
        -Condition (Test-Path (Join-Path $userDir 'aaaaaaaa-0000-0000-0000-000000000001.json'))
    Assert-That -Name '_index.json generated' -Condition (Test-Path (Join-Path $userDir '_index.json'))

    # Same data, keys and array order shuffled, volatile fields churned.
    $usersB = @(
        [pscustomobject]@{ accountEnabled=$false; id='bbbbbbbb-0000-0000-0000-000000000002'; proxyAddresses=@('smtp:b@x.com')
                           onPremisesLastSyncDateTime='2026-08-18T23:59:00Z'; '@odata.etag'='W/"CHANGED"'
                           displayName='Bob Ray'; userPrincipalName='bob@x.com' }
        [pscustomobject]@{ proxyAddresses=@('smtp:a.lee@x.com','SMTP:ann@x.com'); accountEnabled=$true
                           onPremisesLastSyncDateTime='2026-08-18T23:59:00Z'; displayName='Ann Lee'
                           id='aaaaaaaa-0000-0000-0000-000000000001'; '@odata.etag'='W/"CHANGED"'
                           userPrincipalName='ann@x.com'; deletedDateTime=$null }
    )
    Set-Mock -Uri '/v1.0/users' -Data $usersB
    $r2 = Invoke-EndpointCollection -Endpoint $endpoint -BackupRoot $sandbox -Settings $settings
    Assert-That -Name 'shuffled keys, reordered arrays and churned ETags produce zero writes' `
        -Condition ($r2.Written -eq 0) -Detail "expected 0 changed files, got $($r2.Written)"

    # ---------------------------------------------------------------- pruning --
    Write-Host "`nPruning" -ForegroundColor Cyan
    Set-Mock -Uri '/v1.0/users' -Data @($usersA[0])
    $r3 = Invoke-EndpointCollection -Endpoint $endpoint -BackupRoot $sandbox -Settings $settings
    Assert-That -Name 'deleted object is removed from the snapshot' `
        -Condition (-not (Test-Path (Join-Path $userDir 'bbbbbbbb-0000-0000-0000-000000000002.json')))
    Assert-That -Name 'surviving object is retained' `
        -Condition (Test-Path (Join-Path $userDir 'aaaaaaaa-0000-0000-0000-000000000001.json'))
    Assert-That -Name 'count reflects the deletion' -Condition ($r3.Count -eq 1)

    # --------------------------------------------------------------- sharding --
    Write-Host "`nSharding" -ForegroundColor Cyan
    $many = 1..60 | ForEach-Object {
        [pscustomobject]@{ id = ('cccccccc-0000-0000-0000-{0:d12}' -f $_); displayName = "Group $_"; securityEnabled = $true }
    }
    $shardEndpoint = @{ Name='groups'; Category='directory'; Mode='Collection'; IdField='id'; NameField='displayName'
                        Uri='/v1.0/groups' }
    Set-Mock -Uri '/v1.0/groups' -Data $many
    $shardSettings = @{ ShardThreshold = 10; ShardCount = 4; MaxChildFetchParents = 5000 }

    $s1 = Invoke-EndpointCollection -Endpoint $shardEndpoint -BackupRoot $sandbox -Settings $shardSettings
    $groupDir = Join-Path (Join-Path $sandbox 'directory') 'groups'
    $shardFiles = @(Get-ChildItem -Path $groupDir -Filter '*.ndjson')
    Assert-That -Name 'large collection switches to sharded layout' -Condition ($shardFiles.Count -eq 4)

    $totalLines = 0
    foreach ($f in $shardFiles) {
        $totalLines += @(Get-Content $f.FullName | Where-Object { $_.Trim() }).Count
    }
    Assert-That -Name 'every object lands in exactly one shard' -Condition ($totalLines -eq 60) `
        -Detail "expected 60 lines across shards, got $totalLines"

    $s2 = Invoke-EndpointCollection -Endpoint $shardEndpoint -BackupRoot $sandbox -Settings $shardSettings
    Assert-That -Name 're-running rewrites no shard' -Condition ($s2.Written -eq 0) `
        -Detail "expected 0, got $($s2.Written)"

    # Shard assignment must not depend on process-randomised hashing, so the same id is
    # hashed again in a separate process and the two results compared.
    #
    # The host executable is resolved rather than hardcoded: 'powershell' exists only on
    # Windows, and CI runs this on Linux where the host is 'pwsh'.
    $h1 = Get-ShardName -Id 'cccccccc-0000-0000-0000-000000000007' -ShardCount 4
    $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    $collectorPath = Join-Path $libPath 'Collector.psm1'
    $h2 = & $psExe -NoProfile -Command `
        "Import-Module '$collectorPath' -Force -DisableNameChecking; Get-ShardName -Id 'cccccccc-0000-0000-0000-000000000007' -ShardCount 4"
    Assert-That -Name 'shard assignment is stable across processes' -Condition ($h1 -eq ($h2 | Select-Object -Last 1).Trim()) `
        -Detail "this process ($psExe): $h1 / separate process: $h2"

    # ------------------------------------------------------------ safety guard --
    Write-Host "`nSafety guard" -ForegroundColor Cyan
    $prevPath = Join-Path (Join-Path $sandbox '_meta') 'prev.json'
    New-Item -ItemType Directory -Path (Split-Path $prevPath) -Force | Out-Null
    Write-NormalizedJsonFile -Path $prevPath -InputObject ([ordered]@{
        counts = [ordered]@{ users = 2000; groups = 50; conditionalAccessPolicies = 12 }
    }) | Out-Null

    $halved = Test-BackupSafety -PreviousRunPath $prevPath -CurrentCounts @{ users=1000; groups=50; conditionalAccessPolicies=12 }
    Assert-That -Name 'a 50% drop in users is blocked' -Condition (-not $halved.Passed)

    $emptied = Test-BackupSafety -PreviousRunPath $prevPath -CurrentCounts @{ users=2000; groups=50; conditionalAccessPolicies=0 }
    Assert-That -Name 'a collection emptying out is blocked' -Condition (-not $emptied.Passed)

    $normal = Test-BackupSafety -PreviousRunPath $prevPath -CurrentCounts @{ users=1990; groups=51; conditionalAccessPolicies=12 }
    Assert-That -Name 'ordinary churn passes' -Condition ($normal.Passed)

    $grown = Test-BackupSafety -PreviousRunPath $prevPath -CurrentCounts @{ users=9000; groups=50; conditionalAccessPolicies=12 }
    Assert-That -Name 'growth is never blocked' -Condition ($grown.Passed)

    # An unlicensed category must read as "skipped", never as a mass deletion.
    $skippedRun = Test-BackupSafety -PreviousRunPath $prevPath `
        -CurrentCounts @{ users=2000; groups=50 } -SkippedCollections @('conditionalAccessPolicies')
    Assert-That -Name 'a skipped licence-gated collection is not treated as deletion' -Condition ($skippedRun.Passed)

    $firstRun = Test-BackupSafety -PreviousRunPath (Join-Path $sandbox 'nope.json') -CurrentCounts @{ users=5 }
    Assert-That -Name 'first run has no baseline and passes' -Condition ($firstRun.Passed -and $firstRun.IsFirstRun)

    # ------------------------------------------------------------- singleton --
    Write-Host "`nSingleton endpoints" -ForegroundColor Cyan
    Set-Mock -Uri '/v1.0/policies/authorizationPolicy' -Data @([pscustomobject]@{ id='authorizationPolicy'; allowInvitesFrom='adminsAndGuestInviters' })
    $singleEndpoint = @{ Name='authorizationPolicy'; Category='policies'; Mode='Singleton'; Uri='/v1.0/policies/authorizationPolicy' }
    $sg = Invoke-EndpointCollection -Endpoint $singleEndpoint -BackupRoot $sandbox -Settings $settings
    Assert-That -Name 'singleton writes settings.json' `
        -Condition (Test-Path (Join-Path (Join-Path (Join-Path $sandbox 'policies') 'authorizationPolicy') 'settings.json'))
    $sg2 = Invoke-EndpointCollection -Endpoint $singleEndpoint -BackupRoot $sandbox -Settings $settings
    Assert-That -Name 'singleton is idempotent' -Condition ($sg2.Written -eq 0)
}
finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ('-' * 72) -ForegroundColor DarkGray
if ($script:Fail -eq 0) {
    Write-Host "All $($script:Pass) checks passed." -ForegroundColor Green
    exit 0
}
Write-Host "$($script:Pass) passed, $($script:Fail) failed." -ForegroundColor Red
exit 1
