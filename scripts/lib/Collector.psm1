<#
.SYNOPSIS
    Interprets config/endpoints.psd1 and writes normalised snapshots to disk.

.DESCRIPTION
    One generic collection routine drives every endpoint, so adding a backup target is
    a manifest edit rather than new code.

    Two layout modes:
      per-object  One <guid>.json per object. Readable diffs, easy to browse.
      sharded     Newline-delimited JSON split across a fixed number of shards, used
                  once a collection exceeds ShardThreshold. A directory holding tens of
                  thousands of files makes git slow and the GitHub UI unusable; shards
                  keep both workable. Objects are assigned by GUID prefix so an object
                  never migrates between shards and a change touches exactly one.

    Stale files are pruned. Without that step a deleted user would linger in the
    snapshot forever and the backup would quietly stop reflecting the tenant.
#>

Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# Imported WITHOUT -Force, deliberately.
#
# -Force here would load a second, separate instance of GraphClient rather than reuse
# the one the caller already set up. Module state is per-instance, so Initialize-GraphClient
# called by the entry script would configure one instance while every collection call from
# this module reached the other -- which fails with "Graph client not initialised" only
# against a real tenant, since the offline tests mock this exact seam.
Import-Module (Join-Path $here 'GraphClient.psm1') -DisableNameChecking
Import-Module (Join-Path $here 'Normalize.psm1')   -DisableNameChecking

function Get-ShardName {
    <#
    .SYNOPSIS
        Maps an object id to a stable shard index.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [int] $ShardCount
    )

    # FNV-1a over the id. Cheap, well-distributed, and identical on every platform --
    # unlike GetHashCode(), which is randomised per process in .NET Core and would
    # reshuffle every object into a new shard on every run.
    $hash = [uint32]2166136261
    foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($Id)) {
        $hash = [uint32]($hash -bxor $b)
        # The multiply is done in 64 bits and masked back down: PowerShell widens rather
        # than wrapping on overflow, so multiplying directly in uint32 throws instead of
        # producing the truncation FNV-1a depends on.
        #
        # The mask is written in decimal deliberately. Windows PowerShell 5.1 parses the
        # hex literal 0xFFFFFFFF as Int32 -1, which makes -band a silent no-op and lets
        # the value overflow anyway.
        $hash = [uint32]((([uint64]$hash * 16777619) -band 4294967295))
    }
    return 'shard-{0:d2}.ndjson' -f ($hash % $ShardCount)
}

function Invoke-EndpointCollection {
    <#
    .SYNOPSIS
        Collects one manifest endpoint and writes it beneath $BackupRoot.
    .OUTPUTS
        PSCustomObject with Name, Category, Count, Status and Written.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Endpoint,
        [Parameter(Mandatory)] [string] $BackupRoot,
        [Parameter(Mandatory)] [hashtable] $Settings
    )

    $name     = $Endpoint.Name
    $category = $Endpoint.Category
    $mode     = $Endpoint.Mode
    $optional = $Endpoint.ContainsKey('Optional') -and $Endpoint.Optional
    $target   = Join-Path (Join-Path $BackupRoot $category) $name

    Write-Host ("  {0,-38} " -f $name) -NoNewline

    try {
        $items = Get-GraphCollection -Uri $Endpoint.Uri
    }
    catch {
        if (-not (Test-GraphPermissionError -ErrorRecord $_)) {
            Write-Host 'FAILED' -ForegroundColor Red
            throw
        }
        if ($optional) {
            # Almost always a licensing gap (P1/P2/Intune) or a feature the tenant does
            # not use. Skipping keeps one missing SKU from failing the whole backup.
            Write-Host 'skipped (not licensed or not permitted)' -ForegroundColor DarkGray
            return [pscustomobject]@{
                Name = $name; Category = $category; Count = $null
                Status = 'Skipped'; Written = 0; Message = $_.Exception.Message
            }
        }
        Write-Host 'FAILED' -ForegroundColor Red
        throw
    }

    if ($mode -eq 'Singleton') {
        # /v1.0/organization is a collection of one; the rest are true singletons.
        $payload = if ($items.Count -eq 1) { $items[0] } else { $items }
        $written = Write-NormalizedJsonFile -Path (Join-Path $target 'settings.json') -InputObject $payload
        Write-Host 'ok (singleton)' -ForegroundColor Green
        return [pscustomobject]@{
            Name = $name; Category = $category; Count = 1
            Status = 'OK'; Written = [int]$written; Message = $null
        }
    }

    $idField = $Endpoint.IdField
    if ($Endpoint.ContainsKey('Children') -and $items.Count -gt 0) {
        $items = Add-ChildCollections -Items $items -Endpoint $Endpoint -Settings $Settings
    }

    $useShards = $items.Count -gt [int]$Settings.ShardThreshold
    if ($useShards) {
        $result = Write-ShardedCollection -Items $items -Target $target -IdField $idField -ShardCount ([int]$Settings.ShardCount)
    }
    else {
        $result = Write-PerObjectCollection -Items $items -Target $target -IdField $idField
    }

    Write-CollectionIndex -Items $items -Target $target -Endpoint $Endpoint -Sharded:$useShards

    $layout = if ($useShards) { 'sharded' } else { 'files' }
    Write-Host ("ok  {0,6} objects ({1}, {2} changed)" -f $items.Count, $layout, $result.Written) -ForegroundColor Green

    return [pscustomobject]@{
        Name = $name; Category = $category; Count = $items.Count
        Status = 'OK'; Written = $result.Written; Message = $null
    }
}

