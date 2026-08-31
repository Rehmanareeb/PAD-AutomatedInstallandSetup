<#
.SYNOPSIS
  Switches which machine the agent's Computer Use tool runs on.

.DESCRIPTION
  The machine is decided by one line in the Computer Use action, stored in the
  Dataverse botcomponents table:

      connectionReference: <prefix>.shared_computeroperator.<connection-id>

  Each connection targets one machine and carries its Windows credential, so
  rewriting that connection id moves the agent to a different machine. Publish
  the agent afterwards - the change does not reach the runtime until you do.

  Without -SetConnectionId / -ConnectionName this only reads and reports.
  Connection ids and display names come from: pac connection list

  Sign in with one of
      -UseAzureCli    silent, reuses an existing `az login`
      -Interactive    device code, sign in as yourself
      -ApplicationId  app-only, client secret in $env:PAD_SECRET

  App-only is enough to read, and enough to switch between connections that
  already have a reference row - that writes only the link and the action's
  YAML. Creating a row also writes connectionid, which the connectivity service
  only lets the connection's owner do: proven 2026-08-25, the app registration
  fails with code 10006 even holding System Administrator. Use -UseAzureCli or
  -Interactive for that.

  The application user needs Bot Component and Connection Reference
  (Read + Write, Business Unit) on its security role.

  Every parameter: Get-Help .\Probe-CuaConnection.ps1 -Full

.EXAMPLE
  $env:PAD_SECRET = '<client secret>'
  .\Probe-CuaConnection.ps1 -ApplicationId <app-guid> -ConnectionName VM-Desktop

.EXAMPLE
  # Report the current binding only.
  .\Probe-CuaConnection.ps1 -ApplicationId <app-guid>
#>
[CmdletBinding()]
param(
    [string]$ApplicationId,
    # Sign in as a person, in a browser.
    [switch]$Interactive,
    # Take the same delegated token from an existing `az login`, with no prompt.
    [switch]$UseAzureCli,
    # Both default to the local PAD registration, as in Setup_PAD_Final.ps1.
    [string]$OrgUrl,
    [string]$TenantId,
    # Widen to see every connection reference, not just Computer Use ones.
    [switch]$All,
    # Repoint the Computer Use action at a different connection, e.g.
    # 'shared-computeropera-<guid>'. This is what switches machines: the
    # connection carries the machine and its Windows credential. Writes to live
    # agent configuration, so it asks first.
    [string]$SetConnectionId,
    # Same, by connection display name, resolved via `pac connection list`.
    # Name connections after their machine and this reads as
    # -ConnectionName VM-Desktop.
    [string]$ConnectionName,
    # Delete every Computer Use connection reference, so the designer can mint a
    # fresh one without hitting the unique-key collision. Leaves the agent
    # unbound until you pick a machine in the designer.
    [switch]$Reset,
    # Delete one reference row, by the connection id in its name.
    [string]$DeleteConnectionId,
    # Publishing is what moves the live agent - the binding is only authoring
    # state until then - so it happens by default, and only after all four
    # checks pass. Pass -NoPublish to write the binding and stop.
    [switch]$NoPublish,
    # Agent to publish. Schema name or guid.
    [string]$Bot = 'cr720_Agent2UITesting'
)

$ErrorActionPreference = 'Stop'

# Same shape as Setup_PAD_Final.ps1, so output reads consistently across the repo.
function Write-Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok  ($m) { Write-Host "    $m" -ForegroundColor Green }
function Write-Info($m) { Write-Host "    $m" }

function Get-ErrorBody($e) {
    <# Dataverse and AAD both explain themselves in the response body; a bare
       status code does not. #>
    if ($e.ErrorDetails.Message) { return $e.ErrorDetails.Message }
    try {
        $s = $e.Exception.Response.GetResponseStream(); $s.Position = 0
        return (New-Object System.IO.StreamReader($s)).ReadToEnd()
    }
    catch { return $e.Exception.Message }
}

function Get-LocalReg {
    foreach ($p in 'HKLM:\SOFTWARE\Microsoft\Power Automate Desktop\Registration',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Power Automate Desktop\Registration') {
        if (Test-Path $p) { return Get-ItemProperty $p }
    }
}

