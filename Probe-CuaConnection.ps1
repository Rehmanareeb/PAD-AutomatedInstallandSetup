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

  Without -SetActionConnectionId / -ConnectionName this only reads and reports.

  Authenticates with the same app registration and PAD_SECRET as
  Setup_PAD_Final.ps1. Needs Bot Component and Connection Reference (Read +
  Write, Business Unit) on the application user's security role.

.EXAMPLE
  $env:PAD_SECRET = '<client secret>'
  .\Probe-CuaConnection.ps1 -ApplicationId <app-guid> -ConnectionName VM-Desktop

.EXAMPLE
  # Report the current binding only.
  .\Probe-CuaConnection.ps1 -ApplicationId <app-guid>
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    # Print usage and exit. In its own parameter set so -Help alone works
    # without PowerShell prompting for -ApplicationId.
    [Parameter(ParameterSetName = 'Help')][switch]$Help,
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$ApplicationId,
    # Both default to the local PAD registration, as in Setup_PAD_Final.ps1.
    [string]$OrgUrl,
    [string]$TenantId,
    # Widen to see every connection reference, not just Computer Use ones.
    [switch]$All,
    # Repoint the Computer Use connection reference at a different connection,
    # e.g. 'shared-computeropera-<guid>'. This is what switches machines: the
    # connection carries the machine and its Windows credential. Writes to live
    # agent configuration, so it asks first.
    [string]$SetConnectionId,
    # Dump every column of the Computer Use row instead of the five we usually
    # select. Use it to diff a working (designer-bound) state against a broken
    # (PATCH-bound) one and find the column the designer sets that we do not.
    [switch]$Raw,
    # Rewrite the Computer Use ACTION's connectionReference to name this
    # connection. Proven 2026-08-19: the runtime resolves the machine from this
    # string, not from connectionreference.connectionid - a PATCH of the latter
    # left the agent running on the old machine.
    [string]$SetActionConnectionId,
    # Same as -SetActionConnectionId but by connection display name, resolved via
    # `pac connection list`. Needs a pac auth profile (`pac auth create`).
    # Name connections after their machine and this reads as -ConnectionName VM-Desktop.
    [string]$ConnectionName
)

$ErrorActionPreference = 'Stop'

# Same shape as Setup_PAD_Final.ps1, so output reads consistently across the repo.
function Write-Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok  ($m) { Write-Host "    $m" -ForegroundColor Green }
function Write-Info($m) { Write-Host "    $m" }

if ($Help) {
    Write-Host @'
Probe-CuaConnection.ps1 - switch the machine the agent's Computer Use tool runs on.

  The machine is chosen by one line in the Computer Use action, stored in the
  Dataverse botcomponents table. Each connection targets one machine, so
  rewriting the connection id there moves the agent.

REQUIRED
  -ApplicationId <guid>    App registration used for Dataverse. Its application
                           user needs Bot Component and Connection Reference
                           (Read + Write, Business Unit).
  $env:PAD_SECRET          Client secret for that app. Prompted for if unset.

PICK A CONNECTION (one of, optional - omit both to only report)
  -SetActionConnectionId <id>   Bind by connection id.
  -ConnectionName <name>        Bind by connection display name, resolved with
                                pac. Lists the names if it does not match.

OPTIONAL
  -OrgUrl <url>            Default: read from the local PAD registration.
  -TenantId <guid>         Default: read from the local PAD registration.
  -Help                    This text.

DIAGNOSTIC
  -All                     List every connection reference, not just Computer Use.
  -Raw                     Dump every column of the Computer Use row.
  -SetConnectionId <id>    Repoint connectionreference.connectionid. Kept for
                           reference only - proven NOT to change the machine.

EXAMPLES
  $env:PAD_SECRET = '<secret>'
  .\Probe-CuaConnection.ps1 -ApplicationId <app> -ConnectionName VM-Desktop
  .\Probe-CuaConnection.ps1 -ApplicationId <app>          # report current binding

  Writing the binding does NOT publish. Publish from the designer afterwards.
  -ConnectionName needs pac signed in:
  pac auth create --environment https://<org>.crm.dynamics.com
'@
    return
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
Write-Host "Authenticated to $OrgUrl as the app (client credentials)" -ForegroundColor Green

$headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
$select  = 'connectionreferenceid,connectionreferencelogicalname,connectionreferencedisplayname,connectorid,connectionid'
$uri     = "$OrgUrl/api/data/v9.2/connectionreferences?`$select=$select"
if ($Raw) {
    # No $select at all - we are looking for a column we do not know the name of.
    $uri = "$OrgUrl/api/data/v9.2/connectionreferences"
}
if (-not $All) {
    $filter = "contains(connectorid,'computeroperator')"
    # .Contains, not -like '*?*' - in a wildcard, ? matches any single character.
    $uri += "$(if ($uri.Contains('?')) { '&' } else { '?' })`$filter=$([uri]::EscapeDataString($filter))"
}

try { $rows = (Invoke-RestMethod -Method Get -Uri $uri -Headers $headers).value }
catch {
    # Dataverse explains itself in the body; a bare status code does not.
    $body = $_.ErrorDetails.Message
    if (-not $body) {
        try {
            $s = $_.Exception.Response.GetResponseStream(); $s.Position = 0
            $body = (New-Object System.IO.StreamReader($s)).ReadToEnd()
        } catch { }
    }
    throw "Query failed: $(if ($body) { $body } else { $_.Exception.Message })"
}

if (-not $rows) {
    if (-not $All) {
        Write-Warning 'No Computer Use connection references. Re-run with -All to see every one.'
        return
    }

    # Zero rows has two very different causes and they need opposite fixes:
    # privilege filtering (Dataverse silently trims a collection query to rows
    # the caller can see) or simply the wrong environment. Looking for the
    # agent's own solution tells us which - if it is not here, no amount of role
    # editing will help.
    Write-Warning 'No connection references visible at all.'
    try {
        $f    = "contains(uniquename,'CUAExecutionValidator')"
        $sols = (Invoke-RestMethod -Method Get -Headers $headers `
            -Uri ("$OrgUrl/api/data/v9.2/solutions?`$select=uniquename,version" +
                  "&`$filter=$([uri]::EscapeDataString($f))")).value

        if ($sols) {
            Write-Host "`nThe CUA solution IS in this environment:" -ForegroundColor Green
            $sols | ForEach-Object { "    $($_.uniquename) $($_.version)" }
            Write-Host @'

So this is privilege filtering, not the wrong environment. Add Connection
Reference (Read + Write, Business Unit) to the PAD Computer Use role, then
re-run.
'@ -ForegroundColor Yellow
        } else {
            Write-Host @"

The CUA solution is NOT in this environment ($OrgUrl).

That, not privileges, is why nothing came back: this org is where the PAD
machine is registered, but the agent lives somewhere else. Point -OrgUrl at
the agent's environment before touching security roles.
"@ -ForegroundColor Yellow
        }
    }
    catch {
        Write-Warning "Could not read the solutions table either, so the cause is still open: $($_.Exception.Message)"
    }
    return
}

