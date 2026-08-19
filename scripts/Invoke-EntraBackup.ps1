<#
.SYNOPSIS
    Snapshots Microsoft Entra tenant configuration into deterministic JSON for git.

.DESCRIPTION
    Collects every endpoint listed in config/endpoints.psd1, normalises each object so
    an unchanged tenant produces byte-identical files, and compares object counts
    against the previous run before anything is committed.

.PARAMETER Category
    Limit collection to these categories (directory, policies, applications,
    governance, intune). Defaults to all of them.

.PARAMETER AuthMode
    Auto picks OIDC inside GitHub Actions, ClientSecret when a secret is supplied, and
    interactive DeviceCode otherwise.

.PARAMETER AcceptShrink
    Bypasses the mass-deletion tripwire. Use only after confirming that a large drop in
    object count is a real change in the tenant and not a partially failed run.

.EXAMPLE
    .\scripts\Invoke-EntraBackup.ps1 -Category directory
    Interactive local run against one category.

.EXAMPLE
    .\scripts\Invoke-EntraBackup.ps1 -AuthMode OIDC -TenantId $env:AZURE_TENANT_ID -ClientId $env:AZURE_CLIENT_ID
    The production path, as invoked by .github/workflows/backup.yml.

.OUTPUTS
    Exit code 0 on success, 1 on error, 2 when the safety guard blocks the run.