function Add-ChildCollections {
    <#
    .SYNOPSIS
        Fetches per-parent sub-collections and folds them into the parent object.
    .DESCRIPTION
        Members and owners are merged into the group's own file rather than written
        alongside it, which keeps each group self-contained for restore and keeps the
        diff of a membership change in one place.

        These are N+1 requests and dominate runtime on large tenants, hence the
        MaxChildFetchParents ceiling.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] $Items,
        [Parameter(Mandatory)] [hashtable] $Endpoint,
        [Parameter(Mandatory)] [hashtable] $Settings
    )

    $limit = [int]$Settings.MaxChildFetchParents
    $all   = @($Items)

    if ($limit -gt 0 -and $all.Count -gt $limit) {
        Write-Host ''
        Write-Warning "$($Endpoint.Name): $($all.Count) parents exceeds MaxChildFetchParents ($limit); child collections skipped."
        return , $all
    }

    $idField = $Endpoint.IdField
    $index   = 0

    foreach ($item in $all) {
        $index++
        $parentId = $item.$idField
        if (-not $parentId) { continue }

        foreach ($child in @($Endpoint.Children)) {
            $childUri = $child.Uri -replace '\{id\}', [uri]::EscapeDataString([string]$parentId)
            try {
                $childItems = Get-GraphCollection -Uri $childUri
            }
            catch {
                # A child collection we cannot read (a role we lack rights over, a
                # group whose members are hidden) should not sink the parent object.
                if (-not (Test-GraphPermissionError -ErrorRecord $_)) { throw }
                $childItems = @()
            }

            # Added as a normal property so the existing array-sort rules in
            # Normalize.psm1 apply and membership order stops mattering.
            Add-Member -InputObject $item -NotePropertyName $child.Name `
                       -NotePropertyValue @($childItems) -Force
        }

        if ($index % 100 -eq 0) { Write-Host '.' -NoNewline -ForegroundColor DarkGray }
    }

    return , $all
}

function Write-PerObjectCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] $Items,
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [string] $IdField
    )

    if (-not (Test-Path -LiteralPath $Target)) {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
    }

    $expected = New-Object System.Collections.Generic.HashSet[string]
    $written  = 0

    foreach ($item in @($Items)) {
        $id = [string]$item.$IdField
        if (-not $id) {
            Write-Warning "Object in $Target has no '$IdField'; skipped."
            continue
        }

        $fileName = (Get-SafeFileName -Name $id) + '.json'
        [void]$expected.Add($fileName)
        if (Write-NormalizedJsonFile -Path (Join-Path $Target $fileName) -InputObject $item) { $written++ }
    }

    $removed = Remove-StaleFiles -Target $Target -Expected $expected -Pattern '*.json'
    return [pscustomobject]@{ Written = $written; Removed = $removed }
}

function Write-ShardedCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] $Items,
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [string] $IdField,
        [Parameter(Mandatory)] [int] $ShardCount
    )

    if (-not (Test-Path -LiteralPath $Target)) {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
    }

    # Objects are grouped by shard, then sorted by id inside each shard, so line order
    # is a function of content alone and never of the order Graph happened to return.
    $buckets = @{}
    for ($i = 0; $i -lt $ShardCount; $i++) {
        $buckets['shard-{0:d2}.ndjson' -f $i] = New-Object System.Collections.ArrayList
    }

    foreach ($item in @($Items)) {
        $id = [string]$item.$IdField
        if (-not $id) { continue }
        [void]$buckets[(Get-ShardName -Id $id -ShardCount $ShardCount)].Add($item)
    }

    $expected = New-Object System.Collections.Generic.HashSet[string]
    $written  = 0

    foreach ($shardName in ($buckets.Keys | Sort-Object)) {
        [void]$expected.Add($shardName)
        $lines = New-Object System.Collections.ArrayList

        foreach ($item in ($buckets[$shardName] | Sort-Object { [string]$_.$IdField })) {
            $normalized = ConvertTo-NormalizedObject -InputObject $item
            [void]$lines.Add((ConvertTo-DeterministicJson -InputObject $normalized -Compact))
        }

        $content = if ($lines.Count -gt 0) { ($lines -join "`n") + "`n" } else { '' }
        $path    = Join-Path $Target $shardName

        $unchanged = $false
        if (Test-Path -LiteralPath $path) {
            $existing = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false))
            $unchanged = ($existing -eq $content)
        }
        if (-not $unchanged) {
            [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
            $written++
        }
    }

    $removed = Remove-StaleFiles -Target $Target -Expected $expected -Pattern '*.ndjson'
    # Switching from per-object to sharded layout leaves the old files behind.
    $removed += Remove-StaleFiles -Target $Target -Expected (New-Object System.Collections.Generic.HashSet[string]) -Pattern '*.json' -Exclude '_index.json'

    return [pscustomobject]@{ Written = $written; Removed = $removed }
}

function Write-CollectionIndex {
    <#
    .SYNOPSIS
        Writes _index.json mapping immutable ids to human-readable names.
    .DESCRIPTION
        Files are named by GUID so a rename does not read as delete-plus-add. This index
        is what makes the snapshot navigable by a human, and it turns a rename into a
        one-line diff instead of two large ones.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] $Items,
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [hashtable] $Endpoint,
        [switch] $Sharded
    )

    $idField   = $Endpoint.IdField
    $nameField = if ($Endpoint.ContainsKey('NameField')) { $Endpoint.NameField } else { $null }

    $entries = @{}
    foreach ($item in @($Items)) {
        $id = [string]$item.$idField
        if (-not $id) { continue }
        $label = ''
        if ($nameField -and $item.PSObject.Properties.Name -contains $nameField) {
            $label = [string]$item.$nameField
        }
        $entries[$id] = $label
    }

    $ordered = [ordered]@{}
    foreach ($k in ($entries.Keys | Sort-Object -CaseSensitive)) { $ordered[$k] = $entries[$k] }

    $index = [ordered]@{
        collection = $Endpoint.Name
        count      = $entries.Count
        idField    = $idField
        layout     = if ($Sharded) { 'sharded-ndjson' } else { 'per-object' }
        items      = $ordered
    }

    Write-NormalizedJsonFile -Path (Join-Path $Target '_index.json') -InputObject $index | Out-Null
}

function Remove-StaleFiles {
    <#
    .SYNOPSIS
        Deletes files no longer backed by a live object.
    .DESCRIPTION
        Without pruning, deleted users and policies would linger indefinitely and the
        snapshot would drift out of step with the tenant. The mass-deletion tripwire in
        SafetyGuard runs before any of this is committed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Target,
        # Empty is legitimate and meaningful: it is how the sharded writer says
        # "no per-object .json files belong here any more" when a collection has just
        # crossed the shard threshold.
        [Parameter(Mandatory)] [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]] $Expected,
        [Parameter(Mandatory)] [string] $Pattern,
        [string[]] $Exclude = @('_index.json')
    )

    if (-not (Test-Path -LiteralPath $Target)) { return 0 }

    $removed = 0
    foreach ($file in Get-ChildItem -LiteralPath $Target -Filter $Pattern -File) {
        if ($Exclude -contains $file.Name) { continue }
        if (-not $Expected.Contains($file.Name)) {
            Remove-Item -LiteralPath $file.FullName -Force
            $removed++
        }
    }
    return $removed
}

function Get-SafeFileName {
    <#
    .SYNOPSIS
        Strips characters Windows forbids in filenames.
    .DESCRIPTION
        Ids are normally GUIDs, but a few collections key on values like a domain name
        or tenant id, so this guards against the occasional awkward character.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Name)

    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Name.ToCharArray()) {
        if ($invalid -contains $ch) { [void]$sb.Append('_') } else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

Export-ModuleMember -Function Invoke-EndpointCollection, Get-ShardName, Get-SafeFileName,
                              Write-PerObjectCollection, Write-ShardedCollection,
                              Write-CollectionIndex, Remove-StaleFiles, Add-ChildCollections