if ($Raw) {
    # Sorted so two dumps diff cleanly.
    $rows | ForEach-Object {
        $r = $_
        $o = [ordered]@{}
        $r.PSObject.Properties.Name | Where-Object { $_ -notlike '*@odata*' } | Sort-Object |
            ForEach-Object { $o[$_] = $r.$_ }
        [pscustomobject]$o | ConvertTo-Json -Depth 5
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
    <#
      Connections live outside Dataverse and we have no API token that can read
      them, but pac can. Its output is a fixed table, so: id, then a name that
      may contain spaces, then the /providers/... api id, then status.
    #>
    param([string]$Name)

    if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
        throw 'Power Platform CLI (pac) not found - install from https://aka.ms/PowerAppsCLI, or pass -SetActionConnectionId with the raw id instead.'
    }
    $out = pac connection list 2>&1
    if ($LASTEXITCODE -ne 0) { throw "pac connection list failed - run 'pac auth create' first.`n$out" }

    $rows = $out | ForEach-Object {
        if ($_ -match '^(\S+)\s+(.*?)\s+(/providers/\S+)\s+(\S+)\s*$') {
            [pscustomobject]@{ Id = $Matches[1]; Name = $Matches[2].Trim(); Api = $Matches[3] }
        }
    }
    $cua = @($rows | Where-Object { $_.Api -like '*shared_computeroperator' })
    $hit = @($cua | Where-Object { $_.Name -eq $Name })

    if ($hit.Count -eq 1) { return $hit[0].Id }
    if ($hit.Count -gt 1) { throw "'$Name' matches $($hit.Count) Computer Use connections. Rename them so each is unique." }

    throw ("No Computer Use connection named '$Name'. Available:`n" +
           (($cua | ForEach-Object { "    $($_.Name)  ->  $($_.Id)" }) -join "`n"))
}

if ($ConnectionName) {
    if ($SetActionConnectionId) { throw 'Pass -ConnectionName or -SetActionConnectionId, not both.' }
    $SetActionConnectionId = Resolve-ConnectionId $ConnectionName
    Write-Host "Resolved '$ConnectionName' -> $SetActionConnectionId" -ForegroundColor Green
}

