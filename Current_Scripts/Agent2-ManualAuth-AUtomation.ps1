[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$TenantId     = "cc7374ac-e69f-4e98-942a-1023569972ad"
$ClientId     = "0b36118d-8138-44c8-9619-cb78fc72ea8d"

$DataverseUrl = "https://org65efd8ed.crm.dynamics.com"
$BotName      = "Agent 2 UI Testing"

# Optional. Leave empty if you do not want this header sent.
$SolutionUniqueName = "CUA Execution Validator"

$ServiceProviderId = "5232e24f-b6c6-4920-b09d-d93a520c92e9"
$AuthRedirectUrl   = "https://token.botframework.com/.auth/web/redirect"
$ResourceUri       = "https://graph.microsoft.com"
$GrantType         = "Authorization Code"
$BapApiBaseUrl     = "https://api.bap.microsoft.com"

function Read-ErrorResponseBody {
    param($Exception)

    $message = $Exception.Message

    if ($Exception.Response) {
        try {
            $statusCode = [int]$Exception.Response.StatusCode
            $message = "HTTP $statusCode - $message"
        }
        catch {}

        try {
            $stream = $Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()

            if ($body) {
                $message = "$message`nResponse:`n$body"
            }
        }
        catch {}
    }

    return $message
}

function Decode-JwtPayload {
    param([Parameter(Mandatory=$true)][string]$Token)

    $parts = $Token.Split(".")
    if ($parts.Count -lt 2) {
        throw "Access token does not look like a JWT."
    }

    $payload = $parts[1].Replace("-", "+").Replace("_", "/")
    while (($payload.Length % 4) -ne 0) {
        $payload += "="
    }

    try {
        $json = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($payload)
        )
        return $json | ConvertFrom-Json
    }
    catch {
        throw "Unable to decode access token."
    }
}

function Ensure-AzLogin {
    Write-Host ""
    Write-Host "==> Checking Azure CLI login..."

    if ($null -eq (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI was not found. Install Azure CLI and rerun the script."
    }

    $currentTenant = ""

    try {
        $currentTenant = (& az account show `
            --query tenantId `
            --output tsv `
            --only-show-errors 2>$null).Trim()
    }
    catch {
        $currentTenant = ""
    }

    if ($LASTEXITCODE -ne 0) {
        $currentTenant = ""
    }

    if ([string]::IsNullOrWhiteSpace($currentTenant) -or
        $currentTenant -ne $TenantId) {

        Write-Host "Opening az login for tenant $TenantId ..."

        & az login `
            --tenant $TenantId `
            --allow-no-subscriptions `
            --only-show-errors | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "az login failed."
        }

        $currentTenant = (& az account show `
            --query tenantId `
            --output tsv `
            --only-show-errors).Trim()
    }

    if ($currentTenant -ne $TenantId) {
        throw "Azure CLI is logged into tenant '$currentTenant', expected '$TenantId'."
    }

    Write-Host "Azure CLI login ready."
}

function Get-AzAccessToken {
    param(
        [Parameter(Mandatory=$true)][string]$Resource,
        [Parameter(Mandatory=$true)][string]$Description,
        [switch]$Quiet
    )

    if (-not $Quiet) {
        Write-Host "==> Getting token for $Description..."
    }

    $raw = ""

    try {
        $raw = (& az account get-access-token `
            --tenant $TenantId `
            --resource $Resource `
            --query accessToken `
            --output tsv `
            --only-show-errors 2>&1 | Out-String).Trim()
    }
    catch {
        $raw = ""
    }

    if ($LASTEXITCODE -ne 0 -or
        [string]::IsNullOrWhiteSpace($raw) -or
        $raw -notmatch '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.') {

        if ($Quiet) {
            return $null
        }

        throw "Could not obtain token for '$Description' resource '$Resource'. Output: $raw"
    }

    if (-not $Quiet) {
        Write-Host "$Description token acquired."
    }

    return $raw
}

function Normalize-Url {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ""
    }

    return $Url.Trim().TrimEnd("/").ToLowerInvariant()
}

function Escape-ODataString {
    param([string]$Value)
    return $Value.Replace("'", "''")
}

function Invoke-JsonGet {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][hashtable]$Headers,
        [switch]$ReturnNullOnError
    )

    try {
        return Invoke-RestMethod `
            -Method GET `
            -Uri $Uri `
            -Headers $Headers `
            -ErrorAction Stop
    }
    catch {
        if ($ReturnNullOnError) {
            return $null
        }

        $message = Read-ErrorResponseBody -Exception $_.Exception
        throw "GET failed:`n$Uri`n$message"
    }
}

