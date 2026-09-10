<#
.SYNOPSIS
  Binds the solution's connection references to real connections in the target
  environment, so an import comes up connected instead of half-configured.

.DESCRIPTION
  Copilot Studio writes one connection reference per agent tool. For this
  solution that is a Dataverse one and a SharePoint one, both used by Agent 1:

      cr720_Agent1TestScript.shared_commondataserviceforapps.shared-commondataser-...
      cr720_Agent1TestScript.shared_sharepointonline.shared-sharepointonl-...

  Those references arrive at the target environment empty. Nothing in the
  solution carries a connection id, because a connection is per-environment and
  per-user - it cannot travel inside a zip. Until each reference is pointed at a
  connection that exists in the target, the agent's tools fail at run time.

  Platform already has the binding mechanism: the deployment settings file that
  `pac solution import --settings-file` consumes. What it does not have is a way
  to fill that file in. That is all this script is:

      1. pac solution create-settings   lists every reference, ids blank
      2. pac connection list            what actually exists in the target
      3. match by connector, fill in the ids
      4. pac solution import --settings-file   with -Import

  Matching is by connector id. One connection for a connector is taken silently.
  Several - and this tenant has six SharePoint connections - is an ambiguity the
  script refuses to guess at: it prompts, or takes a -Connection override so the
  run stays unattended.

  Dataverse can also be created here, with -CreateDataverse. That connector
  publishes a ServicePrincipalOauth parameter set, so a client id, secret and
  tenant id are enough - no human, no consent screen.

  SharePoint cannot, and this is a platform limit rather than a gap in the
  script. Ask the connector what it accepts and shared_sharepointonline offers
  no parameter sets at all: one `token` of type oauthSetting carrying
  capability 'cloud', and username/password only under capability 'gateway',
  which is on-premises SharePoint Server through a data gateway, not SharePoint
  Online. So the first SharePoint connection in each new environment needs a
  person to sign in once at make.powerapps.com. After that its id is reusable
  forever and every later run is unattended.

.PARAMETER SolutionZip
  The packed solution to read the references from. Either this or -SolutionFolder.

.PARAMETER SolutionFolder
  An unpacked solution folder - the one holding Other\Solution.xml.

.PARAMETER EnvironmentUrl
  Target environment, e.g. https://org59029660.crm.dynamics.com

.PARAMETER SettingsFile
  Where to write the deployment settings. Defaults to .\deploy-settings.json.

.PARAMETER Connection
  Pins a connector to a connection id, 'connector=id', comma separated. Use it
  to keep the run unattended where more than one connection would match:

      -Connection shared_sharepointonline=shared-sharepointonl-25624ec1-...,shared_commondataserviceforapps=shared-commondataser-596d802d-...

.PARAMETER CreateDataverse
  Create a Dataverse connection with a service principal before binding, and use
  it. Needs -AppId and -TenantId, and the secret in $env:PP_CLIENT_SECRET so it
  never lands on a command line or in shell history. Requires `az login`.

.PARAMETER AppId
  Client id of the app registration the Dataverse connection signs in as. That
  app must already be an application user in the target environment.

.PARAMETER TenantId
  Tenant of that app registration.

.PARAMETER EnvironmentId
  Environment GUID, only needed by -CreateDataverse. Looked up from
  -EnvironmentUrl when omitted.

.PARAMETER NewConnectionName
  Display name for the connection -CreateDataverse makes. Default 'dataverse-sp'.

.PARAMETER CreateSharePoint
  Create a SharePoint connection before binding, and use it. Opens a browser for
  one sign-in - SharePoint has no service principal option - then polls until
  the connection reports Connected. Requires `az login`.

.PARAMETER SharePointConnectionName
  Display name for that connection. Default 'sharepoint-oauth'.

.PARAMETER ConsentTimeoutSeconds
  How long to wait for that sign-in. Default 300.

.PARAMETER Import
  Import the solution with the finished settings file. Without it the file is
  written and nothing touches the environment.