$reg = Get-LocalReg
if (-not $OrgUrl -and $reg.OrgUri) {
    # The registry stores the .api. alias; the token scope wants the plain host.
    $OrgUrl = "https://$(([uri]$reg.OrgUri).Host -replace '\.api\.', '.')"
}
if (-not $TenantId) { $TenantId = $reg.TenantId }
if (-not $OrgUrl -or -not $TenantId) { throw 'No OrgUrl/TenantId given and none found in the local registration.' }

function Get-DeviceCodeToken {
    <# Delegated sign-in, for the writes app-only is not allowed to make. #>
    param([string]$Tenant, [string]$ClientId, [string]$Scope)

    $code = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/devicecode" `
        -Body @{ client_id = $ClientId; scope = $Scope }

    Write-Host "`n$($code.message)`n" -ForegroundColor Yellow

    $deadline = (Get-Date).AddSeconds([int]$code.expires_in)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds ([int]$code.interval)
        try {
            return (Invoke-RestMethod -Method Post `
                -Uri "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/token" `
                -Body @{
                    grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                    client_id   = $ClientId
                    device_code = $code.device_code
                }).access_token
        }
        catch {
            # authorization_pending is the normal "not signed in yet" response;
            # anything else is fatal and worth showing verbatim.
            $body = Get-ErrorBody $_
            $err  = ''
            try { $err = ($body | ConvertFrom-Json).error } catch { }
            if ($err -eq 'authorization_pending') { continue }
            if ($err -eq 'slow_down') { Start-Sleep -Seconds 5; continue }
            throw "Sign-in failed: $body"
        }
    }
    throw 'Device code expired before sign-in completed.'
}

if ($UseAzureCli) {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) not found. Install it, or use -Interactive.'
    }
    # --query/-o tsv so the token never lands in a file or the process list.
    $token = az account get-access-token --resource $OrgUrl --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        throw "az could not get a token for $OrgUrl. Run 'az login' as the account that owns the connections.`n$token"
    }
    Write-Ok "Authenticated to $OrgUrl as $(az account show --query 'user.name' -o tsv 2>$null) (delegated, via az)"
}
elseif ($Interactive) {
    # Microsoft's own public client, which every tenant already trusts for
    # Dataverse - no app registration and no "allow public client flows" needed.
    $clientId = if ($ApplicationId) { $ApplicationId } else { '51f81489-12ee-4a9e-aaae-a2591f45987d' }
    $token = Get-DeviceCodeToken -Tenant $TenantId -ClientId $clientId -Scope "$OrgUrl/.default offline_access"
    Write-Ok "Authenticated to $OrgUrl as you (delegated)"
}
else {
    if (-not $ApplicationId) {
        throw 'Pass -UseAzureCli (silent, uses an existing az login), -Interactive (device code), or -ApplicationId for app-only reads.'
    }

    $secret = $env:PAD_SECRET
    if (-not $secret) {
        $secure = Read-Host 'Client secret' -AsSecureString
        $secret = [System.Net.NetworkCredential]::new('', $secure).Password
    }
    if (-not $secret) { throw 'No client secret given. Set PAD_SECRET or type it at the prompt.' }

    $token = (Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body @{
            grant_type    = 'client_credentials'
            client_id     = $ApplicationId
            client_secret = $secret
            scope         = "$OrgUrl/.default"
        }).access_token
    $secret = $null
    Write-Ok "Authenticated to $OrgUrl as the app (client credentials)"
}

$headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }

function Invoke-Dv {
    param([string]$Method = 'Get', [string]$Path, $Body, [string]$Solution)

    $call = @{ Method = $Method; Uri = "$OrgUrl/api/data/v9.2/$Path"; Headers = $headers }
    if ($Body) {
        # If-Match keeps a PATCH update-only; without it Dataverse would upsert.
        if ($Method -eq 'Patch') { $call.Headers = $call.Headers + @{ 'If-Match' = '*' } }
        # Without this the row lands in the Default solution only, and the agent
        # publishes a package that does not contain it - which the runtime reports
        # as SystemError on every message.
        if ($Solution) { $call.Headers = $call.Headers + @{ 'MSCRM.SolutionUniqueName' = $Solution } }
        $call.ContentType = 'application/json'
        $call.Body        = ($Body | ConvertTo-Json -Compress)
    }
    try { return Invoke-RestMethod @call }
    catch {
        $body = Get-ErrorBody $_
        $msg  = $body
        try { $msg = ($body | ConvertFrom-Json).error.message } catch { }
        throw "$Method $($Path -replace '\?.*$', '') failed: $msg"
    }
}