function Invoke-CopilotRequest {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("GET","POST","PUT")]
        [string]$Method,

        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][hashtable]$Headers,
        $Body,
        [switch]$ReturnNullOnError
    )

    $call = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $Headers
        ErrorAction = "Stop"
    }

    if ($null -ne $Body) {
        $call.ContentType = "application/json"
        $call.Body = ($Body | ConvertTo-Json -Depth 50 -Compress)
    }

    try {
        return Invoke-RestMethod @call
    }
    catch {
        if ($ReturnNullOnError) {
            return $null
        }

        $message = Read-ErrorResponseBody -Exception $_.Exception
        throw "$Method $Uri failed:`n$message"
    }
}

function Invoke-DataverseGet {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Token
    )

    $uri = "$($DataverseUrl.TrimEnd('/'))/api/data/v9.2/$Path"

    $headers = @{
        Authorization      = "Bearer $Token"
        Accept             = "application/json"
        "OData-Version"    = "4.0"
        "OData-MaxVersion" = "4.0"
    }

    return Invoke-JsonGet -Uri $uri -Headers $headers
}

function Get-ParameterValue {
    param(
        [Parameter(Mandatory=$true)]$Parameters,
        [Parameter(Mandatory=$true)][string]$Key
    )

    $items = @($Parameters | Where-Object { $_.key -eq $Key })

    if ($items.Count -gt 0) {
        return $items[0].value
    }

    return $null
}

function Get-GuidsFromObject {
    param($Object)

    if ($null -eq $Object) {
        return @()
    }

    $json = $Object | ConvertTo-Json -Depth 80 -Compress
    $pattern = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
    $result = New-Object System.Collections.Generic.List[string]

    foreach ($match in [regex]::Matches($json, $pattern)) {
        $value = $match.Value.ToLowerInvariant()

        if (-not $result.Contains($value)) {
            $result.Add($value)
        }
    }

    return @($result)
}

function Get-AzAccessTokenDetailed {
    param(
        [Parameter(Mandatory=$true)][string]$Mode,
        [Parameter(Mandatory=$true)][string]$Value
    )

    $args = @(
        "account", "get-access-token",
        "--tenant", $TenantId,
        "--query", "accessToken",
        "--output", "tsv",
        "--only-show-errors"
    )

    if ($Mode -eq "resource") {
        $args += @("--resource", $Value)
    }
    elseif ($Mode -eq "scope") {
        $args += @("--scope", $Value)
    }
    else {
        throw "Unsupported token mode '$Mode'."
    }

    $raw = ""

    try {
        $raw = (& az @args 2>&1 | Out-String).Trim()
    }
    catch {
        $raw = ""
    }

    if ($LASTEXITCODE -eq 0 -and
        -not [string]::IsNullOrWhiteSpace($raw) -and
        $raw -match '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.') {

        return @{
            Success = $true
            Token   = $raw
            Error   = $null
        }
    }

    return @{
        Success = $false
        Token   = $null
        Error   = $raw
    }
}