.EXAMPLE
  .\Set-SolutionConnections.ps1 -SolutionFolder C:\...\Explore_Connection_Solution `
                                -EnvironmentUrl https://org59029660.crm.dynamics.com

  Write deploy-settings.json, prompting where a connector is ambiguous.

.EXAMPLE
  .\Set-SolutionConnections.ps1 -SolutionZip .\Solution_Changed.zip `
      -EnvironmentUrl https://org59029660.crm.dynamics.com `
      -Connection shared_sharepointonline=shared-sharepointonl-25624ec1-8ab0-41b9-bdad-6c480a8be8ab,shared_commondataserviceforapps=shared-commondataser-596d802d-0a48-40a0-80e0-b4731da0349c `
      -Import

  Fully unattended: bind both of Agent 1's connectors and import.
#>
[CmdletBinding()]
param(
    [string]   $SolutionZip,
    [string]   $SolutionFolder,
    [string]   $EnvironmentUrl,
    [string]   $SettingsFile,
    [string[]] $Connection = @(),
    [switch]   $CreateDataverse,
    [string]   $AppId,
    [string]   $TenantId,
    [string]   $EnvironmentId,
    [string]   $NewConnectionName = 'dataverse-sp',
    [switch]   $CreateSharePoint,
    [string]   $SharePointConnectionName = 'sharepoint-oauth',
    [int]      $ConsentTimeoutSeconds = 300,
    [switch]   $Import,
    [switch]   $SelfTest,
    [switch]   $Help
)

if ($Help) { Get-Help $PSCommandPath -Detailed; return }

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Write-Log($m)     { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" }
function Write-Section($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

# `pac connection list` prints a fixed-width table, and a connection name may
# contain spaces ("Hosted browser") while the id, connector and status never do.
# So read the columns in from both ends and let the name be whatever is left.
function ConvertFrom-PacConnectionList {
    param([string[]] $Lines)
    $out = @()
    foreach ($line in $Lines) {
        $t = ($line -split '\s+') | Where-Object { $_ }
        if ($t.Count -lt 4) { continue }
        if ($t[-2] -notmatch '^/providers/Microsoft\.PowerApps/apis/') { continue }  # skips the header
        $out += [pscustomobject]@{
            Id        = $t[0]
            Connector = $t[-2] -replace '^.*/', ''
            Status    = $t[-1]
            Name      = ($t[1..($t.Count - 3)] -join ' ')
        }
    }
    $out
}

if ($SelfTest) {
    $rows = ConvertFrom-PacConnectionList @(
        'Id                        Name             API Id                                                       Status',
        'shared-sharepointonl-25   Demouser1@x.com  /providers/Microsoft.PowerApps/apis/shared_sharepointonline  Connected',
        '69f5e3e5258143            T14-GEN1 CUA     /providers/Microsoft.PowerApps/apis/shared_computeroperator  Connected',
        'Connected as somebody@example.com'
    )
    if ($rows.Count -ne 2)                        { throw "selftest: expected 2 rows, got $($rows.Count)" }
    if ($rows[0].Connector -ne 'shared_sharepointonline') { throw "selftest: connector was '$($rows[0].Connector)'" }
    if ($rows[1].Name      -ne 'T14-GEN1 CUA')    { throw "selftest: a name with a space was cut to '$($rows[1].Name)'" }
    if ($rows[0].Id        -ne 'shared-sharepointonl-25') { throw "selftest: id was '$($rows[0].Id)'" }
    'ok'
    return
}

if (-not $SolutionZip -and -not $SolutionFolder) { throw 'Pass -SolutionZip or -SolutionFolder.' }
if ($SolutionZip -and $SolutionFolder)           { throw 'Pass -SolutionZip or -SolutionFolder, not both.' }
if (-not $EnvironmentUrl)                        { throw 'Pass -EnvironmentUrl.' }
$EnvironmentUrl = $EnvironmentUrl.Trim().TrimEnd('/')
if ($Import -and -not $SolutionZip) { throw '-Import needs -SolutionZip: a folder cannot be imported, pack it first.' }

if (-not $SettingsFile) { $SettingsFile = Join-Path (Get-Location).Path 'deploy-settings.json' }

$pac = (Get-Command pac, pac.cmd -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $pac) { $pac = "$env:LOCALAPPDATA\Microsoft\PowerAppsCLI\pac.cmd" }
if (-not (Test-Path $pac)) { throw 'pac not found - install from https://aka.ms/PowerAppsCLI' }

# 'connector=id' pairs, connector name normalised so shared_sharepointonline and
# the full /providers/... form both work.
# -File hands an array parameter through as one comma-joined string, so split it
# back. A connection id never contains a comma.
$Connection = @($Connection | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$pins = @{}
foreach ($c in $Connection) {
    if ($c -notmatch '^(.+?)=(.+)$') { throw "-Connection wants 'connector=id', got '$c'." }
    $pins[($Matches[1] -replace '^.*/', '').Trim()] = $Matches[2].Trim()
}


Write-Section 'READING THE SOLUTION'

$src = if ($SolutionZip) { '--solution-zip' } else { '--solution-folder' }
$val = if ($SolutionZip) { $SolutionZip }     else { $SolutionFolder }
if (-not (Test-Path -LiteralPath $val)) { throw "Not found: $val" }
$val = (Resolve-Path -LiteralPath $val).Path

# pac.cmd returns 0 even where it printed an error, so prove the file instead.
if (Test-Path -LiteralPath $SettingsFile) { Remove-Item -LiteralPath $SettingsFile -Force }
& $pac solution create-settings $src $val --settings-file $SettingsFile 2>&1 | ForEach-Object { Write-Host "  $_" }
if (-not (Test-Path -LiteralPath $SettingsFile)) {
    throw "pac solution create-settings reported success but $SettingsFile is not there."
}

$settings = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
$refs = @($settings.ConnectionReferences)
if (-not $refs) { throw 'The solution declares no connection references - nothing to bind.' }
Write-Log "$($refs.Count) connection reference(s) in the solution."

# create-settings writes "Value": "" for every environment variable, and then the
# import rejects its own file with "Environment variable value can't be an empty
# string". An entry that is simply absent is fine - the value already baked into
# the solution is used - so drop the blanks rather than inventing values.
$vars  = @($settings.EnvironmentVariables)
$empty = @($vars | Where-Object { -not $_.Value })
if ($empty) {
    $settings.EnvironmentVariables = @($vars | Where-Object { $_.Value })
    Write-Log ("Dropped $($empty.Count) environment variable(s) with no value, keeping the solution's own: " +
               ($empty.SchemaName -join ', '))
}


if ($CreateDataverse -or $CreateSharePoint) {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI is needed to create a connection.' }
    if (-not (az account show 2>$null)) { throw 'No Azure CLI session. Run: az login' }

    $paToken = az account get-access-token --resource 'https://service.powerapps.com/' --query accessToken -o tsv
    if (-not $paToken) { throw 'Could not get a Power Apps token.' }
    $paHeaders = @{ Authorization = "Bearer $paToken"; Accept = 'application/json' }

    if (-not $EnvironmentId) {
        # instanceApiUrl is https://org65efd8ed.api.crm.dynamics.com while callers
        # pass https://org65efd8ed.crm.dynamics.com, so match on the org name only.
        $org = ([uri]$EnvironmentUrl).Host -replace '\..*$', ''
        $all = (Invoke-RestMethod -Headers $paHeaders `
                    -Uri 'https://api.powerapps.com/providers/Microsoft.PowerApps/environments?api-version=2016-11-01').value
        $hit = @($all | Where-Object {
            $_.properties.linkedEnvironmentMetadata.instanceApiUrl -and
            (([uri]$_.properties.linkedEnvironmentMetadata.instanceApiUrl).Host -replace '\..*$', '') -eq $org })
        if ($hit.Count -ne 1) { throw "Could not resolve $EnvironmentUrl to one environment id ($($hit.Count) matched). Pass -EnvironmentId." }
        $EnvironmentId = $hit[0].name
    }
    Write-Log "Environment $EnvironmentId"

    # Every connection call wants this filter; without it the API answers
    # MissingEnvironmentFilter.
    $envFilter = '&%24filter=' + [uri]::EscapeDataString("environment eq '$EnvironmentId'")
}


