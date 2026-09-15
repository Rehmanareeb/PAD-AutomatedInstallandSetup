<#
.SYNOPSIS
  Diff two Power Platform connections, to find what a script-created one has
  that a portal-created one does not (or the reverse).

.DESCRIPTION
  A Dataverse connection created by PUT to api.powerapps.com and one created at
  make.powerapps.com can both report Connected and both work at run time, and
  still differ in ways the Copilot Studio designer cares about - which is how a
  tool bound to one shows its inputs and the same tool bound to the other shows
  an empty panel.

  This does not guess at which field matters. It prints every property that
  differs, with secrets redacted, so the difference can be read off rather than
  theorised about.

  Run with no -ScriptMade/-PortalMade and it lists the Dataverse connections in
  the environment so you can pick the two ids.

.PARAMETER EnvironmentId
  Power Platform environment GUID.

.PARAMETER ScriptMade
  Connection id the script created.

.PARAMETER PortalMade
  Connection id created at make.powerapps.com.

.PARAMETER Connector
  Connector to list/compare. Defaults to Dataverse.

.EXAMPLE
  .\Compare-PpConnection.ps1 -EnvironmentId e1035d94-a890-eee7-8688-24702427f70a

  List the Dataverse connections and their ids.

.EXAMPLE
  .\Compare-PpConnection.ps1 -EnvironmentId e1035d94-... -ScriptMade fb2c13fa... -PortalMade 9a41...

  Show every property that differs between the two.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $EnvironmentId,
    [string] $ScriptMade,
    [string] $PortalMade,
    [string] $Connector = 'shared_commondataserviceforapps'
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) not found.' }
$token = az account get-access-token --resource 'https://service.powerapps.com/' --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $token) { throw "Could not get a Power Apps token. Run: az login`n$token" }
$headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }

$envFilter = '&%24filter=' + [uri]::EscapeDataString("environment eq '$EnvironmentId'")
$base = "https://api.powerapps.com/providers/Microsoft.PowerApps/apis/$Connector/connections"

if (-not $ScriptMade -or -not $PortalMade) {
    $all = (Invoke-RestMethod -Uri "$base`?api-version=2016-11-01$envFilter" -Headers $headers).value
    Write-Host "`n$($all.Count) '$Connector' connection(s) in $EnvironmentId`n"
    $all | ForEach-Object {
        $st = @($_.properties.statuses.status)[0]
        '  {0,-34} {1,-28} {2,-10} {3}' -f $_.name, $_.properties.displayName, $st, $_.properties.createdTime
    }
    Write-Host "`nRe-run with -ScriptMade <id> -PortalMade <id> to diff two of them.`n"
    return
}

# Flatten to dotted paths so two shapes can be compared key by key.
function ConvertTo-FlatMap {
    param($Object, [string] $Prefix = '', [hashtable] $Into = @{})
    if ($null -eq $Object) { $Into[$Prefix] = '(null)'; return $Into }
    if ($Object -is [string] -or $Object -is [ValueType]) { $Into[$Prefix] = "$Object"; return $Into }
    if ($Object -is [System.Collections.IEnumerable]) {
        $i = 0
        foreach ($item in $Object) { ConvertTo-FlatMap -Object $item -Prefix "$Prefix[$i]" -Into $Into | Out-Null; $i++ }
        if ($i -eq 0) { $Into[$Prefix] = '(empty)' }
        return $Into
    }
    foreach ($p in $Object.PSObject.Properties) {
        $key = if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }
        ConvertTo-FlatMap -Object $p.Value -Prefix $key -Into $Into | Out-Null
    }
    return $Into
}

function Get-Connection {
    param([string] $Id)
    Invoke-RestMethod -Uri "$base/$Id`?api-version=2016-11-01$envFilter" -Headers $headers
}

$a = ConvertTo-FlatMap (Get-Connection $ScriptMade)
$b = ConvertTo-FlatMap (Get-Connection $PortalMade)

# Never print anything secret-shaped, and ignore fields that must differ.
$secret = '(?i)secret|password|token$|\.token\.|credential'
$noise  = '(?i)^(name|id)$|createdTime|lastModifiedTime|properties\.createdTime|properties\.displayName|^properties\.connectionName'

$keys = @($a.Keys + $b.Keys | Sort-Object -Unique) | Where-Object { $_ -notmatch $noise }

$onlyScript = @(); $onlyPortal = @(); $differs = @()
foreach ($k in $keys) {
    $hasA = $a.ContainsKey($k); $hasB = $b.ContainsKey($k)
    $va = if ($hasA) { if ($k -match $secret) { '<redacted>' } else { $a[$k] } } else { $null }
    $vb = if ($hasB) { if ($k -match $secret) { '<redacted>' } else { $b[$k] } } else { $null }
    if     ($hasA -and -not $hasB) { $onlyScript += [pscustomobject]@{ Property = $k; Value = $va } }
    elseif ($hasB -and -not $hasA) { $onlyPortal += [pscustomobject]@{ Property = $k; Value = $vb } }
    elseif ($va -ne $vb)           { $differs    += [pscustomobject]@{ Property = $k; Script = $va; Portal = $vb } }
}

Write-Host "`n=== only on the SCRIPT-made connection ($ScriptMade) ===" -ForegroundColor Cyan
if ($onlyScript) { $onlyScript | Format-Table -AutoSize } else { Write-Host '  (nothing)' }

Write-Host "`n=== only on the PORTAL-made connection ($PortalMade) ===" -ForegroundColor Cyan
if ($onlyPortal) { $onlyPortal | Format-Table -AutoSize } else { Write-Host '  (nothing)' }

Write-Host "`n=== present on both, different value ===" -ForegroundColor Cyan
if ($differs) { $differs | Format-Table -AutoSize -Wrap } else { Write-Host '  (nothing)' }

Write-Host "`nThe portal-made column is the one that works. Anything listed under" -ForegroundColor Yellow
Write-Host "'only on the PORTAL-made connection' is a candidate for what the PUT omits.`n" -ForegroundColor Yellow