function Resolve-CopilotResource {
    Write-Host ""
    Write-Host "==> Discovering Copilot Studio resource in tenant..."

    # Use TSV rather than JSON for app IDs because Windows PowerShell
    # 5.1 can flatten JSON array properties into one space-separated value.
    $searchNames = @(
        "Power Virtual Agents",
        "Power Virtual Agents Service",
        "ccibotsprod",
        "ccibots"
    )

    $candidateAppIds = New-Object System.Collections.Generic.List[string]

    foreach ($name in $searchNames) {
        $rawIds = ""

        try {
            $rawIds = (& az ad sp list `
                --display-name $name `
                --query "[].appId" `
                --output tsv `
                --only-show-errors 2>$null | Out-String)
        }
        catch {
            $rawIds = ""
        }

        foreach ($line in ($rawIds -split "`r?`n")) {
            $appId = $line.Trim()

            if ($appId -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -and
                -not $candidateAppIds.Contains($appId)) {

                $candidateAppIds.Add($appId)
            }
        }
    }

    if ($candidateAppIds.Count -eq 0) {
        throw "Could not discover Copilot Studio / Power Virtual Agents service principal in this tenant."
    }

    $lastErrors = New-Object System.Collections.Generic.List[string]

    foreach ($appId in $candidateAppIds) {
        $spJson = ""

        try {
            $spJson = (& az ad sp show `
                --id $appId `
                --query "{appId:appId,displayName:displayName,servicePrincipalNames:servicePrincipalNames}" `
                --output json `
                --only-show-errors 2>$null | Out-String).Trim()
        }
        catch {
            $spJson = ""
        }

        if ([string]::IsNullOrWhiteSpace($spJson)) {
            continue
        }

        try {
            $sp = $spJson | ConvertFrom-Json
        }
        catch {
            continue
        }

        Write-Host "  Candidate: $($sp.displayName) [$appId]"

        $targets = New-Object System.Collections.Generic.List[string]
        $targets.Add($appId)

        foreach ($spn in @($sp.servicePrincipalNames)) {
            $value = [string]$spn

            if (-not [string]::IsNullOrWhiteSpace($value) -and
                -not $targets.Contains($value)) {

                $targets.Add($value)
            }
        }

        foreach ($target in $targets) {

            $resourceResult = Get-AzAccessTokenDetailed `
                -Mode "resource" `
                -Value $target

            if ($resourceResult.Success) {
                try {
                    $claims = Decode-JwtPayload -Token $resourceResult.Token

                    if ([string]$claims.tid -eq $TenantId -and
                        -not [string]::IsNullOrWhiteSpace([string]$claims.oid) -and
                        [string]$claims.idtyp -ne "app") {

                        Write-Host "Copilot delegated token acquired."
                        Write-Host "  Service principal: $($sp.displayName)"
                        Write-Host "  App ID:            $appId"
                        Write-Host "  Token audience:    $($claims.aud)"
                        Write-Host "  Token method:      --resource $target"

                        return @{
                            Resource = $appId
                            Token    = $resourceResult.Token
                            Claims   = $claims
                        }
                    }
                }
                catch {}
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$resourceResult.Error)) {
                $lastErrors.Add("--resource $target -> $($resourceResult.Error)")
            }

            $scopeBase = $target.TrimEnd("/")
            $scope = "$scopeBase/.default"

            $scopeResult = Get-AzAccessTokenDetailed `
                -Mode "scope" `
                -Value $scope

            if ($scopeResult.Success) {
                try {
                    $claims = Decode-JwtPayload -Token $scopeResult.Token

                    if ([string]$claims.tid -eq $TenantId -and
                        -not [string]::IsNullOrWhiteSpace([string]$claims.oid) -and
                        [string]$claims.idtyp -ne "app") {

                        Write-Host "Copilot delegated token acquired."
                        Write-Host "  Service principal: $($sp.displayName)"
                        Write-Host "  App ID:            $appId"
                        Write-Host "  Token audience:    $($claims.aud)"
                        Write-Host "  Token method:      --scope $scope"

                        return @{
                            Resource = $appId
                            Token    = $scopeResult.Token
                            Claims   = $claims
                        }
                    }
                }
                catch {}
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$scopeResult.Error)) {
                $lastErrors.Add("--scope $scope -> $($scopeResult.Error)")
            }
        }
    }

    Write-Host ""
    Write-Host "Azure CLI could not obtain a delegated Copilot token."
    Write-Host "Recent Azure CLI / Entra errors:"
    Write-Host ""

    foreach ($err in @($lastErrors | Select-Object -Last 8)) {
        Write-Host "  $err"
    }

    throw @"
Copilot service principals were discovered correctly, but Azure CLI
could not obtain a usable delegated token.

The actual Azure CLI / Entra error is now printed above so we can
identify whether the remaining issue is resource identifier, scope,
consent, or Azure CLI client authorization.
"@
}

function Resolve-Environment {
    param([Parameter(Mandatory=$true)][string]$PowerPlatformToken)

    Write-Host ""
    Write-Host "==> Resolving Power Platform environment..."

    $headers = @{
        Authorization = "Bearer $PowerPlatformToken"
        Accept        = "application/json"
    }

    $response = Invoke-JsonGet `
        -Uri "https://api.powerplatform.com/environmentmanagement/environments?api-version=2024-10-01" `
        -Headers $headers

    $targetUrl = Normalize-Url $DataverseUrl

    $matches = @(
        $response.value | Where-Object {
            (Normalize-Url $_.url) -eq $targetUrl
        }
    )

    if ($matches.Count -eq 0) {
        $domainPrefix = ([uri]$DataverseUrl).Host.Split(".")[0].ToLowerInvariant()

        $matches = @(
            $response.value | Where-Object {
                ([string]$_.domainName).ToLowerInvariant() -eq $domainPrefix
            }
        )
    }

    if ($matches.Count -ne 1) {
        throw "Expected one matching environment; found $($matches.Count)."
    }

    return $matches[0]
}