if ($SetActionConnectionId) {
    $f = [uri]::EscapeDataString("contains(schemaname,'Computeruse')")
    $comp = (Invoke-RestMethod -Headers $headers `
        -Uri "$OrgUrl/api/data/v9.2/botcomponents?`$select=botcomponentid,schemaname,data&`$filter=$f").value
    if ($comp.Count -ne 1) { throw "Expected one Computer Use bot component, found $($comp.Count)." }
    $comp = $comp[0]

    # …shared_computeroperator.<connection-id> - swap only the last segment.
    $pattern = '(?m)^(\s*connectionReference:\s*\S*\.shared_computeroperator\.)(\S+)\s*$'
    $m = [regex]::Match($comp.data, $pattern)
    if (-not $m.Success) { throw 'Could not find the connectionReference line in the bot component.' }
    $current = $m.Groups[2].Value

    if ($current -eq $SetActionConnectionId) {
        Write-Host "Action already bound to $SetActionConnectionId - nothing to do." -ForegroundColor Green
        return
    }

    Write-Host @"

About to rewrite the Computer Use ACTION binding:
    component  $($comp.schemaname)
    from       $current
    to         $SetActionConnectionId

This is the string the runtime resolves the machine from.
"@ -ForegroundColor Yellow
    if ((Read-Host 'Type YES to proceed') -ne 'YES') { Write-Host 'Cancelled.'; return }

    $newData = [regex]::Replace($comp.data, $pattern, { param($x)
        $x.Groups[1].Value + $SetActionConnectionId })

    try {
        Invoke-RestMethod -Method Patch `
            -Uri "$OrgUrl/api/data/v9.2/botcomponents($($comp.botcomponentid))" `
            -Headers ($headers + @{ 'If-Match' = '*' }) -ContentType 'application/json' `
            -Body (@{ data = $newData } | ConvertTo-Json -Compress) | Out-Null
    }
    catch {
        $body = $_.ErrorDetails.Message
        if (-not $body) {
            try {
                $s = $_.Exception.Response.GetResponseStream(); $s.Position = 0
                $body = (New-Object System.IO.StreamReader($s)).ReadToEnd()
            } catch { }
        }
        throw "PATCH failed: $(if ($body) { $body } else { $_.Exception.Message })"
    }

    $after = (Invoke-RestMethod -Headers $headers `
        -Uri "$OrgUrl/api/data/v9.2/botcomponents($($comp.botcomponentid))?`$select=data").data
    $now = [regex]::Match($after, $pattern).Groups[2].Value
    if ($now -ne $SetActionConnectionId) {
        Write-Warning "PATCH reported success but the binding reads back as '$now'. The column is server-controlled."
        return
    }
    Write-Ok "Action now bound to $now"

    Write-Host @"

NOT PUBLISHED. The runtime stays on the old machine until you publish, either
from the designer or with:

    pac copilot publish --environment $OrgUrl --bot <agent-schema-name>
"@ -ForegroundColor Yellow
    return
}

if (-not $SetConnectionId) { return }

$cua = @($rows | Where-Object { $_.connectorid -like '*computeroperator*' })
if ($cua.Count -ne 1) {
    throw "Expected exactly one Computer Use connection reference, found $($cua.Count). Repoint it by hand rather than guessing."
}
$ref = $cua[0]

if ($ref.connectionid -eq $SetConnectionId) {
    Write-Host "Already pointing at $SetConnectionId - nothing to do." -ForegroundColor Green
    return
}

Write-Host @"

About to repoint the Computer Use action:
    ref   $($ref.connectionreferenceid)
    from  $($ref.connectionid)
    to    $SetConnectionId

This changes which machine the live agent runs on.
"@ -ForegroundColor Yellow
if ((Read-Host 'Type YES to proceed') -ne 'YES') { Write-Host 'Cancelled.'; return }

try {
    # If-Match makes this update-only; without it Dataverse would happily upsert
    # a new connection reference row.
    Invoke-RestMethod -Method Patch `
        -Uri "$OrgUrl/api/data/v9.2/connectionreferences($($ref.connectionreferenceid))" `
        -Headers ($headers + @{ 'If-Match' = '*' }) -ContentType 'application/json' `
        -Body (@{ connectionid = $SetConnectionId } | ConvertTo-Json -Compress) | Out-Null
}
catch {
    $body = $_.ErrorDetails.Message
    if (-not $body) {
        try {
            $s = $_.Exception.Response.GetResponseStream(); $s.Position = 0
            $body = (New-Object System.IO.StreamReader($s)).ReadToEnd()
        } catch { }
    }
    throw "PATCH failed: $(if ($body) { $body } else { $_.Exception.Message })"
}

# Read back rather than trusting the 204 - the column may be server-controlled.
$after = (Invoke-RestMethod -Method Get -Headers $headers `
    -Uri "$OrgUrl/api/data/v9.2/connectionreferences($($ref.connectionreferenceid))?`$select=connectionid").connectionid

if ($after -eq $SetConnectionId) {
    Write-Host "Repointed. connectionid is now $after" -ForegroundColor Green
    Write-Host 'Test the agent before trusting it: the runtime may cache the old binding until republish.'
} else {
    Write-Warning "PATCH reported success but connectionid reads back as '$after'. The column is not freely writable - this route does not work."
}