if ($CreateDataverse) {
    Write-Section 'CREATING A DATAVERSE CONNECTION'

    if (-not $AppId)    { throw '-CreateDataverse needs -AppId.' }
    if (-not $TenantId) { throw '-CreateDataverse needs -TenantId.' }
    $secret = $env:PP_CLIENT_SECRET
    if (-not $secret) {
        throw 'Put the client secret in $env:PP_CLIENT_SECRET. It is deliberately not a parameter - a secret on a command line ends up in shell history and in every process listing.'
    }

    $newId = (New-Guid).Guid.Replace('-', '')
    # The braces around $newId are load-bearing: '?' is legal in a PowerShell
    # variable name, so "$newId?api-version" reads as an empty variable.
    $url = 'https://api.powerapps.com/providers/Microsoft.PowerApps/apis/' +
           "shared_commondataserviceforapps/connections/${newId}?api-version=2016-11-01" + $envFilter

    $body = @{
        properties = @{
            displayName = $NewConnectionName
            environment = @{
                id   = "/providers/Microsoft.PowerApps/environments/$EnvironmentId"
                name = $EnvironmentId
            }
            connectionParametersSet = @{
                name   = 'ServicePrincipalOauth'
                values = @{
                    token                 = @{ value = 'https://global.consent.azure-apim.net/redirect/commondataserviceforapps' }
                    'token:clientId'      = @{ value = $AppId }
                    'token:clientSecret'  = @{ value = $secret }
                    'token:TenantId'      = @{ value = $TenantId }
                    'token:grantType'     = @{ value = 'client_credentials' }
                }
            }
        }
    } | ConvertTo-Json -Depth 20

    Write-Log "PUT $NewConnectionName as app $AppId (secret not logged)"
    try {
        Invoke-RestMethod -Method Put -Uri $url -Headers $paHeaders -ContentType 'application/json' -Body $body | Out-Null
    } catch {
        $detail = $_.ErrorDetails.Message -replace '(?i)"token:clientSecret"\s*:\s*\{[^}]*\}', '"token:clientSecret":"<REDACTED>"'
        throw "Creating the connection failed: $($_.Exception.Message)`n$detail"
    }

    # A bad secret still yields 201, with the failure only in statuses, so read
    # back rather than trusting the PUT.
    $made   = Invoke-RestMethod -Uri $url -Headers $paHeaders
    $status = $made.properties.statuses | Select-Object -First 1
    if ($status.status -ne 'Connected') {
        throw "Connection $newId was created but is '$($status.status)': $($status.error.message). Check the secret, and that $AppId is an application user in this environment."
    }
    Write-Log "Created $newId  ($NewConnectionName)  Connected"

    # Pin it, so the binding below uses this one and not some older connection.
    $pins['shared_commondataserviceforapps'] = $newId
}


