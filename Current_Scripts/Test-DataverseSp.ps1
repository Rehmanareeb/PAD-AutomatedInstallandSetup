<#
.SYNOPSIS
  Can this service principal actually talk to Dataverse? Answers it directly,
  with no connector, no connection and no Copilot Studio in the way.

.DESCRIPTION
  A Dataverse connection can report Connected and still fail every real call.
  This isolates which half is broken by going straight at the Web API with a
  client-credentials token for the app:

      1. token          can the app get a Dataverse token at all
      2. WhoAmI         does Dataverse accept it, and as which user
      3. roles          what the application user is allowed to do
      4. table metadata can it READ the table's columns - this is what the
                        designer's inputSchema call needs, and a failure here
                        is what shows up as an empty Row Item
      5. create a row   optional, with -Write; proves write access

  A 401/403 at step 1 or 2 is an app registration or application user problem.
  Everything green here means the app is fine and the fault is in the connector
  or gateway path instead.

.PARAMETER EnvironmentUrl
  e.g. https://org59029660.crm.dynamics.com

.PARAMETER AppId
  Client id of the app registration.

.PARAMETER TenantId
  Tenant of that app.

.PARAMETER Table
  Logical name of the table to probe. Default cr720_uahtestscript.

.PARAMETER Write
  Also create a row, then delete it. Off by default - this is a read-only probe.

.EXAMPLE
  $env:PP_CLIENT_SECRET = '<secret>'
  .\Test-DataverseSp.ps1 -EnvironmentUrl https://org59029660.crm.dynamics.com `
                         -AppId 0b36118d-8138-44c8-9619-cb78fc72ea8d `
                         -TenantId cc7374ac-e69f-4e98-942a-1023569972ad
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $EnvironmentUrl,
    [Parameter(Mandatory)][string] $AppId,
    [Parameter(Mandatory)][string] $TenantId,
    [string] $Table = 'cr720_uahtestscript',
    [switch] $Write
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

$EnvironmentUrl = $EnvironmentUrl.Trim().TrimEnd('/')

$secret = $env:PP_CLIENT_SECRET
if (-not $secret) {
    $ss = Read-Host 'Client secret' -AsSecureString
    $secret = [Net.NetworkCredential]::new('', $ss).Password
}

function Show { param([string] $Step, [bool] $Ok, [string] $Detail)
    $c = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ('{0}  {1,-34} {2}' -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Step, $Detail) -ForegroundColor $c
}

function Get-Body { param($ErrorRecord)
    # The useful part of a Dataverse failure is in the body, not the status line.
    try { return $ErrorRecord.ErrorDetails.Message } catch { }
    try {
        $s = $ErrorRecord.Exception.Response.GetResponseStream()
        $r = New-Object IO.StreamReader($s); $t = $r.ReadToEnd(); $r.Dispose(); return $t
    } catch { return $ErrorRecord.Exception.Message }
}

Write-Host "`nApp $AppId  ->  $EnvironmentUrl`n"

# --- 1. token -----------------------------------------------------------------
try {
    $tok = Invoke-RestMethod -Method Post -ContentType 'application/x-www-form-urlencoded' `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body @{ client_id = $AppId; client_secret = $secret
                 scope = "$EnvironmentUrl/.default"; grant_type = 'client_credentials' }
    $secret = $null
    Show 'client-credentials token' $true "expires in $($tok.expires_in)s"
}
catch {
    $secret = $null
    Show 'client-credentials token' $false (Get-Body $_)
    Write-Host "`nThe app cannot get a Dataverse token. Fix the app registration before anything else.`n" -ForegroundColor Yellow
    return
}

$h = @{ Authorization = "Bearer $($tok.access_token)"; Accept = 'application/json'
        'OData-Version' = '4.0'; 'OData-MaxVersion' = '4.0' }
$api = "$EnvironmentUrl/api/data/v9.2"

# --- 2. WhoAmI ----------------------------------------------------------------
try {
    $who = Invoke-RestMethod -Uri "$api/WhoAmI" -Headers $h
    Show 'WhoAmI' $true "user $($who.UserId)"
}
catch { Show 'WhoAmI' $false (Get-Body $_); Write-Host ''; return }

# --- 3. roles -----------------------------------------------------------------
try {
    $roles = (Invoke-RestMethod -Headers $h `
        -Uri "$api/systemusers($($who.UserId))/systemuserroles_association?`$select=name").value
    $names = @($roles | ForEach-Object { $_.name })
    Show 'security roles' ($names.Count -gt 0) $(if ($names.Count) { $names -join ', ' } else { 'NONE - it can sign in but do nothing' })
}
catch { Show 'security roles' $false (Get-Body $_) }

# --- 4. table metadata --------------------------------------------------------
# The designer's inputSchema call needs exactly this. If the app cannot read the
# columns, Row Item has nothing to show and comes back empty.
try {
    $attrs = (Invoke-RestMethod -Headers $h `
        -Uri "$api/EntityDefinitions(LogicalName='$Table')/Attributes?`$select=LogicalName").value
    $custom = @($attrs | Where-Object { $_.LogicalName -match '^(cr720_|cre44_)' })
    Show "read $Table metadata" $true "$($attrs.Count) attributes, $($custom.Count) custom"
}
catch { Show "read $Table metadata" $false (Get-Body $_) }

# --- 5. read rows -------------------------------------------------------------
try {
    $rows = (Invoke-RestMethod -Headers $h -Uri "$api/$($Table)s?`$top=1&`$select=$($Table)id").value
    Show "read $Table rows" $true "$(@($rows).Count) row(s) returned"
}
catch { Show "read $Table rows" $false (Get-Body $_) }

# --- 6. write -----------------------------------------------------------------
if ($Write) {
    try {
        $r = Invoke-WebRequest -Method Post -Uri "$api/$($Table)s" -Headers $h `
             -ContentType 'application/json' -Body (@{ cr720_scriptname = 'sp-probe' } | ConvertTo-Json)
        $loc = $r.Headers['OData-EntityId']
        Show "create a row in $Table" $true 'created'
        if ($loc) { Invoke-RestMethod -Method Delete -Uri ([string]$loc).Trim('"') -Headers $h | Out-Null
                    Write-Host '      (probe row deleted)' }
    }
    catch { Show "create a row in $Table" $false (Get-Body $_) }
}

Write-Host "`nAll green means the app registration and application user are fine," -ForegroundColor Yellow
Write-Host "and the 403 is coming from the connector or gateway, not Dataverse.`n" -ForegroundColor Yellow
