<#
.SYNOPSIS
    Access token acquisition for Microsoft Graph.

.DESCRIPTION
    Three modes, in order of preference:

      OIDC         GitHub Actions workload identity federation. No secret exists
                   anywhere -- GitHub mints a short-lived JWT proving which repo and
                   branch is running, and Entra exchanges it for a Graph token. This is
                   the production path.
      DeviceCode   Interactive sign-in for local development, so the collector can be
                   exercised against a real tenant before any app registration exists.
      ClientSecret Fallback for tenants where federated credentials are blocked.
                   Discouraged: the secret expires and must be rotated.

    Connect-MgGraph is not used for the OIDC path. Its parameter set has -AccessToken
    but no -ClientAssertion, so the federated exchange has to be done directly against
    the token endpoint regardless; doing the whole thing here keeps one code path.
#>

Set-StrictMode -Version Latest

if ([Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# First-party public client for Microsoft Graph PowerShell. Used only for the
# interactive device-code path, which needs a pre-consented public client.
$script:DeviceCodeClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
$script:GraphScope         = 'https://graph.microsoft.com/.default'

function Get-GitHubOidcToken {
    <#
    .SYNOPSIS
        Requests an OIDC token from the GitHub Actions token service.
    .DESCRIPTION
        Requires 'permissions: id-token: write' on the job. Without it GitHub does not
        populate the request environment variables at all, which is the most common
        cause of this failing.
    #>
    [CmdletBinding()]
    param([string] $Audience = 'api://AzureADTokenExchange')

    $requestUrl   = $env:ACTIONS_ID_TOKEN_REQUEST_URL
    $requestToken = $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN

    if (-not $requestUrl -or -not $requestToken) {
        throw "GitHub OIDC environment not present. The workflow job needs 'permissions: id-token: write'."
    }

    $uri = "$requestUrl&audience=$([uri]::EscapeDataString($Audience))"
    $response = Invoke-RestMethod -Uri $uri -Method GET -Headers @{
        Authorization = "Bearer $requestToken"
        Accept        = 'application/json'
    } -UseBasicParsing -ErrorAction Stop

    if (-not $response.value) { throw 'GitHub OIDC token service returned no token.' }
    return $response.value
}

function ConvertFrom-JwtPayload {
    <#
    .SYNOPSIS
        Decodes a JWT payload without validating the signature.
    .DESCRIPTION
        Diagnostics only -- used to show which subject a workflow actually presents, so
        the federated credential can be built to match it exactly rather than guessed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Token)

    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) { throw 'Not a well-formed JWT.' }

    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
    }

    $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
    return $json | ConvertFrom-Json
}

function Get-EntraTokenFromOidc {
    <#
    .SYNOPSIS
        Exchanges a GitHub OIDC token for a Graph access token via federated credentials.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $ClientId
    )

    $assertion = Get-GitHubOidcToken

    $body = @{
        client_id             = $ClientId
        scope                 = $script:GraphScope
        grant_type            = 'client_credentials'
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = $assertion
    }

    try {
        $response = Invoke-RestMethod `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -Method POST -Body $body -UseBasicParsing -ErrorAction Stop
    }
    catch {
        # AADSTS70021 here almost always means the federated credential subject does not
        # match the token's sub claim. New GitHub repos emit the immutable subject
        # format, so a credential built from the old name-based format silently fails.
        $detail = ''
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $detail = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
        } catch { }
        throw "OIDC token exchange failed. $($_.Exception.Message)`n$detail`n" +
              "Run the 'OIDC Probe' workflow and confirm the federated credential subject matches the token's sub claim exactly."
    }

    return [pscustomobject]@{
        AccessToken = $response.access_token
        ExpiresOn   = [datetime]::UtcNow.AddSeconds([int]$response.expires_in)
        Method      = 'OIDC'
    }
}

function Get-EntraTokenFromClientSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [string] $ClientSecret
    )

    $body = @{
        client_id     = $ClientId
        scope         = $script:GraphScope
        grant_type    = 'client_credentials'
        client_secret = $ClientSecret
    }

    $response = Invoke-RestMethod `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Method POST -Body $body -UseBasicParsing -ErrorAction Stop

    return [pscustomobject]@{
        AccessToken = $response.access_token
        ExpiresOn   = [datetime]::UtcNow.AddSeconds([int]$response.expires_in)
        Method      = 'ClientSecret'
    }
}

