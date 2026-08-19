<#
.SYNOPSIS
    Deterministic JSON normalisation and serialisation for Entra backup snapshots.

.DESCRIPTION
    The entire value of this repo depends on one property: running a backup twice
    against an unchanged tenant must produce byte-identical files. Anything less and
    every run yields a meaningless thousand-line diff.

    Three things break that property, and this module handles all three:

      1. Graph does not guarantee JSON key order between responses.
      2. Several Graph fields churn on their own (sync timestamps, ETags, @odata noise).
      3. PowerShell's built-in ConvertTo-Json is not stable across versions -- 5.1
         defaults to depth 2 and escapes all non-ASCII to \uXXXX, 7.x does neither.

    Rather than depend on PowerShell 7 for (3), this module carries its own JSON
    writer. That keeps output byte-identical on Windows PowerShell 5.1 and pwsh 7
    alike, which means the same snapshot is produced locally and in CI.
#>

Set-StrictMode -Version Latest

# Fields stripped from every object at every depth.
#
# The @odata.* entries are response plumbing, not tenant state. The timestamps below
# move on their own without anyone changing anything -- onPremisesLastSyncDateTime is
# the worst offender, churning roughly every 30 minutes on a Connect-synced tenant and
# by itself dirtying every single user file on every run.
#
# Deliberately NOT stripped: createdDateTime and lastPasswordChangeDateTime are stable
# and genuinely meaningful in an audit trail.
$script:VolatileFields = @(
    '@odata.context'
    '@odata.etag'
    '@odata.id'
    '@odata.nextLink'
    '@odata.deltaLink'
    '@odata.count'
    '@microsoft.graph.tips'
    'onPremisesLastSyncDateTime'
    'refreshTokensValidFromDateTime'
    'signInSessionsValidFromDateTime'
)

# Arrays Graph returns in arbitrary order. Only these are sorted -- order is meaningful
# in plenty of other places (Conditional Access condition sets, for one), so sorting
# every array would corrupt the data it is meant to preserve.
#
# Value is the property to sort objects by; $null means the array holds scalars.
$script:SortableArrays = @{
    'businessPhones'          = $null
    'proxyAddresses'          = $null
    'otherMails'              = $null
    'imAddresses'             = $null
    'alternativeNames'        = $null
    'groupTypes'              = $null
    'servicePrincipalNames'   = $null
    'tags'                    = $null
    'assignedLicenses'        = 'skuId'
    'assignedPlans'           = 'servicePlanId'
    'provisionedPlans'        = 'service'
    'servicePlans'            = 'servicePlanId'
    'verifiedDomains'         = 'name'
    'keyCredentials'          = 'keyId'
    'passwordCredentials'     = 'keyId'
    'appRoles'                = 'id'
    'appRoleAssignedTo'       = 'id'
    'appRoleAssignments'      = 'id'
    'oauth2PermissionScopes'  = 'id'
    'identities'              = 'issuerAssignedId'
    'members'                 = 'id'
    'owners'                  = 'id'
}

