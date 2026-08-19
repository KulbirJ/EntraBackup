<#
.SYNOPSIS
    Lists and restores soft-deleted directory objects within the ~30-day window.

.DESCRIPTION
    This is the only path that restores an object with its ORIGINAL id, which is what
    makes it categorically better than recreating from a snapshot file.

    Recreating a user from JSON produces a new GUID, so every group membership, role
    assignment, ACL, mailbox permission and file share that referenced the original
    still points at nothing. Restoring from deletedItems preserves the id and every
    reference with it.

    That window is roughly 30 days and cannot be extended. Past it, the snapshot tells
    you what to rebuild but the references are unavoidably lost.

.PARAMETER Type
    users, groups, or applications.

.PARAMETER List
    Show what is currently restorable and exit.

.PARAMETER Id
    Object id to restore. Find it in the snapshot or via -List.

.EXAMPLE
    .\Restore-DeletedObject.ps1 -Type users -List

.EXAMPLE
    .\Restore-DeletedObject.ps1 -Type users -Id <guid> -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [ValidateSet('users', 'groups', 'applications')] [string] $Type,
    [switch] $List,
    [string] $Id,
    [string] $TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$libPath    = Join-Path (Split-Path -Parent $scriptRoot) 'lib'

Import-Module (Join-Path $libPath 'Auth.psm1')        -Force -DisableNameChecking
Import-Module (Join-Path $libPath 'GraphClient.psm1') -Force -DisableNameChecking

$graphType = @{ users = 'microsoft.graph.user'; groups = 'microsoft.graph.group'; applications = 'microsoft.graph.application' }[$Type]

$scopes = switch ($Type) {
    'users'        { @('User.ReadWrite.All', 'Directory.ReadWrite.All') }
    'groups'       { @('Group.ReadWrite.All', 'Directory.ReadWrite.All') }
    'applications' { @('Application.ReadWrite.All') }
}

$provider = Get-EntraTokenProvider -Mode DeviceCode -TenantId $TenantId
Initialize-GraphClient -TokenProvider $provider

if ($List -or -not $Id) {
    $deleted = Get-GraphCollection -Uri "/v1.0/directory/deletedItems/$graphType"

    if ($deleted.Count -eq 0) {
        Write-Host "No deleted $Type are currently restorable." -ForegroundColor Yellow
        return
    }

    Write-Host ''
    Write-Host "Restorable deleted $Type ($($deleted.Count)):" -ForegroundColor Cyan
    Write-Host ''

    foreach ($item in $deleted) {
        # Entra purges at roughly 30 days; the remaining window is the useful number.
        $remaining = ''
        if ($item.PSObject.Properties.Name -contains 'deletedDateTime' -and $item.deletedDateTime) {
            $days = 30 - ([datetime]::UtcNow - [datetime]$item.deletedDateTime).TotalDays
            $remaining = "{0:N1} days left" -f [math]::Max($days, 0)
        }
        $label = if ($item.PSObject.Properties.Name -contains 'userPrincipalName' -and $item.userPrincipalName) {
            $item.userPrincipalName
        } else { $item.displayName }

        Write-Host ("  {0,-46} {1,-38} {2}" -f $label, $item.id, $remaining)
    }

    Write-Host ''
    Write-Host "Restore with: -Type $Type -Id <id> -Confirm:`$false" -ForegroundColor DarkGray
    return
}

if (-not $PSCmdlet.ShouldProcess($Id, "Restore deleted $Type object")) {
    Write-Host 'Dry run only. Re-run with -Confirm:$false to restore.' -ForegroundColor Yellow
    return
}

$result = Invoke-GraphRequest -Uri "/v1.0/directory/deletedItems/$Id/restore" -Method POST

Write-Host ''
Write-Host "Restored $($result.displayName) with its original id $($result.id)." -ForegroundColor Green
Write-Host 'Group memberships and role assignments that referenced this id are intact.' -ForegroundColor Green