function Resolve-GatewayBaseUrl {
    param(
        [Parameter(Mandatory=$true)][string]$EnvironmentId,
        [Parameter(Mandatory=$true)][string]$BapToken
    )

    Write-Host ""
    Write-Host "==> Discovering Copilot Studio gateway..."

    $headers = @{
        Authorization = "Bearer $BapToken"
        Accept        = "application/json"
    }

    # The BAP admin environment response contains properties.runtimeEndpoints,
    # including microsoft.PowerVirtualAgents. That value is the actual
    # environment-specific Copilot/PVA gateway.
    #
    # Use the global BAP host. It handles routing to the correct Power Platform
    # region, so the user does not need to know a regional BAP endpoint.

    $listUri = "$BapApiBaseUrl/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2020-10-01&`$expand=properties"

    Write-Host "  Querying BAP environment metadata..."

    $listResult = Invoke-JsonGet `
        -Uri $listUri `
        -Headers $headers `
        -ReturnNullOnError

    if ($listResult -and $listResult.value) {

        $environmentMatch = @(
            $listResult.value | Where-Object {
                ([string]$_.name -eq $EnvironmentId) -or
                ([string]$_.id -match [regex]::Escape($EnvironmentId) + '$')
            }
        )

        if ($environmentMatch.Count -eq 1) {
            $env = $environmentMatch[0]

            $runtimeEndpoints = $env.properties.runtimeEndpoints

            if ($runtimeEndpoints) {
                $pvaEndpoint = $runtimeEndpoints.PSObject.Properties |
                    Where-Object {
                        $_.Name -ieq "microsoft.PowerVirtualAgents"
                    } |
                    Select-Object -First 1

                if ($pvaEndpoint -and
                    -not [string]::IsNullOrWhiteSpace([string]$pvaEndpoint.Value)) {

                    $gateway = ([string]$pvaEndpoint.Value).TrimEnd("/")

                    Write-Host "Gateway resolved dynamically:"
                    Write-Host "  $gateway"

                    return $gateway
                }
            }

            # Some BAP responses also expose the cluster information.
            # Keep this as a fallback if runtimeEndpoints is unexpectedly absent.
            $suffix = [string]$env.properties.cluster.uriSuffix

            if (-not [string]::IsNullOrWhiteSpace($suffix)) {
                $gateway = "https://powervamg.$suffix.powerapps.com"

                Write-Host "Gateway built from BAP cluster metadata:"
                Write-Host "  $gateway"

                return $gateway
            }
        }
        elseif ($environmentMatch.Count -gt 1) {
            throw "BAP returned multiple records for environment '$EnvironmentId'."
        }
    }

    # Fallback: query the target environment directly through the admin route.
    # This route is useful where the list response is filtered or abbreviated.
    Write-Host "  BAP list did not expose the gateway. Trying direct environment metadata..."

    $detailUris = @(
        "$BapApiBaseUrl/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$EnvironmentId?api-version=2016-11-01",
        "$BapApiBaseUrl/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$EnvironmentId?api-version=2020-10-01"
    )

    foreach ($uri in $detailUris) {

        $result = Invoke-JsonGet `
            -Uri $uri `
            -Headers $headers `
            -ReturnNullOnError

        if ($null -eq $result) {
            continue
        }

        $runtimeEndpoints = $result.properties.runtimeEndpoints

        if ($runtimeEndpoints) {
            $pvaEndpoint = $runtimeEndpoints.PSObject.Properties |
                Where-Object {
                    $_.Name -ieq "microsoft.PowerVirtualAgents"
                } |
                Select-Object -First 1

            if ($pvaEndpoint -and
                -not [string]::IsNullOrWhiteSpace([string]$pvaEndpoint.Value)) {

                $gateway = ([string]$pvaEndpoint.Value).TrimEnd("/")

                Write-Host "Gateway resolved dynamically:"
                Write-Host "  $gateway"

                return $gateway
            }
        }

        $suffix = [string]$result.properties.cluster.uriSuffix

        if (-not [string]::IsNullOrWhiteSpace($suffix)) {
            $gateway = "https://powervamg.$suffix.powerapps.com"

            Write-Host "Gateway built from BAP cluster metadata:"
            Write-Host "  $gateway"

            return $gateway
        }
    }

    throw @"
Could not resolve the Power Virtual Agents gateway from BAP metadata.

The script successfully resolved:
  - Copilot resource
  - Copilot delegated token
  - Power Platform environment

No authentication changes were made.

If this occurs again, the next diagnostic is to print the BAP environment
record so we can inspect the runtimeEndpoints returned for this tenant.
"@
}

