<#
.SYNOPSIS
  Creates a Computer Use connection for one Power Automate machine, plus the
  Dataverse connection reference the agent binds to.

.DESCRIPTION
  Interactive. Prompts for four things and does the rest:

      Machine name        as shown in Power Automate -> Monitor -> Machines
      Connection name     ENTER accepts '<machine>-CUA'
      Windows username    the account that signs into that machine
      Windows password    read as a SecureString, never logged

  It then

      1. looks the machine up in the Dataverse flowmachines table and takes its
         flow machine GROUP id - that group id is what the connection binds to,
      2. PUTs a shared_computeroperator connection carrying the group id and the
         Windows credential, and reads it back to confirm targetId took,
      3. creates - or reuses, if one already matches - the Dataverse connection
         reference row named
         <bot component schema>.shared_computeroperator.<connection id>.

  It does NOT point the agent's Computer Use action at the new connection and it
  does not publish. Do that afterwards in the agent designer, or with
  Probe-CuaConnection.ps1 -ConnectionName '<connection name>'.

  Authenticates with the current `az login`, and runs `az login` if there is no
  session. The environment, Dataverse org and bot component schema are constants
  at the top of this file - edit them to target a different agent or org.

.PARAMETER Help
  Print this help and exit, without signing in or prompting.

.EXAMPLE
  .\CreateCUA-Connection.ps1

  Create a connection, answering the four prompts.

.EXAMPLE
  .\CreateCUA-Connection.ps1 -Help
#>
param([switch]$Help)

if ($Help) { Get-Help $PSCommandPath -Detailed; return }

$EnvironmentId      = "cb1f75b0-80a1-e1f6-bd64-3b271177f91e"
$DataverseUrl       = "https://org59029660.crm.dynamics.com"
$ConnectorApiName   = "shared_computeroperator"
$BotComponentSchema = "cr720_Agent2UITesting.action.Computeruse-Computeruse"

function Write-Log($m)     { Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $m" }
function Write-Section($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }


Write-Section "AZURE CLI"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI is not installed or is not available in PATH."
}

# az is a native exe: a failed `account show` sets $LASTEXITCODE, it never throws,
# so this is an if and not a try/catch.
if (-not (az account show 2>$null)) {
    Write-Log "No Azure CLI session. Launching login..."
    az login | Out-Null
}

$Account = az account show --query "{user:user.name,tenant:tenantId}" -o json | ConvertFrom-Json
Write-Log "Authenticated as $($Account.user) on tenant $($Account.tenant)."


Write-Section "TARGET POWER AUTOMATE MACHINE"

Write-Host "`nName the machine exactly as it appears in Power Automate -> Monitor -> Machines.`n"

$TargetMachineName = (Read-Host "Machine name").Trim()
if (-not $TargetMachineName) { throw "Machine name cannot be empty." }


Write-Section "CONNECTION NAME"

$DefaultConnectionName    = "$TargetMachineName-CUA"
$NewConnectionDisplayName = (Read-Host "Connection name (ENTER for '$DefaultConnectionName')").Trim()
if (-not $NewConnectionDisplayName) { $NewConnectionDisplayName = $DefaultConnectionName }

Write-Log "Connection display name: $NewConnectionDisplayName"


Write-Section "DATAVERSE TOKEN"

$DataverseToken = az account get-access-token --resource $DataverseUrl --query accessToken -o tsv
if (-not $DataverseToken) { throw "Unable to obtain Dataverse access token." }

$DataverseHeaders = @{
    Authorization      = "Bearer $DataverseToken"
    Accept             = "application/json"
    "OData-Version"    = "4.0"
    "OData-MaxVersion" = "4.0"
}

Write-Log "Dataverse token obtained (value not logged)."


Write-Section "FINDING POWER AUTOMATE MACHINE"

$EscapedMachineName = $TargetMachineName.Replace("'", "''")
$MachineQuery = "$DataverseUrl/api/data/v9.2/flowmachines?" +
    "`$select=flowmachineid,name,_flowmachinegroupid_value" +
    "&`$filter=name eq '$EscapedMachineName'"