$path = 'connectionreferences?$select=connectionreferenceid,connectionreferencelogicalname,' +
        'connectionreferencedisplayname,connectorid,connectionid'
if (-not $All) {
    $path += '&$filter=' + [uri]::EscapeDataString("contains(connectorid,'computeroperator')")
}
$rows = @((Invoke-Dv -Path $path).value)

if (-not $rows) {
    if (-not $All) {
        Write-Warning 'No Computer Use connection references. Re-run with -All to see every one.'
        return
    }

    # Two causes look identical from here - no privilege, or the wrong
    # environment. Whether the CUA solution is installed tells them apart.
    Write-Warning 'No connection references visible at all.'
    $f = [uri]::EscapeDataString("contains(uniquename,'CUAExecutionValidator')")
    if ((Invoke-Dv -Path "solutions?`$select=uniquename&`$filter=$f").value) {
        Write-Host @'

The CUA solution IS in this environment, so this is privilege filtering, not the
wrong org. Add Connection Reference (Read + Write, Business Unit) to the PAD
Computer Use role, then re-run.
'@ -ForegroundColor Yellow
    } else {
        Write-Host @"

The CUA solution is NOT in $OrgUrl. That, not privileges, is why nothing came
back: this org is where the PAD machine is registered, but the agent lives
somewhere else. Point -OrgUrl at the agent's environment before touching
security roles.
"@ -ForegroundColor Yellow
    }
    return
}

$rows | ForEach-Object {
    [pscustomobject]@{
        LogicalName  = $_.connectionreferencelogicalname
        DisplayName  = $_.connectionreferencedisplayname
        Connector    = ($_.connectorid -replace '.*/', '')
        ConnectionId = $_.connectionid
        RefId        = $_.connectionreferenceid
    }
} | Out-Host

function Resolve-ConnectionId {
    param([string]$Name)

    if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
        throw 'Power Platform CLI (pac) not found - install from https://aka.ms/PowerAppsCLI, or pass -SetConnectionId with the raw id instead.'
    }
    $out = pac connection list 2>&1
    if ($LASTEXITCODE -ne 0) { throw "pac connection list failed - run 'pac auth create' first.`n$out" }

    $cua = @($out | ForEach-Object {
        if ($_ -match '^(\S+)\s+(.*?)\s+(/providers/\S*shared_computeroperator)\s+\S+\s*$') {
            [pscustomobject]@{ Id = $Matches[1]; Name = $Matches[2].Trim() }
        }
    })
    $hit = @($cua | Where-Object { $_.Name -eq $Name })

    if ($hit.Count -eq 1) { return $hit[0].Id }
    if ($hit.Count -gt 1) { throw "'$Name' matches $($hit.Count) Computer Use connections. Rename them so each is unique." }

    throw ("No Computer Use connection named '$Name'. Available:`n" +
           (($cua | ForEach-Object { "    $($_.Name)  ->  $($_.Id)" }) -join "`n"))
}

if ($ConnectionName) {
    if ($SetConnectionId) { throw 'Pass -ConnectionName or -SetConnectionId, not both.' }
    $SetConnectionId = Resolve-ConnectionId $ConnectionName
    Write-Ok "Resolved '$ConnectionName' -> $SetConnectionId"
}

if (-not $SetConnectionId -and -not $Reset -and -not $DeleteConnectionId) { return }

if ($Reset -or $DeleteConnectionId) {
    $victims = @($rows | Where-Object {
        $_.connectorid -like '*computeroperator*' -and (-not $DeleteConnectionId -or
        $_.connectionreferencelogicalname -like "*.shared_computeroperator.$DeleteConnectionId")
    })
    if (-not $victims) {
        Write-Warning ("Nothing to delete. Present:`n" +
            (($rows | ForEach-Object { "    $($_.connectionreferencelogicalname)" }) -join "`n"))
        return
    }

    Write-Host "`nAbout to DELETE $($victims.Count) Computer Use connection reference(s):" -ForegroundColor Yellow
    $victims | ForEach-Object { Write-Info $_.connectionreferencelogicalname }
    Write-Host @'

If the agent's action names one of these, the agent has no machine bound until
you pick one in the designer. Do that straight after - the designer creates the
reference itself, and with none left behind its save cannot hit the unique-key
collision.
'@ -ForegroundColor Yellow
    if ((Read-Host 'Type YES to proceed') -ne 'YES') { Write-Host 'Cancelled.'; return }

    foreach ($v in $victims) {
        Invoke-Dv -Method Delete -Path "connectionreferences($($v.connectionreferenceid))" | Out-Null
        Write-Info "deleted $($v.connectionreferencelogicalname)"
    }
    Write-Ok 'Removed. Now open the agent designer, pick the machine, save and publish.'
    return
}

