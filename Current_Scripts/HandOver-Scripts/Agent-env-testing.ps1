param(
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentId,
 
    [Parameter(Mandatory = $false)]
    [string]$Agent1SchemaName = "cr720_Agent1TestScript",
 
    [Parameter(Mandatory = $false)]
    [string]$Agent2SchemaName = "cr720_Agent2UITesting",
 
    [Parameter(Mandatory = $false)]
    [string]$OutputDirectory = ".",

    # Direct Line secrets are long-lived credentials, so they are masked unless
    # you ask for them. A pasted console log should not hand someone a live key.
    [Parameter(Mandatory = $false)]
    [switch]$ShowSecret
)
 
$ErrorActionPreference = "Stop"
 
function Convert-EnvironmentIdToApiId {
    param([Parameter(Mandatory = $true)][string]$Id)
 
    $clean = $Id.Replace("-", "").Trim()
 
    if ($clean.Length -ne 32) {
        throw "EnvironmentId must be a GUID. Received: $Id"
    }
 
    return $clean.Substring(0, 30) + "." + $clean.Substring(30, 2)
}
 
function Decode-JwtPayload {
    param([Parameter(Mandatory = $true)][string]$Jwt)
 
    $parts = $Jwt.Split(".")
    if ($parts.Length -lt 2) {
        throw "The returned value is not a valid JWT."
    }
 
    $payload = $parts[1].Replace("-", "+").Replace("_", "/")
 
    switch ($payload.Length % 4) {
        0 { }
        2 { $payload += "==" }
        3 { $payload += "=" }
        default { throw "Invalid JWT Base64Url payload." }
    }
 
    $bytes = [Convert]::FromBase64String($payload)
    $json = [Text.Encoding]::UTF8.GetString($bytes)
 
    return $json | ConvertFrom-Json
}
 
# Copilot Studio's own first-party app. The Azure CLI can get a token for this
# with no extra consent, and the powervamg gateway accepts it.
$CopilotStudioResource = "96ff4394-9197-43aa-b393-6a41652e21f8"

function Get-AzToken {
    param([Parameter(Mandatory = $true)][string]$Resource)

    $token = az account get-access-token --resource $Resource --query accessToken -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw "Could not get a token for $Resource. Sign in first: az login"
    }
    return "$token".Trim()
}

function Format-Secret {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return "(empty)" }
    if ($ShowSecret) { return $Value }
    return ("*" * 16) + $Value.Substring([Math]::Max(0, $Value.Length - 4))
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Copilot Studio Agent Connection Discovery" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
 
# 1. Environment API host
$environmentApiId = Convert-EnvironmentIdToApiId -Id $EnvironmentId
$environmentApiBase = "https://$environmentApiId.environment.api.powerplatform.com"
 
Write-Host "[1/7] Environment API discovered" -ForegroundColor Green
Write-Host "      Environment ID : $EnvironmentId"
Write-Host "      Environment API: $environmentApiBase"
Write-Host ""
 
# 2. Agent 1 + Agent 2 direct connect URLs
$agent1DirectConnectUrl =
    "$environmentApiBase/copilotstudio/dataverse-backed/authenticated/bots/$Agent1SchemaName/conversations?api-version=2022-03-01-preview"
 
$agent2DirectConnectUrl =
    "$environmentApiBase/copilotstudio/dataverse-backed/authenticated/bots/$Agent2SchemaName/conversations?api-version=2022-03-01-preview"
 
Write-Host "[2/7] Agent connection strings created" -ForegroundColor Green
Write-Host ""
Write-Host "Agent 1 Direct Connect URL:"
Write-Host $agent1DirectConnectUrl -ForegroundColor Yellow
Write-Host ""
Write-Host "Agent 2 Direct Connect URL:"
Write-Host $agent2DirectConnectUrl -ForegroundColor Yellow
Write-Host ""
 
# 3. Get temporary Agent 2 discovery token and decode the Direct Line channel Bot ID
$agent2DiscoveryTokenUrl =
    "$environmentApiBase/powervirtualagents/botsbyschema/$Agent2SchemaName/directline/token?api-version=2022-03-01-preview"
 
Write-Host "[3/7] Getting Agent 2 discovery token..." -ForegroundColor Cyan
Write-Host "      $agent2DiscoveryTokenUrl"
 