try { $Machines = @((Invoke-RestMethod -Method Get -Uri $MachineQuery -Headers $DataverseHeaders).value) }
catch {
    Write-Log "ERROR querying Flow Machine table: $($_.Exception.Message)"
    throw
}

if ($Machines.Count -eq 0) {
    throw @"
Machine '$TargetMachineName' was not found.

Confirm it already exists under Power Automate -> Monitor -> Machines.
"@
}
if ($Machines.Count -gt 1) {
    throw "More than one machine matched '$TargetMachineName': $($Machines.flowmachineid -join ', ')"
}

$TargetFlowMachineId      = $Machines[0].flowmachineid
$TargetFlowMachineGroupId = $Machines[0]._flowmachinegroupid_value
if (-not $TargetFlowMachineId)      { throw "Flow Machine ID was empty." }
if (-not $TargetFlowMachineGroupId) { throw "Flow Machine Group ID was empty." }

Write-Log "Machine found: $($Machines[0].name)"
Write-Log "Flow Machine ID: $TargetFlowMachineId"
Write-Log "Flow Machine Group ID: $TargetFlowMachineGroupId"


Write-Section "WINDOWS MACHINE CREDENTIALS"

Write-Host "`nThe Windows account used to sign into $TargetMachineName.`n"

$MachineUsername = (Read-Host "Windows username").Trim()
if (-not $MachineUsername) { throw "Windows username cannot be empty." }

$MachinePassword = [Net.NetworkCredential]::new(
    '', (Read-Host "Windows password" -AsSecureString)).Password

Write-Log "Windows credentials received (values not logged)."


Write-Section "POWER APPS API TOKEN"

$PowerAppsToken = az account get-access-token --resource "https://service.powerapps.com/" --query accessToken -o tsv
if (-not $PowerAppsToken) { throw "Unable to obtain Power Apps API token." }

$PowerAppsHeaders = @{ Authorization = "Bearer $PowerAppsToken"; Accept = "application/json" }

Write-Log "Power Apps token obtained (value not logged)."


Write-Section "CREATING COMPUTER USE CONNECTION"

$NewConnectionId = (New-Guid).Guid.Replace("-", "")
Write-Log "New Connection ID: $NewConnectionId"

$ConnectionUrl = "https://api.powerapps.com/providers/Microsoft.PowerApps/apis/" +
    "$ConnectorApiName/connections/$NewConnectionId?api-version=2016-11-01" +
    "&%24filter=$([uri]::EscapeDataString("environment eq '$EnvironmentId'"))"

$ConnectionBody = @{
    properties = @{
        displayName = $NewConnectionDisplayName
        environment = @{
            id   = "/providers/Microsoft.PowerApps/environments/$EnvironmentId"
            name = $EnvironmentId
        }
        connectionParametersSet = @{
            name   = "azureRelay"
            values = @{
                targetId       = @{ value = $TargetFlowMachineGroupId }
                username       = @{ value = $MachineUsername }
                password       = @{ value = $MachinePassword }
                environment    = @{ value = $EnvironmentId }
                xrmInstanceUri = @{ value = "$DataverseUrl/" }
                connectionType = @{ value = "azureRelay" }
            }
        }
    }
} | ConvertTo-Json -Depth 20

Write-Log "Binding $TargetMachineName via targetId $TargetFlowMachineGroupId (credentials redacted)."