$f = [uri]::EscapeDataString("contains(schemaname,'Computeruse')")
$comp = @((Invoke-Dv -Path "botcomponents?`$select=botcomponentid,schemaname,data&`$filter=$f").value)
if ($comp.Count -ne 1) { throw "Expected one Computer Use bot component, found $($comp.Count)." }
$comp = $comp[0]

$linePattern = '(?m)^(\s*connectionReference:\s*)(\S+?)(?=[ \t\r]*$)'
$m = [regex]::Match($comp.data, $linePattern)
if (-not $m.Success) { throw 'Could not find the connectionReference line in the bot component.' }
$actionName = $m.Groups[2].Value
if ($actionName -notmatch '\.shared_computeroperator\.') {
    throw "The action names '$actionName', which is not a Computer Use connection reference."
}

$prefix     = ($actionName -split '\.shared_computeroperator\.')[0]
$targetName = "$prefix.shared_computeroperator.$SetConnectionId"
$targetRow  = @($rows | Where-Object { $_.connectionreferencelogicalname -eq $targetName })[0]

if ($actionName -eq $targetName -and $targetRow) {
    Write-Host "Already on $SetConnectionId - nothing to do." -ForegroundColor Green
    return
}

# The connection reference has to live in the same solution as the action, or it
# is not in the package the agent publishes. Read it off the action rather than
# hardcoding a name, so this survives being renamed or reused on another agent.
$solutionName = @(@((Invoke-Dv -Path ("solutioncomponents?`$select=_solutionid_value&`$filter=" +
    [uri]::EscapeDataString("objectid eq $($comp.botcomponentid)"))).value) | ForEach-Object {
        (Invoke-Dv -Path "solutions($($_._solutionid_value))?`$select=uniquename").uniquename
    } | Where-Object { $_ -notin 'Default', 'Active' })[0]
if (-not $solutionName) {
    throw 'The Computer Use action is not in any solution but Default, so there is nowhere to put the connection reference. Bind a machine once in the designer instead.'
}

$mine = @($rows | Where-Object { $_.connectionreferencelogicalname -like "$prefix.shared_computeroperator.*" })

Write-Host @"

About to switch the Computer Use machine:
    reference row  $(if ($targetRow) { "reuse $($targetRow.connectionreferenceid)" } else { "create '$targetName'" })
    action         $actionName
                -> $targetName

Existing reference rows are left alone - they are what future switches select
between. $($mine.Count) exist now.