function ConvertTo-NormalizedObject {
    <#
    .SYNOPSIS
        Recursively strips volatile fields, sorts keys, and orders unordered arrays.
    .OUTPUTS
        Ordered dictionaries / arrays / scalars ready for ConvertTo-DeterministicJson.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        $InputObject,

        # Extra field names to strip beyond the built-in volatile set.
        [string[]] $AdditionalStrip = @()
    )

    if ($null -eq $InputObject) { return $null }

    # Scalars pass through untouched.
    if ($InputObject -is [string] -or
        $InputObject -is [bool] -or
        $InputObject -is [datetime] -or
        $InputObject -is [ValueType]) {
        return $InputObject
    }

    # Arrays: normalise every element, then sort if this is a known-unordered field.
    # The sort itself is applied by the caller, which knows the property name.
    if ($InputObject -is [System.Collections.IEnumerable] -and
        $InputObject -isnot [System.Collections.IDictionary]) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += , (ConvertTo-NormalizedObject -InputObject $item -AdditionalStrip $AdditionalStrip)
        }
        return , $items
    }

    # Objects: collect key/value pairs from either a dictionary or a PSCustomObject.
    $pairs = @{}
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) { $pairs[[string]$key] = $InputObject[$key] }
    }
    elseif ($InputObject -is [System.Management.Automation.PSObject] -or
            $InputObject.PSObject.Properties.Count -gt 0) {
        foreach ($prop in $InputObject.PSObject.Properties) { $pairs[$prop.Name] = $prop.Value }
    }
    else {
        return $InputObject
    }

    $strip = @($script:VolatileFields) + @($AdditionalStrip)
    $result = [ordered]@{}

    # Sorting the keys here is what makes Graph's arbitrary property order irrelevant.
    foreach ($key in ($pairs.Keys | Sort-Object -CaseSensitive)) {
        if ($strip -contains $key) { continue }

        $value = ConvertTo-NormalizedObject -InputObject $pairs[$key] -AdditionalStrip $AdditionalStrip

        # A null deletedDateTime is present on every live object and carries no
        # information; dropping it keeps files smaller without losing anything.
        if ($key -eq 'deletedDateTime' -and $null -eq $value) { continue }

        if ($null -ne $value -and
            $value -is [System.Collections.IEnumerable] -and
            $value -isnot [string] -and
            $value -isnot [System.Collections.IDictionary] -and
            $script:SortableArrays.ContainsKey($key)) {
            $value = Sort-NormalizedArray -Array $value -SortKey $script:SortableArrays[$key]
        }

        $result[$key] = $value
    }

    return $result
}

function Sort-NormalizedArray {
    <#
    .SYNOPSIS
        Deterministically orders an array of scalars or objects.
    .DESCRIPTION
        Falls back to sorting by the element's serialised form when the requested sort
        key is missing, so an unexpected shape still produces a stable order rather
        than silently reintroducing diff noise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] $Array,
        [AllowNull()] [string] $SortKey
    )

    $items = @($Array)
    if ($items.Count -le 1) { return , $items }

    if ([string]::IsNullOrEmpty($SortKey)) {
        return , @($items | Sort-Object -CaseSensitive { [string]$_ })
    }

    return , @($items | Sort-Object -CaseSensitive {
        if ($null -ne $_ -and
            $_ -is [System.Collections.IDictionary] -and
            $_.Contains($SortKey)) {
            [string]$_[$SortKey]
        }
        else {
            ConvertTo-DeterministicJson -InputObject $_ -Compact
        }
    })
}