function New-CopilotDiscoveryHeaders {
    param(
        [Parameter(Mandatory=$true)][string]$Token,
        [Parameter(Mandatory=$true)]$Claims,
        [Parameter(Mandatory=$true)][string]$EnvironmentId,
        [Parameter(Mandatory=$true)][string]$OrganizationId,
        [Parameter(Mandatory=$true)][string]$CdsBotId
    )

    $headers = @{
        Authorization                = "Bearer $Token"
        Accept                       = "application/json"
        Origin                       = "https://copilotstudio.microsoft.com"
        Referer                      = "https://copilotstudio.microsoft.com/"
        "x-cci-applicationsource"    = "Web"
        "x-cci-bapenvironmentid"     = $EnvironmentId
        "x-cci-cdsbotid"             = $CdsBotId
        "x-cci-organizationid"       = $OrganizationId
        "x-cci-tenantid"             = $TenantId
        "x-ms-client-principal-id"   = [string]$Claims.oid
        "x-ms-client-request-id"     = [guid]::NewGuid().ToString()
        "x-ms-client-session-id"     = [guid]::NewGuid().ToString()
        "x-ms-client-tenant-id"      = [string]$Claims.tid
    }

    if (-not [string]::IsNullOrWhiteSpace($SolutionUniqueName)) {
        $headers["x-ms-solution-unique-name"] = $SolutionUniqueName
    }

    return $headers
}

