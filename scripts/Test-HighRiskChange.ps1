<#
.SYNOPSIS
    Flags security-relevant changes in a pending backup snapshot.

.DESCRIPTION
    A commit history nobody reads is only half a control. This inspects the staged diff
    and separates changes that warrant a human look -- a Conditional Access policy
    disabled, a Global Administrator added, a new app credential, a fresh consent grant
    -- from the ordinary churn of people joining and leaving.

    Intended to run after `git add -A` and before `git commit`, so the findings can go
    into the commit message and raise a GitHub issue.

.PARAMETER Staged
    Inspect staged changes -- what the workflow uses, since it runs between `git add`
    and `git commit`. Without it, compares the range in -Range instead.

.OUTPUTS
    Markdown report on stdout. Exit code 0 always -- this reports, it does not block.
    Sets 'high_risk=true|false' and 'finding_count' in $env:GITHUB_OUTPUT when present.
#>
[CmdletBinding()]
param(
    [switch] $Staged,
    [string] $Range = 'HEAD~1..HEAD'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot   = Split-Path -Parent $scriptRoot
$settings   = Import-PowerShellDataFile -Path (Join-Path (Join-Path $repoRoot 'config') 'settings.psd1')

$changes = if ($Staged) {
    git -C $repoRoot diff --cached --name-status
} else {
    git -C $repoRoot diff --name-status $Range
}

if (-not $changes) {
    Write-Host 'No changes to inspect.'
    if ($env:GITHUB_OUTPUT) {
        "high_risk=false"  | Out-File $env:GITHUB_OUTPUT -Append -Encoding utf8
        "finding_count=0"  | Out-File $env:GITHUB_OUTPUT -Append -Encoding utf8
    }
    return
}

$findings = New-Object System.Collections.ArrayList
$ordinary = 0

foreach ($line in @($changes)) {
    if (-not $line.Trim()) { continue }

    $parts  = $line -split "`t"
    $status = $parts[0]
    $path   = if ($parts.Count -gt 1) { $parts[-1] } else { continue }
    $normalisedPath = $path -replace '\\', '/'

    $isHighRisk = $false
    foreach ($riskPath in @($settings.HighRiskPaths)) {
        if ($normalisedPath.StartsWith(($riskPath -replace '\\', '/'))) { $isHighRisk = $true; break }
    }

    if (-not $isHighRisk) { $ordinary++; continue }

    $verb = switch -Wildcard ($status) {
        'A*' { 'added' }
        'D*' { 'REMOVED' }
        'M*' { 'modified' }
        'R*' { 'renamed' }
        default { $status }
    }

    $area = switch -Wildcard ($normalisedPath) {
        '*conditionalAccessPolicies*' { 'Conditional Access' }
        '*authorizationPolicy*'       { 'Tenant authorization policy' }
        '*authenticationMethodsPolicy*' { 'Authentication methods policy' }
        '*roleAssignments*'           { 'Directory role assignment' }
        '*roleEligibilitySchedules*'  { 'PIM eligible assignment' }
        '*directoryRoles*'            { 'Directory role membership' }
        '*oauth2PermissionGrants*'    { 'OAuth consent grant' }
        default                       { 'Security configuration' }
    }

    # A policy switched off is materially different from one merely edited, and is worth
    # calling out separately -- it is the change most likely to be an attack or a mistake.
    $detail = ''
    if ($verb -eq 'modified' -and $normalisedPath -like '*conditionalAccessPolicies*') {
        $diff = if ($Staged) {
            git -C $repoRoot diff --cached -U0 -- $path
        } else {
            git -C $repoRoot diff -U0 $Range -- $path
        }
        if ($diff -match '(?m)^\+\s*"state":\s*"disabled"') {
            $detail = ' — **policy switched to disabled**'
        }
        elseif ($diff -match '(?m)^\+\s*"state":\s*"enabled"') {
            $detail = ' — policy enabled'
        }
    }

    [void]$findings.Add([pscustomobject]@{
        Area = $area; Verb = $verb; Path = $normalisedPath; Detail = $detail
    })
}

$report = New-Object System.Text.StringBuilder
if ($findings.Count -eq 0) {
    [void]$report.AppendLine("No security-relevant changes. $ordinary other file(s) changed.")
}
else {
    [void]$report.AppendLine("## Security-relevant changes detected")
    [void]$report.AppendLine('')
    [void]$report.AppendLine("$($findings.Count) change(s) touched security configuration, alongside $ordinary routine change(s).")
    [void]$report.AppendLine('')

    foreach ($group in ($findings | Group-Object Area | Sort-Object Name)) {
        [void]$report.AppendLine("### $($group.Name)")
        foreach ($f in $group.Group) {
            [void]$report.AppendLine("- $($f.Verb): ``$($f.Path)``$($f.Detail)")
        }
        [void]$report.AppendLine('')
    }

    [void]$report.AppendLine('Review the commit diff to confirm each change was intended.')
}

$text = $report.ToString()
Write-Host $text

if ($env:GITHUB_OUTPUT) {
    "high_risk=$($findings.Count -gt 0)".ToLower() | Out-File $env:GITHUB_OUTPUT -Append -Encoding utf8
    "finding_count=$($findings.Count)"             | Out-File $env:GITHUB_OUTPUT -Append -Encoding utf8
}
if ($env:GITHUB_STEP_SUMMARY) {
    $text | Out-File $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

# Also left on disk so the workflow can use it as an issue body.
$text | Out-File -FilePath (Join-Path $repoRoot 'high-risk-report.md') -Encoding utf8