function Get-EntraTokenFromDeviceCode {
    <#
    .SYNOPSIS
        Interactive device-code sign-in for local development runs.
    .DESCRIPTION
        Delegated permissions, so the resulting token can only read what the signed-in
        admin can read. Good enough to exercise the collector end to end before the CI
        app registration exists.
    #>
    [CmdletBinding()]
    param(
        [string] $TenantId = 'organizations',
        [string[]] $Scopes = @(
            'Directory.Read.All', 'User.Read.All', 'Group.Read.All', 'Organization.Read.All',
            'Policy.Read.All', 'Application.Read.All', 'RoleManagement.Read.All'
        )
    )

    $scopeString = ($Scopes + 'offline_access') -join ' '

    $deviceCode = Invoke-RestMethod `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
        -Method POST -UseBasicParsing -ErrorAction Stop -Body @{
            client_id = $script:DeviceCodeClientId
            scope     = $scopeString
        }

    Write-Host ''
    Write-Host $deviceCode.message -ForegroundColor Cyan
    Write-Host ''

    $deadline = [datetime]::UtcNow.AddSeconds([int]$deviceCode.expires_in)
    $interval = [int]$deviceCode.interval
    if ($interval -lt 1) { $interval = 5 }

    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $response = Invoke-RestMethod `
                -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                -Method POST -UseBasicParsing -ErrorAction Stop -Body @{
                    grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                    client_id   = $script:DeviceCodeClientId
                    device_code = $deviceCode.device_code
                }

            Write-Host 'Signed in.' -ForegroundColor Green
            return [pscustomobject]@{
                AccessToken = $response.access_token
                ExpiresOn   = [datetime]::UtcNow.AddSeconds([int]$response.expires_in)
                Method      = 'DeviceCode'
            }
        }
        catch {
            $errorCode = ''
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $raw    = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
                $errorCode = ($raw | ConvertFrom-Json).error
            } catch { }

            # Expected while the user is still completing sign-in in the browser.
            if ($errorCode -eq 'authorization_pending') { continue }
            if ($errorCode -eq 'slow_down') { $interval += 5; continue }
            throw "Device code sign-in failed: $errorCode"
        }
    }

    throw 'Device code sign-in timed out.'
}

function Get-EntraTokenProvider {
    <#
    .SYNOPSIS
        Builds a scriptblock that returns a fresh Graph token on demand.
    .DESCRIPTION
        Returning a provider rather than a token lets GraphClient re-acquire silently
        partway through a long backup, instead of dying an hour in.

        Device-code tokens cannot be renewed non-interactively, so that mode returns
        the already-acquired token and lets the run fail loudly if it expires.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Auto', 'OIDC', 'DeviceCode', 'ClientSecret')]
        [string] $Mode = 'Auto',
        [string] $TenantId,
        [string] $ClientId,
        [string] $ClientSecret
    )

    if ($Mode -eq 'Auto') {
        if ($env:ACTIONS_ID_TOKEN_REQUEST_URL) { $Mode = 'OIDC' }
        elseif ($ClientSecret)                 { $Mode = 'ClientSecret' }
        else                                   { $Mode = 'DeviceCode' }
        Write-Verbose "Auth mode auto-selected: $Mode"
    }

    switch ($Mode) {
        'OIDC' {
            if (-not $TenantId -or -not $ClientId) { throw 'OIDC mode requires -TenantId and -ClientId.' }
            return { Get-EntraTokenFromOidc -TenantId $TenantId -ClientId $ClientId }.GetNewClosure()
        }
        'ClientSecret' {
            if (-not $TenantId -or -not $ClientId -or -not $ClientSecret) {
                throw 'ClientSecret mode requires -TenantId, -ClientId and -ClientSecret.'
            }
            return { Get-EntraTokenFromClientSecret -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret }.GetNewClosure()
        }
        'DeviceCode' {
            $tenant = if ($TenantId) { $TenantId } else { 'organizations' }
            $cached = $null
            return {
                if ($null -eq $cached) { $cached = Get-EntraTokenFromDeviceCode -TenantId $tenant }
                return $cached
            }.GetNewClosure()
        }
    }
}

Export-ModuleMember -Function Get-GitHubOidcToken, ConvertFrom-JwtPayload, Get-EntraTokenFromOidc,
                              Get-EntraTokenFromClientSecret, Get-EntraTokenFromDeviceCode,
                              Get-EntraTokenProvider