$discoveryResponse = Invoke-RestMethod `
    -Method GET `
    -Uri $agent2DiscoveryTokenUrl `
    -Headers @{ Accept = "application/json" }
 
$discoveryToken = $discoveryResponse.token
 
if ([string]::IsNullOrWhiteSpace($discoveryToken)) {
    throw "The Agent 2 discovery endpoint did not return a token."
}
 
$jwtPayload = Decode-JwtPayload -Jwt $discoveryToken
$agent2ChannelBotId = [string]$jwtPayload.bot
 
if ([string]::IsNullOrWhiteSpace($agent2ChannelBotId)) {
    throw "Could not find the 'bot' claim in the Agent 2 Direct Line JWT."
}
 
Write-Host ""
Write-Host "      Agent 2 Direct Line Channel Bot ID:" -ForegroundColor Green
Write-Host "      $agent2ChannelBotId" -ForegroundColor Yellow
Write-Host ""
 
# 4. Build the Copilot Studio Web/SSO Direct Line token URL and request a token
$agent2TokenUrl =
    "https://powerva.microsoft.com/api/botmanagement/v1/directline/directlinetoken?botId=$agent2ChannelBotId"
 
Write-Host "[4/7] Getting Agent 2 Web/SSO Direct Line token..." -ForegroundColor Cyan
Write-Host "      $agent2TokenUrl"
 
$directLineResponse = Invoke-RestMethod `
    -Method GET `
    -Uri $agent2TokenUrl `
    -Headers @{ Accept = "application/json" }
 
$directLineToken = $directLineResponse.token
 
if ([string]::IsNullOrWhiteSpace($directLineToken)) {
    throw "The Copilot Studio Direct Line endpoint did not return a token."
}
 
$directLinePayload = Decode-JwtPayload -Jwt $directLineToken
 
Write-Host ""
Write-Host "      Direct Line token acquired successfully." -ForegroundColor Green
 
if ($directLinePayload.exp) {
    $expiry = [DateTimeOffset]::FromUnixTimeSeconds([int64]$directLinePayload.exp).UtcDateTime
    Write-Host "      Token expires UTC: $($expiry.ToString('yyyy-MM-dd HH:mm:ss'))"
}
 
if ($directLinePayload.conv) {
    Write-Host "      Conversation ID : $($directLinePayload.conv)"
}
 
Write-Host ""
 
# 5. Resolve the environment. The regional gateway host and the Dataverse org
#    both come straight off the environment record, so neither is hardcoded.
Write-Host "[5/7] Resolving environment endpoints..." -ForegroundColor Cyan

$powerAppsHeaders = @{
    Authorization = "Bearer $(Get-AzToken 'https://service.powerapps.com/')"
    Accept        = "application/json"
}

$allEnvironments = (Invoke-RestMethod -Headers $powerAppsHeaders `
    -Uri "https://api.powerapps.com/providers/Microsoft.PowerApps/environments?api-version=2016-11-01").value

$environmentRow = @($allEnvironments | Where-Object { $_.name -eq $EnvironmentId })
if ($environmentRow.Count -ne 1) {
    throw "Environment $EnvironmentId matched $($environmentRow.Count) environments you can see, expected 1."
}

$environmentProperties = $environmentRow[0].properties
$gatewayBaseUrl = [string]$environmentProperties.runtimeEndpoints.'microsoft.PowerVirtualAgents'
$dataverseUrl   = ([string]$environmentProperties.linkedEnvironmentMetadata.instanceUrl).TrimEnd("/")

if (-not $gatewayBaseUrl) { throw "The environment record carries no Power Virtual Agents runtime endpoint." }
if (-not $dataverseUrl)   { throw "The environment record carries no linked Dataverse instance." }

Write-Host "      Gateway  : $gatewayBaseUrl"
Write-Host "      Dataverse: $dataverseUrl"
Write-Host ""

# The channel API checks BOTH ids, and they are different things: x-cci-botid is
# the Direct Line channel bot, x-cci-cdsbotid is the row in the Dataverse bots
# table. Sending one without the other is a 400, not a 401.
$dataverseHeaders = @{
    Authorization   = "Bearer $(Get-AzToken $dataverseUrl)"
    Accept          = "application/json"
    "OData-Version" = "4.0"
}

$whoAmI = Invoke-RestMethod -Uri "$dataverseUrl/api/data/v9.2/WhoAmI" -Headers $dataverseHeaders
$organizationId = [string]$whoAmI.OrganizationId

$botFilter   = "`$select=botid,schemaname&`$filter=schemaname eq '$Agent2SchemaName'"
$botQueryUrl = "$dataverseUrl/api/data/v9.2/bots?$botFilter"
$botRows     = @((Invoke-RestMethod -Uri $botQueryUrl -Headers $dataverseHeaders).value)

if ($botRows.Count -ne 1) {
    throw "Expected exactly one bot row with schema name '$Agent2SchemaName'; found $($botRows.Count)."
}

$agent2CdsBotId = [string]$botRows[0].botid
$tenantId = "$(az account show --query tenantId -o tsv 2>$null)".Trim()

Write-Host "      Dataverse bot id: $agent2CdsBotId"
Write-Host "      Organization id : $organizationId"
Write-Host ""

# 6. Direct Line channel secrets. Two keys, primary and secondary, so one can be
#    rotated while the other keeps serving traffic.
Write-Host "[6/7] Reading Direct Line channel secrets..." -ForegroundColor Cyan

$channelHeaders = @{
    Authorization            = "Bearer $(Get-AzToken $CopilotStudioResource)"
    Accept                   = "application/json"
    "x-cci-botid"            = $agent2ChannelBotId
    "x-cci-cdsbotid"         = $agent2CdsBotId
    "x-cci-tenantid"         = $tenantId
    "x-cci-bapenvironmentid" = $EnvironmentId
    "x-cci-organizationid"   = $organizationId
}

$channelUrl = "$gatewayBaseUrl/api/botmanagement/v1/channels/directline"

try {
    $channelResponse = Invoke-RestMethod -Uri $channelUrl -Headers $channelHeaders
    $directLineKeys = @($channelResponse)[0]
}
catch {
    $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    throw "Could not read the Direct Line channel secrets from $channelUrl`n$detail"
}

