<#
.SYNOPSIS
    Mass-deletion tripwire. Blocks a commit when a run looks partially failed.

.DESCRIPTION
    The dangerous failure mode for this tool is not a crash -- a crash is obvious and
    commits nothing. It is the partial success: throttling, a revoked permission, or a
    transient Graph fault returns 20 users where there were 2,000, the collector writes
    what it got, and the run commits a fictional mass deletion over the top of real
    history.

    So the run is compared against the object counts recorded in the previous
    _meta/run.json before anything is committed. Any collection that shrinks past the
    configured fraction, or empties out entirely, aborts the run.

    Growth is never blocked. Onboarding 500 users is not a hazard; losing 500 is.
#>

Set-StrictMode -Version Latest

function Test-BackupSafety {
    <#
    .SYNOPSIS
        Compares this run's counts against the previous run's.
    .PARAMETER PreviousRunPath
        Path to the prior _meta/run.json. A missing file means this is the first run,
        which always passes -- there is no baseline to shrink from.
    .PARAMETER CurrentCounts
        Hashtable of collection name -> object count from this run.
    .OUTPUTS
        PSCustomObject with Passed, Violations, and Comparisons.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] [string] $PreviousRunPath,
        [Parameter(Mandatory)] [hashtable] $CurrentCounts,
        [double] $MaxShrinkFraction = 0.20,
        [bool] $FailOnEmptyCollection = $true,
        [string[]] $SkippedCollections = @()
    )

    $violations  = New-Object System.Collections.ArrayList
    $comparisons = New-Object System.Collections.ArrayList

    if (-not $PreviousRunPath -or -not (Test-Path -LiteralPath $PreviousRunPath)) {
        Write-Verbose 'No previous run found; treating as first run and skipping shrink checks.'
        return [pscustomobject]@{
            Passed      = $true
            IsFirstRun  = $true
            Violations  = @()
            Comparisons = @()
        }
    }

    $previous = Get-Content -LiteralPath $PreviousRunPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not ($previous.PSObject.Properties.Name -contains 'counts')) {
        Write-Warning 'Previous run file has no counts block; skipping shrink checks.'
        return [pscustomobject]@{
            Passed      = $true
            IsFirstRun  = $true
            Violations  = @()
            Comparisons = @()
        }
    }

    foreach ($prop in $previous.counts.PSObject.Properties) {
        $name         = $prop.Name
        $previousCount = [int]$prop.Value

        # A collection deliberately skipped this run (licence gone, -Category filter)
        # has no current count to compare, and must not read as a deletion.
        if ($SkippedCollections -contains $name) {
            [void]$comparisons.Add([pscustomobject]@{
                Collection = $name; Previous = $previousCount; Current = $null
                Delta = $null; Status = 'Skipped'
            })
            continue
        }

        if (-not $CurrentCounts.ContainsKey($name)) {
            [void]$comparisons.Add([pscustomobject]@{
                Collection = $name; Previous = $previousCount; Current = $null
                Delta = $null; Status = 'NotCollected'
            })
            continue
        }

        $currentCount = [int]$CurrentCounts[$name]
        $delta        = $currentCount - $previousCount
        $status       = 'OK'

        if ($previousCount -gt 0) {
            if ($currentCount -eq 0 -and $FailOnEmptyCollection) {
                $status = 'EMPTY'
                [void]$violations.Add("$name returned 0 objects but held $previousCount in the previous run.")
            }
            else {
                $shrink = ($previousCount - $currentCount) / [double]$previousCount
                if ($shrink -gt $MaxShrinkFraction) {
                    $status = 'SHRANK'
                    [void]$violations.Add(
                        ("{0} shrank {1:P1} ({2} -> {3}), exceeding the {4:P0} limit." -f `
                            $name, $shrink, $previousCount, $currentCount, $MaxShrinkFraction))
                }
            }
        }

        [void]$comparisons.Add([pscustomobject]@{
            Collection = $name; Previous = $previousCount; Current = $currentCount
            Delta = $delta; Status = $status
        })
    }

    return [pscustomobject]@{
        Passed      = ($violations.Count -eq 0)
        IsFirstRun  = $false
        Violations  = $violations.ToArray()
        Comparisons = $comparisons.ToArray()
    }
}

function Write-SafetyReport {
    <#
    .SYNOPSIS
        Renders the comparison table, showing only rows that moved.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Result)

    if ($Result.IsFirstRun) {
        Write-Host '  First run -- no baseline to compare against.' -ForegroundColor DarkGray
        return
    }

    $changed = @($Result.Comparisons | Where-Object { $_.Status -ne 'OK' -or ($null -ne $_.Delta -and $_.Delta -ne 0) })
    if ($changed.Count -eq 0) {
        Write-Host '  No object counts changed since the previous run.' -ForegroundColor DarkGray
        return
    }

    foreach ($row in $changed) {
        $colour = switch ($row.Status) {
            'EMPTY'  { 'Red' }
            'SHRANK' { 'Red' }
            'Skipped'      { 'DarkGray' }
            'NotCollected' { 'DarkGray' }
            default  { if ($row.Delta -lt 0) { 'Yellow' } else { 'Green' } }
        }
        $deltaText = if ($null -eq $row.Delta) { $row.Status } `
                     elseif ($row.Delta -ge 0)  { "+$($row.Delta)" } `
                     else                       { "$($row.Delta)" }
        Write-Host ("  {0,-36} {1,6} -> {2,-6} {3}" -f `
            $row.Collection, $row.Previous, "$($row.Current)", $deltaText) -ForegroundColor $colour
    }
}

Export-ModuleMember -Function Test-BackupSafety, Write-SafetyReport
