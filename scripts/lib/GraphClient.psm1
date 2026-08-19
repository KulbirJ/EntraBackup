<#
.SYNOPSIS
    Minimal Microsoft Graph REST client with paging, throttling and retry.

.DESCRIPTION
    Deliberately built on Invoke-RestMethod rather than the Microsoft.Graph PowerShell
    SDK. The SDK is 40+ modules, is slow to install in CI, and changes its output
    shapes between versions -- all three are liabilities for a tool whose entire job is
    producing byte-stable output. A thin client over the REST API has one auth path,
    no install step, and returns exactly what Graph sent.

    Token refresh is handled by a caller-supplied provider scriptblock rather than a
    fixed token string, because a full-tenant backup can easily outlive the one-hour
    lifetime of a Graph access token.
#>

Set-StrictMode -Version Latest

$script:TokenProvider    = $null
$script:AccessToken      = $null
$script:TokenExpiresAt   = [datetime]::MinValue
$script:GraphBaseUri     = 'https://graph.microsoft.com'
$script:MaxRetries       = 6
$script:ThrottleEvents   = 0
$script:RequestCount     = 0

# Windows PowerShell 5.1 still negotiates TLS 1.0 by default, which Graph rejects.
# Harmless on 7.x, where the default is already correct.
if ([Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Marker prefix for "this endpoint is not available to us" errors.
#
# A PowerShell class would be the obvious way to model this, but classes declared in a
# module are not visible to `catch [TypeName]` in a *different* module -- the type fails
# to resolve and the catch silently never matches. A message sentinel plus the helper
# below works across module boundaries and across PowerShell versions.
$script:PermissionErrorSentinel = 'ENTRABACKUP_ACCESS_DENIED'

function Test-GraphPermissionError {
    <#
    .SYNOPSIS
        True when an error record represents a 403/404 from Graph rather than a fault.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowNull()] $ErrorRecord)

    if ($null -eq $ErrorRecord) { return $false }
    return ([string]$ErrorRecord.Exception.Message).StartsWith($script:PermissionErrorSentinel)
}

function Initialize-GraphClient {
    <#
    .SYNOPSIS
        Registers a token provider and resets per-run counters.
    .PARAMETER TokenProvider
        Scriptblock returning a PSCustomObject with AccessToken and ExpiresOn.
        Called on first use and again whenever the token nears expiry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $TokenProvider,
        [int] $MaxRetries = 6
    )

    $script:TokenProvider  = $TokenProvider
    $script:AccessToken    = $null
    $script:TokenExpiresAt = [datetime]::MinValue
    $script:MaxRetries     = $MaxRetries
    $script:ThrottleEvents = 0
    $script:RequestCount   = 0
}

function Get-GraphClientStats {
    [CmdletBinding()] param()
    return [pscustomobject]@{
        RequestCount   = $script:RequestCount
        ThrottleEvents = $script:ThrottleEvents
    }
}

function Get-CurrentAccessToken {
    [CmdletBinding()] param()

    if ($null -eq $script:TokenProvider) {
        throw 'Graph client not initialised. Call Initialize-GraphClient first.'
    }

    # Refresh two minutes early so a long-running page loop never trips over expiry.
    if ($null -eq $script:AccessToken -or
        [datetime]::UtcNow -ge $script:TokenExpiresAt.AddMinutes(-2)) {
        $result = & $script:TokenProvider
        if ($null -eq $result -or -not $result.AccessToken) {
            throw 'Token provider returned no access token.'
        }
        $script:AccessToken  = $result.AccessToken
        $script:TokenExpiresAt = $result.ExpiresOn
        Write-Verbose "Acquired Graph token, expires $($script:TokenExpiresAt.ToString('u'))"
    }

    return $script:AccessToken
}