if ($CreateSharePoint) {
    Write-Section 'CREATING A SHAREPOINT CONNECTION'

    # SharePoint has no service principal option, so the connection has to be
    # consented to by a person. What can be automated is everything around that:
    # the shell, the consent link, catching the code the browser is handed back,
    # and the confirm. The human part is one sign-in, usually one click.
    $newSpId = 'shared-sharepointonl-' + [Guid]::NewGuid().ToString()
    $spUrl   = 'https://api.powerapps.com/providers/Microsoft.PowerApps/apis/' +
               "shared_sharepointonline/connections/${newSpId}?api-version=2016-11-01" + $envFilter

    $spBody = @{ properties = @{
        displayName          = $SharePointConnectionName
        environment          = @{ id = "/providers/Microsoft.PowerApps/environments/$EnvironmentId"; name = $EnvironmentId }
        connectionParameters = @{}
    } } | ConvertTo-Json -Depth 10

    Invoke-RestMethod -Method Put -Uri $spUrl -Headers $paHeaders -ContentType 'application/json' -Body $spBody | Out-Null
    Write-Log "Created $newSpId unauthenticated, asking for a consent link"

    # Signing in at the consent link is what authenticates the connection; the
    # portal's follow-up confirmConsentCode call is bookkeeping, not a
    # requirement. Verified: a connection reaches Connected on sign-in alone.
    # So there is nothing to catch - ask the service, and poll.
    $redirect = 'https://make.powerapps.com/connection/oauth/redirect?oauthPopupId=' + [Guid]::NewGuid()
    $linkUrl  = 'https://api.powerapps.com/providers/Microsoft.PowerApps/apis/' +
                "shared_sharepointonline/connections/$newSpId/getConsentLink?api-version=2016-11-01" + $envFilter
    $link = (Invoke-RestMethod -Method Post -Uri $linkUrl -Headers $paHeaders -ContentType 'application/json' `
                -Body (@{ redirectUrl = $redirect } | ConvertTo-Json)).consentLink
    if (-not $link) { throw 'The consent service returned no link.' }

    Write-Host ''
    Write-Host '  A browser window is opening. Sign in as the account the flows should run as.' -ForegroundColor Yellow
    Write-Host "  If it does not open, paste this in yourself:`n  $link"
    Start-Process $link

    $deadline = (Get-Date).AddSeconds($ConsentTimeoutSeconds)
    do {
        Start-Sleep -Seconds 3
        $spStatus = (Invoke-RestMethod -Uri $spUrl -Headers $paHeaders).properties.statuses | Select-Object -First 1
        Write-Host "  waiting for sign-in... $($spStatus.status)"
    } while ($spStatus.status -ne 'Connected' -and (Get-Date) -lt $deadline)

    if ($spStatus.status -ne 'Connected') {
        throw ("Still '$($spStatus.status)' after $ConsentTimeoutSeconds seconds. " +
               "Connection $newSpId is left behind - delete it in make.powerapps.com, or rerun with " +
               "-Connection shared_sharepointonline=$newSpId once you have signed it in there.")
    }

    $spMade = Invoke-RestMethod -Uri $spUrl -Headers $paHeaders
    Write-Log "Created $newSpId  ($($spMade.properties.displayName))  Connected as $($spMade.properties.authenticatedUser.name)"

    $pins['shared_sharepointonline'] = $newSpId
}


Write-Section "CONNECTIONS IN $EnvironmentUrl"

$listed = & $pac connection list --environment $EnvironmentUrl 2>&1 | ForEach-Object { "$_" }
$conns  = @(ConvertFrom-PacConnectionList $listed)
if (-not $conns) {
    $listed | ForEach-Object { Write-Host "  $_" }
    throw "No connections were listed. Check 'pac auth list' points at $EnvironmentUrl."
}
$conns | Group-Object Connector | ForEach-Object {
    Write-Log "$($_.Name): $($_.Count) connection(s)"
}


Write-Section 'BINDING'

foreach ($r in $refs) {
    $connector = $r.ConnectorId -replace '^.*/', ''

    if ($pins.ContainsKey($connector)) {
        $r.ConnectionId = $pins[$connector]
        Write-Log "$connector -> $($r.ConnectionId)  (-Connection)"
        continue
    }

    $candidates = @($conns | Where-Object { $_.Connector -eq $connector -and $_.Status -eq 'Connected' })

    if ($candidates.Count -eq 0) {
        throw @"
No connected '$connector' connection exists in $EnvironmentUrl.

Create one first - these connectors sign in as a user, so the first one needs a
human to consent:

    Dataverse    pac connection create -env $EnvironmentUrl -n "<name>" -t <tenant> -a <appid> -cs <secret>
    SharePoint   $EnvironmentUrl -> make.powerapps.com -> Connections -> New connection

then run this again.
"@
    }

    if ($candidates.Count -eq 1) {
        $r.ConnectionId = $candidates[0].Id
        Write-Log "$connector -> $($r.ConnectionId)"
        continue
    }

    # Several match. Guessing here binds the agent to whichever connection the
    # API happened to return first, which is how a tool ends up reading the
    # wrong site, so ask instead.
    Write-Host "`n  $($refs.IndexOf($r) + 1). $($r.LogicalName)"
    Write-Host "  $($candidates.Count) '$connector' connections match:"
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host ("    [{0}] {1}  {2}" -f ($i + 1), $candidates[$i].Id, $candidates[$i].Name)
    }
    $answer = (Read-Host "  Pick 1-$($candidates.Count)").Trim()
    $pick = 0
    if (-not [int]::TryParse($answer, [ref]$pick) -or $pick -lt 1 -or $pick -gt $candidates.Count) {
        throw "'$answer' is not one of 1-$($candidates.Count). Pass -Connection $connector=<id> to run unattended."
    }
    $r.ConnectionId = $candidates[$pick - 1].Id
    Write-Log "$connector -> $($r.ConnectionId)"
}

