<#
.SYNOPSIS
    Recreates a Conditional Access policy from a snapshot file.

.DESCRIPTION
    Deliberately not part of the scheduled workflow. The backup identity is read-only by
    design, and restore is a decision a person makes with their own credentials.

    Recreated policies are forced to state 'disabled' unless -EnableImmediately is
    given. Restoring a CA policy straight into enforcement is an excellent way to lock
    an entire tenant out of its own directory; review it in the portal, then enable it.

    A restored policy gets a NEW id. References to the old policy id -- in reports,
    scripts, or documentation -- will not follow.

.PARAMETER Path
    Path to the snapshot JSON, e.g. backup/policies/conditionalAccessPolicies/<id>.json

.PARAMETER EnableImmediately
    Restore in the state recorded in the snapshot rather than forcing it disabled.

.EXAMPLE
    .\Restore-ConditionalAccessPolicy.ps1 -Path ..\..\backup\policies\conditionalAccessPolicies\<id>.json
    Dry run: shows what would be created and changes nothing.

.EXAMPLE
    .\Restore-ConditionalAccessPolicy.ps1 -Path <file> -Confirm:$false
    Actually creates the policy, disabled.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string] $Path,
    [switch] $EnableImmediately,
    [string] $TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$libPath    = Join-Path (Split-Path -Parent $scriptRoot) 'lib'

Import-Module (Join-Path $libPath 'Auth.psm1')        -Force -DisableNameChecking
Import-Module (Join-Path $libPath 'GraphClient.psm1') -Force -DisableNameChecking

if (-not (Test-Path -LiteralPath $Path)) { throw "Snapshot file not found: $Path" }

$policy = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json

# Server-assigned fields must not be sent back; Graph rejects the create if they are.
$payload = @{}
foreach ($prop in $policy.PSObject.Properties) {
    if ($prop.Name -in @('id', 'createdDateTime', 'modifiedDateTime', 'templateId')) { continue }
    if ($prop.Name.StartsWith('@')) { continue }
    $payload[$prop.Name] = $prop.Value
}

if (-not $EnableImmediately) { $payload['state'] = 'disabled' }
$payload['displayName'] = "$($policy.displayName) (restored $(Get-Date -Format 'yyyy-MM-dd'))"

Write-Host ''
Write-Host 'Conditional Access policy restore' -ForegroundColor Cyan
Write-Host "  Source file  : $Path"
Write-Host "  Original id  : $($policy.id)"
Write-Host "  Original name: $($policy.displayName)"
Write-Host "  New name     : $($payload['displayName'])"
Write-Host "  State        : $($payload['state'])$(if (-not $EnableImmediately) { '  (forced -- review before enabling)' })"
Write-Host ''

if (-not $PSCmdlet.ShouldProcess($payload['displayName'], 'Create Conditional Access policy')) {
    Write-Host 'Dry run only. Re-run with -Confirm:$false to create it.' -ForegroundColor Yellow
    return
}

# Interactive sign-in with the operator's own credentials, and the write scope that the
# read-only backup identity deliberately does not hold.
$provider = Get-EntraTokenProvider -Mode DeviceCode -TenantId $TenantId
Initialize-GraphClient -TokenProvider $provider

$json   = $payload | ConvertTo-Json -Depth 100
$result = Invoke-GraphRequest -Uri '/v1.0/identity/conditionalAccess/policies' -Method POST -Body $json

Write-Host "Created policy $($result.id) in state '$($result.state)'." -ForegroundColor Green
Write-Host 'Review it in the portal before enabling.' -ForegroundColor Yellow