#>
[CmdletBinding()]
param(
    [string[]] $Category,
    [ValidateSet('Auto', 'OIDC', 'DeviceCode', 'ClientSecret')]
    [string] $AuthMode = 'Auto',
    [string] $TenantId = $env:AZURE_TENANT_ID,
    [string] $ClientId = $env:AZURE_CLIENT_ID,
    [string] $ClientSecret = $env:AZURE_CLIENT_SECRET,
    [string] $BackupRoot,
    [switch] $AcceptShrink
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot   = Split-Path -Parent $scriptRoot
if (-not $BackupRoot) { $BackupRoot = Join-Path $repoRoot 'backup' }

# Path segments are joined one at a time rather than written as 'lib\Auth.psm1'. A
# backslash is a legal filename character on Linux, so an embedded separator becomes
# part of the name instead of a directory boundary -- and CI runs on Ubuntu.
$libRoot    = Join-Path $scriptRoot 'lib'
$configRoot = Join-Path $repoRoot 'config'

# Import order matters, and leaf modules must come FIRST.
#
# Module state is per-instance. GraphClient holds the access token and token provider in
# its own scope, so if Collector were to load a second instance of it, Initialize-GraphClient
# below would configure one instance while every collection call reached the other.
# Loading GraphClient and Normalize up front means Collector's own (non -Force) imports
# resolve to these exact instances, and there is one shared client throughout.
Import-Module (Join-Path $libRoot 'GraphClient.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $libRoot 'Normalize.psm1')   -Force -DisableNameChecking
Import-Module (Join-Path $libRoot 'Auth.psm1')        -Force -DisableNameChecking
Import-Module (Join-Path $libRoot 'SafetyGuard.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $libRoot 'Collector.psm1')   -Force -DisableNameChecking

$settings  = Import-PowerShellDataFile -Path (Join-Path $configRoot 'settings.psd1')
$manifest  = Import-PowerShellDataFile -Path (Join-Path $configRoot 'endpoints.psd1')
$startTime = Get-Date

if (-not $Category) { $Category = $settings.DefaultCategories }

$endpoints = @($manifest.Endpoints | Where-Object { $Category -contains $_.Category })
if ($endpoints.Count -eq 0) {
    Write-Error "No endpoints match category filter: $($Category -join ', ')"
    exit 1
}

Write-Host ''
Write-Host 'Entra Tenant Backup' -ForegroundColor Cyan
Write-Host ('=' * 72) -ForegroundColor DarkGray
Write-Host "  Categories : $($Category -join ', ')"
Write-Host "  Endpoints  : $($endpoints.Count)"
Write-Host "  Target     : $BackupRoot"
Write-Host ''

# --------------------------------------------------------------------- connect --
try {
    $provider = Get-EntraTokenProvider -Mode $AuthMode -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
    Initialize-GraphClient -TokenProvider $provider -MaxRetries ([int]$settings.MaxRetries)

    # Doubles as an auth smoke test: if this fails, nothing else was ever going to work.
    $org = Get-GraphCollection -Uri '/v1.0/organization'
    if ($org.Count -eq 0) { throw 'Could not read /organization. The token has no directory access.' }

    $tenantDisplayName = $org[0].displayName
    $resolvedTenantId  = $org[0].id
    Write-Host "  Connected to: $tenantDisplayName ($resolvedTenantId)" -ForegroundColor Green
    Write-Host ''
}
catch {
    Write-Host ''
    Write-Error "Authentication failed: $($_.Exception.Message)"
    exit 1
}

# ------------------------------------------------------------------- previous --
# Read the prior run before collection overwrites anything, so the tripwire has a
# baseline to compare against.
$metaPath        = Join-Path (Join-Path $BackupRoot '_meta') 'run.json'
$previousRunPath = if (Test-Path -LiteralPath $metaPath) { $metaPath } else { $null }

# -------------------------------------------------------------------- collect --
Write-Host 'Collecting' -ForegroundColor Cyan
Write-Host ('-' * 72) -ForegroundColor DarkGray

$counts     = @{}
$skipped    = New-Object System.Collections.ArrayList
$results    = New-Object System.Collections.ArrayList
$failed     = New-Object System.Collections.ArrayList

foreach ($endpoint in $endpoints) {
    try {
        $result = Invoke-EndpointCollection -Endpoint $endpoint -BackupRoot $BackupRoot -Settings $settings
        [void]$results.Add($result)

        if ($result.Status -eq 'Skipped') {
            [void]$skipped.Add($result.Name)
        }
        else {
            $counts[$result.Name] = $result.Count
        }
    }
    catch {
        Write-Host ''
        Write-Warning "$($endpoint.Name) failed: $($_.Exception.Message)"
        [void]$failed.Add($endpoint.Name)
    }
}

Write-Host ''

# A mandatory endpoint blowing up means the snapshot is incomplete. Committing it would
# record objects as deleted that were merely unreadable this run.
if ($failed.Count -gt 0) {
    Write-Host 'Failed endpoints:' -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ''
    Write-Error 'One or more required endpoints failed; refusing to record an incomplete snapshot.'
    exit 1
}

# --------------------------------------------------------------------- safety --
Write-Host 'Safety check' -ForegroundColor Cyan
Write-Host ('-' * 72) -ForegroundColor DarkGray

$safety = Test-BackupSafety `
    -PreviousRunPath $previousRunPath `
    -CurrentCounts $counts `
    -MaxShrinkFraction ([double]$settings.MaxShrinkFraction) `
    -FailOnEmptyCollection ([bool]$settings.FailOnEmptyCollection) `
    -SkippedCollections $skipped.ToArray()

Write-SafetyReport -Result $safety
Write-Host ''

if (-not $safety.Passed -and -not $AcceptShrink) {
    Write-Host 'SAFETY GUARD TRIPPED' -ForegroundColor Red
    $safety.Violations | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'This usually means the run was throttled or lost a permission part-way,' -ForegroundColor Yellow
    Write-Host 'not that the objects were really deleted. Nothing has been committed.' -ForegroundColor Yellow
    Write-Host 'If the drop is genuine, re-run with -AcceptShrink.' -ForegroundColor Yellow
    exit 2
}

if (-not $safety.Passed -and $AcceptShrink) {
    Write-Warning 'Safety guard tripped but -AcceptShrink was supplied; recording the snapshot anyway.'
}

# ----------------------------------------------------------------------- meta --
$stats    = Get-GraphClientStats
$duration = (Get-Date) - $startTime

$orderedCounts = [ordered]@{}
foreach ($k in ($counts.Keys | Sort-Object)) { $orderedCounts[$k] = $counts[$k] }

$runMeta = [ordered]@{
    schemaVersion     = 1
    tenantId          = $resolvedTenantId
    tenantDisplayName = $tenantDisplayName
    # Second precision, UTC: this is the one field that legitimately changes every run.
    capturedAtUtc     = $startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    durationSeconds   = [math]::Round($duration.TotalSeconds, 1)
    categories        = @($Category | Sort-Object)
    graphRequests     = $stats.RequestCount
    throttleEvents    = $stats.ThrottleEvents
    skippedEndpoints  = @($skipped.ToArray() | Sort-Object)
    counts            = $orderedCounts
}

Write-NormalizedJsonFile -Path $metaPath -InputObject $runMeta | Out-Null

# -------------------------------------------------------------------- summary --
$totalObjects = 0
foreach ($v in $counts.Values) { $totalObjects += [int]$v }

Write-Host 'Summary' -ForegroundColor Cyan
Write-Host ('-' * 72) -ForegroundColor DarkGray
Write-Host "  Collections   : $($counts.Count)"
Write-Host "  Objects       : $totalObjects"
Write-Host "  Graph requests: $($stats.RequestCount)"
Write-Host "  Throttled     : $($stats.ThrottleEvents)"
Write-Host "  Skipped       : $($skipped.Count)$(if ($skipped.Count) { " ($($skipped -join ', '))" })"
Write-Host "  Duration      : $([math]::Round($duration.TotalSeconds,1))s"
Write-Host ''
Write-Host 'Backup complete.' -ForegroundColor Green
Write-Host ''

exit 0