function Invoke-GraphRequest {
    <#
    .SYNOPSIS
        Issues one Graph request, retrying on throttling and transient failures.
    .PARAMETER Uri
        Absolute URI, or a path such as '/v1.0/users' which is resolved against Graph.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [string] $Method = 'GET',
        [hashtable] $AdditionalHeaders = @{},
        $Body = $null
    )

    if ($Uri -notmatch '^https?://') {
        $Uri = $script:GraphBaseUri + '/' + $Uri.TrimStart('/')
    }

    $attempt = 0
    while ($true) {
        $attempt++
        $headers = @{
            Authorization = "Bearer $(Get-CurrentAccessToken)"
            Accept        = 'application/json'
        }
        foreach ($k in $AdditionalHeaders.Keys) { $headers[$k] = $AdditionalHeaders[$k] }

        try {
            $params = @{
                Uri         = $Uri
                Method      = $Method
                Headers     = $headers
                ErrorAction = 'Stop'
                UseBasicParsing = $true
            }
            if ($null -ne $Body) {
                $params['Body']        = $Body
                $params['ContentType'] = 'application/json'
            }

            $script:RequestCount++
            return Invoke-RestMethod @params
        }
        catch {
            $response   = $null
            $statusCode = 0
            if ($_.Exception.PSObject.Properties.Name -contains 'Response') {
                $response = $_.Exception.Response
            }
            if ($null -ne $response -and $response.PSObject.Properties.Name -contains 'StatusCode') {
                $statusCode = [int]$response.StatusCode
            }

            # 403 and 404 are not transient. They mean a permission was never granted or
            # the feature is not licensed in this tenant. Surface them as a typed error
            # so the collector can skip that category instead of failing the whole run.
            if ($statusCode -eq 403 -or $statusCode -eq 404) {
                throw "$($script:PermissionErrorSentinel): Graph returned $statusCode for $Uri. " +
                      "Check the app's application permissions and tenant licensing."
            }

            $isRetryable = ($statusCode -eq 429 -or $statusCode -ge 500 -or $statusCode -eq 0)
            if (-not $isRetryable -or $attempt -gt $script:MaxRetries) {
                throw "Graph request failed after $attempt attempt(s): $Method $Uri -- $($_.Exception.Message)"
            }

            # Graph tells us exactly how long to wait when it throttles; obeying that is
            # far more effective than guessing, and avoids compounding the throttle.
            $delay = [math]::Pow(2, $attempt)
            if ($statusCode -eq 429) {
                $script:ThrottleEvents++
                if ($null -ne $response -and $response.Headers -and $response.Headers['Retry-After']) {
                    $parsed = 0
                    if ([int]::TryParse([string]$response.Headers['Retry-After'], [ref]$parsed) -and $parsed -gt 0) {
                        $delay = $parsed
                    }
                }
            }

            # Jitter stops parallel categories from retrying in lockstep.
            $delay = [math]::Min($delay, 120) + (Get-Random -Minimum 0.0 -Maximum 1.0)
            Write-Warning "Graph $statusCode on $Uri (attempt $attempt/$($script:MaxRetries)); retrying in $([math]::Round($delay,1))s"
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-GraphCollection {
    <#
    .SYNOPSIS
        Retrieves every page of a Graph collection, following @odata.nextLink.
    .PARAMETER MaxItems
        Safety ceiling; 0 means unlimited.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [hashtable] $AdditionalHeaders = @{},
        [int] $MaxItems = 0
    )

    $all      = New-Object System.Collections.ArrayList
    $next     = $Uri
    $pageNum  = 0

    while ($next) {
        $pageNum++
        $page = Invoke-GraphRequest -Uri $next -AdditionalHeaders $AdditionalHeaders

        if ($null -eq $page) { break }

        $hasValue = $page.PSObject.Properties.Name -contains 'value'
        if ($hasValue) {
            foreach ($item in @($page.value)) { [void]$all.Add($item) }
        }
        else {
            # A singleton resource (organization settings, authorizationPolicy, ...)
            # rather than a collection.
            [void]$all.Add($page)
            break
        }

        if ($MaxItems -gt 0 -and $all.Count -ge $MaxItems) {
            Write-Warning "Reached MaxItems ceiling of $MaxItems for $Uri; results truncated."
            break
        }

        $next = $null
        if ($page.PSObject.Properties.Name -contains '@odata.nextLink') {
            $next = $page.'@odata.nextLink'
        }

        if ($next -and ($pageNum % 10 -eq 0)) {
            Write-Verbose "  ...$($all.Count) items after $pageNum pages"
        }
    }

    return , $all.ToArray()
}

function Get-GraphCount {
    <#
    .SYNOPSIS
        Returns the object count for a collection, or -1 when counting is unsupported.
    .DESCRIPTION
        Used to size the tenant before choosing a file layout. Graph requires the
        eventual-consistency header for $count on directory objects.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Uri)

    try {
        $result = Invoke-GraphRequest -Uri $Uri -AdditionalHeaders @{ ConsistencyLevel = 'eventual' }
        $parsed = 0
        if ([int]::TryParse([string]$result, [ref]$parsed)) { return $parsed }
        return -1
    }
    catch {
        Write-Verbose "Count unavailable for $Uri : $($_.Exception.Message)"
        return -1
    }
}

Export-ModuleMember -Function Initialize-GraphClient, Invoke-GraphRequest, Get-GraphCollection,
                              Test-GraphPermissionError,
                              Get-GraphCount, Get-GraphClientStats, Get-CurrentAccessToken