This changes which machine the live agent runs on$(if (-not $NoPublish) { ", and publishes $Bot
afterwards so it takes effect immediately" }).
"@ -ForegroundColor Yellow
if ((Read-Host 'Type YES to proceed') -ne 'YES') { Write-Host 'Cancelled.'; return }

$linkNav = 'botcomponent_connectionreference'

Write-Step 'Connection reference'
if ($targetRow) {
    Write-Info "Row '$targetName' already exists"
} else {
    Invoke-Dv -Method Post -Path 'connectionreferences' -Solution $solutionName `
        -Body @{
            connectionreferencelogicalname = $targetName
            connectionreferencedisplayname = $targetName
            connectorid                    = '/providers/Microsoft.PowerApps/apis/shared_computeroperator'
            connectionid                   = $SetConnectionId
            iscustomizable                 = @{ Value = $false }
        } | Out-Null
    $targetRow = @((Invoke-Dv -Path ("connectionreferences?`$select=connectionreferenceid&`$filter=" +
        [uri]::EscapeDataString("connectionreferencelogicalname eq '$targetName'"))).value)[0]
    if (-not $targetRow) { throw "Created '$targetName' but it cannot be read back." }
    Write-Ok "Created '$targetName' in solution $solutionName"
}

Write-Step 'Action link'
$linked = @((Invoke-Dv -Path "botcomponents($($comp.botcomponentid))?`$select=botcomponentid&`$expand=$linkNav(`$select=connectionreferenceid)").$linkNav)

foreach ($l in $linked | Where-Object { $_.connectionreferenceid -ne $targetRow.connectionreferenceid }) {
    Invoke-Dv -Method Delete -Path "botcomponents($($comp.botcomponentid))/$linkNav($($l.connectionreferenceid))/`$ref" | Out-Null
    Write-Info "unlinked $($l.connectionreferenceid)"
}
if ($targetRow.connectionreferenceid -in $linked.connectionreferenceid) {
    Write-Info 'Already linked'
} else {
    Invoke-Dv -Method Post -Path "botcomponents($($comp.botcomponentid))/$linkNav/`$ref" `
        -Body @{ '@odata.id' = "$OrgUrl/api/data/v9.2/connectionreferences($($targetRow.connectionreferenceid))" } | Out-Null
    Write-Ok "Linked action to $($targetRow.connectionreferenceid)"
}

Write-Step 'Computer Use action'
if ($actionName -eq $targetName) {
    Write-Info 'Action already names this row'
} else {
    $newData = [regex]::Replace($comp.data, $linePattern, { param($x) $x.Groups[1].Value + $targetName })
    Invoke-Dv -Method Patch -Path "botcomponents($($comp.botcomponentid))" -Body @{ data = $newData } | Out-Null
    Write-Ok 'Repointed'
}

Write-Step 'Verifying'
$nowName = [regex]::Match((Invoke-Dv -Path "botcomponents($($comp.botcomponentid))?`$select=data").data, $linePattern).Groups[2].Value
$nowRow  = @((Invoke-Dv -Path ("connectionreferences?`$select=connectionreferenceid,connectionreferencelogicalname,connectionid&`$filter=" +
    [uri]::EscapeDataString("connectionreferencelogicalname eq '$nowName'"))).value)[0]

if ($nowName -ne $targetName) { Write-Warning "The action reads back as '$nowName'."; return }
if (-not $nowRow)             { Write-Warning "No row answers to '$nowName'. Re-run to repair."; return }
if ($nowRow.connectionid -ne $SetConnectionId) {
    Write-Warning "The row reads back with connectionid '$($nowRow.connectionid)'."
    return
}

$inSolution = @(@((Invoke-Dv -Path ("solutioncomponents?`$select=_solutionid_value&`$filter=" +
    [uri]::EscapeDataString("objectid eq $($nowRow.connectionreferenceid)"))).value) | ForEach-Object {
        (Invoke-Dv -Path "solutions($($_._solutionid_value))?`$select=uniquename").uniquename
    })
if ($solutionName -notin $inSolution) {
    Write-Warning "The connection reference is not in solution '$solutionName' (only: $($inSolution -join ', ')). The published agent will not contain it."
    return
}

# The link is the binding, so verify it rather than trusting the POST.
$nowLinked = @((Invoke-Dv -Path "botcomponents($($comp.botcomponentid))?`$select=botcomponentid&`$expand=$linkNav(`$select=connectionreferenceid)").$linkNav)
if ($nowLinked.Count -ne 1 -or $nowLinked[0].connectionreferenceid -ne $nowRow.connectionreferenceid) {
    Write-Warning ("The action is linked to $($nowLinked.Count) reference(s): $($nowLinked.connectionreferenceid -join ', ') - expected only $($nowRow.connectionreferenceid).")
    return
}

Write-Ok "link     -> $($nowRow.connectionreferenceid)"
Write-Ok "action   -> ...$SetConnectionId"
Write-Ok "row      -> connectionid $($nowRow.connectionid)"
Write-Ok "solution -> $solutionName"

if ($NoPublish) {
    Write-Host @"

NOT PUBLISHED, because -NoPublish was passed. The runtime stays on the old
machine until you publish, either from the designer or with:

    pac copilot publish --environment $OrgUrl --bot $Bot
"@ -ForegroundColor Yellow
    return
}

# Only reached once the link, action, connectionid and solution all verified -
# publishing a half-written binding succeeds and then fails every conversation.
Write-Step "Publishing $Bot"
if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
    throw "Power Platform CLI (pac) not found - install from https://aka.ms/PowerAppsCLI, or publish from the designer. The binding is already written."
}
$out = pac copilot publish --environment $OrgUrl --bot $Bot 2>&1
if ($LASTEXITCODE -ne 0) {
    throw ("Publish failed. The binding is written, so publish from the designer or re-run with -Publish:`n" +
           ($out -join "`n"))
}
Write-Ok 'Published.'