function ConvertTo-DeterministicJson {
    <#
    .SYNOPSIS
        Serialises to JSON with byte-identical output across PowerShell versions.
    .DESCRIPTION
        Written by hand rather than delegating to ConvertTo-Json because the built-in
        differs between 5.1 and 7.x in depth handling, non-ASCII escaping, and number
        formatting -- all of which would make snapshots depend on which host ran them.

        Non-ASCII characters are emitted literally (the file is UTF-8), so an umlaut in
        a display name reads as an umlaut in the diff instead of ü.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] $InputObject,
        [int] $Depth = 0,
        [switch] $Compact
    )

    $indentUnit = if ($Compact) { '' } else { '  ' }
    $newline    = if ($Compact) { '' } else { "`n" }
    $space      = if ($Compact) { '' } else { ' ' }
    $pad        = $indentUnit * $Depth
    $padInner   = $indentUnit * ($Depth + 1)

    if ($null -eq $InputObject) { return 'null' }

    if ($InputObject -is [bool]) { return $(if ($InputObject) { 'true' } else { 'false' }) }

    if ($InputObject -is [string]) { return ConvertTo-JsonString -Value $InputObject }

    # Graph sends timestamps as strings, but ConvertFrom-Json in some PowerShell
    # versions silently rehydrates them into [datetime]. Normalising to UTC round-trip
    # format means the snapshot does not depend on the host's culture or time zone.
    if ($InputObject -is [datetime]) {
        return ConvertTo-JsonString -Value $InputObject.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [cultureinfo]::InvariantCulture)
    }

    if ($InputObject -is [int] -or $InputObject -is [long] -or $InputObject -is [int16] -or $InputObject -is [byte]) {
        return [string]$InputObject
    }

    if ($InputObject -is [double] -or $InputObject -is [single]) {
        return $InputObject.ToString('R', [cultureinfo]::InvariantCulture)
    }

    if ($InputObject -is [decimal]) {
        return $InputObject.ToString([cultureinfo]::InvariantCulture)
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Count -eq 0) { return '{}' }
        $parts = @()
        foreach ($key in $InputObject.Keys) {
            $k = ConvertTo-JsonString -Value ([string]$key)
            $v = ConvertTo-DeterministicJson -InputObject $InputObject[$key] -Depth ($Depth + 1) -Compact:$Compact
            $parts += "$padInner$k`:$space$v"
        }
        return "{$newline" + ($parts -join ",$newline") + "$newline$pad}"
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = @($InputObject)
        if ($items.Count -eq 0) { return '[]' }
        $parts = @()
        foreach ($item in $items) {
            $v = ConvertTo-DeterministicJson -InputObject $item -Depth ($Depth + 1) -Compact:$Compact
            $parts += "$padInner$v"
        }
        return "[$newline" + ($parts -join ",$newline") + "$newline$pad]"
    }

    # Anything else (a bare PSCustomObject that skipped normalisation) is coerced to a
    # string rather than silently emitting invalid JSON.
    return ConvertTo-JsonString -Value ([string]$InputObject)
}

function ConvertTo-JsonString {
    <#
    .SYNOPSIS
        Escapes a string per RFC 8259, leaving non-ASCII characters literal.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()] [AllowNull()] [string] $Value)

    if ($null -eq $Value) { return 'null' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')

    foreach ($ch in $Value.ToCharArray()) {
        switch ($ch) {
            '"'  { [void]$sb.Append('\"');  continue }
            '\'  { [void]$sb.Append('\\');  continue }
            "`b" { [void]$sb.Append('\b');  continue }
            "`f" { [void]$sb.Append('\f');  continue }
            "`n" { [void]$sb.Append('\n');  continue }
            "`r" { [void]$sb.Append('\r');  continue }
            "`t" { [void]$sb.Append('\t');  continue }
            default {
                if ([int]$ch -lt 0x20) {
                    [void]$sb.AppendFormat([cultureinfo]::InvariantCulture, '\u{0:x4}', [int]$ch)
                }
                else {
                    [void]$sb.Append($ch)
                }
            }
        }
    }

    [void]$sb.Append('"')
    return $sb.ToString()
}

function Write-NormalizedJsonFile {
    <#
    .SYNOPSIS
        Normalises an object and writes it as UTF-8 (no BOM) with LF endings.
    .DESCRIPTION
        Skips the write entirely when content is unchanged, so file mtimes stay put and
        git has nothing to notice.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowNull()] $InputObject,
        [string[]] $AdditionalStrip = @()
    )

    $normalized = ConvertTo-NormalizedObject -InputObject $InputObject -AdditionalStrip $AdditionalStrip
    $json = (ConvertTo-DeterministicJson -InputObject $normalized) + "`n"

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Path) {
        $existing = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
        if ($existing -eq $json) { return $false }
    }

    # UTF8Encoding($false) rather than Out-File -Encoding utf8, which emits a BOM on
    # Windows PowerShell 5.1 and would make CI and local output differ byte-for-byte.
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
    return $true
}

Export-ModuleMember -Function ConvertTo-NormalizedObject, ConvertTo-DeterministicJson,
                              ConvertTo-JsonString, Sort-NormalizedArray, Write-NormalizedJsonFile