try {
    Invoke-RestMethod -Method Put -Uri $ConnectionUrl -Headers $PowerAppsHeaders `
        -ContentType "application/json" -Body $ConnectionBody | Out-Null
    Write-Log "Create request succeeded."
}
catch {
    Write-Log "CREATE REQUEST FAILED: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) {
        Write-Log "Server response: $($_.ErrorDetails.Message -replace '(?i)"password"\s*:\s*"[^"]+"', '"password":"<REDACTED>"')"
    }
    throw
}

# Read back rather than trusting the PUT response: targetId is the whole point of
# the connection, and the PUT body is not documented to echo the parameter set.
$Connection = Invoke-RestMethod -Method Get -Uri $ConnectionUrl -Headers $PowerAppsHeaders

$ReturnedTargetId = $Connection.properties.connectionParametersSet.values.targetId.value
if ($ReturnedTargetId -ne $TargetFlowMachineGroupId) {
    throw "Connection was created, but targetId is '$ReturnedTargetId', expected '$TargetFlowMachineGroupId'."
}

$ConnectionStatus = $Connection.properties.statuses.status | Select-Object -First 1
Write-Log "Machine binding validated. Status: $ConnectionStatus"


Write-Section "CONNECTION REFERENCE"

$CrLogicalName = "$BotComponentSchema.$ConnectorApiName.$NewConnectionId"
$CrConnectorId = "/providers/Microsoft.PowerApps/apis/$ConnectorApiName"
$CrSelect      = "connectionreferenceid,connectionreferencelogicalname," +
                 "connectionreferencedisplayname,connectionid,connectorid,createdon,modifiedon"

Write-Log "Logical name: $CrLogicalName"

$CrFilter = [uri]::EscapeDataString(
    "connectionid eq '$NewConnectionId' or connectionreferencelogicalname eq '$CrLogicalName'")
$Existing = @((Invoke-RestMethod -Method Get -Headers $DataverseHeaders `
    -Uri "$DataverseUrl/api/data/v9.2/connectionreferences?`$select=$CrSelect&`$filter=$CrFilter").value)

if ($Existing.Count -gt 1) { throw "Multiple matching Connection Reference rows were found." }

if ($Existing.Count -eq 1) {
    $Cr = $Existing[0]
    Write-Log "Connection Reference already exists - no duplicate row created."
}
else {
    # return=representation hands back the stored row, so no read-back is needed below.
    $CrHeaders = $DataverseHeaders.Clone()
    $CrHeaders["Prefer"] = "return=representation"

    $CrBody = @{
        connectionreferencelogicalname = $CrLogicalName
        connectionreferencedisplayname = $CrLogicalName
        connectionid                   = $NewConnectionId
        connectorid                    = $CrConnectorId
    } | ConvertTo-Json

    try {
        $Cr = Invoke-RestMethod -Method Post -Headers $CrHeaders -ContentType "application/json" -Body $CrBody `
            -Uri "$DataverseUrl/api/data/v9.2/connectionreferences?`$select=$CrSelect"
        Write-Log "Connection Reference created."
    }
    catch {
        Write-Log "Connection Reference CREATE FAILED: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) { Write-Log "Server response: $($_.ErrorDetails.Message)" }
        throw
    }
}

if (-not $Cr.connectionreferenceid) { throw "Connection Reference ID was empty after create/reuse." }
if ($Cr.connectionid -ne $NewConnectionId) {
    throw "Connection Reference verification failed: connectionid is '$($Cr.connectionid)'."
}
if ($Cr.connectionreferencelogicalname -ne $CrLogicalName) {
    throw "Connection Reference verification failed: logical name is '$($Cr.connectionreferencelogicalname)'."
}
if ($Cr.connectorid -ne $CrConnectorId) {
    throw "Connection Reference verification failed: connectorid is '$($Cr.connectorid)'."
}

Write-Log "Connection Reference validated."


Write-Section "DONE"

[pscustomobject]@{
    'Machine'                  = $TargetMachineName
    'Flow Machine ID'          = $TargetFlowMachineId
    'Flow Machine Group ID'    = $TargetFlowMachineGroupId
    'Connection'               = $NewConnectionDisplayName
    'Connection ID'            = $NewConnectionId
    'Status'                   = $ConnectionStatus
    'Connection Reference ID'  = $Cr.connectionreferenceid
    'Reference Logical Name'   = $CrLogicalName
} | Format-List