$blank = @($refs | Where-Object { -not $_.ConnectionId })
if ($blank) { throw "Still unbound: $($blank.LogicalName -join ', ')" }

# UTF8 without a BOM: pac reads this file as JSON and a BOM has bitten this
# pipeline before.
[System.IO.File]::WriteAllText(
    $SettingsFile,
    ($settings | ConvertTo-Json -Depth 20),
    (New-Object System.Text.UTF8Encoding $false))

Write-Log "Wrote $SettingsFile"


if ($Import) {
    Write-Section "IMPORT INTO $EnvironmentUrl"
    $out = & $pac solution import --environment $EnvironmentUrl --path $SolutionZip `
                --settings-file $SettingsFile --publish-changes --force-overwrite `
                --activate-plugins --max-async-wait-time 60 2>&1 | ForEach-Object { "$_" }
    $out | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0 -or ($out -match '^\s*Error:')) {
        # Carry pac's own lines into the exception. Without them the throw is all
        # the caller sees once the console has scrolled.
        $why = @($out | Where-Object { $_ -match '(?i)error|fail|unable|cannot|missing' }) -join "`n  "
        throw ("Import failed.`n  " + $why +
               "`n`nThe settings file is at $SettingsFile - it is reusable, fix the cause and rerun with -Import.")
    }
}


Write-Section 'DONE'
$refs | Select-Object @{n = 'Connector'; e = { $_.ConnectorId -replace '^.*/', '' } }, ConnectionId, LogicalName |
    Format-Table -AutoSize
if (-not $Import) { Write-Host "Import with:  pac solution import --environment $EnvironmentUrl --path <zip> --settings-file $SettingsFile" }