if (-not $directLineKeys.key) { throw "The Direct Line channel returned no key." }

Write-Host "      Primary  : $(Format-Secret $directLineKeys.key)" -ForegroundColor Yellow
Write-Host "      Secondary: $(Format-Secret $directLineKeys.key2)" -ForegroundColor Yellow
if (-not $ShowSecret) {
    Write-Host "      (masked - pass -ShowSecret to print them in full)"
}
Write-Host ""

# Whether anonymous chat is allowed. With this true the secret alone is not
# enough to talk to the agent, and the caller has to sign in as well.
$accessPolicy = $null
try {
    $accessPolicy = Invoke-RestMethod -Uri "$channelUrl/accesspolicy" -Headers $channelHeaders
    Write-Host "      Anonymous access disabled: $($accessPolicy.isAnonymousAccessDisabled)"
}
catch {
    Write-Host "      Access policy unavailable: $($_.Exception.Message)" -ForegroundColor DarkYellow
}
Write-Host ""

# 7. Save stable deployment configuration
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
 
$config = [ordered]@{
    environmentId             = $EnvironmentId
    environmentApiId          = $environmentApiId
    environmentApiBase        = $environmentApiBase
    agent1SchemaName          = $Agent1SchemaName
    agent1DirectConnectUrl    = $agent1DirectConnectUrl
    agent2SchemaName          = $Agent2SchemaName
    agent2DirectConnectUrl    = $agent2DirectConnectUrl
    agent2ChannelBotId        = $agent2ChannelBotId
    agent2CdsBotId            = $agent2CdsBotId
    agent2TokenUrl            = $agent2TokenUrl
    gatewayBaseUrl            = $gatewayBaseUrl
    dataverseUrl              = $dataverseUrl
    organizationId            = $organizationId
    tenantId                  = $tenantId
    directLineChannelUrl      = $channelUrl
    isAnonymousAccessDisabled = $(if ($null -ne $accessPolicy) { $accessPolicy.isAnonymousAccessDisabled } else { $null })
}
 
$configFile = Join-Path $outputPath "Copilot-Agent-Connection-Config.json"
$config | ConvertTo-Json -Depth 5 | Set-Content -Path $configFile -Encoding UTF8
 
# Temporary token output for testing only
$tokenFile = Join-Path $outputPath "Agent2-DirectLine-Token.json"
 
$tokenOutput = [ordered]@{
    token          = $directLineToken
    botId          = $agent2ChannelBotId
    tokenEndpoint  = $agent2TokenUrl
    conversationId = $directLinePayload.conv
    expiresUnix    = $directLinePayload.exp
}
 
$tokenOutput | ConvertTo-Json -Depth 5 | Set-Content -Path $tokenFile -Encoding UTF8
 
Write-Host "[7/7] Complete" -ForegroundColor Green
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " VALUES FOR FRONTEND / DEPLOYMENT" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "NEXT_PUBLIC_AGENT1_DIRECT_CONNECT_URL=" -NoNewline
Write-Host $agent1DirectConnectUrl -ForegroundColor Yellow
Write-Host ""
Write-Host "NEXT_PUBLIC_AGENT2_BOT_ID=" -NoNewline
Write-Host $agent2ChannelBotId -ForegroundColor Yellow
Write-Host ""
Write-Host "NEXT_PUBLIC_AGENT2_TOKEN_URL=" -NoNewline
Write-Host $agent2TokenUrl -ForegroundColor Yellow
Write-Host ""
Write-Host "Current Agent 2 Direct Line token (TEMPORARY):" -ForegroundColor Cyan
Write-Host $directLineToken -ForegroundColor Yellow
Write-Host ""
Write-Host "Stable config saved to:" -ForegroundColor Green
Write-Host "  $configFile"
Write-Host ""
Write-Host "Temporary token saved to:" -ForegroundColor Green
Write-Host "  $tokenFile"
Write-Host ""
Write-Host "IMPORTANT:" -ForegroundColor Magenta
Write-Host "  Keep agent2TokenUrl + Bot ID as stable configuration."
Write-Host "  Do NOT use the generated Direct Line token as permanent config."
Write-Host "  The frontend should request a fresh token from agent2TokenUrl at runtime."
Write-Host ""