function New-CopilotBotHeaders {
    param(
        [Parameter(Mandatory=$true)][string]$Token,
        [Parameter(Mandatory=$true)]$Claims,
        [Parameter(Mandatory=$true)][string]$EnvironmentId,
        [Parameter(Mandatory=$true)][string]$OrganizationId,
        [Parameter(Mandatory=$true)][string]$CdsBotId,
        [Parameter(Mandatory=$true)][string]$InternalBotId
    )

    $headers = New-CopilotDiscoveryHeaders `
        -Token $Token `
        -Claims $Claims `
        -EnvironmentId $EnvironmentId `
        -OrganizationId $OrganizationId `
        -CdsBotId $CdsBotId

    $headers["x-cci-botid"] = $InternalBotId
    $headers["x-cci-routing-botid"] = $InternalBotId

    return $headers
}

function Test-InternalBotId {
    param(
        [Parameter(Mandatory=$true)][string]$Candidate,
        [Parameter(Mandatory=$true)][string]$GatewayBaseUrl,
        [Parameter(Mandatory=$true)][string]$CopilotToken,
        [Parameter(Mandatory=$true)]$CopilotClaims,
        [Parameter(Mandatory=$true)][string]$EnvironmentId,
        [Parameter(Mandatory=$true)][string]$OrganizationId,
        [Parameter(Mandatory=$true)][string]$CdsBotId
    )

    $headers = New-CopilotBotHeaders `
        -Token $CopilotToken `
        -Claims $CopilotClaims `
        -EnvironmentId $EnvironmentId `
        -OrganizationId $OrganizationId `
        -CdsBotId $CdsBotId `
        -InternalBotId $Candidate

    $configurationUri = "$GatewayBaseUrl/api/botmanagement/v1/channels/authentication/connections/configuration"

    $result = Invoke-CopilotRequest `
        -Method GET `
        -Uri $configurationUri `
        -Headers $headers `
        -ReturnNullOnError

    if ($result -and
        -not [string]::IsNullOrWhiteSpace([string]$result.etag)) {

        return @{
            InternalBotId = $Candidate
            Headers       = $headers
            Configuration = $result
        }
    }

    return $null
}

function Resolve-InternalBotId {
    param(
        [Parameter(Mandatory=$true)][string]$GatewayBaseUrl,
        [Parameter(Mandatory=$true)][string]$CopilotToken,
        [Parameter(Mandatory=$true)]$CopilotClaims,
        [Parameter(Mandatory=$true)][string]$EnvironmentId,
        [Parameter(Mandatory=$true)][string]$OrganizationId,
        [Parameter(Mandatory=$true)][string]$CdsBotId,
        [Parameter(Mandatory=$true)]$DataverseBot
    )

    Write-Host ""
    Write-Host "==> Discovering Copilot internal/routing bot ID..."

    $configurationUri = "$GatewayBaseUrl/api/botmanagement/v1/channels/authentication/connections/configuration"

    $discoveryHeaders = New-CopilotDiscoveryHeaders `
        -Token $CopilotToken `
        -Claims $CopilotClaims `
        -EnvironmentId $EnvironmentId `
        -OrganizationId $OrganizationId `
        -CdsBotId $CdsBotId

    # First test whether Copilot can resolve the bot without x-cci-botid.
    $withoutInternal = Invoke-CopilotRequest `
        -Method GET `
        -Uri $configurationUri `
        -Headers $discoveryHeaders `
        -ReturnNullOnError

    if ($withoutInternal -and
        -not [string]::IsNullOrWhiteSpace([string]$withoutInternal.etag)) {

        Write-Host "Internal routing header is not required for this environment."

        return @{
            InternalBotId = $null
            Headers       = $discoveryHeaders
            Configuration = $withoutInternal
        }
    }

    $known = @(
        $EnvironmentId.ToLowerInvariant(),
        $OrganizationId.ToLowerInvariant(),
        $CdsBotId.ToLowerInvariant(),
        $TenantId.ToLowerInvariant(),
        $ClientId.ToLowerInvariant(),
        ([string]$CopilotClaims.oid).ToLowerInvariant()
    )

    $candidateIds = New-Object System.Collections.Generic.List[string]

    foreach ($guid in (Get-GuidsFromObject -Object $DataverseBot)) {
        if (-not $known.Contains($guid) -and
            -not $candidateIds.Contains($guid)) {
            $candidateIds.Add($guid)
        }
    }

    # Probe bot metadata routes that can potentially expose the routing ID.
    # This internal API surface is not publicly documented, so each result
    # is validated before being used.
    $metadataUris = @(
        "$GatewayBaseUrl/api/botmanagement/v1/bots?environmentId=$EnvironmentId",
        "$GatewayBaseUrl/api/botmanagement/v1/environments/$EnvironmentId/bots",
        "$GatewayBaseUrl/api/botmanagement/v1/environments/$EnvironmentId/bots/$CdsBotId",
        "$GatewayBaseUrl/api/botauthoring/v1/environments/$EnvironmentId/bots",
        "$GatewayBaseUrl/api/botauthoring/v1/environments/$EnvironmentId/bots/$CdsBotId",
        "$GatewayBaseUrl/api/botmanagement/v1/bots/$CdsBotId"
    )

    foreach ($uri in $metadataUris) {
        Write-Host "  Probing: $uri"

        $response = Invoke-CopilotRequest `
            -Method GET `
            -Uri $uri `
            -Headers $discoveryHeaders `
            -ReturnNullOnError

        if ($null -eq $response) {
            continue
        }

        foreach ($guid in (Get-GuidsFromObject -Object $response)) {
            if (-not $known.Contains($guid) -and
                -not $candidateIds.Contains($guid)) {

                $candidateIds.Add($guid)
            }
        }
    }

    Write-Host "Candidate routing GUIDs found: $($candidateIds.Count)"

    foreach ($candidate in $candidateIds) {
        Write-Host "  Validating candidate: $candidate"

        $validated = Test-InternalBotId `
            -Candidate $candidate `
            -GatewayBaseUrl $GatewayBaseUrl `
            -CopilotToken $CopilotToken `
            -CopilotClaims $CopilotClaims `
            -EnvironmentId $EnvironmentId `
            -OrganizationId $OrganizationId `
            -CdsBotId $CdsBotId

        if ($validated) {
            Write-Host "Internal Bot ID resolved: $candidate"
            return $validated
        }
    }

    throw @"
Automatic InternalBotId discovery did not find a candidate accepted by
Copilot Studio.

GatewayBaseUrl and CopilotResource were discovered dynamically.
No authentication changes were made.

This means the remaining task is identifying the exact bot metadata
endpoint used by the Copilot Studio UI for x-cci-botid.
"@
}

function New-CreateConfigurationPayload {
    param([Parameter(Mandatory=$true)][string]$Etag)

    $loginUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/authorize"

    return @{
        authenticationMode = "CustomAzureActiveDirectory"

        authenticationConnection = @{
            serviceProviderId = $ServiceProviderId
            scopes            = ""
            parameters = @(
                @{ key = "tenantId";     value = $TenantId },
                @{ key = "clientSecret"; value = $ClientSecret },
                @{ key = "clientId";     value = $ClientId },
                @{ key = "grantType";    value = $GrantType },
                @{ key = "loginUrl";     value = $loginUrl },
                @{ key = "resourceUri";  value = $ResourceUri }
            )
            serviceProviderDisplayName = "Microsoft Entra ID"
            clientSecret               = $ClientSecret
            clientId                   = $ClientId
        }

        etag            = $Etag
        authRedirectUrl = $AuthRedirectUrl
    }
}

function New-UpdateConfigurationPayload {
    param([Parameter(Mandatory=$true)]$Current)

    $connection = $Current.authenticationConnection

    if ($null -eq $connection) {
        throw "Update requested but authenticationConnection is null."
    }

    $existingName = [string]$connection.name
    $existingSettingId = [string]$connection.settingId

    if ([string]::IsNullOrWhiteSpace($existingName) -or
        $existingName.Trim().Length -lt 2) {
        throw "Update requested but the existing authentication connection has no valid connection name. Use CREATE instead."
    }

    if ([string]::IsNullOrWhiteSpace($existingSettingId)) {
        throw "Update requested but the existing authentication connection has no Setting ID. Use CREATE instead."
    }

    $loginUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/authorize"

    return @{
        authenticationMode = "CustomAzureActiveDirectory"

        authenticationConnection = @{
            name                       = [string]$connection.name
            clientId                   = $ClientId
            settingId                  = [string]$connection.settingId
            clientSecret               = $ClientSecret
            scopes                     = $null
            serviceProviderId          = $ServiceProviderId
            serviceProviderDisplayName = "Azure Active Directory"
            clientCertificateUrl       = $null
            isx5cRequired              = $null
            uniqueIdentifier           = $null
            parameters = @(
                @{ key = "tenantId";     value = $TenantId },
                @{ key = "clientSecret"; value = $ClientSecret },
                @{ key = "clientId";     value = $ClientId },
                @{ key = "grantType";    value = $GrantType },
                @{ key = "loginUrl";     value = $loginUrl },
                @{ key = "resourceUri";  value = $ResourceUri },
                @{ key = "scopes";       value = $null }
            )
        }

        etag            = [string]$Current.etag
        authRedirectUrl = $AuthRedirectUrl
    }
}

$DataverseUrl = $DataverseUrl.TrimEnd("/")

Write-Host ""
Write-Host " Copilot Studio Authentication"
Write-Host ""
Write-Host "Tenant:      $TenantId"
Write-Host "Environment: $DataverseUrl"
Write-Host "Bot:         $BotName"
Write-Host ""
Write-Host "GatewayBaseUrl, InternalBotId and CopilotResource are"
Write-Host "discovered automatically."
Write-Host ""

# Login
Ensure-AzLogin

# Tokens used for environment discovery
Write-Host ""

$dataverseToken = Get-AzAccessToken `
    -Resource $DataverseUrl `
    -Description "Dataverse"

$powerPlatformToken = Get-AzAccessToken `
    -Resource "https://api.powerplatform.com/" `
    -Description "Power Platform API"

$bapToken = Get-AzAccessToken `
    -Resource "$BapApiBaseUrl/" `
    -Description "Business Application Platform API"

# Dynamic Copilot resource/token
$copilot = Resolve-CopilotResource
$CopilotResource = [string]$copilot.Resource
$copilotToken = [string]$copilot.Token
$copilotClaims = $copilot.Claims

# Dynamic environment IDs
$environment = Resolve-Environment -PowerPlatformToken $powerPlatformToken
$EnvironmentId = [string]$environment.id
$OrganizationId = [string]$environment.dataverseId

if ([string]::IsNullOrWhiteSpace($EnvironmentId) -or
    [string]::IsNullOrWhiteSpace($OrganizationId)) {
    throw "Environment or Dataverse organization ID could not be resolved."
}

Write-Host "Environment ID:  $EnvironmentId"
Write-Host "Organization ID: $OrganizationId"
Write-Host "Display Name:    $($environment.displayName)"

# Dynamic gateway
$GatewayBaseUrl = Resolve-GatewayBaseUrl `
    -EnvironmentId $EnvironmentId `
    -BapToken $bapToken

# Find bot
Write-Host ""
Write-Host "==> Finding target Dataverse bot '$BotName'..."

$escapedBotName = Escape-ODataString $BotName
$filter = [uri]::EscapeDataString("name eq '$escapedBotName'")

$botResult = Invoke-DataverseGet `
    -Path "bots?`$select=botid,name,schemaname,componentidunique,authenticationconfiguration,authenticationmode,authenticationtrigger,configuration,applicationmanifestinformation,synchronizationstatus&`$filter=$filter" `
    -Token $dataverseToken

$bots = @($botResult.value)

if ($bots.Count -eq 0) {
    throw "Bot '$BotName' was not found."
}

if ($bots.Count -gt 1) {
    throw "Multiple bots named '$BotName' were found."
}

$bot = $bots[0]
$CdsBotId = [string]$bot.botid

Write-Host "CDS Bot ID:  $CdsBotId"
Write-Host "Schema Name: $($bot.schemaname)"

# Dynamic internal routing bot ID + current configuration
$routing = Resolve-InternalBotId `
    -GatewayBaseUrl $GatewayBaseUrl `
    -CopilotToken $copilotToken `
    -CopilotClaims $copilotClaims `
    -EnvironmentId $EnvironmentId `
    -OrganizationId $OrganizationId `
    -CdsBotId $CdsBotId `
    -DataverseBot $bot

$InternalBotId = $routing.InternalBotId
$headers = $routing.Headers
$current = $routing.Configuration

Write-Host ""
Write-Host " DISCOVERY COMPLETE"
Write-Host "Copilot Resource: $CopilotResource"
Write-Host "Gateway Base URL: $GatewayBaseUrl"

if ([string]::IsNullOrWhiteSpace([string]$InternalBotId)) {
    Write-Host "Internal Bot ID:  not required by API"
}
else {
    Write-Host "Internal Bot ID:  $InternalBotId"
}

Write-Host "CDS Bot ID:       $CdsBotId"
Write-Host "Current mode:     $($current.authenticationMode)"
Write-Host "Current ETag:     $($current.etag)"

# Apply create/update immediately
# Some environments return a partial/stub authenticationConnection object
# even when no usable connection has been created yet. In that case the
# connection name and/or settingId can be empty. Treat that as CREATE rather
# than attempting PUT with an invalid connectionName.
$existingConnection = $current.authenticationConnection
$existingConnectionName = ""
$existingSettingId = ""

if ($null -ne $existingConnection) {
    $existingConnectionName = [string]$existingConnection.name
    $existingSettingId = [string]$existingConnection.settingId
}

Write-Host ""
Write-Host "Existing authentication connection:"
Write-Host "  Name:      '$existingConnectionName'"
Write-Host "  SettingId: '$existingSettingId'"

$isCreate = (
    $null -eq $existingConnection -or
    [string]::IsNullOrWhiteSpace($existingConnectionName) -or
    $existingConnectionName.Trim().Length -lt 2 -or
    [string]::IsNullOrWhiteSpace($existingSettingId)
)

if ($isCreate) {
    $configurationMethod = "POST"
    $payload = New-CreateConfigurationPayload -Etag ([string]$current.etag)
    Write-Host ""
    Write-Host "==> Creating manual Entra authentication..."
}
else {
    $configurationMethod = "PUT"
    $payload = New-UpdateConfigurationPayload -Current $current
    Write-Host ""
    Write-Host "==> Updating manual Entra authentication..."
}

$configurationUri = "$GatewayBaseUrl/api/botmanagement/v1/channels/authentication/connections/configuration"

$configResult = Invoke-CopilotRequest `
    -Method $configurationMethod `
    -Uri $configurationUri `
    -Headers $headers `
    -Body $payload

if ($null -eq $configResult -or
    [string]::IsNullOrWhiteSpace([string]$configResult.authenticationConnection.name) -or
    [string]::IsNullOrWhiteSpace([string]$configResult.etag)) {

    throw "Authentication configuration response is incomplete."
}

Write-Host "$configurationMethod configuration succeeded."
Write-Host "Connection Name: $($configResult.authenticationConnection.name)"
Write-Host "Setting ID:      $($configResult.authenticationConnection.settingId)"
Write-Host "ETag:            $($configResult.etag)"

# Authorization
$authorizationUri = "$GatewayBaseUrl/api/botauthoring/v1/environments/$EnvironmentId/bots/$CdsBotId/auth/authorization"

$authorizationPayload = @{
    authenticationTrigger = "Always"
    accessControlPolicy    = "Any"
    etag                   = [string]$configResult.etag
}

Write-Host ""
Write-Host "==> Applying authorization settings..."

Invoke-CopilotRequest `
    -Method POST `
    -Uri $authorizationUri `
    -Headers $headers `
    -Body $authorizationPayload | Out-Null

Write-Host "Authorization settings succeeded."

# Verify
Write-Host ""
Write-Host "==> Verifying final configuration..."

$verify = Invoke-CopilotRequest `
    -Method GET `
    -Uri $configurationUri `
    -Headers $headers

$verifiedTenantId = Get-ParameterValue `
    -Parameters $verify.authenticationConnection.parameters `
    -Key "tenantId"

if ([string]$verify.authenticationMode -ne "CustomAzureActiveDirectory") {
    throw "Verification failed: unexpected authentication mode."
}

if ([string]$verify.authenticationConnection.clientId -ne $ClientId) {
    throw "Verification failed: Client ID mismatch."
}

if ([string]$verifiedTenantId -ne $TenantId) {
    throw "Verification failed: Tenant ID mismatch."
}

Write-Host ""
Write-Host " SUCCESS"
Write-Host "Authentication mode: $($verify.authenticationMode)"
Write-Host "Connection name:     $($verify.authenticationConnection.name)"
Write-Host "Setting ID:          $($verify.authenticationConnection.settingId)"
Write-Host "Client ID:           $($verify.authenticationConnection.clientId)"
Write-Host "Tenant ID:           $verifiedTenantId"
Write-Host "Secret returned as:  $($verify.authenticationConnection.clientSecret)"
Write-Host "ETag:                $($verify.etag)"
Write-Host ""
Write-Host "Authentication deployment completed successfully."
